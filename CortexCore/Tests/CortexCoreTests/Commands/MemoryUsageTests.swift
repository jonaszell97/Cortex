import Foundation
import Testing
@testable import CortexCore

/// `$mem`: reading `vm_stat` and `ps`, and the report. The Mac's real
/// numbers are not asserted.
@Suite struct MemoryUsageTests {
    static let vmStat = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                                    21994.
        Pages active:                                 334584.
        Pages inactive:                               330633.
        Pages speculative:                              3240.
        Pages throttled:                                   0.
        Pages wired down:                             349827.
        Pages purgeable:                                 972.
        "Translation faults":                      718472703.
        File-backed pages:                            176927.
        Anonymous pages:                              491530.
        Pages stored in compressor:                   968939.
        Pages occupied by compressor:                 498785.
        Swapouts:                                    2968376.
        """

    @Test func vmStatIsRead() throws {
        let statistics = try #require(VMStatistics(vmStat: Self.vmStat))
        #expect(statistics.pageSize == 16_384)
        #expect(statistics.wired == 349_827)
        #expect(statistics.purgeable == 972)
        #expect(statistics.fileBacked == 176_927)
        #expect(statistics.anonymous == 491_530)
        #expect(statistics.compressor == 498_785, "occupied, not stored")
        #expect(statistics.appMemory == (491_530 - 972) * 16_384)
        #expect(statistics.usedMemory == statistics.appMemory + 349_827 * 16_384 + 498_785 * 16_384)
        #expect(statistics.cachedFiles == (176_927 + 972) * 16_384)
        #expect(VMStatistics(vmStat: "Pages free: 1.") == nil, "no page size")
    }

    @Test func psIsReadForTheUsersProcesses() {
        let output = """
                1     0  22400 /sbin/launchd
              501   501 204800 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
              777   501   1024 node
             4242   501 512000 /Applications/Safari.app/Contents/MacOS/Safari
            garbage line
            """
        let processes = MemoryUsageCommand.parse(ps: output, uid: 501)
        #expect(processes == [
            ProcessMemory(
                pid: 501, name: "Google Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                residentBytes: 204_800 * 1024),
            ProcessMemory(pid: 777, name: "node", residentBytes: 1024 * 1024),
            ProcessMemory(
                pid: 4242, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", residentBytes: 512_000 * 1024),
        ])
        #expect(MemoryUsageCommand.largest(processes, limit: 2).map(\.name) == ["Safari", "Google Chrome"])
    }

    static let meminfo = """
        MemTotal:        8245584 kB
        MemFree:         5820272 kB
        MemAvailable:    7527568 kB
        Buffers:          110448 kB
        Cached:          1661648 kB
        SwapTotal:        204784 kB
        SwapFree:         104784 kB
        Zswap:                 0 kB
        SReclaimable:      40000 kB
        SUnreclaim:        41680 kB
        KernelStack:        9000 kB
        PageTables:        12000 kB
        """

    @Test func linuxMeminfoIsReadLikeFree() throws {
        let snapshot = try #require(MemorySnapshot(host: "pi", meminfo: Self.meminfo, processes: []))
        #expect(snapshot.host == "pi" && snapshot.platform == .linux && snapshot.wiredTitle == "Kernel")
        #expect(snapshot.physical == 8_245_584 * 1024)
        #expect(snapshot.cachedFiles == (110_448 + 1_661_648 + 40_000) * 1024, "buffers, page cache, reclaimable slabs")
        #expect(snapshot.free == 5_820_272 * 1024)
        #expect(snapshot.wired == (41_680 + 9_000 + 12_000) * 1024)
        #expect(snapshot.compressed == 0)
        #expect(snapshot.used == (8_245_584 - 5_820_272 - 110_448 - 1_661_648 - 40_000) * 1024)
        #expect(snapshot.swapTotal == 204_784 * 1024 && snapshot.swapUsed == 100_000 * 1024)
        #expect(snapshot.pressure == nil)
        #expect(MemorySnapshot(host: "pi", meminfo: "Cached: 1 kB", processes: []) == nil)
    }

    @Test func aHostIsReadOverSSH() async throws {
        let output = "@@ system\nLinux\n@@ meminfo\n" + Self.meminfo + "\n@@ memsize\n@@ vmstat\n@@ swap\n@@ pressure\n"
            + "@@ ps\n    1     0  9000 systemd\n  612     0 116528 AdGuardHome\n  896  1000 92864 labwc\n"
        let command = MemoryUsageCommand { machine, script in
            guard machine == .ssh("raspberrypi"), script == MemoryUsageCommand.remoteScript else { throw QuickActionError("wrong call") }
            return output
        }
        #expect(command.runsOnHosts && command.argument == nil && command.usage == "mem")
        #expect(command.accepts(.none) && !command.accepts(.text("raspberrypi")), "the host comes from @, not the argument")
        let result = try await command.output(.none, context: ActionContext(
            fallbackOutputDirectory: URL(filePath: "/tmp"), temporaryDirectory: URL(filePath: "/tmp"), machine: .ssh("raspberrypi")))
        guard case .report(let report) = result, let snapshot = report.content as? MemorySnapshot else {
            throw QuickActionError("no snapshot")
        }
        #expect(snapshot.host == "raspberrypi")
        #expect(snapshot.processes.map(\.name) == ["AdGuardHome", "labwc", "systemd"], "everyone's, largest first")
        let lines = report.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "raspberrypi")
        #expect(lines.contains { $0.hasPrefix("  Kernel ") } && !lines.contains { $0.contains("Compressed") })
        #expect(lines.contains("Largest processes"))

        await #expect(throws: QuickActionError("wrong call")) {
            try await command.output(.none, context: ActionContext(
                fallbackOutputDirectory: URL(filePath: "/tmp"), temporaryDirectory: URL(filePath: "/tmp"), machine: .ssh("linode")))
        }
        #expect(throws: QuickActionError("bsd runs FreeBSD; only macOS and Linux hosts are read over SSH")) {
            try MemoryUsageCommand.snapshot(host: "bsd", remoteOutput: "@@ system\nFreeBSD\n")
        }
    }

    @Test func aMacHostIsReadLikeThisMac() throws {
        let output = """
            @@ system
            Darwin
            @@ meminfo
            @@ memsize
            25769803776
            @@ vmstat
            \(Self.vmStat)
            @@ swap
            total = 9216.00M  used = 7513.19M  free = 1702.81M  (encrypted)
            @@ pressure
            2
            @@ ps
              501   501 204800 /Applications/Safari.app/Contents/MacOS/Safari
                1     0  22400 /sbin/launchd
            """
        let snapshot = try MemoryUsageCommand.snapshot(host: "studio", remoteOutput: output)
        let statistics = try #require(VMStatistics(vmStat: Self.vmStat))
        #expect(snapshot.host == "studio" && snapshot.platform == .mac && snapshot.wiredTitle == "Wired")
        #expect(snapshot.physical == 24 * 1024 * 1024 * 1024)
        #expect(snapshot.used == statistics.usedMemory)
        #expect(snapshot.pressure == .warning)
        #expect(snapshot.swapTotal == Int64(9216) * 1024 * 1024)
        #expect(snapshot.swapUsed == Int64(7513.19 * 1024 * 1024))
        #expect(snapshot.processes.map(\.name) == ["Safari", "launchd"], "everyone's")
        #expect(throws: QuickActionError("studio gave no memory statistics")) {
            try MemoryUsageCommand.snapshot(host: "studio", remoteOutput: "@@ system\nDarwin\n@@ memsize\n1\n")
        }
        #expect(MemoryUsageCommand.swapUsage(sysctl: "total = 0.00M  used = 0.00M  free = 0.00M")! == (0, 0))
        #expect(MemoryUsageCommand.swapUsage(sysctl: "") == nil)
    }

    @Test func theSnapshot() throws {
        let statistics = try #require(VMStatistics(vmStat: Self.vmStat))
        let snapshot = MemorySnapshot(
            physical: 24 * 1024 * 1024 * 1024, statistics: statistics, swap: (used: 4, total: 5), pressure: .normal,
            processes: [])
        #expect(snapshot.used == statistics.usedMemory)
        #expect(snapshot.cachedFiles == statistics.cachedFiles)
        #expect(snapshot.free == snapshot.physical - statistics.usedMemory - statistics.cachedFiles)
        #expect(snapshot.swapUsed == 4 && snapshot.swapTotal == 5)
        let overfull = MemorySnapshot(physical: 1, statistics: statistics, swap: nil, pressure: nil, processes: [])
        #expect(overfull.free == 0, "never negative")
    }

    @Test func theReport() throws {
        let statistics = try #require(VMStatistics(vmStat: Self.vmStat))
        let report = MemoryUsageCommand.report(
            MemorySnapshot(
                physical: 24 * 1024, statistics: statistics, swap: (used: 4, total: 5), pressure: nil,
                processes: [ProcessMemory(pid: 4242, name: "Safari", residentBytes: 2), ProcessMemory(pid: 77, name: "node", residentBytes: 1)]),
            bytes: { "\($0)" })
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first?.hasPrefix("Physical memory") == true)
        #expect(lines.first?.hasSuffix(" 24576") == true, "values are right-aligned")
        #expect(lines.contains { $0.hasPrefix("  App memory ") })
        #expect(lines.contains { $0.hasPrefix("Swap used") && $0.hasSuffix("4  of 5") })
        #expect(Array(lines.suffix(4)) == [
            "Your largest processes",
            " PID  Memory  Name",
            "4242       2  Safari",
            "  77       1  node",
        ])
        let withoutProcesses = MemoryUsageCommand.report(
            MemorySnapshot(physical: 1, statistics: statistics, swap: nil, pressure: nil, processes: []), bytes: { "\($0)" })
        #expect(!withoutProcesses.contains("Swap") && !withoutProcesses.contains("processes"))
    }

    @Test func itTakesNothingAndRunsOnThisMac() async throws {
        let command = MemoryUsageCommand()
        #expect(command.accepts(.none))
        #expect(command.usage == "mem")
        let outcome = try await command.resolve(.none)
        guard case .value(.report(let report), let refresh) = outcome else { throw QuickActionError("no value") }
        #expect(refresh == .seconds(2), "a value worth reading again while it is selected")
        #expect(report.text.hasPrefix("Physical memory"))
        #expect(report.text.contains("Your largest processes"))
        guard let snapshot = report.content as? MemorySnapshot else {
            throw QuickActionError("no snapshot for the pane")
        }
        #expect(snapshot.physical == Int64(ProcessInfo.processInfo.physicalMemory))
        #expect(snapshot.used + snapshot.cachedFiles + snapshot.free >= snapshot.physical, "free fills up to physical")
        #expect(snapshot.processes.count <= MemoryUsageCommand.processLimit)
    }
}

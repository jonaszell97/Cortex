import Foundation
import Testing
@testable import CortexCore

/// `$cpu`: reading `top` on a Mac and `/proc` on Linux, and the report.
/// The Mac's real numbers are not asserted.
@Suite struct CPUUsageTests {
    static let top = """
        Processes: 598 total, 4 running, 594 sleeping, 5529 threads
        2026/10/23 09:00:00
        Load Avg: 4.51, 4.04, 3.55
        CPU usage: 10.78% user, 13.47% sys, 75.74% idle

        PID    %CPU COMMAND
        13273  0.0  mediaanalysisd
        Processes: 597 total, 4 running, 593 sleeping, 5530 threads
        2026/10/23 09:00:01
        Load Avg: 4.60, 4.06, 3.56
        CPU usage: 16.30% user, 12.12% sys, 71.57% idle

        PID    %CPU  COMMAND
        13273  98.5  mediaanalysisd
        80746  7.0   top
        178    9.4   WindowServer
        35407  13.0  VTDecoderXPCServ
        99     0.0   idle thing
        """

    @Test func aMacIsReadFromTheSecondTopSample() throws {
        let output = "@@ system\nDarwin\n@@ model\nApple M4 Pro\n@@ cores\n14\n@@ top\n" + Self.top
        let snapshot = try CPUUsageCommand.snapshot(host: "studio", output: output)
        #expect(snapshot.host == "studio" && snapshot.platform == .mac)
        #expect(snapshot.model == "Apple M4 Pro" && snapshot.coreCount == 14)
        #expect(abs(snapshot.user - 0.163) < 1e-9 && abs(snapshot.system - 0.1212) < 1e-9)
        #expect(snapshot.loadAverage == [4.60, 4.06, 3.56])
        #expect(snapshot.cores.isEmpty && snapshot.temperature == nil)
        #expect(snapshot.processes.map(\.name) == ["mediaanalysisd", "VTDecoderXPCServ", "WindowServer"],
                "busiest first; top itself and idle ones left out")
        #expect(snapshot.processes.first?.usage == 0.985)
    }

    static let linux = """
        @@ system
        Linux
        @@ model
        Model		: Raspberry Pi 5 Model B Rev 1.0
        @@ load
        0.07 0.05 0.00 2/373 85165
        @@ temperature
        44650
        @@ stat1
        cpu  1000 0 500 8500 0 0 0 0 0 0
        cpu0 500 0 250 4250 0 0 0 0 0 0
        cpu1 500 0 250 4250 0 0 0 0 0 0
        @@ procs1
        1 (systemd) S 0 1 1 0 -1 4194560 63097 3835044 187 3765 100 50 173152 19883 20 0 1 0 0 1 1 1
        42 (Web Content (x)) R 1 42 42 0 -1 0 0 0 0 0 1000 0 0 0 20 0 1 0 0 1 1 1
        @@ stat2
        cpu  1150 0 550 8700 0 0 0 0 0 0
        cpu0 650 0 280 4270 0 0 0 0 0 0
        cpu1 500 0 270 4430 0 0 0 0 0 0
        @@ procs2
        1 (systemd) S 0 1 1 0 -1 4194560 63097 3835044 187 3765 105 50 173152 19883 20 0 1 0 0 1 1 1
        42 (Web Content (x)) R 1 42 42 0 -1 0 0 0 0 0 1150 20 0 0 20 0 1 0 0 1 1 1
        77 (new) R 1 77 77 0 -1 0 0 0 0 0 9 9 0 0 20 0 1 0 0 1 1 1
        """

    @Test func linuxIsReadFromTwoProcSamples() throws {
        let snapshot = try CPUUsageCommand.snapshot(host: "pi", output: Self.linux)
        #expect(snapshot.platform == .linux && snapshot.coreCount == 2)
        #expect(snapshot.model == "Raspberry Pi 5 Model B Rev 1.0")
        // 400 ticks passed: 150 user, 50 system.
        #expect(snapshot.user == 0.375 && snapshot.system == 0.125)
        #expect(snapshot.cores == [0.9, 0.1])
        #expect(snapshot.loadAverage == [0.07, 0.05, 0.00])
        #expect(snapshot.temperature == 44.65)
        // One core's ticks over the sample: 200.
        #expect(snapshot.processes.map(\.name) == ["Web Content (x)", "systemd"], "a name may hold parentheses; new ones left out")
        #expect(snapshot.processes.map(\.usage) == [0.85, 0.025])
    }

    @Test func theReport() throws {
        let report = CPUUsageCommand.report(try CPUUsageCommand.snapshot(host: "pi", output: Self.linux))
        #expect(report.hasPrefix("pi\nRaspberry Pi 5 Model B Rev 1.0 · 2 cores\nBusy"))
        let lines = report.split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.hasPrefix("  User") && $0.hasSuffix("38 %") })
        #expect(lines.contains { $0.hasPrefix("Load average") && $0.hasSuffix("0.07  0.05  0.00  1, 5, 15 min") })
        #expect(lines.contains { $0.hasPrefix("Temperature") && $0.hasSuffix("44.6 °C") || $0.hasSuffix("44.7 °C") })
        #expect(Array(lines.suffix(4)) == ["Busiest processes", "PID   CPU  Name", " 42  85 %  Web Content (x)", "  1   3 %  systemd"])
    }

    @Test func unknownSystemsAreRefused() async throws {
        let command = CPUUsageCommand { machine, _ in machine == .ssh("raspberrypi") ? "@@ system\nSunOS\n" : "" }
        #expect(command.runsOnHosts && command.argument == nil)
        let context = ActionContext(
            fallbackOutputDirectory: URL(filePath: "/tmp"), temporaryDirectory: URL(filePath: "/tmp"), machine: .ssh("raspberrypi"))
        await #expect(throws: QuickActionError("raspberrypi runs SunOS; only macOS and Linux hosts are read over SSH")) {
            try await command.output(.none, context: context)
        }
        #expect(throws: QuickActionError("pi gave no CPU statistics")) {
            try CPUUsageCommand.snapshot(host: "pi", output: "@@ system\nLinux\n")
        }
    }

    @Test func theMachineRunsTheScript() async throws {
        let linux = "@@ system\nLinux\n@@ model\nmodel name\t: ARM\n@@ load\n0.07 0.05 0.00 1/100 5\n@@ stat1\ncpu  100 0 100 800\n"
            + "@@ procs1\n@@ stat2\ncpu  200 0 100 900\n@@ procs2\n"
        let command = CPUUsageCommand { machine, script in
            guard machine == .ssh("pi"), script == CPUUsageCommand.script else { throw QuickActionError("wrong call") }
            return linux
        }
        let output = try await command.output(.none, context: ActionContext(
            fallbackOutputDirectory: URL(filePath: "/tmp"), temporaryDirectory: URL(filePath: "/tmp"), machine: .ssh("pi")))
        guard case .report(let report) = output, let snapshot = report.content as? CPUSnapshot else { throw QuickActionError("no snapshot") }
        #expect(snapshot.host == "pi" && snapshot.platform == .linux)
    }

    @Test func itRunsOnThisMac() async throws {
        let command = CPUUsageCommand()
        #expect(command.accepts(.none) && command.usage == "cpu")
        guard case .value(.report(let report), let refresh) = try await command.resolve(.none) else { throw QuickActionError("no value") }
        #expect(refresh == .seconds(2))
        guard let snapshot = report.content as? CPUSnapshot else {
            throw QuickActionError("no snapshot")
        }
        #expect(snapshot.host == nil && snapshot.platform == .mac)
        #expect(snapshot.coreCount == ProcessInfo.processInfo.activeProcessorCount)
        #expect(snapshot.cores.count == snapshot.coreCount, "from the Mach host")
        #expect(snapshot.cores.allSatisfy { (0...1).contains($0) })
        #expect(snapshot.loadAverage.count == 3)
        #expect(report.text.contains("Busy"))
    }
}

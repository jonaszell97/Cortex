import Foundation
import Testing
@testable import CortexCore

/// `$gpu`: reading `ioreg` on a Mac, `nvidia-smi` and `amdgpu` on Linux,
/// and the report. The Mac's real numbers are not asserted.
@Suite struct GPUUsageTests {
    static func ioreg(windowServer: UInt64, wallpaper: UInt64, utilization: Int) -> String {
        """
        +-o AGXAcceleratorG16X  <class AGXAcceleratorG16X, id 0x10000059d, registered, matched, active, busy 0 (32154 ms), retain 47>
            {
              "model" = "Apple M4 Pro"
              "gpu-core-count" = 20
              "PerformanceStatistics" = {"Alloc system memory"=26676953088,"Tiler Utilization %"=17,"Renderer Utilization %"=24,"Device Utilization %"=\(utilization),"In use system memory"=18962038784}
            }
          +-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x100000f62, !registered, !matched, active, busy 0, retain 5>
          |   {
          |     "AppUsage" = ()
          |     "IOUserClientCreator" = "pid 178, WindowServer"
          |   }
          +-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x100000f64, !registered, !matched, active, busy 0, retain 5>
          |   {
          |     "AppUsage" = ({"API"="Metal","lastSubmittedTime"=1,"accumulatedGPUTime"=\(windowServer)},{"API"="Metal","lastSubmittedTime"=2,"accumulatedGPUTime"=1000})
          |     "IOUserClientCreator" = "pid 178, WindowServer"
          |   }
          +-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x100000f70, !registered, !matched, active, busy 0, retain 5>
          |   {
          |     "IOUserClientCreator" = "pid 13165, Wallpaper (Sequoia)"
          |     "AppUsage" = ({"API"="Metal","lastSubmittedTime"=3,"accumulatedGPUTime"=\(wallpaper)})
          |   }
          +-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x100000f71, !registered, !matched, active, busy 0, retain 5>
              {
                "IOUserClientCreator" = "pid 400, idle"
                "AppUsage" = ({"API"="Metal","lastSubmittedTime"=3,"accumulatedGPUTime"=7})
              }
        """
    }

    @Test func aMacIsReadFromTwoIORegSamples() throws {
        let output = "@@ system\nDarwin\n@@ ioreg1\n" + Self.ioreg(windowServer: 5_000_000_000, wallpaper: 100, utilization: 10)
            + "\n@@ ioreg2\n" + Self.ioreg(windowServer: 5_110_000_000, wallpaper: 300_000_100, utilization: 28)
        let snapshot = try GPUUsageCommand.snapshot(host: "studio", output: output)
        #expect(snapshot.host == "studio" && snapshot.platform == .mac)
        #expect(snapshot.devices == [GPUDevice(
            name: "Apple M4 Pro", coreCount: 20, utilization: 0.28, renderer: 0.24, tiler: 0.17, memoryUsed: 18_962_038_784,
            memoryTotal: nil, temperature: nil, power: nil)], "as the second sample has it")
        #expect(snapshot.processes == [
            ProcessGPU(pid: 13165, name: "Wallpaper (Sequoia)", usage: 0.3, memory: nil),
            ProcessGPU(pid: 178, name: "WindowServer", usage: 0.11, memory: nil),
        ], "nanoseconds over a second, every client of a process together; idle ones left out")
    }

    @Test func nvidiaAndAMDCardsAreReadOnLinux() throws {
        let output = """
            @@ system
            Linux
            @@ nvidia
            NVIDIA GeForce RTX 4090, 45, 1234, 24564, 61, 120.50
            Tesla T4, 0, 0, 15360, [N/A], [N/A]
            @@ nvidia-apps
            4242, /usr/bin/python3, 1200
            77, ollama, 3000
            @@ amd /sys/class/drm/card1/device
            busy 12
            used 1073741824
            total 17163091968
            temperature 52000
            power 35000000
            name 
            """
        let snapshot = try GPUUsageCommand.snapshot(host: "box", output: output)
        #expect(snapshot.devices.map(\.name) == ["NVIDIA GeForce RTX 4090", "Tesla T4", "AMD GPU (card1)"])
        #expect(snapshot.devices[0] == GPUDevice(
            name: "NVIDIA GeForce RTX 4090", coreCount: nil, utilization: 0.45, renderer: nil, tiler: nil,
            memoryUsed: 1234 * 1024 * 1024, memoryTotal: 24564 * 1024 * 1024, temperature: 61, power: 120.5))
        #expect(snapshot.devices[1].temperature == nil && snapshot.devices[1].power == nil, "[N/A]")
        #expect(snapshot.devices[2] == GPUDevice(
            name: "AMD GPU (card1)", coreCount: nil, utilization: 0.12, renderer: nil, tiler: nil,
            memoryUsed: 1_073_741_824, memoryTotal: 17_163_091_968, temperature: 52, power: 35))
        #expect(snapshot.processes == [
            ProcessGPU(pid: 77, name: "ollama", usage: nil, memory: 3000 * 1024 * 1024),
            ProcessGPU(pid: 4242, name: "python3", usage: nil, memory: 1200 * 1024 * 1024),
        ], "by the memory they hold")

        let report = GPUUsageCommand.report(snapshot)
        #expect(report.hasPrefix("box\nNVIDIA GeForce RTX 4090\nBusy"))
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.contains { $0.hasPrefix("Power") && $0.hasSuffix(" 120 W") })
        #expect(lines.contains { $0.hasPrefix("Memory in use") && $0.hasSuffix("of 15 GB") }, "the Tesla's total")
        #expect(report.contains("\n\nTesla T4\n") && report.contains("\n\nAMD GPU (card1)\n"), "a blank line between GPUs")
        #expect(report.contains("\n\nGPU memory by process\n PID   Memory  Name\n  77  "))
    }

    @Test func aHostWithoutAReadableGPUSaysSo() async throws {
        let command = GPUUsageCommand { _, _ in "@@ system\nLinux\n@@ nvidia\n@@ nvidia-apps\n" }
        #expect(command.runsOnHosts && command.argument == nil)
        let context = ActionContext(
            fallbackOutputDirectory: URL(filePath: "/tmp"), temporaryDirectory: URL(filePath: "/tmp"), machine: .ssh("raspberrypi"))
        await #expect(throws: QuickActionError(
            "raspberrypi has no GPU Cortex can read: it reads NVIDIA cards with nvidia-smi and AMD cards with amdgpu")) {
            try await command.output(.none, context: context)
        }
    }

    @Test func itRunsOnThisMac() async throws {
        let command = GPUUsageCommand()
        #expect(command.accepts(.none) && command.usage == "gpu")
        guard case .value(.report(let report), let refresh) = try await command.resolve(.none) else { throw QuickActionError("no value") }
        #expect(refresh == .seconds(2))
        guard let snapshot = report.content as? GPUSnapshot else {
            throw QuickActionError("no snapshot")
        }
        #expect(snapshot.host == nil && !snapshot.devices.isEmpty)
        #expect(snapshot.devices.allSatisfy { (0...1).contains($0.utilization) })
        #expect(report.text.contains("Busy"))
    }
}

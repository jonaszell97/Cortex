import Foundation
import Testing
@testable import CortexCore

/// `$disk`: picking a volume and the table it shows.
@Suite struct DiskSpaceTests {
    static let gb: Int64 = 1_000_000_000
    let startup = VolumeSpace(
        name: "Macintosh HD", path: "/", fileSystem: "APFS", total: 1_000 * gb, available: 400 * gb,
        availableForImportantUsage: 450 * gb)
    let backup = VolumeSpace(name: "Backup", path: "/Volumes/Backup", fileSystem: "ExFAT", total: 2_000 * gb, available: 1_500 * gb)
    var command: DiskSpaceCommand {
        let volumes = [startup, backup]
        return DiskSpaceCommand(volumes: { volumes }, shell: Self.fakeHost)
    }

    /// `df -kP` and `findmnt` as a Raspberry Pi answers; "linode" is down.
    @Sendable static func fakeHost(_ machine: Machine, script: String) async throws -> String {
        guard machine == .ssh("raspberrypi") else {
            throw QuickActionError("\(machine.title): ssh: connect to host linode port 22: Operation timed out")
        }
        if script.contains("'/mnt/usb'") {
            return """
                Filesystem     1024-blocks      Used Available Capacity Mounted on
                /dev/sda1        976762584 488381292 488381292      50% /mnt/usb
                ---
                exfat
                """
        }
        return """
            Filesystem     1024-blocks    Used Available Capacity Mounted on
            /dev/mmcblk0p2    60948972 7782664  50050288      14% /
            ---
            ext4
            """
    }

    private func context(on machine: Machine = .local) -> ActionContext {
        ActionContext(fallbackOutputDirectory: URL(filePath: "/tmp"), temporaryDirectory: URL(filePath: "/tmp"), machine: machine)
    }

    private static func gigabytes(_ bytes: Int64) -> String { "\(bytes / gb) GB" }

    @Test func itsArgumentIsAChoiceOfTheVolumesAndAPathOnAHost() async throws {
        #expect(command.name == "disk" && command.runsOnHosts)
        #expect(command.usage == "disk Macintosh HD")
        let argument = try #require(command.argument)
        #expect(!argument.isRequired)
        #expect(argument.suggestions == .choices)
        guard case .choice(let choices) = argument.kind else { throw QuickActionError("not a choice") }
        #expect(await choices.load() == [
            ActionOption.Choice("/", title: "Macintosh HD"), ActionOption.Choice("/Volumes/Backup", title: "Backup"),
        ], "the mounted volumes only")
        #expect(command.accepts(.none), "the startup volume")
        #expect(command.argument(on: .local) == argument)
        let onHost = try #require(command.argument(on: .ssh("raspberrypi")))
        #expect(onHost.kind == .text && !onHost.isRequired && onHost.placeholder == "/mnt/usb", "not checked against the volumes")
    }

    @Test func theStartupVolumeComesFirst() {
        let other = VolumeSpace(name: "Archive", path: "/Volumes/Archive", total: 1, available: 1)
        #expect(DiskSpaceCommand.sorted([backup, startup, other]).map(\.name) == ["Macintosh HD", "Archive", "Backup"])
    }

    @Test func theTable() {
        #expect(DiskSpaceCommand.table(for: startup, bytes: Self.gigabytes) == """
            Macintosh HD · APFS
            Total      1000 GB
            Used        600 GB  60 %
            Free        400 GB
            Purgeable    50 GB  freed when space is needed
            """)
        #expect(DiskSpaceCommand.table(for: backup, bytes: Self.gigabytes) == """
            Backup · ExFAT
            Total  2000 GB
            Used    500 GB  25 %
            Free   1500 GB
            """, "no purgeable line without purgeable space")
    }

    @Test func typedNamesAndMountPointsPickTheVolume() async throws {
        let byName = try await command.output(.text("backup"), context: context())
        #expect(byName.text?.hasPrefix("Backup · ExFAT\n") == true)
        guard case .report(let report) = byName else { throw QuickActionError("no report") }
        #expect((report.content as? VolumeSpace)?.path == "/Volumes/Backup", "the pane draws the volume")
        let byPath = try await command.output(.text("/"), context: context())
        #expect(byPath.text?.hasPrefix("Macintosh HD") == true)
        let startup = try await command.output(.none, context: context())
        #expect(startup.text?.hasPrefix("Macintosh HD") == true, "nothing typed: the startup volume")
        await #expect(throws: QuickActionError("“Floppy” is not a mounted volume. Mounted: Macintosh HD, Backup")) {
            try await command.output(.text("Floppy"), context: context())
        }
        await #expect(throws: QuickActionError("“raspberrypi” is not a mounted volume. Mounted: Macintosh HD, Backup"),
                      "a bare word is a volume, not a host") {
            try await command.output(.text("raspberrypi"), context: context())
        }
    }

    @Test func itIsAValueThatIsNotRefreshed() async throws {
        guard case .value(.report(let report), let refresh) = try await command.resolve(.none) else { throw QuickActionError("no value") }
        #expect(report.text.hasPrefix("Macintosh HD") && refresh == nil, "sizes change slowly")
    }

    @Test func aHostIsReadOverSSH() async throws {
        let output = try await command.output(.none, context: context(on: .ssh("raspberrypi")))
        guard case .report(let report) = output, let volume = report.content as? VolumeSpace else {
            throw QuickActionError("no report")
        }
        #expect(volume == VolumeSpace(
            name: "raspberrypi", host: "raspberrypi", path: "/", fileSystem: "ext4", total: 60_948_972 * 1024,
            available: 50_050_288 * 1024))
        #expect(report.text.hasPrefix("raspberrypi · ext4\nTotal"))

        let usb = try await command.output(.text("/mnt/usb"), context: context(on: .ssh("raspberrypi")))
        guard case .report(let usbReport) = usb, let usbVolume = usbReport.content as? VolumeSpace else {
            throw QuickActionError("no report")
        }
        #expect(usbVolume.name == "raspberrypi:/mnt/usb" && usbVolume.path == "/mnt/usb" && usbVolume.fileSystem == "exfat")

        await #expect(throws: QuickActionError("“usb” is not an absolute path on raspberrypi: start it with /, like /mnt/usb")) {
            try await command.output(.text("usb"), context: context(on: .ssh("raspberrypi")))
        }
        await #expect(throws: QuickActionError("linode: ssh: connect to host linode port 22: Operation timed out")) {
            try await command.output(.none, context: context(on: .ssh("linode")))
        }
    }

    @Test func theRemoteScriptQuotesThePath() {
        #expect(DiskSpaceCommand.remoteScript(path: "/it's") == #"df -kP -- '/it'\''s' && echo --- && (findmnt -no FSTYPE -T '/it'\''s' 2>/dev/null"#
            + #" || diskutil info '/it'\''s' 2>/dev/null | sed -n 's/^ *File System Personality: *//p')"#)
        #expect(throws: QuickActionError("pi: df gave no sizes")) { try DiskSpaceCommand.volume(host: "pi", df: "df: /x: No such file") }
    }

    @Test func thisMacHasAStartupVolume() {
        let volumes = DiskSpaceCommand.mountedVolumes()
        #expect(volumes.first?.path == "/")
        #expect(volumes.allSatisfy { $0.total > 0 && $0.available <= $0.total })
    }
}

import SwiftUI
import CortexCore

/// The devices that sync (plans/IOS.md, M6): this iPhone first, then the
/// Macs, each with when it last synced, its version and whether it needs an
/// update; swipe to forget one that is gone.
struct DevicesView: View {
    @Environment(MobileSyncService.self) private var sync
    @State private var forgetting: SyncDevice?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    DeviceDetailView(deviceID: thisDevice?.id)
                } label: {
                    thisPhoneRow
                }
            }
            Section {
                ForEach(others) { device in
                    NavigationLink {
                        DeviceDetailView(deviceID: device.id)
                    } label: {
                        DeviceRow(device: device, isBehind: device.isBehind(among: sync.devices))
                    }
                    .swipeActions {
                        Button("Forget", role: .destructive) { forgetting = device }
                    }
                }
            } header: {
                Text("Other Devices")
            } footer: {
                if others.isEmpty {
                    Text("The Macs show up here after their next sync with a version of Cortex that reports them.")
                } else if let line = sync.footerLine {
                    Text(line)
                }
            }
        }
        .navigationTitle("Devices")
        .refreshable { await sync.syncNow() }
        .confirmationDialog(
            "Forget \(forgetting?.name ?? "")?",
            isPresented: Binding { forgetting != nil } set: { if !$0 { forgetting = nil } },
            titleVisibility: .visible,
            presenting: forgetting
        ) { device in
            Button("Forget", role: .destructive) { sync.forgetDevice(device) }
        } message: { _ in
            Text("It disappears from the list on every device. If it syncs again, it comes back.")
        }
    }

    private var thisDevice: SyncDevice? { sync.devices.first(where: \.isThisDevice) }
    private var others: [SyncDevice] { sync.devices.filter { !$0.isThisDevice } }

    /// Before this iPhone's first report there is no record: the name and
    /// the status are enough.
    private var thisPhoneRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(sync.deviceName)
                Text("This iPhone · \(sync.footerLine ?? sync.statusLine)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let thisDevice, thisDevice.isBehind(among: sync.devices) {
                    Label(thisDevice.updateHint, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

private struct DeviceRow: View {
    let device: SyncDevice
    let isBehind: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.symbol)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(device.activityLine(now: context.date))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                Text("Cortex \(device.appVersion) (\(device.appBuild)) · \(device.platform) \(device.osVersion)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if isBehind {
                    Label(device.updateHint, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if device.unsent > 0 {
                    Label(device.unsent == 1 ? "1 change not sent" : "\(device.unsent) changes not sent",
                          systemImage: "arrow.up.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var isActive: Bool { device.activity() == .active }
}

/// Everything a device reported. Looked up by ID, so it follows new
/// reports while open and closes nothing when the device is forgotten.
struct DeviceDetailView: View {
    @Environment(MobileSyncService.self) private var sync
    let deviceID: String?

    var body: some View {
        Form {
            if let device {
                Section {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        LabeledContent("Status", value: device.isThisDevice
                            ? sync.footerLine ?? sync.statusLine
                            : device.activityLine(now: context.date))
                    }
                    LabeledContent("Last report", value: device.reportedAt.formatted(date: .abbreviated, time: .shortened))
                    if device.isBehind(among: sync.devices) {
                        Label(device.updateHint, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if device.unsent > 0 {
                        LabeledContent("Not sent", value: "\(device.unsent)")
                    }
                    if let failure = device.lastFailure {
                        LabeledContent("Last failure") {
                            Text("\(failure.message)\n\(failure.at.formatted(date: .abbreviated, time: .shortened))")
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                Section("Version") {
                    LabeledContent("Cortex", value: "\(device.appVersion) (\(device.appBuild))")
                    if let builtAt = device.builtAt {
                        LabeledContent("Built", value: builtAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent(device.platform, value: device.osVersion)
                    LabeledContent("Syncs", value: syncedCollections(device))
                }
                if device.isMac {
                    Section("Mac") {
                        if let uptime = device.uptimeLine() { LabeledContent("Uptime", value: uptime) }
                        if let disk = device.diskLine { LabeledContent("Disk", value: disk) }
                        if let battery = device.batteryLine { LabeledContent("Battery", value: battery) }
                        if let host = device.hostName { LabeledContent("Host", value: host) }
                        if let user = device.userName { LabeledContent("User", value: user) }
                    }
                }
            } else {
                Section {
                    Text("This iPhone reports itself with its next sync.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(device?.name ?? sync.deviceName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await sync.syncNow() }
    }

    private var device: SyncDevice? {
        sync.devices.first { $0.id == deviceID } ?? (deviceID == nil ? sync.devices.first(where: \.isThisDevice) : nil)
    }

    private func syncedCollections(_ device: SyncDevice) -> String {
        let names: [SyncCollection: String] = [
            .clip: "Clips", .snippet: "Snippets", .action: "Actions", .reading: "Reading list",
            .knowledge: "Knowledge", .device: "Devices",
        ]
        return device.collections.keys.compactMap { names[$0] }.sorted().joined(separator: ", ")
    }
}

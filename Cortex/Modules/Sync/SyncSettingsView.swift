import SwiftUI
import CortexCore

/// Settings → Sync (docs/SYNC.md, "The UI and status messages"): set up the first
/// Mac or join with a pairing code, what to sync, the status, and the maintenance
/// buttons.
struct SyncSettingsView: View {
    let sync: SyncService
    /// For the contributions' options.
    let secrets: ModuleSecrets

    private enum SetupMode: String, CaseIterable, Identifiable {
        case first = "Set up this Mac"
        case join = "Join with pairing code"

        var id: Self { self }
    }

    @State private var mode = SetupMode.first
    @State private var serverURL = ""
    @State private var token = ""
    @State private var pairingCode = ""
    @State private var isBusy = false
    @State private var message: Message?
    @State private var confirmingDisconnect = false
    @State private var pairingQRCode: NSImage?
    @State private var forgetting: SyncDevice?

    private struct Message {
        var text: String
        var isError: Bool
    }

    var body: some View {
        Group {
            if sync.isConfigured {
                configured
            } else {
                setup
            }
        }
        .sheet(isPresented: Binding(get: { pairingQRCode != nil }, set: { if !$0 { pairingQRCode = nil } })) {
            if let pairingQRCode { PairingCodeSheet(image: pairingQRCode) { self.pairingQRCode = nil } }
        }
        .confirmationDialog("Disconnect from the sync server?", isPresented: $confirmingDisconnect) {
            Button("Disconnect", role: .destructive) {
                sync.disconnect()
                message = nil
            }
        } message: {
            Text("The sync key and token are removed from this Mac's Keychain. Your clips, snippets and actions stay as they are. The other Mac keeps its own copy.")
        }
        .confirmationDialog(
            "Forget \(forgetting?.name ?? "")?",
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            presenting: forgetting
        ) { device in
            Button("Forget", role: .destructive) { sync.forgetDevice(device) }
        } message: { _ in
            Text("It disappears from the list on every device. If it syncs again, it comes back.")
        }
    }

    // MARK: Not set up

    @ViewBuilder
    private var setup: some View {
        Section("Sync") {
            Text("Copies clips, snippets and your own quick actions between two Macs through a server on your Tailnet. Everything is encrypted on the Mac with a key only your Macs have; the server holds ciphertext. Switch Sync on above, then set it up.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $mode) {
                ForEach(SetupMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .first:
                TextField("Server", text: $serverURL, prompt: Text("https://cortex-sync.example.dev"))
                    .onSubmit(setUp)
                SecureField("Token", text: $token)
                    .onSubmit(setUp)
                // Never greyed out for empty fields: the click says what is missing.
                HStack {
                    Button("Test Connection") { testConnection() }
                    Spacer()
                    Button("Set Up") { setUp() }
                        .keyboardShortcut(.defaultAction)
                }
                .disabled(isBusy)
                Text("Creates the sync key on this Mac and uploads what it has. Then copy the pairing code to join from the other Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .join:
                SecureField("Pairing code", text: $pairingCode, prompt: Text("cxsync1:…"))
                    .onSubmit(join)
                HStack {
                    Spacer()
                    Button("Join") { join() }
                        .keyboardShortcut(.defaultAction)
                }
                .disabled(isBusy)
                Text("On the other Mac: Settings → Sync → Copy Pairing Code. Send it over AirDrop or Universal Clipboard, never through a chat or mail service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            messageRow
        }
    }

    // MARK: Set up

    @ViewBuilder
    private var configured: some View {
        let settings = sync.settings

        Section("Sync") {
            LabeledContent("Server") {
                Text(settings.serverURL?.absoluteString ?? "")
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            LabeledContent("Status") {
                HStack {
                    Text(sync.status.settingsLine(lastSuccess: sync.lastSuccess))
                        .foregroundStyle(isFailed ? Color.red : Color.secondary)
                        .multilineTextAlignment(.trailing)
                    Button("Sync Now") { sync.syncNow() }
                        .disabled(!sync.isActive || sync.status == .syncing)
                }
            }
        }

        if !sync.devices.isEmpty {
            Section("Devices") {
                ForEach(sync.devices) { device in
                    DeviceRow(device: device, devices: sync.devices, thisDeviceLine: thisMacLine) {
                        forgetting = device
                    }
                }
            }
        }

        Section("What to sync") {
            // One switch per collection of the modules that are on, each
            // with its module's options below it.
            ForEach(sync.contributions) { contribution in
                let isOn = Binding(
                    get: { settings.isSyncing(contribution.toggleKey) },
                    set: { settings.setSyncing(contribution.toggleKey, $0) })
                Toggle(contribution.title, isOn: isOn)
                ModuleOptionsForm(options: contribution.options, secrets: secrets)
                    .disabled(!isOn.wrappedValue)
            }
            if sync.contributions.isEmpty {
                Text("Nothing to sync: the modules whose data syncs are switched off.")
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            HStack {
                Button("Copy Pairing Code") {
                    message = sync.copyPairingCode()
                        ? Message(text: "Copied. It holds the sync key: send it over AirDrop or Universal Clipboard only.", isError: false)
                        : Message(text: "The sync key isn't available.", isError: true)
                }
                Button("Show Pairing Code…") {
                    pairingQRCode = sync.pairingQRCode()
                    if pairingQRCode == nil { message = Message(text: "The sync key isn't available.", isError: true) }
                }
                Button("Upload Everything Again") { sync.uploadEverythingAgain() }
                    .disabled(!sync.isActive)
                Spacer()
                Button("Disconnect…", role: .destructive) { confirmingDisconnect = true }
            }
            messageRow
        }
    }

    /// This Mac's own report lags behind its status.
    private var thisMacLine: String {
        sync.status.menuLine(lastSuccess: sync.lastSuccess) ?? "Sync is off"
    }

    private var isFailed: Bool {
        if case .failed = sync.status { return true }
        return false
    }

    @ViewBuilder
    private var messageRow: some View {
        if let message {
            Text(message.text)
                .font(.caption)
                .foregroundStyle(message.isError ? Color.red : Color.secondary)
        }
    }

    // MARK: Actions

    private func testConnection() {
        guard !isBusy else { return }
        isBusy = true
        message = Message(text: "Connecting…", isError: false)
        Task {
            switch await sync.testConnection(serverURL: serverURL, token: token) {
            case .success(let text): message = Message(text: text, isError: false)
            case .failure(let error): message = Message(text: error.message, isError: true)
            }
            isBusy = false
        }
    }

    private func setUp() {
        guard !isBusy else { return }
        isBusy = true
        message = Message(text: "Setting up…", isError: false)
        Task {
            do {
                try await sync.setUp(serverURL: serverURL, token: token)
                token = ""
                message = nil
            } catch {
                message = Message(text: SyncSetup.message(for: error), isError: true)
            }
            isBusy = false
        }
    }

    private func join() {
        guard !isBusy else { return }
        isBusy = true
        message = Message(text: "Joining…", isError: false)
        Task {
            do {
                try await sync.join(pairingCode: pairingCode)
                pairingCode = ""
                message = nil
            } catch {
                message = Message(text: SyncSetup.message(for: error), isError: true)
            }
            isBusy = false
        }
    }
}

/// A device that syncs (plans/IOS.md, M6): what it is, when it last synced,
/// its version, and whether it needs an update.
private struct DeviceRow: View {
    let device: SyncDevice
    let devices: [SyncDevice]
    let thisDeviceLine: String
    let forget: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: device.symbol)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.isThisDevice ? "\(device.name) (this Mac)" : device.name)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(device.isThisDevice ? thisDeviceLine : device.activityLine(now: context.date))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(device.versionLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if device.isBehind(among: devices) {
                    Label(device.updateHint, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if device.unsent > 0 {
                    Text(device.unsent == 1 ? "1 change not sent" : "\(device.unsent) changes not sent")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if !device.isThisDevice {
                Button("Forget…", action: forget)
            }
        }
    }
}

/// The pairing code as a QR code, for Cortex on the iPhone. It holds the sync
/// key, so it is shown only while this sheet is open.
private struct PairingCodeSheet: View {
    let image: NSImage
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Pairing Code")
                .font(.headline)
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 260, height: 260)
            Text("In Cortex on your iPhone, choose Scan Pairing Code. The code holds the sync key: show it with nobody looking.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 300)
            Button("Done", action: done)
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }
}

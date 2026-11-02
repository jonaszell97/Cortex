import EventKit
import SwiftUI
import CortexCore

/// The server, the sync status, the reading list's and the actions'
/// preferences, Spotlight, what is on this phone, and Disconnect.
struct SettingsView: View {
    @Environment(MobileSyncService.self) private var sync
    @Environment(KnowledgeStore.self) private var knowledge
    @Environment(ReadingListModel.self) private var readingList
    @Environment(ItemActions.self) private var actions
    @Environment(SpotlightIndexer.self) private var spotlight
    @State private var confirmingDisconnect = false

    var body: some View {
        Form {
            Section("Sync") {
                LabeledContent("Server") {
                    Text(sync.serverURL?.host() ?? "")
                        .textSelection(.enabled)
                }
                LabeledContent("Status") {
                    Text(sync.statusLine)
                        .foregroundStyle(isFailed ? Color.red : Color.secondary)
                        .multilineTextAlignment(.trailing)
                }
                Button("Sync Now") {
                    Task { await sync.syncNow() }
                }
                .disabled(sync.status == .syncing)
            }

            readingListSection

            actionsSection

            spotlightSection

            thisIPhoneSection

            Section("On this iPhone") {
                LabeledContent("Projects", value: "\(knowledge.projects.count)")
                LabeledContent("Notes, skills and to-dos", value: "\(knowledge.itemCount)")
                LabeledContent("Links", value: "\(readingList.items.count)")
                NavigationLink("Conflict Copies") { ConflictCopiesView() }
            }

            Section {
                Button("Disconnect…", role: .destructive) { confirmingDisconnect = true }
            } footer: {
                Text("Version \(Self.version)")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Disconnect from the sync server?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { sync.disconnect() }
        } message: {
            Text("The sync key and token are removed from this iPhone. The notes on it stay until you delete the app; your Macs keep theirs.")
        }
    }

    /// Choices for "Delete read links"; 0 keeps them.
    private static let deleteReadChoices = [0, 1, 7, 30, 90, 365]

    private var readingListSection: some View {
        @Bindable var settings = readingList.settings
        return Section {
            Picker("Open Links", selection: $settings.openLinks) {
                Text("In Default Browser").tag(ReadingListSettings.OpenLinks.browser)
                Text("In Cortex").tag(ReadingListSettings.OpenLinks.inApp)
            }
            Toggle("Safari's Reading List Marks Read", isOn: $settings.safariMarksRead)
            Picker("Delete Read Links", selection: $settings.deleteReadAfterDays) {
                ForEach(Self.deleteReadChoices, id: \.self) { days in
                    switch days {
                    case 0: Text("Never").tag(days)
                    case 1: Text("After 1 Day").tag(days)
                    default: Text("After \(days) Days").tag(days)
                    }
                }
            }
            .onChange(of: settings.deleteReadAfterDays) {
                Task { await readingList.purge() }
            }
        } header: {
            Text("Reading List")
        } footer: {
            Text("In Cortex, links open in Reader when the page has one. Read links are deleted on this iPhone only; your Macs keep theirs until their own setting deletes them.")
        }
    }

    private var actionsSection: some View {
        @Bindable var settings = actions.settings
        return Section {
            NavigationLink {
                RemindersListPicker(selection: settings.remindersList) { settings.remindersList = $0 }
            } label: {
                LabeledContent("Reminders List", value: remindersListName ?? "Asked the first time")
            }
            LabeledContent("Notes Shortcut") {
                TextField("Share sheet", text: $settings.notesShortcut)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("Add to Notes opens the share sheet. To add a note in one tap, make a shortcut in Shortcuts with Notes' *Create Note* action and *Shortcut Input* as its text, and enter its name here.")
        }
    }

    private var thisIPhoneSection: some View {
        @Bindable var sync = sync
        return Section {
            LabeledContent("Name") {
                TextField("Name", text: $sync.deviceName, prompt: Text(MobileSyncService.defaultDeviceName))
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
            }
        } header: {
            Text("This iPhone")
        } footer: {
            Text("What your Macs call this iPhone in their list of devices.")
        }
    }

        private var spotlightSection: some View {
        @Bindable var spotlight = spotlight
        return Section {
            Toggle("Show in Spotlight", isOn: $spotlight.isEnabled)
        } footer: {
            Text("Notes and to-dos can be found in Spotlight and open in Cortex. The index stays on this iPhone; turning this off removes it.")
        }
    }

    private var remindersListName: String? {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return nil }
        return actions.reminders.list(withID: actions.settings.remindersList)?.title
    }

    private var isFailed: Bool {
        if case .failed = sync.status { return true }
        return false
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

import EventKit
import EventKitUI
import SwiftUI
import CortexCore

/// The actions for an item, for a menu: Reminders, Calendar (a to-do with
/// a due day), Notes, then copying and sharing.
struct ItemActionsMenu: View {
    let item: KnowledgeItem
    @Environment(ItemActions.self) private var actions
    @Environment(KnowledgeStore.self) private var knowledge
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Button("Add to Reminders", systemImage: "checklist.unchecked") { actions.addToReminders(item) }
            if item.kind == .todo, item.due != nil {
                Button("Add to Calendar", systemImage: "calendar.badge.plus") { actions.addToCalendar(item) }
            }
            if let url = actions.notesShortcutURL(for: item) {
                Button("Add to Notes", systemImage: "note.text.badge.plus") { openURL(url) }
            } else {
                ShareLink(item: item.notesText) { Label("Add to Notes…", systemImage: "note.text.badge.plus") }
            }
        }
        Section {
            Menu("Copy", systemImage: "doc.on.doc") {
                Button("Copy as Markdown", systemImage: "number") { actions.copy(item, as: .markdown) }
                Button("Copy Text", systemImage: "text.alignleft") { actions.copy(item, as: .text) }
                Button("Copy Link", systemImage: "link") { actions.copy(item, as: .link) }
            }
            Menu("Share", systemImage: "square.and.arrow.up") {
                ShareLink(item: item.markdown, subject: Text(item.title)) { Label("Share Text…", systemImage: "text.quote") }
                ShareLink(item: knowledge.folder.url(for: item.path)) { Label("Share File…", systemImage: "doc") }
            }
        }
    }
}

extension View {
    /// A list row's long press: the item's actions.
    func itemActions(_ item: KnowledgeItem) -> some View {
        contextMenu { ItemActionsMenu(item: item) }
    }

    /// On `RootView`: what the actions ask and show, over every tab.
    func itemActionsPresentation() -> some View {
        modifier(ItemActionsPresentation())
    }
}

private struct ItemActionsPresentation: ViewModifier {
    @Environment(ItemActions.self) private var actions
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        @Bindable var actions = actions
        content
            .confirmationDialog(
                "Add “\(actions.askingPerItem?.title ?? "")” to Reminders",
                isPresented: Binding { actions.askingPerItem != nil } set: { if !$0 { actions.askingPerItem = nil } },
                titleVisibility: .visible, presenting: actions.askingPerItem
            ) { item in
                Button("One Reminder") { Task { await actions.addToReminders(item, perItem: false) } }
                Button("One per Item") { Task { await actions.addToReminders(item, perItem: true) } }
            } message: { _ in
                Text("Each open checklist item can be a reminder of its own.")
            }
            .sheet(item: $actions.choosingList) { _ in
                NavigationStack {
                    RemindersListPicker(selection: nil) { actions.chooseList($0) }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { actions.choosingList = nil }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: Binding { actions.event != nil } set: { if !$0 { actions.event = nil } }) {
                if let event = actions.event {
                    EventEditor(event: event, store: actions.reminders.store) { saved in
                        actions.event = nil
                        if saved { actions.show("Added to Calendar") }
                    }
                    .ignoresSafeArea()
                }
            }
            .alert(actions.problem?.title ?? "", isPresented: Binding { actions.problem != nil } set: { if !$0 { actions.problem = nil } }, presenting: actions.problem) { problem in
                if problem.opensSettings {
                    Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                }
                Button("OK", role: .cancel) {}
            } message: { problem in
                Text(problem.message)
            }
            .overlay(alignment: .bottom) {
                if let toast = actions.toast {
                    Text(toast)
                        .font(.callout)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect()
                        .padding(.bottom, 64)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
    }
}

/// The Reminders lists to pick from, after asking for access. Used the
/// first time Add to Reminders runs and in Settings.
struct RemindersListPicker: View {
    /// The list chosen now; nil preselects the default list.
    var selection: String?
    let pick: (String) -> Void
    @Environment(ItemActions.self) private var actions
    @Environment(\.openURL) private var openURL
    @State private var lists: [EKCalendar]?
    @State private var denied = false

    var body: some View {
        List {
            if let lists {
                Section {
                    ForEach(lists, id: \.calendarIdentifier) { list in
                        Button {
                            pick(list.calendarIdentifier)
                        } label: {
                            HStack {
                                Label {
                                    Text(list.title).foregroundStyle(Color.primary)
                                } icon: {
                                    Image(systemName: "circle.fill").foregroundStyle(Color(cgColor: list.cgColor))
                                }
                                Spacer()
                                if list.calendarIdentifier == current {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Reminders added from Cortex go to this list. Adding an item again updates its reminders where they are.")
                }
            }
        }
        .navigationTitle("Reminders List")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if denied {
                ContentUnavailableView {
                    Label("No access to Reminders", systemImage: "checklist.unchecked")
                } description: {
                    Text("Allow Cortex to use Reminders in the Settings app.")
                } actions: {
                    Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                }
            }
        }
        .task {
            denied = !((try? await actions.reminders.requestAccess()) ?? false)
            if !denied { lists = actions.reminders.lists }
        }
    }

    private var current: String? {
        selection ?? actions.reminders.defaultList?.calendarIdentifier
    }
}

/// The system's event editor. Since iOS 17 it runs outside the app and
/// saves without the app having calendar access.
private struct EventEditor: UIViewControllerRepresentable {
    let event: EKEvent
    let store: EKEventStore
    let done: (_ saved: Bool) -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let done: (Bool) -> Void

        init(done: @escaping (Bool) -> Void) {
            self.done = done
        }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            done(action == .saved)
        }
    }
}

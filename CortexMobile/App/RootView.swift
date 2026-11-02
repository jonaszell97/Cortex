import SwiftUI

/// Joining sync first; then the knowledge base, the to-dos, the reading
/// list, the devices that sync and settings. The editor and the item actions' sheets are
/// presented here, over every tab.
struct RootView: View {
    @Environment(MobileSyncService.self) private var sync
    @Environment(ReadingListModel.self) private var readingList
    @Environment(EditorPresenter.self) private var editor
    @Environment(AppNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        if sync.isConfigured {
            TabView(selection: $navigator.tab) {
                Tab("Knowledge", systemImage: "books.vertical", value: .knowledge) {
                    NavigationStack(path: $navigator.knowledgePath) { ProjectsView() }
                }
                Tab("To-Dos", systemImage: "checklist", value: .todos) {
                    NavigationStack { TodosView() }
                }
                Tab("Reading List", systemImage: "eyeglasses", value: .readingList) {
                    NavigationStack { ReadingListView() }
                }
                .badge(readingList.unreadCount)
                Tab("Devices", systemImage: "laptopcomputer.and.iphone", value: .devices) {
                    NavigationStack { DevicesView() }
                }
                Tab("Settings", systemImage: "gear", value: .settings) {
                    NavigationStack { SettingsView() }
                }
            }
            .sheet(isPresented: Binding { editor.draft != nil } set: { if !$0 { editor.close() } }) {
                EditorView()
            }
            .alert("Can't edit it", isPresented: Binding { editor.draft == nil && editor.error != nil } set: {
                if !$0 { editor.error = nil }
            }) {
                Button("OK") {}
            } message: {
                Text(editor.error ?? "")
            }
            .itemActionsPresentation()
        } else {
            JoinView()
        }
    }
}

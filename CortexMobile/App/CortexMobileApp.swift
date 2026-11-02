import CoreSpotlight
import SwiftUI
import CortexCore

/// The iOS companion (plans/IOS.md): a synced copy of the knowledge base and
/// the reading list, readable and editable offline.
@main
struct CortexMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var launch = AppLaunch.open()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            switch launch {
            case .ready(let environment):
                RootView()
                    .environment(environment)
                    .environment(environment.sync)
                    .environment(environment.knowledge)
                    .environment(environment.readingList)
                    .environment(environment.editor)
                    .environment(environment.navigator)
                    .environment(environment.actions)
                    .environment(environment.spotlight)
                    .task { await environment.start() }
                    .onOpenURL { environment.navigator.open($0) }
                    // A Spotlight result: its identifier is the item's path.
                    .onContinueUserActivity(CSSearchableItemActionType) { activity in
                        guard let path = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                        environment.navigator.open(KnowledgeLink.item(path).url)
                    }
                    .onChange(of: scenePhase) { _, phase in environment.scenePhaseChanged(phase) }
            case .failed(let message):
                ContentUnavailableView(
                    "Cortex can't open its data", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .backgroundTask(.appRefresh(AppEnvironment.backgroundRefreshID)) {
            guard case .ready(let environment) = await launch else { return }
            await environment.refreshInBackground()
        }
    }
}

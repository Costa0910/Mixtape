import SwiftUI
import SwiftData

@main
struct SnagPlayerApp: App {
    @StateObject private var player = PlayerEngine.shared
    private let store = SharedStore.container

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .tint(AppTheme.accent)
                .onOpenURL { QuickActions.handle($0) }
        }
        .modelContainer(store)
    }
}

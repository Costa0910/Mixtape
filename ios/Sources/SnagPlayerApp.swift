import SwiftUI
import SwiftData

@main
struct SnagPlayerApp: App {
    @StateObject private var player = PlayerEngine.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .preferredColorScheme(.dark)
                .tint(.indigo)
                .onOpenURL { QuickActions.handle($0) }
        }
        .modelContainer(SharedStore.container)
    }
}

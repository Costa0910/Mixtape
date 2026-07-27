import SwiftUI

@main
struct MixtapeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 760, minHeight: 620)
                .onAppear { state.refreshPhones() }
        }
        .windowResizability(.contentMinSize)
    }
}

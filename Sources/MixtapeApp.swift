import SwiftUI

@main
struct MixtapeApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var state: AppState

    init() {
        let s = SettingsStore()
        _settings = StateObject(wrappedValue: s)
        _state = StateObject(wrappedValue: AppState(settings: s))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(settings)
                .tint(settings.accent.color)
                .frame(minWidth: 900, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1040, height: 720)
    }
}

struct RootView: View {
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        Group {
            if settings.hasOnboarded {
                MainView()
            } else {
                OnboardingView()
            }
        }
        .animation(.smooth, value: settings.hasOnboarded)
    }
}

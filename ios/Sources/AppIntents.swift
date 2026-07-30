import AppIntents
import SwiftData

// One SwiftData container shared by the app (and, later, the widget) so intents can
// read the library. Uses the default on-disk store, so it's the same data the UI sees.
enum SharedStore {
    static let container: ModelContainer = {
        do { return try ModelContainer(for: Track.self, Playlist.self) }
        catch { fatalError("Failed to open store: \(error)") }
    }()
}

// MARK: - Shared quick actions (used by intents and by snag:// deep links)

@MainActor
enum QuickActions {
    private static var library: [Track] {
        (try? SharedStore.container.mainContext.fetch(FetchDescriptor<Track>())) ?? []
    }

    static func smartMix() {
        let tracks = library
        guard !tracks.isEmpty else { return }
        PlayerEngine.shared.playSmart(tracks)
    }

    static func shuffle() {
        let tracks = library
        guard !tracks.isEmpty else { return }
        PlayerEngine.shared.shuffle = true
        PlayerEngine.shared.play(tracks, startAt: Int.random(in: 0..<tracks.count))
    }

    /// Handle a `snag://smartmix` / `snag://shuffle` deep link (from a widget or Shortcut).
    static func handle(_ url: URL) {
        switch url.host {
        case "smartmix": smartMix()
        case "shuffle":  shuffle()
        default: break
        }
    }
}

// MARK: - Intents

struct PlaySmartMixIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Smart Mix"
    static var description = IntentDescription("Play a mix tuned to what you love.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActions.smartMix()
        return .result()
    }
}

struct ShuffleLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "Shuffle Library"
    static var description = IntentDescription("Shuffle your whole library.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActions.shuffle()
        return .result()
    }
}

// MARK: - Shortcuts (Siri / Spotlight / Shortcuts app)

struct SnagShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlaySmartMixIntent(),
            phrases: [
                "Play my \(.applicationName) mix",
                "Play Smart Mix in \(.applicationName)",
                "Start my \(.applicationName) mix",
            ],
            shortTitle: "Smart Mix",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: ShuffleLibraryIntent(),
            phrases: [
                "Shuffle my \(.applicationName) library",
                "Shuffle \(.applicationName)",
            ],
            shortTitle: "Shuffle Library",
            systemImageName: "shuffle"
        )
    }
}

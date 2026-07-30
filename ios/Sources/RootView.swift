import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.modelContext) private var ctx
    @State private var showNowPlaying = false

    var body: some View {
        content
            .task {
                // dev-only: import any audio dropped into Documents (for testing)
                guard ProcessInfo.processInfo.environment["SNAG_SEED"] != nil,
                      ((try? ctx.fetchCount(FetchDescriptor<Track>())) ?? 0) == 0 else { return }
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let audio = ((try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? [])
                    .filter { Storage.isAudio($0) }
                if !audio.isEmpty { _ = await Importer.importFiles(audio, into: ctx) }
            }
    }

    private var content: some View {
        TabView {
            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "music.note.list") }
            NavigationStack { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            NavigationStack { SyncView() }
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
        }
        .safeAreaInset(edge: .bottom) {
            if player.current != nil {
                MiniPlayer().onTapGesture { showNowPlaying = true }
            }
        }
        .fullScreenCover(isPresented: $showNowPlaying) { NowPlayingView() }
    }
}

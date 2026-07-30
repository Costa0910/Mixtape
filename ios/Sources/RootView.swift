import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.modelContext) private var ctx
    @State private var showNowPlaying = false
    @AppStorage("didOnboard") private var didOnboard = false

    var body: some View {
        Group {
            if didOnboard { content } else { OnboardingView(done: $didOnboard) }
        }
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
            tab { LibraryView() }
                .tabItem { Label("Library", systemImage: "music.note.house") }
            tab { PlaylistsView() }
                .tabItem { Label("Playlists", systemImage: "music.note.list") }
            tab { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            tab { SyncView() }
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
        }
        .fullScreenCover(isPresented: $showNowPlaying) { NowPlayingView() }
    }

    // Each tab docks the mini-player just above the tab bar (not over it).
    private func tab<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        NavigationStack { content() }
            .safeAreaInset(edge: .bottom) {
                if player.current != nil {
                    MiniPlayer().onTapGesture { showNowPlaying = true }
                }
            }
    }
}

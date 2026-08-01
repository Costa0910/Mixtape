import SwiftUI
import SwiftData

private enum AppTab: Hashable, CaseIterable {
    case listenNow, library, playlists, sync

    var title: String {
        switch self {
        case .listenNow: "Listen Now"
        case .library: "Library"
        case .playlists: "Playlists"
        case .sync: "Sync"
        }
    }

    var symbol: String {
        switch self {
        case .listenNow: "play.circle.fill"
        case .library: "music.note.house"
        case .playlists: "music.note.list"
        case .sync: "arrow.triangle.2.circlepath"
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var ctx
    @State private var showNowPlaying = false
    @AppStorage("didOnboard") private var didOnboard = false
    @State private var selectedTab: AppTab = .listenNow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .task {
                let tracks = (try? ctx.fetch(FetchDescriptor<Track>())) ?? []
                _ = await Importer.repairArtworkIfNeeded(in: tracks, context: ctx)
            }
    }

    private var content: some View {
        TabView(selection: $selectedTab) {
            tab { ListenNowView() }
                .tag(AppTab.listenNow)
            tab { LibraryView() }
                .tag(AppTab.library)
            tab { PlaylistsView() }
                .tag(AppTab.playlists)
            tab { SyncView() }
                .tag(AppTab.sync)
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomPlaybackDock(selection: $selectedTab, showNowPlaying: $showNowPlaying)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
        .fullScreenCover(isPresented: $showNowPlaying) { NowPlayingView() }
    }

    private func tab<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        NavigationStack { content() }
            .toolbar(.hidden, for: .tabBar)
    }
}

/// A single layout owner keeps playback and navigation visually connected and
/// reserves exactly their real height — no invisible spacer and no double inset.
private struct BottomPlaybackDock: View {
    @Binding var selection: AppTab
    @Binding var showNowPlaying: Bool

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: AppLayout.dockSpacing) { dockContent }
            } else {
                dockContent
            }
        }
        .padding(.horizontal, AppLayout.pageInset)
        .padding(.top, AppLayout.dockSpacing)
        .padding(.bottom, AppLayout.dockBottomPadding)
        .background {
            // Neutralize saturated artwork underneath the glass and visually
            // separate scrolling content from persistent playback controls.
            LinearGradient(colors: [
                .clear,
                Color(uiColor: .systemBackground).opacity(0.72),
                Color(uiColor: .systemBackground).opacity(0.96)
            ],
                           startPoint: .top, endPoint: .bottom)
                .padding(.top, -28)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    private var dockContent: some View {
        VStack(spacing: AppLayout.dockSpacing) {
            PlaybackMiniPlayerSlot(showNowPlaying: $showNowPlaying)
            BalancedGlassTabBar(selection: $selection)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Keeps playback publications (play/pause, track changes) from invalidating
/// the navigation bar and its expensive glass on every player-state change.
private struct PlaybackMiniPlayerSlot: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var showNowPlaying: Bool

    var body: some View {
        if player.current != nil {
            MiniPlayer()
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("miniPlayer")
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onTapGesture { showNowPlaying = true }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct BalancedGlassTabBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: AppTab

    var body: some View {
        if #available(iOS 26.0, *) {
            tabItems
                .padding(.horizontal, 6)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .background(Color(uiColor: .secondarySystemBackground).opacity(0.50), in: Capsule())
                .glassEffect(
                    .regular.tint(Color(uiColor: .systemBackground).opacity(colorScheme == .dark ? 0.55 : 0.38)).interactive(),
                    in: .capsule
                )
        } else {
            tabItems
                .padding(.horizontal, 6)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().fill(Color.primary.opacity(0.06)).allowsHitTesting(false))
                .overlay(Capsule().stroke(Color.primary.opacity(0.16), lineWidth: 0.5))
        }
    }

    private var tabItems: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    Haptics.select()
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 22, weight: .medium))
                        Text(tab.title)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selection == tab ? Color.indigo : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .background(selection == tab ? Color.primary.opacity(0.10) : .clear, in: Capsule())
                    .animation(.snappy, value: selection)
                    .contentShape(Capsule())
                }
                .buttonStyle(Pressable(scale: 0.94))
                .frame(maxWidth: .infinity)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
    }
}

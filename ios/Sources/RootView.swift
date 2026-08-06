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
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeeded") private var hasSeeded = false
    @State private var isLoading = true

    var body: some View {
        ZStack {
            if isLoading {
                LoadingView()
                    .transition(.opacity)
            } else {
                Group {
                    if didOnboard { content } else { OnboardingView(done: $didOnboard) }
                }
                .transition(.opacity)
            }
        }
        .task {
            // dev-only: import any audio dropped into Documents (for testing), gated to once.
            if !hasSeeded, ProcessInfo.processInfo.environment["SNAG_SEED"] != nil,
               ((try? ctx.fetchCount(FetchDescriptor<Track>())) ?? 0) == 0 {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let audio = ((try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? [])
                    .filter { Storage.isAudio($0) }
                if !audio.isEmpty { _ = await Importer.importFiles(audio, into: ctx) }
                hasSeeded = true
            }

            let tracks = (try? ctx.fetch(FetchDescriptor<Track>())) ?? []
            _ = await Importer.repairArtworkIfNeeded(in: tracks, context: ctx)

            withAnimation(.easeInOut(duration: 0.25)) {
                isLoading = false
            }
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
                .padding(.bottom, -18)
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
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var glassNamespace
    @Binding var selection: AppTab
    @Binding var showNowPlaying: Bool

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 0) {
                    dockContent
                        .background(
                            Color(uiColor: .secondarySystemBackground).opacity(0.42),
                            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                        )
                        .glassEffect(
                            .regular.tint(
                                Color(uiColor: .systemBackground)
                                    .opacity(colorScheme == .dark ? 0.48 : 0.32)
                            ),
                            in: .rect(cornerRadius: 28)
                        )
                        .glassEffectID("mediaDock", in: glassNamespace)
                        .glassEffectTransition(.matchedGeometry)
                }
            } else {
                dockContent
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    }
            }
        }
        .padding(.horizontal, AppLayout.pageInset)
        .padding(.top, AppLayout.dockSpacing)
        .padding(.bottom, AppLayout.dockBottomPadding)
        .background {
            LinearGradient(colors: [
                .clear,
                Color(uiColor: .systemBackground).opacity(0.68),
                Color(uiColor: .systemBackground).opacity(0.94)
            ],
                           startPoint: .top, endPoint: .bottom)
                .padding(.top, -22)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .animation(.snappy, value: player.current?.id != nil)
    }

    private var dockContent: some View {
        VStack(spacing: 0) {
            if player.current != nil {
                PlaybackMiniPlayerSlot(showNowPlaying: $showNowPlaying)
                Divider()
                    .padding(.horizontal, 12)
                    .transition(.opacity)
            }
            IntegratedDockTabBar(selection: $selection)
                .frame(maxWidth: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
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
                .accessibilityAction(named: "Open Now Playing") { showNowPlaying = true }
                .contentShape(Rectangle())
                .onTapGesture { showNowPlaying = true }
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
    }
}

private struct IntegratedDockTabBar: View {
    @Binding var selection: AppTab
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        tabItems
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
    }

    private var tabItems: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    Haptics.select()
                    selection = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 20, weight: .semibold))
                        Text(tab.title)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selection == tab ? AppTheme.accent : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(selection == tab ? AppTheme.accent.opacity(colorScheme == .dark ? 0.20 : 0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .animation(.snappy, value: selection)
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(Pressable(scale: 0.94))
                .frame(maxWidth: .infinity)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
    }
}

private struct LoadingView: View {
    var body: some View {
        ZStack {
            AppTheme.screenBackground
                .ignoresSafeArea()

            VStack(spacing: 20) {
                BrandMark(size: 104)

                Text("Snag")
                    .font(.title.weight(.bold))
                    .tracking(-0.5)

                ProgressView("Preparing your library")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .tint(AppTheme.accent)
                    .padding(.top, 8)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

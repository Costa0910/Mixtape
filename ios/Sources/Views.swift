import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ImageIO

// MARK: - Artwork

enum ArtworkImageLoader {
    /// Decode only the pixels the UI can display. A full camera-sized cover can
    /// otherwise occupy tens of MB after decompression even when shown at 150 pt.
    static func downsample(_ url: URL, maxPixelSize: Int = 600) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 80
        cache.totalCostLimit = 64 * 1_024 * 1_024
    }

    func get(for url: URL) -> UIImage? {
        return cache.object(forKey: url as NSURL)
    }

    func set(_ image: UIImage, for url: URL) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

struct ArtworkView: View {
    let url: URL?
    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(uiColor: .secondarySystemFill)
                    Image(systemName: "music.note")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: url) {
            guard let url else { self.image = nil; return }
            // A recycled shelf/grid cell must never display the previous
            // track's cover while its new cover is being decoded.
            self.image = nil
            if let cached = ImageCache.shared.get(for: url) {
                self.image = cached
                return
            }

            let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                ArtworkImageLoader.downsample(url)
            }.value

            guard !Task.isCancelled else { return }
            if let loaded {
                ImageCache.shared.set(loaded, for: url)
                self.image = loaded
            } else {
                self.image = nil
            }
        }
    }
}

struct ImportButton: View {
    @Environment(\.modelContext) private var ctx
    @State private var importing = false
    var label = "Import"
    var body: some View {
        Button { importing = true } label: { Label(label, systemImage: "square.and.arrow.down") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .mpeg4Audio, .mp3],
                          allowsMultipleSelection: true) { res in
                if case .success(let urls) = res {
                    Task {
                        let n = await Importer.importFiles(urls, into: ctx)
                        if n > 0 { Haptics.success() }
                    }
                }
            }
    }
}

private struct InsightsReloadID: Hashable {
    let trackCount: Int
    let memory: String
    let discovery: Double
    let timelessFavorites: Bool
    let learnFromSkips: Bool
}

struct ListenNowView: View {
    private let player = PlayerEngine.shared
    @Query private var tracks: [Track]
    @AppStorage(RecommendationPreferences.memoryKey) private var memoryRaw = TasteMemory.balanced.rawValue
    @AppStorage(RecommendationPreferences.discoveryKey) private var discovery = 0.45
    @AppStorage(RecommendationPreferences.timelessFavoritesKey) private var timelessFavorites = true
    @AppStorage(RecommendationPreferences.learnFromSkipsKey) private var learnFromSkips = true

    @State private var forYou: [Recommender.Mix] = []
    @State private var loved: [Track] = []
    @State private var mostPlayed: [Track] = []
    @State private var discover: [Track] = []
    @State private var recentlyPlayed: [Track] = []
    @State private var showSettings = false
    private let recommendationPlanner = RecommendationPlanner.shared

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableView {
                    Label("No music yet", systemImage: "music.note")
                } description: {
                    Text("Sync from your Mac, or import audio files.")
                } actions: {
                    ImportButton(label: "Import files").buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        smartMixCard

                        if !forYou.isEmpty { forYouSection }
                        if !loved.isEmpty { TrackShelf(title: "Favorites", tracks: loved) }
                        if mostPlayed.count >= 3 { TrackShelf(title: "Most Played", tracks: mostPlayed) }
                        if discover.count >= 3 { TrackShelf(title: "Discover", tracks: discover) }
                        if recentlyPlayed.count >= 3 { TrackShelf(title: "Recently Played", tracks: recentlyPlayed) }
                    }
                    .padding(.horizontal, AppLayout.pageInset)
                    .padding(.top, 6)
                    .padding(.bottom, AppLayout.scrollEndPadding)
                }
                .refreshable { await reloadInsights() }
                .appScreenBackground()
            }
        }
        .navigationTitle("Listen Now")
        .navigationBarTitleDisplayMode(.large)
        .appScreenBackground()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SearchView() } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Search library")
            }
            ToolbarItem(placement: .topBarTrailing) { ImportButton() }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        // Listening-stat saves do not need to rebuild every recommendation.
        // Imports/deletions change the count; pull-to-refresh explicitly reloads
        // updated listening data from SwiftData.
        .task(id: InsightsReloadID(trackCount: tracks.count,
                                   memory: memoryRaw,
                                   discovery: discovery,
                                   timelessFavorites: timelessFavorites,
                                   learnFromSkips: learnFromSkips)) {
            await reloadInsights()
        }
    }

    @MainActor private func reloadInsights() async {
        guard let dashboard = try? await recommendationPlanner.dashboard(),
              !Task.isCancelled else { return }
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        loved = dashboard.lovedIDs.compactMap { byID[$0] }
        mostPlayed = dashboard.mostPlayedIDs.compactMap { byID[$0] }
        recentlyPlayed = dashboard.recentlyPlayedIDs.compactMap { byID[$0] }
        discover = dashboard.discoverIDs.compactMap { byID[$0] }
        forYou = dashboard.mixes.map { plan in
            Recommender.Mix(id: plan.id, name: plan.name, subtitle: plan.subtitle,
                            tracks: plan.trackIDs.compactMap { byID[$0] })
        }
    }

    private var smartMixCard: some View {
        Button {
            player.playSmart(tracks); Haptics.rigid()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart Mix").font(.headline)
                    Text("Tuned to what you love").font(.caption).opacity(0.85)
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(AppTheme.accent)
            }
            .foregroundStyle(.primary)
            .padding(16)
            .groupedSurface()
        }.buttonStyle(Pressable(scale: 0.97))
    }

    private var forYouSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "For You")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(forYou) { mix in
                        NavigationLink { MixDetailView(mix: mix) } label: { MixCard(mix: mix) }
                            .buttonStyle(Pressable(scale: 0.95))
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 2)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

// MARK: - Library

struct LibraryView: View {
    private let player = PlayerEngine.shared
    @Environment(\.modelContext) private var ctx
    @Query(sort: \Track.dateAdded, order: .reverse) private var tracks: [Track]

    @State private var recentlyAdded: [Track] = []
    @State private var recentlyPlayed: [Track] = []
    @State private var mostPlayed: [Track] = []
    @State private var artistCount = 0
    @State private var albumCount = 0
    @State private var genreCount = 0
    @State private var showSettings = false

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableView {
                    Label("No music yet", systemImage: "music.note")
                } description: {
                    Text("Sync from your Mac, or import audio files.")
                } actions: {
                    ImportButton(label: "Import files").buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        actionBar

                        browseSection

                        if recentlyAdded.count >= 4 { TrackShelf(title: "Recently Added", tracks: recentlyAdded) }
                    }
                    .padding(.horizontal, AppLayout.pageInset)
                    .padding(.top, 4)
                    .padding(.bottom, AppLayout.scrollEndPadding)
                }
                .refreshable { await reloadLibrary() }
                .appScreenBackground()
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .appScreenBackground()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .topBarTrailing) { ImportButton() }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task(id: tracks.count) {
            updateLibraryCollections(from: tracks)
        }
    }

    @MainActor private func reloadLibrary() async {
        await Task.yield()
        let all = (try? ctx.fetch(FetchDescriptor<Track>())) ?? tracks
        var descriptor = FetchDescriptor<Track>(sortBy: [SortDescriptor(\Track.dateAdded, order: .reverse)])
        descriptor.fetchLimit = 12
        recentlyAdded = (try? ctx.fetch(descriptor)) ?? Array(tracks.prefix(12))
        recentlyPlayed = Smart.recentlyPlayed(all)
        mostPlayed = Smart.mostPlayed(all)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                player.shuffle = false; player.play(tracks, startAt: 0); Haptics.rigid()
            } label: {
                Label("Play", systemImage: "play.fill")
            }.buttonStyle(PrimaryActionButtonStyle())
            Button {
                shuffleAll(); Haptics.rigid()
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }.buttonStyle(SecondaryActionButtonStyle())
        }
        .groupedGlassEffects()
    }

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Browse")
            VStack(spacing: 0) {
                NavigationLink { AllSongsView() } label: { BrowseRow(icon: "music.note", title: "Songs", count: tracks.count) }
                Divider().padding(.leading, 56)
                NavigationLink { ArtistsView() } label: { BrowseRow(icon: "music.mic", title: "Artists", count: artistCount) }
                Divider().padding(.leading, 56)
                NavigationLink { AllAlbumsView() } label: { BrowseRow(icon: "square.stack", title: "Albums", count: albumCount) }
                Divider().padding(.leading, 56)
                NavigationLink { GenresView() } label: { BrowseRow(icon: "guitars", title: "Genres", count: genreCount) }
            }
            .groupedSurface()

            SectionTitle(title: "Your Listening").padding(.top, 8)
            VStack(spacing: 0) {
                NavigationLink {
                    ListeningCollectionDetailView(kind: .favorites)
                } label: {
                    BrowseRow(icon: ListeningCollectionKind.favorites.symbol,
                              title: ListeningCollectionKind.favorites.title,
                              count: Smart.loved(tracks).count)
                }
                Divider().padding(.leading, 56)
                NavigationLink {
                    ListeningCollectionDetailView(kind: .recentlyPlayed)
                } label: {
                    BrowseRow(icon: ListeningCollectionKind.recentlyPlayed.symbol,
                              title: ListeningCollectionKind.recentlyPlayed.title,
                              count: recentlyPlayed.count)
                }
                Divider().padding(.leading, 56)
                NavigationLink {
                    ListeningCollectionDetailView(kind: .mostPlayed)
                } label: {
                    BrowseRow(icon: ListeningCollectionKind.mostPlayed.symbol,
                              title: ListeningCollectionKind.mostPlayed.title,
                              count: mostPlayed.count)
                }
            }
            .groupedSurface()
        }
        .buttonStyle(.plain)
    }

    private func shuffleAll() {
        player.playShuffled(tracks)
    }

    private func updateLibraryCollections(from library: [Track]) {
        recentlyAdded = Array(library.prefix(12))
        recentlyPlayed = Smart.recentlyPlayed(library)
        mostPlayed = Smart.mostPlayed(library)
        artistCount = Set(library.map(\.artist)).count
        albumCount = Set(library.map(\.album)).count
        genreCount = Set(library.map { $0.genre.isEmpty ? "Unknown" : $0.genre }).count
    }
}

/// A horizontal shelf of tappable song cards; tapping plays from that song in the shelf's order.
struct TrackShelf: View {
    let title: String
    let tracks: [Track]
    private let player = PlayerEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { pair in
                        Button {
                            player.shuffle = false; player.play(tracks, startAt: pair.offset); Haptics.light()
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                SquareArtwork(url: pair.element.artworkURL, corner: 12)
                                    .frame(width: 150, height: 150)
                                    .shadow(color: .black.opacity(0.35), radius: 7, y: 4)
                                Text(pair.element.title).font(.subheadline.weight(.medium))
                                    .lineLimit(1).frame(width: 150, alignment: .leading)
                                Text(pair.element.artist).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).frame(width: 150, alignment: .leading)
                            }
                        }
                        .buttonStyle(Pressable(scale: 0.94))
                        .trackMenu(pair.element)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 2)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// A "Daily Mix" card: representative artwork, with a neutral fallback.
struct MixCard: View {
    let mix: Recommender.Mix

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if mix.artwork != nil {
                SquareArtwork(url: mix.artwork, corner: 14)
                    .overlay(
                        LinearGradient(colors: [.clear, .black.opacity(0.7)],
                                       startPoint: .center, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    )
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "music.note").font(.title3)
                            .foregroundStyle(.secondary).padding(12)
                    }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(mix.subtitle.uppercased()).font(.caption2.weight(.semibold))
                    .foregroundStyle(mix.artwork != nil ? Color.white.opacity(0.75) : Color.secondary)
                Text(mix.name).font(.headline)
                    .foregroundStyle(mix.artwork != nil ? Color.white : Color.primary)
                    .lineLimit(2)
            }
            .padding(12)
        }
        .frame(width: 168, height: 168)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
    }
}

struct MixDetailView: View {
    let mix: Recommender.Mix
    @EnvironmentObject var player: PlayerEngine
    @AppStorage("collectionLayout.mixTracks") private var layout: CollectionLayoutMode = .list

    var body: some View {
        Group {
            if layout == .list { mixList } else { mixGrid }
        }
        .appScreenBackground()
        .navigationTitle(mix.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { CollectionLayoutPicker(selection: $layout) }
    }

    private var mixList: some View {
        List {
            Section {
                mixHeader
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
            }
            Section {
                ForEach(Array(mix.tracks.enumerated()), id: \.element.id) { pair in
                    Button { player.play(mix.tracks, startAt: pair.offset); Haptics.light() } label: {
                        TrackRow(track: pair.element, playing: player.current?.id == pair.element.id)
                    }.buttonStyle(.plain).trackMenu(pair.element)
                }
            }
        }
        .listStyle(.plain)
    }

    private var mixGrid: some View {
        ScrollView {
            VStack(spacing: 20) {
                mixHeader
                TrackGridContent(tracks: mix.tracks, currentTrackID: player.current?.id) { index in
                    player.play(mix.tracks, startAt: index)
                }
            }
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.bottom, AppLayout.scrollEndPadding)
        }
    }

    private var mixHeader: some View {
        VStack(spacing: 14) {
            SquareArtwork(url: mix.artwork, corner: 18)
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                .padding(.top, 8)
            Text(mix.name).font(.title2.bold()).tracking(-0.3).multilineTextAlignment(.center)
            Text("\(mix.tracks.count) song\(mix.tracks.count == 1 ? "" : "s")")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button { player.shuffle = false; player.play(mix.tracks, startAt: 0); Haptics.rigid() } label: {
                    Label("Play", systemImage: "play.fill")
                }.buttonStyle(PrimaryActionButtonStyle())
                Button { player.playShuffled(mix.tracks); Haptics.rigid() } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }.buttonStyle(SecondaryActionButtonStyle())
            }
            .groupedGlassEffects()
        }
    }
}

struct AllAlbumsView: View {
    @Query private var tracks: [Track]
    @State private var albums: [AlbumGroup] = []
    @AppStorage("collectionLayout.albums") private var layout: CollectionLayoutMode = .grid

    private let cols = [
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18)
    ]

    var body: some View {
        Group {
            if layout == .grid {
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 18) {
                        ForEach(albums) { album in
                            NavigationLink { AlbumDetailView(album: album) } label: { AlbumTile(album: album) }
                                .buttonStyle(Pressable(scale: 0.97))
                        }
                    }
                    .padding(.horizontal, AppLayout.pageInset)
                    .padding(.top, 14)
                    .padding(.bottom, AppLayout.scrollEndPadding)
                }
            } else {
                List(albums) { album in
                    NavigationLink { AlbumDetailView(album: album) } label: {
                        HStack(spacing: 12) {
                            SquareArtwork(url: album.artworkURL, corner: 10).frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.name).font(.body.weight(.medium)).lineLimit(1)
                                Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
            }
        }
        .appScreenBackground()
        .navigationTitle("Albums")
        .toolbar { CollectionLayoutPicker(selection: $layout) }
        .onChange(of: tracks, initial: true) { _, newTracks in
            albums = LibraryGrouping.albums(newTracks)
        }
    }
}

struct AlbumTile: View {
    let album: AlbumGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SquareArtwork(url: album.artworkURL, corner: 14)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct AlbumDetailView: View {
    let album: AlbumGroup
    @EnvironmentObject var player: PlayerEngine
    @AppStorage("collectionLayout.albumTracks") private var layout: CollectionLayoutMode = .list

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SquareArtwork(url: album.artworkURL, corner: 18)
                    .frame(width: 220, height: 220)
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
                    .padding(.top, 8)

                VStack(spacing: 4) {
                    Text(album.name).font(.title2.bold()).tracking(-0.3).multilineTextAlignment(.center)
                    Text(album.artist).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button { player.shuffle = false; player.play(album.tracks, startAt: 0); Haptics.rigid() } label: {
                        Label("Play", systemImage: "play.fill")
                    }.buttonStyle(PrimaryActionButtonStyle())
                    Button { player.playShuffled(album.tracks); Haptics.rigid() } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }.buttonStyle(SecondaryActionButtonStyle())
                }
                .groupedGlassEffects()
                .padding(.horizontal, 4)

                if layout == .list {
                    VStack(spacing: 0) {
                        ForEach(Array(album.tracks.enumerated()), id: \.element.id) { pair in
                            Button {
                                player.play(album.tracks, startAt: pair.offset); Haptics.light()
                            } label: {
                                TrackRow(track: pair.element, index: pair.offset + 1,
                                         playing: player.current?.id == pair.element.id)
                            }.buttonStyle(Pressable(scale: 0.985)).trackMenu(pair.element)
                            if pair.offset < album.tracks.count - 1 {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                } else {
                    TrackGridContent(tracks: album.tracks, currentTrackID: player.current?.id) { index in
                        player.play(album.tracks, startAt: index)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, AppLayout.scrollEndPadding)
        }
        .appScreenBackground()
        .navigationTitle(album.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { CollectionLayoutPicker(selection: $layout) }
    }
}

/// Album-like destination for the complete local listening history. Unlike the
/// small Listen Now shelves, these collections remain available in Library and
/// queue every matching track in their meaningful order.
struct ListeningCollectionDetailView: View {
    let kind: ListeningCollectionKind
    @EnvironmentObject private var player: PlayerEngine
    @Query private var library: [Track]
    @AppStorage("collectionLayout.listeningTracks") private var layout: CollectionLayoutMode = .list

    var body: some View {
        // Sort the library once per render (not on every property access), and
        // render rows lazily below so opening the screen stays instant.
        let tracks = kind.tracks(from: library)
        return Group {
            if tracks.isEmpty {
                ContentUnavailableView {
                    Label(kind.emptyTitle, systemImage: kind.symbol)
                } description: {
                    Text(kind.emptyDescription)
                }
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemFill))
                            Image(systemName: kind.symbol)
                                .font(.system(size: 72, weight: .semibold))
                                .foregroundStyle(.primary)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .frame(width: 220, height: 220)
                        .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
                        .padding(.top, 8)
                        .accessibilityHidden(true)

                        VStack(spacing: 4) {
                            Text(kind.title).font(.title2.bold()).tracking(-0.3)
                            Text(kind.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)

                        HStack(spacing: 12) {
                            Button {
                                Haptics.rigid()
                                player.shuffle = false
                                player.play(tracks, startAt: 0)
                            } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            .buttonStyle(PrimaryActionButtonStyle())

                            Button {
                                Haptics.rigid()
                                player.playShuffled(tracks)
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                        }
                        .groupedGlassEffects()
                        .padding(.horizontal, 4)

                        if layout == .list {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(tracks.enumerated()), id: \.element.id) { pair in
                                    Button {
                                        Haptics.light()
                                        player.shuffle = false
                                        player.play(tracks, startAt: pair.offset)
                                    } label: {
                                        TrackRow(track: pair.element, index: pair.offset + 1,
                                                 playing: player.current?.id == pair.element.id)
                                    }
                                    .buttonStyle(Pressable(scale: 0.985))
                                    .trackMenu(pair.element)
                                    if pair.offset < tracks.count - 1 { Divider().padding(.leading, 44) }
                                }
                            }
                        } else {
                            TrackGridContent(tracks: tracks, currentTrackID: player.current?.id) { index in
                                player.shuffle = false
                                player.play(tracks, startAt: index)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, AppLayout.scrollEndPadding)
                }
            }
        }
        .appScreenBackground()
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !tracks.isEmpty { CollectionLayoutPicker(selection: $layout) }
        }
    }
}

struct TrackRow: View {
    let track: Track
    var index: Int? = nil
    var playing = false
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if playing {
                    Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.indigo)
                } else if let index {
                    Text("\(index)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "music.note").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1).fontWeight(playing ? .semibold : .regular)
                    .foregroundStyle(playing ? Color.indigo : Color.primary)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if track.loved { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink) }
            Text(track.durationText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject var player: PlayerEngine
    @Query private var tracks: [Track]
    @State private var q = ""
    @AppStorage("collectionLayout.search") private var layout: CollectionLayoutMode = .list

    var results: [Track] {
        guard !q.isEmpty else { return [] }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.artist.localizedCaseInsensitiveContains(q) ||
            $0.album.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        Group {
            if q.isEmpty {
                ContentUnavailableView("Search your library", systemImage: "magnifyingglass",
                                       description: Text("Find songs, artists, and albums."))
            } else if results.isEmpty {
                ContentUnavailableView.search(text: q)
            } else if layout == .grid {
                TrackGridView(tracks: results, currentTrackID: player.current?.id) { index in
                    player.play(results, startAt: index)
                }
            } else {
                List {
                    ForEach(Array(results.enumerated()), id: \.element.id) { pair in
                        Button { player.play(results, startAt: pair.offset); Haptics.light() } label: {
                            TrackRow(track: pair.element, playing: player.current?.id == pair.element.id)
                        }.buttonStyle(.plain).trackMenu(pair.element).trackSwipeActions(pair.element)
                    }
                }.listStyle(.plain)
            }
        }
        .appScreenBackground()
        .searchable(text: $q, prompt: "Songs, artists, albums")
        .navigationTitle("Search")
        .toolbar {
            if !q.isEmpty { CollectionLayoutPicker(selection: $layout) }
        }
    }
}

// MARK: - Sync (Wi‑Fi from the Mac)

struct SyncView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var tracks: [Track]
    @StateObject private var client = SyncClient()
    @StateObject private var browser = BonjourBrowser()
    @AppStorage("syncHost") private var host = ""
    @AppStorage("syncPin") private var pin = ""

    var body: some View {
        List {
            if !browser.found.isEmpty {
                Section {
                    ForEach(browser.found) { mac in
                        Button {
                            Haptics.light(); host = mac.address
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer").foregroundStyle(.indigo)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(mac.name).foregroundStyle(.primary)
                                    Text(mac.address).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if host == mac.address { Image(systemName: "checkmark").foregroundStyle(.indigo) }
                            }
                        }
                    }
                } header: { Text("On your network") }
            }

            Section {
                TextField("192.168.1.42:8080", text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("PIN", text: $pin).keyboardType(.numberPad)
            } header: { Text("Your Mac") } footer: {
                Text("On the Mac: **Snag → Devices → Wireless (on)**. Your Mac appears above automatically, or type the address and PIN it shows.")
            }

            Section {
                Button { Task { await run() } } label: {
                    HStack {
                        if client.busy { ProgressView().tint(.white) }
                        Text(client.busy ? "Syncing…" : "Sync now").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(client.busy || host.isEmpty || pin.isEmpty)
                .listRowBackground(host.isEmpty || pin.isEmpty ? Color(uiColor: .tertiarySystemFill) : AppTheme.accent)
                .foregroundStyle(host.isEmpty || pin.isEmpty ? Color.secondary : Color.white)

                if client.busy {
                    ProgressView(value: client.progress).tint(.indigo)
                }
                if !client.status.isEmpty {
                    Text(client.status).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section {
                ImportDeviceMusicButton()
                ImportButton(label: "Import from Files")
            } header: { Text("On this iPhone") } footer: {
                Text("Bring in the music already in your Music app, or add files via AirDrop or the Files app.")
            }
        }
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.large)
        .appScreenBackground()
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func run() async {
        Haptics.light()
        await client.sync(host: host, pin: pin, into: ctx)
        if client.progress >= 1 { Haptics.success() }
    }
}

// MARK: - Floating mini-player

struct MiniPlayer: View {
    @EnvironmentObject var player: PlayerEngine
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                SquareArtwork(url: player.current?.artworkURL, corner: 9)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.current?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(player.current?.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { player.playPause(); Haptics.soft() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.08), in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(Pressable(scale: 0.85))
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.next(userInitiated: true); Haptics.soft() } label: {
                    Image(systemName: "forward.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Pressable(scale: 0.85))
                .accessibilityLabel("Next")
            }
            .foregroundStyle(.primary)
            MiniPlayerProgress()
                .padding(.horizontal, 2)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 7)
    }
}

private struct MiniPlayerProgress: View {
    @ObservedObject private var clock = PlayerEngine.shared.clock

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(Color.indigo)
                    .frame(width: max(0, geo.size.width * clock.progress))
            }
        }
        .frame(height: 2)
    }
}

struct TimedLyricLine: Identifiable, Equatable {
    let id: String
    let time: Double
    let text: String
}

struct TimedLyricsParser {
    static func parse(_ lyricsText: String) -> [TimedLyricLine] {
        var lines: [TimedLyricLine] = []
        let components = lyricsText.components(separatedBy: .newlines)

        let tsRegexPattern = "\\[(\\d+):(\\d+)(?::(\\d+))?(?:[.,](\\d+))?\\]"
        guard let tsRegex = try? NSRegularExpression(pattern: tsRegexPattern, options: []) else { return [] }

        for (sourceIndex, line) in components.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let range = NSRange(location: 0, length: trimmed.utf16.count)
            let tsMatches = tsRegex.matches(in: trimmed, options: [], range: range)
            guard !tsMatches.isEmpty else { continue }

            let lastMatch = tsMatches.last!
            let textStartIndex = lastMatch.range.location + lastMatch.range.length
            let lyricText = (trimmed as NSString).substring(from: textStartIndex).trimmingCharacters(in: .whitespacesAndNewlines)

            for tsMatch in tsMatches {
                let firstStr = (trimmed as NSString).substring(with: tsMatch.range(at: 1))
                let secondStr = (trimmed as NSString).substring(with: tsMatch.range(at: 2))
                
                var thirdStr: String? = nil
                if tsMatch.range(at: 3).location != NSNotFound {
                    thirdStr = (trimmed as NSString).substring(with: tsMatch.range(at: 3))
                }
                
                var fourthStr: String? = nil
                if tsMatch.range(at: 4).location != NSNotFound {
                    fourthStr = (trimmed as NSString).substring(with: tsMatch.range(at: 4))
                }
                
                var totalSecs = 0.0
                if let first = Double(firstStr), let second = Double(secondStr) {
                    if let third = thirdStr.flatMap(Double.init) {
                        let hours = first
                        let minutes = second
                        let seconds = third
                        var msVal = 0.0
                        if let fourth = fourthStr {
                            let paddedMs = fourth.padding(toLength: 3, withPad: "0", startingAt: 0)
                            msVal = (Double(paddedMs) ?? 0.0) / 1000.0
                        }
                        totalSecs = hours * 3600.0 + minutes * 60.0 + seconds + msVal
                    } else {
                        let minutes = first
                        let seconds = second
                        var msVal = 0.0
                        if let fourth = fourthStr {
                            let paddedMs = fourth.padding(toLength: 3, withPad: "0", startingAt: 0)
                            msVal = (Double(paddedMs) ?? 0.0) / 1000.0
                        }
                        totalSecs = minutes * 60.0 + seconds + msVal
                    }
                    
                    let identity = "\(sourceIndex)-\(tsMatch.range.location)-\(totalSecs)"
                    lines.append(TimedLyricLine(id: identity, time: totalSecs, text: lyricText))
                }
            }
        }

        return lines.sorted(by: { $0.time < $1.time })
    }
}

/// The only lyrics subtree that observes the five-Hz playback clock. Keeping
/// it separate prevents artwork, controls, queue, and the full-screen layout
/// from being recomputed for every lyric/progress update.
private struct TimedLyricsView: View {
    let lines: [TimedLyricLine]
    @ObservedObject private var clock = PlayerEngine.shared.clock
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeLyricId: String? {
        lines.last(where: { $0.time <= clock.elapsed })?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(lines) { line in
                        let isActive = line.id == activeLyricId
                        Text(line.text)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(isActive ? Color.primary : Color.secondary)
                            .scaleEffect(isActive ? 1.02 : 1.0)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 24)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Haptics.soft()
                                PlayerEngine.shared.seek(toTime: line.time)
                            }
                            .id(line.id)
                    }
                }
                .padding(.vertical, 100)
            }
            .onChange(of: activeLyricId) {
                guard let id = activeLyricId else { return }
                if reduceMotion { proxy.scrollTo(id, anchor: .center) }
                else { withAnimation(.settled) { proxy.scrollTo(id, anchor: .center) } }
            }
            .onAppear {
                if let id = activeLyricId { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

// MARK: - Now Playing

struct NowPlayingView: View {
    private enum PlayerSurface {
        case artwork
        case lyrics
        case queue
    }

    @EnvironmentObject var player: PlayerEngine
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingPlaylistSheet = false
    @State private var activeMenuTrack: Track? = nil
    @State private var trackPendingDeletion: Track? = nil
    @State private var artDrag: CGFloat = 0
    @State private var surface: PlayerSurface = .artwork

    private var timedLyrics: [TimedLyricLine] {
        guard let text = player.current?.lyrics else { return [] }
        return TimedLyricsParser.parse(text)
    }

    var body: some View {
        GeometryReader { geometry in
            let artworkSize = max(1, min(358, geometry.size.width - 48, geometry.size.height * 0.40))

            VStack(spacing: 0) {
                playerHeader
                    .frame(width: max(0, geometry.size.width - 36))
                    .padding(.top, 8)

                playerSurface(artworkSize: artworkSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 10)

                controlConsole
                    .frame(width: max(0, geometry.size.width - 32))
                    .padding(.bottom, 6)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(
            AmbientBackground(url: player.current?.artworkURL)
                .animation(reduceMotion ? nil : .settled, value: player.current?.id)
        )
        .onChange(of: player.current?.id) { _, _ in
            if player.current?.lyrics?.isEmpty != false, surface == .lyrics { surface = .artwork }
        }
        .confirmationDialog("Delete this track?", isPresented: Binding(
            get: { trackPendingDeletion != nil },
            set: { if !$0 { trackPendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("Delete from Library", role: .destructive) {
                if let trackPendingDeletion { deleteTrack(trackPendingDeletion) }
                trackPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { trackPendingDeletion = nil }
        } message: {
            Text("This removes the audio file from this iPhone. You can sync it again from your Mac.")
        }
        .sheet(isPresented: $showingPlaylistSheet) {
            if let track = activeMenuTrack {
                AddToPlaylistSheet(track: track)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private var playerHeader: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(Pressable(scale: 0.88))
            .accessibilityLabel("Close player")

            Spacer()

            VStack(spacing: 5) {
                Capsule()
                    .fill(.secondary.opacity(0.55))
                    .frame(width: 36, height: 4)
                Text(surfaceTitle)
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            Spacer()

            Button {
                Haptics.select()
                changeSurface(to: surface == .queue ? .artwork : .queue)
            } label: {
                Image(systemName: "list.bullet")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(surface == .queue ? Color.indigo : Color.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(Pressable(scale: 0.88))
            .accessibilityLabel(surface == .queue ? "Hide queue" : "Show queue")
            .accessibilityValue(surface == .queue ? "On" : "Off")
        }
        .foregroundStyle(.primary)
    }

    private var surfaceTitle: String {
        switch surface {
        case .artwork: "Now Playing"
        case .lyrics: "Lyrics"
        case .queue: "Up Next"
        }
    }

    @ViewBuilder
    private func playerSurface(artworkSize: CGFloat) -> some View {
        switch surface {
        case .lyrics:
            if timedLyrics.isEmpty {
                ScrollView(showsIndicators: false) {
                    Text(player.current?.lyrics ?? "")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 40)
                }
            } else {
                TimedLyricsView(lines: timedLyrics)
            }
        case .queue:
            InlineQueueView()
                .padding(.horizontal, 16)
        case .artwork:
            SquareArtwork(url: player.current?.artworkURL, corner: 28)
                .frame(width: artworkSize, height: artworkSize)
                .shadow(color: .black.opacity(0.34), radius: 28, y: 16)
                .offset(x: artDrag)
                .contentShape(Rectangle())
                .gesture(artworkGesture)
                .onTapGesture {
                    if player.current?.lyrics?.isEmpty == false {
                        changeSurface(to: .lyrics)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
        }
    }

    private var artworkGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                if abs(value.translation.width) > abs(value.translation.height) {
                    artDrag = value.translation.width / 3
                }
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if reduceMotion { artDrag = 0 }
                else { withAnimation(.snappy) { artDrag = 0 } }

                if abs(dx) > abs(dy) {
                    if dx < -60 { player.next(userInitiated: true); Haptics.soft() }
                    else if dx > 60 { player.previous(); Haptics.soft() }
                } else if dy > 90 {
                    dismiss()
                }
            }
    }

    private var controlConsole: some View {
        VStack(spacing: 10) {
            trackIdentity
            Scrubber()
            transportControls
            SystemVolumeControl()
            secondaryControls
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .playerControlSurface(cornerRadius: 30)
    }

    private var trackIdentity: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "")
                    .font(.title3.weight(.bold))
                    .tracking(-0.25)
                    .lineLimit(1)
                Text(player.current?.artist ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                guard let track = player.current else { return }
                Haptics.rigid()
                withAnimation(.bouncy) {
                    track.loved.toggle()
                    try? ctx.save()
                }
            } label: {
                Image(systemName: (player.current?.loved ?? false) ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle((player.current?.loved ?? false) ? Color.pink : Color.secondary)
                    .symbolEffect(.bounce, value: player.current?.loved)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Pressable(scale: 0.82))
            .accessibilityLabel((player.current?.loved ?? false) ? "Remove from favorites" : "Add to favorites")

            trackMenu
        }
    }

    private var trackMenu: some View {
        Menu {
            Button {
                if let current = player.current {
                    activeMenuTrack = current
                    showingPlaylistSheet = true
                }
            } label: {
                Label("Add to Playlist…", systemImage: "text.badge.plus")
            }

            Button(role: .destructive) {
                if let current = player.current { trackPendingDeletion = current }
            } label: {
                Label("Delete from Library", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(Pressable(scale: 0.82))
        .accessibilityLabel("More")
    }

    private var transportControls: some View {
        HStack {
            Button { player.previous(); Haptics.soft() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(width: 58, height: 58)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Pressable(scale: 0.86))
            .accessibilityLabel("Previous")

            Spacer()

            Button { player.playPause(); Haptics.rigid() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 27, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(width: 68, height: 68)
                    .background(Color.primary, in: Circle())
            }
            .buttonStyle(Pressable(scale: 0.91))
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Spacer()

            Button { player.next(userInitiated: true); Haptics.soft() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(width: 58, height: 58)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Pressable(scale: 0.86))
            .accessibilityLabel("Next")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
    }

    private var secondaryControls: some View {
        HStack {
            Button {
                Haptics.soft()
                changeSurface(to: surface == .lyrics ? .artwork : .lyrics)
            } label: {
                Image(systemName: "quote.bubble")
                    .foregroundStyle(surface == .lyrics ? Color.indigo : Color.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Pressable(scale: 0.8))
            .disabled(player.current?.lyrics?.isEmpty != false)
            .opacity(player.current?.lyrics?.isEmpty != false ? 0.25 : 1)
            .accessibilityLabel(surface == .lyrics ? "Hide lyrics" : "Show lyrics")
            .accessibilityValue(surface == .lyrics ? "On" : "Off")

            Spacer()

            Button { Haptics.select(); player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.shuffle ? Color.indigo : Color.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Pressable(scale: 0.8))
            .accessibilityLabel("Shuffle")
            .accessibilityValue(player.shuffle ? "On" : "Off")

            Spacer()

            Button { Haptics.select(); player.autoplay.toggle() } label: {
                Image(systemName: "infinity")
                    .foregroundStyle(player.autoplay ? Color.indigo : Color.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Pressable(scale: 0.8))
            .accessibilityLabel("Autoplay")
            .accessibilityValue(player.autoplay ? "On" : "Off")

            Spacer()

            sleepTimerMenu

            Spacer()

            Button { Haptics.select(); player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.indigo)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Pressable(scale: 0.8))
            .accessibilityLabel("Repeat")
            .accessibilityValue(player.repeatMode == .off ? "Off" : (player.repeatMode == .one ? "One" : "All"))

            Spacer()

            AirPlayButton(tint: .secondaryLabel)
                .frame(width: 44, height: 44)
                .accessibilityLabel("AirPlay")
        }
        .font(.title3)
    }

    private var sleepTimerMenu: some View {
        Menu {
            if player.sleepTimerRemaining != nil || player.sleepTimerEndBlock {
                Section("Active Timer") {
                    if let remaining = player.sleepTimerRemaining {
                        let mins = Int(remaining) / 60
                        let secs = Int(remaining) % 60
                        Button("Cancel Timer (\(String(format: "%d:%02d", mins, secs)) left)", role: .destructive) {
                            player.setSleepTimer(minutes: nil)
                        }
                    } else if player.sleepTimerEndBlock {
                        Button("Cancel (End of Song)", role: .destructive) {
                            player.setSleepTimer(minutes: nil)
                        }
                    }
                }
            }
            Section("Set Timer") {
                Button("End of Current Song") { player.setSleepTimerEndBlock() }
                Button("15 Minutes") { player.setSleepTimer(minutes: 15) }
                Button("30 Minutes") { player.setSleepTimer(minutes: 30) }
                Button("45 Minutes") { player.setSleepTimer(minutes: 45) }
                Button("60 Minutes") { player.setSleepTimer(minutes: 60) }
            }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: "timer")
                    .foregroundStyle((player.sleepTimerRemaining != nil || player.sleepTimerEndBlock) ? Color.indigo : Color.secondary)
                if let remaining = player.sleepTimerRemaining {
                    Text(String(format: "%d:%02d", Int(remaining) / 60, Int(remaining) % 60))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.indigo)
                } else if player.sleepTimerEndBlock {
                    Text("End")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.indigo)
                }
            }
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Sleep timer")
    }

    private func changeSurface(to destination: PlayerSurface) {
        if reduceMotion { surface = destination }
        else { withAnimation(.settled) { surface = destination } }
    }

    private func deleteTrack(_ track: Track) {
        Haptics.rigid()

        // Stop playback if current
        if player.current?.id == track.id {
            player.playPause()
            player.current = nil
        }

        // Delete audio file
        try? FileManager.default.removeItem(at: track.url)

        // Delete artwork if no other track uses it
        if let artworkURL = track.artworkURL {
            let trackID = track.id
            let artworkRel = track.artworkRel
            let allTracks = (try? ctx.fetch(FetchDescriptor<Track>())) ?? []
            let shared = allTracks.contains { $0.id != trackID && $0.artworkRel == artworkRel }
            if !shared {
                try? FileManager.default.removeItem(at: artworkURL)
            }
        }

        // Remove from all playlists
        let trackID = track.id
        if let playlists = try? ctx.fetch(FetchDescriptor<Playlist>()) {
            for pl in playlists {
                pl.trackIDs.removeAll { $0 == trackID }
            }
        }

        ctx.delete(track)
        try? ctx.save()
        dismiss()
    }
}

/// Direct-manipulation scrubber: responds on touch-down, tracks 1:1, seeks on release (§1–§2).
struct Scrubber: View {
    @EnvironmentObject var player: PlayerEngine
    @ObservedObject private var clock = PlayerEngine.shared.clock
    @State private var dragFrac: Double? = nil

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let frac = dragFrac ?? clock.progress
                ZStack(alignment: .leading) {
                    Capsule().fill(.tertiary)
                    Capsule().fill(.primary).frame(width: max(0, geo.size.width * frac))
                }
                .frame(height: dragFrac == nil ? 6 : 9)
                .frame(maxHeight: .infinity, alignment: .center)
                .animation(.snappy, value: dragFrac == nil)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in dragFrac = min(max(v.location.x / geo.size.width, 0), 1) }
                        .onEnded { v in
                            let f = min(max(v.location.x / geo.size.width, 0), 1)
                            player.seek(toFraction: f); dragFrac = nil; Haptics.select()
                        }
                )
            }.frame(height: 24)

            HStack {
                Text(timeStr((dragFrac ?? clock.progress) * clock.duration))
                Spacer()
                Text("-" + timeStr(max(0, clock.duration - (dragFrac ?? clock.progress) * clock.duration)))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(timeStr(clock.elapsed)) of \(timeStr(clock.duration))")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 15.0 : -15.0
            player.seek(toTime: min(max(clock.elapsed + delta, 0), clock.duration))
            Haptics.select()
        }
    }

    private func timeStr(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let i = Int(s); return String(format: "%d:%02d", i / 60, i % 60)
    }
}

// MARK: - Inline Queue

struct InlineQueueView: View {
    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        let upcoming = player.fullQueue.enumerated().filter { $0.offset > player.currentQueueIndex }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Up Next")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(upcoming.count) \(upcoming.count == 1 ? "song" : "songs")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)

            if let current = player.current {
                VStack(spacing: 8) {
                    QueueRow(track: current, active: true)
                    Divider()
                }
                .padding(.horizontal, 14)
            }

            if upcoming.isEmpty {
                ContentUnavailableView(
                    "Nothing Up Next",
                    systemImage: "music.note.list",
                    description: Text("Autoplay can keep the music going.")
                )
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(upcoming, id: \.offset) { index, track in
                        Button {
                            Haptics.light()
                            player.skipToQueueIndex(index)
                        } label: {
                            QueueRow(track: track, active: false)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.primary.opacity(0.08))
                    }
                    .onDelete { indexSet in
                        for offset in indexSet.sorted(by: >) {
                            player.removeFromQueue(at: upcoming[offset].offset)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback queue")
    }
}

struct QueueRow: View {
    let track: Track
    let active: Bool

    var body: some View {
        HStack(spacing: 12) {
            SquareArtwork(url: track.artworkURL, corner: 6)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.86))
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if active {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .symbolEffect(.variableColor, options: .repeating)
            }
        }
        .padding(.vertical, 2)
    }
}

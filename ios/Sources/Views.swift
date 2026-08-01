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

struct ListenNowView: View {
    private let player = PlayerEngine.shared
    @Query private var tracks: [Track]

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
            }
        }
        .navigationTitle("Listen Now")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(nil, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .principal) {
                Text("Listen Now").font(.headline)
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
        .task(id: tracks.count) {
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
            HStack(spacing: 14) {
                Image(systemName: "sparkles").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart Mix").font(.headline)
                    Text("Tuned to what you love").font(.caption).opacity(0.85)
                }
                Spacer()
                Image(systemName: "play.circle.fill").font(.title)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 18).padding(.vertical, 16)
            .balancedGlassCard()
        }.buttonStyle(Pressable(scale: 0.97))
    }

    private var forYouSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("For You").font(.title3.bold()).tracking(-0.2)
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
                    .padding(.horizontal)
                    .padding(.top, 4)
                    .padding(.bottom, AppLayout.scrollEndPadding)
                }
                .refreshable { await reloadLibrary() }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
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
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Color.indigo, in: Capsule()).foregroundStyle(.white)
            }.buttonStyle(Pressable())
            Button {
                shuffleAll(); Haptics.rigid()
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.primary)
            }.buttonStyle(Pressable())
        }
    }

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browse").font(.title3.bold()).tracking(-0.2)
            VStack(spacing: 0) {
                NavigationLink { AllSongsView() } label: { BrowseRow(icon: "music.note", title: "Songs", count: tracks.count) }
                Divider().padding(.leading, 56)
                NavigationLink { ArtistsView() } label: { BrowseRow(icon: "music.mic", title: "Artists", count: artistCount) }
                Divider().padding(.leading, 56)
                NavigationLink { AllAlbumsView() } label: { BrowseRow(icon: "square.stack", title: "Albums", count: albumCount) }
                Divider().padding(.leading, 56)
                NavigationLink { GenresView() } label: { BrowseRow(icon: "guitars", title: "Genres", count: genreCount) }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("Your Listening").font(.title3.bold()).tracking(-0.2).padding(.top, 8)
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
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            Text(title).font(.title3.bold()).tracking(-0.2)
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
                        .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.indigo, in: Capsule()).foregroundStyle(.white)
                }.buttonStyle(Pressable())
                Button { player.playShuffled(mix.tracks); Haptics.rigid() } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                }.buttonStyle(Pressable())
            }
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
                            .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.indigo, in: Capsule()).foregroundStyle(.white)
                    }.buttonStyle(Pressable())
                    Button { player.playShuffled(album.tracks); Haptics.rigid() } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                    }.buttonStyle(Pressable())
                }.padding(.horizontal, 4)

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

    private var tracks: [Track] { kind.tracks(from: library) }

    var body: some View {
        Group {
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
                                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                                    .background(Color.indigo, in: Capsule()).foregroundStyle(.white)
                            }
                            .buttonStyle(Pressable())

                            Button {
                                Haptics.rigid()
                                player.playShuffled(tracks)
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            .buttonStyle(Pressable())
                        }
                        .padding(.horizontal, 4)

                        if layout == .list {
                            VStack(spacing: 0) {
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
                .listRowBackground(host.isEmpty || pin.isEmpty ? Color.gray.opacity(0.3) : Color.indigo)
                .foregroundStyle(.white)

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
        VStack(spacing: 0) {
            MiniPlayerProgress()

            HStack(spacing: 12) {
                SquareArtwork(url: player.current?.artworkURL, corner: 8)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.current?.title ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(player.current?.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { player.playPause(); Haptics.soft() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 30, height: 30)
                        .contentTransition(.symbolEffect(.replace))
                }.buttonStyle(Pressable(scale: 0.85))
                Button { player.next(userInitiated: true); Haptics.soft() } label: {
                    Image(systemName: "forward.fill").font(.body).frame(width: 30, height: 30)
                }.buttonStyle(Pressable(scale: 0.85))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .balancedGlassCard()
        .shadow(color: .black.opacity(0.24), radius: 10, y: 3)
    }
}

private struct MiniPlayerProgress: View {
    @ObservedObject private var clock = PlayerEngine.shared.clock

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(Color.indigo)
                .frame(width: max(0, geo.size.width * clock.progress), height: 2)
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

        let pattern = "^\\[(\\d+):(\\d+)(?:\\.(\\d+))?\\].*$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let tsRegexPattern = "\\[(\\d+):(\\d+)(?:\\.(\\d+))?\\]"
        guard let tsRegex = try? NSRegularExpression(pattern: tsRegexPattern, options: []) else { return [] }

        for (sourceIndex, line) in components.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let range = NSRange(location: 0, length: trimmed.utf16.count)
            let matchResults = regex.matches(in: trimmed, options: [], range: range)

            if !matchResults.isEmpty {
                let tsMatches = tsRegex.matches(in: trimmed, options: [], range: range)
                if tsMatches.isEmpty { continue }

                let lastMatch = tsMatches.last!
                let textStartIndex = lastMatch.range.location + lastMatch.range.length
                let lyricText = (trimmed as NSString).substring(from: textStartIndex).trimmingCharacters(in: .whitespacesAndNewlines)

                for tsMatch in tsMatches {
                    let minStr = (trimmed as NSString).substring(with: tsMatch.range(at: 1))
                    let secStr = (trimmed as NSString).substring(with: tsMatch.range(at: 2))
                    var msVal = 0.0
                    if tsMatch.numberOfRanges > 3, tsMatch.range(at: 3).location != NSNotFound {
                        let msStr = (trimmed as NSString).substring(with: tsMatch.range(at: 3))
                        let paddedMs = msStr.padding(toLength: 3, withPad: "0", startingAt: 0)
                        msVal = (Double(paddedMs) ?? 0.0) / 1000.0
                    }

                    if let mins = Double(minStr), let secs = Double(secStr) {
                        let totalSecs = mins * 60.0 + secs + msVal
                        let identity = "\(sourceIndex)-\(tsMatch.range.location)-\(totalSecs)"
                        lines.append(TimedLyricLine(id: identity, time: totalSecs, text: lyricText))
                    }
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
                            .font(.system(size: 26, weight: .bold))
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
            let surfaceSize = max(1, min(340, geometry.size.width - 68, geometry.size.height * 0.38))

            VStack(spacing: 0) {
                Capsule().fill(.secondary.opacity(0.55)).frame(width: 40, height: 5).padding(.top, 10)

                if surface == .lyrics {
                    // Full Screen Timed Lyrics View
                    VStack(spacing: 16) {
                        // Mini Header
                        HStack(spacing: 12) {
                            SquareArtwork(url: player.current?.artworkURL, corner: 6)
                                .frame(width: 48, height: 48)
                                .shadow(radius: 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(player.current?.title ?? "").font(.headline).foregroundStyle(.primary).lineLimit(1)
                                Text(player.current?.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()

                            // Heart button
                            Button {
                                guard let t = player.current else { return }
                                Haptics.rigid(); withAnimation(.bouncy) {
                                    t.loved.toggle()
                                    try? ctx.save()
                                }
                            } label: {
                                Image(systemName: (player.current?.loved ?? false) ? "heart.fill" : "heart")
                                    .font(.title3)
                                    .foregroundStyle((player.current?.loved ?? false) ? Color.pink : Color.secondary)
                            }
                            .buttonStyle(Pressable(scale: 0.8))
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)

                        // Large Timed Lyrics (Left aligned)
                        if timedLyrics.isEmpty {
                            ScrollView(showsIndicators: false) {
                                Text(player.current?.lyrics ?? "")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(.primary.opacity(0.9))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 48)
                            }
                        } else {
                            TimedLyricsView(lines: timedLyrics)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                } else if surface == .queue {
                    InlineQueueView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 34)
                        .transition(.opacity)
                } else {
                    // Original artwork and title presentation.
                    VStack(spacing: 18) {
                        SquareArtwork(url: player.current?.artworkURL, corner: 22)
                            .frame(width: surfaceSize, height: surfaceSize)
                            .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
                            .offset(x: artDrag)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 20)
                                    .onChanged { v in
                                        if abs(v.translation.width) > abs(v.translation.height) { artDrag = v.translation.width / 3 }
                                    }
                                    .onEnded { v in
                                        let dx = v.translation.width, dy = v.translation.height
                                        if reduceMotion { artDrag = 0 }
                                        else { withAnimation(.snappy) { artDrag = 0 } }
                                        if abs(dx) > abs(dy) {
                                            if dx < -60 { player.next(userInitiated: true); Haptics.soft() }
                                            else if dx > 60 { player.previous(); Haptics.soft() }
                                        } else if dy > 90 { dismiss() }
                                    }
                            )
                            .onTapGesture {
                                if let lyrics = player.current?.lyrics, !lyrics.isEmpty {
                                    changeSurface(to: .lyrics)
                                }
                            }
                            .frame(maxHeight: .infinity, alignment: .center)

                        // Title Row (No lyrics button here to prevent clipping)
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(player.current?.title ?? "").font(.title2.bold()).tracking(-0.4).lineLimit(1)
                                    .foregroundStyle(.primary)
                                Text(player.current?.artist ?? "").font(.title3).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Spacer(minLength: 12)

                            Button {
                                guard let t = player.current else { return }
                                Haptics.rigid(); withAnimation(.bouncy) {
                                    t.loved.toggle()
                                    try? ctx.save()
                                }
                            } label: {
                                Image(systemName: (player.current?.loved ?? false) ? "heart.fill" : "heart")
                                    .font(.title2)
                                    .foregroundStyle((player.current?.loved ?? false) ? Color.pink : Color.secondary)
                                    .symbolEffect(.bounce, value: player.current?.loved)
                            }.buttonStyle(Pressable(scale: 0.8))

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
                                    if let current = player.current {
                                        trackPendingDeletion = current
                                    }
                                } label: {
                                    Label("Delete from Library", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }.buttonStyle(Pressable(scale: 0.8))
                        }
                        .padding(.horizontal, 34)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 8)
                    .transition(.opacity)
                }

                Scrubber()
                    .padding(.horizontal, 34)
                    .padding(.top, 20)

                HStack(spacing: 44) {
                    Button { player.previous(); Haptics.soft() } label: {
                        Image(systemName: "backward.fill").font(.title)
                    }.buttonStyle(Pressable(scale: 0.85))
                    Button { player.playPause(); Haptics.rigid() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 72))
                            .contentTransition(.symbolEffect(.replace))
                    }.buttonStyle(Pressable(scale: 0.9))
                    Button { player.next(userInitiated: true); Haptics.soft() } label: {
                        Image(systemName: "forward.fill").font(.title)
                    }.buttonStyle(Pressable(scale: 0.85))
                }
                .foregroundStyle(.primary)
                .padding(.top, 4)

                SystemVolumeControl()
                    .padding(.horizontal, 34)
                    .padding(.top, 2)

                // Bottom row with Lyrics Toggle on the far left
                HStack(spacing: 34) {
                    Button {
                        Haptics.soft()
                        changeSurface(to: surface == .lyrics ? .artwork : .lyrics)
                    } label: {
                        Image(systemName: "quote.bubble")
                            .foregroundStyle(surface == .lyrics ? Color.indigo : Color.secondary)
                    }
                    .buttonStyle(Pressable(scale: 0.8))
                    .disabled(player.current?.lyrics?.isEmpty != false)
                    .opacity(player.current?.lyrics?.isEmpty != false ? 0.25 : 1.0)
                    .accessibilityLabel(surface == .lyrics ? "Hide lyrics" : "Show lyrics")
                    .accessibilityValue(surface == .lyrics ? "On" : "Off")

                    Button { Haptics.select(); player.toggleShuffle() } label: {
                        Image(systemName: "shuffle")
                            .foregroundStyle(player.shuffle ? Color.indigo : Color.secondary)
                    }.buttonStyle(Pressable(scale: 0.8))
                    .accessibilityValue(player.shuffle ? "On" : "Off")

                    Button { Haptics.select(); player.autoplay.toggle() } label: {
                        Image(systemName: "infinity")
                            .foregroundStyle(player.autoplay ? Color.indigo : Color.secondary)
                    }.buttonStyle(Pressable(scale: 0.8))
                    .accessibilityLabel("Autoplay")
                    .accessibilityValue(player.autoplay ? "On" : "Off")

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
                            Button("End of Current Song") {
                                player.setSleepTimerEndBlock()
                            }
                            Button("15 Minutes") {
                                player.setSleepTimer(minutes: 15)
                            }
                            Button("30 Minutes") {
                                player.setSleepTimer(minutes: 30)
                            }
                            Button("45 Minutes") {
                                player.setSleepTimer(minutes: 45)
                            }
                            Button("60 Minutes") {
                                player.setSleepTimer(minutes: 60)
                            }
                        }
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: "timer")
                                .font(.title3)
                                .foregroundStyle((player.sleepTimerRemaining != nil || player.sleepTimerEndBlock) ? Color.indigo : Color.secondary)
                            if let remaining = player.sleepTimerRemaining {
                                let mins = Int(remaining) / 60
                                let secs = Int(remaining) % 60
                                Text(String(format: "%d:%02d", mins, secs))
                                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.indigo)
                            } else if player.sleepTimerEndBlock {
                                Text("End")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Color.indigo)
                            }
                        }
                        .frame(height: 32)
                    }

                    Button { Haptics.select(); player.cycleRepeat() } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                            .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.indigo)
                    }.buttonStyle(Pressable(scale: 0.8))
                    .accessibilityValue(player.repeatMode == .off ? "Off" : (player.repeatMode == .one ? "One" : "All"))
                }
                .font(.title3)
                .padding(.top, 2)

                AirPlayButton(tint: .secondaryLabel)
                    .frame(width: 44, height: 30)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.body.weight(.semibold)).padding(14)
                    .foregroundStyle(.primary.opacity(0.85))
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                Haptics.select()
                changeSurface(to: surface == .queue ? .artwork : .queue)
            } label: {
                Image(systemName: "list.bullet").font(.body.weight(.semibold)).padding(14)
                    .foregroundStyle(.primary.opacity(0.85))
            }
            .accessibilityLabel(surface == .queue ? "Hide queue" : "Show queue")
            .accessibilityValue(surface == .queue ? "On" : "Off")
        }
        .sheet(isPresented: $showingPlaylistSheet) {
            if let track = activeMenuTrack {
                AddToPlaylistSheet(track: track)
                    .presentationDetents([.medium, .large])
            }
        }
        }
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

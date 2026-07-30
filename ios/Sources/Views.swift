import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Artwork

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    
    private init() {
        cache.countLimit = 150
    }
    
    func get(for url: URL) -> UIImage? {
        return cache.object(forKey: url as NSURL)
    }
    
    func set(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
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
                    LinearGradient(colors: [Color(hue: 0.66, saturation: 0.45, brightness: 0.52),
                                            Color(hue: 0.78, saturation: 0.5, brightness: 0.34)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .task(id: url) {
            guard let url else { self.image = nil; return }
            if let cached = ImageCache.shared.get(for: url) {
                self.image = cached
                return
            }
            
            let loaded = await Task.detached(priority: .userInteractive) { () -> UIImage? in
                guard let data = try? Data(contentsOf: url),
                      let img = UIImage(data: data) else { return nil }
                _ = img.cgImage?.dataProvider?.data // force decode
                return img
            }.value
            
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

// MARK: - Library

struct LibraryView: View {
    @EnvironmentObject var player: PlayerEngine
    @Query(sort: \Track.dateAdded, order: .reverse) private var tracks: [Track]
    private let cols = [GridItem(.adaptive(minimum: 158, maximum: 210), spacing: 16)]

    @State private var albums: [AlbumGroup] = []
    @State private var recent: [Track] = []
    @State private var loved: [Track] = []
    @State private var mostPlayed: [Track] = []
    @State private var recentlyPlayed: [Track] = []
    @State private var discover: [Track] = []
    @State private var forYou: [Recommender.Mix] = []

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
                        if tracks.count >= 4 { smartMixCard }
                        if !forYou.isEmpty { forYouSection }
                        if !loved.isEmpty { TrackShelf(title: "Loved", tracks: loved) }
                        if mostPlayed.count >= 3 { TrackShelf(title: "Most Played", tracks: mostPlayed) }
                        if discover.count >= 3 { TrackShelf(title: "Discover", tracks: discover) }
                        if recentlyPlayed.count >= 3 { TrackShelf(title: "Recently Played", tracks: recentlyPlayed) }
                        if recent.count >= 4 { TrackShelf(title: "Recently Added", tracks: recent) }
                        albumsSection
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
            }
        }
        .navigationTitle("Library")
        .toolbar { ImportButton() }
        .onChange(of: tracks, initial: true) { _, newTracks in
            albums = LibraryGrouping.albums(newTracks)
            recent = Array(newTracks.prefix(12))
            loved = Smart.loved(newTracks)
            mostPlayed = Smart.mostPlayed(newTracks)
            recentlyPlayed = Smart.recentlyPlayed(newTracks)
            discover = Recommender.discover(newTracks)
            forYou = Recommender.dailyMixes(from: newTracks)
        }
    }

    private var smartMixCard: some View {
        Button {
            Haptics.rigid(); player.playSmart(tracks)
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
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 16)
            .background(
                LinearGradient(colors: [Color.indigo, Color.purple],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .shadow(color: .indigo.opacity(0.35), radius: 12, y: 6)
        }.buttonStyle(Pressable(scale: 0.97))
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.rigid(); player.shuffle = false; player.play(tracks, startAt: 0)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Color.indigo, in: Capsule()).foregroundStyle(.white)
            }.buttonStyle(Pressable())
            Button {
                Haptics.rigid(); shuffleAll()
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.primary)
            }.buttonStyle(Pressable())
        }
    }

    private var forYouSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("For You").font(.title3.bold()).tracking(-0.2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(forYou) { mix in
                        NavigationLink { MixDetailView(mix: mix) } label: { MixCard(mix: mix) }
                            .buttonStyle(Pressable(scale: 0.95))
                    }
                }.padding(.vertical, 2)
            }
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Albums").font(.title3.bold()).tracking(-0.2)
            LazyVGrid(columns: cols, spacing: 18) {
                ForEach(albums) { album in
                    NavigationLink { AlbumDetailView(album: album) } label: { AlbumTile(album: album) }
                        .buttonStyle(Pressable(scale: 0.97))
                }
            }
        }
    }

    private func shuffleAll() {
        player.shuffle = true
        player.play(tracks, startAt: Int.random(in: 0..<max(tracks.count, 1)))
    }
}

/// A horizontal shelf of tappable song cards; tapping plays from that song in the shelf's order.
struct TrackShelf: View {
    let title: String
    let tracks: [Track]
    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold()).tracking(-0.2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { pair in
                        Button {
                            Haptics.light(); player.shuffle = false; player.play(tracks, startAt: pair.offset)
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
                }.padding(.vertical, 2)
            }
        }
    }
}

/// A "Daily Mix" card: representative artwork (or a tinted gradient) with the mix name overlaid.
struct MixCard: View {
    let mix: Recommender.Mix

    private var tint: Color {
        let hue = Double(abs(mix.id.hashValue) % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.6)
    }

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
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.55)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "music.note").font(.title3)
                            .foregroundStyle(.white.opacity(0.85)).padding(12)
                    }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(mix.subtitle.uppercased()).font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text(mix.name).font(.headline).foregroundStyle(.white).lineLimit(2)
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

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    SquareArtwork(url: mix.artwork, corner: 18)
                        .frame(width: 200, height: 200)
                        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                        .padding(.top, 8)
                    Text(mix.name).font(.title2.bold()).tracking(-0.3).multilineTextAlignment(.center)
                    Text("\(mix.tracks.count) song\(mix.tracks.count == 1 ? "" : "s")")
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button { Haptics.rigid(); player.shuffle = false; player.play(mix.tracks, startAt: 0) } label: {
                            Label("Play", systemImage: "play.fill")
                                .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color.indigo, in: Capsule()).foregroundStyle(.white)
                        }.buttonStyle(Pressable())
                        Button { Haptics.rigid(); player.shuffle = true; player.play(mix.tracks, startAt: 0) } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: Capsule())
                        }.buttonStyle(Pressable())
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
            }
            Section {
                ForEach(Array(mix.tracks.enumerated()), id: \.element.id) { pair in
                    Button { Haptics.light(); player.play(mix.tracks, startAt: pair.offset) } label: {
                        TrackRow(track: pair.element, playing: player.current?.id == pair.element.id)
                    }.buttonStyle(.plain).trackMenu(pair.element)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(mix.name).navigationBarTitleDisplayMode(.inline)
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
                    Button { Haptics.rigid(); player.shuffle = false; player.play(album.tracks, startAt: 0) } label: {
                        Label("Play", systemImage: "play.fill")
                            .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.indigo, in: Capsule()).foregroundStyle(.white)
                    }.buttonStyle(Pressable())
                    Button { Haptics.rigid(); player.shuffle = true; player.play(album.tracks, startAt: 0) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                    }.buttonStyle(Pressable())
                }.padding(.horizontal, 4)

                VStack(spacing: 0) {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { pair in
                        Button {
                            Haptics.light(); player.play(album.tracks, startAt: pair.offset)
                        } label: {
                            TrackRow(track: pair.element, index: pair.offset + 1,
                                     playing: player.current?.id == pair.element.id)
                        }.buttonStyle(Pressable(scale: 0.985)).trackMenu(pair.element)
                        if pair.offset < album.tracks.count - 1 {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle(album.name).navigationBarTitleDisplayMode(.inline)
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
            } else {
                List {
                    ForEach(Array(results.enumerated()), id: \.element.id) { pair in
                        Button { Haptics.light(); player.play(results, startAt: pair.offset) } label: {
                            TrackRow(track: pair.element, playing: player.current?.id == pair.element.id)
                        }.buttonStyle(.plain).trackMenu(pair.element)
                    }
                }.listStyle(.plain)
            }
        }
        .searchable(text: $q, prompt: "Songs, artists, albums")
        .navigationTitle("Search")
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
        let existing = Set(tracks.map {
            let filename = ($0.relPath as NSString).lastPathComponent
            return "\($0.album.lowercased())/\(filename.lowercased())"
        })
        await client.sync(host: host, pin: pin, existingFilenames: existing, into: ctx)
        if client.progress >= 1 { Haptics.success() }
    }
}

// MARK: - Floating mini-player

struct MiniPlayer: View {
    @EnvironmentObject var player: PlayerEngine
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                Capsule().fill(Color.indigo)
                    .frame(width: max(0, geo.size.width * player.progress), height: 2)
                    .animation(.linear(duration: 0.3), value: player.progress)
            }.frame(height: 2)

            HStack(spacing: 12) {
                SquareArtwork(url: player.current?.artworkURL, corner: 8)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.current?.title ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(player.current?.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { Haptics.soft(); player.playPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 30, height: 30)
                }.buttonStyle(Pressable(scale: 0.85))
                Button { Haptics.soft(); player.next(userInitiated: true) } label: {
                    Image(systemName: "forward.fill").font(.body).frame(width: 30, height: 30)
                }.buttonStyle(Pressable(scale: 0.85))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        .padding(.horizontal, 10)
    }
}

// MARK: - Now Playing

struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @State private var showingQueue = false
    @State private var showingPlaylistSheet = false
    @State private var activeMenuTrack: Track? = nil

    var body: some View {
            VStack(spacing: 0) {
                Capsule().fill(.white.opacity(0.5)).frame(width: 40, height: 5).padding(.top, 10)

                Spacer(minLength: 16)

                SquareArtwork(url: player.current?.artworkURL, corner: 22)
                    .frame(maxWidth: 340, maxHeight: 340)
                    .frame(maxWidth: .infinity)
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
                    .scaleEffect(player.isPlaying ? 1.0 : 0.84)
                    .animation(.bouncy, value: player.isPlaying)

                Spacer(minLength: 16)

                VStack(spacing: 20) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(player.current?.title ?? "").font(.title2.bold()).tracking(-0.4).lineLimit(1)
                                .foregroundStyle(.white)
                            Text(player.current?.artist ?? "").font(.title3).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
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
                                .foregroundStyle((player.current?.loved ?? false) ? Color.pink : .white.opacity(0.8))
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
                                    deleteTrack(current)
                                }
                            } label: {
                                Label("Delete from Library", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title2)
                                .foregroundStyle(.white.opacity(0.8))
                        }.buttonStyle(Pressable(scale: 0.8))
                    }

                    Scrubber()

                    HStack(spacing: 44) {
                        Button { Haptics.soft(); player.previous() } label: {
                            Image(systemName: "backward.fill").font(.title)
                        }.buttonStyle(Pressable(scale: 0.85))
                        Button { Haptics.rigid(); player.playPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 72))
                                .contentTransition(.symbolEffect(.replace))
                        }.buttonStyle(Pressable(scale: 0.9))
                        Button { Haptics.soft(); player.next(userInitiated: true) } label: {
                            Image(systemName: "forward.fill").font(.title)
                        }.buttonStyle(Pressable(scale: 0.85))
                    }
                    .foregroundStyle(.white)
                    .padding(.top, 4)

                    HStack(spacing: 34) {
                        Button { Haptics.select(); player.toggleShuffle() } label: {
                            Image(systemName: "shuffle")
                                .foregroundStyle(player.shuffle ? Color.indigo : .white.opacity(0.6))
                        }.buttonStyle(Pressable(scale: 0.8))
                        Button { Haptics.select(); player.autoplay.toggle() } label: {
                            Image(systemName: "infinity")
                                .foregroundStyle(player.autoplay ? Color.indigo : .white.opacity(0.6))
                        }.buttonStyle(Pressable(scale: 0.8))
                        
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
                                    .foregroundStyle((player.sleepTimerRemaining != nil || player.sleepTimerEndBlock) ? Color.indigo : .white.opacity(0.6))
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
                                .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.6) : Color.indigo)
                        }.buttonStyle(Pressable(scale: 0.8))
                    }
                    .font(.title3)
                    .padding(.top, 2)
                }
                .padding(.horizontal, 34)

                Spacer(minLength: 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                AmbientBackground(url: player.current?.artworkURL)
                    .animation(.easeInOut(duration: 0.5), value: player.current?.id)
            )
        .preferredColorScheme(.dark)
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.body.weight(.semibold)).padding(14)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { Haptics.select(); showingQueue = true } label: {
                Image(systemName: "list.bullet").font(.body.weight(.semibold)).padding(14)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .sheet(isPresented: $showingQueue) {
            QueueView()
        }
        .sheet(isPresented: $showingPlaylistSheet) {
            if let track = activeMenuTrack {
                AddToPlaylistSheet(track: track)
                    .presentationDetents([.medium, .large])
            }
        }
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
    @State private var dragFrac: Double? = nil

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let frac = dragFrac ?? player.progress
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white).frame(width: max(0, geo.size.width * frac))
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
                Text(timeStr((dragFrac ?? player.progress) * player.duration))
                Spacer()
                Text("-" + timeStr(max(0, player.duration - (dragFrac ?? player.progress) * player.duration)))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
        }
    }

    private func timeStr(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let i = Int(s); return String(format: "%d:%02d", i / 60, i % 60)
    }
}

// MARK: - Queue Viewer

struct QueueView: View {
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                if let current = player.current {
                    Section("Now Playing") {
                        QueueRow(track: current, active: true)
                    }
                }
                
                let upcoming = player.fullQueue.enumerated().filter { $0.offset > player.currentQueueIndex }
                if !upcoming.isEmpty {
                    Section("Next Up") {
                        ForEach(upcoming, id: \.element.id) { index, track in
                            Button {
                                Haptics.light()
                                player.skipToQueueIndex(index)
                            } label: {
                                QueueRow(track: track, active: false)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { indexSet in
                            for offset in indexSet {
                                let targetIndex = offset + player.currentQueueIndex + 1
                                player.removeFromQueue(at: targetIndex)
                            }
                        }
                    }
                } else {
                    Section("Next Up") {
                        Text("Queue is empty").foregroundStyle(.secondary).font(.callout)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Playing Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
                    .foregroundStyle(active ? Color.indigo : .primary)
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
                    .foregroundStyle(Color.indigo)
                    .symbolEffect(.variableColor, options: .repeating)
            }
        }
        .padding(.vertical, 2)
    }
}

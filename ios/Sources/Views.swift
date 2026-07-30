import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Artwork

struct ArtworkView: View {
    let url: URL?
    var body: some View {
        if let url, let img = UIImage(contentsOfFile: url.path) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [.indigo.opacity(0.7), .purple.opacity(0.4)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").foregroundStyle(.white.opacity(0.85))
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
                    Task { _ = await Importer.importFiles(urls, into: ctx) }
                }
            }
    }
}

// MARK: - Library

struct LibraryView: View {
    @EnvironmentObject var player: PlayerEngine
    @Query(sort: \Track.dateAdded, order: .reverse) private var tracks: [Track]
    private let cols = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    var albums: [AlbumGroup] { LibraryGrouping.albums(tracks) }

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableView {
                    Label("No music yet", systemImage: "music.note")
                } description: {
                    Text("Sync from your Mac, or import audio files.")
                } actions: {
                    ImportButton(label: "Import files")
                }
            } else {
                ScrollView {
                    HStack {
                        Button { shuffleAll() } label: { Label("Shuffle", systemImage: "shuffle") }
                            .buttonStyle(.borderedProminent)
                        Button { player.play(tracks, startAt: 0) } label: { Label("Play all", systemImage: "play.fill") }
                            .buttonStyle(.bordered)
                        Spacer()
                    }.padding(.horizontal).padding(.top, 8)

                    LazyVGrid(columns: cols, spacing: 16) {
                        ForEach(albums) { album in
                            NavigationLink { AlbumDetailView(album: album) } label: { AlbumTile(album: album) }
                                .buttonStyle(.plain)
                        }
                    }.padding()
                }
            }
        }
        .navigationTitle("Library")
        .toolbar { ImportButton() }
    }

    private func shuffleAll() {
        player.shuffle = true
        player.play(tracks, startAt: Int.random(in: 0..<max(tracks.count, 1)))
    }
}

struct AlbumTile: View {
    let album: AlbumGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: album.artworkURL)
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(album.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct AlbumDetailView: View {
    let album: AlbumGroup
    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ArtworkView(url: album.artworkURL)
                        .frame(width: 200, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    Text(album.name).font(.title3.bold()).multilineTextAlignment(.center)
                    Text(album.artist).foregroundStyle(.secondary)
                    HStack {
                        Button { player.shuffle = false; player.play(album.tracks, startAt: 0) } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent)
                        Button { player.shuffle = true; player.play(album.tracks, startAt: 0) } label: {
                            Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Array(album.tracks.enumerated()), id: \.element.id) { pair in
                    TrackRow(track: pair.element, playing: player.current?.id == pair.element.id)
                        .contentShape(Rectangle())
                        .onTapGesture { player.play(album.tracks, startAt: pair.offset) }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.name).navigationBarTitleDisplayMode(.inline)
    }
}

struct TrackRow: View {
    let track: Track
    var playing = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: playing ? "speaker.wave.2.fill" : "music.note")
                .font(.caption).foregroundStyle(playing ? .indigo : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1).fontWeight(playing ? .semibold : .regular)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if track.loved { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink) }
            Text(track.durationText).font(.caption).foregroundStyle(.secondary)
        }
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
        List {
            ForEach(Array(results.enumerated()), id: \.element.id) { pair in
                TrackRow(track: pair.element, playing: player.current?.id == pair.element.id)
                    .contentShape(Rectangle())
                    .onTapGesture { player.play(results, startAt: pair.offset) }
            }
        }
        .listStyle(.plain)
        .searchable(text: $q, prompt: "Songs, artists, albums")
        .navigationTitle("Search")
    }
}

// MARK: - Sync (placeholder for Wi-Fi sync; import for now)

struct SyncView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 44)).foregroundStyle(.indigo)
            Text("Sync from your Mac").font(.title3.bold())
            Text("Wi‑Fi sync from the Snag Mac app is coming next.\nFor now, import audio files from Files or AirDrop.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
            ImportButton(label: "Import files")
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Sync")
    }
}

// MARK: - Mini-player + Now Playing

struct MiniPlayer: View {
    @EnvironmentObject var player: PlayerEngine
    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: player.current?.artworkURL)
                .frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(player.current?.title ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
                Text(player.current?.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { player.playPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            Button { player.next(userInitiated: true) } label: { Image(systemName: "forward.fill") }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            Capsule().fill(.secondary).frame(width: 40, height: 5).padding(.top, 8)
            ArtworkView(url: player.current?.artworkURL)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(radius: 16, y: 8)
                .padding(.horizontal, 30)

            VStack(spacing: 4) {
                Text(player.current?.title ?? "").font(.title2.bold()).lineLimit(1)
                Text(player.current?.artist ?? "").foregroundStyle(.secondary)
            }.padding(.horizontal)

            VStack(spacing: 4) {
                Slider(value: Binding(get: { player.progress }, set: { player.seek(toFraction: $0) }))
                HStack {
                    Text(timeStr(player.elapsed)).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(timeStr(player.duration)).font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 30)

            HStack(spacing: 40) {
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                Button { player.playPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64))
                }
                Button { player.next(userInitiated: true) } label: { Image(systemName: "forward.fill").font(.title) }
            }

            HStack(spacing: 50) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle").foregroundStyle(player.shuffle ? Color.indigo : Color.secondary)
                }
                Button { if let t = player.current { t.loved.toggle() } } label: {
                    Image(systemName: (player.current?.loved ?? false) ? "heart.fill" : "heart")
                        .foregroundStyle((player.current?.loved ?? false) ? Color.pink : Color.secondary)
                }
                Button { player.cycleRepeat() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.indigo)
                }
            }.font(.title3)

            Spacer()
        }
        .padding(.bottom, 30)
        .presentationDragIndicator(.hidden)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { Image(systemName: "chevron.down").padding() }
                .foregroundStyle(.secondary)
        }
    }

    private func timeStr(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "0:00" }
        let i = Int(s); return String(format: "%d:%02d", i / 60, i % 60)
    }
}

import SwiftUI
import SwiftData
import AVKit

// MARK: - Library "Browse" section (rows into Songs / Artists / Genres)

struct BrowseRow: View {
    let icon: String
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.body).foregroundStyle(.indigo).frame(width: 26)
            Text(title).font(.body.weight(.medium))
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

// MARK: - All Songs (sortable)

enum SongSort: String, CaseIterable, Identifiable {
    case title = "Title", artist = "Artist", recent = "Recently Added", plays = "Most Played"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .title: return "textformat"
        case .artist: return "music.mic"
        case .recent: return "clock"
        case .plays: return "flame"
        }
    }
}

struct AllSongsView: View {
    @EnvironmentObject var player: PlayerEngine
    @Query private var tracks: [Track]
    @AppStorage("songSort") private var sortRaw = SongSort.title.rawValue

    private var sort: SongSort { SongSort(rawValue: sortRaw) ?? .title }

    private var sorted: [Track] {
        switch sort {
        case .title:  return tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: return tracks.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .recent: return tracks.sorted { $0.dateAdded > $1.dateAdded }
        case .plays:  return tracks.sorted { $0.playCount > $1.playCount }
        }
    }

    var body: some View {
        List {
            ForEach(Array(sorted.enumerated()), id: \.element.id) { pair in
                Button { Haptics.light(); player.play(sorted, startAt: pair.offset) } label: {
                    TrackRow(track: pair.element, playing: player.current?.id == pair.element.id)
                }
                .buttonStyle(.plain)
                .trackMenu(pair.element)
                .trackSwipeActions(pair.element)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Songs").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            HStack {
                Button { Haptics.rigid(); player.shuffle = true; player.play(sorted, startAt: Int.random(in: 0..<max(sorted.count, 1))) } label: {
                    Image(systemName: "shuffle")
                }.disabled(sorted.isEmpty)
                Menu {
                    Picker("Sort", selection: $sortRaw) {
                        ForEach(SongSort.allCases) { s in
                            Label(s.rawValue, systemImage: s.systemImage).tag(s.rawValue)
                        }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
    }
}

// MARK: - Artists

struct ArtistsView: View {
    @Query private var tracks: [Track]
    private var artists: [ArtistGroup] { LibraryGrouping.artists(tracks) }

    var body: some View {
        List(artists) { artist in
            NavigationLink { ArtistDetailView(artist: artist) } label: {
                HStack(spacing: 12) {
                    SquareArtwork(url: artist.artworkURL, corner: 24)
                        .frame(width: 48, height: 48).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name).font(.body.weight(.medium)).lineLimit(1)
                        Text("\(artist.tracks.count) song\(artist.tracks.count == 1 ? "" : "s") · \(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Artists").navigationBarTitleDisplayMode(.inline)
    }
}

struct ArtistDetailView: View {
    let artist: ArtistGroup
    @EnvironmentObject var player: PlayerEngine
    private let cols = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]
    private var albums: [AlbumGroup] { LibraryGrouping.albums(artist.tracks) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Button { Haptics.rigid(); player.shuffle = false; player.play(artist.tracks, startAt: 0) } label: {
                        Label("Play", systemImage: "play.fill")
                            .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.indigo, in: Capsule()).foregroundStyle(.white)
                    }.buttonStyle(Pressable())
                    Button { Haptics.rigid(); player.shuffle = true; player.play(artist.tracks, startAt: 0) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                    }.buttonStyle(Pressable())
                }

                Text("Albums").font(.title3.bold()).tracking(-0.2)
                LazyVGrid(columns: cols, spacing: 18) {
                    ForEach(albums) { album in
                        NavigationLink { AlbumDetailView(album: album) } label: { AlbumTile(album: album) }
                            .buttonStyle(Pressable(scale: 0.97))
                    }
                }
            }
            .padding()
        }
        .navigationTitle(artist.name).navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Genres

struct GenresView: View {
    @Query private var tracks: [Track]
    private var genres: [GenreGroup] { LibraryGrouping.genres(tracks) }

    var body: some View {
        List(genres) { genre in
            NavigationLink { GenreDetailView(genre: genre) } label: {
                HStack(spacing: 12) {
                    SquareArtwork(url: genre.artworkURL, corner: 10).frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(genre.name).font(.body.weight(.medium)).lineLimit(1)
                        Text("\(genre.tracks.count) song\(genre.tracks.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Genres").navigationBarTitleDisplayMode(.inline)
    }
}

struct GenreDetailView: View {
    let genre: GenreGroup
    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Button { Haptics.rigid(); player.shuffle = false; player.play(genre.tracks, startAt: 0) } label: {
                        Label("Play", systemImage: "play.fill")
                            .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.indigo, in: Capsule()).foregroundStyle(.white)
                    }.buttonStyle(Pressable())
                    Button { Haptics.rigid(); player.shuffle = true; player.play(genre.tracks, startAt: 0) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                    }.buttonStyle(Pressable())
                }
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Array(genre.tracks.enumerated()), id: \.element.id) { pair in
                    Button { Haptics.light(); player.play(genre.tracks, startAt: pair.offset) } label: {
                        TrackRow(track: pair.element, playing: player.current?.id == pair.element.id)
                    }
                    .buttonStyle(.plain)
                    .trackMenu(pair.element)
                    .trackSwipeActions(pair.element)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(genre.name).navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - AirPlay / output route picker

struct AirPlayButton: UIViewRepresentable {
    var tint: UIColor = .white
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = tint
        v.activeTintColor = UIColor(Color.indigo)
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

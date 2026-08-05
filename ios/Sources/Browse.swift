import SwiftUI
import SwiftData
import AVKit
import MediaPlayer

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
    @AppStorage("collectionLayout.songs") private var layout: CollectionLayoutMode = .list

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
        Group {
            if layout == .list {
                List {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { pair in
                        Button { player.play(sorted, startAt: pair.offset); Haptics.light() } label: {
                            TrackRow(track: pair.element, playing: player.current?.id == pair.element.id)
                        }
                        .buttonStyle(.plain)
                        .trackMenu(pair.element)
                        .trackSwipeActions(pair.element)
                    }
                }
                .listStyle(.plain)
            } else {
                TrackGridView(tracks: sorted, currentTrackID: player.current?.id) { index in
                    player.play(sorted, startAt: index)
                }
            }
        }
        .appScreenBackground()
        .navigationTitle("Songs").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            HStack {
                CollectionLayoutPicker(selection: $layout)
                Button { player.playShuffled(sorted); Haptics.rigid() } label: {
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
    @AppStorage("collectionLayout.artists") private var layout: CollectionLayoutMode = .list
    private var artists: [ArtistGroup] { LibraryGrouping.artists(tracks) }

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        Group {
            if layout == .list {
                List(artists) { artist in
                    NavigationLink { ArtistDetailView(artist: artist) } label: {
                        ArtistListLabel(artist: artist)
                    }
                }
                .listStyle(.plain)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(artists) { artist in
                            NavigationLink { ArtistDetailView(artist: artist) } label: {
                                VStack(spacing: 8) {
                                    SquareArtwork(url: artist.artworkURL, corner: 80).clipShape(Circle())
                                    Text(artist.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text("\(artist.tracks.count) songs").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(Pressable(scale: 0.97))
                        }
                    }
                    .padding(.horizontal, AppLayout.pageInset)
                    .padding(.top, 12)
                    .padding(.bottom, AppLayout.scrollEndPadding)
                }
            }
        }
        .appScreenBackground()
        .navigationTitle("Artists").navigationBarTitleDisplayMode(.inline)
        .toolbar { CollectionLayoutPicker(selection: $layout) }
    }
}

private struct ArtistListLabel: View {
    let artist: ArtistGroup

    var body: some View {
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

struct ArtistDetailView: View {
    let artist: ArtistGroup
    @EnvironmentObject var player: PlayerEngine
    private let cols = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]
    private var albums: [AlbumGroup] { LibraryGrouping.albums(artist.tracks) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Button { player.shuffle = false; player.play(artist.tracks, startAt: 0); Haptics.rigid() } label: {
                        Label("Play", systemImage: "play.fill")
                    }.buttonStyle(PrimaryActionButtonStyle())
                    Button { player.playShuffled(artist.tracks); Haptics.rigid() } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }.buttonStyle(SecondaryActionButtonStyle())
                }
                .groupedGlassEffects()

                SectionTitle(title: "Albums")
                LazyVGrid(columns: cols, spacing: 18) {
                    ForEach(albums) { album in
                        NavigationLink { AlbumDetailView(album: album) } label: { AlbumTile(album: album) }
                            .buttonStyle(Pressable(scale: 0.97))
                    }
                }
            }
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.top, AppLayout.pageInset)
            .padding(.bottom, AppLayout.scrollEndPadding)
        }
        .appScreenBackground()
        .navigationTitle(artist.name).navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Genres

struct GenresView: View {
    @Query private var tracks: [Track]
    @AppStorage("collectionLayout.genres") private var layout: CollectionLayoutMode = .list
    private var genres: [GenreGroup] { LibraryGrouping.genres(tracks) }

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        Group {
            if layout == .list {
                List(genres) { genre in
                    NavigationLink { GenreDetailView(genre: genre) } label: {
                        GenreListLabel(genre: genre)
                    }
                }
                .listStyle(.plain)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(genres) { genre in
                            NavigationLink { GenreDetailView(genre: genre) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    SquareArtwork(url: genre.artworkURL, corner: 14)
                                    Text(genre.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text("\(genre.tracks.count) songs").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(Pressable(scale: 0.97))
                        }
                    }
                    .padding(.horizontal, AppLayout.pageInset)
                    .padding(.top, 12)
                    .padding(.bottom, AppLayout.scrollEndPadding)
                }
            }
        }
        .appScreenBackground()
        .navigationTitle("Genres").navigationBarTitleDisplayMode(.inline)
        .toolbar { CollectionLayoutPicker(selection: $layout) }
    }
}

private struct GenreListLabel: View {
    let genre: GenreGroup

    var body: some View {
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

struct GenreDetailView: View {
    let genre: GenreGroup
    @EnvironmentObject var player: PlayerEngine
    @AppStorage("collectionLayout.genreTracks") private var layout: CollectionLayoutMode = .list

    var body: some View {
        Group {
            if layout == .list {
                List {
                    Section { playButtons }
                    Section {
                        ForEach(Array(genre.tracks.enumerated()), id: \.element.id) { pair in
                            Button { player.play(genre.tracks, startAt: pair.offset); Haptics.light() } label: {
                                TrackRow(track: pair.element, playing: player.current?.id == pair.element.id)
                            }
                            .buttonStyle(.plain)
                            .trackMenu(pair.element)
                            .trackSwipeActions(pair.element)
                        }
                    }
                }
                .listStyle(.plain)
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        playButtons
                        TrackGridContent(tracks: genre.tracks, currentTrackID: player.current?.id) { index in
                            player.play(genre.tracks, startAt: index)
                        }
                    }
                    .padding(.horizontal, AppLayout.pageInset)
                    .padding(.top, 12)
                    .padding(.bottom, AppLayout.scrollEndPadding)
                }
            }
        }
        .appScreenBackground()
        .navigationTitle(genre.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { CollectionLayoutPicker(selection: $layout) }
    }

    private var playButtons: some View {
        HStack(spacing: 12) {
            Button { player.shuffle = false; player.play(genre.tracks, startAt: 0); Haptics.rigid() } label: {
                Label("Play", systemImage: "play.fill")
            }.buttonStyle(PrimaryActionButtonStyle())
            Button { player.playShuffled(genre.tracks); Haptics.rigid() } label: {
                Label("Shuffle", systemImage: "shuffle")
            }.buttonStyle(SecondaryActionButtonStyle())
        }
        .groupedGlassEffects()
        .listRowSeparator(.hidden)
    }
}

// MARK: - AirPlay / output route picker

struct AirPlayButton: UIViewRepresentable {
    var tint: UIColor = .label
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = tint
        v.activeTintColor = UIColor(Color.indigo)
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - System volume

/// The sanctioned system-volume control. It follows hardware-button changes
/// and the active output route instead of applying a second gain to the track.
struct SystemVolumeControl: View {
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.caption.weight(.medium))
                .frame(width: 16, height: 44, alignment: .center)
                .accessibilityHidden(true)
            SystemVolumeSlider()
                .frame(maxWidth: .infinity)
                .frame(height: 44, alignment: .center)
                .accessibilityLabel("Volume")
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption.weight(.medium))
                .frame(width: 16, height: 44, alignment: .center)
                .accessibilityHidden(true)
        }
        .frame(height: 44, alignment: .center)
        .foregroundStyle(.secondary)
    }
}

private struct SystemVolumeSlider: View {
#if targetEnvironment(simulator)
    @State private var previewVolume = 0.55

    var body: some View {
        Slider(value: $previewVolume, in: 0...1)
            .tint(.primary)
            .frame(height: 32, alignment: .center)
            .accessibilityHint("System volume changes require a physical iPhone")
    }
#else
    var body: some View {
        DeviceSystemVolumeSlider()
            .frame(height: 23)
            .offset(y: 2.7)
            .frame(height: 32, alignment: .center)
    }
#endif
}

#if !targetEnvironment(simulator)
private final class StyledVolumeView: MPVolumeView {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let slider = subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.minimumTrackTintColor = .label
        slider.maximumTrackTintColor = .tertiaryLabel
        slider.tintColor = .label
        // AirPlay has a dedicated AVRoutePickerView in the player chrome.
        // Keep MPVolumeView focused on volume without using its deprecated
        // route-button configuration API.
        subviews.compactMap { $0 as? UIButton }.forEach { $0.isHidden = true }
    }
}

private struct DeviceSystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = StyledVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
#endif

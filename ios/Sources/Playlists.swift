import SwiftUI
import SwiftData

// MARK: - Playlists list

struct PlaylistsView: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \Playlist.createdAt, order: .reverse) private var playlists: [Playlist]
    @Query private var tracks: [Track]

    @State private var showingNew = false
    @State private var newName = ""
    @AppStorage("collectionLayout.playlists") private var layout: CollectionLayoutMode = .list

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        Group {
            if playlists.isEmpty {
                ContentUnavailableView {
                    Label("No playlists", systemImage: "music.note.list")
                } description: {
                    Text("Make a playlist, then add songs from any track's ⋯ menu.")
                } actions: {
                    Button("New Playlist") { showingNew = true }.buttonStyle(.borderedProminent)
                }
            } else {
                if layout == .list {
                    List {
                        ForEach(playlists) { pl in
                            NavigationLink { PlaylistDetailView(playlist: pl) } label: {
                                PlaylistRow(playlist: pl, tracks: tracks)
                            }
                        }
                        .onDelete { idx in
                            idx.map { playlists[$0] }.forEach(ctx.delete)
                            try? ctx.save(); Haptics.rigid()
                        }
                    }
                    .listStyle(.plain)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(playlists) { playlist in
                                NavigationLink { PlaylistDetailView(playlist: playlist) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        PlaylistArtwork(tracks: playlist.tracks(in: tracks))
                                        Text(playlist.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text("\(playlist.trackIDs.count) songs").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(Pressable(scale: 0.97))
                                .contextMenu {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        ctx.delete(playlist); try? ctx.save(); Haptics.rigid()
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, AppLayout.pageInset)
                        .padding(.top, 12)
                        .padding(.bottom, AppLayout.scrollEndPadding)
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.large)
        .appScreenBackground()
        .toolbar {
            HStack {
                CollectionLayoutPicker(selection: $layout)
                Button { showingNew = true } label: { Image(systemName: "plus") }
            }
        }
        .alert("New Playlist", isPresented: $showingNew) {
            TextField("Name", text: $newName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        ctx.insert(Playlist(name: name)); try? ctx.save()
        newName = ""; Haptics.success()
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    let tracks: [Track]
    private var items: [Track] { playlist.tracks(in: tracks) }
    var body: some View {
        HStack(spacing: 12) {
            PlaylistArtwork(tracks: items).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).font(.body.weight(.medium)).lineLimit(1)
                Text("\(items.count) song\(items.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

/// A playlist thumbnail: the first track's cover, or a music-note tile.
struct PlaylistArtwork: View {
    let tracks: [Track]
    var body: some View {
        SquareArtwork(url: tracks.first(where: { $0.artworkURL != nil })?.artworkURL, corner: 10)
    }
}

// MARK: - Playlist detail

struct PlaylistDetailView: View {
    @Bindable var playlist: Playlist
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.modelContext) private var ctx
    @Query private var allTracks: [Track]
    @AppStorage("collectionLayout.playlistTracks") private var layout: CollectionLayoutMode = .list

    private var items: [Track] { playlist.tracks(in: allTracks) }

    var body: some View {
        Group {
            if layout == .list { playlistList } else { playlistGrid }
        }
        .appScreenBackground()
        .navigationTitle(playlist.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            CollectionLayoutPicker(selection: $layout)
            if layout == .list { EditButton() }
        }
    }

    private var playlistList: some View {
        List {
            Section {
                playlistHeader
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
            }

            Section {
                ForEach(Array(items.enumerated()), id: \.element.id) { pair in
                    Button { player.play(items, startAt: pair.offset); Haptics.light() } label: {
                        TrackRow(track: pair.element, playing: player.current?.id == pair.element.id)
                    }.buttonStyle(.plain).trackMenu(pair.element)
                }
                .onMove { from, to in
                    playlist.trackIDs.move(fromOffsets: from, toOffset: to); try? ctx.save()
                }
                .onDelete { idx in
                    let ids = idx.map { items[$0].id }
                    playlist.trackIDs.removeAll { ids.contains($0) }
                    try? ctx.save(); Haptics.light()
                }
            }
        }
        .listStyle(.plain)
    }

    private var playlistGrid: some View {
        ScrollView {
            VStack(spacing: 20) {
                playlistHeader
                TrackGridContent(tracks: items, currentTrackID: player.current?.id) { index in
                    player.play(items, startAt: index)
                }
            }
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.bottom, AppLayout.scrollEndPadding)
        }
    }

    private var playlistHeader: some View {
        VStack(spacing: 14) {
            PlaylistArtwork(tracks: items)
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                .padding(.top, 8)
            Text(playlist.name).font(.title2.bold()).tracking(-0.3)
            Text("\(items.count) song\(items.count == 1 ? "" : "s")")
                .font(.subheadline).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("Add songs from any track's More menu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button { player.shuffle = false; player.play(items, startAt: 0); Haptics.rigid() } label: {
                    Label("Play", systemImage: "play.fill")
                }.buttonStyle(PrimaryActionButtonStyle()).disabled(items.isEmpty)
                Button { player.playShuffled(items); Haptics.rigid() } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }.buttonStyle(SecondaryActionButtonStyle()).disabled(items.isEmpty)
            }
            .groupedGlassEffects()
        }
    }
}

// MARK: - Add to playlist

/// Context menu + sheet to drop a track into a playlist. Attach with `.trackMenu(track)`.
struct TrackMenu: ViewModifier {
    let track: Track
    @Environment(\.modelContext) private var ctx
    @State private var picking = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button { PlayerEngine.shared.playNext(track); Haptics.light() } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button { PlayerEngine.shared.addToQueue(track); Haptics.light() } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }
                Divider()
                Button { PlayerEngine.shared.playSimilar(to: track); Haptics.rigid() } label: {
                    Label("More Like This", systemImage: "wand.and.stars")
                }
                Button { track.loved.toggle(); try? ctx.save(); Haptics.rigid() } label: {
                    Label(track.loved ? "Unlove" : "Love", systemImage: track.loved ? "heart.slash" : "heart")
                }
                Button { picking = true } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }
            }
            .sheet(isPresented: $picking) {
                AddToPlaylistSheet(track: track)
                    .presentationDetents([.medium, .large])
            }
    }
}

/// Leading/trailing swipe actions for a track row in a List (Play Next / Queue / Love).
struct TrackSwipeActions: ViewModifier {
    let track: Track
    @Environment(\.modelContext) private var ctx
    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { PlayerEngine.shared.playNext(track); Haptics.light() } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }.tint(.indigo)
                Button { PlayerEngine.shared.addToQueue(track); Haptics.light() } label: {
                    Label("Queue", systemImage: "text.append")
                }.tint(.purple)
            }
            .swipeActions(edge: .trailing) {
                Button { track.loved.toggle(); try? ctx.save(); Haptics.rigid() } label: {
                    Label("Love", systemImage: track.loved ? "heart.slash" : "heart")
                }.tint(.pink)
            }
    }
}

extension View {
    func trackMenu(_ track: Track) -> some View { modifier(TrackMenu(track: track)) }
    func trackSwipeActions(_ track: Track) -> some View { modifier(TrackSwipeActions(track: track)) }
}

struct AddToPlaylistSheet: View {
    let track: Track
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Playlist.createdAt, order: .reverse) private var playlists: [Playlist]
    @Query private var allTracks: [Track]

    @State private var showingNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Button { showingNew = true } label: {
                    Label("New Playlist", systemImage: "plus.circle.fill")
                }
                ForEach(playlists) { pl in
                    Button { add(to: pl) } label: {
                        HStack {
                            PlaylistArtwork(tracks: pl.tracks(in: allTracks)).frame(width: 40, height: 40)
                            VStack(alignment: .leading) {
                                Text(pl.name).foregroundStyle(.primary)
                                Text("\(pl.trackIDs.count) song\(pl.trackIDs.count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if pl.trackIDs.contains(track.id) {
                                Image(systemName: "checkmark").foregroundStyle(.indigo)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .alert("New Playlist", isPresented: $showingNew) {
                TextField("Name", text: $newName)
                Button("Create") { createAndAdd() }
                Button("Cancel", role: .cancel) { newName = "" }
            }
        }
    }

    private func add(to pl: Playlist) {
        if !pl.trackIDs.contains(track.id) { pl.trackIDs.append(track.id); try? ctx.save() }
        Haptics.success(); dismiss()
    }

    private func createAndAdd() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let pl = Playlist(name: name, trackIDs: [track.id])
        ctx.insert(pl); try? ctx.save()
        newName = ""; Haptics.success(); dismiss()
    }
}

import SwiftUI
import SwiftData

// MARK: - Playlists list

struct PlaylistsView: View {
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.modelContext) private var ctx
    @Query(sort: \Playlist.createdAt, order: .reverse) private var playlists: [Playlist]
    @Query private var tracks: [Track]

    @State private var showingNew = false
    @State private var newName = ""

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
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            Button { showingNew = true } label: { Image(systemName: "plus") }
        }
        .alert("New Playlist", isPresented: $showingNew) {
            TextField("Name", text: $newName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
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

    private var items: [Track] { playlist.tracks(in: allTracks) }

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    PlaylistArtwork(tracks: items)
                        .frame(width: 200, height: 200)
                        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                        .padding(.top, 8)
                    Text(playlist.name).font(.title2.bold()).tracking(-0.3)
                    Text("\(items.count) song\(items.count == 1 ? "" : "s")")
                        .font(.subheadline).foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button { Haptics.rigid(); player.shuffle = false; player.play(items, startAt: 0) } label: {
                            Label("Play", systemImage: "play.fill")
                                .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color.indigo, in: Capsule()).foregroundStyle(.white)
                        }.buttonStyle(Pressable()).disabled(items.isEmpty)
                        Button { Haptics.rigid(); player.shuffle = true; player.play(items, startAt: 0) } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: Capsule())
                        }.buttonStyle(Pressable()).disabled(items.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
            }

            Section {
                ForEach(Array(items.enumerated()), id: \.element.id) { pair in
                    Button { Haptics.light(); player.play(items, startAt: pair.offset) } label: {
                        TrackRow(track: pair.element, playing: player.current?.id == pair.element.id)
                    }.buttonStyle(.plain)
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
        .navigationTitle(playlist.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
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
                Button { Haptics.rigid(); PlayerEngine.shared.playSimilar(to: track) } label: {
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

extension View {
    func trackMenu(_ track: Track) -> some View { modifier(TrackMenu(track: track)) }
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
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let pl = Playlist(name: name, trackIDs: [track.id])
        ctx.insert(pl); try? ctx.save()
        newName = ""; Haptics.success(); dismiss()
    }
}

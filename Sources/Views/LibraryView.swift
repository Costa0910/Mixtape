import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: SettingsStore

    @State private var search = ""
    @State private var selected: AlbumFolder?

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)]

    private var filtered: [AlbumFolder] {
        search.isEmpty ? state.albums
            : state.albums.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    ScreenHeader(title: "Library",
                                 subtitle: "\(state.albums.count) albums · \(totalTracks) tracks · \(librarySize)",
                                 systemImage: "music.note.list")
                    Button { state.reveal(settings.libraryURL) } label: {
                        Label("Open folder", systemImage: "folder")
                    }.controlSize(.large)
                }

                if state.albums.isEmpty {
                    emptyState
                } else {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search albums…", text: $search).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: 320)

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filtered) { album in
                            AlbumTile(album: album) { selected = album }
                        }
                    }
                }
            }
            .padding(22)
        }
        .onAppear { state.scanLibrary() }
        .sheet(item: $selected) { album in AlbumDetailView(album: album) }
    }

    private var totalTracks: Int { state.albums.reduce(0) { $0 + $1.trackCount } }
    private var librarySize: String {
        let bytes = state.albums.reduce(Int64(0)) { acc, album in
            let files = (try? FileManager.default.contentsOfDirectory(at: album.url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return acc + files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 46)).foregroundStyle(.secondary)
            Text("Your library is empty").font(.title3.weight(.semibold))
            Text("Download a playlist to see it here.").foregroundStyle(.secondary)
            Button { state.section = .download } label: {
                Label("Go to Download", systemImage: "arrow.down.circle.fill")
            }.buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

struct AlbumTile: View {
    let album: AlbumFolder
    var onOpen: () -> Void
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var player: Player
    @State private var art: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let art {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [settings.accent.color.opacity(0.7), settings.accent.color.opacity(0.35)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: 34)).foregroundStyle(.white.opacity(0.85))
                }
                if hovering { Color.black.opacity(0.25) }
            }
            .frame(height: 170).frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                if hovering {
                    Button { playFirst() } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44)).foregroundStyle(.white)
                            .shadow(radius: 6)
                    }.buttonStyle(.plain)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hovering {
                    HStack(spacing: 6) {
                        TileButton(icon: "folder") { state.reveal(album.url) }
                        TileButton(icon: "trash") { state.deleteAlbum(album) }
                    }.padding(8)
                }
            }
            .overlay(alignment: .topLeading) {
                if album.isVideo {
                    Label("Video", systemImage: "film.fill")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white).padding(8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)

            Text(album.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text("\(album.trackCount) tracks").font(.caption).foregroundStyle(.secondary)
        }
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.snappy(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .task { art = await ArtworkStore.shared.artwork(for: album) }
    }

    private func playFirst() {
        guard let first = state.tracks(in: album).first else { return }
        if Media.isAudio(first.url) { player.toggle(first.url) }
        else { NSWorkspace.shared.open(first.url) }
    }
}

struct TileButton: View {
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.55), in: Circle())
                .foregroundStyle(.white)
        }.buttonStyle(.plain)
    }
}

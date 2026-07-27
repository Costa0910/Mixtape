import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: SettingsStore

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    ScreenHeader(title: "Library",
                                 subtitle: "\(state.albums.count) albums · \(totalTracks) tracks",
                                 systemImage: "music.note.list")
                    Button { state.reveal(settings.libraryURL) } label: {
                        Label("Open folder", systemImage: "folder")
                    }.controlSize(.large)
                }

                if state.albums.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(state.albums) { album in
                            AlbumTile(album: album)
                        }
                    }
                }
            }
            .padding(22)
        }
        .onAppear { state.scanLibrary() }
    }

    private var totalTracks: Int { state.albums.reduce(0) { $0 + $1.trackCount } }

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
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: SettingsStore
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
            }
            .frame(height: 170).frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .bottomTrailing) {
                if hovering {
                    HStack(spacing: 6) {
                        TileButton(icon: "folder") { state.reveal(album.url) }
                        TileButton(icon: "trash") { state.deleteAlbum(album) }
                    }.padding(8)
                }
            }

            Text(album.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text("\(album.trackCount) tracks").font(.caption).foregroundStyle(.secondary)
        }
        .onHover { hovering = $0 }
        .task { art = await ArtworkStore.shared.artwork(for: album) }
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

import SwiftUI
import AppKit

struct AlbumDetailView: View {
    let album: AlbumFolder
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) private var dismiss

    @State private var art: NSImage?
    @State private var tracks: [TrackFile] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(tracks) { track in TrackRow(track: track, album: album) }
                }
                .padding(12)
            }
            Divider()
            footer
        }
        .frame(width: 540, height: 580)
        .background(.background)
        .task {
            art = await ArtworkStore.shared.artwork(for: album)
            tracks = state.tracks(in: album)
        }
        .onDisappear { player.stop() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                if let art { Image(nsImage: art).resizable().aspectRatio(contentMode: .fill) }
                else {
                    LinearGradient(colors: [settings.accent.color, settings.accent.color.opacity(0.4)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.title).foregroundStyle(.white)
                }
            }
            .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(album.name).font(.title3.weight(.bold)).lineLimit(2)
                Text("\(album.trackCount) tracks").foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button { state.reveal(album.url) } label: { Label("Reveal in Finder", systemImage: "folder") }
            Spacer()
            Button(role: .destructive) {
                state.deleteAlbum(album); dismiss()
            } label: { Label("Delete album", systemImage: "trash") }
        }
        .padding(14)
    }
}

struct TrackRow: View {
    let track: TrackFile
    let album: AlbumFolder
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: Player
    @State private var hovering = false

    private var isCurrent: Bool { player.currentURL == track.url }
    private var playing: Bool { isCurrent && player.isPlaying }
    private var isVideo: Bool { !Media.isAudio(track.url) }
    private var iconName: String {
        isVideo ? "play.rectangle.fill" : (playing ? "pause.circle.fill" : "play.circle.fill")
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { open() } label: {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }.buttonStyle(.plain)

            Text("\(track.index)").font(.caption.monospaced()).foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            Text(track.title).lineLimit(1)
                .fontWeight(isCurrent ? .semibold : .regular)
            Spacer()
            if hovering {
                Button { state.deleteTrack(track, in: album) } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(isCurrent ? AnyShapeStyle(.tint.opacity(0.10)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }

    private func open() {
        if isVideo { NSWorkspace.shared.open(track.url) }
        else { player.toggle(track.url) }
    }
}

import SwiftUI

/// A persistent, user-controlled presentation for library collections.
enum CollectionLayoutMode: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: "List"
        case .grid: "Grid"
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.2x2"
        }
    }
}

struct CollectionLayoutPicker: View {
    @Binding var selection: CollectionLayoutMode

    var body: some View {
        Menu {
            Picker("View as", selection: $selection) {
                ForEach(CollectionLayoutMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
        } label: {
            Image(systemName: selection.symbol)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("View as \(selection.title)")
        .accessibilityHint("Changes between list and grid layouts")
    }
}

/// Shared grid presentation for song collections outside Listen Now.
struct TrackGridView: View {
    let tracks: [Track]
    let currentTrackID: UUID?
    let play: (Int) -> Void

    var body: some View {
        ScrollView {
            TrackGridContent(tracks: tracks, currentTrackID: currentTrackID, play: play)
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.top, 12)
            .padding(.bottom, AppLayout.scrollEndPadding)
        }
        .appScreenBackground()
    }
}

struct TrackGridContent: View {
    let tracks: [Track]
    let currentTrackID: UUID?
    let play: (Int) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { pair in
                Button {
                    Haptics.light()
                    play(pair.offset)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        SquareArtwork(url: pair.element.artworkURL, corner: 14)
                            .overlay(alignment: .bottomTrailing) {
                                if currentTrackID == pair.element.id {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(8)
                                        .background(.black.opacity(0.58), in: Circle())
                                        .padding(8)
                                }
                            }
                            .shadow(color: .black.opacity(0.28), radius: 7, y: 3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(pair.element.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(pair.element.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(Pressable(scale: 0.97))
                .trackMenu(pair.element)
                .accessibilityLabel("\(pair.element.title), by \(pair.element.artist)")
            }
        }
    }
}

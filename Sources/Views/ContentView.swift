import SwiftUI

// MARK: - Liquid Glass helpers

extension View {
    /// Frosted "Liquid Glass" surface — real glass on macOS 26, material fallback below.
    @ViewBuilder
    func glassSurface(_ cornerRadius: CGFloat = 16) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

// MARK: - Shared components

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(18)
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
    }
}

struct ScreenHeader: View {
    let title: String
    let subtitle: String
    var systemImage: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 24, weight: .bold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct StatusBadge: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Main shell

struct MainView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: Player

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 216, ideal: 232, max: 280)
        } detail: {
            Group {
                switch state.section {
                case .download: DownloadView()
                case .library:  LibraryView()
                case .devices:  DevicesView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.background)
            .safeAreaInset(edge: .bottom) {
                if player.currentURL != nil { MiniPlayerBar() }
            }
        }
        .onAppear {
            state.scanLibrary(); state.refreshPhones(); Notifier.requestAuth()
            state.autoUpdateYtDlpIfDue()
        }
    }
}

struct MiniPlayerBar: View {
    @EnvironmentObject var player: Player
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "music.note")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.tint, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(player.nowPlaying.isEmpty ? "—" : player.nowPlaying)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !player.albumName.isEmpty {
                    Text(player.albumName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 18) {
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                    .disabled(!player.hasPrev)
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 16))
                }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                    .disabled(!player.hasNext)
                Button { player.stop() } label: { Image(systemName: "xmark") }
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).font(.system(size: 14))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(LinearGradient(colors: [settings.accent.color, settings.accent.color.opacity(0.6)],
                                               startPoint: .top, endPoint: .bottom),
                                in: RoundedRectangle(cornerRadius: 9))
                Text("Snag").font(.system(size: 17, weight: .bold))
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 12)

            ForEach(AppSection.allCases) { s in
                SidebarRow(section: s,
                           selected: state.section == s,
                           badge: s == .download && state.activeJobCount > 0 ? "\(state.activeJobCount)" : nil) {
                    withAnimation(.snappy(duration: 0.15)) { state.section = s }
                }
            }

            Spacer()

            // mini device status
            HStack(spacing: 8) {
                Circle().fill(state.phones.isEmpty ? Color.secondary : Color.green).frame(width: 8, height: 8)
                Text(state.phones.isEmpty ? "No phone" : state.phones.first!.name)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(9)
        }
        .padding(10)
    }
}

struct SidebarRow: View {
    let section: AppSection
    let selected: Bool
    var badge: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: section.icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20)
                Text(section.title).font(.system(size: 14, weight: .medium))
                Spacer()
                if let badge {
                    Text(badge).font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint, in: Capsule()).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .foregroundStyle(selected ? Color.primary : .secondary)
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? AnyShapeStyle(.tint.opacity(0.15))
                                   : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : .clear))
            }
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(.tint).frame(width: 3, height: 16).offset(x: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

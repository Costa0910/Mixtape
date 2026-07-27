import SwiftUI

// MARK: - Shared components

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.06)))
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
        }
        .onAppear { state.scanLibrary(); state.refreshPhones() }
    }
}

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(LinearGradient(colors: [settings.accent.color, settings.accent.color.opacity(0.6)],
                                               startPoint: .top, endPoint: .bottom),
                                in: RoundedRectangle(cornerRadius: 9))
                Text("Mixtape").font(.system(size: 17, weight: .bold))
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
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
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
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

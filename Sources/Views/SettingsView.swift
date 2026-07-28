import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Settings",
                             subtitle: "Defaults & customization",
                             systemImage: "gearshape")

                Form {
                    Section("Downloads") {
                        Picker("Default format", selection: $settings.defaultFormat) {
                            ForEach(AudioFormat.allCases) { Text($0.display).tag($0) }
                        }
                        if settings.defaultFormat == .mp3 {
                            Picker("MP3 bitrate", selection: $settings.mp3Bitrate) {
                                ForEach(["320", "256", "192", "128"], id: \.self) { Text("\($0) kbps").tag($0) }
                            }
                        }
                        Toggle("Skip vlogs / non-music by default", isOn: $settings.skipVlogs)
                    }

                    Section("Organization") {
                        Picker("Album name from", selection: $settings.albumSource) {
                            ForEach(AlbumSource.allCases) { Text($0.label).tag($0) }
                        }
                        Stepper("Track number digits: \(settings.trackPadding)",
                                value: $settings.trackPadding, in: 1...4)
                        Toggle("Create .m3u8 playlists", isOn: $settings.makePlaylists)
                        TextField("Genre tag", text: $settings.genre)
                    }

                    Section("Library") {
                        HStack {
                            Text("Location")
                            Spacer()
                            Text(settings.libraryPath).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Button("Change…", action: pickFolder)
                        }
                    }

                    Section("Transfer") {
                        Toggle("Auto-transfer to selected phone after download", isOn: $settings.autoTransfer)
                    }

                    Section("Appearance") {
                        HStack(spacing: 10) {
                            Text("Accent")
                            Spacer()
                            ForEach(AccentTheme.allCases) { theme in
                                Circle().fill(theme.color)
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(.primary, lineWidth: settings.accent == theme ? 2 : 0))
                                    .onTapGesture { settings.accent = theme }
                            }
                        }
                    }

                    Section("Tools") {
                        toolRow(.ytdlp); toolRow(.ffmpeg); toolRow(.adb)
                        HStack {
                            Button { state.updateYtDlp() } label: {
                                Label("Update yt-dlp", systemImage: "arrow.triangle.2.circlepath")
                            }
                            if !state.ytdlpUpdateStatus.isEmpty {
                                Text(state.ytdlpUpdateStatus).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.tail)
                            }
                        }
                        Text("Bundle them with Scripts/fetch-tools.sh for a self-contained app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section("About") {
                        LabeledContent("Mixtape", value: "v0.1")
                        Link("github.com/Costa0910/Mixtape",
                             destination: URL(string: "https://github.com/Costa0910/Mixtape")!)
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: 640)
            }
            .padding(22)
        }
    }

    private func toolRow(_ tool: Tool) -> some View {
        let ok = BinaryLocator.url(for: tool) != nil
        return HStack {
            Text(tool.rawValue)
            Spacer()
            Label(ok ? "Found" : "Missing", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red).font(.callout)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.libraryURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.libraryPath = url.path
            state.scanLibrary()
        }
    }
}

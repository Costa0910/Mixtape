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
                    Section("General") {
                        Picker("Default kind", selection: $settings.defaultKind) {
                            ForEach(MediaKind.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                        }
                        Toggle("Embed thumbnail / cover art", isOn: $settings.embedThumbnail)
                        Toggle("Resume interrupted downloads (skip already-downloaded)",
                               isOn: $settings.resumeDownloads)
                    }

                    Section {
                        Picker("Format", selection: $settings.defaultFormat) {
                            ForEach(AudioFormat.allCases) { Text($0.display).tag($0) }
                        }
                        if settings.defaultFormat == .mp3 {
                            Picker("Bitrate", selection: $settings.mp3Bitrate) {
                                ForEach(["320", "256", "192", "128"], id: \.self) { Text("\($0) kbps").tag($0) }
                            }
                        }
                        Toggle("Skip vlogs / non-music", isOn: $settings.skipVlogs)
                        Picker("Album name from", selection: $settings.albumSource) {
                            ForEach(AlbumSource.allCases) { Text($0.label).tag($0) }
                        }
                        Stepper("Track number digits: \(settings.trackPadding)",
                                value: $settings.trackPadding, in: 1...4)
                        Toggle("Create .m3u8 playlists", isOn: $settings.makePlaylists)
                        TextField("Genre tag", text: $settings.genre)
                    } header: { Label("Music", systemImage: "music.note") }

                    Section {
                        Picker("Format", selection: $settings.podcastFormat) {
                            ForEach(AudioFormat.allCases) { Text($0.display).tag($0) }
                        }
                        Toggle("Number episodes (01 - , 02 - …)", isOn: $settings.numberPodcastTracks)
                        Text("Keeps the channel as the artist — no album/Various-Artists tagging.")
                            .font(.caption).foregroundStyle(.secondary)
                    } header: { Label("Audio / Podcast", systemImage: "waveform") }

                    Section {
                        Picker("Max quality", selection: $settings.videoQuality) {
                            Text("1080p").tag("1080"); Text("720p").tag("720")
                            Text("480p").tag("480"); Text("Best available").tag("best")
                        }
                        Picker("Container", selection: $settings.videoContainer) {
                            Text("MP4").tag("mp4"); Text("MKV").tag("mkv")
                        }
                        Toggle("Embed subtitles", isOn: $settings.embedSubtitles)
                        if settings.embedSubtitles {
                            TextField("Subtitle language(s)", text: $settings.subtitleLang)
                        }
                    } header: { Label("Video", systemImage: "film") }

                    Section("Library & Transfer") {
                        HStack {
                            Text("Location")
                            Spacer()
                            Text(settings.libraryPath).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Button("Change…", action: pickFolder)
                        }
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
                        LabeledContent("Snag", value: "v0.1.1")
                        Link("github.com/Costa0910/Snag",
                             destination: URL(string: "https://github.com/Costa0910/Snag")!)
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

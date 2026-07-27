import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !state.missingTools.isEmpty { missingBanner }
                inputCard
                if let a = state.analysis { AnalysisCard(analysis: a) }
                progressCard
                deviceCard
                logDisclosure
            }
            .padding(22)
        }
        .background(.background)
    }

    // MARK: Header
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mixtape").font(.system(size: 22, weight: .bold))
                Text("Download music · organize · send to your phone")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge
        }
    }

    private var statusBadge: some View {
        Text(state.phase.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(badgeColor.opacity(0.15), in: Capsule())
            .foregroundStyle(badgeColor)
    }
    private var badgeColor: Color {
        switch state.phase {
        case .done: return .green
        case .failed: return .red
        case .idle, .ready: return .secondary
        default: return .accentColor
        }
    }

    // MARK: Missing tools
    private var missingBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Missing tools: \(state.missingTools.map(\.rawValue).joined(separator: ", "))")
                    .fontWeight(.semibold)
                Text("Install with Homebrew:  brew install \(state.missingTools.map(\.rawValue).joined(separator: " "))")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Input
    private var inputCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Source", systemImage: "link").font(.headline)
                HStack {
                    TextField("Paste a YouTube video or playlist URL…", text: $state.urlInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { state.analyze() }
                    Button("Analyze") { state.analyze() }
                        .disabled(state.urlInput.isEmpty || state.phase == .analyzing)
                }
                HStack(spacing: 16) {
                    Picker("Format", selection: $state.format) {
                        ForEach(AudioFormat.allCases) { Text($0.display).tag($0) }
                    }.frame(maxWidth: 280)
                    if state.format == .mp3 {
                        Picker("Bitrate", selection: $state.mp3Bitrate) {
                            ForEach(["320", "256", "192", "128"], id: \.self) { Text("\($0)k").tag($0) }
                        }.frame(width: 130)
                    }
                    Toggle("Skip vlogs", isOn: $state.skipVlogs)
                    Spacer()
                }
                HStack {
                    Text("Album name").foregroundStyle(.secondary)
                    TextField("auto", text: $state.albumName).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button {
                        state.startDownload()
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large).buttonStyle(.borderedProminent)
                    .disabled(state.urlInput.isEmpty ||
                              state.phase == .downloading || state.phase == .organizing)
                }
            }
        }
    }

    // MARK: Progress
    private var progressCard: some View {
        Group {
            if state.phase == .downloading || state.phase == .organizing || state.phase == .done {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(state.phase.label, systemImage: "waveform").font(.headline)
                        ProgressView(value: max(0, min(state.progressValue, 1)))
                        Text(state.progressDetail).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if state.phase == .done {
                            Button("Reveal in Finder") { state.revealLibrary() }
                        }
                    }
                }
            }
        }
    }

    // MARK: Devices
    private var deviceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Send to phone", systemImage: "iphone.gen3").font(.headline)
                    Spacer()
                    Button { state.refreshPhones() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }.controlSize(.small)
                }
                if !state.adbAvailable {
                    Text("Android transfer needs adb:  brew install android-platform-tools")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if state.phones.isEmpty {
                    Text("No phone detected. Connect via USB (Android: enable File Transfer + USB debugging; iPhone: tap Trust).")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Picker("Phone", selection: $state.selectedPhone) {
                        ForEach(state.phones) { p in
                            Text("\(p.kind == .iphone ? "" : "") \(p.name) \(p.freeText.isEmpty ? "" : "· \(p.freeText)")")
                                .tag(Optional(p))
                        }
                    }
                    Button {
                        state.transfer()
                    } label: {
                        Label(state.selectedPhone?.kind == .iphone ? "Prepare for iPhone" : "Transfer",
                              systemImage: "square.and.arrow.up")
                    }
                    .disabled(state.transferring || state.lastAlbumDir == nil)
                    .help(state.lastAlbumDir == nil ? "Download something first" : "")
                }
                if !state.transferStatus.isEmpty {
                    Text(state.transferStatus).font(.callout)
                        .foregroundStyle(state.transferStatus.hasPrefix("✓") ? .green : .primary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: Log
    private var logDisclosure: some View {
        DisclosureGroup("Activity log") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(state.log.enumerated()), id: \.offset) { entry in
                    Text(entry.element).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.top, 6)
        }
        .font(.subheadline)
    }
}

// Simple card container.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct AnalysisCard: View {
    let analysis: Analysis
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(analysis.isPlaylist ? "Playlist" : "Single track", systemImage: "list.bullet")
                        .font(.headline)
                    Spacer()
                    Text("\(analysis.entries.count) tracks"
                         + (analysis.vlogCount > 0 ? " · \(analysis.vlogCount) vlogs skipped" : ""))
                        .font(.callout).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(analysis.entries) { t in
                            HStack {
                                Text("\(t.index).").foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                                Text(t.title).lineLimit(1)
                                if t.isLikelyVlog {
                                    Text("vlog").font(.caption2).padding(.horizontal, 5)
                                        .background(.orange.opacity(0.2), in: Capsule())
                                }
                                Spacer()
                                Text(t.durationText).foregroundStyle(.secondary).font(.caption)
                            }
                            .font(.callout)
                            .opacity(t.isLikelyVlog ? 0.5 : 1)
                        }
                    }
                }.frame(maxHeight: 180)
            }
        }
    }
}

import SwiftUI
import AppKit

struct DownloadView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: SettingsStore

    @State private var url = ""
    @State private var format: AudioFormat = .m4a
    @State private var bitrate = "320"
    @State private var skipVlogs = true
    @State private var customAlbum = ""

    @State private var analysis: Analysis?
    @State private var analyzing = false
    @State private var analyzeError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Download",
                             subtitle: "Paste a YouTube video or playlist link",
                             systemImage: "arrow.down.circle")

                if !state.missingTools.isEmpty { MissingToolsBanner(tools: state.missingTools) }

                inputCard
                if analyzing { analyzingRow }
                if let a = analysis { TrackListCard(analysis: a) }
                if !state.jobs.isEmpty { queueCard }
            }
            .padding(22)
        }
        .onAppear {
            format = settings.defaultFormat
            bitrate = settings.mp3Bitrate
            skipVlogs = settings.skipVlogs
        }
    }

    private var inputCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    TextField("https://youtube.com/…", text: $url)
                        .textFieldStyle(.plain).font(.system(size: 14))
                        .onSubmit(analyze)
                    Button {
                        if let s = NSPasteboard.general.string(forType: .string) { url = s }
                    } label: { Image(systemName: "doc.on.clipboard") }
                        .buttonStyle(.borderless).help("Paste")
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))

                HStack(spacing: 14) {
                    Picker("", selection: $format) {
                        ForEach(AudioFormat.allCases) { Text($0.display).tag($0) }
                    }.labelsHidden().frame(maxWidth: 260)
                    if format == .mp3 {
                        Picker("", selection: $bitrate) {
                            ForEach(["320", "256", "192", "128"], id: \.self) { Text("\($0)k").tag($0) }
                        }.labelsHidden().frame(width: 92)
                    }
                    Toggle("Skip vlogs", isOn: $skipVlogs)
                    Spacer()
                }

                if settings.albumSource == .custom {
                    TextField("Album name (optional)", text: $customAlbum)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 10) {
                    Button(action: analyze) {
                        Label("Preview", systemImage: "eye")
                    }
                    .disabled(url.isEmpty || analyzing)

                    Button(action: addToQueue) {
                        Label("Add to queue", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large).buttonStyle(.borderedProminent)
                    .disabled(url.isEmpty)
                }
                if let e = analyzeError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private var analyzingRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Reading link…").foregroundStyle(.secondary)
        }.padding(.horizontal, 4)
    }

    private var queueCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Queue", systemImage: "list.bullet.rectangle").font(.headline)
                    Spacer()
                    if state.jobs.contains(where: { $0.status.isFinished }) {
                        Button("Clear finished") { state.clearFinished() }
                            .controlSize(.small).buttonStyle(.borderless)
                    }
                }
                ForEach(state.jobs) { job in JobRow(job: job) }
            }
        }
    }

    private func analyze() {
        guard !url.isEmpty else { return }
        analyzing = true; analyzeError = nil; analysis = nil
        let target = url
        Task {
            do { analysis = try await Downloader.analyze(target) }
            catch { analyzeError = error.localizedDescription }
            analyzing = false
        }
    }

    private func addToQueue() {
        let album = (settings.albumSource == .custom && !customAlbum.isEmpty) ? customAlbum : nil
        state.enqueue(url: url, format: format, bitrate: bitrate, skipVlogs: skipVlogs, customAlbum: album)
        url = ""; analysis = nil; customAlbum = ""
    }
}

struct JobRow: View {
    @ObservedObject var job: DownloadJob
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(job.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                StatusBadge(text: job.status.label, color: color)
                if !job.status.isFinished {
                    Button { state.cancel(job) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            if job.status.isActive {
                ProgressView(value: max(0, min(job.progress, 1)))
                Text(job.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else if !job.detail.isEmpty {
                Text(job.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 11))
    }

    private var color: Color {
        switch job.status {
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }
    private var icon: String {
        switch job.status {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "slash.circle"
        default: return "arrow.down.circle"
        }
    }
}

struct TrackListCard: View {
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
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(analysis.entries) { t in
                            HStack {
                                Text("\(t.index)").foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .trailing).font(.caption.monospaced())
                                Text(t.title).lineLimit(1).font(.callout)
                                if t.isLikelyVlog { StatusBadge(text: "vlog", color: .orange) }
                                Spacer()
                                Text(t.durationText).font(.caption).foregroundStyle(.secondary)
                            }
                            .opacity(t.isLikelyVlog ? 0.5 : 1)
                        }
                    }
                }.frame(maxHeight: 200)
            }
        }
    }
}

struct MissingToolsBanner: View {
    let tools: [Tool]
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Missing: \(tools.map(\.rawValue).joined(separator: ", "))").fontWeight(.semibold)
                Text("Run Scripts/fetch-tools.sh, or: brew install \(tools.map(\.rawValue).joined(separator: " "))")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

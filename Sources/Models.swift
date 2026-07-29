import Foundation

// What kind of thing the user is downloading — changes how it's fetched & organized.
enum MediaKind: String, CaseIterable, Identifiable {
    case music   // audio, organized as albums with track tags
    case audio   // spoken audio (podcast/talk/audiobook) — keep channel as artist
    case video   // the actual video, to watch offline

    var id: String { rawValue }
    var label: String {
        switch self {
        case .music: return "Music"
        case .audio: return "Audio / Podcast"
        case .video: return "Video"
        }
    }
    var icon: String {
        switch self {
        case .music: return "music.note"
        case .audio: return "waveform"
        case .video: return "film"
        }
    }
    var isAudio: Bool { self != .video }
}

// File-extension groups shared across the app.
enum Media {
    static let audio: Set<String> = ["m4a", "mp3", "opus", "ogg", "wav", "flac", "aac"]
    static let video: Set<String> = ["mp4", "mkv", "webm", "mov", "m4v"]
    static var all: Set<String> { audio.union(video) }
    static func isAudio(_ url: URL) -> Bool { audio.contains(url.pathExtension.lowercased()) }
    static func isMedia(_ url: URL) -> Bool { all.contains(url.pathExtension.lowercased()) }
}

// Output audio format the user can pick.
enum AudioFormat: String, CaseIterable, Identifiable {
    case m4a   // keep original AAC, no re-encode (best quality/speed)
    case mp3   // re-encode to mp3 (max compatibility)
    case opus  // re-encode to opus (small, efficient)
    case best  // best available, whatever it is

    var id: String { rawValue }

    var display: String {
        switch self {
        case .m4a:  return "M4A · original quality (recommended)"
        case .mp3:  return "MP3 · most compatible"
        case .opus: return "Opus · small & efficient"
        case .best: return "Best available"
        }
    }

    // Whether yt-dlp must re-encode (uses -x --audio-format) vs. keep the stream.
    var reencodes: Bool { self != .m4a }
}

// A single entry discovered in a URL / playlist.
struct TrackEntry: Identifiable, Hashable {
    let id: String          // youtube id
    let index: Int          // 1-based position
    let title: String
    let duration: Int?      // seconds
    var isLikelyVlog: Bool

    var durationText: String {
        guard let d = duration, d > 0 else { return "" }
        let h = d / 3600, m = (d % 3600) / 60, s = d % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

// Result of analysing a URL before download.
struct Analysis {
    let albumName: String
    let entries: [TrackEntry]
    var vlogCount: Int { entries.filter { $0.isLikelyVlog }.count }
    var isPlaylist: Bool { entries.count > 1 }
}

// High-level phase of the pipeline, drives the UI.
enum Phase: Equatable {
    case idle
    case analyzing
    case ready          // analysis done, awaiting download
    case downloading
    case organizing
    case done
    case failed(String)

    var label: String {
        switch self {
        case .idle:        return "Ready"
        case .analyzing:   return "Reading URL…"
        case .ready:       return "Ready to download"
        case .downloading: return "Downloading"
        case .organizing:  return "Organizing"
        case .done:        return "Done"
        case .failed(let m): return "Failed: \(m)"
        }
    }
}

// Sidebar sections of the app.
enum AppSection: String, CaseIterable, Identifiable {
    case download, library, devices, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .download: return "Download"
        case .library:  return "Library"
        case .devices:  return "Devices"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .download: return "arrow.down.circle"
        case .library:  return "music.note.list"
        case .devices:  return "iphone.gen3"
        case .settings: return "gearshape"
        }
    }
}

// Status of a single download job in the queue.
enum JobStatus: Equatable {
    case queued, analyzing, downloading, organizing, done, cancelled
    case failed(String)
    var label: String {
        switch self {
        case .queued: return "Queued"
        case .analyzing: return "Analyzing"
        case .downloading: return "Downloading"
        case .organizing: return "Organizing"
        case .done: return "Done"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }
    var isActive: Bool {
        switch self { case .analyzing, .downloading, .organizing: return true; default: return false }
    }
    var isFinished: Bool {
        switch self { case .done, .cancelled, .failed: return true; default: return false }
    }
}

// A snapshot of every option a download uses, captured when it's queued.
struct JobConfig: Equatable {
    var kind: MediaKind = .music
    // audio (music + podcast)
    var format: AudioFormat = .m4a
    var bitrate: String = "320"
    // video
    var videoQuality: String = "1080"          // 480/720/1080/best
    var videoContainer: String = "mp4"         // mp4/mkv
    var embedSubtitles: Bool = false
    var subtitleLang: String = "en"
    // shared
    var embedThumbnail: Bool = true
    var skipVlogs: Bool = true                 // music only
    var numberTracks: Bool = true              // prefix "NN - "
    var trackPadding: Int = 3
    var resume: Bool = true                     // download-archive so retries skip done items
    var genre: String = "Music"                // written to the genre tag (players group by it)
}

// One queued/active download.
@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    let id = UUID()
    let url: String
    let config: JobConfig
    var customAlbum: String?

    @Published var title: String
    @Published var status: JobStatus = .queued
    @Published var progress: Double = 0
    @Published var detail: String = ""
    @Published var trackCount: Int = 0
    var albumDir: URL?
    var task: Task<Void, Never>?

    var kind: MediaKind { config.kind }        // convenience passthrough

    init(url: String, config: JobConfig, customAlbum: String?) {
        self.url = url
        self.config = config
        self.customAlbum = customAlbum
        self.title = customAlbum ?? url
    }
}

// Result of a download run.
struct DownloadOutcome {
    let albumDir: URL
    let filesPresent: Int
    let errors: Int
}

// A single audio file inside an album.
struct TrackFile: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let index: Int
    let title: String
}

// A connected phone we can transfer to.
struct Phone: Identifiable, Hashable {
    enum Kind { case android, iphone }
    let id: String          // serial / udid
    let kind: Kind
    let name: String
    let freeBytes: Int64?
    var needsSetup: Bool = false    // connected but not ready (debugging off / not trusted)
    var hint: String = ""           // what the user should do

    var freeText: String {
        guard let f = freeBytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: f, countStyle: .file) + " free"
    }
}

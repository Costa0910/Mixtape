import Foundation

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

// A connected phone we can transfer to.
struct Phone: Identifiable, Hashable {
    enum Kind { case android, iphone }
    let id: String          // serial / udid
    let kind: Kind
    let name: String
    let freeBytes: Int64?

    var freeText: String {
        guard let f = freeBytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: f, countStyle: .file) + " free"
    }
}

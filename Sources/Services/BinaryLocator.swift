import Foundation

// Finds the CLI tools the app relies on. Prefers binaries bundled inside the
// app (Resources/bin) and falls back to the user's Homebrew / system install.
enum Tool: String {
    case ytdlp = "yt-dlp"
    case ffmpeg = "ffmpeg"
    case ffprobe = "ffprobe"
    case adb = "adb"
}

struct BinaryLocator {
    // Common install locations to search, in priority order.
    private static let searchDirs: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ]

    // Updated copies (e.g. yt-dlp) live here, outside the read-only signed bundle.
    static var overrideDir: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Snag/bin", isDirectory: true)
    }

    static func url(for tool: Tool) -> URL? {
        // 0) an updated copy in Application Support wins (keeps yt-dlp fresh)
        if let ov = overrideDir?.appendingPathComponent(tool.rawValue),
           FileManager.default.isExecutableFile(atPath: ov.path) {
            return ov
        }
        // 1) bundled copy inside the app
        if let bundled = Bundle.main.url(forResource: "bin/\(tool.rawValue)", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        // 2) known install dirs
        for dir in searchDirs {
            let p = "\(dir)/\(tool.rawValue)"
            if FileManager.default.isExecutableFile(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        return nil
    }

    // Which required tools are missing (adb is optional; only needed for Android).
    static func missingRequired() -> [Tool] {
        [.ytdlp, .ffmpeg].filter { url(for: $0) == nil }
    }

    // A PATH that includes our search dirs so child tools (yt-dlp → ffmpeg) resolve.
    static var augmentedPath: String {
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return (searchDirs + [existing]).joined(separator: ":")
    }
}

import SwiftUI

// How album folders are named when organizing.
enum AlbumSource: String, CaseIterable, Identifiable {
    case playlistTitle   // use the YouTube playlist / video title
    case custom          // always ask / use the field
    var id: String { rawValue }
    var label: String {
        switch self {
        case .playlistTitle: return "Playlist / video title"
        case .custom:        return "Ask each time"
        }
    }
}

// Accent themes the user can choose.
enum AccentTheme: String, CaseIterable, Identifiable {
    case indigo, purple, pink, teal, orange, green
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .indigo: return Color(red: 0.35, green: 0.34, blue: 0.95)
        case .purple: return Color(red: 0.58, green: 0.30, blue: 0.93)
        case .pink:   return Color(red: 0.92, green: 0.28, blue: 0.60)
        case .teal:   return Color(red: 0.16, green: 0.63, blue: 0.68)
        case .orange: return Color(red: 0.96, green: 0.52, blue: 0.16)
        case .green:  return Color(red: 0.20, green: 0.68, blue: 0.42)
        }
    }
    var label: String { rawValue.capitalized }
}

// Central, persisted user preferences.
@MainActor
final class SettingsStore: ObservableObject {
    private let d = UserDefaults.standard

    @Published var hasOnboarded: Bool { didSet { d.set(hasOnboarded, forKey: "hasOnboarded") } }
    @Published var defaultFormat: AudioFormat { didSet { d.set(defaultFormat.rawValue, forKey: "defaultFormat") } }
    @Published var mp3Bitrate: String { didSet { d.set(mp3Bitrate, forKey: "mp3Bitrate") } }
    @Published var libraryPath: String { didSet { d.set(libraryPath, forKey: "libraryPath") } }
    @Published var skipVlogs: Bool { didSet { d.set(skipVlogs, forKey: "skipVlogs") } }
    @Published var makePlaylists: Bool { didSet { d.set(makePlaylists, forKey: "makePlaylists") } }
    @Published var albumSource: AlbumSource { didSet { d.set(albumSource.rawValue, forKey: "albumSource") } }
    @Published var trackPadding: Int { didSet { d.set(trackPadding, forKey: "trackPadding") } }
    @Published var genre: String { didSet { d.set(genre, forKey: "genre") } }
    @Published var autoTransfer: Bool { didSet { d.set(autoTransfer, forKey: "autoTransfer") } }
    @Published var accent: AccentTheme { didSet { d.set(accent.rawValue, forKey: "accent") } }

    var libraryURL: URL { URL(fileURLWithPath: (libraryPath as NSString).expandingTildeInPath) }

    init() {
        hasOnboarded = d.bool(forKey: "hasOnboarded")
        defaultFormat = AudioFormat(rawValue: d.string(forKey: "defaultFormat") ?? "") ?? .m4a
        mp3Bitrate = d.string(forKey: "mp3Bitrate") ?? "320"
        libraryPath = d.string(forKey: "libraryPath")
            ?? (FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Music/Mixtape").path)
        skipVlogs = d.object(forKey: "skipVlogs") as? Bool ?? true
        makePlaylists = d.object(forKey: "makePlaylists") as? Bool ?? true
        albumSource = AlbumSource(rawValue: d.string(forKey: "albumSource") ?? "") ?? .playlistTitle
        trackPadding = d.object(forKey: "trackPadding") as? Int ?? 3
        genre = d.string(forKey: "genre") ?? "Music"
        autoTransfer = d.object(forKey: "autoTransfer") as? Bool ?? false
        accent = AccentTheme(rawValue: d.string(forKey: "accent") ?? "") ?? .indigo
    }
}

import Foundation
import SwiftData

// A song stored on the device. Includes on-device listening stats (Phase 3)
// up front so we never need a schema migration for them.
@Model
final class Track {
    @Attribute(.unique) var id: UUID
    var title: String
    var artist: String
    var album: String
    var genre: String
    var relPath: String          // audio file, relative to the app's Media dir
    var artworkRel: String?      // extracted cover, relative to the Media dir
    var duration: Double
    var dateAdded: Date
    var trackNo: Int
    var sourcePath: String?      // original Mac manifest path (e.g. "Album/track.m4a"), for exact re-sync dedup
    var lyrics: String?          // song lyrics

    // listening stats (private, on-device)
    var playCount: Int
    var skipCount: Int
    var lastPlayedAt: Date?
    var loved: Bool

    init(id: UUID = UUID(), title: String, artist: String, album: String, genre: String,
         relPath: String, artworkRel: String?, duration: Double, trackNo: Int, sourcePath: String? = nil, lyrics: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.relPath = relPath
        self.artworkRel = artworkRel
        self.duration = duration
        self.trackNo = trackNo
        self.sourcePath = sourcePath
        self.lyrics = lyrics
        self.dateAdded = Date()
        self.playCount = 0
        self.skipCount = 0
        self.lastPlayedAt = nil
        self.loved = false
    }

    var url: URL { Storage.media.appendingPathComponent(relPath) }
    var artworkURL: URL? { artworkRel.map { Storage.media.appendingPathComponent($0) } }
    var durationText: String {
        guard duration > 0 else { return "" }
        let s = Int(duration); return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// A user-made playlist. Stores an ordered list of Track ids so tracks can be
// reordered and can appear in multiple playlists.
@Model
final class Playlist {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var trackIDs: [UUID]

    init(id: UUID = UUID(), name: String, trackIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.trackIDs = trackIDs
    }

    /// Resolve this playlist's ids to Tracks, preserving order and skipping any that were deleted.
    func tracks(in all: [Track]) -> [Track] {
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return trackIDs.compactMap { byID[$0] }
    }
}

// Where the app keeps audio + artwork (in its own container).
enum Storage {
    static let media: URL = {
        let base = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
            .appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("Artwork"), withIntermediateDirectories: true)
        return base
    }()

    static let audioExts: Set<String> = ["m4a", "mp3", "aac", "opus", "ogg", "wav", "flac", "aiff", "caf"]
    static func isAudio(_ url: URL) -> Bool { audioExts.contains(url.pathExtension.lowercased()) }
}

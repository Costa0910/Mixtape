import Foundation
import AVFoundation
import SwiftData
import MediaPlayer
import UIKit

enum Importer {
    /// Import audio file URLs into the library. Returns how many were added.
    @MainActor
    static func importFiles(_ urls: [URL], into ctx: ModelContext) async -> Int {
        var added = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard Storage.isAudio(url) else { continue }
            if let t = await makeTrack(from: url) { ctx.insert(t); added += 1 }
        }
        try? ctx.save()
        return added
    }

    /// Copy a file into the app's Media store and read its metadata.
    static func makeTrack(from src: URL) async -> Track? {
        let name = uniqueAudioName(src.lastPathComponent)
        let audioRel = "Audio/\(name)"
        let dest = Storage.media.appendingPathComponent(audioRel)
        do {
            if !FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.copyItem(at: src, to: dest)
            }
        } catch { return nil }

        let asset = AVURLAsset(url: dest)
        var title = src.deletingPathExtension().lastPathComponent
        var artist = "", album = "", genre = ""
        var artworkData: Data?
        var duration = 0.0

        if let d = try? await asset.load(.duration) {
            let secs = CMTimeGetSeconds(d); if secs.isFinite { duration = secs }
        }
        if let items = try? await asset.load(.commonMetadata) {
            for it in items {
                guard let key = it.commonKey else { continue }
                switch key {
                case .commonKeyTitle:     if let s = try? await it.load(.stringValue) { title = s }
                case .commonKeyArtist:    if let s = try? await it.load(.stringValue) { artist = s }
                case .commonKeyAlbumName: if let s = try? await it.load(.stringValue) { album = s }
                case .commonKeyArtwork:   if let d = try? await it.load(.dataValue) { artworkData = d }
                case .commonKeyType:      if let s = try? await it.load(.stringValue) { genre = s }
                default: break
                }
            }
        }
        // genre usually lives in format-specific (iTunes/ID3) metadata, not the common set
        if genre.isEmpty, let all = try? await asset.load(.metadata) {
            let ids: [AVMetadataIdentifier] = [.iTunesMetadataUserGenre, .iTunesMetadataPredefinedGenre, .id3MetadataContentType]
            search: for id in ids {
                for item in AVMetadataItem.metadataItems(from: all, filteredByIdentifier: id) {
                    if let s = try? await item.load(.stringValue), !s.isEmpty { genre = s; break search }
                }
            }
        }
        // strip a leading "NN - " track-number prefix from the title
        if let r = title.range(of: #"^\d+\s*-\s*"#, options: .regularExpression) { title.removeSubrange(r) }
        if album.isEmpty { album = "Unknown Album" }
        if artist.isEmpty { artist = "Unknown Artist" }

        var artRel: String?
        if let data = artworkData {
            let key = album == "Unknown Album" ? title : album
            let rel = "Artwork/\(abs(key.hashValue)).jpg"
            let out = Storage.media.appendingPathComponent(rel)
            if !FileManager.default.fileExists(atPath: out.path) { try? data.write(to: out) }
            artRel = rel
        }
        return Track(title: title, artist: artist, album: album, genre: genre,
                     relPath: audioRel, artworkRel: artRel, duration: duration, trackNo: 0)
    }

    /// Build a Track from a song in the phone's Music library, exporting its audio
    /// into our store as m4a so it plays fully offline like everything else.
    static func makeTrack(from item: MPMediaItem) async -> Track? {
        guard let src = item.assetURL else { return nil }
        let stem = sanitize(item.title ?? "Song")
        let name = uniqueAudioName("\(stem).m4a")
        let audioRel = "Audio/\(name)"
        let dest = Storage.media.appendingPathComponent(audioRel)

        let asset = AVURLAsset(url: src)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        ex.outputURL = dest
        ex.outputFileType = .m4a
        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            ex.exportAsynchronously { cont.resume(returning: ex.status == .completed) }
        }
        guard ok else { try? FileManager.default.removeItem(at: dest); return nil }

        var artRel: String?
        if let img = item.artwork?.image(at: CGSize(width: 600, height: 600)),
           let data = img.jpegData(compressionQuality: 0.85) {
            let key = item.albumTitle ?? item.title ?? UUID().uuidString
            let rel = "Artwork/\(abs(key.hashValue)).jpg"
            let out = Storage.media.appendingPathComponent(rel)
            if !FileManager.default.fileExists(atPath: out.path) { try? data.write(to: out) }
            artRel = rel
        }

        return Track(title: item.title ?? "Unknown",
                     artist: item.artist ?? "Unknown Artist",
                     album: item.albumTitle ?? "Unknown Album",
                     genre: item.genre ?? "",
                     relPath: audioRel, artworkRel: artRel,
                     duration: item.playbackDuration, trackNo: item.albumTrackNumber)
    }

    private static func sanitize(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
    }

    private static func uniqueAudioName(_ name: String) -> String {
        let dir = Storage.media.appendingPathComponent("Audio")
        var candidate = name, i = 1
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = "\(base) (\(i)).\(ext)"; i += 1
        }
        return candidate
    }
}

// Group tracks into albums for browsing.
struct AlbumGroup: Identifiable {
    var id: String { name }
    let name: String
    let artist: String
    let tracks: [Track]
    var artworkURL: URL? { tracks.first(where: { $0.artworkURL != nil })?.artworkURL }
}

enum LibraryGrouping {
    static func albums(_ tracks: [Track]) -> [AlbumGroup] {
        Dictionary(grouping: tracks, by: { $0.album })
            .map { AlbumGroup(name: $0.key,
                              artist: $0.value.first?.artist ?? "",
                              tracks: $0.value.sorted { $0.relPath < $1.relPath }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

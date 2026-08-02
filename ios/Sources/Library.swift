import Foundation
import AVFoundation
import SwiftData
import MediaPlayer
import UIKit
import CryptoKit
import os

enum Importer {
    private static let logger = Logger(subsystem: "com.costa.SnagPlayer", category: "Importer")
    private static let lyricsScanRegistryKey = "lyricsMetadataScanV1"
    private static let artworkRepairRegistryKey = "contentAddressedArtworkV1"

    private struct LyricsCandidate: Sendable {
        let id: UUID
        let url: URL
    }

    private struct ArtworkCandidate: Sendable {
        let id: UUID
        let url: URL
    }

    private struct LyricsScanResult: Sendable {
        let attemptedIDs: [UUID]
        let lyricsByID: [UUID: String]
    }

    /// Import audio file URLs into the library. Returns how many were added.
    @MainActor
    static func importFiles(_ urls: [URL], into ctx: ModelContext) async -> Int {
        logger.info("Starting import pipeline for \(urls.count) URLs")
        var added = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard Storage.isAudio(url) else {
                logger.warning("Skipping non-audio file: \(url.lastPathComponent)")
                continue
            }
            if let t = await makeTrack(from: url) {
                ctx.insert(t)
                added += 1
                logger.info("Successfully imported and inserted track: '\(t.title)' by '\(t.artist)'")
            } else {
                logger.error("Failed to import track from URL: \(url.lastPathComponent)")
            }
        }
        do {
            try ctx.save()
            logger.info("Saved context successfully. Added \(added) tracks.")
        } catch {
            logger.error("Failed to save SwiftData context after import: \(error.localizedDescription)")
        }
        return added
    }

    /// Copy a file into the app's Media store and read its metadata.
    static func makeTrack(from src: URL, albumSubfolder: String? = nil, sourcePath: String? = nil,
                          sourceSize: Int64? = nil) async -> Track? {
        logger.info("Processing source track file: \(src.lastPathComponent)")
        let asset = AVURLAsset(url: src)
        var title = src.deletingPathExtension().lastPathComponent
        var artist = "", album = "", genre = ""
        var artworkData: Data?
        var duration = 0.0

        if let d = try? await asset.load(.duration) {
            let secs = CMTimeGetSeconds(d); if secs.isFinite { duration = secs }
        }
        let allMetadata = (try? await asset.load(.metadata)) ?? []
        let lyrics = await resolvedLyrics(from: asset, metadata: allMetadata) ?? ""
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
        if genre.isEmpty {
            let ids: [AVMetadataIdentifier] = [.iTunesMetadataUserGenre, .iTunesMetadataPredefinedGenre, .id3MetadataContentType]
            search: for id in ids {
                for item in AVMetadataItem.metadataItems(from: allMetadata, filteredByIdentifier: id) {
                    if let s = try? await item.load(.stringValue), !s.isEmpty { genre = s; break search }
                }
            }
        }
        // strip a leading "NN - " track-number prefix from the title
        if let r = title.range(of: #"^\d+\s*-\s*"#, options: .regularExpression) { title.removeSubrange(r) }
        if album.isEmpty { album = "Unknown Album" }
        if artist.isEmpty { artist = "Unknown Artist" }

        let subfolder = albumSubfolder ?? album
        let sanitizedSub = sanitize(subfolder)
        let name = uniqueAudioName(src.lastPathComponent, in: sanitizedSub)
        let audioRel = "Audio/\(sanitizedSub)/\(name)"
        let dest = Storage.media.appendingPathComponent(audioRel)
        
        do {
            let parent = dest.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.copyItem(at: src, to: dest)
                logger.info("Copied audio file to destination: \(audioRel)")
            } else {
                logger.info("Destination audio file already exists, skipping copy: \(audioRel)")
            }
        } catch {
            logger.error("Failed to copy file to media store: \(error.localizedDescription) at path: \(dest.path)")
            return nil
        }

        let artRel = artworkData.flatMap(storeArtwork)
        let normalizationGainDB = await Task.detached(priority: .utility) {
            LoudnessAnalyzer.analyze(dest) ?? 0
        }.value
        logger.info("Metadata parsed successfully - Title: '\(title)', Artist: '\(artist)', Album: '\(album)', Duration: \(duration)s, Gain: \(normalizationGainDB) dB")
        return Track(title: title, artist: artist, album: album, genre: genre,
                     relPath: audioRel, artworkRel: artRel, duration: duration, trackNo: 0,
                     sourcePath: sourcePath, sourceSize: sourceSize, lyrics: lyrics.isEmpty ? nil : lyrics,
                     normalizationGainDB: normalizationGainDB)
    }

    /// Artwork filenames are derived from the image bytes, not an album-name
    /// hash. Different covers can therefore never alias the same cached file,
    /// while genuinely identical covers are safely shared.
    static func artworkRelativePath(for data: Data) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "Artwork/\(digest).jpg"
    }

    private static func storeArtwork(_ data: Data) -> String? {
        let rel = artworkRelativePath(for: data)
        let out = Storage.media.appendingPathComponent(rel)
        do {
            if !FileManager.default.fileExists(atPath: out.path) {
                try data.write(to: out, options: .atomic)
                logger.info("Stored new content-addressed artwork: \(rel)")
            }
            return rel
        } catch {
            logger.error("Failed to write artwork file to \(out.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Repairs libraries imported by builds that keyed artwork only by album
    /// title. Metadata reads and file hashing stay off MainActor; only the final
    /// SwiftData property updates are applied to the visible model.
    @MainActor
    static func repairArtworkIfNeeded(in tracks: [Track], context: ModelContext) async -> Int {
        guard !UserDefaults.standard.bool(forKey: artworkRepairRegistryKey), !tracks.isEmpty else { return 0 }
        logger.info("Starting artwork repair check for \(tracks.count) tracks...")
        let candidates = tracks.map { ArtworkCandidate(id: $0.id, url: $0.url) }

        let repaired = await Task.detached(priority: .utility) { () async -> [UUID: String] in
            var result: [UUID: String] = [:]
            for candidate in candidates {
                guard !Task.isCancelled else { return result }
                let asset = AVURLAsset(url: candidate.url)
                guard let metadata = try? await asset.load(.commonMetadata) else { continue }
                for item in metadata where item.commonKey == .commonKeyArtwork {
                    if let data = try? await item.load(.dataValue),
                       let rel = storeArtwork(data) {
                        result[candidate.id] = rel
                        break
                    }
                }
            }
            return result
        }.value

        guard !Task.isCancelled else { return 0 }
        var changed = 0
        for track in tracks {
            if let rel = repaired[track.id], track.artworkRel != rel {
                track.artworkRel = rel
                changed += 1
                logger.info("Repaired artwork path for track '\(track.title)': \(rel)")
            }
        }
        if changed > 0 {
            try? context.save()
            logger.info("Saved context successfully after repairing \(changed) artwork paths.")
        }
        UserDefaults.standard.set(true, forKey: artworkRepairRegistryKey)
        return changed
    }

    /// Re-reads local files that predate lyrics support. Pull-to-refresh calls
    /// this so existing synced music can gain embedded or description fallback
    /// text without being downloaded again.
    @MainActor
    static func refreshMissingLyrics(in tracks: [Track], context: ModelContext) async -> Int {
        let previouslyScanned = Set(
            (UserDefaults.standard.stringArray(forKey: lyricsScanRegistryKey) ?? [])
                .compactMap(UUID.init(uuidString:))
        )
        let candidates = tracks.compactMap { track -> LyricsCandidate? in
            guard track.lyrics?.isEmpty != false, !previouslyScanned.contains(track.id) else { return nil }
            return LyricsCandidate(id: track.id, url: track.url)
        }
        guard !candidates.isEmpty else { return 0 }
        logger.info("Found \(candidates.count) tracks candidate for lyrics scan.")

        // AVAsset metadata inspection can take seconds across a large library.
        // Keep the entire scan off MainActor and only apply plain results here.
        let scan = await Task.detached(priority: .utility) {
            var attemptedIDs: [UUID] = []
            var lyricsByID: [UUID: String] = [:]
            for candidate in candidates {
                guard !Task.isCancelled else { break }
                let asset = AVURLAsset(url: candidate.url)
                let metadata = (try? await asset.load(.metadata)) ?? []
                if let lyrics = await resolvedLyrics(from: asset, metadata: metadata) {
                    lyricsByID[candidate.id] = lyrics
                }
                attemptedIDs.append(candidate.id)
            }
            return LyricsScanResult(attemptedIDs: attemptedIDs, lyricsByID: lyricsByID)
        }.value

        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        for (id, lyrics) in scan.lyricsByID {
            if let track = tracksByID[id] {
                track.lyrics = lyrics
                logger.info("Scanned and updated lyrics for track: '\(track.title)'")
            }
        }
        let scanned = previouslyScanned.union(scan.attemptedIDs)
        UserDefaults.standard.set(scanned.map(\.uuidString), forKey: lyricsScanRegistryKey)

        let updated = scan.lyricsByID.count
        if updated > 0 {
            try? context.save()
            logger.info("Saved context successfully after refreshing lyrics for \(updated) tracks.")
        }
        return updated
    }

    /// Measures older files that were imported before loudness normalization.
    /// Pull-to-refresh uses this as a one-time, local library upgrade.
    @MainActor
    static func refreshMissingAudioAnalysis(in tracks: [Track], context: ModelContext) async -> Int {
        var updated = 0
        for track in tracks where track.normalizationGainDB == nil {
            if Task.isCancelled { break }
            let url = track.url
            logger.info("Analyzing missing loudness normalization for track '\(track.title)'")
            let gain = await Task.detached(priority: .utility) {
                LoudnessAnalyzer.analyze(url)
            }.value
            track.normalizationGainDB = gain ?? 0
            updated += 1
            logger.info("Loudness normalization analysis completed for track '\(track.title)': \(gain ?? 0) dB")
        }
        if updated > 0 {
            try? context.save()
            logger.info("Saved context successfully after analyzing \(updated) tracks.")
        }
        return updated
    }

    private static func stringKey(from key: AnyObject) -> String? {
        if let s = key as? String { return s }
        if let val = key as? Int {
            let u32 = UInt32(bitPattern: Int32(val))
            let bytes = [
                UInt8((u32 >> 24) & 0xff),
                UInt8((u32 >> 16) & 0xff),
                UInt8((u32 >> 8) & 0xff),
                UInt8(u32 & 0xff)
            ]
            return String(bytes.compactMap { $0 >= 32 && $0 <= 126 ? Character(UnicodeScalar($0)) : nil })
        }
        return nil
    }

    private static func resolvedLyrics(from asset: AVURLAsset,
                                       metadata: [AVMetadataItem]) async -> String? {
        if let value = try? await asset.load(.lyrics),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.info("Found lyrics using standard asset lyrics reader.")
            return value
        }

        // Check for any metadata item whose key is a string case-insensitively matching "lyrics"
        for item in metadata {
            if let keyString = item.key as? String,
               keyString.caseInsensitiveCompare("lyrics") == .orderedSame {
                if let value = try? await item.load(.stringValue),
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    logger.info("Found lyrics in custom metadata item: '\(keyString)'")
                    return value
                }
            }
        }

        let lyricIDs: [AVMetadataIdentifier] = [.iTunesMetadataLyrics, .id3MetadataUnsynchronizedLyric]
        for id in lyricIDs {
            for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: id) {
                if let value = try? await item.load(.stringValue),
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    logger.info("Found lyrics using metadata identifier: '\(id.rawValue)'")
                    return value
                }
            }
        }

        var descriptions: [String] = []
        for item in metadata {
            guard let key = item.key else { continue }
            let keyStr = stringKey(from: key)?.lowercased() ?? ""
            let idStr = item.identifier?.rawValue.lowercased() ?? ""
            
            let isComment = keyStr.contains("comment") || keyStr.contains("cmt") || idStr.contains("comment") || idStr.contains("cmt")
            let isDescription = keyStr.contains("desc") || keyStr.contains("synopsis") || keyStr == "ldes" || idStr.contains("desc") || idStr.contains("synopsis") || idStr.contains("ldes")
            
            if isComment || isDescription {
                if let value = try? await item.load(.stringValue), !value.isEmpty {
                    descriptions.append(value)
                }
            }
        }
        for description in descriptions {
            if let fallback = LyricsFallback.content(fromDescription: description) {
                logger.info("Found lyrics using fallback description parser.")
                return fallback
            }
        }
        return nil
    }

    /// Build a Track from a song in the phone's Music library, exporting its audio
    /// into our store as m4a so it plays fully offline like everything else.
    static func makeTrack(from item: MPMediaItem) async -> Track? {
        guard let src = item.assetURL else { return nil }
        let stem = sanitize(item.title ?? "Song")
        let albumTitle = item.albumTitle ?? "Unknown Album"
        let sanitizedSub = sanitize(albumTitle)
        let name = uniqueAudioName("\(stem).m4a", in: sanitizedSub)
        let audioRel = "Audio/\(sanitizedSub)/\(name)"
        let dest = Storage.media.appendingPathComponent(audioRel)
        
        do {
            let parent = dest.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch { return nil }

        let asset = AVURLAsset(url: src)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        do {
            try await ex.export(to: dest, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }

        var artRel: String?
        if let img = item.artwork?.image(at: CGSize(width: 600, height: 600)),
           let data = img.jpegData(compressionQuality: 0.85) {
            let key = item.albumTitle ?? item.title ?? UUID().uuidString
            let rel = "Artwork/\(abs(key.hashValue)).jpg"
            let out = Storage.media.appendingPathComponent(rel)
            if !FileManager.default.fileExists(atPath: out.path) { try? data.write(to: out) }
            artRel = rel
        }

        let normalizationGainDB = await Task.detached(priority: .utility) {
            LoudnessAnalyzer.analyze(dest) ?? 0
        }.value

        return Track(title: item.title ?? "Unknown",
                     artist: item.artist ?? "Unknown Artist",
                     album: albumTitle,
                     genre: item.genre ?? "",
                     relPath: audioRel, artworkRel: artRel,
                     duration: item.playbackDuration, trackNo: item.albumTrackNumber,
                     lyrics: item.lyrics, normalizationGainDB: normalizationGainDB)
    }

    static func sanitize(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
    }

    private static func uniqueAudioName(_ name: String, in subfolder: String? = nil) -> String {
        var dir = Storage.media.appendingPathComponent("Audio")
        if let sub = subfolder { dir = dir.appendingPathComponent(sub) }
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

// Group tracks by artist / genre for browsing.
struct ArtistGroup: Identifiable {
    var id: String { name }
    let name: String
    let tracks: [Track]
    var albumCount: Int { Set(tracks.map { $0.album }).count }
    var artworkURL: URL? { tracks.first(where: { $0.artworkURL != nil })?.artworkURL }
}

struct GenreGroup: Identifiable {
    var id: String { name }
    let name: String
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

    static func artists(_ tracks: [Track]) -> [ArtistGroup] {
        Dictionary(grouping: tracks, by: { $0.artist })
            .map { ArtistGroup(name: $0.key, tracks: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func genres(_ tracks: [Track]) -> [GenreGroup] {
        Dictionary(grouping: tracks, by: { $0.genre.isEmpty ? "Unknown" : $0.genre })
            .map { GenreGroup(name: $0.key, tracks: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

import Foundation
import SwiftData
import os

// Pulls the library from the Snag Mac app over Wi‑Fi (its PIN-protected web server).
@MainActor
final class SyncClient: ObservableObject {
    @Published var status = ""
    @Published var progress = 0.0
    @Published var busy = false

    private let logger = Logger(subsystem: "com.costa.SnagPlayer", category: "SyncClient")

    struct Manifest: Decodable {
        let tracks: [Item]
        let playlists: [PlaylistManifest]?

        struct Item: Decodable {
            let path: String
            let size: Int
        }

        struct PlaylistManifest: Decodable {
            let name: String
            let tracks: [String]
        }
    }

    func sync(host rawHost: String, pin: String, into ctx: ModelContext) async {
        busy = true; progress = 0; status = "Connecting…"
        defer { busy = false }

        let host = rawHost.trimmingCharacters(in: .whitespaces)
        let base = host.hasPrefix("http") ? host : "http://\(host)"
        guard let baseURL = URL(string: base) else {
            status = "That address doesn't look right."
            logger.error("Invalid host URL configured: \(rawHost)")
            return
        }

        logger.info("Sync started. Authenticating with Snag Mac server at \(base)...")
        // 1) authenticate (server sets a session cookie stored by URLSession)
        var login = URLRequest(url: baseURL.appendingPathComponent("login"))
        login.httpMethod = "POST"
        login.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        login.httpBody = "pin=\(pin)".data(using: .utf8)
        
        do {
            _ = try await URLSession.shared.data(for: login)
            logger.info("Sent login request to server.")
        } catch {
            logger.error("Authentication request failed: \(error.localizedDescription)")
        }

        // 2) fetch the manifest
        status = "Reading your Mac's library…"
        guard let manURL = URL(string: "\(base)/manifest"),
              let (mdata, resp) = try? await URLSession.shared.data(from: manURL),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: mdata) else {
            status = "Couldn't reach Snag on the Mac. Check the address, PIN, and that Wireless is on."
            logger.error("Failed to reach server manifest endpoint or parse response.")
            return
        }
        logger.info("Successfully fetched manifest containing \(manifest.tracks.count) tracks.")

        // 3) download the tracks we don't have yet
        let localTracks = (try? ctx.fetch(FetchDescriptor<Track>())) ?? []
        var todo: [(item: Manifest.Item, replacing: Track?)] = []
        var updatedAny = false

        for item in manifest.tracks {
            if let matchedTrack = matchingTrack(manifestPath: item.path, manifestSize: item.size, localTracks: localTracks) {
                if matchedTrack.sourcePath == nil || matchedTrack.sourcePath?.isEmpty == true {
                    matchedTrack.sourcePath = item.path
                    updatedAny = true
                }
                let remoteSize = Int64(item.size)
                if matchedTrack.sourceSize == remoteSize { continue }
                if matchedTrack.sourceSize == nil,
                   fileSize(of: matchedTrack.url) == remoteSize,
                   matchedTrack.sourcePath?.caseInsensitiveCompare(item.path) != .orderedSame {
                    matchedTrack.sourceSize = remoteSize
                    updatedAny = true
                    continue
                }
                todo.append((item, matchedTrack))
                logger.info("Queued track for replacement/refresh (size mismatch): '\(item.path)'")
            } else {
                todo.append((item, nil))
                logger.info("Queued track for download (new track): '\(item.path)'")
            }
        }
        if updatedAny {
            try? ctx.save()
            logger.info("Saved local context updates for matched tracks.")
        }

        if todo.isEmpty {
            logger.info("No new or updated tracks found to download. Library is up to date.")
            await syncPlaylists(manifest.playlists, into: ctx)
            status = "Up to date — \(manifest.tracks.count) tracks."; progress = 1; return
        }

        logger.info("Starting downloads for \(todo.count) tracks...")
        var done = 0
        var refreshed = 0
        for pending in todo {
            let item = pending.item
            status = "Downloading \(done + 1) of \(todo.count)…"
            let enc = item.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.path
            guard let fileURL = URL(string: "\(base)/f/\(enc)"),
                  let (tmp, response) = try? await URLSession.shared.download(from: fileURL),
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                logger.error("Failed to download track from server: \(item.path)")
                continue
            }

            let pathParts = item.path.split(separator: "/")
            let serverAlbum = pathParts.count >= 2 ? String(pathParts[0]) : nil

            let named = FileManager.default.temporaryDirectory
                .appendingPathComponent((item.path as NSString).lastPathComponent)
            try? FileManager.default.removeItem(at: named)
            try? FileManager.default.moveItem(at: tmp, to: named)
            
            logger.info("Importing downloaded file: \(named.lastPathComponent)")
            if let track = await Importer.makeTrack(from: named, albumSubfolder: serverAlbum,
                                                    sourcePath: item.path, sourceSize: Int64(item.size)) {
                if let existing = pending.replacing {
                    replace(existing, with: track)
                    refreshed += 1
                    logger.info("Successfully refreshed existing track: '\(track.title)'")
                } else {
                    ctx.insert(track)
                    logger.info("Successfully inserted new track: '\(track.title)'")
                }
                done += 1
            } else {
                logger.error("Failed to import downloaded track: \(item.path)")
            }
            try? FileManager.default.removeItem(at: named)
            progress = Double(done) / Double(todo.count)
        }
        do {
            try ctx.save()
            logger.info("Saved SwiftData context successfully after downloading tracks.")
        } catch {
            logger.error("Failed to save SwiftData context after downloading: \(error.localizedDescription)")
        }

        await syncPlaylists(manifest.playlists, into: ctx)

        let newCount = done - refreshed
        status = refreshed > 0
            ? "Synced \(newCount) new and refreshed \(refreshed) track\(refreshed == 1 ? "" : "s") 🎉"
            : "Synced \(newCount) new track\(newCount == 1 ? "" : "s") 🎉"
        logger.info("Sync session finished. New: \(newCount), Refreshed: \(refreshed)")
        progress = 1
    }

    private func matchingTrack(manifestPath: String, manifestSize: Int, localTracks: [Track]) -> Track? {
        let manifestPathLower = manifestPath.lowercased()
        let manifestURL = URL(fileURLWithPath: manifestPathLower)
        let manifestFilename = manifestURL.lastPathComponent
        let manifestAlbumFolder = manifestURL.deletingLastPathComponent().lastPathComponent

        // Strategy 1: Exact sourcePath match
        if let match = localTracks.first(where: { $0.sourcePath?.lowercased() == manifestPathLower }) {
            return match
        }

        // Strategy 2: Sanitized album folder + filename match
        let cleanManifestAlbum = Importer.sanitize(manifestAlbumFolder).lowercased()
        for t in localTracks {
            let localURL = URL(fileURLWithPath: t.relPath)
            let localFilename = localURL.lastPathComponent.lowercased()
            let localAlbumFolder = localURL.deletingLastPathComponent().lastPathComponent.lowercased()

            if localFilename == manifestFilename && localAlbumFolder == cleanManifestAlbum {
                return t
            }
        }

        // Strategy 3: Filename + File size similarity (within 250KB tolerance)
        for t in localTracks {
            let localURL = URL(fileURLWithPath: t.relPath)
            let localFilename = localURL.lastPathComponent.lowercased()
            if localFilename == manifestFilename {
                let localPath = t.url.path
                if let attrs = try? FileManager.default.attributesOfItem(atPath: localPath),
                   let size = attrs[.size] as? Int64 {
                    let diff = abs(size - Int64(manifestSize))
                    if diff < 250 * 1024 {
                        return t
                    }
                }
            }
        }

        return nil
    }

    private func fileSize(of url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }

    private func replace(_ existing: Track, with imported: Track) {
        let previousURL = existing.url
        existing.title = imported.title
        existing.artist = imported.artist
        existing.album = imported.album
        existing.genre = imported.genre
        existing.relPath = imported.relPath
        existing.artworkRel = imported.artworkRel
        existing.duration = imported.duration
        existing.trackNo = imported.trackNo
        existing.sourcePath = imported.sourcePath
        existing.sourceSize = imported.sourceSize
        existing.lyrics = imported.lyrics
        if previousURL != existing.url { try? FileManager.default.removeItem(at: previousURL) }
    }

    private func syncPlaylists(_ serverPlaylists: [Manifest.PlaylistManifest]?, into ctx: ModelContext) async {
        guard let serverPlaylists, !serverPlaylists.isEmpty else { return }

        status = "Syncing playlists…"

        // Fetch all tracks currently in the local SwiftData store to build a lookup map
        let allTracks = (try? ctx.fetch(FetchDescriptor<Track>())) ?? []
        var trackLookup: [String: Track] = [:]
        for t in allTracks {
            // exact match on the original Mac path (robust for any album name)…
            if let sp = t.sourcePath, !sp.isEmpty { trackLookup[sp.lowercased()] = t }
            // …plus an album/filename fallback for tracks added another way
            let filename = (t.relPath as NSString).lastPathComponent
            trackLookup["\(t.album.lowercased())/\(filename.lowercased())"] = t
        }

        // Fetch existing local playlists to avoid duplicating them. Names aren't
        // unique in the app, so keep the first match rather than trapping on a dup key.
        let existingPlaylists = (try? ctx.fetch(FetchDescriptor<Playlist>())) ?? []
        var playlistMap = Dictionary(existingPlaylists.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        for p in serverPlaylists {
            var matchedIDs: [UUID] = []
            for serverTrackPath in p.tracks {
                let key = serverTrackPath.lowercased()
                if let t = trackLookup[key] {
                    matchedIDs.append(t.id)
                }
            }

            guard !matchedIDs.isEmpty else { continue }

            if let localPlaylist = playlistMap[p.name] {
                localPlaylist.trackIDs = matchedIDs
            } else {
                let newPlaylist = Playlist(name: p.name, trackIDs: matchedIDs)
                ctx.insert(newPlaylist)
                playlistMap[p.name] = newPlaylist
            }
        }
        try? ctx.save()
    }
}

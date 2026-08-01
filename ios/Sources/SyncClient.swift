import Foundation
import SwiftData

// Pulls the library from the Snag Mac app over Wi‑Fi (its PIN-protected web server).
@MainActor
final class SyncClient: ObservableObject {
    @Published var status = ""
    @Published var progress = 0.0
    @Published var busy = false

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

    func sync(host rawHost: String, pin: String, existingFilenames: Set<String>, into ctx: ModelContext) async {
        busy = true; progress = 0; status = "Connecting…"
        defer { busy = false }

        let host = rawHost.trimmingCharacters(in: .whitespaces)
        let base = host.hasPrefix("http") ? host : "http://\(host)"
        guard let baseURL = URL(string: base) else { status = "That address doesn't look right."; return }

        // 1) authenticate (server sets a session cookie stored by URLSession)
        var login = URLRequest(url: baseURL.appendingPathComponent("login"))
        login.httpMethod = "POST"
        login.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        login.httpBody = "pin=\(pin)".data(using: .utf8)
        _ = try? await URLSession.shared.data(for: login)

        // 2) fetch the manifest
        status = "Reading your Mac's library…"
        guard let manURL = URL(string: "\(base)/manifest"),
              let (mdata, resp) = try? await URLSession.shared.data(from: manURL),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: mdata) else {
            status = "Couldn't reach Snag on the Mac. Check the address, PIN, and that Wireless is on."
            return
        }

        // 3) download the tracks we don't have yet
        let todo = manifest.tracks.filter {
            !existingFilenames.contains($0.path.lowercased())
        }
        if todo.isEmpty {
            await syncPlaylists(manifest.playlists, into: ctx)
            status = "Up to date — \(manifest.tracks.count) tracks."; progress = 1; return
        }

        var done = 0
        for item in todo {
            status = "Downloading \(done + 1) of \(todo.count)…"
            let enc = item.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.path
            guard let fileURL = URL(string: "\(base)/f/\(enc)"),
                  let (tmp, _) = try? await URLSession.shared.download(from: fileURL) else { continue }
            
            let pathParts = item.path.split(separator: "/")
            let serverAlbum = pathParts.count >= 2 ? String(pathParts[0]) : nil
            
            let named = FileManager.default.temporaryDirectory
                .appendingPathComponent((item.path as NSString).lastPathComponent)
            try? FileManager.default.removeItem(at: named)
            try? FileManager.default.moveItem(at: tmp, to: named)
            if let track = await Importer.makeTrack(from: named, albumSubfolder: serverAlbum, sourcePath: item.path) { ctx.insert(track); done += 1 }
            try? FileManager.default.removeItem(at: named)
            progress = Double(done) / Double(todo.count)
        }
        try? ctx.save()
        
        await syncPlaylists(manifest.playlists, into: ctx)
        
        status = "Synced \(done) new track\(done == 1 ? "" : "s") 🎉"
        progress = 1
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

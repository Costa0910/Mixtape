import Foundation
import SwiftData

// Pulls the library from the Snag Mac app over Wi‑Fi (its PIN-protected web server).
@MainActor
final class SyncClient: ObservableObject {
    @Published var status = ""
    @Published var progress = 0.0
    @Published var busy = false

    struct Manifest: Decodable { let tracks: [Item]; struct Item: Decodable { let path: String; let size: Int } }

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
            !existingFilenames.contains(($0.path as NSString).lastPathComponent)
        }
        if todo.isEmpty { status = "Up to date — \(manifest.tracks.count) tracks."; progress = 1; return }

        var done = 0
        for item in todo {
            status = "Downloading \(done + 1) of \(todo.count)…"
            let enc = item.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.path
            guard let fileURL = URL(string: "\(base)/f/\(enc)"),
                  let (tmp, _) = try? await URLSession.shared.download(from: fileURL) else { continue }
            let named = FileManager.default.temporaryDirectory
                .appendingPathComponent((item.path as NSString).lastPathComponent)
            try? FileManager.default.removeItem(at: named)
            try? FileManager.default.moveItem(at: tmp, to: named)
            if let track = await Importer.makeTrack(from: named) { ctx.insert(track); done += 1 }
            try? FileManager.default.removeItem(at: named)
            progress = Double(done) / Double(todo.count)
        }
        try? ctx.save()
        status = "Synced \(done) new track\(done == 1 ? "" : "s") 🎉"
        progress = 1
    }
}

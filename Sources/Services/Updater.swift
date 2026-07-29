import Foundation

// Keeps yt-dlp fresh. Because the bundled copy lives inside the signed app
// (read-only), updates are downloaded to Application Support and preferred by
// BinaryLocator — so YouTube changes don't silently break downloads.
enum Updater {
    static var binDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Snag/bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func currentVersion() async -> String? {
        guard let exe = BinaryLocator.url(for: .ytdlp) else { return nil }
        let out = try? await ProcessRunner.capture(exe, ["--version"])
        return out?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func latestVersion() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        return tag.trimmingCharacters(in: .whitespaces)
    }

    /// Downloads a newer yt-dlp if available. Returns a human-readable status.
    @discardableResult
    static func updateYtdlp(force: Bool) async -> String {
        let current = await currentVersion() ?? "unknown"
        guard let latest = await latestVersion() else {
            return "Couldn't reach the update server."
        }
        if current == latest && !force {
            return "yt-dlp is up to date (\(current))."
        }
        if current == latest {
            return "Already on the latest yt-dlp (\(current))."
        }
        guard let dl = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos") else {
            return "Update URL error."
        }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: dl)
            let dest = binDir.appendingPathComponent("yt-dlp")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            return "Updated yt-dlp \(current) → \(latest)."
        } catch {
            return "Update failed: \(error.localizedDescription)"
        }
    }
}

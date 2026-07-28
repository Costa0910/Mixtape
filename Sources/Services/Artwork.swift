import AppKit

// Extracts embedded cover art from a track (cached), for library thumbnails.
actor ArtworkStore {
    static let shared = ArtworkStore()
    private var cache: [String: NSImage] = [:]

    func artwork(for album: AlbumFolder) async -> NSImage? {
        if let hit = cache[album.id] { return hit }
        guard let ffmpeg = await MainActor.run(body: { BinaryLocator.url(for: .ffmpeg) }) else { return nil }
        let fm = FileManager.default
        guard let first = (try? fm.contentsOfDirectory(at: album.url, includingPropertiesForKeys: nil))?
            .filter({ Media.isMedia($0) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first else { return nil }

        let out = fm.temporaryDirectory.appendingPathComponent("snag-art-\(abs(album.id.hashValue)).png")
        let args = ["-v", "error", "-y", "-i", first.path, "-an", "-map", "0:v", "-frames:v", "1", out.path]
        _ = try? await ProcessRunner.capture(ffmpeg, args)
        guard let img = NSImage(contentsOf: out) else { return nil }
        cache[album.id] = img
        return img
    }
}

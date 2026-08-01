import Foundation

struct Organizer {

    static func safeName(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "/", with: "-")
                   .replacingOccurrences(of: ":", with: "-")
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "Untitled" : out
    }

    private static func ffmpeg() throws -> URL {
        guard let u = BinaryLocator.url(for: .ffmpeg) else { throw RunError.notFound("ffmpeg") }
        return u
    }

    private static func parseSubtitlesToLyrics(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var lyricLines: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "WEBVTT" || trimmed.hasPrefix("Kind:") || trimmed.hasPrefix("Language:") {
                continue
            }
            if CharacterSet(charactersIn: trimmed).isSubset(of: .decimalDigits) {
                continue
            }
            if trimmed.contains("-->") {
                continue
            }
            let cleanLine = trimmed.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            if !cleanLine.isEmpty {
                lyricLines.append(cleanLine)
            }
        }
        
        return lyricLines.joined(separator: "\n")
    }

    // Tag every audio file in the album folder with album / album_artist / track,
    // preserving audio + cover art. Reports 0…1 progress.
    static func tagAlbum(_ albumDir: URL,
                         album: String,
                         genre: String?,
                         onProgress: @escaping (Double, String) -> Void) async throws {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: albumDir, includingPropertiesForKeys: nil))?
            .filter { Media.audio.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        guard !files.isEmpty else { return }

        let exe = try ffmpeg()
        for (i, file) in files.enumerated() {
            let base = file.lastPathComponent
            let track = base.prefix(while: { $0.isNumber || $0 == "0" })
            let trackNum = Int(track) ?? (i + 1)
            let tmp = albumDir.appendingPathComponent(".tmp-\(base)")

            var meta = ["-metadata", "album=\(album)",
                        "-metadata", "album_artist=Various Artists",
                        "-metadata", "track=\(trackNum)"]
            if let g = genre { meta += ["-metadata", "genre=\(g)"] }

            // Look for matching subtitle file
            let baseName = file.deletingPathExtension().lastPathComponent
            let allFilesInFolder = (try? fm.contentsOfDirectory(at: albumDir, includingPropertiesForKeys: nil)) ?? []
            let subtitleFile = allFilesInFolder.first { f in
                let fName = f.lastPathComponent
                return fName.hasPrefix(baseName) && (f.pathExtension.lowercased() == "srt" || f.pathExtension.lowercased() == "vtt" || f.pathExtension.lowercased() == "lrc")
            }

            if let subFile = subtitleFile, let content = try? String(contentsOf: subFile, encoding: .utf8) {
                let cleanLyrics = parseSubtitlesToLyrics(content)
                if !cleanLyrics.isEmpty {
                    meta += ["-metadata", "lyrics=\(cleanLyrics)"]
                }
            }

            let args = ["-v", "error", "-y", "-i", file.path,
                        "-map", "0", "-map", "-0:d", "-c", "copy"] + meta + [tmp.path]
            _ = try await ProcessRunner.capture(exe, args)
            // swap tmp -> original
            try? fm.removeItem(at: file)
            try fm.moveItem(at: tmp, to: file)

            // Clean up sidecar subtitle file
            if let subFile = subtitleFile {
                try? fm.removeItem(at: subFile)
            }

            onProgress(Double(i + 1) / Double(files.count), base)
        }
    }

    // Write an .m3u8 for a single album folder + refresh the "All Songs" one.
    static func writePlaylists(libraryRoot: URL) throws {
        let fm = FileManager.default
        let albums = (try? fm.contentsOfDirectory(at: libraryRoot, includingPropertiesForKeys: nil))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        var allLines = ["#EXTM3U"]
        for album in albums {
            let tracks = (try? fm.contentsOfDirectory(at: album, includingPropertiesForKeys: nil))?
                .filter { Media.audio.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            guard !tracks.isEmpty else { continue }

            var lines = ["#EXTM3U"]
            for t in tracks {
                let rel = "\(album.lastPathComponent)/\(t.lastPathComponent)"
                lines.append(rel)
                allLines.append(rel)
            }
            let m3u = libraryRoot.appendingPathComponent("\(album.lastPathComponent).m3u8")
            try lines.joined(separator: "\n").write(to: m3u, atomically: true, encoding: .utf8)
        }
        if allLines.count > 1 {
            let all = libraryRoot.appendingPathComponent("00 All Songs.m3u8")
            try allLines.joined(separator: "\n").write(to: all, atomically: true, encoding: .utf8)
        }
    }
}

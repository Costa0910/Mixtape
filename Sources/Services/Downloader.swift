import Foundation

struct DownloadProgress {
    var itemIndex: Int = 0
    var itemTotal: Int = 0
    var filePercent: Double = 0
    var currentTitle: String = ""
    var line: String = ""
}

struct Downloader {

    private static func ytdlp() throws -> URL {
        guard let u = BinaryLocator.url(for: .ytdlp) else { throw RunError.notFound("yt-dlp") }
        return u
    }

    // Inspect a URL/playlist without downloading.
    static func analyze(_ urlString: String) async throws -> Analysis {
        let exe = try ytdlp()
        let fmt = "%(playlist_index)s\t%(id)s\t%(title)s\t%(duration)s\t%(playlist_title)s"
        let out = try await ProcessRunner.capture(exe, [
            "--flat-playlist", "--ignore-errors", "--no-warnings",
            "--print", fmt, urlString
        ])

        var entries: [TrackEntry] = []
        var album = "Downloaded Music"
        var autoIndex = 0
        for raw in out.split(separator: "\n") {
            let cols = raw.components(separatedBy: "\t")
            guard cols.count >= 3 else { continue }
            autoIndex += 1
            let idx = Int(cols[0]) ?? autoIndex
            let id = cols[1]
            let title = cols[2]
            let dur = cols.count > 3 ? Int(Double(cols[3]) ?? 0) : nil
            let plTitle = cols.count > 4 ? cols[4] : "NA"
            if plTitle != "NA" && !plTitle.isEmpty { album = plTitle }
            let vlog = title.range(of: "vlog", options: .caseInsensitive) != nil
            entries.append(TrackEntry(id: id, index: idx, title: title,
                                      duration: dur, isLikelyVlog: vlog))
        }
        if entries.count == 1 { album = entries[0].title }
        if entries.isEmpty { throw RunError.exit(1, "No downloadable media found at that URL.") }
        return Analysis(albumName: album, entries: entries)
    }

    // Download audio into <libraryRoot>/<album>/. Returns that album folder URL.
    static func download(url: String,
                         album: String,
                         kind: MediaKind,
                         format: AudioFormat,
                         mp3Bitrate: String,
                         videoQuality: String,
                         skipVlogs: Bool,
                         libraryRoot: URL,
                         padding: Int = 3,
                         onProgress: @escaping (DownloadProgress) -> Void) async throws -> URL {
        let exe = try ytdlp()
        let safeAlbum = Organizer.safeName(album)
        let albumDir = libraryRoot.appendingPathComponent(safeAlbum, isDirectory: true)
        try FileManager.default.createDirectory(at: albumDir, withIntermediateDirectories: true)

        var args: [String] = []
        switch kind {
        case .video:
            if videoQuality == "best" {
                args += ["-f", "bv*+ba/b"]
            } else {
                args += ["-f", "bv*[height<=\(videoQuality)]+ba/b[height<=\(videoQuality)]"]
            }
            args += ["--merge-output-format", "mp4"]
        case .music, .audio:
            if format.reencodes {
                args += ["-f", "bestaudio/best", "-x", "--audio-format", format == .best ? "best" : format.rawValue]
                if format == .mp3 { args += ["--audio-quality", mp3Bitrate] }
            } else {
                args += ["-f", "bestaudio[ext=m4a]/bestaudio"]
            }
        }
        args += [
            "--embed-thumbnail", "--embed-metadata",
            "--ignore-errors", "--no-warnings", "--newline",
        ]
        if skipVlogs { args += ["--match-filters", "title!~=(?i)vlog"] }
        let pad = max(1, min(padding, 4))
        let template = albumDir.appendingPathComponent("%(playlist_index,autonumber)0\(pad)d - %(title)s.%(ext)s").path
        args += ["-o", template, url]

        var prog = DownloadProgress()
        for try await line in ProcessRunner.stream(exe, args) {
            prog.line = line
            if let r = line.range(of: #"Downloading item (\d+) of (\d+)"#, options: .regularExpression) {
                let nums = line[r].components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
                if nums.count >= 2 { prog.itemIndex = nums[0]; prog.itemTotal = nums[1] }
            }
            if let pr = line.range(of: #"([0-9.]+)% of"#, options: .regularExpression) {
                let n = line[pr].components(separatedBy: CharacterSet(charactersIn: "% of")).first ?? ""
                prog.filePercent = Double(n.trimmingCharacters(in: .whitespaces)) ?? prog.filePercent
            }
            if line.contains("[download] Destination:") || line.contains("[ExtractAudio] Destination:") {
                if let name = line.components(separatedBy: "Destination:").last {
                    prog.currentTitle = (name as NSString).lastPathComponent
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            onProgress(prog)
        }
        return albumDir
    }
}

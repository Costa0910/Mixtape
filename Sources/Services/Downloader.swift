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

    // Download into <libraryRoot>/<album>/. Resilient: continues past failed
    // items, resumes on retry, and reports how many files/errors resulted.
    static func download(url: String,
                         album: String,
                         config: JobConfig,
                         libraryRoot: URL,
                         onProgress: @escaping (DownloadProgress) -> Void) async throws -> DownloadOutcome {
        let exe = try ytdlp()
        let safeAlbum = Organizer.safeName(album)
        let albumDir = libraryRoot.appendingPathComponent(safeAlbum, isDirectory: true)
        try FileManager.default.createDirectory(at: albumDir, withIntermediateDirectories: true)

        var args: [String] = []
        switch config.kind {
        case .video:
            if config.videoQuality == "best" {
                args += ["-f", "bv*+ba/b"]
            } else {
                args += ["-f", "bv*[height<=\(config.videoQuality)]+ba/b[height<=\(config.videoQuality)]"]
            }
            args += ["--merge-output-format", config.videoContainer]
            if config.embedSubtitles {
                args += ["--embed-subs", "--sub-langs", config.subtitleLang, "--convert-subs", "srt"]
            }
        case .music, .audio:
            if config.format.reencodes {
                args += ["-f", "bestaudio/best", "-x",
                         "--audio-format", config.format == .best ? "best" : config.format.rawValue]
                if config.format == .mp3 { args += ["--audio-quality", config.bitrate] }
            } else {
                args += ["-f", "bestaudio[ext=m4a]/bestaudio"]
            }
        }
        if config.embedThumbnail { args += ["--embed-thumbnail"] }
        args += ["--embed-metadata", "--newline"]
        // resilience: keep going past errors, never abort a playlist on one bad item
        args += ["--ignore-errors", "--no-abort-on-error", "--no-warnings"]
        // resume: record completed items + never re-download / overwrite existing files
        if config.resume {
            args += ["--download-archive", albumDir.appendingPathComponent(".snag-archive.txt").path,
                     "--no-overwrites", "--continue"]
        }
        if config.kind == .music && config.skipVlogs {
            args += ["--match-filters", "title!~=(?i)vlog"]
        }
        let pad = max(1, min(config.trackPadding, 4))
        let prefix = config.numberTracks ? "%(playlist_index,autonumber)0\(pad)d - " : ""
        let template = albumDir.appendingPathComponent("\(prefix)%(title)s.%(ext)s").path
        args += ["-o", template, url]

        var prog = DownloadProgress()
        var errors = 0
        do {
            for try await line in ProcessRunner.stream(exe, args) {
                prog.line = line
                if line.range(of: #"^ERROR:"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    errors += 1
                }
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
        } catch let e as RunError {
            // yt-dlp exits non-zero when some items failed; that's fine as long as
            // we produced files. Only a total wipeout is a real failure.
            if case .exit = e {} else { throw e }
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: albumDir, includingPropertiesForKeys: nil))?
            .filter { Media.isMedia($0) }.count ?? 0
        if files == 0 {
            throw RunError.exit(1, errors > 0
                ? "Nothing downloaded (\(errors) error\(errors == 1 ? "" : "s"))."
                : "Nothing downloaded — the link may be unavailable.")
        }
        return DownloadOutcome(albumDir: albumDir, filesPresent: files, errors: errors)
    }
}

import Foundation

struct Transfer {

    private static func run(_ path: String, _ args: [String]) async throws -> String {
        try await ProcessRunner.capture(URL(fileURLWithPath: path), args)
    }

    // MARK: Detection

    static func detectPhones() async -> [Phone] {
        var phones: [Phone] = []
        // Android via adb
        if let adb = BinaryLocator.url(for: .adb) {
            if let out = try? await ProcessRunner.capture(adb, ["devices"]) {
                for line in out.split(separator: "\n").dropFirst() {
                    let cols: [String] = String(line)
                        .components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }
                    guard cols.count >= 2 else { continue }
                    let serial = cols[0], state = cols[1]
                    guard state == "device" else {
                        if state == "unauthorized" {
                            phones.append(Phone(id: serial, kind: .android,
                                                name: "Android (tap Allow on phone)", freeBytes: nil))
                        }
                        continue
                    }
                    let model = (try? await ProcessRunner.capture(adb, ["-s", serial, "shell", "getprop", "ro.product.model"]))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Android device"
                    var free: Int64? = nil
                    if let df = try? await ProcessRunner.capture(adb, ["-s", serial, "shell", "df", "/sdcard"]) {
                        // last line, "Avail" column (in 1K blocks)
                        if let last = df.split(separator: "\n").last {
                            let parts = last.split(whereSeparator: { $0 == " " }).map(String.init)
                            if parts.count >= 4, let kb = Int64(parts[3]) { free = kb * 1024 }
                        }
                    }
                    phones.append(Phone(id: serial, kind: .android, name: model, freeBytes: free))
                }
            }
        }
        // iPhone via system_profiler (presence only; iOS blocks deeper access)
        if let usb = try? await run("/usr/sbin/system_profiler", ["SPUSBDataType"]) {
            let lines = usb.split(separator: "\n").map(String.init)
            for (i, l) in lines.enumerated() where l.contains("iPhone") || l.contains("iPad") {
                let name = l.trimmingCharacters(in: CharacterSet(charactersIn: " :"))
                var serial = "ios-\(i)"
                for j in i..<min(i + 12, lines.count) where lines[j].contains("Serial Number:") {
                    serial = lines[j].components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? serial
                    break
                }
                if !phones.contains(where: { $0.id == serial }) {
                    phones.append(Phone(id: serial, kind: .iphone, name: name, freeBytes: nil))
                }
                break
            }
        }
        return phones
    }

    // MARK: Android — fully automatic

    static func pushAndroid(libraryRoot: URL,
                            albums: [AlbumFolder],
                            phone: Phone,
                            onProgress: @escaping (Double, String) -> Void) async throws {
        guard let adb = BinaryLocator.url(for: .adb) else { throw RunError.notFound("adb") }
        let rootName = libraryRoot.lastPathComponent
        // audio → Music, video → Movies (so each shows in the right phone app)
        let musicBase = "/sdcard/Music/\(rootName)"
        let movieBase = "/sdcard/Movies/\(rootName)"
        let hasAudio = albums.contains { !$0.isVideo }
        let hasVideo = albums.contains { $0.isVideo }
        if hasAudio { _ = try? await ProcessRunner.capture(adb, ["-s", phone.id, "shell", "mkdir", "-p", musicBase]) }
        if hasVideo { _ = try? await ProcessRunner.capture(adb, ["-s", phone.id, "shell", "mkdir", "-p", movieBase]) }

        let total = max(albums.count, 1)
        for (i, album) in albums.enumerated() {
            let base = album.isVideo ? movieBase : musicBase
            for try await line in ProcessRunner.stream(adb, ["-s", phone.id, "push", album.url.path, base + "/"]) {
                if let r = line.range(of: #"(\d+)%"#, options: .regularExpression) {
                    let pct = (Double(line[r].dropLast()) ?? 0) / 100.0
                    onProgress((Double(i) + pct) / Double(total), "Copying \(album.name)…")
                }
            }
        }
        // playlists go with the audio (best-effort)
        if hasAudio, let m3us = try? FileManager.default.contentsOfDirectory(at: libraryRoot, includingPropertiesForKeys: nil) {
            for pl in m3us where pl.pathExtension == "m3u8" {
                _ = try? await ProcessRunner.capture(adb, ["-s", phone.id, "push", pl.path, musicBase + "/"])
            }
        }
        // force a media scan so players see the new files (sets is_music/duration)
        for base in [hasAudio ? musicBase : nil, hasVideo ? movieBase : nil].compactMap({ $0 }) {
            let scan = "find '\(base)' -type f | while read f; do am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \"file://$f\" >/dev/null 2>&1; done; echo scanned"
            _ = try? await ProcessRunner.capture(adb, ["-s", phone.id, "shell", scan])
        }
    }

    // MARK: iPhone — assisted (Apple blocks full automation)

    // Copies audio into Music's auto-import folder and opens Music. The user
    // does the final "Sync" in Finder. Returns a human-readable status.
    static func prepareIPhone(albums: [AlbumFolder]) async throws -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let autoAdd = home
            .appendingPathComponent("Music/Music/Media.localized/Automatically Add to Music.localized")
        guard fm.fileExists(atPath: autoAdd.path) else {
            throw RunError.exit(1, "Couldn't find the Music auto-import folder. Open the Music app once, then retry.")
        }
        var count = 0
        var skippedVideo = 0
        for album in albums {
            let files = (try? fm.contentsOfDirectory(at: album.url, includingPropertiesForKeys: nil)) ?? []
            for f in files where Media.isMedia(f) {
                guard Media.isAudio(f) else { skippedVideo += 1; continue }
                let dest = autoAdd.appendingPathComponent(f.lastPathComponent)
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: f, to: dest)
                count += 1
            }
        }
        _ = try? await run("/usr/bin/open", ["-a", "Music"])
        var msg = "Imported \(count) audio track(s) into the Music app. Now open Finder → your iPhone → Music tab → tick “Sync music” → Sync."
        if skippedVideo > 0 {
            msg += "\n\(skippedVideo) video file(s) were skipped — iPhone doesn't take video via Music. Use Finder → your iPhone → Files → an app like VLC to copy those."
        }
        return msg
    }
}

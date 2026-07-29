import Foundation

struct Transfer {

    private static func run(_ path: String, _ args: [String]) async throws -> String {
        try await ProcessRunner.capture(URL(fileURLWithPath: path), args)
    }

    // MARK: Detection

    // Known Android phone USB vendor IDs (Samsung, Google, Xiaomi, OnePlus,
    // Huawei, Motorola, LG, Sony, ZTE, HTC, Oppo/Realme, Vivo, Nothing…).
    private static let androidVendorIDs = [
        "0x04e8", "0x18d1", "0x2717", "0x2a70", "0x12d1", "0x22b8", "0x1004",
        "0x0fce", "0x19d2", "0x0bb4", "0x22d9", "0x2d95", "0x2c7c",
    ]

    static func detectPhones() async -> [Phone] {
        var phones: [Phone] = []

        // Android via adb (make sure the server is up first so we get clean output)
        if let adb = BinaryLocator.url(for: .adb) {
            _ = try? await ProcessRunner.capture(adb, ["start-server"])
            if let out = try? await ProcessRunner.capture(adb, ["devices"]) {
                for line in out.split(separator: "\n") {
                    let cols = String(line).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    guard cols.count >= 2 else { continue }
                    let serial = cols[0], deviceState = cols[1]
                    if deviceState == "unauthorized" {
                        phones.append(Phone(id: serial, kind: .android, name: "Android phone",
                                            freeBytes: nil, needsSetup: true,
                                            hint: "Tap “Allow USB debugging” on the phone, then Refresh."))
                    } else if deviceState == "device" {
                        let model = (try? await ProcessRunner.capture(adb, ["-s", serial, "shell", "getprop", "ro.product.model"]))?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Android device"
                        var free: Int64? = nil
                        if let df = try? await ProcessRunner.capture(adb, ["-s", serial, "shell", "df", "/sdcard"]),
                           let last = df.split(separator: "\n").last {
                            let parts = last.split(whereSeparator: { $0 == " " }).map(String.init)
                            if parts.count >= 4, let kb = Int64(parts[3]) { free = kb * 1024 }
                        }
                        phones.append(Phone(id: serial, kind: .android, name: model, freeBytes: free))
                    }
                }
            }
        }

        // USB scan: find iPhones, and Android phones that adb can't reach yet.
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
                    phones.append(Phone(id: serial, kind: .iphone, name: name, freeBytes: nil,
                                        needsSetup: false, hint: ""))
                }
                break
            }
            // Android connected over USB but adb sees nothing → debugging is off.
            if !phones.contains(where: { $0.kind == .android }) {
                let looksAndroid = androidVendorIDs.contains(where: { usb.contains($0) })
                    || usb.localizedCaseInsensitiveContains("Android")
                if looksAndroid {
                    phones.append(Phone(id: "android-usb", kind: .android, name: "Android phone",
                                        freeBytes: nil, needsSetup: true,
                                        hint: "Connected over USB. On the phone: set USB to File Transfer and turn on USB debugging (Developer options), then Refresh."))
                }
            }
        }
        return phones
    }

    // MARK: Android — fully automatic

    static func pushAndroid(libraryRoot: URL,
                            albums: [AlbumFolder],
                            subfolder: String,
                            phone: Phone,
                            onProgress: @escaping (Double, String) -> Void) async throws {
        guard let adb = BinaryLocator.url(for: .adb) else { throw RunError.notFound("adb") }
        let fm = FileManager.default
        let sub = subfolder.trimmingCharacters(in: .whitespaces)
        let suffix = sub.isEmpty ? "" : "/\(sub)"
        // audio → Music, video → Movies (so each shows in the right phone app)
        let musicBase = "/sdcard/Music\(suffix)"
        let movieBase = "/sdcard/Movies\(suffix)"
        let playlistDir = "/sdcard/Playlists"
        let audioAlbums = albums.filter { !$0.isVideo }
        let videoAlbums = albums.filter { $0.isVideo }
        if !audioAlbums.isEmpty { _ = try? await ProcessRunner.capture(adb, ["-s", phone.id, "shell", "mkdir", "-p", musicBase]) }
        if !videoAlbums.isEmpty { _ = try? await ProcessRunner.capture(adb, ["-s", phone.id, "shell", "mkdir", "-p", movieBase]) }

        // 1) copy the album folders
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

        // 2) build real playlists with ABSOLUTE on-device paths and push them
        if !audioAlbums.isEmpty {
            onProgress(-1, "Creating playlists…")
            _ = try? await ProcessRunner.capture(adb, ["-s", phone.id, "shell", "mkdir", "-p", playlistDir])
            let tmp = fm.temporaryDirectory.appendingPathComponent("snag-pl-\(UUID().uuidString)")
            try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let listName = sub.isEmpty ? "Snag" : sub
            var allLines = ["#EXTM3U"]
            for album in audioAlbums {
                let phoneDir = "\(musicBase)/\(album.url.lastPathComponent)"
                let tracks = ((try? fm.contentsOfDirectory(at: album.url, includingPropertiesForKeys: nil)) ?? [])
                    .filter { Media.isAudio($0) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard !tracks.isEmpty else { continue }
                var lines = ["#EXTM3U"]
                for t in tracks { let p = "\(phoneDir)/\(t.lastPathComponent)"; lines.append(p); allLines.append(p) }
                let f = tmp.appendingPathComponent("\(Organizer.safeName(album.name)).m3u8")
                try? lines.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
                _ = try? await ProcessRunner.capture(adb, ["-s", phone.id, "push", f.path, playlistDir + "/"])
                _ = try? await ProcessRunner.capture(adb, ["-s", phone.id, "push", f.path, musicBase + "/"])
            }
            if allLines.count > 1 {
                let allF = tmp.appendingPathComponent("\(listName) — All Music.m3u8")
                try? allLines.joined(separator: "\n").write(to: allF, atomically: true, encoding: .utf8)
                _ = try? await ProcessRunner.capture(adb, ["-s", phone.id, "push", allF.path, playlistDir + "/"])
                _ = try? await ProcessRunner.capture(adb, ["-s", phone.id, "push", allF.path, musicBase + "/"])
            }
            try? fm.removeItem(at: tmp)
        }

        // 3) media-scan everything so players index the tracks + playlists
        onProgress(-1, "Refreshing phone library…")
        let bases = [
            audioAlbums.isEmpty ? nil : musicBase,
            videoAlbums.isEmpty ? nil : movieBase,
            audioAlbums.isEmpty ? nil : playlistDir,
        ].compactMap { $0 }
        for base in bases {
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

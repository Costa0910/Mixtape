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
                            phone: Phone,
                            onProgress: @escaping (Double, String) -> Void) async throws {
        guard let adb = BinaryLocator.url(for: .adb) else { throw RunError.notFound("adb") }
        let dest = "/sdcard/Music/"
        for try await line in ProcessRunner.stream(adb, ["-s", phone.id, "push", libraryRoot.path, dest]) {
            if let r = line.range(of: #"(\d+)%"#, options: .regularExpression) {
                let n = line[r].dropLast()
                onProgress((Double(n) ?? 0) / 100.0, "Copying…")
            } else {
                onProgress(-1, line)
            }
        }
        // force a metadata scan so players see the tracks (sets is_music/duration)
        let folderName = libraryRoot.lastPathComponent
        let scan = "find '/sdcard/Music/\(folderName)' -name '*.m4a' -o -name '*.mp3' -o -name '*.opus' | while read f; do am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \"file://$f\" >/dev/null 2>&1; done; echo scanned"
        _ = try? await ProcessRunner.capture(adb, ["-s", phone.id, "shell", scan])
    }

    // MARK: iPhone — assisted (Apple blocks full automation)

    // Copies audio into Music's auto-import folder and opens Music. The user
    // does the final "Sync" in Finder. Returns a human-readable status.
    static func prepareIPhone(libraryRoot: URL) async throws -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let autoAdd = home
            .appendingPathComponent("Music/Music/Media.localized/Automatically Add to Music.localized")
        guard fm.fileExists(atPath: autoAdd.path) else {
            throw RunError.exit(1, "Couldn't find the Music auto-import folder. Open the Music app once, then retry.")
        }
        var count = 0
        if let en = fm.enumerator(at: libraryRoot, includingPropertiesForKeys: nil) {
            for case let f as URL in en where ["m4a", "mp3", "opus"].contains(f.pathExtension.lowercased()) {
                let dest = autoAdd.appendingPathComponent(f.lastPathComponent)
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: f, to: dest)
                count += 1
            }
        }
        _ = try? await run("/usr/bin/open", ["-a", "Music"])
        return "Imported \(count) tracks into the Music app. Now open Finder → your iPhone → Music tab → tick “Sync music” → Sync."
    }
}

import Foundation
import Network
import AppKit
import CoreImage.CIFilterBuiltins

// A tiny HTTP file server so any phone (incl. iPhone) can grab tracks from a
// browser over the local Wi-Fi — no USB, no Music sync. PIN-protected, and
// files are streamed in chunks (with HTTP Range support), not read into memory.
final class WebServer: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var address = ""
    @Published private(set) var pin = ""

    private var listener: NWListener?
    private var root = FileManager.default.temporaryDirectory
    private var token = ""                     // session cookie value
    private let queue = DispatchQueue(label: "snag.webserver")

    func toggle(root: URL) { running ? stop() : start(root: root) }

    func start(root: URL) {
        self.root = root
        stop()
        let newPin = String(format: "%04d", Int.random(in: 0...9999))
        let newToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var chosen: NWListener?
        for p: UInt16 in [8080, 8000, 8888, 0] {
            if let port = NWEndpoint.Port(rawValue: p), let l = try? NWListener(using: .tcp, on: port) {
                chosen = l; break
            }
        }
        guard let l = chosen else { return }
        listener = l
        token = newToken
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .global())
            self?.receive(conn, buffer: Data())
        }
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = self.listener?.port?.rawValue ?? 8080
                let ip = WebServer.localIP() ?? "localhost"
                DispatchQueue.main.async {
                    self.running = true; self.address = "http://\(ip):\(port)"; self.pin = newPin
                }
            case .failed, .cancelled:
                DispatchQueue.main.async { self.running = false; self.address = ""; self.pin = "" }
            default: break
            }
        }
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel(); listener = nil
        DispatchQueue.main.async { self.running = false; self.address = ""; self.pin = "" }
    }

    // MARK: request reading (accumulate header + any POST body)

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var buf = buffer
            if let d = data { buf.append(d) }
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { conn.cancel() } else { self.receive(conn, buffer: buf) }
                return
            }
            let header = String(data: buf.subdata(in: buf.startIndex..<end.lowerBound), encoding: .utf8) ?? ""
            let bodyBytes = buf.count - buf.distance(from: buf.startIndex, to: end.upperBound)
            let needed = Int(self.headerValue("Content-Length", header) ?? "0") ?? 0
            if needed > bodyBytes && !isComplete {
                self.receive(conn, buffer: buf)     // wait for the rest of the POST body
            } else {
                let body = buf.subdata(in: end.upperBound..<buf.endIndex)
                self.route(conn, header: header, body: body)
            }
        }
    }

    // MARK: routing + auth

    private func route(_ conn: NWConnection, header: String, body: Data) {
        let first = header.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = first.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = parts[0]
        let rawPath = parts[1]
        let path = rawPath.removingPercentEncoding ?? rawPath

        // login submission
        if method == "POST" && rawPath.hasPrefix("/login") {
            let form = String(data: body, encoding: .utf8) ?? ""
            let given = formValue("pin", form)
            if given == pin {
                sendHeaderOnly(conn, status: "303 See Other",
                               extra: ["Location": "/", "Set-Cookie": "snag=\(token); Path=/; HttpOnly; SameSite=Lax"])
            } else {
                send(conn, status: "200 OK", contentType: "text/html; charset=utf-8",
                     body: Data(loginHTML(error: true).utf8))
            }
            return
        }

        // everything else requires a valid session cookie
        guard method == "GET" else { send(conn, status: "405 Method Not Allowed", body: Data("nope".utf8)); return }
        let cookie = headerValue("Cookie", header) ?? ""
        let authed = cookie.contains("snag=\(token)")
        if !authed {
            send(conn, status: "200 OK", contentType: "text/html; charset=utf-8",
                 body: Data(loginHTML(error: false).utf8))
            return
        }

        if path == "/" || path.hasPrefix("/?") {
            send(conn, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(indexHTML().utf8))
        } else if path.hasPrefix("/f/") {
            streamFile(conn, rel: String(path.dropFirst(3)), range: headerValue("Range", header))
        } else {
            send(conn, status: "404 Not Found", body: Data("Not found".utf8))
        }
    }

    // MARK: streaming file responses (chunked, with Range support)

    private func streamFile(_ conn: NWConnection, rel: String, range: String?) {
        let safe = rel.split(separator: "/").filter { $0 != ".." }.joined(separator: "/")
        let fileURL = root.appendingPathComponent(safe)
        guard fileURL.path.hasPrefix(root.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            send(conn, status: "404 Not Found", body: Data("Not found".utf8)); return
        }

        var start = 0, end = size - 1, status = "200 OK"
        var extra: [String: String] = [
            "Accept-Ranges": "bytes",
            "Content-Disposition": "attachment; filename=\"\(fileURL.lastPathComponent)\"",
        ]
        if let r = parseRange(range, size: size) {
            start = r.0; end = r.1; status = "206 Partial Content"
            extra["Content-Range"] = "bytes \(start)-\(end)/\(size)"
        }
        let length = max(0, end - start + 1)
        try? handle.seek(toOffset: UInt64(start))

        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(length)\r\nContent-Type: \(contentType(fileURL.pathExtension))\r\nConnection: close\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"

        let chunkSize = 256 * 1024
        func sendChunk(remaining: Int) {
            guard remaining > 0 else { try? handle.close(); conn.cancel(); return }
            let n = min(chunkSize, remaining)
            let data = (try? handle.read(upToCount: n)) ?? Data()
            if data.isEmpty { try? handle.close(); conn.cancel(); return }
            conn.send(content: data, completion: .contentProcessed { err in
                if err != nil { try? handle.close(); conn.cancel() }
                else { sendChunk(remaining: remaining - data.count) }
            })
        }
        conn.send(content: Data(head.utf8), completion: .contentProcessed { err in
            if err != nil { try? handle.close(); conn.cancel() }
            else { sendChunk(remaining: length) }
        })
    }

    // MARK: small responses

    private func send(_ conn: NWConnection, status: String,
                      contentType: String = "text/plain; charset=utf-8",
                      body: Data, extra: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nContent-Type: \(contentType)\r\nConnection: close\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func sendHeaderOnly(_ conn: NWConnection, status: String, extra: [String: String]) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: HTML

    private func loginHTML(error: Bool) -> String {
        """
        <!doctype html><html><head><meta charset=utf-8>
        <meta name=viewport content='width=device-width,initial-scale=1'><title>Snag</title><style>
        body{font-family:-apple-system,system-ui,sans-serif;background:#0f1115;color:#e8e8ea;display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}
        form{background:#181b22;padding:28px;border-radius:16px;text-align:center;width:260px}
        h1{font-size:20px;margin:0 0 14px} input{font-size:22px;letter-spacing:6px;text-align:center;width:150px;padding:10px;border-radius:10px;border:1px solid #333;background:#0f1115;color:#fff}
        button{margin-top:14px;width:100%;padding:12px;border:0;border-radius:10px;background:#5b6cff;color:#fff;font-size:16px}
        .err{color:#ff6b6b;font-size:13px;margin-top:10px;\(error ? "" : "display:none")}
        </style></head><body><form method=POST action=/login>
        <h1>📥 Snag</h1>
        <input name=pin type=tel inputmode=numeric maxlength=6 autofocus placeholder="PIN">
        <button>Unlock</button><div class=err>Wrong PIN — try again.</div>
        </form></body></html>
        """
    }

    private func indexHTML() -> String {
        let fm = FileManager.default
        let albums = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        var rows = ""
        for album in albums {
            let tracks = (try? fm.contentsOfDirectory(at: album, includingPropertiesForKeys: nil))?
                .filter { Media.isMedia($0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            if tracks.isEmpty { continue }
            rows += "<h2>\(esc(album.lastPathComponent))</h2><ul>"
            for t in tracks {
                let rel = "\(album.lastPathComponent)/\(t.lastPathComponent)"
                let enc = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel
                rows += "<li><a href=\"/f/\(enc)\" download>\(esc(t.lastPathComponent))</a></li>"
            }
            rows += "</ul>"
        }
        if rows.isEmpty { rows = "<p>Library is empty.</p>" }
        return """
        <!doctype html><html><head><meta charset=utf-8>
        <meta name=viewport content='width=device-width,initial-scale=1'><title>Snag</title><style>
        body{font-family:-apple-system,system-ui,sans-serif;max-width:760px;margin:0 auto;padding:18px;background:#0f1115;color:#e8e8ea}
        a{color:#8aa4ff;text-decoration:none}a:active{opacity:.6}
        h1{font-size:22px}h2{font-size:15px;margin:22px 0 6px;color:#aab}li{margin:8px 0}
        </style></head><body><h1>📥 Snag library</h1>
        <p>Tap a track to download it to this device.</p>\(rows)</body></html>
        """
    }

    // MARK: parsing helpers

    private func headerValue(_ name: String, _ header: String) -> String? {
        for line in header.split(separator: "\r\n") {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                if key.lowercased() == name.lowercased() {
                    return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    private func formValue(_ name: String, _ form: String) -> String? {
        for pair in form.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, kv[0] == name {
                return kv[1].removingPercentEncoding ?? kv[1]
            }
        }
        return nil
    }

    private func parseRange(_ range: String?, size: Int) -> (Int, Int)? {
        guard let range, range.hasPrefix("bytes=") else { return nil }
        let spec = range.dropFirst(6)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let start = Int(parts[0]) ?? 0
        let end = parts[1].isEmpty ? size - 1 : (Int(parts[1]) ?? size - 1)
        guard start <= end, start < size else { return nil }
        return (max(0, start), min(end, size - 1))
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func contentType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "m4a", "aac": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "opus", "ogg": return "audio/ogg"
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "m3u8": return "application/vnd.apple.mpegurl"
        default: return "application/octet-stream"
        }
    }

    static func localIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING) {
                let name = String(cString: cur.pointee.ifa_name)
                if name == "en0" || name == "en1" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        address = String(cString: host)
                    }
                }
            }
            ptr = cur.pointee.ifa_next
        }
        freeifaddrs(ifaddr)
        return address
    }

    static func qrImage(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: ci)
        let img = NSImage(size: rep.size); img.addRepresentation(rep)
        return img
    }
}

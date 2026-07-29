import Foundation
import Network
import AppKit
import CoreImage.CIFilterBuiltins

// A tiny HTTP file server so any phone (incl. iPhone) can grab tracks from a
// browser over the local Wi-Fi — no USB, no Music sync.
final class WebServer: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var address = ""

    private var listener: NWListener?
    private var root = FileManager.default.temporaryDirectory
    private let queue = DispatchQueue(label: "snag.webserver")

    func toggle(root: URL) { running ? stop() : start(root: root) }

    func start(root: URL) {
        self.root = root
        stop()
        var chosen: NWListener?
        for p: UInt16 in [8080, 8000, 8888, 0] {
            if let port = NWEndpoint.Port(rawValue: p), let l = try? NWListener(using: .tcp, on: port) {
                chosen = l; break
            }
        }
        guard let l = chosen else { return }
        listener = l
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
                DispatchQueue.main.async { self.running = true; self.address = "http://\(ip):\(port)" }
            case .failed, .cancelled:
                DispatchQueue.main.async { self.running = false; self.address = "" }
            default: break
            }
        }
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel(); listener = nil
        DispatchQueue.main.async { self.running = false; self.address = "" }
    }

    // MARK: request handling

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(data: buf.subdata(in: buf.startIndex..<end.lowerBound), encoding: .utf8) ?? ""
                self.respond(conn, header: header)
            } else if isComplete {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, header: String) {
        guard let line = header.split(separator: "\r\n").first else { conn.cancel(); return }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            send(conn, status: "405 Method Not Allowed", body: Data("nope".utf8)); return
        }
        let rawPath = String(parts[1])
        let path = rawPath.removingPercentEncoding ?? rawPath
        if path == "/" || path.hasPrefix("/?") {
            send(conn, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(indexHTML().utf8))
        } else if path.hasPrefix("/f/") {
            serveFile(conn, rel: String(path.dropFirst(3)))
        } else {
            send(conn, status: "404 Not Found", body: Data("Not found".utf8))
        }
    }

    private func serveFile(_ conn: NWConnection, rel: String) {
        let safe = rel.split(separator: "/").filter { $0 != ".." }.joined(separator: "/")
        let fileURL = root.appendingPathComponent(safe)
        guard fileURL.path.hasPrefix(root.path), let data = try? Data(contentsOf: fileURL) else {
            send(conn, status: "404 Not Found", body: Data("Not found".utf8)); return
        }
        send(conn, status: "200 OK", contentType: contentType(fileURL.pathExtension), body: data,
             extra: ["Content-Disposition": "attachment; filename=\"\(fileURL.lastPathComponent)\""])
    }

    private func send(_ conn: NWConnection, status: String,
                      contentType: String = "text/plain; charset=utf-8",
                      body: Data, extra: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nContent-Type: \(contentType)\r\nConnection: close\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
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
        <meta name=viewport content='width=device-width,initial-scale=1'>
        <title>Snag</title><style>
        body{font-family:-apple-system,system-ui,sans-serif;max-width:760px;margin:0 auto;padding:18px;background:#0f1115;color:#e8e8ea}
        a{color:#8aa4ff;text-decoration:none} a:active{opacity:.6}
        h1{font-size:22px} h2{font-size:15px;margin:22px 0 6px;color:#aab} li{margin:8px 0}
        </style></head><body><h1>📥 Snag library</h1>
        <p>Tap a track to download it to this device.</p>\(rows)</body></html>
        """
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

    // MARK: helpers

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

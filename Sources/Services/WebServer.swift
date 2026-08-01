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
    private var artCache: [String: Data] = [:] // album path → cover PNG
    private let artLock = NSLock()

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
        // Advertise over Bonjour so the iPhone app can find this Mac without typing an IP.
        let deviceName = Host.current().localizedName ?? "Snag Mac"
        l.service = NWListener.Service(name: deviceName, type: "_snag._tcp")
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
        } else if path.hasPrefix("/art/") {
            serveArt(conn, album: String(path.dropFirst(5)))
        } else if path == "/manifest" {
            send(conn, status: "200 OK", contentType: "application/json", body: Data(manifestJSON().utf8))
        } else {
            send(conn, status: "404 Not Found", body: Data("Not found".utf8))
        }
    }

    // JSON list of downloadable audio tracks — for the iOS app to sync from.
    private func manifestJSON() -> String {
        let fm = FileManager.default
        var items: [[String: Any]] = []
        let albums = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        for album in albums {
            let tracks = (try? fm.contentsOfDirectory(at: album, includingPropertiesForKeys: [.fileSizeKey]))?
                .filter { Media.isAudio($0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            for t in tracks {
                let size = (try? t.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                items.append(["path": "\(album.lastPathComponent)/\(t.lastPathComponent)", "size": size])
            }
        }
        
        // Only expose hand-made playlists — skip Snag's own auto-generated ones
        // (the per-album mirrors named after each album folder, and "00 All Songs").
        let albumNames = Set(albums.map { $0.lastPathComponent })
        var playlistItems: [[String: Any]] = []
        if let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension.lowercased() == "m3u8" {
                let name = f.deletingPathExtension().lastPathComponent
                if name == "00 All Songs" || albumNames.contains(name) { continue }
                if let content = try? String(contentsOf: f, encoding: .utf8) {
                    var plTracks: [String] = []
                    for line in content.split(separator: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                        plTracks.append(trimmed)
                    }
                    if !plTracks.isEmpty {
                        playlistItems.append(["name": name, "tracks": plTracks])
                    }
                }
            }
        }
        
        let obj: [String: Any] = ["tracks": items, "playlists": playlistItems]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{\"tracks\":[],\"playlists\":[]}" }
        return s
    }

    // Extracts and caches an album's embedded cover art (off the listener queue).
    private func serveArt(_ conn: NWConnection, album: String) {
        let safe = album.split(separator: "/").filter { $0 != ".." }.joined(separator: "/")
        artLock.lock(); let hit = artCache[safe]; artLock.unlock()
        if let hit {
            send(conn, status: "200 OK", contentType: "image/png", body: hit,
                 extra: ["Cache-Control": "max-age=86400"]); return
        }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let dir = self.root.appendingPathComponent(safe)
            guard dir.path.hasPrefix(self.root.path),
                  let ffmpeg = BinaryLocator.url(for: .ffmpeg),
                  let first = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                    .filter({ Media.isAudio($0) })
                    .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first else {
                self.send(conn, status: "404 Not Found", body: Data()); return
            }
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("snagweb-art-\(abs(safe.hashValue)).png")
            let p = Process()
            p.executableURL = ffmpeg
            p.arguments = ["-v", "error", "-y", "-i", first.path, "-an", "-map", "0:v", "-frames:v", "1", out.path]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = BinaryLocator.augmentedPath
            p.environment = env
            try? p.run(); p.waitUntilExit()
            guard let data = try? Data(contentsOf: out) else {
                self.send(conn, status: "404 Not Found", body: Data()); return
            }
            self.artLock.lock(); self.artCache[safe] = data; self.artLock.unlock()
            self.send(conn, status: "200 OK", contentType: "image/png", body: data,
                      extra: ["Cache-Control": "max-age=86400"])
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
        var jsItems: [String] = []   // playable audio tracks for the in-page player
        var gi = 0
        for album in albums {
            let tracks = (try? fm.contentsOfDirectory(at: album, includingPropertiesForKeys: nil))?
                .filter { Media.isMedia($0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            if tracks.isEmpty { continue }
            let albEnc = album.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                ?? album.lastPathComponent
            let artURL = "/art/\(albEnc)"
            rows += "<div class=section><div class=alb><img class=art src=\"\(artURL)\" onerror=\"this.classList.add('ph')\">"
                + "<h2>\(esc(album.lastPathComponent))</h2></div><ul>"
            for t in tracks {
                let rel = "\(album.lastPathComponent)/\(t.lastPathComponent)"
                let enc = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel
                let name = t.deletingPathExtension().lastPathComponent
                if Media.isAudio(t) {
                    jsItems.append("{t:\"\(jsEsc(name))\",u:\"/f/\(enc)\",a:\"\(artURL)\"}")
                    rows += "<li><button class=pl data-i=\(gi)>▶</button> "
                        + "<span class=nm data-i=\(gi)>\(esc(name))</span> "
                        + "<a class=dl href=\"/f/\(enc)\" download>⬇︎</a></li>"
                    gi += 1
                } else {
                    rows += "<li>🎬 <a href=\"/f/\(enc)\" download>\(esc(name))</a></li>"
                }
            }
            rows += "</ul></div>"
        }
        if rows.isEmpty { rows = "<p>Library is empty.</p>" }
        let js = "[" + jsItems.joined(separator: ",") + "]"
        return """
        <!doctype html><html><head><meta charset=utf-8>
        <meta name=viewport content='width=device-width,initial-scale=1'><title>Snag</title><style>
        body{font-family:-apple-system,system-ui,sans-serif;max-width:760px;margin:0 auto;padding:18px 18px 130px;background:#0f1115;color:#e8e8ea}
        a{color:#8aa4ff;text-decoration:none}a:active{opacity:.6}
        h1{font-size:22px;margin:0 0 4px}
        .alb{display:flex;align-items:center;gap:12px;margin:22px 0 6px}
        .art{width:46px;height:46px;border-radius:8px;object-fit:cover;background:#242938}
        .art.ph{background:#242938} h2{font-size:15px;margin:0;color:#cdd}
        ul{list-style:none;padding:0;margin:0 0 4px} li{margin:2px 0;padding:8px 6px;border-radius:8px;display:flex;align-items:center;gap:10px}
        li.cur{background:#1c2030}
        .pl{background:#2a2f3d;color:#fff;border:0;border-radius:8px;width:34px;height:34px;font-size:13px}
        .nm{flex:1} .dl{opacity:.6;font-size:18px}
        .btns{display:flex;gap:10px;margin:6px 0 12px;flex-wrap:wrap}
        .bg{background:#5b6cff;color:#fff;border:0;border-radius:10px;padding:10px 16px;font-size:15px}
        .bg.sec{background:#2a2f3d}
        .search{width:100%;box-sizing:border-box;padding:11px 14px;margin:4px 0 12px;border-radius:10px;border:1px solid #2a2f3d;background:#181b22;color:#fff;font-size:15px}
        #bar{position:fixed;left:0;right:0;bottom:0;background:#181b22;border-top:1px solid #2a2f3d;padding:8px 14px}
        .now{display:flex;align-items:center;gap:10px;margin-bottom:6px}
        #bart{width:38px;height:38px;border-radius:6px;object-fit:cover;background:#242938}
        #np{font-size:13px;color:#cdd;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1}
        audio{width:100%}
        .tip{color:#889;font-size:12px;margin:6px 0 12px}
        </style></head><body>
        <h1>📥 Snag library</h1>
        <p class=tip>Tap ▶ to <b>play here</b> — streams from your Mac, nothing to find. ⬇︎ downloads the file (iPhone saves to <b>Files → Downloads</b>).</p>
        <input class=search id=q placeholder="Search tracks or albums…" autocomplete=off>
        <div class=btns><button class=bg id=all>▶ Play all</button><button class="bg sec" id=shuf>🔀 Shuffle</button><button class="bg sec" id=rep>🔁 Repeat: Off</button></div>
        \(rows)
        <div id=bar><div class=now><img id=bart><div id=np>—</div></div><audio id=au controls playsinline></audio></div>
        <script>
        const T=\(js);const au=document.getElementById('au'),np=document.getElementById('np'),bart=document.getElementById('bart');
        let order=T.map((_,i)=>i),pos=-1;
        function mark(cur){document.querySelectorAll('li.cur').forEach(e=>e.classList.remove('cur'));
          document.querySelectorAll('.pl').forEach(b=>b.textContent='▶');
          const b=document.querySelector('.pl[data-i="'+cur+'"]');if(b){b.textContent='⏸';b.closest('li').classList.add('cur');}}
        function playPos(p){if(p<0||p>=order.length)return;pos=p;const cur=order[p];
          au.src=T[cur].u;au.play();np.textContent=T[cur].t;bart.src=T[cur].a;mark(cur);}
        function shuffle(a){for(let i=a.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[a[i],a[j]]=[a[j],a[i]];}return a;}
        document.querySelectorAll('.pl').forEach(b=>b.addEventListener('click',()=>{const i=+b.dataset.i;
          if(order[pos]===i){if(au.paused){au.play();b.textContent='⏸';}else{au.pause();b.textContent='▶';}}
          else{order=T.map((_,k)=>k);playPos(i);}}));
        document.getElementById('all').onclick=()=>{order=T.map((_,k)=>k);playPos(0);};
        document.getElementById('shuf').onclick=()=>{order=shuffle(T.map((_,k)=>k));playPos(0);};
        let rep=0;const repBtn=document.getElementById('rep'),repLbl=['🔁 Repeat: Off','🔁 Repeat: All','🔂 Repeat: One'];
        repBtn.onclick=()=>{rep=(rep+1)%3;repBtn.textContent=repLbl[rep];};
        au.addEventListener('ended',()=>{if(rep===2){au.currentTime=0;au.play();return;}
          if(pos+1<order.length)playPos(pos+1);else if(rep===1)playPos(0);});
        const q=document.getElementById('q');
        q.addEventListener('input',()=>{const s=q.value.toLowerCase();
          document.querySelectorAll('.section').forEach(sec=>{let any=false;
            const alb=sec.querySelector('h2').textContent.toLowerCase();
            sec.querySelectorAll('li').forEach(li=>{const nm=li.querySelector('.nm');
              const txt=((nm?nm.textContent:li.textContent)+' '+alb).toLowerCase();
              const show=txt.includes(s);li.style.display=show?'':'none';if(show)any=true;});
            sec.style.display=any?'':'none';});});
        </script></body></html>
        """
    }

    private func jsEsc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
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

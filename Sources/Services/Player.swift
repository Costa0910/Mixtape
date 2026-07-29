import AVFoundation
import Combine

// Queue-based audio player: plays a whole album, auto-advances, and drives the
// now-playing bar.
@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    @Published var currentURL: URL?
    @Published var isPlaying = false
    @Published var nowPlaying = ""          // current track title
    @Published var albumName = ""

    private var queue: [TrackFile] = []
    private var idx = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    var hasNext: Bool { idx + 1 < queue.count }
    var hasPrev: Bool { idx > 0 }

    // Play a list of tracks starting at an index.
    func play(_ tracks: [TrackFile], startAt: Int = 0, album: String = "") {
        queue = tracks
        idx = max(0, min(startAt, max(tracks.count - 1, 0)))
        albumName = album
        playCurrent()
    }

    // Quick single-track toggle (library tile / one row).
    func toggle(_ url: URL) {
        if currentURL == url, let p = player {
            if p.isPlaying { p.pause(); isPlaying = false } else { p.play(); isPlaying = true }
        } else {
            let name = url.deletingPathExtension().lastPathComponent
            play([TrackFile(url: url, index: 1, title: name)])
        }
    }

    func togglePlayPause() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false } else { p.play(); isPlaying = true }
    }

    func next() {
        guard hasNext else { stop(); return }
        idx += 1; playCurrent()
    }

    func previous() {
        if let p = player, p.currentTime > 3 { p.currentTime = 0; return }
        guard hasPrev else { player?.currentTime = 0; return }
        idx -= 1; playCurrent()
    }

    func stop() {
        player?.stop(); player = nil
        isPlaying = false; currentURL = nil; nowPlaying = ""; albumName = ""
        queue = []; idx = 0
        timer?.invalidate(); timer = nil
    }

    private func playCurrent() {
        guard queue.indices.contains(idx) else { stop(); return }
        let track = queue[idx]
        player?.stop()
        do {
            let p = try AVAudioPlayer(contentsOf: track.url)
            player = p; p.play()
            currentURL = track.url; nowPlaying = track.title; isPlaying = true
            startMonitor()
        } catch {
            if hasNext { next() } else { stop() }   // skip unplayable, keep going
        }
    }

    private func startMonitor() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                if !p.isPlaying, self.isPlaying, p.currentTime >= p.duration - 0.15 {
                    self.next()   // auto-advance
                }
            }
        }
    }
}

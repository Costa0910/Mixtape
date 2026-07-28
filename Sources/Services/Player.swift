import AVFoundation
import Combine

// Simple audio preview player for the library.
@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    @Published var currentURL: URL?
    @Published var isPlaying = false

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ url: URL) {
        if currentURL == url, let p = player {
            if p.isPlaying { p.pause(); isPlaying = false }
            else { p.play(); isPlaying = true }
        } else {
            play(url)
        }
    }

    func play(_ url: URL) {
        player?.stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            player = p
            p.play()
            currentURL = url
            isPlaying = true
            startMonitor()
        } catch {
            currentURL = nil
            isPlaying = false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentURL = nil
        timer?.invalidate(); timer = nil
    }

    private func startMonitor() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let p = self.player, !p.isPlaying, self.isPlaying, p.currentTime >= p.duration - 0.1 {
                    self.stop()
                }
            }
        }
    }
}

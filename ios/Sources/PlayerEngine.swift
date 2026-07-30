import AVFoundation
import MediaPlayer
import UIKit
import SwiftUI

@MainActor
final class PlayerEngine: ObservableObject {
    static let shared = PlayerEngine()

    enum RepeatMode { case off, all, one }

    @Published var current: Track?
    @Published var isPlaying = false
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .off
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0

    private let player = AVPlayer()
    private var queue: [Track] = []
    private var order: [Int] = []
    private var pos = -1

    init() {
        configureSession()
        setupRemoteCommands()
        observeTime()
        NotificationCenter.default.addObserver(self, selector: #selector(itemEnded),
                                               name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    var progress: Double { duration > 0 ? elapsed / duration : 0 }
    var hasNext: Bool { pos + 1 < order.count || repeatMode != .off }
    var hasPrev: Bool { pos > 0 }

    // MARK: control

    func play(_ tracks: [Track], startAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        order = Array(0..<tracks.count)
        if shuffle {
            order.shuffle()
            if let at = order.firstIndex(of: index) { order.swapAt(0, at) }
            pos = 0
        } else {
            pos = min(max(index, 0), tracks.count - 1)
        }
        startCurrent()
    }

    func playPause() {
        if isPlaying { player.pause(); isPlaying = false }
        else { player.play(); isPlaying = true }
        updateNowPlaying()
    }

    func next(userInitiated: Bool = false) {
        if userInitiated, let c = current { c.skipCount += 1 }
        if repeatMode == .one && !userInitiated { seek(toFraction: 0); player.play(); return }
        if pos + 1 < order.count { pos += 1 }
        else if repeatMode != .off { pos = 0 }
        else { player.pause(); isPlaying = false; return }
        startCurrent()
    }

    func previous() {
        if elapsed > 3 { seek(toFraction: 0); return }
        guard pos > 0 else { seek(toFraction: 0); return }
        pos -= 1
        startCurrent()
    }

    func toggleShuffle() {
        shuffle.toggle()
        guard !queue.isEmpty, pos >= 0, pos < order.count else { return }
        let cur = order[pos]
        if shuffle {
            var rest = Array(0..<queue.count).filter { $0 != cur }
            rest.shuffle()
            order = [cur] + rest; pos = 0
        } else {
            order = Array(0..<queue.count); pos = cur
        }
    }

    func cycleRepeat() {
        repeatMode = repeatMode == .off ? .all : (repeatMode == .all ? .one : .off)
    }

    func seek(toFraction f: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: f * duration, preferredTimescale: 600))
        elapsed = f * duration
        updateNowPlaying()
    }

    // MARK: internals

    private func startCurrent() {
        guard order.indices.contains(pos) else { return }
        let track = queue[order[pos]]
        player.replaceCurrentItem(with: AVPlayerItem(url: track.url))
        player.play()
        current = track
        isPlaying = true
        duration = track.duration
        elapsed = 0
        track.playCount += 1
        track.lastPlayedAt = Date()
        updateNowPlaying()
    }

    @objc private func itemEnded() { next() }

    private func configureSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observeTime() {
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                       queue: .main) { [weak self] t in
            guard let self else { return }
            self.elapsed = t.seconds.isFinite ? t.seconds : 0
            if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
        }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.playPause(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.playPause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.playPause(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(userInitiated: true); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let self, let e = e as? MPChangePlaybackPositionCommandEvent, self.duration > 0 else { return .commandFailed }
            self.seek(toFraction: e.positionTime / self.duration); return .success
        }
    }

    private func updateNowPlaying() {
        guard let t = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let url = t.artworkURL, let img = UIImage(contentsOfFile: url.path) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

import AVFoundation
import MediaPlayer
import UIKit
import SwiftUI
import SwiftData
import Combine

// Playback runs through AVAudioEngine (not AVPlayer) so we can offer a real
// equalizer and crossfade. Two player nodes feed a mixer → EQ → output; normal
// playback uses one node, crossfade ramps between the two.
@MainActor
final class PlayerEngine: ObservableObject {
    static let shared = PlayerEngine()

    enum RepeatMode { case off, all, one }

    @Published var current: Track?
    @Published var isPlaying = false
    @Published var shuffle = false
    @Published var autoplay = true
    @Published var repeatMode: RepeatMode = .off
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
    @Published private(set) var queueVersion = 0

    // Sleep timer
    @Published var sleepTimerRemaining: TimeInterval? = nil
    @Published var sleepTimerEndBlock: Bool = false
    private var sleepTimer: Timer? = nil

    // MARK: audio graph
    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: PlaybackSettings.bandCount)
    private let nodes = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    private var files: [AVAudioFile?] = [nil, nil]
    private var active = 0
    private var fileSampleRate: Double = 44_100
    private var segmentStartFrame: AVAudioFramePosition = 0
    private var scheduleGen = 0
    private var crossfading = false
    private var crossfadeTimer: Timer?
    private var ticker: Timer?
    private let settings = PlaybackSettings.shared
    private var cancellables = Set<AnyCancellable>()

    // logical queue
    private var queue: [Track] = []
    private var order: [Int] = []
    private var pos = -1

    init() {
        configureSession()
        setupEngine()
        setupRemoteCommands()
        startTicker()
        settings.objectWillChange
            .sink { [weak self] in Task { @MainActor in self?.applyEQ() } }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption),
                                               name: AVAudioSession.interruptionNotification, object: nil)
    }

    var progress: Double { duration > 0 ? elapsed / duration : 0 }
    var hasNext: Bool { pos + 1 < order.count || repeatMode != .off }
    var hasPrev: Bool { pos > 0 }
    var fullQueue: [Track] { order.map { queue[$0] } }
    var currentQueueIndex: Int { pos }

    // MARK: engine setup

    private func setupEngine() {
        engine.attach(mixer); engine.attach(eq)
        nodes.forEach { engine.attach($0) }
        let std = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        nodes.forEach { engine.connect($0, to: mixer, format: std) }
        engine.connect(mixer, to: eq, format: std)
        engine.connect(eq, to: engine.mainMixerNode, format: std)
        let freqs = PlaybackSettings.frequencies
        for (i, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = i < freqs.count ? freqs[i] : 1000
            band.bandwidth = 0.5
            band.bypass = false
        }
        applyEQ()
        try? engine.start()
    }

    private func ensureEngineRunning() {
        if !engine.isRunning { try? engine.start() }
    }

    func applyEQ() {
        let gains = settings.effectiveGains
        for (i, band) in eq.bands.enumerated() {
            band.bypass = !settings.eqEnabled
            band.gain = settings.eqEnabled && i < gains.count ? gains[i] : 0
        }
    }

    // MARK: loading / scheduling

    /// Open `track`, connect `node` with its format, and schedule from `startFrame`.
    @discardableResult
    private func load(_ track: Track, on idx: Int, startFrame: AVAudioFramePosition) -> Bool {
        guard let file = try? AVAudioFile(forReading: track.url) else { return false }
        let node = nodes[idx]
        node.stop()
        engine.connect(node, to: mixer, format: file.processingFormat)
        files[idx] = file
        let total = file.length
        let from = min(max(startFrame, 0), total)
        let count = AVAudioFrameCount(max(0, total - from))
        scheduleGen += 1
        let token = scheduleGen
        if count > 0 {
            node.scheduleSegment(file, startingFrame: from, frameCount: count, at: nil,
                                 completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in self?.handleCompletion(token: token) }
            }
        }
        if idx == active {
            fileSampleRate = file.processingFormat.sampleRate
            segmentStartFrame = from
        }
        return true
    }

    private func handleCompletion(token: Int) {
        guard token == scheduleGen, !crossfading else { return }
        itemEnded()
    }

    // MARK: control

    func play(_ tracks: [Track], startAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        cancelCrossfade()
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

    func playSmart(_ tracks: [Track]) {
        let mix = Smart.mix(tracks)
        guard !mix.isEmpty else { return }
        shuffle = false
        play(mix, startAt: 0)
    }

    func playSimilar(to seed: Track) {
        let lib = (try? SharedStore.container.mainContext.fetch(FetchDescriptor<Track>())) ?? []
        shuffle = false
        play([seed] + Recommender.similar(to: seed, in: lib), startAt: 0)
    }

    func playPause() {
        if isPlaying {
            nodes.forEach { if $0.isPlaying { $0.pause() } }
            isPlaying = false
        } else {
            ensureEngineRunning()
            nodes[active].play()
            if crossfading { nodes[1 - active].play() }
            isPlaying = true
        }
        updateNowPlaying()
    }

    func next(userInitiated: Bool = false) {
        cancelCrossfade()
        if userInitiated, let c = current { c.skipCount += 1 }
        if repeatMode == .one && !userInitiated { seek(toFraction: 0); return }
        if pos + 1 < order.count { pos += 1 }
        else if repeatMode != .off { pos = 0 }
        else {
            if autoplay { appendRecommendations() }
            if pos + 1 < order.count { pos += 1 }
            else { stopPlayback(); return }
        }
        startCurrent()
    }

    func previous() {
        cancelCrossfade()
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
        queueVersion &+= 1
    }

    func cycleRepeat() {
        repeatMode = repeatMode == .off ? .all : (repeatMode == .all ? .one : .off)
    }

    func seek(toFraction f: Double) {
        cancelCrossfade()
        guard let file = files[active] else { return }
        let frame = AVAudioFramePosition(Double(file.length) * min(max(f, 0), 1))
        let node = nodes[active]
        let wasPlaying = isPlaying
        node.stop()
        guard let track = current else { return }
        _ = load(track, on: active, startFrame: frame)
        node.volume = 1
        if wasPlaying { node.play() }
        elapsed = Double(frame) / fileSampleRate
        updateNowPlaying()
    }

    // MARK: queue editing

    func skipToQueueIndex(_ index: Int) {
        guard index >= 0, index < order.count else { return }
        pos = index
        startCurrent()
    }

    func removeFromQueue(at index: Int) {
        guard index >= 0, index < order.count, order.count > 1 else { return }
        if index == pos {
            next()
            if pos > index { pos -= 1 }
        } else if pos > index {
            pos -= 1
        }
        order.remove(at: index)
        updateNowPlaying(); queueVersion &+= 1
    }

    func playNext(_ track: Track) {
        if queue.isEmpty { play([track]); return }
        queue.append(track)
        order.insert(queue.count - 1, at: min(pos + 1, order.count))
        queueVersion &+= 1
    }

    func addToQueue(_ track: Track) {
        if queue.isEmpty { play([track]); return }
        queue.append(track)
        order.append(queue.count - 1)
        queueVersion &+= 1
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        let base = pos + 1
        guard base <= order.count else { return }
        var upcoming = Array(order[base...])
        upcoming.move(fromOffsets: source, toOffset: destination)
        order.replaceSubrange(base..<order.count, with: upcoming)
        queueVersion &+= 1
    }

    private func appendRecommendations() {
        let lib = (try? SharedStore.container.mainContext.fetch(FetchDescriptor<Track>())) ?? []
        guard !lib.isEmpty, let seed = current else { return }
        let have = Set(queue.map { $0.id })
        let recs = Recommender.similar(to: seed, in: lib, limit: 20).filter { !have.contains($0.id) }
        guard !recs.isEmpty else { return }
        let start = queue.count
        queue.append(contentsOf: recs)
        order.append(contentsOf: start..<queue.count)
    }

    // MARK: internals

    private func startCurrent() {
        guard order.indices.contains(pos) else { return }
        cancelCrossfade()
        let track = queue[order[pos]]
        nodes.forEach { $0.stop(); $0.volume = 1 }
        ensureEngineRunning()
        guard load(track, on: active, startFrame: 0) else { return }
        nodes[active].volume = 1
        nodes[active].play()
        current = track
        isPlaying = true
        duration = resolvedDuration(track, files[active])
        elapsed = 0
        track.playCount += 1
        track.lastPlayedAt = Date()
        updateNowPlaying(); queueVersion &+= 1
    }

    private func stopPlayback() {
        nodes.forEach { $0.stop() }
        isPlaying = false
        updateNowPlaying()
    }

    private func itemEnded() {
        if sleepTimerEndBlock { sleepTimerEndBlock = false; stopPlayback(); return }
        next()
    }

    private func resolvedDuration(_ track: Track, _ file: AVAudioFile?) -> Double {
        if track.duration > 0 { return track.duration }
        if let f = file, f.processingFormat.sampleRate > 0 {
            return Double(f.length) / f.processingFormat.sampleRate
        }
        return 0
    }

    // MARK: crossfade

    private func peekNextPos() -> Int? {
        if pos + 1 < order.count { return pos + 1 }
        if repeatMode == .all, !order.isEmpty { return 0 }
        return nil
    }

    private func beginCrossfade() {
        guard repeatMode != .one, let np = peekNextPos() else { return }
        let nextTrack = queue[order[np]]
        let to = 1 - active
        guard load(nextTrack, on: to, startFrame: 0) else { return }
        crossfading = true
        let from = active
        nodes[to].volume = 0
        nodes[to].play()
        let dur = max(0.5, settings.crossfadeSeconds)
        let steps = max(4, Int(dur * 20))
        var step = 0
        crossfadeTimer?.invalidate()
        crossfadeTimer = Timer.scheduledTimer(withTimeInterval: dur / Double(steps), repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, self.crossfading else { t.invalidate(); return }
                step += 1
                let p = Float(step) / Float(steps)
                self.nodes[from].volume = max(0, 1 - p)
                self.nodes[to].volume = min(1, p)
                if step >= steps {
                    t.invalidate()
                    self.completeCrossfade(from: from, to: to, newPos: np, newTrack: nextTrack)
                }
            }
        }
    }

    private func completeCrossfade(from: Int, to: Int, newPos: Int, newTrack: Track) {
        nodes[from].stop(); nodes[from].volume = 1
        active = to
        if let f = files[to] { fileSampleRate = f.processingFormat.sampleRate }
        segmentStartFrame = 0
        pos = newPos
        current = newTrack
        duration = resolvedDuration(newTrack, files[to])
        newTrack.playCount += 1
        newTrack.lastPlayedAt = Date()
        crossfading = false
        updateNowPlaying(); queueVersion &+= 1
    }

    private func cancelCrossfade() {
        crossfadeTimer?.invalidate(); crossfadeTimer = nil
        if crossfading {
            let other = 1 - active
            nodes[other].stop(); nodes[other].volume = 1
            nodes[active].volume = 1
            crossfading = false
        }
    }

    // MARK: time / ticker

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let node = nodes[active]
        if let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt), fileSampleRate > 0 {
            let e = Double(segmentStartFrame + pt.sampleTime) / fileSampleRate
            elapsed = max(0, duration > 0 ? min(e, duration) : e)
        }
        if settings.crossfadeEnabled, isPlaying, !crossfading, duration > 0 {
            let remaining = duration - elapsed
            if remaining > 0, remaining <= settings.crossfadeSeconds { beginCrossfade() }
        }
    }

    // MARK: sleep timer

    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate(); sleepTimer = nil
        sleepTimerEndBlock = false
        guard let minutes else { sleepTimerRemaining = nil; return }
        sleepTimerRemaining = TimeInterval(minutes * 60)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let rem = self.sleepTimerRemaining {
                    if rem <= 1 {
                        self.sleepTimerRemaining = nil
                        self.sleepTimer?.invalidate(); self.sleepTimer = nil
                        if self.isPlaying { self.playPause() }
                    } else {
                        self.sleepTimerRemaining = rem - 1
                    }
                }
            }
        }
    }

    func setSleepTimerEndBlock() {
        sleepTimer?.invalidate(); sleepTimer = nil
        sleepTimerRemaining = nil
        sleepTimerEndBlock = true
    }

    // MARK: session / remote / now playing

    private func configureSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began, isPlaying { playPause() }
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
        guard let t = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
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

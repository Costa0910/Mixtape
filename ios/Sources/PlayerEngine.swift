import AVFoundation
import MediaPlayer
import UIKit
import SwiftUI
import SwiftData
import Combine

/// Serializes small listening-history writes away from the UI/player actor.
/// The visible library intentionally refreshes on its normal reload path.
actor ListeningHistoryWriter {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func record(trackID: UUID, engagement: Int = 0, completion: Int = 0,
                skip: Int = 0, at date: Date = Date()) throws {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.id == trackID })
        guard let track = try context.fetch(descriptor).first else { return }
        if engagement > 0 {
            track.engagedPlayCount = max((track.engagedPlayCount ?? 0) + engagement, track.playCount)
        }
        track.playCount += completion
        track.skipCount += skip
        track.lastPlayedAt = date
        try context.save()
    }
}

// Playback runs through AVAudioEngine (not AVPlayer) so we can offer a real
// equalizer and crossfade. Two player nodes feed a mixer → EQ → output; normal
// playback uses one node, crossfade ramps between the two.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var elapsed: Double = 0
    @Published fileprivate(set) var duration: Double = 0

    var progress: Double { duration > 0 ? elapsed / duration : 0 }
}

@MainActor
final class PlayerEngine: ObservableObject {
    static let shared = PlayerEngine()

    enum RepeatMode { case off, all, one }

    @Published var current: Track?
    @Published var isPlaying = false
    @Published var shuffle = false
    @Published var autoplay = true
    @Published var repeatMode: RepeatMode = .off
    @Published private(set) var queueVersion = 0

    // Position changes five times per second. Isolating that high-frequency
    // signal prevents every PlayerEngine observer from rebuilding on each tick.
    let clock = PlaybackClock()
    var elapsed: Double {
        get { clock.elapsed }
        set { clock.elapsed = newValue }
    }
    var duration: Double {
        get { clock.duration }
        set { clock.duration = newValue }
    }

    // Sleep timer
    @Published var sleepTimerRemaining: TimeInterval? = nil
    @Published var sleepTimerEndBlock: Bool = false
    private var sleepTimer: Timer? = nil

    // MARK: audio graph
    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: PlaybackSettings.bandCount)
    private let nodes = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    private let trackGains = [AVAudioUnitEQ(numberOfBands: 0), AVAudioUnitEQ(numberOfBands: 0)]
    private var files: [AVAudioFile?] = [nil, nil]
    private var loadedTracks: [Track?] = [nil, nil]
    private var active = 0
    private var fileSampleRate: Double = 44_100
    private var segmentStartFrame: AVAudioFramePosition = 0
    private var scheduleSerial = 0
    private var nodeScheduleTokens = [0, 0]
    private var crossfading = false
    private var crossfadeTimer: Timer?
    private var ticker: Timer?
    private let settings = PlaybackSettings.shared
    private var cancellables = Set<AnyCancellable>()
    private var sessionIsActive = false
    private var sessionDeactivationTask: Task<Void, Never>?
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var nowPlayingArtworkTrackID: UUID?
    private var nowPlayingArtwork: MPMediaItemArtwork?

    // logical queue
    private var queue: [Track] = []
    private var order: [Int] = []
    private var pos = -1
    private var qualifiedTrackID: UUID?
    private var didRecordRecommendationListen = false
    private var didRecordQualifiedListen = false
    private var shouldResumeAfterInterruption = false
    private var shouldResumeAfterRouteReconnect = false
    private var attemptedAutoplayForCurrent = false
    private var recommendationTask: Task<Void, Never>?
    private var recommendationSeedID: UUID?
    private var continueWhenRecommendationsArrive = false
    private let recommendationPlanner = RecommendationPlanner.shared
    private let historyWriter = ListeningHistoryWriter(container: SharedStore.container)

    private struct GaplessPreparation {
        let node: Int
        let nextPosition: Int
        let token: Int
    }
    private var gaplessPreparation: GaplessPreparation?

    init() {
        configureSession()
        setupEngine()
        setupRemoteCommands()
        startTicker()
        settings.audioSettingsDidChange
            .sink { [weak self] in
                self?.applyAudioSettings()
            }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange),
                                               name: AVAudioSession.routeChangeNotification, object: nil)
    }

    var progress: Double { clock.progress }
    var hasNext: Bool { pos + 1 < order.count || repeatMode != .off }
    var hasPrev: Bool { pos > 0 }
    var fullQueue: [Track] { order.map { queue[$0] } }
    var currentQueueIndex: Int { pos }

    // MARK: engine setup

    private func setupEngine() {
        engine.attach(mixer); engine.attach(eq)
        nodes.forEach { engine.attach($0) }
        trackGains.forEach { engine.attach($0) }
        let std = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        for index in nodes.indices {
            engine.connect(nodes[index], to: trackGains[index], format: std)
            engine.connect(trackGains[index], to: mixer, format: std)
        }
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
        // Preallocate render resources so the first user tap doesn't pay the
        // engine's setup cost on the interaction path.
        engine.prepare()
    }

    @discardableResult
    private func ensureEngineRunning() -> Bool {
        sessionDeactivationTask?.cancel()
        sessionDeactivationTask = nil
        do {
            if !sessionIsActive {
                try AVAudioSession.sharedInstance().setActive(true)
                sessionIsActive = true
            }
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            return engine.isRunning
        } catch {
            sessionIsActive = false
            return false
        }
    }

    func applyEQ() {
        let gains = settings.effectiveGains
        for (i, band) in eq.bands.enumerated() {
            band.bypass = !settings.eqEnabled
            band.gain = settings.eqEnabled && i < gains.count ? gains[i] : 0
        }
    }

    private func applyAudioSettings() {
        applyEQ()
        for index in nodes.indices { applyNormalization(to: index) }
        if settings.crossfadeEnabled || !settings.gaplessEnabled {
            cancelGaplessPreparation()
        }
    }

    private func applyNormalization(to index: Int) {
        guard trackGains.indices.contains(index) else { return }
        let measuredGain = loadedTracks[index]?.normalizationGainDB ?? 0
        trackGains[index].globalGain = settings.normalizationEnabled
            ? Float(min(max(measuredGain, -LoudnessAnalyzer.maximumAdjustmentDB),
                        LoudnessAnalyzer.maximumAdjustmentDB))
            : 0
    }

    // MARK: loading / scheduling

    /// Open `track`, connect `node` with its format, and schedule from `startFrame`.
    @discardableResult
    private func load(_ track: Track, on idx: Int, startFrame: AVAudioFramePosition,
                      at time: AVAudioTime? = nil) -> Int? {
        invalidateSchedule(on: idx)
        guard let file = try? AVAudioFile(forReading: track.url) else { return nil }
        let node = nodes[idx]
        files[idx] = file
        loadedTracks[idx] = track
        applyNormalization(to: idx)
        let total = file.length
        let from = min(max(startFrame, 0), total)
        let count = AVAudioFrameCount(max(0, total - from))
        scheduleSerial &+= 1
        let token = scheduleSerial
        nodeScheduleTokens[idx] = token
        if count > 0 {
            node.scheduleSegment(file, startingFrame: from, frameCount: count, at: time,
                                 completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in self?.handleCompletion(node: idx, token: token) }
            }
        }
        if idx == active {
            fileSampleRate = file.processingFormat.sampleRate
            segmentStartFrame = from
        }
        return token
    }

    private func invalidateSchedule(on index: Int) {
        scheduleSerial &+= 1
        nodeScheduleTokens[index] = scheduleSerial
        nodes[index].stop()
    }

    private func handleCompletion(node index: Int, token: Int) {
        guard nodeScheduleTokens[index] == token, index == active, !crossfading else { return }
        if let prepared = gaplessPreparation,
           nodeScheduleTokens[prepared.node] == prepared.token {
            completeGaplessTransition(prepared)
            return
        }
        itemEnded()
    }

    // MARK: control

    func play(_ tracks: [Track], startAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        cancelRecommendationPlanning()
        cancelTransitions()
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

    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        shuffle = true
        play(tracks, startAt: Int.random(in: 0..<tracks.count))
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
            pausePlayback(clearAutomaticResume: true, deactivateSession: true)
        } else {
            resumePlayback(clearAutomaticResume: true)
        }
    }

    private func pausePlayback(clearAutomaticResume: Bool, deactivateSession: Bool = false) {
        cancelGaplessPreparation()
        nodes.forEach { if $0.isPlaying { $0.pause() } }
        // Keep the prepared graph running silently for a short manual pause so
        // resume does not pay a hardware/audio-graph restart. Interruption
        // pauses still release render work immediately.
        if !deactivateSession { engine.pause() }
        isPlaying = false
        if clearAutomaticResume {
            shouldResumeAfterInterruption = false
            shouldResumeAfterRouteReconnect = false
        }
        if deactivateSession {
            scheduleSessionDeactivation()
        }
        updateNowPlaying()
    }

    private func resumePlayback(clearAutomaticResume: Bool) {
        guard current != nil else { return }
        if clearAutomaticResume {
            shouldResumeAfterInterruption = false
            shouldResumeAfterRouteReconnect = false
        }
        guard ensureEngineRunning() else {
            isPlaying = false
            updateNowPlaying()
            return
        }
        nodes[active].play()
        if crossfading { nodes[1 - active].play() }
        isPlaying = engine.isRunning && nodes[active].isPlaying
        updateNowPlaying()
    }

    func next(userInitiated: Bool = false) {
        cancelTransitions()
        if userInitiated { recordSkipIfNeeded() }
        if repeatMode == .one && !userInitiated { seek(toFraction: 0); return }
        if pos + 1 < order.count { pos += 1 }
        else if repeatMode != .off { pos = 0 }
        else {
            if autoplay { requestRecommendationsIfNeeded() }
            if pos + 1 < order.count { pos += 1 }
            else if autoplay {
                // The audio boundary has arrived before background planning.
                // Keep the UI truthful, then continue as soon as results land.
                continueWhenRecommendationsArrive = true
                isPlaying = false
                updateNowPlaying()
                return
            } else { stopPlayback(); return }
        }
        startCurrent()
    }

    func previous() {
        cancelTransitions()
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
        cancelTransitions()
        guard let file = files[active] else { return }
        let frame = AVAudioFramePosition(Double(file.length) * min(max(f, 0), 1))
        let node = nodes[active]
        let wasPlaying = isPlaying
        node.stop()
        guard let track = current else { return }
        guard load(track, on: active, startFrame: frame) != nil else { return }
        node.volume = 1
        if wasPlaying { node.play() }
        elapsed = Double(frame) / fileSampleRate
        updateNowPlaying()
    }

    func seek(toTime t: Double) {
        guard duration > 0 else { return }
        seek(toFraction: t / duration)
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

    private func requestRecommendationsIfNeeded() {
        guard autoplay, let seed = current, peekNextPos() == nil else { return }
        if recommendationSeedID == seed.id, recommendationTask != nil { return }
        recommendationTask?.cancel()
        recommendationSeedID = seed.id
        attemptedAutoplayForCurrent = true

        let have = Set(queue.map { $0.id })
        let recentStart = max(0, pos - 4)
        let recentIDs = order.indices.contains(pos)
            ? order[recentStart...pos].map { queue[$0].id }
            : [seed.id]
        let preferences = RecommendationPreferences.current
        let seedID = seed.id

        recommendationTask = Task { [weak self] in
            guard let ids = try? await self?.recommendationPlanner.continuationIDs(
                after: seedID, recentIDs: recentIDs, excluding: have,
                limit: 20, preferences: preferences
            ) else { return }
            guard !Task.isCancelled, let self,
                  self.current?.id == seedID else { return }
            self.recommendationTask = nil
            self.recommendationSeedID = nil
            let alreadyQueued = Set(self.queue.map(\.id))
            var tracksByID: [UUID: Track] = [:]
            for id in ids where !alreadyQueued.contains(id) {
                let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.id == id })
                if let track = try? SharedStore.container.mainContext.fetch(descriptor).first {
                    tracksByID[id] = track
                }
            }
            let recs = ids.compactMap { tracksByID[$0] }
            if !recs.isEmpty {
                let start = self.queue.count
                self.queue.append(contentsOf: recs)
                self.order.append(contentsOf: start..<self.queue.count)
                self.queueVersion &+= 1
            }
            if self.continueWhenRecommendationsArrive {
                self.continueWhenRecommendationsArrive = false
                if self.pos + 1 < self.order.count {
                    self.pos += 1
                    self.startCurrent()
                } else {
                    self.stopPlayback()
                }
            }
        }
    }

    private func cancelRecommendationPlanning() {
        recommendationTask?.cancel()
        recommendationTask = nil
        recommendationSeedID = nil
        continueWhenRecommendationsArrive = false
    }

    // MARK: internals

    private func startCurrent() {
        guard order.indices.contains(pos) else { return }
        cancelTransitions()
        let track = queue[order[pos]]
        for index in nodes.indices {
            invalidateSchedule(on: index)
            nodes[index].volume = 1
        }
        guard load(track, on: active, startFrame: 0) != nil else { return }
        guard ensureEngineRunning() else { return }
        nodes[active].volume = 1
        nodes[active].play()
        current = track
        isPlaying = engine.isRunning && nodes[active].isPlaying
        duration = resolvedDuration(track, files[active])
        elapsed = 0
        attemptedAutoplayForCurrent = false
        beginListeningSignal(for: track)
        updateNowPlaying(); queueVersion &+= 1
        if peekNextPos() == nil, autoplay { requestRecommendationsIfNeeded() }
    }

    private func stopPlayback() {
        cancelTransitions()
        for index in nodes.indices { invalidateSchedule(on: index) }
        isPlaying = false
        shouldResumeAfterInterruption = false
        shouldResumeAfterRouteReconnect = false
        sessionDeactivationTask?.cancel()
        engine.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionIsActive = false
        updateNowPlaying()
    }

    private func itemEnded() {
        recordQualifiedListenIfNeeded(force: true)
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
        cancelGaplessPreparation()
        let nextTrack = queue[order[np]]
        let to = 1 - active
        guard load(nextTrack, on: to, startFrame: 0) != nil else { return }
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
                    self.completeCrossfade(from: from, to: to, newPos: np)
                }
            }
        }
    }

    private func completeCrossfade(from: Int, to: Int, newPos: Int) {
        recordQualifiedListenIfNeeded(force: true)
        invalidateSchedule(on: from); nodes[from].volume = 1
        active = to
        if let f = files[to] { fileSampleRate = f.processingFormat.sampleRate }
        segmentStartFrame = 0
        pos = newPos
        let newTrack = queue[order[newPos]]
        current = newTrack
        duration = resolvedDuration(newTrack, files[to])
        elapsed = 0
        attemptedAutoplayForCurrent = false
        beginListeningSignal(for: newTrack)
        crossfading = false
        updateNowPlaying(); queueVersion &+= 1
        if peekNextPos() == nil, autoplay { requestRecommendationsIfNeeded() }
    }

    private func cancelCrossfade() {
        crossfadeTimer?.invalidate(); crossfadeTimer = nil
        if crossfading {
            let other = 1 - active
            invalidateSchedule(on: other); nodes[other].volume = 1
            nodes[active].volume = 1
            crossfading = false
        }
    }

    private func cancelTransitions() {
        cancelCrossfade()
        cancelGaplessPreparation()
    }

    // MARK: gapless playback

    /// Schedules the next file against the current render clock before the
    /// current file ends. The audio hardware performs the handoff; the main
    /// thread only updates UI and history after the boundary has rendered.
    private func prepareGaplessTransitionIfNeeded() {
        guard settings.gaplessEnabled, !settings.crossfadeEnabled,
              !crossfading, gaplessPreparation == nil, repeatMode != .one,
              isPlaying, let file = files[active], fileSampleRate > 0 else { return }

        if peekNextPos() == nil, autoplay, !attemptedAutoplayForCurrent {
            requestRecommendationsIfNeeded()
        }
        guard let nextPosition = peekNextPos(),
              let renderTime = nodes[active].lastRenderTime,
              renderTime.isHostTimeValid,
              let playerTime = nodes[active].playerTime(forNodeTime: renderTime) else { return }

        let remainingFrames = max(0, file.length - segmentStartFrame - playerTime.sampleTime)
        guard remainingFrames > 0 else { return }
        let remainingSeconds = Double(remainingFrames) / fileSampleRate
        let endHostTime = renderTime.hostTime + AVAudioTime.hostTime(forSeconds: remainingSeconds)
        let startTime = AVAudioTime(hostTime: endHostTime)
        let nextNode = 1 - active
        let nextTrack = queue[order[nextPosition]]
        guard let token = load(nextTrack, on: nextNode, startFrame: 0, at: startTime) else { return }
        nodes[nextNode].volume = 1
        nodes[nextNode].play(at: startTime)
        gaplessPreparation = GaplessPreparation(node: nextNode,
                                                nextPosition: nextPosition,
                                                token: token)
    }

    private func completeGaplessTransition(_ prepared: GaplessPreparation) {
        guard gaplessPreparation?.token == prepared.token else { return }
        gaplessPreparation = nil
        recordQualifiedListenIfNeeded(force: true)
        if sleepTimerEndBlock {
            sleepTimerEndBlock = false
            stopPlayback()
            return
        }

        let previousNode = active
        active = prepared.node
        pos = prepared.nextPosition
        invalidateSchedule(on: previousNode)
        if let file = files[active] { fileSampleRate = file.processingFormat.sampleRate }
        segmentStartFrame = 0
        let newTrack = queue[order[pos]]
        current = newTrack
        duration = resolvedDuration(newTrack, files[active])
        elapsed = 0
        attemptedAutoplayForCurrent = false
        beginListeningSignal(for: newTrack)
        updateNowPlaying()
        queueVersion &+= 1
        if peekNextPos() == nil, autoplay { requestRecommendationsIfNeeded() }
    }

    private func cancelGaplessPreparation() {
        guard let prepared = gaplessPreparation else { return }
        gaplessPreparation = nil
        invalidateSchedule(on: prepared.node)
        files[prepared.node] = nil
        loadedTracks[prepared.node] = nil
    }

    // MARK: time / ticker

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        ticker?.tolerance = 0.03
    }

    private func tick() {
        // A paused player has no changing playback state. Avoid publishing the
        // same elapsed value and rebuilding the entire SwiftUI hierarchy.
        guard isPlaying else { return }
        let node = nodes[active]
        if let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt), fileSampleRate > 0 {
            let e = Double(segmentStartFrame + pt.sampleTime) / fileSampleRate
            let resolved = max(0, duration > 0 ? min(e, duration) : e)
            if abs(resolved - elapsed) >= 0.04 { elapsed = resolved }
        }
        if settings.crossfadeEnabled, isPlaying, !crossfading, duration > 0 {
            let remaining = duration - elapsed
            if remaining > 0, remaining <= settings.crossfadeSeconds { beginCrossfade() }
        } else if settings.gaplessEnabled, isPlaying {
            prepareGaplessTransitionIfNeeded()
        }
        recordRecommendationListenIfNeeded()
        recordQualifiedListenIfNeeded()
    }

    // MARK: listening signals

    private func beginListeningSignal(for track: Track) {
        qualifiedTrackID = track.id
        didRecordRecommendationListen = false
        didRecordQualifiedListen = false
    }

    private func recordRecommendationListenIfNeeded(force: Bool = false) {
        guard !didRecordRecommendationListen,
              let track = current,
              qualifiedTrackID == track.id,
              ListeningSignal.qualifiesForRecommendation(elapsed: elapsed, duration: duration,
                                                          naturalEnd: force)
        else { return }
        didRecordRecommendationListen = true
        persistListeningSignals(trackID: track.id, engagement: 1)
    }

    private func recordQualifiedListenIfNeeded(force: Bool = false) {
        guard !didRecordQualifiedListen,
              let track = current,
              qualifiedTrackID == track.id,
              ListeningSignal.classify(elapsed: elapsed, duration: duration, naturalEnd: force) == .completed
        else { return }
        recordRecommendationListenIfNeeded(force: force)
        didRecordQualifiedListen = true
        persistListeningSignals(trackID: track.id, completion: 1)
    }

    private func recordSkipIfNeeded() {
        guard let track = current, qualifiedTrackID == track.id else { return }
        recordRecommendationListenIfNeeded()
        switch ListeningSignal.classify(elapsed: elapsed, duration: duration) {
        case .skip where !didRecordQualifiedListen:
            persistListeningSignals(trackID: track.id, skip: 1)
        case .completed:
            recordQualifiedListenIfNeeded()
        case .skip, .neutral:
            break
        }
    }

    private func persistListeningSignals(trackID: UUID, engagement: Int = 0,
                                         completion: Int = 0, skip: Int = 0) {
        Task { [historyWriter] in
            try? await historyWriter.record(trackID: trackID, engagement: engagement,
                                             completion: completion, skip: skip)
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
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        // Keep latency bounded without choosing a battery-expensive tiny buffer.
        try? session.setPreferredIOBufferDuration(0.023)
    }

    private func scheduleSessionDeactivation() {
        sessionDeactivationTask?.cancel()
        sessionDeactivationTask = Task { [weak self] in
            // A quick pause/resume stays warm. A longer pause releases the audio
            // session so other apps can resume and the device can become idle.
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, !self.isPlaying else { return }
            self.engine.pause()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.sessionIsActive = false
            self.sessionDeactivationTask = nil
        }
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            sessionIsActive = false
            shouldResumeAfterInterruption = isPlaying
            if isPlaying {
                pausePlayback(clearAutomaticResume: false)
            }
        case .ended:
            let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            let shouldResume = shouldResumeAfterInterruption && options.contains(.shouldResume)
            shouldResumeAfterInterruption = false
            if shouldResume, !shouldResumeAfterRouteReconnect {
                resumePlayback(clearAutomaticResume: false)
            }
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            let intendedToPlay = isPlaying || shouldResumeAfterInterruption
            guard intendedToPlay else { return }
            shouldResumeAfterRouteReconnect = true
            shouldResumeAfterInterruption = false
            if isPlaying {
                pausePlayback(clearAutomaticResume: false)
            }
        case .newDeviceAvailable:
            guard shouldResumeAfterRouteReconnect else { return }
            shouldResumeAfterRouteReconnect = false
            resumePlayback(clearAutomaticResume: false)
        default:
            break
        }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            guard let self, self.current != nil else { return .noSuchContent }
            if !self.isPlaying { self.resumePlayback(clearAutomaticResume: true) }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.current != nil else { return .noSuchContent }
            if self.isPlaying { self.pausePlayback(clearAutomaticResume: true, deactivateSession: true) }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.playPause(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(userInitiated: true); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let self, let e = e as? MPChangePlaybackPositionCommandEvent, self.duration > 0 else { return .commandFailed }
            self.seek(toFraction: e.positionTime / self.duration); return .success
        }
    }

    private func updateNowPlaying() {
        guard let t = current else {
            nowPlayingArtworkTask?.cancel()
            nowPlayingArtworkTrackID = nil
            nowPlayingArtwork = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        if nowPlayingArtworkTrackID != t.id {
            nowPlayingArtworkTask?.cancel()
            nowPlayingArtworkTrackID = t.id
            nowPlayingArtwork = nil
            if let url = t.artworkURL {
                let trackID = t.id
                nowPlayingArtworkTask = Task { [weak self] in
                    let image = await Task.detached(priority: .utility) {
                        ArtworkImageLoader.downsample(url, maxPixelSize: 600)
                    }.value
                    guard !Task.isCancelled, let self,
                          self.current?.id == trackID, let image else { return }
                    self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    self.publishNowPlayingInfo(for: self.current!)
                }
            }
        }
        publishNowPlayingInfo(for: t)
    }

    private func publishNowPlayingInfo(for t: Track) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

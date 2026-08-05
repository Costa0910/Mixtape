import Foundation
import Combine

// 10-band graphic EQ presets. Gains map to [32,64,125,250,500,1k,2k,4k,8k,16k] Hz.
enum EQPreset: String, CaseIterable, Identifiable {
    case flat = "Flat"
    case bassBoost = "Bass Boost"
    case trebleBoost = "Treble Boost"
    case vocal = "Vocal"
    case rock = "Rock"
    case electronic = "Electronic"
    case hipHop = "Hip-Hop"
    case jazz = "Jazz"
    case classical = "Classical"
    case custom = "Custom"

    var id: String { rawValue }

    var gains: [Float] {
        switch self {
        case .flat, .custom:  return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bassBoost:      return [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
        case .trebleBoost:    return [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]
        case .vocal:          return [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]
        case .rock:           return [4, 3, 1, -1, -1, 0, 2, 3, 4, 4]
        case .electronic:     return [5, 4, 1, 0, -1, 1, 0, 2, 4, 5]
        case .hipHop:         return [5, 4, 2, 1, 0, -1, 0, 1, 2, 3]
        case .jazz:           return [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]
        case .classical:      return [4, 3, 2, 0, -1, -1, 0, 2, 3, 4]
        }
    }
}

private enum PlaybackTransitionMode {
    case none
    case gapless
    case crossfade
}

// Persisted playback preferences read by the audio engine and edited in Settings.
@MainActor
final class PlaybackSettings: ObservableObject {
    static let shared = PlaybackSettings()

    static let bandCount = 10
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    @Published private var transitionMode: PlaybackTransitionMode {
        didSet {
            d.set(transitionMode == .crossfade, forKey: K.crossfadeOn)
            d.set(transitionMode == .gapless, forKey: K.gaplessOn)
            audioSettingsDidChange.send()
        }
    }
    @Published var crossfadeSeconds: Double {
        didSet {
            d.set(crossfadeSeconds, forKey: K.crossfadeSecs)
            audioSettingsDidChange.send()
        }
    }
    @Published var normalizationEnabled: Bool {
        didSet {
            d.set(normalizationEnabled, forKey: K.normalizationOn)
            audioSettingsDidChange.send()
        }
    }
    @Published var eqEnabled: Bool {
        didSet {
            d.set(eqEnabled, forKey: K.eqOn)
            audioSettingsDidChange.send()
        }
    }
    @Published var eqPreset: EQPreset {
        didSet {
            d.set(eqPreset.rawValue, forKey: K.eqPreset)
            audioSettingsDidChange.send()
        }
    }
    @Published var customGains: [Float] {
        didSet {
            d.set(customGains.map { Double($0) }, forKey: K.eqGains)
            audioSettingsDidChange.send()
        }
    }

    /// Emits after a preference has changed, so the audio graph always reads
    /// the new value rather than racing ObservableObject's pre-change signal.
    let audioSettingsDidChange = PassthroughSubject<Void, Never>()

    /// The gains actually applied (preset gains, or the custom curve).
    var effectiveGains: [Float] { eqPreset == .custom ? customGains : eqPreset.gains }
    var crossfadeEnabled: Bool { transitionMode == .crossfade }
    var gaplessEnabled: Bool { transitionMode == .gapless }

    func setCrossfadeEnabled(_ enabled: Bool) {
        transitionMode = enabled ? .crossfade : .none
    }

    func setGaplessEnabled(_ enabled: Bool) {
        transitionMode = enabled ? .gapless : .none
    }

    /// Removes all equalizer processing and clears the saved custom curve.
    /// This returns playback to the sound encoded in the original track.
    func restoreOriginalSound() {
        customGains = Array(repeating: 0, count: Self.bandCount)
        eqPreset = .flat
        eqEnabled = false
    }

    /// Edit one band — switches to the Custom preset, seeding from the current curve.
    func setBand(_ index: Int, _ value: Float) {
        guard index >= 0, index < Self.bandCount else { return }
        var gains = eqPreset == .custom ? customGains : effectiveGains
        if gains.count != Self.bandCount { gains = Array(repeating: 0, count: Self.bandCount) }
        gains[index] = value
        customGains = gains
        eqPreset = .custom
    }

    private let d: UserDefaults
    private enum K {
        static let crossfadeOn = "crossfadeEnabled"
        static let crossfadeSecs = "crossfadeSeconds"
        static let gaplessOn = "gaplessEnabled"
        static let normalizationOn = "normalizationEnabled"
        static let eqOn = "eqEnabled"
        static let eqPreset = "eqPreset"
        static let eqGains = "eqGains"
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        let storedCrossfade = defaults.bool(forKey: K.crossfadeOn)
        let storedGapless = defaults.object(forKey: K.gaplessOn) as? Bool ?? true
        transitionMode = storedCrossfade ? .crossfade : (storedGapless ? .gapless : .none)
        let storedDuration = defaults.object(forKey: K.crossfadeSecs) as? Double ?? 4.0
        crossfadeSeconds = storedDuration.isFinite ? min(max(storedDuration, 1), 12) : 4.0
        // Crossfade has always taken precedence in the engine. Normalize legacy
        // installs that may have persisted both toggles as enabled.
        normalizationEnabled = d.object(forKey: K.normalizationOn) as? Bool ?? true
        eqEnabled = d.bool(forKey: K.eqOn)
        eqPreset = EQPreset(rawValue: d.string(forKey: K.eqPreset) ?? "") ?? .flat
        let stored = (d.array(forKey: K.eqGains) as? [Double])?.map { Float($0) }
        customGains = stored?.count == Self.bandCount
            ? stored!.map { min(max($0, -12), 12) }
            : Array(repeating: 0, count: Self.bandCount)

        d.set(crossfadeSeconds, forKey: K.crossfadeSecs)
        d.set(transitionMode == .crossfade, forKey: K.crossfadeOn)
        d.set(transitionMode == .gapless, forKey: K.gaplessOn)
    }
}

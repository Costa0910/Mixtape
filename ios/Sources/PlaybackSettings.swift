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

// Persisted playback preferences read by the audio engine and edited in Settings.
@MainActor
final class PlaybackSettings: ObservableObject {
    static let shared = PlaybackSettings()

    static let bandCount = 10
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    @Published var crossfadeEnabled: Bool { didSet { d.set(crossfadeEnabled, forKey: K.crossfadeOn) } }
    @Published var crossfadeSeconds: Double { didSet { d.set(crossfadeSeconds, forKey: K.crossfadeSecs) } }
    @Published var gaplessEnabled: Bool { didSet { d.set(gaplessEnabled, forKey: K.gaplessOn) } }
    @Published var normalizationEnabled: Bool { didSet { d.set(normalizationEnabled, forKey: K.normalizationOn) } }
    @Published var eqEnabled: Bool { didSet { d.set(eqEnabled, forKey: K.eqOn) } }
    @Published var eqPreset: EQPreset { didSet { d.set(eqPreset.rawValue, forKey: K.eqPreset) } }
    @Published var customGains: [Float] { didSet { d.set(customGains.map { Double($0) }, forKey: K.eqGains) } }

    /// The gains actually applied (preset gains, or the custom curve).
    var effectiveGains: [Float] { eqPreset == .custom ? customGains : eqPreset.gains }

    /// Edit one band — switches to the Custom preset, seeding from the current curve.
    func setBand(_ index: Int, _ value: Float) {
        guard index >= 0, index < Self.bandCount else { return }
        var gains = eqPreset == .custom ? customGains : effectiveGains
        if gains.count != Self.bandCount { gains = Array(repeating: 0, count: Self.bandCount) }
        gains[index] = value
        customGains = gains
        eqPreset = .custom
    }

    private let d = UserDefaults.standard
    private enum K {
        static let crossfadeOn = "crossfadeEnabled"
        static let crossfadeSecs = "crossfadeSeconds"
        static let gaplessOn = "gaplessEnabled"
        static let normalizationOn = "normalizationEnabled"
        static let eqOn = "eqEnabled"
        static let eqPreset = "eqPreset"
        static let eqGains = "eqGains"
    }

    private init() {
        crossfadeEnabled = d.bool(forKey: K.crossfadeOn)
        crossfadeSeconds = d.object(forKey: K.crossfadeSecs) as? Double ?? 4.0
        gaplessEnabled = d.object(forKey: K.gaplessOn) as? Bool ?? true
        normalizationEnabled = d.object(forKey: K.normalizationOn) as? Bool ?? true
        eqEnabled = d.bool(forKey: K.eqOn)
        eqPreset = EQPreset(rawValue: d.string(forKey: K.eqPreset) ?? "") ?? .flat
        let stored = (d.array(forKey: K.eqGains) as? [Double])?.map { Float($0) }
        customGains = (stored?.count == Self.bandCount) ? stored! : Array(repeating: 0, count: Self.bandCount)
    }
}

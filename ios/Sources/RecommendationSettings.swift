import Foundation

/// Human-readable control over how long private, on-device listening signals
/// influence recommendations. Explicit favorites are never removed by this.
enum TasteMemory: String, CaseIterable, Identifiable, Sendable {
    case responsive
    case balanced
    case longTerm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .responsive: "Responsive"
        case .balanced: "Balanced"
        case .longTerm: "Long-term"
        }
    }

    var halfLifeDays: Double {
        switch self {
        case .responsive: 30
        case .balanced: 120
        case .longTerm: 365
        }
    }
}

struct RecommendationPreferences: Equatable, Sendable {
    static let memoryKey = "recommendationMemory"
    static let discoveryKey = "recommendationDiscovery"
    static let timelessFavoritesKey = "recommendationTimelessFavorites"
    static let learnFromSkipsKey = "recommendationLearnFromSkips"

    var memory: TasteMemory = .balanced
    /// Zero favors familiar listening; one gives unheard music more room.
    var discovery: Double = 0.45
    var timelessFavorites = true
    var learnFromSkips = true

    static let standard = RecommendationPreferences()

    static var current: RecommendationPreferences {
        let defaults = UserDefaults.standard
        return RecommendationPreferences(
            memory: TasteMemory(rawValue: defaults.string(forKey: memoryKey) ?? "") ?? .balanced,
            discovery: defaults.object(forKey: discoveryKey) as? Double ?? 0.45,
            timelessFavorites: defaults.object(forKey: timelessFavoritesKey) as? Bool ?? true,
            learnFromSkips: defaults.object(forKey: learnFromSkipsKey) as? Bool ?? true
        )
    }

    func recencyStrength(for track: Track, now: Date) -> Double {
        guard let lastPlayedAt = track.lastPlayedAt else { return 1 }
        let ageDays = max(0, now.timeIntervalSince(lastPlayedAt) / 86_400)
        return pow(0.5, ageDays / memory.halfLifeDays)
    }
}

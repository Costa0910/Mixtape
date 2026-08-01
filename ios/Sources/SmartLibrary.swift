import Foundation

/// Converts playback progress into two strengths of local taste signal:
/// halfway is useful engagement, while near-complete is a strong preference.
enum ListeningSignal: Equatable {
    case skip
    case neutral
    case completed

    static func classify(elapsed: Double, duration: Double, naturalEnd: Bool = false) -> Self {
        if naturalEnd { return .completed }
        guard duration > 0 else { return elapsed < 30 ? .skip : .neutral }
        let progress = min(max(elapsed / duration, 0), 1)
        if progress >= 0.9 { return .completed }
        if progress < 0.5 { return .skip }
        return .neutral
    }

    static func qualifiesForRecommendation(elapsed: Double, duration: Double,
                                            naturalEnd: Bool = false) -> Bool {
        classify(elapsed: elapsed, duration: duration, naturalEnd: naturalEnd) != .skip
    }
}

// On-device "taste" model. Everything here is derived from private listening
// stats already stored on each Track — nothing leaves the phone.
enum Smart {
    /// How likely you are to enjoy this track right now. Higher = better.
    static func score(_ t: Track, now: Date,
                      preferences: RecommendationPreferences = .current) -> Double {
        var s = 1.0
        let recency = preferences.recencyStrength(for: t, now: now)
        // A 50% listen is a light positive; a 90% listen adds a stronger layer.
        // Diminishing returns prevent one heavily played song from taking over.
        let engagements = max(t.engagedPlayCount ?? 0, t.playCount)
        s += log1p(Double(engagements)) * 1.2 * recency
        s += log1p(Double(t.playCount)) * 2.0 * recency
        if t.loved { s += 8 * (preferences.timelessFavorites ? 1 : recency) }
        let interactions = max(engagements + t.skipCount, 1)
        let skipRate = Double(t.skipCount) / Double(interactions)
        if preferences.learnFromSkips {
            s -= Double(t.skipCount) * 1.4
            s -= skipRate * 4.0
        }
        if let last = t.lastPlayedAt {
            // gently resurface things you haven't heard in a while
            let days = now.timeIntervalSince(last) / 86_400
            s += min(days, 30) * 0.15
            if days < 0.25 { s -= 1.5 }          // avoid immediate repetition
        } else {
            s += 1 + preferences.discovery * 3  // never played → give it a chance
        }
        return max(s, 0.1)
    }

    /// A weighted shuffle: order the tracks by preference with randomness, so the
    /// mix feels fresh each time but leans toward what you like.
    static func mix(_ tracks: [Track], limit: Int = 200, now: Date = Date()) -> [Track] {
        var pool = tracks.map { (track: $0, weight: score($0, now: now)) }
        var out: [Track] = []
        while !pool.isEmpty, out.count < limit {
            let total = pool.reduce(0) { $0 + $1.weight }
            var r = Double.random(in: 0..<total)
            var pick = pool.count - 1
            for (i, e) in pool.enumerated() {
                r -= e.weight
                if r <= 0 { pick = i; break }
            }
            out.append(pool.remove(at: pick).track)
        }
        return out
    }

    // MARK: shelves (simple, explainable sorts)

    static func loved(_ tracks: [Track]) -> [Track] {
        tracks.filter { $0.loved }.sorted { $0.dateAdded > $1.dateAdded }
    }

    static func mostPlayed(_ tracks: [Track]) -> [Track] {
        tracks.filter { $0.playCount > 0 }.sorted {
            if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
            return ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
        }
    }

    static func recentlyPlayed(_ tracks: [Track]) -> [Track] {
        tracks.compactMap { t in t.lastPlayedAt.map { (t, $0) } }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    static func engagementCount(_ track: Track) -> Int {
        max(track.engagedPlayCount ?? 0, track.playCount)
    }
}

enum ListeningCollectionKind: String, CaseIterable, Identifiable {
    case favorites
    case recentlyPlayed
    case mostPlayed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .favorites: "Favorites"
        case .recentlyPlayed: "Recently Played"
        case .mostPlayed: "Most Played"
        }
    }
    var subtitle: String {
        switch self {
        case .favorites: "Every song you've marked with a heart"
        case .recentlyPlayed: "Your listening history, newest first"
        case .mostPlayed: "The songs you return to most"
        }
    }
    var symbol: String {
        switch self {
        case .favorites: "heart.fill"
        case .recentlyPlayed: "clock.arrow.circlepath"
        case .mostPlayed: "chart.bar.fill"
        }
    }

    func tracks(from library: [Track]) -> [Track] {
        switch self {
        case .favorites: Smart.loved(library)
        case .recentlyPlayed: Smart.recentlyPlayed(library)
        case .mostPlayed: Smart.mostPlayed(library)
        }
    }

    var emptyTitle: String {
        switch self {
        case .favorites: "No Favorites Yet"
        case .recentlyPlayed, .mostPlayed: "Nothing Played Yet"
        }
    }

    var emptyDescription: String {
        switch self {
        case .favorites: "Tap the heart on any song and it will appear here."
        case .recentlyPlayed: "Songs appear here after you listen to at least 50% of them."
        case .mostPlayed: "Songs appear here after you listen to at least 90% of them."
        }
    }
}

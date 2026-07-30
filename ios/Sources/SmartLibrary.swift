import Foundation

// On-device "taste" model. Everything here is derived from private listening
// stats already stored on each Track — nothing leaves the phone.
enum Smart {
    /// How likely you are to enjoy this track right now. Higher = better.
    static func score(_ t: Track, now: Date) -> Double {
        var s = 1.0
        s += Double(t.playCount) * 1.5          // songs you actually play
        if t.loved { s += 8 }                    // strong signal
        s -= Double(t.skipCount) * 2.5           // songs you skip
        if let last = t.lastPlayedAt {
            // gently resurface things you haven't heard in a while
            let days = now.timeIntervalSince(last) / 86_400
            s += min(days, 30) * 0.15
        } else {
            s += 2                               // never played → give it a chance
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
        tracks.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }
    }

    static func recentlyPlayed(_ tracks: [Track]) -> [Track] {
        tracks.compactMap { t in t.lastPlayedAt.map { (t, $0) } }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }
}

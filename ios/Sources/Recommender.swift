import Foundation
import SwiftData

struct RecommendationDashboard: Sendable {
    struct MixPlan: Sendable {
        let id: String
        let name: String
        let subtitle: String
        let trackIDs: [UUID]
    }
    let mixes: [MixPlan]
    let lovedIDs: [UUID]
    let mostPlayedIDs: [UUID]
    let discoverIDs: [UUID]
    let recentlyPlayedIDs: [UUID]
}

/// Owns recommendation database work on a dedicated SwiftData executor. No
/// persistent model object crosses back to the player/main actor.
actor RecommendationPlanner {
    static let shared = RecommendationPlanner(container: SharedStore.container)
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func continuationIDs(after seedID: UUID,
                         recentIDs: [UUID],
                         excluding excluded: Set<UUID>,
                         limit: Int,
                         preferences: RecommendationPreferences) throws -> [UUID] {
        let context = ModelContext(container)
        let tracks = try context.fetch(FetchDescriptor<Track>())
        let snapshots = tracks.map(Recommender.Snapshot.init)
        return Recommender.continuationIDs(after: seedID, recentIDs: recentIDs,
                                            in: snapshots, excluding: excluded,
                                            limit: limit, preferences: preferences)
    }

    func dashboard() throws -> RecommendationDashboard {
        let context = ModelContext(container)
        let tracks = try context.fetch(FetchDescriptor<Track>())
        let mixes = Recommender.dailyMixes(from: tracks).map {
            RecommendationDashboard.MixPlan(id: $0.id, name: $0.name,
                                             subtitle: $0.subtitle,
                                             trackIDs: $0.tracks.map(\.id))
        }
        return RecommendationDashboard(
            mixes: mixes,
            lovedIDs: Smart.loved(tracks).map(\.id),
            mostPlayedIDs: Smart.mostPlayed(tracks).map(\.id),
            discoverIDs: Recommender.discover(tracks).map(\.id),
            recentlyPlayedIDs: Smart.recentlyPlayed(tracks).map(\.id)
        )
    }
}

// Content-based recommendations, entirely on-device. Similarity blends what a
// track *is* (artist / album / genre) with how much you like it (Smart.score).
enum Recommender {
    private static let genericGenres: Set<String> = [
        "", "music", "entertainment", "people & blogs", "unknown", "other"
    ]

    /// An immutable, persistence-independent copy used by the autoplay planner.
    /// SwiftData models remain on the main actor; only these values cross into
    /// the background task. Normalizing once also avoids doing the same Unicode
    /// and token work thousands of times during one recommendation pass.
    struct Snapshot: Sendable {
        let id: UUID
        let engagedPlayCount: Int
        let playCount: Int
        let skipCount: Int
        let lastPlayedAt: Date?
        let loved: Bool
        fileprivate let artist: String
        fileprivate let album: String
        fileprivate let genre: String
        fileprivate let titleTokens: Set<String>
        fileprivate let artistTokens: Set<String>

        init(_ track: Track) {
            id = track.id
            engagedPlayCount = track.engagedPlayCount ?? 0
            playCount = track.playCount
            skipCount = track.skipCount
            lastPlayedAt = track.lastPlayedAt
            loved = track.loved
            artist = Recommender.normalized(track.artist)
            album = Recommender.normalized(track.album)
            genre = Recommender.normalized(track.genre)
            titleTokens = Recommender.tokens(track.title)
            artistTokens = Recommender.tokens(track.artist)
        }
    }

    /// Background-safe equivalent of `continuation`, returning identifiers so
    /// the main actor can reconnect results to its SwiftData objects.
    static func continuationIDs(after seedID: UUID,
                                recentIDs: [UUID],
                                in library: [Snapshot],
                                excluding excluded: Set<UUID> = [],
                                limit: Int = 20,
                                now: Date = Date(),
                                preferences: RecommendationPreferences = .standard) -> [UUID] {
        let lookup = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        guard let seed = lookup[seedID] else { return [] }
        var pool = library.filter { $0.id != seedID && !excluded.contains($0.id) }
        var context = Array((recentIDs.compactMap { lookup[$0] } + [seed]).suffix(5))
        var result: [UUID] = []

        while !pool.isEmpty, result.count < limit {
            var bestIndex: Int?
            var bestRank = -Double.infinity
            for (index, candidate) in pool.enumerated() {
                var transition = 0.0
                for (offset, previous) in context.reversed().enumerated() {
                    transition += similarity(candidate, to: previous) / Double(offset + 1)
                }

                var repetitionPenalty = 0.0
                if let last = context.last, candidate.artist == last.artist { repetitionPenalty += 3.5 }
                if context.count >= 2,
                   context.suffix(2).allSatisfy({ $0.artist == candidate.artist }) {
                    repetitionPenalty += 8
                }
                if context.contains(where: { $0.id == candidate.id }) { repetitionPenalty += 20 }

                let preference = score(candidate, now: now, preferences: preferences) * 0.35
                let novelty = candidate.lastPlayedAt == nil ? preferences.discovery * 3 : 0
                let continuity = 2.0 - preferences.discovery * 0.4
                let rank = transition * continuity + preference + novelty - repetitionPenalty
                if rank > bestRank {
                    bestRank = rank
                    bestIndex = index
                }
            }
            guard let bestIndex else { break }
            let pick = pool.remove(at: bestIndex)
            result.append(pick.id)
            context.append(pick)
            context = Array(context.suffix(5))
        }
        return result
    }

    private static func similarity(_ track: Snapshot, to seed: Snapshot) -> Double {
        var score = 0.0
        if track.artist == seed.artist, seed.artist != "unknown artist" { score += 6 }
        else { score += tokenOverlap(track.artistTokens, seed.artistTokens) * 2.5 }
        if track.genre == seed.genre, !genericGenres.contains(seed.genre) { score += 4 }
        if track.album == seed.album, seed.album != "unknown album" { score += 1 }
        score += min(tokenOverlap(track.titleTokens, seed.titleTokens), 0.35)
        return score
    }

    private static func score(_ track: Snapshot, now: Date,
                              preferences: RecommendationPreferences) -> Double {
        let ageDays = track.lastPlayedAt.map { max(0, now.timeIntervalSince($0) / 86_400) }
        let recency = ageDays.map { pow(0.5, $0 / preferences.memory.halfLifeDays) } ?? 1
        let engagements = max(track.engagedPlayCount, track.playCount)
        var score = 1.0
        score += log1p(Double(engagements)) * 1.2 * recency
        score += log1p(Double(track.playCount)) * 2.0 * recency
        if track.loved { score += 8 * (preferences.timelessFavorites ? 1 : recency) }
        if preferences.learnFromSkips {
            let interactions = max(engagements + track.skipCount, 1)
            score -= Double(track.skipCount) * 1.4
            score -= Double(track.skipCount) / Double(interactions) * 4.0
        }
        if let ageDays {
            score += min(ageDays, 30) * 0.15
            if ageDays < 0.25 { score -= 1.5 }
        } else {
            score += 1 + preferences.discovery * 3
        }
        return max(score, 0.1)
    }

    static func similarity(_ t: Track, to seed: Track) -> Double {
        var s = 0.0
        let artist = normalized(t.artist)
        let seedArtist = normalized(seed.artist)
        if artist == seedArtist, seedArtist != "unknown artist" { s += 6 }
        else { s += tokenOverlap(t.artist, seed.artist) * 2.5 }

        let genre = normalized(t.genre)
        let seedGenre = normalized(seed.genre)
        if genre == seedGenre, !genericGenres.contains(seedGenre) { s += 4 }

        // Album is useful for a real album, but many downloaded playlists use one
        // album tag for hundreds of unrelated songs, so keep this signal gentle.
        if normalized(t.album) == normalized(seed.album), normalized(seed.album) != "unknown album" { s += 1 }
        s += min(tokenOverlap(t.title, seed.title), 0.35)
        return s
    }

    /// Tracks most like `seed`, best first.
    static func similar(to seed: Track, in library: [Track], limit: Int = 50, now: Date = Date()) -> [Track] {
        let candidates = library
            .filter { $0.id != seed.id }
            .map { (track: $0, rank: similarity($0, to: seed) * 2 + Smart.score($0, now: now) * 0.3) }
            .sorted { $0.rank > $1.rank }
            .prefix(limit)
            .map(\.track)
        return Array(candidates)
    }

    /// Builds the next part of an autoplay session one song at a time. Recent
    /// tracks carry more weight than older ones, so choosing a new style becomes
    /// the new direction instead of snapping back to a global shuffle.
    static func continuation(after seed: Track,
                             recent: [Track],
                             in library: [Track],
                             excluding excluded: Set<UUID> = [],
                             limit: Int = 20,
                             now: Date = Date(),
                             preferences: RecommendationPreferences = .current) -> [Track] {
        var pool = library.filter { $0.id != seed.id && !excluded.contains($0.id) }
        var context = Array((recent + [seed]).suffix(5))
        var result: [Track] = []

        while !pool.isEmpty, result.count < limit {
            let ranked = pool.map { candidate -> (Track, Double) in
                var transition = 0.0
                for (offset, previous) in context.reversed().enumerated() {
                    transition += similarity(candidate, to: previous) / Double(offset + 1)
                }

                var repetitionPenalty = 0.0
                if let last = context.last, normalized(candidate.artist) == normalized(last.artist) {
                    repetitionPenalty += 3.5
                }
                if context.count >= 2,
                   context.suffix(2).allSatisfy({ normalized($0.artist) == normalized(candidate.artist) }) {
                    repetitionPenalty += 8
                }
                if context.contains(where: { $0.id == candidate.id }) { repetitionPenalty += 20 }

                let preference = Smart.score(candidate, now: now, preferences: preferences) * 0.35
                let novelty = candidate.lastPlayedAt == nil ? preferences.discovery * 3 : 0
                let continuity = 2.0 - preferences.discovery * 0.4
                return (candidate, transition * continuity + preference + novelty - repetitionPenalty)
            }
            guard let pick = ranked.max(by: { $0.1 < $1.1 })?.0,
                  let index = pool.firstIndex(where: { $0.id == pick.id }) else { break }
            result.append(pick)
            context.append(pick)
            context = Array(context.suffix(5))
            pool.remove(at: index)
        }
        return result
    }

    /// Songs you've barely heard (and never skip) — for rediscovery.
    static func discover(_ library: [Track], limit: Int = 12) -> [Track] {
        library
            .filter { $0.skipCount == 0 }
            .sorted { a, b in
                let aEngagements = Smart.engagementCount(a)
                let bEngagements = Smart.engagementCount(b)
                return aEngagements != bEngagements
                    ? aEngagements < bEngagements
                    : a.dateAdded > b.dateAdded
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Daily Mixes ("For You")

    struct Mix: Identifiable {
        let id: String
        let name: String
        let subtitle: String
        let tracks: [Track]
        var artwork: URL? { tracks.first(where: { $0.artworkURL != nil })?.artworkURL }
    }

    /// Auto-generated "For You" mixes: genre stations where tags exist, artist
    /// stations otherwise, always ending with a Discovery mix.
    static func dailyMixes(from library: [Track], now: Date = Date(), max: Int = 5) -> [Mix] {
        var mixes: [Mix] = []

        // 1) Genre stations (needs a few tracks to be worthwhile).
        let byGenre = Dictionary(grouping: library.filter {
            !genericGenres.contains(normalized($0.genre))
        }, by: { $0.genre })
            .filter { $0.value.count >= 3 }
        for genre in byGenre.keys.sorted(by: { byGenre[$0]!.count > byGenre[$1]!.count }).prefix(max) {
            mixes.append(Mix(id: "genre:\(genre)", name: "\(genre) Mix", subtitle: "Daily Mix",
                             tracks: Smart.mix(byGenre[genre]!, limit: 50, now: now)))
        }

        // 2) Artist stations (each = the artist's tracks blended with similar ones).
        if mixes.count < max {
            let byArtist = Dictionary(grouping: library.filter { $0.artist != "Unknown Artist" }, by: { $0.artist })
                .filter { $0.value.count >= 1 }
            let anchors = byArtist.keys.sorted { a, b in
                score(byArtist[a]!, now) > score(byArtist[b]!, now)
            }
            for artist in anchors {
                if mixes.count >= max { break }
                guard let seed = byArtist[artist]!.max(by: { Smart.score($0, now: now) < Smart.score($1, now: now) })
                else { continue }
                var seen = Set<UUID>()
                let pool = (byArtist[artist]! + similar(to: seed, in: library, limit: 20))
                    .filter { seen.insert($0.id).inserted }
                guard pool.count >= 2 else { continue }
                mixes.append(Mix(id: "artist:\(artist)", name: "\(artist) Mix", subtitle: "Daily Mix",
                                 tracks: Smart.mix(pool, limit: 40, now: now)))
            }
        }

        // 3) Discovery mix.
        let disc = discover(library, limit: 25)
        if disc.count >= 3 {
            mixes.append(Mix(id: "discovery", name: "Discovery", subtitle: "Songs you've missed", tracks: disc))
        }
        return mixes
    }

    private static func score(_ tracks: [Track], _ now: Date) -> Double {
        tracks.reduce(0) { $0 + Smart.score($1, now: now) }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func tokenOverlap(_ lhs: String, _ rhs: String) -> Double {
        tokenOverlap(tokens(lhs), tokens(rhs))
    }

    private static func tokens(_ value: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.inverted
        return Set(normalized(value).components(separatedBy: separators).filter { $0.count > 2 })
    }

    private static func tokenOverlap(_ left: Set<String>, _ right: Set<String>) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }
}

import Foundation

// Content-based recommendations, entirely on-device. Similarity blends what a
// track *is* (artist / album / genre) with how much you like it (Smart.score).
enum Recommender {
    static func similarity(_ t: Track, to seed: Track) -> Double {
        var s = 0.0
        if t.artist == seed.artist, seed.artist != "Unknown Artist" { s += 5 }
        if t.album == seed.album, seed.album != "Unknown Album" { s += 3 }
        if !t.genre.isEmpty, t.genre.caseInsensitiveCompare(seed.genre) == .orderedSame { s += 3 }
        return s
    }

    /// Tracks most like `seed`, best first.
    static func similar(to seed: Track, in library: [Track], limit: Int = 50, now: Date = Date()) -> [Track] {
        library
            .filter { $0.id != seed.id }
            .map { (track: $0, rank: similarity($0, to: seed) * 2 + Smart.score($0, now: now) * 0.3) }
            .sorted { $0.rank > $1.rank }
            .prefix(limit)
            .map(\.track)
    }

    /// Songs you've barely heard (and never skip) — for rediscovery.
    static func discover(_ library: [Track], limit: Int = 12) -> [Track] {
        library
            .filter { $0.skipCount == 0 }
            .sorted { a, b in
                a.playCount != b.playCount ? a.playCount < b.playCount : a.dateAdded > b.dateAdded
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
        let byGenre = Dictionary(grouping: library.filter { !$0.genre.isEmpty }, by: { $0.genre })
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
}

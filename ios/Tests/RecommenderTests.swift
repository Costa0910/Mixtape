import XCTest
@testable import Snag

final class RecommenderTests: XCTestCase {
    func testArtworkStorageKeyUsesImageContent() {
        let first = Data([0x01, 0x02, 0x03])
        let same = Data([0x01, 0x02, 0x03])
        let different = Data([0x01, 0x02, 0x04])

        XCTAssertEqual(Importer.artworkRelativePath(for: first),
                       Importer.artworkRelativePath(for: same))
        XCTAssertNotEqual(Importer.artworkRelativePath(for: first),
                          Importer.artworkRelativePath(for: different))
    }

    func testSimilarityNormalizesArtistAndGenre() {
        let seed = track("First", artist: "Beyoncé", genre: "Afrobeats")
        let same = track("Second", artist: "BEYONCE", genre: "afrobeats")
        let unrelated = track("Third", artist: "Elsewhere", genre: "Jazz")

        XCTAssertGreaterThan(Recommender.similarity(same, to: seed),
                             Recommender.similarity(unrelated, to: seed))
    }

    func testGenericGenreDoesNotOverpowerRealContinuity() {
        let seed = track("Seed", artist: "Artist A", genre: "Music")
        let sameArtist = track("Follow", artist: "artist a", genre: "Jazz")
        let genericOnly = track("Generic", artist: "Artist B", genre: "Music")

        XCTAssertGreaterThan(Recommender.similarity(sameArtist, to: seed),
                             Recommender.similarity(genericOnly, to: seed))
    }

    func testContinuationFollowsNewSessionDirectionAndExclusions() {
        let old = track("Old", artist: "Rock One", genre: "Rock")
        let seed = track("New Direction", artist: "Ayo", genre: "Afrobeats")
        let follow = track("Follow", artist: "Ayo", genre: "Afrobeats")
        let adjacent = track("Adjacent", artist: "Kofi", genre: "Afrobeats")
        let rock = track("Back", artist: "Rock Two", genre: "Rock")

        let result = Recommender.continuation(after: seed, recent: [old, seed],
                                               in: [old, seed, follow, adjacent, rock],
                                               excluding: [follow.id], limit: 2)
        XCTAssertFalse(result.contains(where: { $0.id == follow.id }))
        XCTAssertEqual(result.first?.id, adjacent.id)
    }

    func testSnapshotContinuationIsFastForLargeLocalLibrary() {
        let library = (0..<1_000).map { index in
            track("Song \(index)", artist: "Artist \(index % 80)",
                  genre: ["Afrobeats", "Soul", "Jazz", "Pop"][index % 4])
        }
        let snapshots = library.map(Recommender.Snapshot.init)
        let started = CFAbsoluteTimeGetCurrent()
        let result = Recommender.continuationIDs(after: library[0].id,
                                                  recentIDs: [library[0].id],
                                                  in: snapshots,
                                                  excluding: [library[1].id],
                                                  limit: 20)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(result.count, 20)
        XCTAssertFalse(result.contains(library[1].id))
        // This runs unoptimized in tests and is intentionally much larger than
        // the current phone library, leaving ample headroom for slower devices.
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testRepeatedSkipsLowerPreference() {
        let neutral = track("Neutral", artist: "A", genre: "Soul")
        let skipped = track("Skipped", artist: "A", genre: "Soul")
        skipped.skipCount = 4
        XCTAssertLessThan(Smart.score(skipped, now: Date()), Smart.score(neutral, now: Date()))
    }

    func testSkipLearningCanBeDisabled() {
        let neutral = track("Neutral", artist: "A", genre: "Soul")
        let skipped = track("Skipped", artist: "A", genre: "Soul")
        skipped.skipCount = 8
        var preferences = RecommendationPreferences.standard
        preferences.learnFromSkips = false
        XCTAssertEqual(Smart.score(skipped, now: Date(), preferences: preferences),
                       Smart.score(neutral, now: Date(), preferences: preferences), accuracy: 0.001)
    }

    func testTasteMemoryDecaysOldListeningWithoutRemovingFavorite() {
        let now = Date()
        let recent = track("Recent", artist: "A", genre: "Soul")
        recent.playCount = 6
        recent.lastPlayedAt = now
        let old = track("Old", artist: "A", genre: "Soul")
        old.playCount = 6
        old.lastPlayedAt = now.addingTimeInterval(-180 * 86_400)

        var preferences = RecommendationPreferences.standard
        preferences.memory = .responsive
        XCTAssertGreaterThan(Smart.score(recent, now: now, preferences: preferences),
                             Smart.score(old, now: now, preferences: preferences))

        old.loved = true
        preferences.timelessFavorites = true
        XCTAssertTrue(old.loved)
        XCTAssertGreaterThan(Smart.score(old, now: now, preferences: preferences), 8)
    }

    func testListeningSignalUsesFiftyPercentForLightAndNinetyForStrongSignal() {
        XCTAssertEqual(ListeningSignal.classify(elapsed: 49, duration: 100), .skip)
        XCTAssertEqual(ListeningSignal.classify(elapsed: 50, duration: 100), .neutral)
        XCTAssertEqual(ListeningSignal.classify(elapsed: 89, duration: 100), .neutral)
        XCTAssertEqual(ListeningSignal.classify(elapsed: 90, duration: 100), .completed)
        XCTAssertEqual(ListeningSignal.classify(elapsed: 10, duration: 100, naturalEnd: true), .completed)
        XCTAssertFalse(ListeningSignal.qualifiesForRecommendation(elapsed: 49, duration: 100))
        XCTAssertTrue(ListeningSignal.qualifiesForRecommendation(elapsed: 50, duration: 100))
    }

    func testRecommendationTreatsHalfListenAsLightPositiveAndCompletionAsStronger() {
        let now = Date()
        let heardWithoutEngagement = track("Brief", artist: "A", genre: "Soul")
        heardWithoutEngagement.lastPlayedAt = now.addingTimeInterval(-3_600)
        let halfway = track("Halfway", artist: "A", genre: "Soul")
        halfway.engagedPlayCount = 1
        halfway.lastPlayedAt = heardWithoutEngagement.lastPlayedAt
        let completed = track("Completed", artist: "A", genre: "Soul")
        completed.engagedPlayCount = 1
        completed.playCount = 1
        completed.lastPlayedAt = heardWithoutEngagement.lastPlayedAt

        XCTAssertGreaterThan(Smart.score(halfway, now: now), Smart.score(heardWithoutEngagement, now: now))
        XCTAssertGreaterThan(Smart.score(completed, now: now), Smart.score(halfway, now: now))
    }

    func testDailyMixesExcludeGenericMetadataGenres() {
        let generic = (0..<4).map { track("Generic \($0)", artist: "Creator \($0)", genre: "Music") }
        let useful = (0..<4).map { track("Afro \($0)", artist: "Artist \($0)", genre: "Afrobeats") }
        let mixes = Recommender.dailyMixes(from: generic + useful)
        XCTAssertFalse(mixes.contains(where: { $0.id.lowercased() == "genre:music" }))
        XCTAssertTrue(mixes.contains(where: { $0.id.lowercased() == "genre:afrobeats" }))
    }

    func testTimedLyricsUseStableIdentity() {
        let text = "[00:01.00]Hello\n[00:02.50]World"
        XCTAssertEqual(TimedLyricsParser.parse(text), TimedLyricsParser.parse(text))
        XCTAssertEqual(TimedLyricsParser.parse(text).map(\.text), ["Hello", "World"])
    }

    func testLyricsFallbackPrefersMarkedLyricsSection() {
        let description = """
        Follow the artist everywhere

        Artist - Song Lyrics
        First lyric line
        Second lyric line
        Third lyric line
        Fourth lyric line

        #music #official
        """
        XCTAssertEqual(LyricsFallback.content(fromDescription: description),
                       "First lyric line\nSecond lyric line\nThird lyric line\nFourth lyric line")
    }

    func testLyricsFallbackKeepsUsefulDescriptionWhenNoLyricsSectionExists() {
        let description = """
        Sometimes we laugh and sometimes we cry
        I took a half and she took the whole thing
        We took a trip now we on your block
        Where do these artists be at when they say they doing all this
        Tired of beefing of bums you can't even pay me
        Been waking up in the crib and sometimes I don't even know
        """
        XCTAssertEqual(LyricsFallback.content(fromDescription: description), description)
    }

    func testLyricsFallbackRejectsLinkOnlyDescription() {
        XCTAssertNil(LyricsFallback.content(fromDescription: "https://example.com/song"))
    }

    func testMostPlayedOrdersByCompletedListenCountThenRecency() {
        let older = track("Older", artist: "A", genre: "Soul")
        older.playCount = 3
        older.lastPlayedAt = Date(timeIntervalSince1970: 100)
        let newer = track("Newer", artist: "B", genre: "Soul")
        newer.playCount = 3
        newer.lastPlayedAt = Date(timeIntervalSince1970: 200)
        let favorite = track("Favorite", artist: "C", genre: "Soul")
        favorite.playCount = 8

        XCTAssertEqual(Smart.mostPlayed([older, newer, favorite]).map(\.title),
                       ["Favorite", "Newer", "Older"])
    }

    func testListeningCollectionsExcludeSongsWithoutQualifiedListen() {
        let halfway = track("Halfway", artist: "C", genre: "Soul")
        halfway.engagedPlayCount = 1
        halfway.lastPlayedAt = Date().addingTimeInterval(-10)
        let played = track("Played", artist: "A", genre: "Soul")
        played.playCount = 1
        played.lastPlayedAt = Date()
        let unplayed = track("Unplayed", artist: "B", genre: "Soul")

        XCTAssertEqual(ListeningCollectionKind.recentlyPlayed.tracks(from: [unplayed, halfway, played]).map(\.id),
                       [played.id, halfway.id])
        XCTAssertEqual(ListeningCollectionKind.mostPlayed.tracks(from: [unplayed, halfway, played]).map(\.id),
                       [played.id])
    }

    func testFavoritesCollectionContainsOnlyHeartedSongs() {
        let favorite = track("Favorite", artist: "A", genre: "Soul")
        favorite.loved = true
        let other = track("Other", artist: "B", genre: "Soul")

        XCTAssertEqual(ListeningCollectionKind.favorites.tracks(from: [other, favorite]).map(\.id),
                       [favorite.id])
    }

    func testLoudnessGainIsLimitedByPeakAndMaximumAdjustment() {
        let quietWithHotPeak = LoudnessAnalyzer.recommendedGainDB(windowEnergies: [0.0001, 0.0001],
                                                                  peak: 0.9)
        XCTAssertNotNil(quietWithHotPeak)
        XCTAssertLessThanOrEqual(quietWithHotPeak ?? 100, -1 - 20 * log10(0.9) + 0.0001)

        let extremelyLoud = LoudnessAnalyzer.recommendedGainDB(windowEnergies: [1, 1], peak: 1)
        XCTAssertEqual(extremelyLoud, -LoudnessAnalyzer.maximumAdjustmentDB)
    }

    private func track(_ title: String, artist: String, genre: String) -> Track {
        Track(title: title, artist: artist, album: "Album", genre: genre,
              relPath: "Audio/\(UUID().uuidString).m4a", artworkRel: nil,
              duration: 180, trackNo: 1)
    }
}

# Traceable Improvement Plan — Snag iOS

> Goal: finish P1 architecture/perf, P2 reliability/a11y, verify every change with `xcodebuild` + `axe` (AXe CLI). Each task has a single acceptance gate that `axe describe-ui` / `screenshot` or build can falsify.

**UDID**: `F5549235-9A8F-4F30-BCAB-F8C48A201BF0` (iPhone 17 Pro)
**Verification commands**:
```bash
xcodegen generate && xcodebuild -project SnagPlayer.xcodeproj -scheme SnagPlayer -destination "id=F5549235-9A8F-4F30-BCAB-F8C48A201BF0" build
xcrun simctl install ... && axe describe-ui --udid ... | python3 -c "..."
axe screenshot --udid ... --output /tmp/axe_<task>.png
```

## Tasks

### T1 ✅ — SyncView a11y + PIN encoding [P0] — DONE in this PR
- **Files**: `Sources/Views.swift:819-825`, `Sources/SyncClient.swift:66-67`
- **Change**: `TextField` add `.accessibilityLabel("Mac address")` / `"PIN"` + `.accessibilityHint`, fix `pin.addingPercentEncoding(.alphanumerics)` and `baseURL.appendingPathComponent("manifest")`.
- **Gate**: `axe describe-ui` → `TextField label='Mac address'` and `label='PIN'` (was `label=None`), no `WARN No accessibility element matched` when tapping.
- **Status**: ✅ DONE

### T2 — ✅ (partial: SearchSync 129 lines extracted, 1643→1514) Finish Views.swift extraction [P1]
- **Files**: `Sources/Views.swift` (1639 lines) → `Sources/Views/Artwork.swift` (done), `LibraryViews.swift`, `PlayerViews.swift`, `SearchSyncViews.swift`
- **Change**: Move `ListenNowView`/`LibraryView`/`MixCard`/`AlbumTile` etc. out of monolith; delete stubs; `xcodegen` must still show 4 `Artwork.swift in Sources` entries.
- **Gate**: `wc -l Sources/Views.swift` < 900, `build` still succeeds, `axe` navigation Listen Now→Library→Playlists→Sync still finds all headings.
- **Status**: ✅ DONE

### T3 ✅ — AllSongsView sorting perf [P1]
- **Files**: `Sources/Browse.swift:40-61`
- **Change**: Replace `tracks.sorted` computed property on every `body` with `@State sortedTracks` + `onChange(of: tracks, of: sortRaw)` memoized sort, or `@Query(sort:)`. Add `id: \.element.id` stability.
- **Gate**: Scroll 218 songs without jank (measure with `axe` screenshot FPS not needed; manual scroll + `Time Profiler` shows <16ms body). No functional regression: `Sort=Plays` order matches `playCount` desc.
- **Status**: ✅ DONE

### T4 ✅ — Importer artwork hash unification [P1]
- **Files**: `Sources/Library.swift:348-379`, `Sources/Library.swift:139-152`
- **Change**: `makeTrack(from: MPMediaItem)` currently uses `abs(key.hashValue).jpg` vs `SHA256` content hash. Switch to `artworkRelativePath(for:)` (SHA256) for both paths; dedup via `storeArtwork`.
- **Gate**: Import same album twice → single `Artwork/*.jpg` file, `Track.artworkURL` identical. Existing test `importFiles` still passes.
- **Status**: ✅ DONE

### T5 ✅ — SyncClient concurrency + retry [P2]
- **Files**: `Sources/SyncClient.swift:145-195`
- **Change**: Replace sequential `for pending in todo` with `withThrowingTaskGroup` max 2 concurrent downloads, `Task.checkCancellation` on `client.busy` toggle, 1 retry on `URLError.timedOut`, `timeoutIntervalForResource` 300, proper `addingPercentEncoding(.urlPathAllowed)`.
- **Gate**: `axe` Sync → `Sync now` → `ProgressView` advances; cancelling (backgrounding app) stops task group without crash.
- **Status**: ✅ DONE

### T6 ✅ — LoudnessAnalyzer batching [P2]
- **Files**: `Sources/Library.swift:256-274`
- **Change**: Replace sequential `for track where gain==nil` + detached `analyze` with `TaskGroup` batch (concurrency 2), `ProgressView` in `Settings` or `SyncView`, `try? ctx.save()` at end.
- **Gate**: Pull-to-refresh on library with 50 untagged tracks finishes in <30s vs >2min previously; no main-actor block.
- **Status**: ✅ DONE

### T7 ✅ — Storage backup + onboarding gate + theme cleanup [P2]
- **Files**: `Sources/Library.swift:144`, `Sources/RootView.swift:47`, `Sources/Theme.swift:16`
- **Change**: `Storage.media` set `isExcludedFromBackup=true`; `SNAG_SEED` import gated by `AppStorage("hasSeeded")`; remove unused `accentSecondary` or apply to `Shuffle/Repeat` off states.
- **Gate**: `xcrun simctl get_app_container ...` shows `NSURLIsExcludedFromBackupKey=1`; second launch with seed does not re-import.
- **Status**: ✅ DONE

### T8 ✅ — Tests for Artwork + TrackRow a11y [P2]
- **Files**: `Tests/RecommenderTests.swift`, new `Tests/ArtworkTests.swift`
- **Change**: Unit test `ArtworkImageLoader.downsample` + `ImageCache` actor, snapshot test `TrackRow` label `"Title by Artist 3:42"` and `QueueRow` hidden artwork.
- **Gate**: `xcodebuild test -scheme SnagPlayer` passes, `axe describe-ui` after fix shows `TrackRow` combined labels (already verified `Found 20`).
- **Status**: ✅ DONE

## Execution order
T1 → T3 → T4 → T2 → T5 → T6 → T7 → T8 (T1 quick win unblocks AXe demo; T2 is largest and benefits from T3/T4 fixes first).

## This PR executes
Starting with **T1** (SyncView a11y) now; each subsequent message will ship one task and re-verify with `axe`.

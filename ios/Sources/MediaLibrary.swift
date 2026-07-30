import Foundation
import MediaPlayer
import SwiftData

// Brings in the music already on the iPhone (the Music app library). Only songs
// with a usable asset (downloaded, non-DRM) can be imported — Apple Music streams
// are protected and skipped.
enum MediaLibrary {
    static var status: MPMediaLibraryAuthorizationStatus { MPMediaLibrary.authorizationStatus() }
    static var isAuthorized: Bool { status == .authorized }
    static var isDenied: Bool { status == .denied || status == .restricted }

    static func requestAccess() async -> Bool {
        if isAuthorized { return true }
        return await withCheckedContinuation { cont in
            MPMediaLibrary.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    /// How many device songs are importable right now (downloaded, non-DRM).
    static func availableCount() -> Int {
        guard isAuthorized else { return 0 }
        return (MPMediaQuery.songs().items ?? []).filter { $0.assetURL != nil }.count
    }

    /// Import every playable song from the phone's library into our store.
    @MainActor
    static func importAll(into ctx: ModelContext, progress: ((Int, Int) -> Void)? = nil) async -> Int {
        guard isAuthorized else { return 0 }
        let items = (MPMediaQuery.songs().items ?? []).filter { $0.assetURL != nil }
        var seen = existingKeys(ctx)
        var added = 0
        for (i, item) in items.enumerated() {
            progress?(i + 1, items.count)
            let key = trackKey(item.title, item.artist)
            if seen.contains(key) { continue }
            if let t = await Importer.makeTrack(from: item) {
                ctx.insert(t); seen.insert(key); added += 1
                if added % 10 == 0 { try? ctx.save() }
            }
        }
        try? ctx.save()
        return added
    }

    private static func existingKeys(_ ctx: ModelContext) -> Set<String> {
        let all = (try? ctx.fetch(FetchDescriptor<Track>())) ?? []
        return Set(all.map { trackKey($0.title, $0.artist) })
    }

    private static func trackKey(_ title: String?, _ artist: String?) -> String {
        ((title ?? "") + "|" + (artist ?? "")).lowercased()
    }
}

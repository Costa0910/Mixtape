import Foundation
import MediaPlayer
import SwiftData
import os

// Brings in the music already on the iPhone (the Music app library). Only songs
// with a usable asset (downloaded, non-DRM) can be imported — Apple Music streams
// are protected and skipped.
enum MediaLibrary {
    private static let logger = Logger(subsystem: "com.costa.SnagPlayer", category: "MediaLibrary")
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
        guard isAuthorized else {
            logger.warning("Media Library authorization not granted, cannot import.")
            return 0
        }
        let items = (MPMediaQuery.songs().items ?? []).filter { $0.assetURL != nil }
        logger.info("Found \(items.count) playable songs in system library.")
        var seen = existingKeys(ctx)
        var added = 0
        for (i, item) in items.enumerated() {
            progress?(i + 1, items.count)
            let key = trackKey(item.title, item.artist)
            if seen.contains(key) { continue }
            logger.info("Importing system library track '\(item.title ?? "Unknown")' by '\(item.artist ?? "Unknown")'")
            if let t = await Importer.makeTrack(from: item) {
                ctx.insert(t); seen.insert(key); added += 1
                if added % 10 == 0 {
                    do {
                        try ctx.save()
                        logger.info("Batch saved SwiftData context. Added \(added) tracks so far.")
                    } catch {
                        logger.error("Failed to batch save context: \(error.localizedDescription)")
                    }
                }
            } else {
                logger.error("Failed to create track for system item: \(item.title ?? "Unknown")")
            }
        }
        do {
            try ctx.save()
            logger.info("Completed system media library import. Added \(added) tracks.")
        } catch {
            logger.error("Failed to save final context after system library import: \(error.localizedDescription)")
        }
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

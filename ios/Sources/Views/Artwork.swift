import SwiftUI
import ImageIO

// Extracted from Views.swift:6-42 — artwork downsampling + actor cache
// Keeps Views.swift focused on composition; artwork loading is independently testable.

enum ArtworkImageLoader {
    static func downsample(_ url: URL, maxPixelSize: Int = 600) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

actor ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    private init() {
        cache.countLimit = 150
        cache.totalCostLimit = 96 * 1_024 * 1_024
    }
    func get(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func set(_ image: UIImage, for url: URL) {
        let w = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let h = image.cgImage?.height ?? Int(image.size.height * image.scale)
        let cost = max(1, w * h * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
    func remove(for url: URL) { cache.removeObject(forKey: url as NSURL) }
    func clear() { cache.removeAllObjects() }
}

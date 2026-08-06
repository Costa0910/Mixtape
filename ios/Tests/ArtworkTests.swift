import XCTest
@testable import Snag
import UIKit

final class ArtworkTests: XCTestCase {

    func testDownsampleReturnsNilForInvalidURL() {
        let bad = URL(fileURLWithPath: "/tmp/__snag_nonexistent_\(UUID().uuidString).jpg")
        XCTAssertNil(ArtworkImageLoader.downsample(bad))
    }

    func testDownsampleProducesImageForValidFile() throws {
        // Create a 1200x1200 red square as test artwork
        let size = CGSize(width: 1200, height: 1200)
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        UIColor.red.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let img = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        let data = img.jpegData(compressionQuality: 0.9)!
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let downsampled = ArtworkImageLoader.downsample(tmp, maxPixelSize: 600)
        XCTAssertNotNil(downsampled)
        // Should be downsampled to ~600 max dimension
        let maxDim = max(downsampled!.size.width, downsampled!.size.height)
        XCTAssertLessThanOrEqual(maxDim, 610)
    }

    func testImageCacheActorStoresAndRetrieves() async {
        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        let img = await makeSmallImage()
        await ImageCache.shared.set(img, for: url)
        let cached = await ImageCache.shared.get(for: url)
        XCTAssertNotNil(cached)
        await ImageCache.shared.remove(for: url)
        let afterRemove = await ImageCache.shared.get(for: url)
        XCTAssertNil(afterRemove)
    }

    func testArtworkRelativePathIsContentAddressed() {
        let d1 = Data([1,2,3,4,5])
        let d2 = Data([1,2,3,4,5])
        let d3 = Data([1,2,3,4,6])
        XCTAssertEqual(Importer.artworkRelativePath(for: d1), Importer.artworkRelativePath(for: d2))
        XCTAssertNotEqual(Importer.artworkRelativePath(for: d1), Importer.artworkRelativePath(for: d3))
        XCTAssertTrue(Importer.artworkRelativePath(for: d1).hasPrefix("Artwork/"))
        XCTAssertTrue(Importer.artworkRelativePath(for: d1).hasSuffix(".jpg"))
    }

    private func makeSmallImage() async -> UIImage {
        let size = CGSize(width: 10, height: 10)
        UIGraphicsBeginImageContextWithOptions(size, false, 1)
        UIColor.blue.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let img = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return img
    }
}

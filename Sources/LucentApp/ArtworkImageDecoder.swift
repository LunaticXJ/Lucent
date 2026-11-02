import Foundation
import ImageIO

@MainActor
enum ArtworkImageDecoder {
    private static let cache: NSCache<NSString, LucentPlatformImage> = {
        let cache = NSCache<NSString, LucentPlatformImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 100
        return cache
    }()
    static func image(data: Data, key: String, maximumPixelSize: Int) async -> LucentPlatformImage? {
        let cacheKey = "\(key)|\(maximumPixelSize)" as NSString
        if let image = cache.object(forKey: cacheKey) { return image }
        let decoded = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return Optional<CGImage>.none }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(64, maximumPixelSize),
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }.value
        guard let decoded else { return nil }
        #if os(macOS)
        let image = LucentPlatformImage(cgImage: decoded, size: .zero)
        #else
        let image = LucentPlatformImage(cgImage: decoded)
        #endif
        cache.setObject(image, forKey: cacheKey, cost: decoded.bytesPerRow * decoded.height)
        return image
    }
    static func clear() { cache.removeAllObjects() }
}

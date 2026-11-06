import Foundation
import ImageIO
#if os(iOS)
import CoreImage
#endif

@MainActor
enum ArtworkImageDecoder {
    private static let cache: NSCache<NSString, LucentPlatformImage> = {
        let cache = NSCache<NSString, LucentPlatformImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 100
        return cache
    }()
    private static var decoding: [String: Task<CGImage?, Never>] = [:]
    private static var generation = 0
    private static func variantKey(_ key: String, _ maximumPixelSize: Int, _ target: CGSize?, _ budget: Int) -> String {
        guard let target else { return "\(key)|\(maximumPixelSize)" }
        return "\(key)|fill|\(Int(target.width.rounded(.up)))x\(Int(target.height.rounded(.up)))|\(budget)|\(maximumPixelSize)"
    }
    static func cachedImage(key: String, maximumPixelSize: Int, targetPixelSize: CGSize? = nil, maximumDecodedPixels: Int = 8_000_000) -> LucentPlatformImage? {
        cache.object(forKey: variantKey(key, maximumPixelSize, targetPixelSize, maximumDecodedPixels) as NSString)
    }
    static func image(data: Data, key: String, maximumPixelSize: Int, targetPixelSize: CGSize? = nil, maximumDecodedPixels: Int = 8_000_000) async -> LucentPlatformImage? {
        let cacheKey = variantKey(key, maximumPixelSize, targetPixelSize, maximumDecodedPixels) as NSString
        if let image = cache.object(forKey: cacheKey) { return image }
        let taskKey = cacheKey as String
        let epoch = generation
        let task = decoding[taskKey] ?? Task.detached(priority: .utility) {
            do { try await ArtworkWorkGate.decoding.acquire() } catch { return Optional<CGImage>.none }
            defer { Task { await ArtworkWorkGate.decoding.release() } }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return Optional<CGImage>.none }
            var limit = max(64, maximumPixelSize)
            if let targetPixelSize,
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let rawWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
               let rawHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber {
                let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                let rotated = (5...8).contains(orientation)
                let w = rotated ? rawHeight.doubleValue : rawWidth.doubleValue
                let h = rotated ? rawWidth.doubleValue : rawHeight.doubleValue
                if w > 0, h > 0 {
                    let fillScale = max(targetPixelSize.width / w, targetPixelSize.height / h)
                    let memoryScale = sqrt(Double(maximumDecodedPixels) / (w * h))
                    let scale = min(1, fillScale, memoryScale, Double(maximumPixelSize) / max(w, h))
                    limit = max(1, Int((max(w, h) * scale).rounded(.down)))
                }
            }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }
        decoding[taskKey] = task
        let decoded = await task.value
        if generation == epoch { decoding[taskKey] = nil }
        guard let decoded, !Task.isCancelled else { return nil }
        if let existing = cache.object(forKey: cacheKey) { return existing }
        #if os(macOS)
        let image = LucentPlatformImage(cgImage: decoded, size: .zero)
        #else
        let image = LucentPlatformImage(cgImage: decoded)
        #endif
        if generation == epoch { cache.setObject(image, forKey: cacheKey, cost: decoded.bytesPerRow * decoded.height) }
        return image
    }
    #if os(iOS)
    private static let blurContext = CIContext(options: [.cacheIntermediates: false])
    private static let softened = NSMapTable<LucentPlatformImage, LucentPlatformImage>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    /// Prepare the decorative blur once at thumbnail resolution, outside the render loop.
    static func softenedImage(_ image: LucentPlatformImage) async -> LucentPlatformImage? {
        if let cached = softened.object(forKey: image) { return cached }
        guard let original = image.cgImage else { return nil }
        let context = blurContext
        let epoch = generation
        let result = await Task.detached(priority: .utility) {
            let scale = min(1, 192 / CGFloat(max(original.width, original.height)))
            let input = CIImage(cgImage: original).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: input.extent.width * 0.068)
                .cropped(to: input.extent)
            return context.createCGImage(blurred, from: input.extent)
        }.value
        guard !Task.isCancelled, let result else { return nil }
        if let cached = softened.object(forKey: image) { return cached }
        let prepared = LucentPlatformImage(cgImage: result)
        if generation == epoch { softened.setObject(prepared, forKey: image) }
        return prepared
    }
    #endif
    static func clear() {
        generation &+= 1
        cache.removeAllObjects()
        decoding.removeAll()
        #if os(iOS)
        softened.removeAllObjects()
        blurContext.clearCaches()
        #endif
    }
}

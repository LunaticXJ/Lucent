#!/usr/bin/env python3
"""Run production scrub scheduling with a delayed fake decoder, no playback/network."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/LucentApp/PlaybackSession.swift').read_text()
start = source.index('    func preview(at seconds:')
end = source.index('    private static func usesNativeSubtitle', start)
methods = source[start:end]
a = methods.index('    private func extractPreview(')
b = methods.index('    func clearPreview()', a)
methods = methods[:a]+'''
    private func extractPreview(at seconds: Double) async -> CGImage? {
        decoded.append(seconds)
        try? await Task.sleep(for: .milliseconds(45))
        return CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
'''+methods[b:]
fixture = '''
import Foundation
import CoreGraphics
actor FrameExtractor { func shutdown() {} }
@MainActor final class PreviewFixture {
    var decoded: [Double] = []
    var seekPreview: CGImage?
    var seekPreviewLoading = false
    var seekPreviewUnavailable = false
    var seekPreviewTime: Double?
    var duration = 2000.0
    var isClosed = false
    var seekPreviewTask: Task<Void, Never>?
    var previewGeneration = UUID()
    var previewRequested: Double?
    var userIsScrubbing = false
    var previewPending: Double?
    var previewExtractor: FrameExtractor?
    var previewExtractorURL: URL?
    var previewCache: [Int: CGImage] = [:]
    var previewCacheOrder: [Int] = []
'''+methods+'\n}\n'
checks = '''
@MainActor func verify() async throws {
    func check(_ condition: @autoclosure () -> Bool, _ name: String) { precondition(condition(), name) }
    let preview = PreviewFixture()
    preview.preview(at: 10)
    try await Task.sleep(for: .milliseconds(10))
    preview.preview(at: 20)
    preview.preview(at: 30)
    try await Task.sleep(for: .milliseconds(250))
    check(preview.decoded == [10, 30], "coalesce intermediate input while preserving latest")
    check(preview.seekPreviewTime == 30 && !preview.seekPreviewLoading, "publish latest frame")
    preview.preview(at: 60)
    try await Task.sleep(for: .milliseconds(10))
    preview.preview(at: 10) // Immediate cache hit must win over an older in-flight result.
    try await Task.sleep(for: .milliseconds(100))
    check(preview.seekPreviewTime == 10, "cache hit cannot be overwritten by stale result")
    let count = preview.decoded.count
    preview.preview(at: 10.5)
    check(preview.decoded.count == count, "same time bucket reuses image")
    preview.preview(at: 100)
    try await Task.sleep(for: .milliseconds(10))
    preview.clearPreview()
    try await Task.sleep(for: .milliseconds(100))
    check(preview.seekPreview == nil && !preview.seekPreviewLoading && preview.seekPreviewTime == nil, "cancel prevents late publication")
    check(preview.seekPreviewTask == nil && preview.previewPending == nil && !preview.userIsScrubbing, "cancel releases scheduling state")
    print("PASS: production preview coalescing, latest target, cache precedence and cancellation")
}
try await verify()
'''
with tempfile.TemporaryDirectory(prefix='lucent-preview-') as directory:
    path = Path(directory)/'main.swift'; path.write_text(fixture+'\n'+checks)
    subprocess.run(['swift', '-module-cache-path', '/tmp/lucent-swift-module-cache', str(path)], check=True)

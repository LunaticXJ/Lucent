import Foundation
import os

/// A seekable InputStream for VLCKit's callback-based media API.
final class RangeInputStream: InputStream, @unchecked Sendable {
    private static let diagnosticLog = Logger(subsystem: "com.lucent.app", category: "RangeInputStream")
    private let readRange: @Sendable (UInt64, Int) throws -> SMBScanner.RangeResult
    private let lock = NSLock()
    private var offset: UInt64 = 0
    private var totalSize: UInt64?
    private var cachedStart: UInt64 = 0
    private var cachedData = Data()
    private var status: Stream.Status = .notOpen
    private var failure: Error?

    init(readRange: @escaping @Sendable (UInt64, Int) throws -> SMBScanner.RangeResult) {
        self.readRange = readRange
        super.init(data: Data())
    }

    override func open() {
        lock.lock()
        if status == .notOpen { status = .open }
        lock.unlock()
    }

    override func close() {
        lock.lock()
        status = .closed
        lock.unlock()
    }

    override var streamStatus: Stream.Status {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    override var streamError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    override var hasBytesAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return status == .open && (totalSize.map { offset < $0 } ?? true)
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard status == .open, len > 0 else { return -1 }
        if let totalSize, offset >= totalSize { status = .atEnd; return 0 }
        do {
            let cachedEnd = cachedStart + UInt64(cachedData.count)
            if offset < cachedStart || offset >= cachedEnd {
                #if DEBUG
                Self.diagnosticLog.info("fetch offset=\(self.offset) requested=1048576")
                #endif
                let result = try readRange(offset, 1_048_576)
                #if DEBUG
                Self.diagnosticLog.info("fetched bytes=\(result.data.count) total=\(result.totalSize)")
                #endif
                totalSize = result.totalSize
                guard !result.data.isEmpty else { status = .atEnd; return 0 }
                cachedStart = offset
                cachedData = result.data
            }
            let index = Int(offset - cachedStart)
            let count = min(len, cachedData.count - index)
            cachedData.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                buffer.update(from: base.assumingMemoryBound(to: UInt8.self).advanced(by: index),
                              count: count)
            }
            offset += UInt64(count)
            return count
        } catch {
            #if DEBUG
            Self.diagnosticLog.error("read failed at offset=\(self.offset) type=\(String(describing: type(of: error)))")
            #endif
            failure = error
            status = .error
            return -1
        }
    }

    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
                            length len: UnsafeMutablePointer<Int>) -> Bool {
        false
    }

    override func property(forKey key: Stream.PropertyKey) -> Any? {
        guard key == .fileCurrentOffsetKey else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return NSNumber(value: offset)
    }

    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool {
        guard key == .fileCurrentOffsetKey,
              let number = property as? NSNumber else { return false }
        lock.lock()
        defer { lock.unlock() }
        offset = number.uint64Value
        #if DEBUG
        Self.diagnosticLog.info("seek offset=\(self.offset)")
        #endif
        if status == .atEnd || status == .error {
            status = .open
            failure = nil
        }
        return true
    }
}

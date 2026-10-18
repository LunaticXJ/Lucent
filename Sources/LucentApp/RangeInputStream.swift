import Foundation

/// A seekable InputStream for VLCKit's callback-based media API.
final class RangeInputStream: InputStream, @unchecked Sendable {
    private let readRange: @Sendable (UInt64, Int) throws -> SMBScanner.RangeResult
    private let lock = NSLock()
    private var offset: UInt64 = 0
    private var totalSize: UInt64?
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
            let result = try readRange(offset, min(len, 1_048_576))
            totalSize = result.totalSize
            guard !result.data.isEmpty else { status = .atEnd; return 0 }
            result.data.copyBytes(to: buffer, count: result.data.count)
            offset += UInt64(result.data.count)
            return result.data.count
        } catch {
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
        if status == .atEnd { status = .open }
        return true
    }
}

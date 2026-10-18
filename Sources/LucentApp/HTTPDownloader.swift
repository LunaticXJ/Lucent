import Foundation

final class HTTPDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var finished = false
    private var cancelled = false
    private var destination: URL?
    private var resumeURL: URL?
    private var progress: (@Sendable (Double) -> Void)?

    func download(_ request: URLRequest, to destination: URL, resumeURL: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.destination = destination
                self.resumeURL = resumeURL
                self.progress = progress
                self.continuation = continuation
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                self.session = session
                let task: URLSessionDownloadTask
                if let data = try? Data(contentsOf: resumeURL) {
                    task = session.downloadTask(withResumeData: data)
                } else {
                    task = session.downloadTask(with: request)
                }
                self.task = task
                let cancelled = self.cancelled
                lock.unlock()
                task.resume()
                if cancelled { task.cancel() }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func pause() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            let task = self.task
            let resumeURL = self.resumeURL
            lock.unlock()
            guard let task, let resumeURL else {
                continuation.resume(returning: false)
                return
            }
            task.cancel(byProducingResumeData: { data in
                guard let data else {
                    continuation.resume(returning: false)
                    return
                }
                do {
                    try data.write(to: resumeURL, options: .atomic)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            })
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode), let destination else {
            result = .failure(CocoaError(.fileReadUnknown))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            if let resumeURL { try? FileManager.default.removeItem(at: resumeURL) }
            result = .success(())
        } catch {
            result = .failure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let result = error.map { Result<Void, Error>.failure($0) } ?? self.result ?? .failure(CocoaError(.fileReadUnknown))
        lock.unlock()
        session.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}

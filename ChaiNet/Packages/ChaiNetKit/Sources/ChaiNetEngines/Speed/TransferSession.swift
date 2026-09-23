import Foundation

/// URLSession delegate that counts bytes as they move and **discards download data
/// immediately** — nothing is buffered or written to disk (no download tasks, no cache).
final class TransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let counter: ByteCounter
    private let completions = LockedValue<[Int: CheckedContinuation<Void, Error>]>([:])

    init(counter: ByteCounter) {
        self.counter = counter
    }

    func register(_ taskID: Int, _ continuation: CheckedContinuation<Void, Error>) {
        completions.withLock { $0[taskID] = continuation }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        counter.add(Int64(data.count))
        // `data` goes out of scope here — download payload lives only in memory, briefly.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        counter.add(bytesSent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let cont = completions.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }

    /// Fails every outstanding transfer (session invalidated).
    func failAll() {
        let all = completions.withLock { d -> [CheckedContinuation<Void, Error>] in
            let values = Array(d.values)
            d.removeAll()
            return values
        }
        for c in all { c.resume(throwing: CancellationError()) }
    }
}

/// One parallel stream = one URLSession (= its own TCP/QUIC connection; separate sessions
/// prevent HTTP/2 from multiplexing all "parallel" streams onto a single connection).
final class TransferStream: @unchecked Sendable {
    let session: URLSession
    let delegate: TransferDelegate

    init(counter: ByteCounter, timeout: Double) {
        delegate = TransferDelegate(counter: counter)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = timeout
        config.httpMaximumConnectionsPerHost = 1
        config.waitsForConnectivity = false
        config.httpShouldUsePipelining = false
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Runs one data or upload task to completion. Cancelling the Swift task cancels the transfer.
    func run(_ request: URLRequest, uploading body: Data?) async throws {
        let task: URLSessionTask = if let body { session.uploadTask(with: request, from: body) } else { session.dataTask(with: request) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                delegate.register(task.taskIdentifier, cont)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func invalidate() {
        session.invalidateAndCancel()
        delegate.failAll()
    }
}

/// Random, incompressible upload payload generated in memory.
enum UploadPayload {
    static func make(bytes: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var words = [UInt64](repeating: 0, count: (bytes + 7) / 8)
        for i in words.indices { words[i] = generator.next() }
        return words.withUnsafeBytes { Data($0.prefix(bytes)) }
    }
}

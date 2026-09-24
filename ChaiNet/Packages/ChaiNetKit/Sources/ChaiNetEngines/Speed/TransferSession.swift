import Foundation

/// Collects per-request outcomes of all streams of one transfer (for `TransferValidator`).
final class TransferCollector: @unchecked Sendable {
    private let state = LockedValue(TransferDiagnostics())
    let isDownload: Bool
    let expectedBytes: Int64

    init(isDownload: Bool, expectedBytes: Int64) {
        self.isDownload = isDownload
        self.expectedBytes = expectedBytes
        state.withLock { $0.expectedBytesPerRequest = expectedBytes }
    }

    func started() { state.withLock { $0.requestsStarted += 1 } }

    func finished(status: Int?, contentType: String?, bodyBytes: Int64, error: Error?) {
        // Transfers cancelled at the planned stop are not errors.
        if let error, Self.isCancellation(error) { return }
        state.withLock { d in
            if let status {
                d.responses += 1
                d.statusCounts[String(status), default: 0] += 1
            }
            if let t = contentType?.lowercased(), !d.contentTypes.contains(t), d.contentTypes.count < 5 { d.contentTypes.append(t) }
            if let error {
                d.errorCount += 1
                if (error as? URLError)?.code == .timedOut { d.timeoutCount += 1 }
                if d.errorSamples.count < 5 { d.errorSamples.append(error.localizedDescription) }
            } else if isDownload, let status, (200..<300).contains(status) {
                d.completedOK += 1
                d.smallestResponseBytes = min(d.smallestResponseBytes ?? bodyBytes, bodyBytes)
                if expectedBytes > 0 && bodyBytes < expectedBytes / 10 { d.tinyResponses += 1 }
            }
        }
    }

    func snapshot(perStreamBytes: [Int64]) -> TransferDiagnostics {
        var d = state.current
        d.perStreamBytes = perStreamBytes
        return d
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// URLSession delegate that counts bytes as they move and **discards download data
/// immediately** — nothing is buffered or written to disk (no download tasks, no cache).
/// It also records each response's status / content type / body size for validation.
final class TransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct TaskRecord { var status: Int?; var contentType: String?; var bytes: Int64 = 0 }

    let counter: ByteCounter
    /// Bytes of this stream only.
    let streamCounter = ByteCounter()
    let collector: TransferCollector?
    private let completions = LockedValue<[Int: CheckedContinuation<Void, Error>]>([:])
    private let records = LockedValue<[Int: TaskRecord]>([:])

    init(counter: ByteCounter, collector: TransferCollector? = nil) {
        self.counter = counter
        self.collector = collector
    }

    func register(_ taskID: Int, _ continuation: CheckedContinuation<Void, Error>) {
        completions.withLock { $0[taskID] = continuation }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        records.withLock { r in
            r[dataTask.taskIdentifier, default: TaskRecord()].status = http?.statusCode
            r[dataTask.taskIdentifier, default: TaskRecord()].contentType = http?.value(forHTTPHeaderField: "Content-Type")
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let n = Int64(data.count)
        counter.add(n)
        streamCounter.add(n)
        records.withLock { $0[dataTask.taskIdentifier, default: TaskRecord()].bytes += n }
        // `data` goes out of scope here — download payload lives only in memory, briefly.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        counter.add(bytesSent)
        streamCounter.add(bytesSent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var record = records.withLock { $0.removeValue(forKey: task.taskIdentifier) } ?? TaskRecord()
        // Fallback when the response callback wasn't delivered (e.g. upload tasks).
        if record.status == nil, let http = task.response as? HTTPURLResponse {
            record.status = http.statusCode
            record.contentType = http.value(forHTTPHeaderField: "Content-Type")
        }
        collector?.finished(status: record.status, contentType: record.contentType, bodyBytes: record.bytes, error: error)
        guard let cont = completions.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error { return cont.resume(throwing: error) }
        // An error page (429 / 403 / 5xx) completes "successfully" at the URLSession level — it is a failure here.
        if let status = record.status, !(200..<300).contains(status) {
            return cont.resume(throwing: EngineError.server("HTTP \(status)"))
        }
        cont.resume()
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

    init(counter: ByteCounter, timeout: Double, collector: TransferCollector? = nil) {
        delegate = TransferDelegate(counter: counter, collector: collector)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = timeout
        config.httpMaximumConnectionsPerHost = 1
        config.waitsForConnectivity = false
        config.httpShouldUsePipelining = false
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    var bytes: Int64 { delegate.streamCounter.total }

    /// Runs one data or upload task to completion. Cancelling the Swift task cancels the transfer.
    func run(_ request: URLRequest, uploading body: Data?) async throws {
        let task: URLSessionTask = if let body { session.uploadTask(with: request, from: body) } else { session.dataTask(with: request) }
        delegate.collector?.started()
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

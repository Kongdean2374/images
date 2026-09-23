import Foundation

/// A value protected by a lock. Used for state shared between URLSession / Network.framework
/// callbacks (which run on arbitrary queues) and async code.
public final class LockedValue<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value { withLock { $0 } }
}

/// One-shot flag: `trySet()` returns true exactly once. Guards continuations against double resume.
public final class OnceFlag: @unchecked Sendable {
    private let state = LockedValue(false)
    public init() {}
    public func trySet() -> Bool {
        state.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }
}

/// Thread-safe byte counter shared by all parallel transfer streams.
public final class ByteCounter: @unchecked Sendable {
    private let state = LockedValue<Int64>(0)
    public init() {}
    public func add(_ n: Int64) { state.withLock { $0 += n } }
    public var total: Int64 { state.current }
}

public extension Duration {
    /// Duration as fractional seconds.
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    var milliseconds: Double { seconds * 1000 }
}

/// Monotonic stopwatch (immune to wall-clock changes).
public struct Stopwatch: Sendable {
    private let start = ContinuousClock.now
    public init() {}
    public var elapsed: Double { (ContinuousClock.now - start).seconds }
    public var elapsedMs: Double { elapsed * 1000 }
}

public enum EngineError: Error, LocalizedError, Sendable, Equatable {
    case timeout
    case invalidResponse(String)
    case unsupported(String)
    case resolutionFailed(String)
    case socket(String)
    case server(String)
    case noNetwork

    public var errorDescription: String? {
        switch self {
        case .timeout: "逾時"
        case .invalidResponse(let s): "回應無效：\(s)"
        case .unsupported(let s): "不支援：\(s)"
        case .resolutionFailed(let s): "無法解析主機：\(s)"
        case .socket(let s): "Socket 錯誤：\(s)"
        case .server(let s): "伺服器錯誤：\(s)"
        case .noNetwork: "目前沒有網路連線"
        }
    }
}

/// Runs `operation`, throwing `EngineError.timeout` if it does not finish in time.
/// The operation is cancelled when the timeout wins.
public func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw EngineError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw EngineError.timeout }
        return first
    }
}

/// Sleeps until `offset` seconds after `stopwatch` started (no-op if already past).
func sleepUntil(_ offset: Double, since stopwatch: Stopwatch) async throws {
    let remaining = offset - stopwatch.elapsed
    if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
}

/// Wraps an async producer into a cancellable `AsyncThrowingStream`: terminating the stream
/// (consumer cancelled or stopped iterating) cancels the producing task.
public func makeCancellableStream<Element: Sendable>(
    _ body: @escaping @Sendable (AsyncThrowingStream<Element, Error>.Continuation) async throws -> Void
) -> AsyncThrowingStream<Element, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                try await body(continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

import Foundation

/// A cancellation signal independent of actor scheduling, including during synchronous inserts.
final class ImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: () -> Void] = [:]
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let callbacks = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }
    func register(_ id: UUID, handler: @escaping () -> Void) {
        lock.lock()
        let runNow = cancelled
        if !runNow { handlers[id] = handler }
        lock.unlock()
        if runNow { handler() }
    }
    func remove(_ id: UUID) {
        lock.lock(); handlers.removeValue(forKey: id); lock.unlock()
    }
}

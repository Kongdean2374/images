import Foundation

enum BackgroundFactory {
    /// Construct queue-bound objects on an actual background thread. A detached
    /// Swift task can still inherit isolation through its closure's inferred type.
    static func make<Value: Sendable>(_ create: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: create())
            }
        }
    }
}

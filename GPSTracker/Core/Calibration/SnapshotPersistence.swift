import Foundation

enum SnapshotRead<Payload: Sendable>: Sendable {
    case missing
    case loaded(Payload)
    case unreadable
}

/// Writes, clears and reads share one serial queue, so an older queued write
/// cannot resurrect a snapshot after a successful save/explicit discard.
final class SnapshotPersistence<Payload: Codable & Sendable>: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.gpstracker.snapshot.persistence", qos: .utility)
    init(url: URL) { self.url = url }
    func save(_ snapshot: Payload) {
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: self.url, options: .atomic)
        }
    }
    func clear() {
        queue.async { try? FileManager.default.removeItem(at: self.url) }
    }
    func load() async -> SnapshotRead<Payload> {
        await withCheckedContinuation { continuation in
            queue.async {
                guard FileManager.default.fileExists(atPath: self.url.path) else {
                    continuation.resume(returning: .missing); return
                }
                do {
                    let data = try Data(contentsOf: self.url)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    continuation.resume(returning: .loaded(try decoder.decode(Payload.self, from: data)))
                } catch {
                    // Preserve unreadable and old files; never delete evidence during startup.
                    continuation.resume(returning: .unreadable)
                }
            }
        }
    }
}

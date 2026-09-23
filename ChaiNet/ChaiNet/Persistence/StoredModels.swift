import Foundation
import SwiftData
import ChaiNetCore

/// A persisted test result. Summary columns power list / chart queries; the full `TestResult`
/// (with every raw sample) is kept as JSON in `payload`. Everything stays on the device.
@Model
final class StoredResult {
    @Attribute(.unique) var id: UUID
    var date: Date
    var kindRaw: String
    var networkRaw: String
    var serverName: String?
    var downloadMbps: Double?
    var uploadMbps: Double?
    var pingMs: Double?
    var jitterMs: Double?
    var lossPercent: Double?
    var overallScore: Int?
    var latitude: Double?
    var longitude: Double?
    @Attribute(.externalStorage) var payload: Data

    init(result: TestResult, payload: Data) {
        let m = result.metrics
        id = result.id
        date = result.date
        kindRaw = result.kind.rawValue
        networkRaw = NetworkClass(snapshot: result.network).rawValue
        serverName = result.server?.name
        downloadMbps = m.downloadMbps
        uploadMbps = m.uploadMbps
        pingMs = m.idleLatencyMs
        jitterMs = m.jitterMs
        lossPercent = m.lossPercent
        overallScore = result.scores.overall
        latitude = result.location?.latitude
        longitude = result.location?.longitude
        self.payload = payload
    }

    var kind: TestKind { TestKind(rawValue: kindRaw) ?? .fullSpeedTest }
    var networkClass: NetworkClass { NetworkClass(rawValue: networkRaw) ?? .unknown }
}

/// A persisted diagnostic session (JSON of `DiagnosticSession`).
@Model
final class StoredSession {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var testCount: Int
    var topCause: String?
    var topConfidence: Int?
    @Attribute(.externalStorage) var payload: Data

    init(id: UUID, title: String, createdAt: Date, payload: Data) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.testCount = 0
        self.payload = payload
    }
}

enum Codec {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

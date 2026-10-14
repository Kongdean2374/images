import XCTest
import Foundation
@testable import CalibrationCore

final class ResponsivenessTests: XCTestCase {
    struct Fixture: Codable, Sendable { var values: [Int]; var saved: Date; var sessionID: UUID? = nil }
    func store() throws -> (SnapshotPersistence<Fixture>, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("recovery.json")
        return (SnapshotPersistence(url: url), url)
    }
    func testQueuedSaveThenClearCannotResurrectRecovery() async throws {
        let (store, url) = try store()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        store.save(Fixture(values: Array(0..<100_000), saved: Date()))
        store.clear()
        let result = await store.load()
        guard case .missing = result else { return XCTFail("Queued writes resurrected a cleared snapshot") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testLargeOldSnapshotLoadsCompletelyWithoutAutomaticDeletion() async throws {
        let (store, url) = try store()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let old = Fixture(values: Array(0..<100_000), saved: Date(timeIntervalSince1970: 0))
        store.save(old)
        guard case .loaded(let loaded) = await store.load() else { return XCTFail("Valid old recovery lost") }
        XCTAssertEqual(loaded.values, old.values); XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(loaded.sessionID)
    }
    func testUnreadableSnapshotRemainsRecoverableOnDisk() async throws {
        let (store, url) = try store()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let raw = Data("partial-unreadable-original".utf8)
        try raw.write(to: url)
        guard case .unreadable = await store.load() else { return XCTFail("Expected read failure") }
        XCTAssertEqual(try Data(contentsOf: url), raw)
    }
    func testLargePersistenceDoesNotBlockMainActorHeartbeat() async throws {
        let (store, url) = try store()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        store.save(Fixture(values: Array(0..<500_000), saved: Date()))
        let read = Task { await store.load() }
        let heartbeat = Task { @MainActor in 42 }
        let heartbeatResult = await heartbeat.value
        XCTAssertEqual(heartbeatResult, 42)
        guard case .loaded(let value) = await read.value else { return XCTFail("Load failed") }
        XCTAssertEqual(value.values.count, 500_000)
    }
    func testPerformanceWindowHandles100000PointsInLinearPass() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0..<100_000).map { PerformancePoint(timestamp: start.addingTimeInterval(Double($0)), distance: Double($0) * 3) }
        let duration = try PerformanceWindow.fastest(points: points, distance: 3000)
        XCTAssertEqual(duration, 1000)
    }
    func testWindowDoesNotBridgeDistanceResetOrInvalidTimes() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = [PerformancePoint(timestamp: start, distance: 0),
                      PerformancePoint(timestamp: start.addingTimeInterval(20), distance: 300),
                      PerformancePoint(timestamp: start.addingTimeInterval(21), distance: 0),
                      PerformancePoint(timestamp: start.addingTimeInterval(22), distance: 300)]
        XCTAssertNil(try PerformanceWindow.fastest(points: points, distance: 400))
    }
    func testCancellationStopsLongWindowWork() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0..<100_000).map { PerformancePoint(timestamp: start.addingTimeInterval(Double($0)), distance: Double($0)) }
        let task = Task {
            try Task.checkCancellation()
            return try PerformanceWindow.fastest(points: points, distance: 1000)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled computation applied a result") }
        catch is CancellationError { }
    }
    func testLegacyRecoveryIdentityIsStableAndDistinct() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(RecoveryIdentity.id(start: start, type: "gpsRun"), RecoveryIdentity.id(start: start, type: "gpsRun"))
        XCTAssertNotEqual(RecoveryIdentity.id(start: start, type: "gpsRun"), RecoveryIdentity.id(start: start, type: "gpsHike"))
        XCTAssertNotEqual(RecoveryIdentity.id(start: start, type: "gpsRun"), RecoveryIdentity.id(start: start.addingTimeInterval(1), type: "gpsRun"))
    }
}

import XCTest
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import CalibrationCore

final class CalibrationCoreTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    func evidence(_ method: MeasurementMethod = .independentGPS) -> MeasurementEvidence {
        var e = MeasurementEvidence(); e.method = method; e.distanceConfirmed = true; e.stepsAligned = true
        return e
    }
    func decision(_ e: MeasurementEvidence, gps: GPSQuality? = GPSQuality(coverage: 1, measuredDistance: 720), profile: String = "walking") -> CalibrationDecision {
        CalibrationEligibility.evaluate(evidence: e, distance: 720, steps: 1000, duration: 600, profile: profile, supported: true, gps: gps)
    }
    func testEstimateRoundTripCannotTrain() throws {
        for method in [MeasurementMethod.strideEstimate, .systemEstimate, .mixed, .unknown] {
            var e = evidence(method); e.generatedByThisApp = true
            let restored = try JSONDecoder().decode(MeasurementEvidence.self, from: JSONEncoder().encode(e))
            XCTAssertFalse(decision(restored).eligible)
        }
    }
    func testGPSRouteDoesNotElevateEstimate() { XCTAssertFalse(decision(evidence(.strideEstimate)).eligible) }
    func testMixedGPSCannotTrainTotal() {
        var e = evidence(); e.stepAssistedDistance = 100
        XCTAssertTrue(decision(e).reasons.contains(.assistedDistance)); XCTAssertFalse(decision(e).eligible)
    }
    func testMissingSourceAndAlignmentAreConservative() {
        var e = evidence(); e.distanceConfirmed = false; e.stepsAligned = false; e.stepSource = "mixed"
        let d = decision(e)
        XCTAssertFalse(d.eligible); XCTAssertTrue(d.reasons.contains(.unknownSource)); XCTAssertTrue(d.reasons.contains(.mixedStepSources))
    }
    func testReliableIndependentMeasurementTrains() { XCTAssertTrue(decision(evidence()).eligible) }
    func testKnownDistanceRequiresConfirmation() {
        var e = evidence(.knownDistance); XCTAssertTrue(decision(e, gps: nil).eligible)
        e.distanceConfirmed = false; XCTAssertFalse(decision(e, gps: nil).eligible)
    }
    func testUserExclusionCannotBeBypassed() {
        let d = CalibrationEligibility.evaluate(evidence: evidence(), distance: 720, steps: 1000, duration: 600, profile: "walking", supported: true, gps: GPSQuality(coverage: 1, measuredDistance: 720), userExcluded: true)
        XCTAssertFalse(d.eligible); XCTAssertEqual(d.grade, .d)
    }
    func testGPSAnomaliesAndOriginalPointsRetained() {
        let points = [GPSObservation(latitude: 25, longitude: 121, date: start, accuracy: 5),
                      GPSObservation(latitude: 26, longitude: 122, date: start.addingTimeInterval(1), accuracy: 5),
                      GPSObservation(latitude: 25, longitude: 121, date: start, accuracy: nil)]
        let result = GPSQualityAnalyzer.analyze(points, start: start, end: start.addingTimeInterval(600))
        XCTAssertTrue(result.reasons.contains(.gpsJump)); XCTAssertTrue(result.reasons.contains(.timeReversed)); XCTAssertTrue(result.reasons.contains(.gpsAccuracy)); XCTAssertEqual(points.count, 3)
    }
    func testFullRouteBeyond6000Points() {
        let points = (0..<7001).map { GPSObservation(latitude: 25 + Double($0) * 0.00001, longitude: 121, date: start.addingTimeInterval(Double($0)), accuracy: 5) }
        let quality = GPSQualityAnalyzer.analyze(points, start: start, end: points.last!.date)
        XCTAssertTrue(quality.isReliable); XCTAssertEqual(points.count, 7001); XCTAssertGreaterThan(quality.measuredDistance, 7000)
    }
    func identity(_ id: String, offset: Double = 0, duration: Double = 600, distance: Double = 720) -> WorkoutIdentity {
        WorkoutIdentity(id: id, activity: "walking", start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + duration), distance: distance)
    }
    func testStableIdentityAndCrossDeviceDeduplication() {
        XCTAssertTrue(identity("one").matches(identity("one", offset: 100)))
        XCTAssertTrue(identity("one").matches(identity("two", offset: 2)))
        XCTAssertFalse(identity("one").matches(identity("two", offset: 600)))
        XCTAssertFalse(identity("one").matches(identity("two", offset: 2, duration: 120)))
    }
    func testOriginRelationshipSurvivesLocalDeletion() {
        var imported = identity("hk"); imported.originID = "local"
        XCTAssertTrue(imported.matches(identity("local", offset: 30)))
    }
    func testSparseCandidateDoesNotReplaceOldModel() {
        let outcome = CalibrationValidator.validate(samples: [ValidationSample(workoutID: "one", date: start, distance: 1600, steps: 1000)], baseline: 0.72)
        XCTAssertFalse(outcome.applied); XCTAssertNil(outcome.candidateError)
    }
    func fixtures() -> [ValidationSample] {
        (0..<9).map { ValidationSample(workoutID: "\($0)", date: start.addingTimeInterval(Double($0) * 86400), distance: 800, steps: 1000) }
    }
    func testTemporalHoldoutImprovesAndNonImprovementRetains() {
        let a = CalibrationValidator.validate(samples: fixtures(), baseline: 0.72)
        XCTAssertTrue(a.applied); XCTAssertEqual(a.testCount, 3); XCTAssertEqual(a.candidateError, 0)
        XCTAssertFalse(CalibrationValidator.validate(samples: fixtures(), baseline: 0.8).applied)
    }
    func testDuplicateSamplesDoNotCreateFalseValidationSet() {
        let single = fixtures()[0]
        XCTAssertFalse(CalibrationValidator.validate(samples: Array(repeating: single, count: 20), baseline: 0.72).applied)
    }
    func testNoTemporalSeparationRejects() {
        let records = fixtures().map { ValidationSample(workoutID: $0.workoutID, date: start, distance: $0.distance, steps: $0.steps) }
        XCTAssertFalse(CalibrationValidator.validate(samples: records, baseline: 0.72).applied)
    }
    func testWindowIntegrationAndFallbackNeverRecalculateHistory() {
        var a = StepDistanceAccumulator()
        _ = a.ingest(rawSteps: 100, systemDistance: nil, cadence: 100, date: start, stride: 0.72, calibrated: true)
        _ = a.ingest(rawSteps: 200, systemDistance: nil, cadence: 170, date: start.addingTimeInterval(60), stride: 1.05, calibrated: true)
        _ = a.ingest(rawSteps: 300, systemDistance: nil, cadence: nil, date: start.addingTimeInterval(120), stride: 0.72, calibrated: true)
        XCTAssertEqual(a.steps, 300); XCTAssertEqual(a.distance, 249, accuracy: 0.001)
    }
    func testPauseRestartDuplicateAndRollback() {
        var a = StepDistanceAccumulator()
        _ = a.ingest(rawSteps: 100, systemDistance: nil, cadence: nil, date: start, stride: 0.72, calibrated: false)
        XCTAssertNil(a.ingest(rawSteps: 50, systemDistance: nil, cadence: nil, date: start.addingTimeInterval(1), stride: 0.72, calibrated: false))
        a.rebase()
        _ = a.ingest(rawSteps: 10, systemDistance: nil, cadence: nil, date: start.addingTimeInterval(60), stride: 0.72, calibrated: false)
        XCTAssertNil(a.ingest(rawSteps: 10, systemDistance: nil, cadence: nil, date: start.addingTimeInterval(60), stride: 0.72, calibrated: false))
        XCTAssertEqual(a.steps, 110); XCTAssertEqual(a.distance, 79.2, accuracy: 0.001)
    }
    func testStationaryAndCarStepsSuppressed() {
        var a = StepDistanceAccumulator()
        _ = a.ingest(rawSteps: 10, systemDistance: 100, cadence: nil, date: start, stride: 0.72, calibrated: false, suppress: true)
        XCTAssertEqual(a.steps, 0); XCTAssertEqual(a.distance, 0)
        _ = a.ingest(rawSteps: 20, systemDistance: 108, cadence: nil, date: start.addingTimeInterval(60), stride: 0.72, calibrated: false)
        XCTAssertEqual(a.distance, 8, accuracy: 0.001)
    }
    func testUnknownLoadAndCarrySurviveBackup() throws {
        let restored = try JSONDecoder().decode(MeasurementEvidence.self, from: JSONEncoder().encode(evidence()))
        XCTAssertNil(restored.loadWeight); XCTAssertEqual(restored.carryPosition, .unknown)
    }
    func testPauseIntervalsIncludeUnfinishedPause() {
        let pauses = WorkoutTime.pauses(start: start, end: start.addingTimeInterval(100), log: [start.addingTimeInterval(20), start.addingTimeInterval(30), start.addingTimeInterval(80)])
        XCTAssertEqual(pauses.reduce(0) { $0 + $1.duration }, 30)
    }
    func testCSVSpecialCharactersAndEmptyUnknownFields() {
        XCTAssertEqual(ExportEncoding.csv([["備註", "未知負重"], ["a,\"b\"\n&<", ""]]), "備註,未知負重\r\n\"a,\"\"b\"\"\n&<\",\r\n")
        XCTAssertEqual(ExportEncoding.number(nil), ""); XCTAssertEqual(ExportEncoding.number(.nan), "")
    }
    func testTCXWithoutGPSIsValidAndHasNoInventedCoordinates() {
        let record = TCXRecord(start: start, end: start.addingTimeInterval(600), duration: 500, distance: 720, calories: nil, running: false, notes: "a,&<\"\n", points: [])
        let xml = TCXEncoder.encode(record)
        XCTAssertTrue(XMLParser(data: Data(xml.utf8)).parse()); XCTAssertFalse(xml.contains("<Position>"))
        XCTAssertTrue(xml.contains("720.00")); XCTAssertTrue(xml.contains("熱量未知")); XCTAssertTrue(xml.contains("&amp;"))
    }
    func testTCXWithFullRawRoute() {
        let points = (0..<7001).map { TCXRecord.Point(time: start.addingTimeInterval(Double($0)), latitude: 25, longitude: 121, altitude: 10, distance: Double($0)) }
        let xml = TCXEncoder.encode(TCXRecord(start: start, end: start.addingTimeInterval(7000), duration: 7000, distance: 7000, calories: 100, running: true, notes: "GPS", points: points))
        XCTAssertTrue(XMLParser(data: Data(xml.utf8)).parse()); XCTAssertEqual(xml.components(separatedBy: "<Trackpoint>").count - 1, 7001)
    }
}

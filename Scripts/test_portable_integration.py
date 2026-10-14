#!/usr/bin/env python3
"""Execute production Foundation model/export/backup logic on Linux.
Only SwiftData annotations and iOS presentation dependencies are replaced. This
is not a substitute for an Xcode build, SwiftData migration, or device tests.
"""
from pathlib import Path
import os, re, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
swiftc = os.environ.get('SWIFTC', 'swiftc')

def source(name): return (ROOT / 'GPSTracker' / name).read_text()
models = source('Models/WorkoutModels.swift').replace('import SwiftData', '')
models = re.sub(r'@Model\s*', '', models)
models = re.sub(r'@Attribute\([^\n]+\)\s*', '', models)
models = re.sub(r'@Relationship\([^\n]+\)\s*', '', models)
exports = source('Core/DataExporter.swift')
exports = exports[:exports.index('    // MARK: PDF')] + exports[exports.index('    private static let errorLock'):]
exports = exports.replace('import SwiftUI', '').replace('import UIKit', '')
backup = source('Core/BackupManager.swift').split('// MARK: - 備份與還原')[0].replace('import SwiftData', '')
coordinator = source('Core/Calibration/CalibrationCoordinator.swift')
reports = coordinator[coordinator.index('struct CalibrationReport:'):coordinator.index('@ModelActor')]
stubs = '''
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
struct SportKind { var id: String; var name: String; var icon: String; var met: Double }
enum HealthActivity { case walking, running, hiking, cycling, handCycling, downhillSkiing, crossCountrySkiing, snowboarding, rowing, paddleSports, sailing, skatingSports, other }
enum SportCatalog {
 static func find(_ id: String?) -> SportKind? { nil }
 static func healthKitType(for sport: SportKind) -> HealthActivity { .other }
}
struct ExerciseItem: Codable {}
struct IntervalPlan: Codable {}
struct FitnessStandards: Codable {}
'''
harness = '''
@main struct IntegrationCheck {
 @MainActor static func main() throws {
  let start = Date(timeIntervalSince1970: 1700000000)
  let session = WorkoutSession(type: .ruck, startDate: start, endDate: start.addingTimeInterval(600), duration: 500, totalDistance: 720, stepCount: 1000, distanceSource: .stride, notes: "a,\\\"b\\\"\\n&<")
  var e = MeasurementEvidence(); e.method = .strideEstimate; e.generatedByThisApp = true; e.stepsAligned = true
  session.evidence = e
  precondition(session.type.strideProfile == .ruck)
  precondition(!CalibrationSessionAnalyzer.evaluate(session).eligible)
  let csv = DataExporter.sessionCSVText(session)
  precondition(csv.contains("720.00") && csv.contains("summary") && csv.contains("步幅估算"))
  let noGPS = RouteFileExporter.tcx(for: session)
  precondition(XMLParser(data: Data(noGPS.utf8)).parse() && !noGPS.contains("<Position>"))
  session.routePoints = (0..<7001).map { RoutePoint(latitude: 25 + Double($0) * 0.00001, longitude: 121, altitude: 10, timestamp: start.addingTimeInterval(Double($0)), speed: 1, distanceFromStart: Double($0), horizontalAccuracy: 5) }
  precondition(DataExporter.sessionCSVText(session).components(separatedBy: "GPS原始點").count - 1 == 7001)
  let tcx = RouteFileExporter.tcx(for: session)
  precondition(XMLParser(data: Data(tcx.utf8)).parse() && tcx.components(separatedBy: "<Trackpoint>").count - 1 == 7001)
  precondition(RouteFileExporter.gpx(for: session)!.components(separatedBy: "<trkpt ").count - 1 == 7001)
  let first = DataExporter.routeCSV(session: session)!, second = DataExporter.routeCSV(session: session)!
  precondition(first != second && FileManager.default.fileExists(atPath: first.path))
  precondition(DataExporter.write(nil, filename: "empty.csv") == nil && DataExporter.lastWriteError != nil)
  let oldState = #"{"stride":0.72,"confidence":0.8,"sampleCount":108,"weightedCount":50,"spanDays":300,"updated":0,"method":"auto"}"#
  let restored = try JSONDecoder().decode(StrideState.self, from: Data(oldState.utf8))
  precondition(restored.sampleCount == 108 && restored.validation == nil && restored.modelVersion == nil)
  let oldSession = #"{"id":"01234567-89AB-CDEF-0123-456789ABCDEF","type":"walk","startDate":0,"endDate":600,"duration":600,"healthKitSynced":false,"isImported":false,"routePoints":[],"laps":[]}"#
  let decoded = try JSONDecoder().decode(SessionBackup.self, from: Data(oldSession.utf8))
  precondition(decoded.provenanceJSON == nil && decoded.trainingExcluded == nil && decoded.loadWeight == nil)
  precondition(!MeasurementEvidence.decode(decoded.provenanceJSON).distanceConfirmed)
  let newJSON = try JSONEncoder().encode(decoded)
  let newDecoded = try JSONDecoder().decode(SessionBackup.self, from: newJSON)
  precondition(newDecoded.id == decoded.id)
  let original = UserDefaults.standard.data(forKey: "strideState.walking")
  let previous = UserDefaults.standard.data(forKey: "strideState.walking.previous")
  defer { UserDefaults.standard.set(original, forKey: "strideState.walking"); UserDefaults.standard.set(previous, forKey: "strideState.walking.previous") }
  StrideCalibration.restore(restored, profile: .walking)
  StrideCalibration.setManual(0.8, profile: .walking)
  StrideCalibration.rollback(.walking)
  precondition(StrideCalibration.sampleCount(.walking) == 108 && StrideCalibration.stride(.walking) == 0.72)
  var report = CalibrationReport(); report.scanned = 4; report.gradeCounts = ["A":1,"B":1,"C":1,"D":1]
  report.eligible = 1; report.pending = 1; report.excluded = 1; report.insufficient = 1
  precondition(report.gradeCounts.values.reduce(0,+) == report.scanned)
  precondition(report.eligible + report.pending + report.excluded + report.insufficient == report.scanned)
  let reports = try JSONDecoder().decode([CalibrationReport].self, from: JSONEncoder().encode([report]))
  precondition(reports[0].scanned == 4)
  try DataExporter.sessionCSVText(session).write(toFile: CommandLine.arguments[1] + "/workout.csv", atomically: true, encoding: .utf8)
  try tcx.write(toFile: CommandLine.arguments[1] + "/workout.tcx", atomically: true, encoding: .utf8)
  print("Portable production integration checks passed (exports, 7001 points, legacy backup, 108-sample snapshot, rollback, report counts).")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='gpstracker-integration-') as directory:
    target = Path(directory)
    (target / 'Fixture.swift').write_text(stubs + models + backup + reports + exports + source('Core/RouteFileExporter.swift') + source('Core/StrideCalibration.swift') + source('Core/CoverageGap.swift') + harness)
    core = [ROOT / 'GPSTracker/Core/Calibration' / name for name in ('MeasurementPolicy.swift','StrideValidation.swift','WorkoutTime.swift','ExportEncoding.swift')]
    subprocess.run([swiftc, '-module-cache-path', str(target / 'modules'), '-o', str(target / 'check'), str(target / 'Fixture.swift'), *map(str,core)], check=True)
    subprocess.run([str(target / 'check'), directory], check=True)
    import csv, xml.etree.ElementTree as ET
    with (target / 'workout.csv').open(newline='') as handle: rows = list(csv.reader(handle))
    assert len(rows) == 7003 and all(len(row) == len(rows[0]) for row in rows)
    assert rows[1][21] == '' and rows[1][29] == 'summary'
    ET.parse(target / 'workout.tcx')
    print(f'Independent Python CSV/XML validation passed: {len(rows)-1} data rows, {len(rows[0])} uniform columns; unknown load is empty.')

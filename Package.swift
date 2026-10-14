// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "GPSTrackerCalibrationCore", products: [.library(name: "CalibrationCore", targets: ["CalibrationCore"])],
    targets: [.target(name: "CalibrationCore", path: "GPSTracker/Core/Calibration",
                      exclude: ["CalibrationCoordinator.swift"],
                      sources: ["MeasurementPolicy.swift", "StrideValidation.swift", "WorkoutTime.swift", "ExportEncoding.swift"]),
              .testTarget(name: "CalibrationCoreTests", dependencies: ["CalibrationCore"], path: "Tests/CalibrationCoreTests")])

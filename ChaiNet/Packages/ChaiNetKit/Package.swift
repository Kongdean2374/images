// swift-tools-version: 6.0
import PackageDescription

/// ChaiNetKit holds everything that is *not* UI:
/// - `ChaiNetCore`: pure, platform-independent models and math (statistics, scoring,
///   diagnostics, codecs, export). No networking, fully deterministic, heavily unit-tested.
/// - `ChaiNetEngines`: the measurement engines (URLSession / Network.framework / BSD sockets).
///   Every engine is exposed through a protocol so the app and tests can inject mocks.
let package = Package(
    name: "ChaiNetKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ChaiNetCore", targets: ["ChaiNetCore"]),
        .library(name: "ChaiNetEngines", targets: ["ChaiNetEngines"]),
    ],
    targets: [
        .target(name: "ChaiNetCore"),
        .target(name: "ChaiNetEngines", dependencies: ["ChaiNetCore"]),
        .testTarget(name: "ChaiNetCoreTests", dependencies: ["ChaiNetCore"]),
        .testTarget(name: "ChaiNetEnginesTests", dependencies: ["ChaiNetEngines", "ChaiNetCore"]),
    ],
    swiftLanguageModes: [.v6]
)

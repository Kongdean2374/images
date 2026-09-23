import Foundation
import Observation
import ChaiNetCore
import ChaiNetEngines

/// A diagnostic session: several tests (networks, IP families, servers) analysed together by
/// the Root Cause engine. Re-analysed after every added test and persisted locally.
@MainActor
@Observable
final class DiagnosticSessionViewModel {
    private(set) var session: DiagnosticSession
    private(set) var analysis: RootCauseAnalysis?
    let run: RunViewModel
    private let app: AppContainer

    init(session: DiagnosticSession, app: AppContainer) {
        self.session = session
        self.app = app
        self.run = app.makeRunViewModel()
        self.run.featureID = "diagnostics"
        reanalyze()
    }

    var isRunning: Bool { run.isRunning }

    /// Runs a test and adds it to the session.
    func addTest(items: Set<TestItem>, ipPreference: IPFamilyPreference? = nil, labelSuffix: String? = nil) {
        let label = session.nextLabel
        run.start(kind: .fullSpeedTest, items: items, onCellular: app.onCellular, adjust: { config in
            if let ipPreference { config.settings.ipPreference = ipPreference }
            config.settings.autoCrossValidation = true
        }, completion: { [weak self] result in
            self?.append(result, label: label, suffix: labelSuffix)
        })
    }

    /// Adds an already finished result from history (e.g. yesterday's 5G test).
    func append(_ result: TestResult, label: String? = nil, suffix: String? = nil) {
        let base = label ?? session.nextLabel
        let network = NetworkClass(snapshot: result.network).displayName
        let text = [base + "：" + network, suffix].compactMap { $0 }.joined(separator: " · ")
        session.tests.append(SessionTest(label: text, result: result))
        reanalyze()
        persist()
    }

    func removeTest(id: UUID) {
        session.tests.removeAll { $0.id == id }
        reanalyze()
        persist()
    }

    func rename(_ title: String) {
        session.title = title
        persist()
    }

    func stop() { run.stop() }

    func reanalyze() {
        guard !session.tests.isEmpty else { analysis = nil; return }
        let baselines = app.baselines(excluding: Set(session.tests.map(\.id)))
        analysis = app.analyzer.analyze(session: session, baselines: baselines)
    }

    func persist() {
        try? app.history.saveSession(session, analysis: analysis)
    }

    func makeReport() -> DiagnosticReport? {
        guard let analysis else { return nil }
        let platform = "iOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)"
        return app.reportGenerator.makeReport(session: session, analysis: analysis, appVersion: ExportService.appVersion,
                                              platform: platform, includeLocation: app.settings.settings.includeLocationInExports)
    }

    /// Items to run for an automatable recommended test (nil = manual step, e.g. switching LTE/5G).
    static func items(for test: RecommendedTest) -> Set<TestItem>? {
        switch test {
        case .testAlternateServers: [.ping, .packetLoss, .crossValidation]
        case .compareIPFamilies: [.ipFamilies]
        case .runTraceroute: [.traceroute]
        case .runMTUTest: [.mtu]
        case .runDNSBenchmark: [.dns]
        case .runContinuousMonitor: [.dropMonitor, .packetLoss]
        case .runBufferbloatTest: [.ping, .bufferbloat]
        case .runProtocolProbe: [.http, .tls, .quic]
        case .repeatAtDifferentTime, .repeatOnLTE, .repeatOn5G, .repeatOnWiFi, .repeatOnCellular, .disableVPNAndRepeat,
             .disableLowDataMode, .moveCloserToRouter, .pauseOtherDevices, .restartDeviceNetwork:
            TestProfile.cellular.items.union([.ping, .crossValidation])
        case .contactProvider: nil
        }
    }

    /// Whether the test requires the user to change something first.
    static func isManual(_ test: RecommendedTest) -> Bool {
        switch test {
        case .repeatAtDifferentTime, .repeatOnLTE, .repeatOn5G, .repeatOnWiFi, .repeatOnCellular, .disableVPNAndRepeat,
             .disableLowDataMode, .moveCloserToRouter, .pauseOtherDevices, .restartDeviceNetwork, .contactProvider:
            true
        default:
            false
        }
    }
}

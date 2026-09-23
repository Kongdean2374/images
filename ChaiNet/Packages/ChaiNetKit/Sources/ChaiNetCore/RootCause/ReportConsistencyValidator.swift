import Foundation

/// Cross-checks a report so its sections can never contradict each other. Used by the report
/// itself (section 14) and by unit tests.
public enum ReportConsistencyValidator {

    public static func validate(_ report: DiagnosticReport) -> [String] {
        var issues: [String] = []
        let analysis = report.analysis
        let evidenceIDs = Set(analysis.evidence.evidence.map(\.id))

        // Summary ↔ hypotheses
        if let top = analysis.mostLikely {
            if !(top.likelihood == .likely || top.likelihood == .possible) {
                issues.append("most likely cause \(top.cause.rawValue) has status \(top.likelihood.rawValue)")
            }
            if !report.summary.contains(top.title) { issues.append("summary does not name the most likely cause") }
        }
        for h in analysis.hypotheses {
            switch h.likelihood {
            case .ruledOut:
                if h.rulingOutEvidence.isEmpty { issues.append("\(h.cause.rawValue) ruled out without decisive evidence") }
                for e in h.rulingOutEvidence {
                    if e.kind == .notTested || e.kind == .heuristic {
                        issues.append("\(h.cause.rawValue) ruled out by \(e.kind.rawValue) evidence \(e.code.rawValue)")
                    }
                    if !evidenceIDs.contains(e.id) { issues.append("\(h.cause.rawValue) cites evidence missing from the evidence list") }
                }
            case .likely, .possible:
                if h.supportingEvidence.isEmpty { issues.append("\(h.cause.rawValue) is \(h.likelihood.rawValue) without supporting evidence") }
            default:
                break
            }
            for e in h.supportingEvidence + h.contradictingEvidence where !evidenceIDs.contains(e.id) {
                issues.append("\(h.cause.rawValue) cites evidence missing from the evidence list: \(e.code.rawValue)")
            }
        }
        // Conclusion "ruled out" list must only name ruled-out hypotheses.
        let ruledTitles = Set(analysis.ruledOut.map(\.title))
        for h in analysis.hypotheses where h.likelihood != .ruledOut && ruledTitles.contains(h.title) {
            issues.append("\(h.cause.rawValue) listed as ruled out but has status \(h.likelihood.rawValue)")
        }
        if let line = analysis.conclusion.split(separator: "\n").first(where: { $0.hasPrefix("已排除") }) {
            for h in analysis.hypotheses where h.likelihood != .ruledOut && line.contains(h.title) {
                issues.append("conclusion lists \(h.cause.rawValue) as ruled out but its status is \(h.likelihood.rawValue)")
            }
        }

        // Statistics ↔ raw measurements: every reported speed statistic must be reproducible
        // from the raw samples with the documented method.
        for test in report.rawTests {
            let r = test.result
            for speed in [r.download, r.upload].compactMap({ $0 }) {
                let s = speed.summary
                let recomputed = SpeedCalculator.summarize(samples: speed.samples, streamChanges: speed.streamChanges,
                                                           warmupDuration: s.warmupDuration ?? 1.0,
                                                           windowSamples: s.windowSamples ?? SpeedCalculator.defaultWindowSamples)
                if let windows = s.analysisWindowMbps, !windows.isEmpty {
                    if let m = Percentile.value(0.5, in: windows), abs(m - s.medianMbps) > 1e-6 {
                        issues.append("\(test.label) \(speed.direction.rawValue): median does not match its statistics windows")
                    }
                    if abs(recomputed.medianMbps - s.medianMbps) > 0.01 * max(1, s.medianMbps) {
                        issues.append("\(test.label) \(speed.direction.rawValue): median not reproducible from raw samples")
                    }
                }
            }
            // Evidence must quote the protocol that was actually negotiated.
            if let proto = r.protocolProbe?.http?.negotiatedProtocol, proto != .http2 {
                for e in analysis.evidence.evidence where e.testIDs.contains(test.id) && e.statement.contains("HTTP/2 正常") {
                    issues.append("\(test.label): evidence claims HTTP/2 but \(proto.rawValue) was negotiated")
                }
            }
        }

        // Unavailable ≠ degraded.
        if let interfaces = analysis.evidence.crossTest?.interfaces {
            if interfaces.verdict == .allDegraded && interfaces.groups.contains(where: { !$0.degraded || $0.measuredCount == 0 }) {
                issues.append("allInterfacesDegraded includes a group that was not measured as degraded")
            }
            for g in interfaces.groups where g.measuredCount == 0 {
                issues.append("interface group \(g.networkClass.rawValue) has no measured tests but is included in verdicts")
            }
        }
        if let servers = analysis.evidence.crossTest?.servers {
            for e in servers.entries where e.status == .notMeasured && e.isAnomalous {
                issues.append("unavailable endpoint \(e.id) counted as anomalous")
            }
        }
        return issues
    }
}

import Foundation

public struct PrioritizedTest: Codable, Sendable, Hashable, Identifiable {
    public var test: RecommendedTest
    /// Highest confidence among the hypotheses this test helps confirm or exclude.
    public var priority: Double
    public var reasons: [String]
    public var id: RecommendedTest { test }
}

/// Complete root-cause analysis of a session.
public struct RootCauseAnalysis: Codable, Sendable, Hashable {
    public var evidence: EvidenceSet
    /// All hypotheses, ordered: likely → possible → insufficient → unlikely → ruled out, then by confidence.
    public var hypotheses: [DiagnosticHypothesis]
    public var recommendedTests: [PrioritizedTest]
    public var conclusion: String

    public var mostLikely: DiagnosticHypothesis? {
        hypotheses.first { $0.likelihood == .likely } ?? hypotheses.first { $0.likelihood == .possible }
    }
    public var likely: [DiagnosticHypothesis] { hypotheses.filter { $0.likelihood == .likely } }
    public var possible: [DiagnosticHypothesis] { hypotheses.filter { $0.likelihood == .possible } }
    public var unlikely: [DiagnosticHypothesis] { hypotheses.filter { $0.likelihood == .unlikely } }
    public var insufficient: [DiagnosticHypothesis] { hypotheses.filter { $0.likelihood == .insufficientEvidence } }
    public var ruledOut: [DiagnosticHypothesis] { hypotheses.filter { $0.likelihood == .ruledOut } }
}

public protocol RootCauseAnalyzing: Sendable {
    func analyze(session: DiagnosticSession, baselines: BaselineStore?) -> RootCauseAnalysis
}

/// Evidence-based differential diagnosis.
///
/// For every `HypothesisModel` (see `HypothesisCatalog` for the scoring formula):
///
/// 1. **Scope** — only evidence from tests on the relevant network (cellular / fixed) plus
///    session-level comparisons is considered.
/// 2. **Applicability** — if the model requires a condition (e.g. "on cellular") that is
///    verifiably absent, the cause is *ruled out*; if unknown, *insufficient evidence*.
/// 3. **Ruling-out evidence** — decisive contradicting facts (e.g. "all servers anomalous" rules
///    out "single server issue").
/// 4. **Scoring** — log-odds accumulation, one contribution per evidence code, capped.
/// 5. **Classification**
///
///        missing required dimension → conf ≤ 0.6; ≥ 0.40 possible, else insufficient evidence
///        no supporting evidence     → unlikely
///        conf ≥ 0.70 likely · ≥ 0.40 possible · else unlikely
///
/// No single metric can produce a "likely" verdict on its own unless the model's weight for it is
/// decisive by design (e.g. `ipv6DegradedOnly`, which is itself a cross-test comparison).
public struct RootCauseAnalyzer: RootCauseAnalyzing {
    public var models: [HypothesisModel]
    public var extractor: EvidenceExtractor

    public init(models: [HypothesisModel] = HypothesisCatalog.all, extractor: EvidenceExtractor = EvidenceExtractor()) {
        self.models = models
        self.extractor = extractor
    }

    public static let likelyThreshold = 0.70
    public static let possibleThreshold = 0.40

    public func analyze(session: DiagnosticSession, baselines: BaselineStore?) -> RootCauseAnalysis {
        analyze(evidence: extractor.extract(from: session, baselines: baselines))
    }

    public func analyze(evidence set: EvidenceSet) -> RootCauseAnalysis {
        let hypotheses = models.map { evaluate($0, set) }.sorted { lhs, rhs in
            lhs.likelihood != rhs.likelihood ? lhs.likelihood < rhs.likelihood : lhs.confidence > rhs.confidence
        }
        let tests = prioritizeTests(hypotheses)
        return RootCauseAnalysis(evidence: set, hypotheses: hypotheses, recommendedTests: tests,
                                 conclusion: conclusion(hypotheses, set, tests))
    }

    static func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }

    func scoped(_ evidence: [DiagnosticEvidence], _ scope: EvidenceScope) -> [DiagnosticEvidence] {
        switch scope {
        case .all: evidence
        case .cellular: evidence.filter { $0.interface == nil || $0.interface == .cellular }
        case .fixed: evidence.filter { $0.interface == nil || $0.interface == .wifi || $0.interface == .wiredEthernet }
        }
    }

    public func evaluate(_ model: HypothesisModel, _ set: EvidenceSet) -> DiagnosticHypothesis {
        let allCodes = set.codes
        let evidence = scoped(set.evidence, model.scope)
        let codes = Set(evidence.map(\.code))
        let missing = model.requiredDimensions.subtracting(set.measuredDimensions).sorted { $0.rawValue < $1.rawValue }

        func make(_ confidence: Double, _ likelihood: Likelihood, supporting: [DiagnosticEvidence] = [],
                  contradicting: [DiagnosticEvidence] = [], rulingOut: [DiagnosticEvidence] = []) -> DiagnosticHypothesis {
            DiagnosticHypothesis(cause: model.cause, layer: model.layer, title: model.title, explanation: model.explanation,
                                 supportingEvidence: supporting, contradictingEvidence: contradicting, rulingOutEvidence: rulingOut,
                                 missingDimensions: missing, confidence: confidence, likelihood: likelihood,
                                 recommendedNextTests: nextTests(model, missing: missing, codes: allCodes),
                                 limitations: model.limitations)
        }

        // Applicability.
        if !model.requiresAny.isEmpty, allCodes.isDisjoint(with: model.requiresAny) {
            let absent = set.evidence.filter { model.notApplicableWhen.contains($0.code) }
            return absent.isEmpty ? make(0, .insufficientEvidence) : make(0, .ruledOut, rulingOut: absent)
        }

        let supporting = evidence.filter { (model.weights[$0.code] ?? 0) > 0 }
        let contradicting = evidence.filter { (model.weights[$0.code] ?? 0) < 0 }
        let rulingOut = evidence.filter { model.ruledOutBy.contains($0.code) }

        let score = model.prior + codes.reduce(0.0) { $0 + (model.weights[$1] ?? 0) }
        var confidence = min(model.confidenceCap, Self.sigmoid(score))

        if !rulingOut.isEmpty {
            return make(min(confidence, 0.05), .ruledOut, supporting: supporting, contradicting: contradicting, rulingOut: rulingOut)
        }
        let likelihood: Likelihood
        if !missing.isEmpty {
            confidence = min(confidence, HypothesisModel.incompleteCap)
            likelihood = confidence >= Self.possibleThreshold && !supporting.isEmpty ? .possible : .insufficientEvidence
        } else if supporting.isEmpty {
            likelihood = .unlikely
        } else if confidence >= Self.likelyThreshold {
            likelihood = .likely
        } else if confidence >= Self.possibleThreshold {
            likelihood = .possible
        } else {
            likelihood = .unlikely
        }
        return make(confidence, likelihood, supporting: supporting, contradicting: contradicting)
    }

    /// Model-specific verification tests plus tests that would fill missing dimensions.
    func nextTests(_ model: HypothesisModel, missing: [EvidenceDimension], codes: Set<EvidenceCode>) -> [RecommendedTest] {
        var tests = model.verificationTests
        for dim in missing {
            switch dim {
            case .crossServer: tests.append(.testAlternateServers)
            case .ipFamily: tests.append(.compareIPFamilies)
            case .interfaceCompare: tests.append(codes.contains(.onCellular) ? .repeatOnWiFi : .repeatOnCellular)
            case .radioCompare: tests.append(codes.contains(.on5G) ? .repeatOnLTE : .repeatOn5G)
            case .dns: tests.append(.runDNSBenchmark)
            case .protocols: tests.append(.runProtocolProbe)
            case .mtu: tests.append(.runMTUTest)
            case .stabilityMonitoring: tests.append(.runContinuousMonitor)
            case .bufferbloat: tests.append(.runBufferbloatTest)
            case .baseline: tests.append(.repeatAtDifferentTime)
            case .throughput, .latency, .loss, .environment: break
            }
        }
        // Don't suggest switching to a network the user is already comparing, or LTE while on LTE only.
        var seen = Set<RecommendedTest>()
        return tests.filter { seen.insert($0).inserted }
    }

    func prioritizeTests(_ hypotheses: [DiagnosticHypothesis]) -> [PrioritizedTest] {
        var table: [RecommendedTest: PrioritizedTest] = [:]
        for h in hypotheses where h.likelihood == .likely || h.likelihood == .possible || h.likelihood == .insufficientEvidence {
            // Insufficient-evidence hypotheses still deserve a test, at a low priority.
            let weight = h.likelihood == .insufficientEvidence ? 0.1 : h.confidence
            for t in h.recommendedNextTests {
                var entry = table[t] ?? PrioritizedTest(test: t, priority: 0, reasons: [])
                entry.priority = max(entry.priority, weight)
                entry.reasons.append(h.title)
                table[t] = entry
            }
        }
        return table.values.sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.test.rawValue < $1.test.rawValue }
    }

    func conclusion(_ hypotheses: [DiagnosticHypothesis], _ set: EvidenceSet, _ tests: [PrioritizedTest]) -> String {
        var lines: [String] = []
        let likely = hypotheses.filter { $0.likelihood == .likely }
        let possible = hypotheses.filter { $0.likelihood == .possible }
        if let top = likely.first ?? possible.first {
            lines.append("最可能原因：\(top.title)（\(top.likelihood.displayName)，信心 \(top.confidencePercent)%，位於「\(top.layer.displayName)」層）。")
            if !top.supportingEvidence.isEmpty {
                lines.append("主要依據：" + top.supportingEvidence.prefix(4).map(\.statement).joined(separator: "；") + "。")
            }
            if !top.contradictingEvidence.isEmpty {
                lines.append("反向證據：" + top.contradictingEvidence.prefix(3).map(\.statement).joined(separator: "；") + "。")
            }
            let others = (likely + possible).dropFirst().prefix(3)
            if !others.isEmpty {
                lines.append("其他可能：" + others.map { "\($0.title)（\($0.confidencePercent)%）" }.joined(separator: "、") + "。")
            }
        } else if set.evidence.isEmpty {
            lines.append("尚無足夠的測試資料可供診斷。")
        } else {
            lines.append("目前沒有任何原因達到「有可能」以上的信心；若仍有症狀，請依建議補做測試。")
        }
        let ruled = hypotheses.filter { $0.likelihood == .ruledOut }
        if !ruled.isEmpty {
            lines.append("已排除：" + ruled.prefix(6).map(\.title).joined(separator: "、") + "。")
        }
        if let next = tests.first {
            lines.append("建議下一步：\(next.test.title)。")
        }
        if set.codes.contains(.cellularRadioMetricsUnavailable) {
            lines.append("限制：iOS 不提供 RSRP / RSRQ / SINR / 頻段 / Cell ID，因此無法直接判定基地台或手機硬體問題。")
        }
        return lines.joined(separator: "\n")
    }
}

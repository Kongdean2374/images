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

    /// A cause (likely / possible) is preferred; a supported *condition* is shown only when no cause qualifies.
    public var mostLikely: DiagnosticHypothesis? {
        hypotheses.first { $0.likelihood == .likely } ?? hypotheses.first { $0.likelihood == .possible }
            ?? hypotheses.first { $0.likelihood == .supported }
    }
    public var supported: [DiagnosticHypothesis] { hypotheses.filter { $0.likelihood == .supported } }
    public var broadIssueUnlikely: [DiagnosticHypothesis] { hypotheses.filter { $0.likelihood == .broadIssueUnlikely } }
    public var noEvidence: [DiagnosticHypothesis] { hypotheses.filter { $0.likelihood == .noEvidence } }
    public var likely: [DiagnosticHypothesis] { hypotheses.filter { $0.likelihood == .likely } }
    public var possible: [DiagnosticHypothesis] { hypotheses.filter { $0.likelihood == .possible } }
    public var unlikely: [DiagnosticHypothesis] { hypotheses.filter { $0.likelihood == .unlikely } }
    public var insufficient: [DiagnosticHypothesis] { hypotheses.filter { $0.likelihood == .insufficientEvidence } }
    public var notTested: [DiagnosticHypothesis] { hypotheses.filter { $0.likelihood == .notTested } }
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
///        required condition never exercised  → not tested (never "ruled out")
///        decisive measured contradiction     → ruled out
///        missing required dimension          → conf ≤ 0.6; ≥ 0.40 with support possible;
///                                              never attempted → not tested, else insufficient evidence
///        no supporting evidence              → unlikely
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

    /// Codes produced from a limited (non-comparable) comparison, and the confidence they may reach.
    static let limitedComparisonCodes: Set<EvidenceCode> = [.loadedLatencyRiseLimitedComparison]
    static let limitedComparisonCap = 0.6

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
        let neverAttempted = model.requiredDimensions.subtracting(set.attemptedDimensions)

        func make(_ confidence: Double, _ likelihood: Likelihood, supporting: [DiagnosticEvidence] = [],
                  contradicting: [DiagnosticEvidence] = [], rulingOut: [DiagnosticEvidence] = [], reason: String? = nil) -> DiagnosticHypothesis {
            DiagnosticHypothesis(cause: model.cause, layer: model.layer, title: model.title, explanation: model.explanation,
                                 supportingEvidence: supporting, contradictingEvidence: contradicting, rulingOutEvidence: rulingOut,
                                 statusReason: reason, missingDimensions: missing, confidence: confidence, likelihood: likelihood,
                                 recommendedNextTests: nextTests(model, missing: missing, codes: allCodes),
                                 limitations: model.limitations)
        }

        // 1. Applicability. A required condition that was never exercised is "not tested" —
        //    only an authoritative measurement of its absence can rule the cause out.
        if !model.requiresAny.isEmpty, allCodes.isDisjoint(with: model.requiresAny) {
            let absent = set.evidence.filter { model.notApplicableWhen.contains($0.code) }
            if !absent.isEmpty {
                let decisive = model.absenceIsDecisive && absent.allSatisfy { $0.kind == .measured }
                return decisive
                    ? make(0, .ruledOut, rulingOut: absent, reason: "實測條件不成立")
                    : make(0.05, .unlikely, contradicting: absent, reason: "觀察到條件不成立（非決定性證據）")
            }
            let need = model.requirement.isEmpty ? "所需條件" : model.requirement
            return make(0, .notTested, reason: "本工作階段沒有\(need)，無法評估此原因（未測試 ≠ 已排除）")
        }

        let supporting = evidence.filter { (model.weights[$0.code] ?? 0) > 0 }
        let contradicting = evidence.filter { (model.weights[$0.code] ?? 0) < 0 }
        // 2. Ruling out needs a decisive, directly measured or derived fact — never a
        //    "not tested" / heuristic observation.
        // An unexplained fact that the ruling-out evidence can't account for keeps the hypothesis open.
        let blocked = !codes.isDisjoint(with: model.ruleOutBlockedBy)
        let rulingOut = blocked ? [] : evidence.filter { model.ruledOutBy.contains($0.code) && ($0.kind == .measured || $0.kind == .derived) }

        let score = model.prior + codes.reduce(0.0) { $0 + (model.weights[$1] ?? 0) }
        var confidence = min(model.confidenceCap, Self.sigmoid(score))
        // Evidence from a non-comparable baseline (e.g. bufferbloat with mixed probe sources) is
        // indicative only: never a high band while the measured condition itself is absent.
        if !codes.isDisjoint(with: Self.limitedComparisonCodes), model.observedCondition.map({ !codes.contains($0) }) ?? true {
            confidence = min(confidence, Self.limitedComparisonCap)
        }
        // Not reproduced with the same protocol / configuration or by a server-level measurement.
        if !model.reproducedBy.isEmpty, codes.isDisjoint(with: model.reproducedBy) {
            confidence = min(confidence, model.unreproducedCap)
        }

        if !rulingOut.isEmpty {
            // Controls that only cover the broad form of the cause (one target / transport) can't
            // exclude a narrower variant.
            if model.scopedRuleOut {
                return make(min(confidence, 0.15), .broadIssueUnlikely, supporting: supporting, contradicting: contradicting + rulingOut,
                            reason: "受測的控制條件使「廣泛性」問題不太可能，但不足以排除其他特定路徑 / 目標")
            }
            return make(min(confidence, 0.05), .ruledOut, supporting: supporting, contradicting: contradicting, rulingOut: rulingOut,
                        reason: "決定性實測證據與此原因矛盾（具正交控制）")
        }
        // A directly measured condition: the fact is established, its mechanism / location is not.
        if let condition = model.observedCondition, let fact = evidence.first(where: { $0.code == condition && $0.kind == .measured }) {
            return make(confidence, .supported, supporting: supporting.isEmpty ? [fact] : supporting, contradicting: contradicting,
                        reason: "條件已實測成立；發生位置 / 機制仍屬推論")
        }
        // 3. Missing data.
        if !missing.isEmpty {
            confidence = min(confidence, HypothesisModel.incompleteCap)
            if confidence >= Self.possibleThreshold && !supporting.isEmpty {
                return make(confidence, .possible, supporting: supporting, contradicting: contradicting,
                            reason: "部分支持，但缺少：\(missing.map(\.displayName).joined(separator: "、"))")
            }
            if neverAttempted.count == model.requiredDimensions.subtracting(set.measuredDimensions).count && supporting.isEmpty {
                return make(confidence, .notTested, supporting: supporting, contradicting: contradicting,
                            reason: "未執行：\(missing.map(\.displayName).joined(separator: "、"))")
            }
            return make(confidence, .insufficientEvidence, supporting: supporting, contradicting: contradicting,
                        reason: "已測試但資料不足以判斷：\(missing.map(\.displayName).joined(separator: "、"))")
        }
        // 4. Scored classification.
        if supporting.isEmpty {
            if contradicting.isEmpty {
                return make(confidence, .noEvidence, reason: "沒有與此原因相關的觀察（無支持亦無反向證據）")
            }
            return make(confidence, .unlikely, contradicting: contradicting, reason: "沒有支持此原因的觀察，且有反向證據")
        }
        let likelihood: Likelihood = confidence >= Self.likelyThreshold ? .likely : (confidence >= Self.possibleThreshold ? .possible : .unlikely)
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
            case .route: tests.append(.runTraceroute)
            case .throughput, .latency, .loss, .environment: break
            }
        }
        // Don't suggest switching to a network the user is already comparing, or LTE while on LTE only.
        var seen = Set<RecommendedTest>()
        return tests.filter { Self.applicable($0, codes: codes) && seen.insert($0).inserted }
    }

    /// Environment-aware filter: a recommendation must make sense for the network that was tested.
    ///
    ///     moveCloserToRouter / pauseOtherDevices  → only with a Wi-Fi test
    ///     disableVPNAndRepeat                     → only with a VPN detected
    ///     disableLowDataMode                      → only with Low Data Mode on
    ///     repeatOnCellular                        → not when every test already is cellular
    ///     repeatOnWiFi                            → not when every test already is Wi-Fi
    ///     repeatOnLTE / repeatOn5G                → not when the only radio tested already is that one
    static func applicable(_ test: RecommendedTest, codes: Set<EvidenceCode>) -> Bool {
        let wifi = codes.contains(.onWiFi), cellular = codes.contains(.onCellular)
        switch test {
        case .moveCloserToRouter, .pauseOtherDevices: return wifi
        case .disableVPNAndRepeat: return codes.contains(.vpnActive)
        case .disableLowDataMode: return codes.contains(.lowDataMode)
        case .repeatOnCellular: return !(cellular && !wifi)
        case .repeatOnWiFi: return !(wifi && !cellular)
        case .repeatOnLTE: return !(codes.contains(.onLTE) && !codes.contains(.on5G))
        case .repeatOn5G: return !(codes.contains(.on5G) && !codes.contains(.onLTE))
        default: return true
        }
    }

    func prioritizeTests(_ hypotheses: [DiagnosticHypothesis]) -> [PrioritizedTest] {
        var table: [RecommendedTest: PrioritizedTest] = [:]
        for h in hypotheses where [.supported, .likely, .possible, .insufficientEvidence, .notTested].contains(h.likelihood) {
            // Untested / inconclusive hypotheses still deserve a test, at a low priority.
            let weight = h.likelihood == .insufficientEvidence ? 0.1 : (h.likelihood == .notTested ? 0.05 : h.confidence)
            for t in h.recommendedNextTests {
                var entry = table[t] ?? PrioritizedTest(test: t, priority: 0, reasons: [])
                entry.priority = max(entry.priority, weight)
                entry.reasons.append(h.title)
                table[t] = entry
            }
        }
        return table.values.sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.test.rawValue < $1.test.rawValue }
    }

    /// Conclusion text. Every line is labelled with its epistemic status so a measured fact is
    /// never presented as a hypothesis or vice versa:
    ///
    ///     [實測] measured fact · [推導] derived observation · [推論] hypothesis (evidence score,
    ///     uncalibrated — not a probability) · [未測量] dimensions without data
    func conclusion(_ hypotheses: [DiagnosticHypothesis], _ set: EvidenceSet, _ tests: [PrioritizedTest]) -> String {
        var lines: [String] = []
        func score(_ h: DiagnosticHypothesis) -> String { "證據分數 \(h.evidenceScore)/100，信心區間：\(h.confidenceBand.displayName)" }
        let supported = hypotheses.filter { $0.likelihood == .supported }
        for h in supported {
            let facts = h.supportingEvidence.filter { $0.kind == .measured }.prefix(2).map(\.statement)
            lines.append("[實測] " + (facts.isEmpty ? h.title : facts.joined(separator: "；")) + "。")
            lines.append("[推論] 發生位置 / 機制：\(h.title) 的位置仍未知，屬假設而非實測。")
        }
        let likely = hypotheses.filter { $0.likelihood == .likely }
        let possible = hypotheses.filter { $0.likelihood == .possible }
        if let top = likely.first ?? possible.first {
            lines.append("[推論] 最可能原因：\(top.title)（\(top.likelihood.displayName)，\(score(top))，位於「\(top.layer.displayName)」層；分數未經真實故障資料校準，不是機率）。")
            let measured = top.supportingEvidence.filter { $0.kind == .measured }.prefix(3)
            let derived = top.supportingEvidence.filter { $0.kind == .derived }.prefix(2)
            let heuristic = top.supportingEvidence.filter { $0.kind == .heuristic }.prefix(2)
            if !measured.isEmpty { lines.append("[實測] 依據：" + measured.map(\.statement).joined(separator: "；") + "。") }
            if !derived.isEmpty { lines.append("[推導] 依據：" + derived.map(\.statement).joined(separator: "；") + "。") }
            if !heuristic.isEmpty { lines.append("[推論] 啟發式依據：" + heuristic.map(\.statement).joined(separator: "；") + "。") }
            if !top.contradictingEvidence.isEmpty {
                lines.append("反向證據：" + top.contradictingEvidence.prefix(3).map(\.statement).joined(separator: "；") + "。")
            }
            let others = (likely + possible).dropFirst().prefix(3)
            if !others.isEmpty {
                lines.append("[推論] 其他可能：" + others.map { "\($0.title)（\($0.evidenceScore)/100）" }.joined(separator: "、") + "。")
            }
        } else if set.evidence.isEmpty {
            lines.append("尚無足夠的測試資料可供診斷。")
        } else if supported.isEmpty {
            lines.append("目前沒有任何原因達到「有可能」以上；若仍有症狀，請依建議補做測試。")
        }
        let ruled = hypotheses.filter { $0.likelihood == .ruledOut }
        if !ruled.isEmpty {
            lines.append("已排除（有正交控制的實測證據）：" + ruled.prefix(6).map(\.title).joined(separator: "、") + "。")
        }
        let broad = hypotheses.filter { $0.likelihood == .broadIssueUnlikely }
        if !broad.isEmpty {
            lines.append("廣泛性問題不太可能（未排除特定路徑 / 目標）：" + broad.prefix(6).map(\.title).joined(separator: "、") + "。")
        }
        let untested = hypotheses.filter { $0.likelihood == .notTested }
        if !untested.isEmpty {
            lines.append("未測試（不代表已排除）：" + untested.prefix(6).map(\.title).joined(separator: "、") + "。")
        }
        let unmeasured = EvidenceDimension.allCases.filter { !set.measuredDimensions.contains($0) }
        if !unmeasured.isEmpty && !set.evidence.isEmpty {
            lines.append("[未測量] " + unmeasured.map(\.displayName).joined(separator: "、") + "。")
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

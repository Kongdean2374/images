import Foundation

/// Complete machine-oriented export of one result: English keys, explicit units, every raw
/// sample. Intended for engineers and AI analysis, not for reading on the phone.
public struct RawDataExport: Codable, Sendable {
    public var schema: String
    public var version: Int
    public var generatedAt: Date
    public var appVersion: String
    public var platform: String
    public var result: TestResult
    public var analysis: RootCauseAnalysis?
    /// "aiSafe; ip_addresses=[REDACTED] …" or "engineer; ip_addresses=full …".
    public var privacy: String?
    /// v2: values derived from the raw data (spike summary, bufferbloat comparability, DNS rows…),
    /// so JSON consumers do not have to re-implement the analysis. Absent in v1 exports.
    public var derived: RawDataDerived?
}

/// Schema v2 derived section (all optional; v1 readers ignore it).
public struct RawDataDerived: Codable, Sendable {
    public var monitoringSpikes: SpikeSummary?
    public var bufferbloatComparisons: [BufferbloatComparison]?
    public var dnsLookups: [DNSLookupRow]?
    public var dnsFindings: [DNSFinding]?
    /// Per direction: "cross_provider_median" or "primary_method".
    public var headlineScope: [String: String]?
    public var headlineMbps: [String: Double]?
    public var claimTypes: [String: String]?
    /// v2.2.1: provenance per generic latency section ("idle", "downloadLoaded", "uploadLoaded").
    public var latencyProvenance: [String: LatencyProvenance]?
    public var dnsOutliers: [DNSOutlier]?
    public var durationAdjustmentReason: String?
}

extension EvidenceKind {
    /// Export claim type: measured fact / derived observation / heuristic inference / not measured.
    public var claimType: String {
        switch self {
        case .measured: return "measured_fact"
        case .derived: return "derived_observation"
        case .heuristic: return "heuristic_inference"
        case .notTested: return "not_measured"
        }
    }
}

public enum RawDataExporter {
    public static let schema = "chainet.raw-export"
    /// v2 (ChaiNet 2.2.0): bufferbloat comparability, method-aware cross-provider statistics,
    /// scoped loss verdicts, evidence scores instead of probability-like confidence, spike
    /// definition, per-lookup DNS rows, per-endpoint HTTP/3 status, scoped MTU, traceroute
    /// analysis, upload measurement source, data limits. Every v1 key is still written.
    public static let version = 2

    public static func derived(for r: TestResult) -> RawDataDerived {
        var d = RawDataDerived()
        d.monitoringSpikes = r.monitoringSpikeSummary
        if let st = r.stress {
            d.bufferbloatComparisons = TransferDirection.allCases.compactMap { st.bufferbloatComparison($0) }
            var scope: [String: String] = [:], mbps: [String: Double] = [:]
            for dir in TransferDirection.allCases {
                scope[dir.rawValue] = st.headlineScope(dir)
                if let v = st.headlineMbps(dir) { mbps[dir.rawValue] = v }
            }
            d.headlineScope = scope
            d.headlineMbps = mbps
        }
        if let dns = r.dns {
            d.dnsLookups = DNSAnalyzer.rows(dns)
            d.dnsFindings = DNSAnalyzer.analyze(dns)
            d.dnsOutliers = DNSAnalyzer.outliers(dns)
        }
        var provenance: [String: LatencyProvenance] = [:]
        for section in LatencySection.allCases { provenance[section.rawValue] = r.latencyProvenance(section) }
        d.latencyProvenance = provenance.isEmpty ? nil : provenance
        d.durationAdjustmentReason = r.stress.map { $0.plan.durationAdjustmentReason(configuredSeconds: $0.configuredSeconds) }
        d.claimTypes = Dictionary(uniqueKeysWithValues: [EvidenceKind.measured, .derived, .heuristic, .notTested].map { ($0.rawValue, $0.claimType) })
        return d
    }

    /// Single-test root-cause analysis for the export.
    public static func analysis(for result: TestResult, baselines: BaselineStore? = nil) -> RootCauseAnalysis {
        let session = DiagnosticSession(title: "export", tests: [SessionTest(label: "Test A", result: result)])
        return RootCauseAnalyzer().analyze(session: session, baselines: baselines)
    }

    /// `privacy` defaults to AI-safe: every IP literal is `[REDACTED]` (see `IPRedactor`).
    public static func json(_ result: TestResult, analysis: RootCauseAnalysis?, appVersion: String, platform: String,
                            includeLocation: Bool = false, privacy: ExportPrivacy = .aiSafe) throws -> Data {
        var r = result
        if !includeLocation { r.location = nil }
        let export = RawDataExport(schema: schema, version: version, generatedAt: Date(), appVersion: appVersion, platform: platform,
                                   result: r, analysis: analysis, privacy: privacy.summary, derived: derived(for: r))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(export)
        guard privacy.redactsIPs else { return data }
        return Data(IPRedactor.redact(String(decoding: data, as: UTF8.self)).utf8)
    }

    // MARK: Text

    public static func text(_ r: TestResult, analysis: RootCauseAnalysis?, appVersion: String, platform: String,
                            includeLocation: Bool = false, privacy: ExportPrivacy = .aiSafe) -> String {
        var o: [String] = []
        let iso = ISO8601DateFormatter()
        func sec(_ title: String) { o.append(""); o.append("[\(title)]") }
        func kv(_ k: String, _ v: String) { o.append("\(k)=\(v)") }
        func n(_ x: Double?, _ d: Int = 3) -> String { x.map { $0.isFinite ? Fmt.d($0, d) : "nan" } ?? "null" }
        func b(_ x: Bool?) -> String { x.map { $0 ? "true" : "false" } ?? "null" }
        func avail<T: Codable & Sendable & Hashable>(_ a: Availability<T>, _ f: (T) -> String) -> String {
            if case .available(let v) = a { return f(v) }
            return "unavailable"
        }
        func provenance(_ p: LatencyProvenance?, comparableWithIdle: Bool? = nil) {
            guard let p else { return }
            kv("probe_target", p.probe.target); kv("probe_method", p.probe.method); kv("probe_protocol", p.probe.protocolName)
            kv("probe_ip_family", p.probe.ipFamily); kv("measurement_source", p.measurementSource); kv("comparison_group", p.comparisonGroup)
            kv("comparison_group_id", p.probe.comparisonGroupID)
            if let c = comparableWithIdle {
                kv("comparable_with_latency_idle", b(c))
                if !c { o.append("# Not the same probe as [latency_idle] (different target / method): do NOT subtract or compare these two sections. Idle vs loaded for bufferbloat: [bufferbloat_control_idle] vs this section.") }
            }
        }
        func latency(_ name: String, _ s: LatencyStatistics?, _ section: LatencySection? = nil) {
            sec(name)
            if let section {
                provenance(r.latencyProvenance(section), comparableWithIdle: section == .idle ? nil : r.latencySectionsComparable(.idle, section))
            }
            guard let s else { kv("measured", "false"); return }
            kv("sent", "\(s.sent)"); kv("received", "\(s.received)")
            if let t = s.rtt {
                kv("rtt_min_ms", n(t.minimum)); kv("rtt_avg_ms", n(t.average)); kv("rtt_median_ms", n(t.median)); kv("rtt_max_ms", n(t.maximum))
                kv("rtt_p95_ms", n(t.p95)); kv("rtt_p99_ms", n(t.p99)); kv("jitter_mean_abs_diff_ms", n(t.jitter))
                kv("jitter_rfc3550_ms", n(t.jitterRFC3550)); kv("rtt_stddev_ms", n(t.standardDeviation))
            }
            let l = s.loss
            kv("loss_percent", n(l.lossPercent)); kv("lost", "\(l.lost)"); kv("loss_pattern", l.pattern.rawValue)
            kv("random_loss_percent", n(l.randomLossPercent)); kv("burst_loss_percent", n(l.burstLossPercent))
            kv("random_loss_events", "\(l.randomLossEvents)"); kv("burst_events", "\(l.burstEvents)"); kv("longest_burst", "\(l.longestBurst)")
            kv("burst_threshold", "\(l.burstThreshold)")
            kv("gilbert_p_loss_after_receive", n(l.lossProbabilityAfterReceive)); kv("gilbert_r_recover_after_loss", n(l.recoveryProbabilityAfterLoss))
        }
        func diagnostics(_ d: TransferDiagnostics) {
            kv("http_requests", "\(d.requestsStarted)"); kv("http_responses", "\(d.responses)")
            kv("http_status_counts", d.statusCounts.keys.sorted().map { "\($0):\(d.statusCounts[$0]!)" }.joined(separator: ","))
            kv("content_types", d.contentTypes.joined(separator: "|")); kv("expected_bytes_per_request", d.expectedBytesPerRequest.map(String.init) ?? "null")
            kv("smallest_response_bytes", d.smallestResponseBytes.map(String.init) ?? "null"); kv("tiny_responses", "\(d.tinyResponses)")
            kv("transport_errors", "\(d.errorCount)"); kv("timeouts", "\(d.timeoutCount)")
            kv("per_stream_bytes", d.perStreamBytes.map(String.init).joined(separator: ","))
        }
        func speed(_ name: String, _ s: SpeedResult?) {
            sec(name)
            guard let s else { kv("measured", "false"); return }
            let m = s.summary
            func reliable(_ v: Double?, _ d: Int = 3) -> String { m.shortWindowReliable ? n(v, d) : "unavailable" }
            kv("valid", b(s.isValid))
            if let v = s.validity, !v.valid { kv("error", v.reason?.rawValue ?? "invalid"); kv("error_detail", v.detail ?? "") }
            kv("avg_mbps_time_weighted", n(m.averageMbps)); kv("peak_mbps", reliable(m.peakMbps)); kv("min_mbps", reliable(m.minimumMbps))
            kv("median_mbps", reliable(m.medianMbps)); kv("p95_mbps", reliable(m.p95Mbps)); kv("p10_mbps_sustained", reliable(m.p10Mbps))
            kv("measurement_source", s.measurementSource ?? "clientCounters")
            if let sc = s.serverConfirmed {
                kv("server_confirmed_source", sc.source); kv("server_confirmed_avg_mbps", n(sc.averageMbps))
                kv("server_confirmed_median_1s_mbps", n(sc.medianMbps)); kv("server_confirmed_p10_1s_mbps", n(sc.p10Mbps))
                kv("server_confirmed_stability_0_100", n(sc.stabilityScore, 1))
                kv("server_confirmed_windows_1s_mbps", sc.windowMbps.map { Fmt.d($0, 2) }.joined(separator: ","))
            }
            kv("sampling_artifact", b(m.samplingArtifactDetected ?? false))
            if m.shortWindowReliable {
                kv("stability_score_0_100", n(m.stability.score, 1)); kv("stability_cv", n(m.stability.coefficientOfVariation, 4))
                kv("drop_windows_below_50pct_median", "\(m.stability.dropCount)")
            } else {
                kv("stability", "unavailable"); kv("stability_reason", m.stabilityUnavailableReason ?? "measurementSamplingArtifact")
                kv("drop_windows_below_50pct_median", "unavailable")
                o.append("# Progress reporting was batched (long 0 Mbps runs + bursts): short-window statistics describe the reporting cadence, not the network. Average = bytes / elapsed time remains valid.")
            }
            if let d = s.diagnostics { diagnostics(d) }
            kv("total_bytes", "\(m.totalBytes)"); kv("duration_s", n(m.duration)); kv("cancelled", b(s.wasCancelled))
            kv("statistics_method", "time-weighted windows of \(m.windowSamples ?? 1) x 100 ms samples after warm-up \(n(m.warmupDuration ?? 1, 1)) s and stream-count transition guard 1.0 s")
            kv("excluded_samples_total", "\(m.warmupSampleCount)"); kv("excluded_samples_stream_transitions", "\(m.transitionExcludedSampleCount ?? 0)")
            kv("analysis_windows", "\(m.analysisWindowCount ?? 0)")
            kv("analysis_window_mbps", (m.analysisWindowMbps ?? []).map { Fmt.d($0, 2) }.joined(separator: ","))
            kv("stream_changes", s.streamChanges.map { "\(Fmt.d($0.offset, 2))s:\($0.streams)" }.joined(separator: ","))
        }
        func csvSamples(_ name: String, _ samples: [LatencySample]?) {
            guard let samples, !samples.isEmpty else { return }
            sec(name)
            o.append("seq,offset_s,rtt_ms")
            for x in samples.sorted(by: { $0.sequence < $1.sequence }) {
                o.append("\(x.sequence),\(Fmt.d(x.offset, 3)),\(x.rttMs.map { Fmt.d($0, 3) } ?? "lost")")
            }
        }
        func speedSamples(_ name: String, _ s: SpeedResult?) {
            guard let s, !s.samples.isEmpty else { return }
            sec(name)
            o.append("offset_s,interval_s,interval_bytes,cumulative_bytes,active_streams,mbps")
            for x in s.samples {
                o.append("\(Fmt.d(x.offset, 3)),\(Fmt.d(x.intervalDuration, 3)),\(x.intervalBytes),\(x.cumulativeBytes),\(x.activeStreams),\(Fmt.d(x.mbps, 3))")
            }
        }

        o.append("ChaiNet Raw Data Export v\(version)")
        o.append("# Plain-text, English, explicit units. Every raw sample follows the summaries. Intended for engineers / AI analysis.")
        o.append("# Values the iOS platform does not expose are written as 'unavailable' (never simulated).")
        o.append("# schema_version 2: v1 keys are kept; new keys are additive. claim_type = measured_fact | derived_observation | heuristic_inference | not_measured.")
        o.append("# evidence_score_0_100 / confidence_band are uncalibrated evidence strength, NOT probabilities.")

        sec("meta")
        kv("schema", schema); kv("schema_version", "\(version)"); kv("generated_at", iso.string(from: Date())); kv("app_version", appVersion); kv("platform", platform)
        kv("test_id", r.id.uuidString); kv("test_date", iso.string(from: r.date)); kv("test_kind", r.kind.rawValue); kv("cancelled", b(r.wasCancelled))
        kv("ip_family_preference", r.ipFamilyPreference.rawValue)
        kv("export_privacy", privacy.summary)
        if includeLocation, let loc = r.location { kv("location", "\(Fmt.d(loc.latitude, 5)),\(Fmt.d(loc.longitude, 5)) acc=\(Fmt.d(loc.horizontalAccuracy, 0))m") }

        if let p = r.fullTestPlan {
            sec("full_test_plan")
            kv("requested_s", n(p.requestedSeconds, 0)); kv("estimated_s", n(p.estimatedSeconds, 0)); kv("server_count", "\(p.serverCount)")
            kv("force_max_streams", b(p.forceMaxStreams))
            kv("per_server_idle_s", n(p.idleSeconds, 1)); kv("per_server_loss_s", n(p.lossSeconds, 1)); kv("per_server_throughput_s_each_direction", n(p.throughputSeconds, 1))
            kv("monitoring_s", n(p.monitoringSeconds, 1)); kv("cross_validation_s", n(p.crossValidationSeconds, 1))
            kv("ip_family_s", n(p.ipFamilySeconds, 1)); kv("interface_compare_s", n(p.interfaceSeconds, 1))
        }

        if let st = r.stress {
            sec("stress_test")
            kv("test_mode", st.testMode)
            kv("configured_duration_s", n(st.configuredSeconds, 0)); kv("planned_duration_s", n(st.plan.estimatedSeconds, 0))
            kv("actual_duration_s", n(st.actualSeconds, 1)); kv("rounds", "\(st.plan.rounds)")
            kv("duration_adjustment_reason", st.plan.durationAdjustmentReason(configuredSeconds: st.configuredSeconds))
            kv("minimum_duration_s", n(StressTestPlan.minimumSeconds, 0)); kv("diagnostic_phases_s", n(st.plan.diagnosticSeconds, 1))
            kv("throughput_phases_s", n(st.plan.estimatedSeconds - st.plan.diagnosticSeconds, 1))
            if let e = st.trafficEstimate {
                kv("estimated_data_usage_bytes", "\(e.totalBytes)"); kv("estimated_data_usage_range_bytes", "\(e.lowBytes)-\(e.highBytes)")
                kv("estimate_assumed_mbps", "download=\(n(e.assumedDownloadMbps, 0)) upload=\(n(e.assumedUploadMbps, 0)) (conservative point estimate)")
                if let cd = e.ceilingDownloadMbps, let cu = e.ceilingUploadMbps {
                    kv("estimate_range_ceiling_mbps", "download=\(n(cd, 0)) upload=\(n(cu, 0)) (fast-link upper bound for this network type)")
                }
            }
            if let p = st.trafficProjection {
                func v(_ x: Int64?) -> String { x.map(String.init) ?? "null" }
                kv("original_estimate_bytes", v(p.originalEstimateBytes))
                kv("original_estimate_range_bytes", "\(v(p.originalRangeLowBytes))-\(v(p.originalRangeHighBytes))")
                kv("updated_estimate_bytes", v(p.updatedEstimateBytes)); kv("updated_estimate_basis", p.updatedBasis ?? "null")
                kv("observed_download_mbps", n(p.observedDownloadMbps)); kv("observed_upload_mbps", n(p.observedUploadMbps))
                kv("latest_projection_bytes", v(p.latestProjectionBytes))
                kv("actual_usage_bytes", "\(st.totalBytes)")
                if let o = p.originalEstimateBytes, o > 0 {
                    kv("actual_vs_original_estimate_percent", n(Double(st.totalBytes - o) / Double(o) * 100, 1))
                }
                kv("projection_warning", p.warning ?? "none")
                o.append("# updated_estimate = bytes used after round 1 + remaining planned transfer seconds x observed Mbps (budget-recycled extra rounds are added to latest_projection only when they start).")
            }
            kv("http_streams_per_transfer", "\(st.plan.streams)"); kv("ndt7_streams_per_transfer", "1")
            kv("transfer_s_per_node_direction_round", n(st.plan.transferSeconds, 1))
            kv("stress_packet_rate_pps", n(st.plan.stressPacketsPerSecond, 0)); kv("control_packet_rate_pps", n(st.plan.controlPacketsPerSecond, 0))
            kv("total_download_bytes", "\(st.totalDownloadBytes)"); kv("total_upload_bytes", "\(st.totalUploadBytes)"); kv("total_bytes", "\(st.totalBytes)")
            kv("stress_score_0_100", st.score.map(String.init) ?? "null")
            kv("score_confidence", st.scoreConfidence?.rawValue ?? "null")
            kv("excluded_invalid_metrics", (st.excludedInvalidMetrics ?? []).joined(separator: " | "))
            kv("recycled_budget_s", n(st.recycledSeconds, 1)); kv("extended_monitoring_median_ms", n(st.extendedMonitoring?.rtt?.median))
            let lim = st.dataLimits ?? .unlimited
            func cap(_ v: Int64?) -> String { v.map(String.init) ?? "unlimited" }
            kv("data_limit_policy", lim.policy ?? (lim.isLimited ? "userConfigured" : "unknown"))
            kv("data_warning_bytes", cap(lim.warningBytes)); kv("data_soft_warning_bytes", cap(lim.softWarningBytes)); kv("data_hard_cap_bytes", cap(lim.hardCapBytes))
            kv("data_download_cap_bytes", cap(lim.downloadCapBytes)); kv("data_upload_cap_bytes", cap(lim.uploadCapBytes))
            kv("data_cap_reached", b(st.dataCapReached ?? false))
            if st.dataCapReached == true { o.append("# Throughput phases after the cap were skipped (phase note 'skipped: dataCapReached'); low-data diagnostics still ran.") }
            for w in st.warnings { kv("warning", w) }
            sec("stress_nodes")
            o.append("node_id,name,provider,host,capabilities,throughput_capable,healthy,health_latency_ms,health_detail")
            for node in st.nodes {
                o.append([node.id, node.name, node.provider.rawValue, node.host, node.capabilityList, b(node.isThroughputCapable),
                          b(node.healthy), n(node.healthLatencyMs), (node.healthDetail ?? "").replacingOccurrences(of: ",", with: ";")].joined(separator: ","))
            }
            sec("stress_phases")
            o.append("phase,round,node_id,planned_s,start_offset_s,actual_s,download_bytes,upload_bytes,note")
            for p in st.phases {
                o.append([p.kind.rawValue, p.round.map(String.init) ?? "", p.nodeID ?? "", n(p.plannedSeconds, 1), n(p.startOffset, 2),
                          n(p.actualSeconds, 2), "\(p.downloadBytes)", "\(p.uploadBytes)", (p.note ?? "").replacingOccurrences(of: ",", with: ";")]
                    .joined(separator: ","))
            }
            sec("stress_transfers_per_server")
            o.append("node_id,round,attempt,direction,method,valid,error,load_valid,bytes,duration_s,avg_mbps,median_mbps,p10_mbps,p95_mbps,min_mbps,peak_mbps,stability,stability_reason,window_samples,sampling_artifact,loaded_median_ms,loaded_p95_ms,http_status_counts,tiny_responses,per_stream_bytes,measurement_source,server_confirmed_mbps")
            for t in st.transfers {
                let m = t.speed?.summary
                let rel = m?.shortWindowReliable ?? false
                func sw(_ v: Double?, _ d: Int = 3) -> String { rel ? n(v, d) : "unavailable" }
                let d = t.speed?.diagnostics
                let error: String = t.isValid ? "none" : (t.validity?.reason?.rawValue ?? "endpointFailure")
                let ident: [String] = [t.nodeID, "\(t.round)", "\(t.attempt ?? 1)", t.direction.rawValue, t.method, b(t.isValid), error,
                                       b(t.loadValid), "\(t.bytes)"]
                let rates: [String] = [n(m?.duration, 2), n(m?.averageMbps), sw(m?.medianMbps), sw(m?.p10Mbps), sw(m?.p95Mbps),
                                       sw(m?.minimumMbps), sw(m?.peakMbps)]
                let stabilityText: String = rel ? n(m?.stability.score, 1) : "unavailable"
                let window: String = m?.windowSamples.map { String($0) } ?? "null"
                let stab: [String] = [stabilityText, m?.stabilityUnavailableReason ?? "", window, b(m?.samplingArtifactDetected ?? false)]
                let loadedMedian: String = t.loadValid ? n(t.loadedLatency?.rtt?.median) : "unavailable"
                let loadedP95: String = t.loadValid ? n(t.loadedLatency?.rtt?.p95) : "unavailable"
                let counts: [String: Int] = d?.statusCounts ?? [:]
                let statusText: String = counts.keys.sorted().map { "\($0):\(counts[$0] ?? 0)" }.joined(separator: "|")
                let tiny: String = d.map { "\($0.tinyResponses)" } ?? ""
                let perStream: String = (d?.perStreamBytes ?? []).map { String($0) }.joined(separator: "|")
                let source: String = t.speed?.measurementSource ?? "clientCounters"
                let confirmed: String = n(t.speed?.serverConfirmed?.averageMbps)
                let row: [String] = ident + rates + stab + [loadedMedian, loadedP95, statusText, tiny, perStream, source, confirmed]
                o.append(row.joined(separator: ","))
            }
            let invalid = st.invalidTransfers()
            if !invalid.isEmpty {
                sec("stress_invalid_transfers")
                for t in invalid {
                    kv("transfer.\(t.nodeID).round\(t.round).\(t.direction.rawValue).attempt\(t.attempt ?? 1)",
                       "error=\(t.validity?.reason?.rawValue ?? "endpointFailure") detail=\((t.validity?.detail ?? t.error ?? "").replacingOccurrences(of: "\n", with: " ")) excluded_from=throughput_aggregate,degradation,cross_provider_variance,stability,bufferbloat,stress_score,root_cause")
                }
            }
            for agg in [st.downloadAggregate, st.uploadAggregate].compactMap({ $0 }) {
                sec("stress_cross_provider_\(agg.direction.rawValue)")
                kv("nodes", agg.values.map { "\($0.nodeID)(\($0.provider.rawValue))=\(Fmt.d($0.mbps, 2))" }.joined(separator: ","))
                o.append("node_id,role,method,stream_count,transport_protocol,mbps")
                for v in agg.values {
                    o.append([v.nodeID, v.nodeID == st.primaryNodeID ? "primary" : "validation", v.method ?? "unknown",
                              v.streamCount.map(String.init) ?? "unknown", v.transportProtocol ?? "unknown", n(v.mbps, 2)].joined(separator: ","))
                }
                kv("comparison_method_equivalent", b(agg.methodEquivalent))
                kv("headline_scope", st.headlineScope(agg.direction)); kv("primary_node", st.primaryNodeID ?? "null")
                kv("headline_mbps", n(st.headlineMbps(agg.direction)))
                kv("validation_nodes", agg.values.filter { $0.nodeID != st.primaryNodeID }.map(\.nodeID).joined(separator: ","))
                kv("min_mbps", n(agg.minMbps)); kv("max_mbps", n(agg.maxMbps))
                if agg.comparable {
                    kv("mean_mbps", n(agg.meanMbps)); kv("median_mbps", n(agg.medianMbps))
                    kv("p10_mbps", n(agg.p10Mbps)); kv("p95_mbps", n(agg.p95Mbps)); kv("inter_server_variance_mbps2", n(agg.variance))
                    kv("coefficient_of_variation", n(agg.coefficientOfVariation, 4)); kv("large_cross_provider_throughput_variance", b(agg.largeVariance))
                    kv("cross_provider_consistent", b(agg.isConsistent))
                } else {
                    for k in ["mean_mbps", "median_mbps", "p10_mbps", "p95_mbps", "inter_server_variance_mbps2", "coefficient_of_variation"] { kv(k, "not_comparable") }
                    kv("large_cross_provider_throughput_variance", "not_comparable"); kv("cross_provider_consistent", "not_comparable")
                    kv("observed_range_mbps", "\(n(agg.minMbps, 2))-\(n(agg.maxMbps, 2))")
                    o.append("# Methods differ (protocol / stream count): values are a method-dependent observed range, not a provider comparison; not averaged into the headline.")
                }
            }
            sec("stress_loss_probes")
            o.append("probe_id,name,target,method,pps,role,counts_for_loss_verdict,sent,received,loss_percent,median_ms,p95_ms,jitter_ms")
            for p in [st.stressProbe].compactMap({ $0 }) + st.controlProbes {
                o.append([p.id, p.isStressProbe ? "High-rate ICMP stress probe" : p.name, p.target, p.method, n(p.packetsPerSecond, 0),
                          p.isStressProbe ? "stress" : "control", b(!p.isStressProbe && p.isPacketLossProbe), "\(p.sent)", "\(p.statistics.received)", n(p.lossPercent),
                          n(p.statistics.rtt?.median), n(p.statistics.rtt?.p95), n(p.statistics.rtt?.jitter)].joined(separator: ","))
            }
            let lc = st.lossConfirmation
            kv("loss_verdict", lc.verdict.rawValue); kv("stress_loss_percent", n(lc.stressLossPercent)); kv("confirmed_loss_percent_control_median", n(lc.confirmedLossPercent))
            kv("valid_controls", "\(lc.validControlCount)"); kv("lossy_controls", "\(lc.lossyControlCount)")
            kv("affected_targets", (lc.affectedTargets ?? []).joined(separator: ",")); kv("clean_targets", (lc.cleanTargets ?? []).joined(separator: ","))
            kv("loss_verdict_values", "confirmedGeneralPacketLoss|endpointSpecificLossObserved|possibleICMPRateLimiting|noConfirmedGeneralPacketLoss|inconclusive")
            // Two measurement groups, never subtracted across: the reference endpoint (primary
            // speed server's own probe) and the independent bufferbloat control (fixed target).
            let refProbe = st.referenceProbe
            sec("stress_latency_recovery")
            o.append("# Reference endpoint latency only (comparison_group_id below). Loaded values probe the reference endpoint while ANY node is loaded;")
            o.append("# they are not the bufferbloat measure. Idle-vs-loaded deltas are only in [stress_bufferbloat_comparison] (same target + protocol + method).")
            kv("reference_probe_target", refProbe?.target ?? "unknown"); kv("reference_probe_method", refProbe?.method ?? "unknown")
            kv("reference_probe_protocol", refProbe?.protocolName ?? "unknown")
            kv("comparison_group_id", refProbe?.comparisonGroupID ?? "unknown")
            kv("reference_preload_median_ms", n(st.preLoadLatency?.rtt?.median)); kv("reference_preload_p95_ms", n(st.preLoadLatency?.rtt?.p95))
            kv("reference_preload_jitter_ms", n(st.preLoadLatency?.rtt?.jitter))
            for d in TransferDirection.allCases {
                let valid = !st.loadValidTransfers(d).isEmpty
                kv("\(d.rawValue)_load_valid", b(valid))
                kv("transfer_endpoint_loaded_\(d.rawValue)_median_ms", valid ? n(LatencyStatistics.compute(from: st.pooledLoadedSamples(d)).rtt?.median ?? st.loadedLatencyMs(d)) : "unavailable")
            }
            for (i, post) in st.postLoadLatency.enumerated() {
                kv("reference_post_load_round_\(i + 1)_median_ms", n(post.rtt?.median)); kv("reference_post_load_round_\(i + 1)_p95_ms", n(post.rtt?.p95))
            }
            kv("reference_post_load_recovery_delta_ms", n(st.recoveryDeltaMs))
            kv("throughput_degradation_first_to_last_round_percent", n(st.throughputDegradationPercent))
            kv("renamed_keys", "pre_load_median_ms>reference_preload_median_ms,pre_load_p95_ms>reference_preload_p95_ms,pre_load_jitter_ms>reference_preload_jitter_ms,loaded_<dir>_median_ms>transfer_endpoint_loaded_<dir>_median_ms,<dir>_loaded_latency_increase_ms>control_<dir>_increase_ms,loaded_latency_inflation_ms>control_max_increase_ms,post_load_round_N_*>reference_post_load_round_N_*,post_load_recovery_delta_ms>reference_post_load_recovery_delta_ms")

            sec("stress_bufferbloat_comparison")
            o.append("# The only idle-vs-loaded pairs in this export that may be subtracted: same target + protocol + method (comparison_group_id).")
            let comparisons = TransferDirection.allCases.compactMap { st.bufferbloatComparison($0) }
            let fromControl = comparisons.first?.source == "independentControlProbe"
            let pre = fromControl ? "control" : "reference_limited"
            if let first = comparisons.first {
                kv("comparison_source", first.source); kv("comparison_group_id", first.probe.comparisonGroupID)
                kv("probe_target", first.probe.target); kv("probe_method", first.probe.method); kv("probe_protocol", first.probe.protocolName)
                kv("\(pre)_idle_median_ms", n(first.idleMedianMs))
            } else {
                kv("comparison_source", "unavailable")
            }
            for d in TransferDirection.allCases {
                if let c = comparisons.first(where: { $0.direction == d }) {
                    kv("\(pre)_\(d.rawValue)_loaded_median_ms", n(c.loadedMedianMs)); kv("\(pre)_\(d.rawValue)_increase_ms", n(c.increaseMs))
                } else {
                    kv("\(pre)_\(d.rawValue)_increase_ms", "unavailable")
                    kv("\(d.rawValue)_grade", "unavailable"); kv("\(d.rawValue)_grade_reason", "insufficientLoad")
                }
            }
            kv("\(pre)_max_increase_ms", n(st.bufferbloatMs)); kv("queue_location", "unknown")
            for c in comparisons {
                let p = "\(c.direction.rawValue)_comparison"
                kv("\(p).source", c.source); kv("\(p).probe_target", c.probe.target); kv("\(p).probe_method", c.probe.method)
                kv("\(p).probe_protocol", c.probe.protocolName); kv("\(p).probe_ip_family", c.probe.ipFamily)
                kv("\(p).comparison_group_id", c.probe.comparisonGroupID)
                kv("\(p).idle_sample_count", "\(c.idleSampleCount)"); kv("\(p).loaded_sample_count", "\(c.loadedSampleCount)")
                kv("\(p).idle_median_ms", n(c.idleMedianMs)); kv("\(p).loaded_median_ms", n(c.loadedMedianMs)); kv("\(p).increase_ms", n(c.increaseMs))
                kv("\(p).comparison_target_same", b(c.comparisonTargetSame)); kv("\(p).comparison_method_same", b(c.comparisonMethodSame))
                kv("\(p).comparison_quality", c.quality.rawValue); kv("\(p).note", c.note)
            }
        }

        let net = r.network
        sec("environment")
        kv("status", net.status.rawValue); kv("interface", net.primaryInterface.rawValue); kv("network_class", NetworkClass(snapshot: net).rawValue)
        kv("available_interfaces", NetworkSnapshot.deduplicated(net.availableInterfaces).map(\.rawValue).joined(separator: ","))
        kv("is_expensive", b(net.isExpensive)); kv("is_constrained_low_data_mode", b(net.isConstrained))
        kv("supports_ipv4", b(net.supportsIPv4)); kv("supports_ipv6", b(net.supportsIPv6)); kv("supports_dns", b(net.supportsDNS))
        kv("vpn_state_heuristic", net.vpn.state.rawValue); kv("vpn_interfaces", net.vpn.interfaces.joined(separator: ","))
        kv("public_ipv4", avail(net.publicIPv4) { $0 }); kv("public_ipv6", avail(net.publicIPv6) { $0 })
        kv("local_addresses", net.localAddresses.map { "\($0.interfaceName)=\($0.address)" }.joined(separator: ","))
        if let c = net.cellular {
            kv("cellular_radio_access_technology", avail(c.radioTechnology) { $0.rawValue })
            kv("cellular_rsrp_dbm", avail(c.signal.rsrp) { n($0, 0) }); kv("cellular_rsrq_db", avail(c.signal.rsrq) { n($0, 0) })
            kv("cellular_sinr_db", avail(c.signal.sinr) { n($0, 0) }); kv("cellular_band", avail(c.signal.band) { $0 })
            kv("cellular_cell_id", avail(c.signal.cellID) { $0 }); kv("cellular_carrier", avail(c.carrierName) { $0 })
            o.append("# iOS does not expose RSRP / RSRQ / SINR / NR band / cell ID to App Store apps.")
        }
        if let w = net.wifi { kv("wifi_ssid", avail(w.ssid) { $0 }); kv("wifi_rssi_dbm", avail(w.rssi) { n($0, 0) }) }

        sec("server")
        if let s = r.server {
            kv("id", s.id); kv("name", s.name); kv("location", s.location); kv("kind", s.kind.rawValue); kv("base_url", s.baseURL.absoluteString)
            kv("udp_echo_port", s.udpEchoPort.map(String.init) ?? "null"); kv("icmp_host", s.icmpHost ?? "null")
        }
        if let i = r.serverInfo {
            kv("server_seen_client_ip", i.clientIP); kv("server_seen_ip_family", i.clientIPFamily); kv("server_http_protocol", i.httpProtocol)
            kv("server_supports_http3", b(i.supportsHTTP3))
        }
        if let h = r.serverHealth { kv("health_reachable", b(h.reachable)); kv("health_ok", b(h.healthy)); kv("health_response_ms", n(h.responseMs)) }

        sec("scores_0_100")
        kv("overall", r.scores.overall.map(String.init) ?? "null"); kv("gaming", r.scores.gaming.map(String.init) ?? "null")
        kv("streaming", r.scores.streaming.map(String.init) ?? "null"); kv("voice", r.scores.voice.map(String.init) ?? "null")
        kv("upload", r.scores.upload.map(String.init) ?? "null")

        if let st = r.stress {
            // Stress: generic sections are the aggregate of valid transfers, never one node's last transfer.
            for agg in [(TransferDirection.download, st.downloadAggregate), (TransferDirection.upload, st.uploadAggregate)] {
                sec(agg.0.rawValue)
                kv("scope", "stress_aggregate_of_valid_transfers (per-node / per-round detail: [stress_transfers_per_server])")
                kv("valid_transfers", "\(st.transfers(agg.0).count)"); kv("invalid_transfers", "\(st.invalidTransfers().filter { $0.direction == agg.0 }.count)")
                kv("headline_scope", st.headlineScope(agg.0)); kv("headline_mbps", n(st.headlineMbps(agg.0)))
                let comparable = agg.1?.comparable ?? true
                kv("median_across_nodes_mbps", comparable ? n(agg.1?.medianMbps) : "not_comparable")
                kv("mean_across_nodes_mbps", comparable ? n(agg.1?.meanMbps) : "not_comparable")
                kv("max_node_mbps", n(agg.1?.maxMbps)); kv("min_node_mbps", n(agg.1?.minMbps))
                if let score = st.stability(agg.0) { kv("stability_score_0_100", n(score, 1)) }
                else { kv("stability", "unavailable"); kv("stability_reason", st.stabilityUnavailableReason(agg.0) ?? "unavailable") }
            }
            latency("latency_idle", r.idleLatency, .idle)
            if let ctl = st.controlIdleStatistics, let probe = st.controlProbe {
                // The comparable idle baseline for the loaded sections when they come from the control probe.
                sec("bufferbloat_control_idle")
                kv("target", probe.target); kv("probe_method", probe.method); kv("probe_protocol", probe.protocolName)
                kv("probe_ip_family", probe.ipFamily); kv("measurement_source", "independentControlProbe")
                kv("comparison_group", LatencyProvenance.bufferbloatControlGroup); kv("comparison_group_id", probe.comparisonGroupID)
                kv("sample_count", "\(ctl.sent)"); kv("received", "\(ctl.received)")
                kv("median_ms", n(ctl.rtt?.median)); kv("p95_ms", n(ctl.rtt?.p95)); kv("jitter_ms", n(ctl.rtt?.jitter))
                kv("loss_percent", n(ctl.loss.lossPercent))
            }
            latency("latency_download_loaded", r.downloadLoadedLatency, .downloadLoaded)
            kv("scope", "pooled samples of load-valid download transfers (\(st.loadValidTransfers(.download).count))")
            kv("load_valid", b(!st.loadValidTransfers(.download).isEmpty))
            latency("latency_upload_loaded", r.uploadLoadedLatency, .uploadLoaded)
            kv("scope", "pooled samples of load-valid upload transfers (\(st.loadValidTransfers(.upload).count))")
            kv("load_valid", b(!st.loadValidTransfers(.upload).isEmpty))
        } else {
            speed("download", r.download)
            speed("upload", r.upload)
            latency("latency_idle", r.idleLatency, .idle)
            latency("latency_download_loaded", r.downloadLoadedLatency, .downloadLoaded)
            latency("latency_upload_loaded", r.uploadLoadedLatency, .uploadLoaded)
        }
        latency("packet_loss_probe", r.packetLoss)
        if let m = r.packetLossMethod { kv("method", m.replacingOccurrences(of: "，", with: "; ").replacingOccurrences(of: "個封包", with: "packets").replacingOccurrences(of: "每", with: "every ")) }

        if let bb = r.bufferbloat {
            sec("bufferbloat")
            kv("grade", bb.grade.rawValue); kv("idle_median_ms", n(bb.idleMedianMs))
            if let p = r.latencyProvenance(.downloadLoaded) ?? r.latencyProvenance(.uploadLoaded) {
                let control = p.comparisonGroup == LatencyProvenance.bufferbloatControlGroup
                kv("idle_source", control ? "bufferbloat_control_idle" : "latency_idle")
                kv("loaded_source", "latency_download_loaded,latency_upload_loaded"); kv("probe_target", p.probe.target); kv("probe_method", p.probe.method)
            }
            kv("download_loaded_median_ms", n(bb.downloadLoadedMedianMs)); kv("download_increase_ms", n(bb.downloadIncreaseMs))
            kv("download_grade", bb.downloadGrade?.rawValue ?? "unavailable")
            if bb.downloadGrade == nil { kv("download_grade_reason", "insufficientLoad") }
            kv("upload_loaded_median_ms", n(bb.uploadLoadedMedianMs)); kv("upload_increase_ms", n(bb.uploadIncreaseMs))
            kv("upload_grade", bb.uploadGrade?.rawValue ?? "unavailable")
            if bb.uploadGrade == nil { kv("upload_grade_reason", "insufficientLoad") }
            if let st = r.stress {
                let q = TransferDirection.allCases.compactMap { st.bufferbloatComparison($0)?.quality }
                kv("comparison_quality", q.isEmpty ? "unavailable" : (q.contains(.limited) ? "limited" : "full"))
                if q.contains(.limited) { o.append("# comparison_quality=limited: idle / loaded not from one independent fixed control probe; indicative only, not a high-confidence grade.") }
            }
            kv("interpretation", "loadedLatencyInflation / networkPathQueueing")
            kv("queue_location", "unknown")
            kv("possible_queue_locations", "device_or_modem_queue,radio_scheduler,access_network,carrier_or_core_network,router,remote_path")
        }

        if let g = r.gaming {
            sec("quality_gaming")
            kv("packets_per_second", n(g.packetsPerSecond, 0)); kv("latency_spikes", "\(g.spikes.count)")
            for v in g.verdicts { kv("genre.\(v.genre.rawValue)", "\(v.verdict.rawValue) limiting=\(v.limitingFactors.count)") }
        }
        if let v = r.voice {
            sec("quality_voice_emodel")
            kv("r_factor", n(v.rFactor, 2)); kv("mos", n(v.mos, 3)); kv("rating", v.rating.rawValue); kv("effective_latency_ms", n(v.effectiveLatencyMs))
            kv("stream", "\(n(v.packetsPerSecond, 0)) pps x \(v.payloadBytes) B")
        }
        if let st = r.streaming {
            sec("quality_streaming")
            kv("sustained_p10_mbps", n(st.sustainedMbps)); kv("max_supported_tier", st.maxSupportedTier?.name ?? "none")
            kv("estimated_startup_ms", n(st.estimatedStartupMs))
            for t in st.tiers { kv("tier.\(t.tier.requiredMbps)mbps", "\(t.supported) headroom=\(n(t.headroom, 2))") }
        }
        if let ob = r.obs {
            sec("quality_obs_upload")
            kv("sustained_p10_mbps", n(ob.sustainedMbps)); kv("recommended_bitrate_kbps", n(ob.recommendedBitrateKbps, 0))
            for p in ob.presets { kv("preset.\(p.preset.name.split(separator: " ").first ?? "")", "\(p.verdict.rawValue) bitrate_kbps=\(n(p.preset.bitrateKbps, 0))") }
        }

        if let d = r.dns {
            sec("dns")
            kv("domains", d.domains.joined(separator: ","))
            for res in d.ranked {
                kv("resolver.\(res.resolver.id)", "transport=\(res.resolver.transport.rawValue) endpoint=\(res.resolver.endpoint) median_ms=\(n(res.statistics.rtt?.median)) p95_ms=\(n(res.statistics.rtt?.p95)) failures=\(res.statistics.loss.lost)/\(res.statistics.sent)")
                o.append("  samples_ms=" + res.samples.map { $0.rttMs.map { Fmt.d($0, 2) } ?? "fail" }.joined(separator: ","))
            }
            for f in DNSAnalyzer.analyze(d) { kv("dns_finding", "\(f.kind.rawValue) subject=\(f.subject)") }
            kv("dns_outlier_domains", DNSAnalyzer.outlierDomains(d).joined(separator: ","))
            kv("dns_outlier_method", "per-resolver median/MAD: latency >= max(median + max(3.5 x 1.4826 x MAD, 50 ms), 2 x median), validated against the same domain on the other resolvers")
            for out in DNSAnalyzer.outliers(d) {
                let key = "dns_outlier.\(out.domain).\(out.resolverID)"
                kv("\(key).kind", out.kind.rawValue); kv("\(key).latency_ms", n(out.latencyMs, 2))
                kv("\(key).outlier_reason", out.reason)
                kv("\(key).comparison_resolvers", out.comparisonResolvers.keys.sorted().map { id -> String in
                    let v: Double? = out.comparisonResolvers[id] ?? nil
                    return "\(id):" + (v.map { Fmt.d($0, 2) } ?? "fail")
                }.joined(separator: ","))
                kv("\(key).confidence_band", out.confidenceBand.rawValue)
            }
            if let ex = DNSAnalyzer.systemStatsExcludingOutliers(d)?.rtt {
                kv("system_median_ms_excluding_outlier_domains", n(ex.median)); kv("system_p95_ms_excluding_outlier_domains", n(ex.p95))
            }
            sec("dns_lookups")
            o.append("domain,transport,resolver,latency_ms,status,cached_or_unknown")
            for row in DNSAnalyzer.rows(d) {
                o.append([row.domain, row.transport.rawValue, row.resolverID, row.latencyMs.map { Fmt.d($0, 2) } ?? "", row.status, row.cached].joined(separator: ","))
            }
        }
        if let p = r.protocolProbe {
            sec("protocols")
            if let h = p.http {
                kv("http_negotiated", h.negotiatedProtocol.rawValue); kv("http_dns_ms", n(h.dnsMs)); kv("http_tcp_connect_ms", n(h.tcpConnectMs))
                kv("http_tls_ms", n(h.tlsMs)); kv("http_ttfb_ms", n(h.ttfbMs)); kv("http_total_ms", n(h.totalMs)); kv("http_tls_version", h.tlsVersion ?? "null")
                kv("http_remote_address", h.remoteAddress ?? "null"); kv("http_status", h.statusCode.map(String.init) ?? "null")
            }
            kv("http3_attempt_negotiated", p.http3Attempt?.negotiatedProtocol.rawValue ?? "null")
            kv("quic_assessment", (p.quicAssessment ?? .notTested).rawValue)
            for q in p.quicProbes ?? [] {
                kv("quic.\(q.host)", "handshake_ms=\(n(q.handshakeMs)) failure=\(q.failure?.rawValue ?? "none") tcp443=\(b(q.tcpReachable))")
                kv("quic_reachable.\(q.host)", b(q.handshakeMs != nil && q.failure == nil))
            }
            let probes = p.quicProbes ?? []
            kv("general_quic_reachable", probes.isEmpty ? "notTested" : b(probes.contains { $0.handshakeMs != nil && $0.failure == nil }))
            if let h3 = p.http3Attempt {
                let proto = h3.negotiatedProtocol
                kv("http3_status.\(p.host)", proto == .http3 ? "negotiated" : "fallback:\(proto.rawValue)")
            } else {
                kv("http3_status.\(p.host)", "notTested")
            }
            kv("strict_http3_verification", "http3_status is per endpoint; a fallback to h2 only means this endpoint / attempt did not negotiate HTTP/3 (Alt-Svc cache, server choice), not that HTTP/3 is unavailable on the network")
            kv("tcp_connect_median_ms", n(p.tcpConnect?.rtt?.median)); kv("tcp_tls_ready_median_ms", n(p.tlsConnect?.rtt?.median))
            kv("http_warm_latency_median_ms", n(p.httpLatency?.rtt?.median))
            kv("ipv4_tcp_connect_ms", avail(p.ipv4Reachable) { n($0) }); kv("ipv6_tcp_connect_ms", avail(p.ipv6Reachable) { n($0) })
        }
        if let f = r.ipFamilyComparison {
            sec("ip_families")
            kv("target", f.target); kv("method", f.method.rawValue)
            kv("ipv4", f.ipv4Error != nil ? "unavailable" : "median_ms=\(n(f.ipv4?.rtt?.median)) loss_percent=\(n(f.ipv4?.loss.lossPercent)) jitter_ms=\(n(f.ipv4?.rtt?.jitter))")
            kv("ipv6", f.ipv6Error != nil ? "unavailable" : "median_ms=\(n(f.ipv6?.rtt?.median)) loss_percent=\(n(f.ipv6?.loss.lossPercent)) jitter_ms=\(n(f.ipv6?.rtt?.jitter))")
        }
        if let checks = r.crossValidation {
            sec("cross_validation_endpoints")
            for c in checks {
                kv("endpoint.\(c.id)", c.error != nil ? "unavailable primary=\(b(c.isPrimary))" :
                    "method=\(c.method.rawValue) primary=\(b(c.isPrimary)) median_ms=\(n(c.statistics?.rtt?.median)) p95_ms=\(n(c.statistics?.rtt?.p95)) jitter_ms=\(n(c.statistics?.rtt?.jitter)) loss_percent=\(n(c.statistics?.loss.lossPercent)) sent=\(c.statistics?.sent ?? 0)")
            }
        }
        if let runs = r.serverRuns {
            sec("multi_server")
            for run in runs {
                let lat = run.packetLoss ?? run.idleLatency
                kv("server.\(run.server.id)", "median_ms=\(n(lat?.rtt?.median)) jitter_ms=\(n(lat?.rtt?.jitter)) loss_percent=\(n(lat?.loss.lossPercent)) download_mbps=\(n(run.download?.summary.averageMbps)) download_median_mbps=\(n(run.download?.summary.medianMbps)) upload_mbps=\(n(run.upload?.summary.averageMbps)) upload_median_mbps=\(n(run.upload?.summary.medianMbps)) error=\(run.error == nil ? "none" : "yes")")
            }
        }
        if let ifs = r.interfaceCompare {
            sec("interface_compare")
            for i in ifs { kv("interface.\(i.interface.rawValue)", i.error != nil ? "unavailable" : "tcp_median_ms=\(n(i.tcpConnect?.rtt?.median)) loss_percent=\(n(i.tcpConnect?.loss.lossPercent))") }
        }
        if let mtu = r.mtu {
            sec("mtu")
            kv("target", mtu.target); kv("path_mtu_bytes", mtu.pathMTU.map(String.init) ?? "null"); kv("scope", "tested IPv4 path only")
            kv("observed_path_mtu_ipv4_bytes", mtu.pathMTU.map(String.init) ?? "null")
            let failedBelow = mtu.pathMTU.map { m in mtu.probes.contains { !$0.succeeded && $0.packetSize <= m } } ?? false
            kv("mtu_blackhole_evidence", mtu.pathMTU == nil ? "inconclusive" : b(failedBelow))
            kv("method", mtu.method)
            kv("probes", mtu.probes.map { "\($0.packetSize):\($0.succeeded ? "ok" : "fail")" }.joined(separator: ","))
        }
        if let tr = r.traceroute {
            sec("traceroute")
            kv("target", "\(tr.target) (\(tr.resolvedAddress))"); kv("reached", b(tr.reachedDestination))
            for h in tr.hops {
                o.append("hop \(h.ttl) \(h.address ?? "*") \(h.hostname ?? "-") rtt_ms=" + h.rttsMs.map { $0.map { Fmt.d($0, 2) } ?? "*" }.joined(separator: ","))
            }
            let ta = TracerouteAnalyzer.analyze(tr.hops)
            kv("analysis_sufficient", b(ta.sufficient)); kv("analysis_threshold_ms", n(TracerouteAnalyzer.thresholdMs, 0))
            kv("persistent_latency_steps", ta.steps.map { "\($0.fromTTL)->\($0.toTTL):+\(Fmt.d($0.increaseMs, 1))ms" }.joined(separator: ","))
            kv("isolated_elevated_hops", ta.isolatedHighHops.map { "\($0.ttl):+\(Fmt.d($0.excessMs, 1))ms" }.joined(separator: ","))
            if !ta.isolatedHighHops.isEmpty { kv("isolated_elevated_hops_interpretation", "icmpDeprioritization (later hops not elevated; not path latency)") }
        }
        if let mon = r.monitoring {
            latency("monitoring", mon.statistics)
            let spikeSummary = r.monitoringSpikeSummary
            kv("target", mon.target); kv("interval_s", n(mon.intervalSeconds, 2))
            kv("spikes", "\(max(mon.spikes.count, spikeSummary?.count ?? 0))"); kv("drops", "\(mon.drops.count)")
            kv("engine_spike_events", "\(mon.spikes.count)")
            if let sp = spikeSummary {
                kv("spike_threshold_ms", n(sp.thresholdMs)); kv("spike_count", "\(sp.count)"); kv("worst_spike_ms", n(sp.worstMs))
                kv("spike_offsets", sp.offsets.map { Fmt.d($0, 2) }.joined(separator: ","))
                kv("spike_definition", sp.definition); kv("spike_baseline_source", sp.baselineSource)
            }
            for sp in mon.spikes { o.append("spike offset_s=\(n(sp.offset, 2)) rtt_ms=\(n(sp.rttMs)) baseline_ms=\(n(sp.baselineMs)) threshold_ms=\(n(sp.thresholdMs))") }
            for d in mon.drops { o.append("drop start_s=\(n(d.startOffset, 2)) duration_s=\(n(d.duration, 2)) lost_probes=\(d.lostProbes)") }
            for pc in mon.pathChanges { o.append("path_change offset_s=\(n(pc.offset, 2)) interface=\(pc.interface.rawValue) status=\(pc.status.rawValue)") }
        }

        sec("findings")
        for f in r.findings {
            kv(f.code.rawValue, f.severity.rawValue)
            if f.code == .http3FallbackObserved, let p = r.protocolProbe {
                kv("\(f.code.rawValue).endpoint", p.host)
                kv("\(f.code.rawValue).fallback", p.http3Attempt?.negotiatedProtocol.rawValue ?? p.http?.negotiatedProtocol.rawValue ?? "unknown")
                kv("\(f.code.rawValue).scope", "endpointSpecific (general HTTP/3 unavailability requires >= 2 independent strict HTTP/3 endpoints all failing)")
            }
        }

        if let a = analysis {
            sec("root_cause_evidence")
            o.append("code,kind,dimension,value,unit,claim_type")
            for e in a.evidence.evidence {
                o.append("\(e.code.rawValue),\(e.kind.rawValue),\(e.dimension.rawValue),\(e.value.map { n($0) } ?? ""),\(e.unit ?? ""),\(e.kind.claimType)")
            }
            kv("measured_dimensions", a.evidence.measuredDimensions.map(\.rawValue).sorted().joined(separator: ","))
            kv("attempted_dimensions", a.evidence.attemptedDimensions.map(\.rawValue).sorted().joined(separator: ","))
            sec("root_cause_hypotheses")
            o.append("cause,status,evidence_score_0_100,confidence_band,claim_type,layer,supporting,contradicting,ruling_out,missing_dimensions")
            for h in a.hypotheses {
                o.append([h.cause.rawValue, h.likelihood.rawValue, "\(h.evidenceScore)", h.confidenceBand.rawValue, "heuristic_inference", h.layer.rawValue,
                          h.supportingEvidence.map(\.code.rawValue).joined(separator: "|"),
                          h.contradictingEvidence.map(\.code.rawValue).joined(separator: "|"),
                          h.rulingOutEvidence.map(\.code.rawValue).joined(separator: "|"),
                          h.missingDimensions.map(\.rawValue).joined(separator: "|")].joined(separator: ","))
            }
            kv("most_likely", a.mostLikely.map { "\($0.cause.rawValue) (\($0.likelihood.rawValue), evidence_score_0_100=\($0.evidenceScore), confidence_band=\($0.confidenceBand.rawValue))" } ?? "none")
            kv("score_semantics", "evidence_score_0_100 is uncalibrated evidence strength, not a probability")
            if let g = a.hypotheses.first(where: { $0.cause == .serverOrRouteSpecific }) {
                kv("generalServerOrRouteIssue", "\(g.likelihood.rawValue) (alias of serverOrRouteSpecific)")
            }
            // Scoped to the probed address + method: 1.1.1.1 over ICMP says nothing about
            // speed.cloudflare.com over HTTPS, even though both belong to one provider.
            if let e = a.hypotheses.first(where: { $0.cause == .endpointSpecificPathIssue }) {
                for target in r.stress?.lossConfirmation.affectedTargets ?? [] {
                    kv("endpointSpecificPathIssue.\(target)", "\(e.likelihood.rawValue) (scope=this address + ICMP only; not inferred for other services of the same provider)")
                }
            }
            if let i = a.hypotheses.first(where: { $0.cause == .icmpRateLimitingOrPolicy }) {
                kv("icmpRateLimitingOrPolicy", "\(i.likelihood.rawValue) (separate from server / route behaviour)")
            }
            kv("hypothesis_separation", "serverOrRouteSpecific=test-server behaviour (needs same-protocol / server-level reproduction for > medium); endpointSpecificPathIssue=route to one probed address; icmpRateLimitingOrPolicy=ICMP handling only")
            kv("recommended_next_tests", a.recommendedTests.map(\.test.rawValue).joined(separator: ","))
        }

        // Every baseline the analyzer used, so matchesBaseline / deviatesFromBaseline are traceable.
        sec("baseline")
        let comparison = analysis?.evidence.baselineComparisons.first { $0.testID == r.id }
        if let c = comparison, let bl = c.baseline {
            kv("available", "true"); kv("network_type", bl.key.network.rawValue)
            kv("radio_type", bl.key.network == .nr || bl.key.network == .lte ? bl.key.network.rawValue : "n/a")
            kv("sample_count", "\(bl.sampleCount)"); kv("baseline_age_days", n(bl.ageDays(at: r.date), 1))
            kv("baseline_oldest", bl.oldestDate.map { iso.string(from: $0) } ?? "unknown")
            let rows: [(String, BaselineMetric)] = [("download_median_mbps", .downloadMbps), ("upload_median_mbps", .uploadMbps),
                                                     ("latency_median_ms", .latencyMs), ("jitter_median_ms", .jitterMs),
                                                     ("loss_median_percent", .lossPercent)]
            for (key, metric) in rows { kv(key, n(bl.metric(metric)?.median)) }
            kv("matching_criteria", bl.matchingCriteria); kv("confidence_band", bl.confidenceBand.rawValue)
            kv("compared_metrics", (c.comparedMetrics ?? []).map(\.rawValue).joined(separator: ","))
            kv("sufficient_for_match", b(c.sufficientForMatch))
            kv("anomalies", c.anomalies.map { "\($0.metric.rawValue):z=\(Fmt.d($0.robustZ, 1))" }.joined(separator: ","))
        } else {
            kv("available", "false")
            kv("reason", analysis == nil ? "no analysis in this export" : (comparison == nil ? "no baseline store used" : "not enough history for this network type"))
        }

        // Raw samples last (largest part).
        speedSamples("raw.download_samples_100ms", r.download)
        speedSamples("raw.upload_samples_100ms", r.upload)
        csvSamples("raw.idle_latency", r.idleSamples)
        csvSamples("raw.download_loaded_latency", r.downloadLoadedSamples)
        csvSamples("raw.upload_loaded_latency", r.uploadLoadedSamples)
        csvSamples("raw.packet_loss_probe", r.packetLossSamples)
        csvSamples("raw.monitoring", r.monitoring?.samples)
        if let st = r.stress {
            csvSamples("raw.stress.pre_load_latency", st.preLoadSamples)
            csvSamples("raw.stress.extended_monitoring", st.extendedMonitoringSamples)
            for (i, post) in st.postLoadSamples.enumerated() { csvSamples("raw.stress.post_load_round_\(i + 1)", post) }
            for p in [st.stressProbe].compactMap({ $0 }) + st.controlProbes { csvSamples("raw.stress.loss_probe.\(p.id)", p.samples) }
            for t in st.transfers {
                let tag = "raw.stress.\(t.nodeID).round\(t.round)\((t.attempt ?? 1) > 1 ? ".attempt\(t.attempt!)" : "").\(t.direction.rawValue)"
                speedSamples("\(tag)_samples_100ms", t.speed)
                csvSamples("\(tag)_loaded_latency", t.loadedSamples)
            }
        }
        for run in r.serverRuns ?? [] {
            speedSamples("raw.multi_server.\(run.server.id).download_samples_100ms", run.download)
            speedSamples("raw.multi_server.\(run.server.id).upload_samples_100ms", run.upload)
        }
        o.append("")
        o.append("# end of ChaiNet Raw Data Export v\(version)")
        let text = o.joined(separator: "\n")
        return privacy.redactsIPs ? IPRedactor.redact(text) : text
    }
}

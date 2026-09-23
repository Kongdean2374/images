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
}

public enum RawDataExporter {
    public static let schema = "chainet.raw-export"
    public static let version = 1

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
                                   result: r, analysis: analysis, privacy: privacy.summary)
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
        func latency(_ name: String, _ s: LatencyStatistics?) {
            sec(name)
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
        func speed(_ name: String, _ s: SpeedResult?) {
            sec(name)
            guard let s else { kv("measured", "false"); return }
            let m = s.summary
            kv("avg_mbps_time_weighted", n(m.averageMbps)); kv("peak_mbps", n(m.peakMbps)); kv("min_mbps", n(m.minimumMbps))
            kv("median_mbps", n(m.medianMbps)); kv("p95_mbps", n(m.p95Mbps)); kv("p10_mbps_sustained", n(m.p10Mbps))
            kv("stability_score_0_100", n(m.stability.score, 1)); kv("stability_cv", n(m.stability.coefficientOfVariation, 4))
            kv("drop_windows_below_50pct_median", "\(m.stability.dropCount)")
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

        sec("meta")
        kv("schema", schema); kv("generated_at", iso.string(from: Date())); kv("app_version", appVersion); kv("platform", platform)
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
            kv("http_streams_per_transfer", "\(st.plan.streams)"); kv("ndt7_streams_per_transfer", "1")
            kv("transfer_s_per_node_direction_round", n(st.plan.transferSeconds, 1))
            kv("stress_packet_rate_pps", n(st.plan.stressPacketsPerSecond, 0)); kv("control_packet_rate_pps", n(st.plan.controlPacketsPerSecond, 0))
            kv("total_download_bytes", "\(st.totalDownloadBytes)"); kv("total_upload_bytes", "\(st.totalUploadBytes)"); kv("total_bytes", "\(st.totalBytes)")
            kv("stress_score_0_100", st.score.map(String.init) ?? "null")
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
            o.append("node_id,round,direction,method,bytes,avg_mbps,median_mbps,p10_mbps,p95_mbps,min_mbps,peak_mbps,stability,window_samples,sampling_artifact,loaded_median_ms,loaded_p95_ms,error")
            for t in st.transfers {
                let m = t.speed?.summary
                o.append([t.nodeID, "\(t.round)", t.direction.rawValue, t.method, "\(t.bytes)", n(m?.averageMbps), n(m?.medianMbps), n(m?.p10Mbps),
                          n(m?.p95Mbps), n(m?.minimumMbps), n(m?.peakMbps), n(m?.stability.score, 1), m?.windowSamples.map(String.init) ?? "null",
                          b(m?.samplingArtifactDetected), n(t.loadedLatency?.rtt?.median), n(t.loadedLatency?.rtt?.p95),
                          t.error == nil ? "none" : "yes"].joined(separator: ","))
            }
            for agg in [st.downloadAggregate, st.uploadAggregate].compactMap({ $0 }) {
                sec("stress_cross_provider_\(agg.direction.rawValue)")
                kv("nodes", agg.values.map { "\($0.nodeID)(\($0.provider.rawValue))=\(Fmt.d($0.mbps, 2))" }.joined(separator: ","))
                kv("mean_mbps", n(agg.meanMbps)); kv("median_mbps", n(agg.medianMbps)); kv("min_mbps", n(agg.minMbps)); kv("max_mbps", n(agg.maxMbps))
                kv("p10_mbps", n(agg.p10Mbps)); kv("p95_mbps", n(agg.p95Mbps)); kv("inter_server_variance_mbps2", n(agg.variance))
                kv("coefficient_of_variation", n(agg.coefficientOfVariation, 4)); kv("large_cross_provider_throughput_variance", b(agg.largeVariance))
            }
            sec("stress_loss_probes")
            o.append("probe_id,name,target,method,pps,role,sent,received,loss_percent,median_ms,p95_ms,jitter_ms")
            for p in [st.stressProbe].compactMap({ $0 }) + st.controlProbes {
                o.append([p.id, p.isStressProbe ? "High-rate ICMP stress probe" : p.name, p.target, p.method, n(p.packetsPerSecond, 0),
                          p.isStressProbe ? "stress" : "control", "\(p.sent)", "\(p.statistics.received)", n(p.lossPercent),
                          n(p.statistics.rtt?.median), n(p.statistics.rtt?.p95), n(p.statistics.rtt?.jitter)].joined(separator: ","))
            }
            let lc = st.lossConfirmation
            kv("loss_verdict", lc.verdict.rawValue); kv("stress_loss_percent", n(lc.stressLossPercent)); kv("confirmed_loss_percent_control_median", n(lc.confirmedLossPercent))
            kv("valid_controls", "\(lc.validControlCount)"); kv("lossy_controls", "\(lc.lossyControlCount)")
            sec("stress_latency_recovery")
            kv("pre_load_median_ms", n(st.preLoadLatency?.rtt?.median)); kv("pre_load_p95_ms", n(st.preLoadLatency?.rtt?.p95))
            kv("pre_load_jitter_ms", n(st.preLoadLatency?.rtt?.jitter))
            kv("loaded_download_median_ms", n(st.loadedLatencyMs(.download))); kv("loaded_upload_median_ms", n(st.loadedLatencyMs(.upload)))
            kv("loaded_latency_inflation_ms", n(st.bufferbloatMs)); kv("queue_location", "unknown")
            for (i, post) in st.postLoadLatency.enumerated() {
                kv("post_load_round_\(i + 1)_median_ms", n(post.rtt?.median)); kv("post_load_round_\(i + 1)_p95_ms", n(post.rtt?.p95))
            }
            kv("post_load_recovery_delta_ms", n(st.recoveryDeltaMs)); kv("throughput_degradation_first_to_last_round_percent", n(st.throughputDegradationPercent))
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

        speed("download", r.download)
        speed("upload", r.upload)
        latency("latency_idle", r.idleLatency)
        latency("latency_download_loaded", r.downloadLoadedLatency)
        latency("latency_upload_loaded", r.uploadLoadedLatency)
        latency("packet_loss_probe", r.packetLoss)
        if let m = r.packetLossMethod { kv("method", m.replacingOccurrences(of: "，", with: "; ").replacingOccurrences(of: "個封包", with: "packets").replacingOccurrences(of: "每", with: "every ")) }

        if let bb = r.bufferbloat {
            sec("bufferbloat")
            kv("grade", bb.grade.rawValue); kv("idle_median_ms", n(bb.idleMedianMs))
            kv("download_loaded_median_ms", n(bb.downloadLoadedMedianMs)); kv("download_increase_ms", n(bb.downloadIncreaseMs)); kv("download_grade", bb.downloadGrade?.rawValue ?? "null")
            kv("upload_loaded_median_ms", n(bb.uploadLoadedMedianMs)); kv("upload_increase_ms", n(bb.uploadIncreaseMs)); kv("upload_grade", bb.uploadGrade?.rawValue ?? "null")
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
            }
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
            kv("probes", mtu.probes.map { "\($0.packetSize):\($0.succeeded ? "ok" : "fail")" }.joined(separator: ","))
        }
        if let tr = r.traceroute {
            sec("traceroute")
            kv("target", "\(tr.target) (\(tr.resolvedAddress))"); kv("reached", b(tr.reachedDestination))
            for h in tr.hops {
                o.append("hop \(h.ttl) \(h.address ?? "*") \(h.hostname ?? "-") rtt_ms=" + h.rttsMs.map { $0.map { Fmt.d($0, 2) } ?? "*" }.joined(separator: ","))
            }
        }
        if let mon = r.monitoring {
            latency("monitoring", mon.statistics)
            kv("target", mon.target); kv("interval_s", n(mon.intervalSeconds, 2)); kv("spikes", "\(mon.spikes.count)"); kv("drops", "\(mon.drops.count)")
            for sp in mon.spikes { o.append("spike offset_s=\(n(sp.offset, 2)) rtt_ms=\(n(sp.rttMs)) baseline_ms=\(n(sp.baselineMs)) threshold_ms=\(n(sp.thresholdMs))") }
            for d in mon.drops { o.append("drop start_s=\(n(d.startOffset, 2)) duration_s=\(n(d.duration, 2)) lost_probes=\(d.lostProbes)") }
            for pc in mon.pathChanges { o.append("path_change offset_s=\(n(pc.offset, 2)) interface=\(pc.interface.rawValue) status=\(pc.status.rawValue)") }
        }

        sec("findings")
        for f in r.findings { kv(f.code.rawValue, f.severity.rawValue) }

        if let a = analysis {
            sec("root_cause_evidence")
            o.append("code,kind,dimension,value,unit")
            for e in a.evidence.evidence {
                o.append("\(e.code.rawValue),\(e.kind.rawValue),\(e.dimension.rawValue),\(e.value.map { n($0) } ?? ""),\(e.unit ?? "")")
            }
            kv("measured_dimensions", a.evidence.measuredDimensions.map(\.rawValue).sorted().joined(separator: ","))
            kv("attempted_dimensions", a.evidence.attemptedDimensions.map(\.rawValue).sorted().joined(separator: ","))
            sec("root_cause_hypotheses")
            o.append("cause,status,confidence,layer,supporting,contradicting,ruling_out,missing_dimensions")
            for h in a.hypotheses {
                o.append([h.cause.rawValue, h.likelihood.rawValue, n(h.confidence), h.layer.rawValue,
                          h.supportingEvidence.map(\.code.rawValue).joined(separator: "|"),
                          h.contradictingEvidence.map(\.code.rawValue).joined(separator: "|"),
                          h.rulingOutEvidence.map(\.code.rawValue).joined(separator: "|"),
                          h.missingDimensions.map(\.rawValue).joined(separator: "|")].joined(separator: ","))
            }
            kv("most_likely", a.mostLikely.map { "\($0.cause.rawValue) (\($0.likelihood.rawValue), \(n($0.confidence)))" } ?? "none")
            kv("recommended_next_tests", a.recommendedTests.map(\.test.rawValue).joined(separator: ","))
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
            for (i, post) in st.postLoadSamples.enumerated() { csvSamples("raw.stress.post_load_round_\(i + 1)", post) }
            for p in [st.stressProbe].compactMap({ $0 }) + st.controlProbes { csvSamples("raw.stress.loss_probe.\(p.id)", p.samples) }
            for t in st.transfers {
                speedSamples("raw.stress.\(t.nodeID).round\(t.round).\(t.direction.rawValue)_samples_100ms", t.speed)
                csvSamples("raw.stress.\(t.nodeID).round\(t.round).\(t.direction.rawValue)_loaded_latency", t.loadedSamples)
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

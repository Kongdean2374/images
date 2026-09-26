import XCTest
@testable import ChaiNetCore

/// Regressions from the v2.2.0 raw export: section provenance, scoped findings, robust DNS
/// outliers, cellular data defaults, endpoint-specific paths and traceable baselines.
final class ExportConsistencyTests: XCTestCase {
    static func probe(_ id: String, target: String, rtt: Double, lost: Int, of count: Int, stress: Bool = false) -> LossProbeResult {
        let samples = (0..<count).map { LatencySample(sequence: $0, offset: Double($0) * 0.2, rttMs: $0 < lost ? nil : rtt) }
        return LossProbeResult(id: id, name: id, target: target, method: "icmpEcho", packetsPerSecond: stress ? 50 : 5,
                               isStressProbe: stress, samples: samples)
    }

    // MARK: 1. Latency sections carry their probe; Cloudflare HTTP idle ≠ Google ICMP loaded

    func testIdleAndLoadedFromDifferentProbesAreNotOneGroup() {
        let t = StressValidityTests.self
        var dl = t.transfer("cloudflare", round: 1, .download, t.speed(.download, mbps: 300, seconds: 20), loadedMs: 60)
        dl.controlLoadedSamples = (0..<40).map { LatencySample(sequence: $0, offset: 1 + Double($0) * 0.25, rttMs: 60) }
        var s = t.summary([dl])
        s.referenceProbe = ProbeDescriptor(target: "speed.cloudflare.com", method: "httpPing", protocolName: "HTTPS/TCP", ipFamily: "system")
        s.controlProbe = ProbeDescriptor(target: "8.8.8.8", method: "icmpEcho", protocolName: "ICMP", ipFamily: "IPv4")
        s.controlIdleSamples = (0..<20).map { LatencySample(sequence: $0, offset: Double($0) * 0.25, rttMs: 16.194) }
        var r = Fixture.result(.nr)
        r.kind = .extremeStressTest
        r.stress = s
        r.idleLatency = Fixture.latency(median: 63)
        r.downloadLoadedLatency = Fixture.latency(median: 60)

        let idle = r.latencyProvenance(.idle)!, loaded = r.latencyProvenance(.downloadLoaded)!
        XCTAssertEqual(idle.probe.target, "speed.cloudflare.com")
        XCTAssertEqual(idle.probe.method, "httpPing")
        XCTAssertEqual(idle.comparisonGroup, "primaryEndpointLatency")
        XCTAssertEqual(loaded.probe.target, "8.8.8.8")
        XCTAssertEqual(loaded.probe.method, "icmpEcho")
        XCTAssertEqual(loaded.comparisonGroup, "bufferbloatControl")
        XCTAssertFalse(r.latencySectionsComparable(.idle, .downloadLoaded))
        // Bufferbloat uses the comparable control idle (≈ 16 ms), never 60 − 63 < 0.
        XCTAssertEqual(r.metrics.downloadBloatMs!, 60 - 16.194, accuracy: 0.5)

        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.2.1", platform: "iOS")
        XCTAssertTrue(text.contains("[bufferbloat_control_idle]\ntarget=8.8.8.8"))
        XCTAssertTrue(text.contains("median_ms=16.194"))
        XCTAssertTrue(text.contains("[latency_idle]\nprobe_target=speed.cloudflare.com\nprobe_method=httpPing"))
        XCTAssertTrue(text.contains("comparison_group=primaryEndpointLatency"))
        XCTAssertTrue(text.contains("[latency_download_loaded]\nprobe_target=8.8.8.8\nprobe_method=icmpEcho"))
        XCTAssertTrue(text.contains("comparison_group=bufferbloatControl"))
        XCTAssertTrue(text.contains("comparable_with_latency_idle=false"))
        XCTAssertTrue(text.contains("idle_source=bufferbloat_control_idle") || r.bufferbloat == nil)
        // v1 keys stay.
        XCTAssertTrue(text.contains("rtt_median_ms="))
    }

    func testRegularTestSectionsShareTheServerProbe() {
        let r = Fixture.result(.wifi, download: 100, upload: 20, latency: 20, uploadBloat: 40)
        XCTAssertTrue(r.latencySectionsComparable(.idle, .uploadLoaded))
        XCTAssertEqual(r.latencyProvenance(.idle)?.measurementSource, "serverLatencyProbe")
        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.2.1", platform: "iOS")
        XCTAssertTrue(text.contains("comparable_with_latency_idle=true"))
    }

    // MARK: 2. One HTTP/3 fallback is endpoint-specific

    func http(_ proto: HTTPProtocolVersion) -> HTTPTimingBreakdown {
        HTTPTimingBreakdown(url: "https://speed.cloudflare.com", dnsMs: 5, tcpConnectMs: 10, tlsMs: 20, ttfbMs: 60, totalMs: 70, negotiatedProtocol: proto,
                            reusedConnection: false, remoteAddress: nil, localAddress: nil, ipFamily: nil, tlsVersion: "1.3", statusCode: 200)
    }

    func testSingleHTTP3FallbackIsNotGeneralUnavailability() {
        var p = ProtocolProbeResult(date: Date(), host: "speed.cloudflare.com", http: http(.http1_1), http3Attempt: http(.http1_1),
                                    quicHandshakeMs: .available(20), tcpConnect: nil, tlsConnect: nil, httpLatency: nil,
                                    ipv4Reachable: .available(10), ipv6Reachable: .available(12), errors: [])
        p.quicProbes = [QUICProbeOutcome(host: "cloudflare.com", handshakeMs: 20, failure: nil, detail: nil, tcpReachable: true),
                        QUICProbeOutcome(host: "www.google.com", handshakeMs: 22, failure: nil, detail: nil, tcpReachable: true)]
        p.quicAssessment = QUICClassifier.classify(p.quicProbes!)
        var r = Fixture.result(.wifi)
        r.protocolProbe = p
        r.evaluate()
        let codes = Set(r.findings.map(\.code))
        XCTAssertTrue(codes.contains(.http3FallbackObserved))
        XCTAssertFalse(codes.contains(.http3Unavailable))
        XCTAssertFalse(codes.contains(.generalHttp3Unavailable))
        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.2.1", platform: "iOS")
        XCTAssertTrue(text.contains("http3FallbackObserved=info"))
        XCTAssertTrue(text.contains("http3FallbackObserved.endpoint=speed.cloudflare.com"))
        XCTAssertTrue(text.contains("http3FallbackObserved.fallback=http/1.1"))
        XCTAssertFalse(text.contains("\nhttp3Unavailable="))
        XCTAssertTrue(text.contains("general_quic_reachable=true"))

        // Only ≥ 2 independent strict HTTP/3 endpoints all failing is general.
        var m = MetricSnapshot()
        m.http3Supported = false
        m.strictHTTP3EndpointsAttempted = 2
        m.strictHTTP3EndpointsFailed = 2
        XCTAssertTrue(Set(DiagnosticsEngine().diagnose(m).map(\.code)).contains(.generalHttp3Unavailable))
        m.strictHTTP3EndpointsFailed = 1
        XCTAssertFalse(Set(DiagnosticsEngine().diagnose(m).map(\.code)).contains(.generalHttp3Unavailable))
    }

    // MARK: 3. 216 ms wikipedia.org on the system resolver only

    func testSystemResolverDomainOutlierIsDetected() {
        func resolver(_ id: String, _ transport: DNSTransport, _ endpoint: String, _ rtts: [Double?]) -> DNSResolverResult {
            let samples = rtts.enumerated().map { LatencySample(sequence: $0.offset, offset: Double($0.offset), rttMs: $0.element) }
            return DNSResolverResult(resolver: DNSResolverDescriptor(id: id, name: id, transport: transport, endpoint: endpoint),
                                     samples: samples, statistics: LatencyStatistics.compute(from: samples), errors: [])
        }
        let domains = ["apple.com", "google.com", "cloudflare.com", "github.com", "youtube.com", "netflix.com",
                       "wikipedia.org", "amazon.com", "microsoft.com", "facebook.com"]
        let dns = DNSBenchmarkResult(date: Date(), domains: domains, resolvers: [
            resolver("system", .system, "", [2.49, 17.56, 14.97, 22.84, 17.00, 20.34, 216.76, 51.25, 53.77, 18.24]),
            resolver("google-udp", .udp, "8.8.8.8", [17, 18, 16, 19, 18, 17, 18, 20, 19, 18]),
            resolver("cloudflare-doh", .doh, "https://cloudflare-dns.com/dns-query", [20, 19, 21, 22, 19, 20, 19, 23, 21, 20]),
        ])
        XCTAssertEqual(DNSAnalyzer.outlierDomains(dns), ["wikipedia.org"])
        let o = DNSAnalyzer.outliers(dns).first!
        XCTAssertEqual(o.resolverID, "system")
        XCTAssertEqual(o.kind, .domainSpecificSystemResolverOutlier)
        XCTAssertEqual(o.confidenceBand, .high)
        XCTAssertEqual(o.comparisonResolvers["google-udp"] ?? nil, 18)
        let findings = DNSAnalyzer.analyze(dns)
        XCTAssertFalse(findings.contains { $0.kind == .resolverWideDegradation && $0.subject == "system" }, "one slow domain ≠ system DNS failure")

        var r = Fixture.result(.wifi)
        r.dns = dns
        let codes = Set(EvidenceExtractor().extract(test: SessionTest(label: "A", result: r)).0.map(\.code))
        XCTAssertTrue(codes.contains(.dnsDomainSpecificOutlier))
        XCTAssertFalse(codes.contains(.dnsFailures))
        XCTAssertFalse(codes.contains(.dnsSlow))
        XCTAssertFalse(codes.contains(.dnsHighTailLatencyObserved), "the tail is the one outlier domain")
        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.2.1", platform: "iOS")
        XCTAssertTrue(text.contains("dns_outlier_domains=wikipedia.org"))
        XCTAssertTrue(text.contains("dns_outlier.wikipedia.org.system.kind=domainSpecificSystemResolverOutlier"))
        XCTAssertTrue(text.contains("dns_outlier.wikipedia.org.system.comparison_resolvers=cloudflare-doh:19.00,google-udp:18.00"))
        XCTAssertTrue(text.contains("dns_outlier.wikipedia.org.system.confidence_band=high"))
        XCTAssertTrue(text.contains("dns_outlier.wikipedia.org.system.outlier_reason=latency 216.76 ms"))
    }

    // MARK: 4. Cellular never defaults to unlimited data

    func testCellularExtremeTestDefaultsToCaps() {
        let d = StressDataLimits.unlimited.effective(onCellular: true)
        XCTAssertEqual(d.policy, "cellularDefault")
        XCTAssertEqual(d.hardCapBytes, 1_500_000_000)
        XCTAssertEqual(d.warningBytes, 500_000_000)
        XCTAssertEqual(d.softWarningBytes, 750_000_000)
        XCTAssertTrue(d.isLimited)

        let explicit = StressDataLimits(explicitlyUnlimited: true).effective(onCellular: true)
        XCTAssertNil(explicit.hardCapBytes, "only an explicit choice runs uncapped")
        XCTAssertEqual(explicit.policy, "explicitUnlimited")
        XCTAssertEqual(StressDataLimits.unlimited.effective(onCellular: false).policy, "unlimitedNonCellular")
        let user = StressDataLimits.withHardCap(5 * StressDataLimits.gigabyte).effective(onCellular: true)
        XCTAssertEqual(user.policy, "userConfigured")
        XCTAssertEqual(user.hardCapBytes, 5_000_000_000)
    }

    func testDurationAdjustmentIsExplained() {
        let nodes = [StressNode.throughputNode(for: ServerDescriptor.builtIn[0]), StressNode.throughputNode(for: .mlabNDT7)] + StressNode.latencyOnlyDefaults
        let plan = StressTestPlan.make(totalSeconds: 60, nodes: nodes)
        XCTAssertGreaterThan(plan.estimatedSeconds, 60)
        XCTAssertEqual(plan.durationAdjustmentReason(configuredSeconds: 60), "minimumRequiredDiagnosticPhases")
        XCTAssertEqual(StressTestPlan.make(totalSeconds: 30, nodes: nodes).durationAdjustmentReason(configuredSeconds: 30), "requestedBelowMinimum")

        let t = StressValidityTests.self
        var s = t.summary([t.transfer("cloudflare", round: 1, .download, t.speed(.download, mbps: 300, seconds: 20), loadedMs: 40)])
        s.dataLimits = StressDataLimits.unlimited.effective(onCellular: true)
        s.trafficEstimate = plan.trafficEstimate(downloadMbps: 400, uploadMbps: 60)
        var r = Fixture.result(.nr)
        r.kind = .extremeStressTest
        r.stress = s
        let text = RawDataExporter.text(r, analysis: nil, appVersion: "2.2.1", platform: "iOS")
        XCTAssertTrue(text.contains("duration_adjustment_reason="))
        XCTAssertTrue(text.contains("data_limit_policy=cellularDefault"))
        XCTAssertTrue(text.contains("data_hard_cap_bytes=1500000000"))
        XCTAssertTrue(text.contains("data_warning_bytes=500000000"))
        XCTAssertTrue(text.contains("data_soft_warning_bytes=750000000"))
        XCTAssertTrue(text.contains("estimated_data_usage_bytes="))
        XCTAssertFalse(text.contains("data_hard_cap_bytes=unlimited"))
    }

    // MARK: 5. Cloudflare-only loss stays endpoint-specific

    func testCloudflareSpecificLossIsNotGeneralized() {
        let stress = Self.probe("stress", target: "1.1.1.1", rtt: 40, lost: 27, of: 1500, stress: true)          // 1.8 %
        let controls = [Self.probe("cf", target: "1.1.1.1", rtt: 40, lost: 3, of: 150),                          // 2 %
                        Self.probe("google", target: "8.8.8.8", rtt: 16, lost: 0, of: 150),
                        Self.probe("apple", target: "17.253.144.10", rtt: 11, lost: 0, of: 150),
                        Self.probe("quad9", target: "9.9.9.9", rtt: 60, lost: 0, of: 150)]
        let nodes = [StressNode.throughputNode(for: ServerDescriptor.builtIn[0])] + StressNode.latencyOnlyDefaults
        let s = StressSummary(plan: StressTestPlan.make(totalSeconds: 300, nodes: nodes), configuredSeconds: 300, actualSeconds: 300, nodes: nodes,
                              transfers: [], phases: [], stressProbe: stress, controlProbes: controls,
                              preLoadLatency: Fixture.latency(median: 63), preLoadSamples: nil, postLoadLatency: [], postLoadSamples: [], warnings: [])
        XCTAssertEqual(s.lossConfirmation.verdict, .endpointSpecificLossObserved)
        XCTAssertEqual(s.affectedProviders, ["cloudflare"])
        XCTAssertEqual(s.elevatedAffectedEndpoints?.endpoints.first?.target, "1.1.1.1")

        var r = Fixture.result(.nr)
        r.kind = .extremeStressTest
        r.stress = s
        r.packetLoss = controls[1].statistics
        let session = Fixture.session([r])
        let a = RootCauseAnalyzer().analyze(session: session, baselines: nil)
        let codes = a.evidence.codes
        XCTAssertTrue(codes.contains(.endpointSpecificLossObserved))
        XCTAssertTrue(codes.contains(.endpointLatencyElevatedVsPeers))
        XCTAssertFalse(codes.contains(.lossHigh))
        XCTAssertFalse(codes.contains(.lossSevere))
        let specific = a.hypotheses.first { $0.cause == .endpointSpecificPathIssue }!
        XCTAssertEqual(specific.likelihood, .possible, "ICMP loss may be rate limiting: never more than possible")
        XCTAssertLessThanOrEqual(specific.confidence, 0.65)
        let general = a.hypotheses.first { $0.cause == .serverOrRouteSpecific }!
        XCTAssertFalse([Likelihood.likely, .possible, .supported].contains(general.likelihood))
        XCTAssertFalse([Likelihood.likely, .supported].contains(a.hypotheses.first { $0.cause == .ispOrCarrierCongestion }!.likelihood))

        let text = RawDataExporter.text(r, analysis: a, appVersion: "2.2.1", platform: "iOS")
        XCTAssertTrue(text.contains("endpointSpecificPathIssue.1.1.1.1=possible"))
        XCTAssertFalse(text.contains("cloudflareSpecificPathIssue"), "1.1.1.1 ICMP must not be generalised to the provider's other services")
        XCTAssertTrue(text.contains("generalServerOrRouteIssue="))
        XCTAssertTrue(text.contains("loss_verdict=endpointSpecificLossObserved"))
    }

    // MARK: 6. matchesBaseline must be backed by an exported baseline

    static func store(_ metrics: [MetricBaseline], samples: Int = 12) -> BaselineStore {
        BaselineStore(baselines: [Baseline(key: BaselineKey(network: .wifi, timeBucket: nil, region: nil), sampleCount: samples, metrics: metrics,
                                           oldestDate: Date(timeIntervalSince1970: 1_699_000_000), newestDate: Date(timeIntervalSince1970: 1_699_900_000))])
    }

    func testMatchesBaselineIsTraceable() {
        let r = Fixture.result(.wifi, download: 300, upload: 50, latency: 10)
        let store = Self.store([MetricBaseline(metric: .downloadMbps, count: 12, median: 300, mad: 10, p10: 280, p90: 320),
                                MetricBaseline(metric: .uploadMbps, count: 12, median: 50, mad: 2, p10: 46, p90: 54),
                                MetricBaseline(metric: .latencyMs, count: 12, median: 10, mad: 1, p10: 9, p90: 11)])
        let a = RootCauseAnalyzer().analyze(session: Fixture.session([r]), baselines: store)
        XCTAssertTrue(a.evidence.codes.contains(.matchesBaseline))
        let text = RawDataExporter.text(r, analysis: a, appVersion: "2.2.1", platform: "iOS")
        XCTAssertTrue(text.contains("[baseline]\navailable=true"))
        XCTAssertTrue(text.contains("network_type=wifi"))
        XCTAssertTrue(text.contains("sample_count=12"))
        XCTAssertTrue(text.contains("download_median_mbps=300.000"))
        XCTAssertTrue(text.contains("matching_criteria=network=wifi,time_bucket=any,region=any"))
        XCTAssertTrue(text.contains("confidence_band=medium"))
        XCTAssertTrue(text.contains("baseline_age_days="))
        XCTAssertTrue(text.contains("compared_metrics=downloadMbps,uploadMbps,latencyMs"))
    }

    func testNoMatchesBaselineWithoutSufficientBaseline() {
        let r = Fixture.result(.wifi, download: 300, upload: 50, latency: 10)
        // Only one metric in common: not enough to call the result "normal".
        let thin = Self.store([MetricBaseline(metric: .latencyMs, count: 12, median: 10, mad: 1, p10: 9, p90: 11)])
        let a = RootCauseAnalyzer().analyze(session: Fixture.session([r]), baselines: thin)
        XCTAssertFalse(a.evidence.codes.contains(.matchesBaseline))
        XCTAssertTrue(RawDataExporter.text(r, analysis: a, appVersion: "2.2.1", platform: "iOS").contains("sufficient_for_match=false"))

        let none = RootCauseAnalyzer().analyze(session: Fixture.session([r]), baselines: BaselineStore(baselines: []))
        XCTAssertFalse(none.evidence.codes.contains(.matchesBaseline))
        let text = RawDataExporter.text(r, analysis: none, appVersion: "2.2.1", platform: "iOS")
        XCTAssertTrue(text.contains("[baseline]\navailable=false"))
    }
}

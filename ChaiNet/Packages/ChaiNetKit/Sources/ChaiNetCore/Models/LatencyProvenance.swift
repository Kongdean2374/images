import Foundation

/// The three generic latency sections of a result.
public enum LatencySection: String, Codable, Sendable, Hashable, CaseIterable {
    case idle, downloadLoaded, uploadLoaded
}

/// Where a latency section's samples came from. Sections are only directly comparable when they
/// share a `comparisonGroup` (same probe method and target).
///
///     primaryEndpointLatency : the speed-test server's own latency probe (HTTP ping / TCP connect)
///     bufferbloatControl     : independent fixed control probe (e.g. ICMP 8.8.8.8), never under load
public struct LatencyProvenance: Codable, Sendable, Hashable {
    public var probe: ProbeDescriptor
    /// "serverLatencyProbe", "referenceProbe" or "independentControlProbe".
    public var measurementSource: String
    public var comparisonGroup: String

    public static let primaryEndpointGroup = "primaryEndpointLatency"
    public static let bufferbloatControlGroup = "bufferbloatControl"

    public init(probe: ProbeDescriptor, measurementSource: String, comparisonGroup: String) {
        self.probe = probe
        self.measurementSource = measurementSource
        self.comparisonGroup = comparisonGroup
    }
}

extension TestResult {
    /// Provenance of a generic latency section (nil when the section has no data source).
    ///
    /// Extreme Stress Test: idle = reference probe (primary HTTP node); loaded = the independent
    /// control probe when it produced data (the runner pools those samples into the generic loaded
    /// sections), otherwise the reference probe. Other tests: every section uses the server probe.
    public func latencyProvenance(_ section: LatencySection) -> LatencyProvenance? {
        if let st = stress {
            let reference = LatencyProvenance(
                probe: st.referenceProbe ?? ProbeDescriptor(target: server?.host ?? "unknown", method: "unknown", protocolName: "unknown", ipFamily: "unknown"),
                measurementSource: "referenceProbe", comparisonGroup: LatencyProvenance.primaryEndpointGroup)
            if section == .idle { return reference }
            if st.usesControlProbeForLoadedLatency, let control = st.controlProbe {
                return LatencyProvenance(probe: control, measurementSource: "independentControlProbe",
                                         comparisonGroup: LatencyProvenance.bufferbloatControlGroup)
            }
            return reference
        }
        guard let server else { return nil }
        let forced = ipFamilyPreference != .automatic
        let family: String
        switch ipFamilyPreference {
        case .automatic: family = "system"
        case .ipv4Only: family = "IPv4"
        case .ipv6Only: family = "IPv6"
        }
        return LatencyProvenance(probe: ProbeDescriptor(target: server.host, method: forced ? "tcpConnect" : "httpPing",
                                                        protocolName: forced ? "TCP" : "HTTPS/TCP", ipFamily: family),
                                 measurementSource: "serverLatencyProbe", comparisonGroup: LatencyProvenance.primaryEndpointGroup)
    }

    /// True when the idle and loaded sections share a probe method and target.
    public func latencySectionsComparable(_ a: LatencySection, _ b: LatencySection) -> Bool {
        guard let x = latencyProvenance(a), let y = latencyProvenance(b) else { return false }
        return x.comparisonGroup == y.comparisonGroup && x.probe.target == y.probe.target && x.probe.method == y.probe.method
    }
}

extension StressSummary {
    /// Mirrors the runner: generic loaded sections use the control probe when either direction's
    /// bufferbloat comparison came from it.
    public var usesControlProbeForLoadedLatency: Bool {
        bufferbloatComparison(.download)?.source == "independentControlProbe"
            || bufferbloatComparison(.upload)?.source == "independentControlProbe"
    }

    /// Idle samples of the independent control probe as statistics (the comparable idle baseline).
    public var controlIdleStatistics: LatencyStatistics? {
        guard let s = controlIdleSamples, !s.isEmpty else { return nil }
        return LatencyStatistics.compute(from: s)
    }
}

// MARK: - Endpoint-specific path evidence

extension StressSummary {
    /// Anycast addresses used as probe targets that are not stress nodes themselves.
    static let wellKnownProviders: [String: String] = [
        "1.1.1.1": "cloudflare", "1.0.0.1": "cloudflare", "8.8.8.8": "google", "8.8.4.4": "google", "9.9.9.9": "quad9",
    ]

    /// Providers of the endpoints where loss was observed (e.g. ["cloudflare"]), from node hosts.
    public var affectedProviders: [String] {
        var seen = Set<String>()
        return (lossConfirmation.affectedTargets ?? []).compactMap { target in
            nodes.first { $0.host == target || $0.server?.icmpHost == target }?.provider.rawValue ?? Self.wellKnownProviders[target]
        }.filter { seen.insert($0).inserted }
    }

    /// Affected endpoints that also answer clearly slower than the clean independent peers,
    /// same probe method (low-rate controls):
    ///
    ///     elevated ⇔ affected median ≥ max(1.5 × peer median, peer median + 15 ms)
    ///     peer median = median of the clean targets' control medians
    public var elevatedAffectedEndpoints: (endpoints: [(target: String, medianMs: Double)], peerMedianMs: Double)? {
        let affected = Set(lossConfirmation.affectedTargets ?? [])
        let clean = Set(lossConfirmation.cleanTargets ?? [])
        guard !affected.isEmpty, !clean.isEmpty else { return nil }
        let controls = controlProbes.filter { !$0.isStressProbe && $0.isPacketLossProbe }
        func median(_ target: String) -> Double? {
            Descriptive.median(controls.filter { $0.target == target }.compactMap { $0.statistics.rtt?.median })
        }
        guard let peer = Descriptive.median(clean.compactMap(median)) else { return nil }
        let limit = max(1.5 * peer, peer + 15)
        let elevated: [(target: String, medianMs: Double)] = affected.sorted().compactMap { t -> (target: String, medianMs: Double)? in
            guard let m = median(t), m >= limit else { return nil }
            return (target: t, medianMs: m)
        }
        return elevated.isEmpty ? nil : (elevated, peer)
    }
}

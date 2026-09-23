import Foundation
@testable import ChaiNetCore

/// Builders for synthetic, fully deterministic test results.
enum Fixture {
    static func network(_ cls: NetworkClass, vpn: VPNDetection.State = .notDetected, constrained: Bool = false) -> NetworkSnapshot {
        let iface: InterfaceKind
        var cellular: CellularInfo?
        switch cls {
        case .wifi: iface = .wifi
        case .wired: iface = .wiredEthernet
        case .lte, .nr, .cellularOther:
            iface = .cellular
            let rat: RadioAccessTechnology = cls == .lte ? .lte : (cls == .nr ? .nrNSA : .wcdma)
            cellular = CellularInfo(radioTechnology: .available(rat), carrierName: .unavailable(reason: UnavailableReason.carrierName),
                                    signal: .unavailableOnIOS)
        case .unknown: iface = .other
        }
        return NetworkSnapshot(capturedAt: Date(timeIntervalSince1970: 0), status: .satisfied, primaryInterface: iface, availableInterfaces: [iface],
                               isExpensive: iface == .cellular, isConstrained: constrained, supportsIPv4: true, supportsIPv6: true, supportsDNS: true,
                               localAddresses: [], publicIPv4: .unavailable(reason: "test"), publicIPv6: .unavailable(reason: "test"),
                               vpn: VPNDetection(state: vpn, interfaces: vpn == .detected ? ["utun4"] : [], method: "test"),
                               cellular: cellular, wifi: nil)
    }

    static func latency(median: Double, jitter: Double = 2, lossPercent: Double = 0, count: Int = 100, burst: Bool = false) -> LatencyStatistics {
        let lostCount = Int((lossPercent / 100 * Double(count)).rounded())
        var samples: [LatencySample] = []
        for i in 0..<count {
            let lost: Bool
            if burst { lost = i >= 10 && i < 10 + lostCount } else { lost = lostCount > 0 && i % max(1, count / max(lostCount, 1)) == 0 && samples.filter(\.isLost).count < lostCount }
            let rtt = median + (i % 2 == 0 ? jitter / 2 : -jitter / 2)
            samples.append(LatencySample(sequence: i, offset: Double(i), rttMs: lost ? nil : rtt))
        }
        return LatencyStatistics.compute(from: samples)
    }

    static func speed(_ direction: TransferDirection, mbps: Double, jitterFraction: Double = 0) -> SpeedResult {
        var cumulative: Int64 = 0
        let samples = (0..<50).map { i -> SpeedSample in
            let rate = mbps * (1 + (i % 2 == 0 ? jitterFraction : -jitterFraction))
            let b = Int64(rate * 1_000_000 / 8 * 0.2); cumulative += b
            return SpeedSample(offset: Double(i + 1) * 0.2, intervalDuration: 0.2, intervalBytes: b, cumulativeBytes: cumulative, activeStreams: 4)
        }
        return SpeedResult(direction: direction, samples: samples, summary: SpeedCalculator.summarize(samples: samples), streamChanges: [], wasCancelled: false)
    }

    static func server(_ id: String, region: String = "Taipei") -> ServerDescriptor {
        ServerDescriptor(id: id, name: "Server \(id)", location: region, kind: .chainet, baseURL: URL(string: "https://\(id).example.com")!)
    }

    static func result(_ cls: NetworkClass, download: Double? = nil, upload: Double? = nil, uploadJitter: Double = 0,
                       latency: Double? = 20, jitter: Double = 2, loss: Double = 0, burst: Bool = false,
                       uploadBloat: Double? = nil, downloadBloat: Double? = nil, server: String = "a",
                       vpn: VPNDetection.State = .notDetected, date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> TestResult {
        var r = TestResult(date: date, kind: .fullSpeedTest, network: network(cls, vpn: vpn))
        r.server = Fixture.server(server)
        if let download { r.download = speed(.download, mbps: download) }
        if let upload { r.upload = speed(.upload, mbps: upload, jitterFraction: uploadJitter) }
        if let latency {
            r.idleLatency = Fixture.latency(median: latency, jitter: jitter, lossPercent: loss, burst: burst)
            if let downloadBloat { r.downloadLoadedLatency = Fixture.latency(median: latency + downloadBloat) }
            if let uploadBloat { r.uploadLoadedLatency = Fixture.latency(median: latency + uploadBloat) }
            r.bufferbloat = BufferbloatCalculator.evaluate(idle: r.idleLatency!, downloadLoaded: r.downloadLoadedLatency, uploadLoaded: r.uploadLoadedLatency)
        }
        r.evaluate()
        return r
    }

    static func check(_ id: String, region: String = "Anycast", median: Double, loss: Double = 0) -> EndpointCheck {
        EndpointCheck(id: id, name: "Endpoint \(id)", host: "\(id).example", region: region, method: .tcpConnect,
                      statistics: latency(median: median, lossPercent: loss, count: 50), error: nil, isPrimary: false)
    }

    static func session(_ results: [TestResult]) -> DiagnosticSession {
        var s = DiagnosticSession(title: "test")
        for r in results { s.tests.append(SessionTest(label: s.nextLabel, result: r)) }
        return s
    }
}

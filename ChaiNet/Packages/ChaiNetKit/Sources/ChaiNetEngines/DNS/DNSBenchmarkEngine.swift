import Foundation
import Network
import ChaiNetCore

public protocol DNSBenchmarkEngineProtocol: Sendable {
    func run(resolvers: [DNSResolverDescriptor], domains: [String],
             progress: @escaping @Sendable (DNSResolverResult) -> Void) async throws -> DNSBenchmarkResult
}

/// DNS resolver benchmark.
///
/// - System: `getaddrinfo` — what apps actually experience (note: iOS caches answers, so the
///   first lookup of each domain is the meaningful one; repeated domains are avoided).
/// - UDP: hand-built RFC 1035 query to resolver:53, time from send to matching response.
/// - DoH: RFC 8484 POST over a warmed HTTPS connection (connection setup excluded).
///
/// NOERROR and NXDOMAIN both count as answered; SERVFAIL / timeout count as failures.
public struct DNSBenchmarkEngine: DNSBenchmarkEngineProtocol {
    public var timeout: Double

    public init(timeout: Double = 3) {
        self.timeout = timeout
    }

    public static let defaultDomains = ["apple.com", "google.com", "cloudflare.com", "youtube.com", "netflix.com",
                                        "github.com", "wikipedia.org", "amazon.com", "line.me", "twitch.tv"]

    public func run(resolvers: [DNSResolverDescriptor], domains: [String] = Self.defaultDomains,
                    progress: @escaping @Sendable (DNSResolverResult) -> Void) async throws -> DNSBenchmarkResult {
        var results: [DNSResolverResult] = []
        for resolver in resolvers {
            try Task.checkCancellation()
            let r = await benchmark(resolver, domains: domains)
            results.append(r)
            progress(r)
        }
        return DNSBenchmarkResult(date: Date(), domains: domains, resolvers: results)
    }

    func benchmark(_ resolver: DNSResolverDescriptor, domains: [String]) async -> DNSResolverResult {
        var samples: [LatencySample] = []
        var errors: [String] = []
        let stopwatch = Stopwatch()
        var doh: URLSession?
        if resolver.transport == .doh {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            doh = URLSession(configuration: config)
            _ = try? await dohQuery(session: doh!, endpoint: resolver.endpoint, name: "example.com") // warm-up
        }
        for (i, domain) in domains.enumerated() {
            if Task.isCancelled { break }
            let offset = stopwatch.elapsed
            do {
                let ms: Double
                switch resolver.transport {
                case .system: ms = try await systemLookup(domain)
                case .udp: ms = try await udpQuery(server: resolver.endpoint, name: domain, id: UInt16(truncatingIfNeeded: i &+ 0x5A00))
                case .doh: ms = try await dohQuery(session: doh!, endpoint: resolver.endpoint, name: domain)
                }
                samples.append(LatencySample(sequence: i, offset: offset, rttMs: ms))
            } catch {
                samples.append(LatencySample(sequence: i, offset: offset, rttMs: nil))
                errors.append("\(domain): \(error.localizedDescription)")
            }
        }
        doh?.invalidateAndCancel()
        return DNSResolverResult(resolver: resolver, samples: samples, statistics: LatencyStatistics.compute(from: samples), errors: errors)
    }

    func systemLookup(_ domain: String) async throws -> Double {
        let t = timeout
        return try await withTimeout(t) {
            let stopwatch = Stopwatch()
            _ = try await SocketSupport.resolve(domain)
            return stopwatch.elapsedMs
        }
    }

    func udpQuery(server: String, name: String, id: UInt16) async throws -> Double {
        let connection = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
        defer { connection.cancel() }
        try await NWAsync.connect(connection, timeout: timeout)
        let query = Data(DNSMessage.makeQuery(id: id, name: name, type: .a))
        let t = timeout
        return try await withTimeout(t) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Double, Error>) in
                let stopwatch = Stopwatch()
                let once = OnceFlag()
                connection.receiveMessage { data, _, _, error in
                    guard once.trySet() else { return }
                    if let error { return cont.resume(throwing: error) }
                    guard let data, let header = DNSMessage.parseHeader([UInt8](data)), header.id == id, header.isResponse else {
                        return cont.resume(throwing: EngineError.invalidResponse("DNS"))
                    }
                    guard header.rcode == 0 || header.rcode == 3 else {
                        return cont.resume(throwing: EngineError.server("RCODE \(header.rcode)"))
                    }
                    cont.resume(returning: stopwatch.elapsedMs)
                }
                connection.send(content: query, completion: .contentProcessed { error in
                    if let error, once.trySet() { cont.resume(throwing: error) }
                })
            }
        }
    }

    func dohQuery(session: URLSession, endpoint: String, name: String) async throws -> Double {
        guard let url = URL(string: endpoint) else { throw EngineError.unsupported(endpoint) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = Data(DNSMessage.makeQuery(id: 0, name: name, type: .a))
        let stopwatch = Stopwatch()
        let (data, response) = try await session.data(for: request)
        let ms = stopwatch.elapsedMs
        guard (response as? HTTPURLResponse)?.statusCode == 200, let header = DNSMessage.parseHeader([UInt8](data)), header.isResponse else {
            throw EngineError.invalidResponse("DoH")
        }
        guard header.rcode == 0 || header.rcode == 3 else { throw EngineError.server("RCODE \(header.rcode)") }
        return ms
    }
}

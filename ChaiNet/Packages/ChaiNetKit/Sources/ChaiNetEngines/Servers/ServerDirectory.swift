import Foundation
import ChaiNetCore

public protocol ServerDirectoryProtocol: Sendable {
    /// Ranks servers by median HTTP latency (3 probes each, measured concurrently).
    func rank(_ servers: [ServerDescriptor]) async -> [ServerLatencyRanking]
    /// `/info` of a ChaiNet backend (nil for other server kinds).
    func info(for server: ServerDescriptor) async -> ServerInfo?
    /// `/health` of a ChaiNet backend; for other kinds a ping request is used.
    func health(for server: ServerDescriptor) async -> ServerHealth
}

public struct ServerDirectory: ServerDirectoryProtocol {
    public init() {}

    static func session(timeout: Double) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    public func rank(_ servers: [ServerDescriptor]) async -> [ServerLatencyRanking] {
        await withTaskGroup(of: ServerLatencyRanking.self) { group in
            for server in servers {
                group.addTask {
                    let probe = HTTPLatencyProbe(url: server.pingURL())
                    defer { Task { await probe.close() } }
                    do {
                        try await probe.prepare()
                        let samples = await LatencySampler.collect(probe: probe, count: 3, interval: 0.15, timeout: 2)
                        let median = LatencyStatistics.compute(from: samples).rtt?.median
                        return ServerLatencyRanking(server: server, medianMs: median, error: median == nil ? "無回應" : nil)
                    } catch {
                        return ServerLatencyRanking(server: server, medianMs: nil, error: error.localizedDescription)
                    }
                }
            }
            var out: [ServerLatencyRanking] = []
            for await r in group { out.append(r) }
            return out.sorted { ($0.medianMs ?? .infinity) < ($1.medianMs ?? .infinity) }
        }
    }

    public func info(for server: ServerDescriptor) async -> ServerInfo? {
        guard let url = server.infoURL() else { return nil }
        let session = Self.session(timeout: 5)
        defer { session.invalidateAndCancel() }
        guard let reply = try? await session.data(from: url),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(ServerInfo.self, from: reply.0)
    }

    public func health(for server: ServerDescriptor) async -> ServerHealth {
        let url = server.healthURL() ?? server.pingURL()
        let session = Self.session(timeout: 5)
        defer { session.invalidateAndCancel() }
        let stopwatch = Stopwatch()
        do {
            let (data, response) = try await session.data(from: url)
            let ms = stopwatch.elapsedMs
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            struct Health: Decodable { var status: String?; var active_sessions: Int?; var detail: String? }
            let decoded = try? JSONDecoder().decode(Health.self, from: data)
            let healthy = status == 200 && (decoded?.status.map { $0 == "ok" } ?? true)
            return ServerHealth(reachable: true, healthy: healthy, responseMs: ms, activeSessions: decoded?.active_sessions,
                                detail: healthy ? nil : (decoded?.detail ?? "HTTP \(status)"))
        } catch {
            return ServerHealth(reachable: false, healthy: false, responseMs: nil, activeSessions: nil, detail: error.localizedDescription)
        }
    }
}

import Foundation
import Network
import ChaiNetCore

/// Async helpers around `NWConnection`.
public enum NWAsync {
    static let queue = DispatchQueue(label: "chainet.nw", qos: .userInitiated, attributes: .concurrent)

    /// Starts the connection and waits for `.ready`. `.waiting` is treated as failure (a probe
    /// must not silently wait for connectivity). Honours cancellation and `timeout`.
    public static func connect(_ connection: NWConnection, timeout: Double) async throws {
        let once = OnceFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if once.trySet() { cont.resume() }
                    case .failed(let error), .waiting(let error):
                        if once.trySet() { cont.resume(throwing: error) }
                    case .cancelled:
                        if once.trySet() { cont.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    if once.trySet() {
                        connection.cancel()
                        cont.resume(throwing: EngineError.timeout)
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Time from `start()` to `.ready`, in ms. The connection is cancelled afterwards.
    public static func timeToReady(_ connection: NWConnection, timeout: Double) async -> Result<Double, Error> {
        let stopwatch = Stopwatch()
        do {
            try await connect(connection, timeout: timeout)
            let ms = stopwatch.elapsedMs
            connection.cancel()
            return .success(ms)
        } catch {
            connection.cancel()
            return .failure(error)
        }
    }

    public static func parameters(tcp: Bool, tls: Bool = false, ipVersion: NWProtocolIP.Options.Version? = nil,
                                  interface: NWInterface.InterfaceType? = nil) -> NWParameters {
        let params: NWParameters
        if tcp {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.connectionTimeout = 5
            tcpOptions.noDelay = true
            params = NWParameters(tls: tls ? NWProtocolTLS.Options() : nil, tcp: tcpOptions)
        } else {
            params = NWParameters.udp
        }
        if let ipVersion, let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = ipVersion
        }
        if let interface { params.requiredInterfaceType = interface }
        params.preferNoProxies = true
        return params
    }

    public static func interfaceType(_ kind: InterfaceKind) -> NWInterface.InterfaceType? {
        switch kind {
        case .wifi: .wifi
        case .cellular: .cellular
        case .wiredEthernet: .wiredEthernet
        case .loopback: .loopback
        case .other, .none: nil
        }
    }
}

/// TCP handshake time (SYN → SYN/ACK → ready). A lost SYN shows up as a timeout because the
/// first retransmission happens after ~1 s, which is longer than the probe timeout.
public struct TCPConnectProbe: LatencyProbe {
    public let host: String
    public let port: UInt16
    public let ipVersion: NWProtocolIP.Options.Version?
    public let interface: NWInterface.InterfaceType?
    public let useTLS: Bool
    public var method: EndpointProbeMethod { .tcpConnect }
    public var targetDescription: String { "\(host):\(port)\(useTLS ? " (TLS)" : "")" }

    public init(host: String, port: UInt16 = 443, ipVersion: NWProtocolIP.Options.Version? = nil,
                interface: NWInterface.InterfaceType? = nil, useTLS: Bool = false) {
        self.host = host
        self.port = port
        self.ipVersion = ipVersion
        self.interface = interface
        self.useTLS = useTLS
    }

    public func prepare() async throws {}
    public func close() async {}

    public func probe(sequence: Int, timeout: Double) async -> Double? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                      using: NWAsync.parameters(tcp: true, tls: useTLS, ipVersion: ipVersion, interface: interface))
        if case .success(let ms) = await NWAsync.timeToReady(connection, timeout: timeout) { return ms }
        return nil
    }
}

/// QUIC handshake (ALPN h3) via Network.framework.
public enum QUICProbe {
    public static func handshake(host: String, port: UInt16 = 443, timeout: Double = 5) async -> Result<Double, Error> {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .failure(EngineError.unsupported("port")) }
        let options = NWProtocolQUIC.Options(alpn: ["h3"])
        let params = NWParameters(quic: options)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        return await NWAsync.timeToReady(connection, timeout: timeout)
    }
}

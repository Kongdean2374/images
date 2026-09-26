import Foundation

/// Counters collected by the transfer engines for validation and export.
public struct TransferDiagnostics: Codable, Sendable, Hashable {
    public var requestsStarted: Int = 0
    /// Requests that got an HTTP response (any status).
    public var responses: Int = 0
    /// Download responses with a 2xx status that completed normally.
    public var completedOK: Int = 0
    /// "200": n, "429": n …
    public var statusCounts: [String: Int] = [:]
    /// Distinct response content types (first few).
    public var contentTypes: [String] = []
    /// Payload size requested per download request / sent per upload request.
    public var expectedBytesPerRequest: Int64?
    /// Smallest completed 2xx download body.
    public var smallestResponseBytes: Int64?
    /// Completed 2xx download bodies smaller than 10 % of the requested size.
    public var tinyResponses: Int = 0
    /// Transport errors (cancellation at the planned stop is not counted).
    public var errorCount: Int = 0
    public var timeoutCount: Int = 0
    public var errorSamples: [String] = []
    /// Bytes moved per parallel stream.
    public var perStreamBytes: [Int64] = []
    /// Times all connections were rebuilt because no bytes moved for a few seconds (nil = never / older result).
    public var stallRestarts: Int?

    public init() {}

    public var rateLimitedResponses: Int { statusCounts["429"] ?? 0 }
    public var non2xxResponses: Int { statusCounts.filter { !(200..<300).contains(Int($0.key) ?? 0) }.values.reduce(0, +) }
    public var serverErrorResponses: Int { statusCounts.filter { (500..<600).contains(Int($0.key) ?? 0) }.values.reduce(0, +) }
}

public enum TransferInvalidReason: String, Codable, Sendable, Hashable {
    /// Wrong status / content type (e.g. an HTML or JSON error page instead of the payload).
    case unexpectedResponse
    /// Responses completed but far smaller than requested, or the whole transfer moved almost nothing.
    case insufficientPayload
    /// 5xx responses or transport errors.
    case endpointFailure
    /// HTTP 429.
    case rateLimited
    /// Nothing arrived before the timeout.
    case timeout
    /// No bytes and no error.
    case noData
}

public struct TransferValidity: Codable, Sendable, Hashable {
    public var valid: Bool
    public var reason: TransferInvalidReason?
    public var detail: String?

    public init(valid: Bool, reason: TransferInvalidReason? = nil, detail: String? = nil) {
        self.valid = valid
        self.reason = reason
        self.detail = detail
    }

    public static let ok = TransferValidity(valid: true)
    public static func invalid(_ reason: TransferInvalidReason, _ detail: String) -> TransferValidity {
        TransferValidity(valid: false, reason: reason, detail: detail)
    }
}

/// Decides whether a transfer generated a real measurement. Rules, first match wins:
///
///     any 429                                      → rateLimited
///     non-2xx ≥ 2xx responses (5xx present)        → endpointFailure, else unexpectedResponse
///     download: tiny 2xx bodies (< 10 % requested) ≥ half of completed 2xx → insufficientPayload
///     download: text/html or application/json body → unexpectedResponse
///     0 bytes: timeouts → timeout · errors → endpointFailure · else noData
///     < 256 KB in ≥ 3 s (unexpected tiny body)     → endpointFailure if errors, else insufficientPayload
///
/// A slow but real link still moves ≥ 256 KB in a multi-second transfer (≈ 0.7 Mbps over 3 s),
/// and its responses are in progress rather than completed-but-tiny.
public enum TransferValidator {
    public static let minimumBytes: Int64 = 256_000
    public static let minimumDuration = 3.0

    public static func evaluate(_ r: SpeedResult) -> TransferValidity {
        let bytes = r.summary.totalBytes
        let seconds = r.summary.duration
        if let d = r.diagnostics {
            let ok2xx = d.statusCounts.filter { (200..<300).contains(Int($0.key) ?? 0) }.values.reduce(0, +)
            if d.rateLimitedResponses > 0 {
                return .invalid(.rateLimited, "HTTP 429 × \(d.rateLimitedResponses)（端點限流）")
            }
            if d.non2xxResponses > 0 && d.non2xxResponses >= ok2xx {
                let codes = d.statusCounts.keys.sorted().map { "\($0)×\(d.statusCounts[$0]!)" }.joined(separator: ", ")
                return .invalid(d.serverErrorResponses > 0 ? .endpointFailure : .unexpectedResponse, "HTTP 狀態 \(codes)")
            }
            if r.direction == .download, d.tinyResponses > 0, d.tinyResponses * 2 >= max(1, d.completedOK) {
                return .invalid(.insufficientPayload, "\(d.tinyResponses) 個回應內容過小（最小 \(d.smallestResponseBytes ?? 0) bytes，要求 \(d.expectedBytesPerRequest ?? 0) bytes）")
            }
            if r.direction == .download, let bad = d.contentTypes.first(where: { $0.contains("text/html") || $0.contains("application/json") }) {
                return .invalid(.unexpectedResponse, "回應類型 \(bad)，不是測速資料")
            }
            if bytes == 0 {
                if d.timeoutCount > 0 { return .invalid(.timeout, "逾時 × \(d.timeoutCount)，未收到資料") }
                if d.errorCount > 0 { return .invalid(.endpointFailure, d.errorSamples.first ?? "連線錯誤") }
            }
        }
        if bytes == 0 { return .invalid(.noData, "沒有傳輸任何資料") }
        if bytes < minimumBytes && seconds >= minimumDuration {
            let errors = r.diagnostics?.errorCount ?? 0
            return .invalid(errors > 0 ? .endpointFailure : .insufficientPayload,
                            "\(Fmt.d(seconds, 1)) 秒僅 \(bytes) bytes（異常過小的回應）")
        }
        return .ok
    }
}

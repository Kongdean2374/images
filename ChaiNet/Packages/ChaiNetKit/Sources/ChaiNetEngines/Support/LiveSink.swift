import Foundation
import ChaiNetCore

/// Receives live progress from an engine while it measures, for the running-test screen:
/// `sample(series, sample)` for time series (e.g. "IPv4" / "IPv6") and `note(text)` for a short
/// Traditional-Chinese description of what is being measured right now. Display only.
public struct LiveSink: Sendable {
    public var sample: @Sendable (String, LatencySample) -> Void
    public var note: @Sendable (String) -> Void

    public init(sample: @escaping @Sendable (String, LatencySample) -> Void = { _, _ in },
                note: @escaping @Sendable (String) -> Void = { _ in }) {
        self.sample = sample
        self.note = note
    }

    public static let none = LiveSink()
}

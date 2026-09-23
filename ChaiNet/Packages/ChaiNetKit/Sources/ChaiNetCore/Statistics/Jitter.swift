import Foundation

/// Jitter (packet delay variation) estimators.
///
/// Both estimators operate on the RTTs of *received* probes in send order. Lost probes are
/// removed before calling, so a loss does not create an artificial jump.
public enum Jitter {

    /// Mean absolute difference between consecutive RTTs (the "jitter" reported by most
    /// speed-test and gaming tools, a form of IPDV — RFC 5481).
    ///
    ///     J = (1 / (n − 1)) · Σᵢ₌₁ⁿ⁻¹ |Rᵢ − Rᵢ₋₁|
    ///
    /// Returns `nil` with fewer than 2 samples.
    public static func meanConsecutiveDifference(_ rtts: [Double]) -> Double? {
        guard rtts.count > 1 else { return nil }
        var total = 0.0
        for i in 1..<rtts.count {
            total += abs(rtts[i] - rtts[i - 1])
        }
        return total / Double(rtts.count - 1)
    }

    /// RFC 3550 §6.4.1 inter-arrival jitter, applied to RTTs.
    ///
    ///     Dᵢ = Rᵢ − Rᵢ₋₁
    ///     Jᵢ = Jᵢ₋₁ + (|Dᵢ| − Jᵢ₋₁) / 16,   J₀ = 0
    ///
    /// This is an exponentially smoothed estimator (gain 1/16) that is used by RTP / VoIP
    /// stacks. It reacts slower than the mean difference and is less sensitive to single spikes.
    public static func rfc3550(_ rtts: [Double]) -> Double? {
        guard rtts.count > 1 else { return nil }
        var jitter = 0.0
        for i in 1..<rtts.count {
            let d = abs(rtts[i] - rtts[i - 1])
            jitter += (d - jitter) / 16.0
        }
        return jitter
    }
}

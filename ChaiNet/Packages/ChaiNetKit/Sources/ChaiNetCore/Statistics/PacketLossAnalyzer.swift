import Foundation

/// How losses are distributed over time.
public enum LossPattern: String, Codable, Sendable, Hashable, CaseIterable {
    /// No packet was lost.
    case none
    /// All losses are isolated single packets (typical for light random loss / RF noise).
    case random
    /// All losses happen in runs of consecutive packets (typical for queue overflow,
    /// Wi-Fi roaming, radio handover or a short outage).
    case burst
    /// Both isolated and burst losses occurred.
    case mixed
}

/// Result of analysing a probe sequence for loss.
public struct LossAnalysis: Codable, Sendable, Hashable {
    /// Probes sent.
    public var sent: Int
    /// Probes answered in time.
    public var received: Int
    /// `sent − received`.
    public var lost: Int
    /// `lost / sent × 100`.
    public var lossPercent: Double
    /// Number of loss runs shorter than the burst threshold (isolated losses).
    public var randomLossEvents: Int
    /// Number of loss runs whose length ≥ burst threshold.
    public var burstEvents: Int
    /// Packets lost inside burst runs.
    public var packetsLostInBursts: Int
    /// Length of the longest run of consecutive losses.
    public var longestBurst: Int
    /// Isolated lost packets / sent × 100.
    public var randomLossPercent: Double
    /// Burst lost packets / sent × 100.
    public var burstLossPercent: Double
    /// Gilbert–Elliott `p`: P(loss | previous packet received).
    public var lossProbabilityAfterReceive: Double
    /// Gilbert–Elliott `r`: P(received | previous packet lost).
    public var recoveryProbabilityAfterLoss: Double
    /// Qualitative classification.
    public var pattern: LossPattern
    /// Minimum run length counted as a burst.
    public var burstThreshold: Int

    public static let empty = LossAnalysis(
        sent: 0, received: 0, lost: 0, lossPercent: 0, randomLossEvents: 0, burstEvents: 0,
        packetsLostInBursts: 0, longestBurst: 0, randomLossPercent: 0, burstLossPercent: 0,
        lossProbabilityAfterReceive: 0, recoveryProbabilityAfterLoss: 0, pattern: .none,
        burstThreshold: 2)
}

/// Packet-loss analysis that separates random loss from burst loss.
///
/// Input: the delivery outcome of each probe in *send order* (`true` = received).
///
/// Definitions:
///
///     loss%           = lost / sent × 100
///     loss run        = maximal sequence of consecutive `false`
///     random event    = run with length < burstThreshold  (default threshold 2 → single losses)
///     burst event     = run with length ≥ burstThreshold
///     random loss%    = packets in random runs / sent × 100
///     burst loss%     = packets in burst runs  / sent × 100   (random% + burst% = loss%)
///
/// Two-state Gilbert–Elliott transition estimates:
///
///     p = #(received → lost) / #(received packets that have a successor)
///     r = #(lost → received) / #(lost packets that have a successor)
///
/// A high `p` with a high `r` means scattered loss; a low `r` means that once loss starts it
/// tends to continue (bursty channel).
public enum PacketLossAnalyzer {

    public static func analyze(received: [Bool], burstThreshold: Int = 2) -> LossAnalysis {
        let threshold = max(2, burstThreshold)
        let sent = received.count
        guard sent > 0 else {
            var empty = LossAnalysis.empty
            empty.burstThreshold = threshold
            return empty
        }

        let receivedCount = received.lazy.filter { $0 }.count
        let lost = sent - receivedCount

        // Run-length encode the losses.
        var runs: [Int] = []
        var current = 0
        for delivered in received {
            if delivered {
                if current > 0 { runs.append(current); current = 0 }
            } else {
                current += 1
            }
        }
        if current > 0 { runs.append(current) }

        let randomRuns = runs.filter { $0 < threshold }
        let burstRuns = runs.filter { $0 >= threshold }
        let randomPackets = randomRuns.reduce(0, +)
        let burstPackets = burstRuns.reduce(0, +)

        // Gilbert–Elliott transition counts.
        var goodWithSuccessor = 0, goodToBad = 0
        var badWithSuccessor = 0, badToGood = 0
        if sent > 1 {
            for i in 0..<(sent - 1) {
                if received[i] {
                    goodWithSuccessor += 1
                    if !received[i + 1] { goodToBad += 1 }
                } else {
                    badWithSuccessor += 1
                    if received[i + 1] { badToGood += 1 }
                }
            }
        }

        let pattern: LossPattern
        if lost == 0 {
            pattern = .none
        } else if burstRuns.isEmpty {
            pattern = .random
        } else if randomRuns.isEmpty {
            pattern = .burst
        } else {
            pattern = .mixed
        }

        let total = Double(sent)
        return LossAnalysis(
            sent: sent,
            received: receivedCount,
            lost: lost,
            lossPercent: Double(lost) / total * 100,
            randomLossEvents: randomRuns.count,
            burstEvents: burstRuns.count,
            packetsLostInBursts: burstPackets,
            longestBurst: runs.max() ?? 0,
            randomLossPercent: Double(randomPackets) / total * 100,
            burstLossPercent: Double(burstPackets) / total * 100,
            lossProbabilityAfterReceive: goodWithSuccessor > 0 ? Double(goodToBad) / Double(goodWithSuccessor) : 0,
            recoveryProbabilityAfterLoss: badWithSuccessor > 0 ? Double(badToGood) / Double(badWithSuccessor) : 0,
            pattern: pattern,
            burstThreshold: threshold)
    }
}

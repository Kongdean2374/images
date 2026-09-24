import Foundation

public struct OBSPreset: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    /// Video + audio bitrate in kbps.
    public var bitrateKbps: Double
    public var id: String { name }

    public static let standard: [OBSPreset] = [
        OBSPreset(name: "720p30", bitrateKbps: 3_000 + 160),
        OBSPreset(name: "720p60", bitrateKbps: 4_500 + 160),
        OBSPreset(name: "1080p30", bitrateKbps: 4_500 + 160),
        OBSPreset(name: "1080p60", bitrateKbps: 6_000 + 160),
        OBSPreset(name: "1440p60 (YouTube)", bitrateKbps: 12_000 + 160),
        OBSPreset(name: "4K30 (YouTube)", bitrateKbps: 20_000 + 160),
        OBSPreset(name: "4K60 (YouTube)", bitrateKbps: 35_000 + 160),
    ]
}

public struct OBSPresetVerdict: Codable, Sendable, Hashable, Identifiable {
    public var preset: OBSPreset
    public var verdict: SuitabilityVerdict
    public var id: String { preset.id }
}

public struct OBSSuitabilityResult: Codable, Sendable, Hashable {
    public var upload: SpeedResult
    public var uploadLoadedLatency: LatencyStatistics?
    public var idleLatency: LatencyStatistics?
    /// P10 of upload throughput.
    public var sustainedMbps: Double
    /// Recommended OBS bitrate (kbps).
    public var recommendedBitrateKbps: Double
    public var presets: [OBSPresetVerdict]
    public var warnings: [String]
    public var score: Int?
}

/// OBS / live-streaming upload suitability.
///
///     sustained          = P10(upload interval throughput)           (Mbps)
///     recommendedKbps    = sustained × 1000 × 0.75                   (keep 25 % headroom for
///                                                                     retransmissions & other apps)
///     ratio(preset)      = preset.kbps / (sustained × 1000)
///     verdict            = ≤ 0.60 great · ≤ 0.75 playable · ≤ 0.90 degraded · else unsuitable
///
/// A stability score < 70 or upload bufferbloat > 100 ms downgrades every preset by one step,
/// because RTMP/SRT encoders drop frames when the uplink queue oscillates.
public enum OBSSuitabilityCalculator {
    public static let headroom = 0.75

    static func verdict(ratio: Double) -> SuitabilityVerdict {
        switch ratio {
        case ...0.60: .great
        case ...0.75: .playable
        case ...0.90: .degraded
        default: .unsuitable
        }
    }

    static func downgrade(_ v: SuitabilityVerdict) -> SuitabilityVerdict {
        switch v {
        case .great: .playable
        case .playable: .degraded
        case .degraded, .unsuitable: .unsuitable
        }
    }

    public static func evaluate(upload: SpeedResult, idleLatency: LatencyStatistics?, uploadLoadedLatency: LatencyStatistics?,
                                presets: [OBSPreset] = OBSPreset.standard, score: Int?) -> OBSSuitabilityResult {
        // P10 when short windows are reliable; bytes / elapsed time when progress reporting is batched.
        let sustained = upload.summary.sustainedMbps
        let capacityKbps = sustained * 1000
        var warnings: [String] = []

        // Unavailable stability (sampling artifact) is a measurement limitation, not instability.
        let stability = upload.summary.reliableStabilityScore
        var bloat: Double?
        if let idle = idleLatency?.rtt?.median, let loaded = uploadLoadedLatency?.rtt?.median {
            bloat = max(0, loaded - idle)
        }
        let unstable = stability.map { $0 < 70 } ?? false
        let bloated = (bloat ?? 0) > 100
        if unstable { warnings.append("上傳速度不穩定（穩定度 \(Int(stability ?? 0))/100），直播可能掉幀。") }
        if bloated { warnings.append("上傳時延遲增加 \(Int(bloat ?? 0)) ms（上行 Bufferbloat）。") }

        let verdicts = presets.map { preset -> OBSPresetVerdict in
            var v = capacityKbps > 0 ? verdict(ratio: preset.bitrateKbps / capacityKbps) : .unsuitable
            if unstable || bloated { v = downgrade(v) }
            return OBSPresetVerdict(preset: preset, verdict: v)
        }
        return OBSSuitabilityResult(upload: upload, uploadLoadedLatency: uploadLoadedLatency, idleLatency: idleLatency,
                                    sustainedMbps: sustained, recommendedBitrateKbps: capacityKbps * headroom,
                                    presets: verdicts, warnings: warnings, score: score)
    }
}

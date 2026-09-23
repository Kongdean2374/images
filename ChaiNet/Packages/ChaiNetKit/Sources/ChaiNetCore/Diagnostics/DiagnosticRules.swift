import Foundation

/// The built-in rule set. Thresholds are documented on each rule.
public enum DiagnosticRules {

    static func fmt(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }

    /// download > 100 Mbps AND upload < 3 Mbps → uplink congestion / heavily asymmetric plan.
    public static let uplinkCongestion = ClosureRule(.uplinkCongestion) { m in
        guard let dl = m.downloadMbps, let ul = m.uploadMbps, dl > 100, ul < 3 else { return nil }
        return DiagnosticFinding(code: .uplinkCongestion, severity: .warning, title: "上行壅塞",
            detail: "下載 \(fmt(dl)) Mbps，但上傳僅 \(fmt(ul)) Mbps。下行充足而上行極低，通常代表上行鏈路壅塞或方案嚴重不對稱。",
            recommendation: "檢查是否有裝置正在上傳（雲端備份、監視器），或向 ISP 確認上行頻寬。")
    }

    /// download / upload > 20 AND upload < 10 → info: asymmetric link (only when not already congestion).
    public static let asymmetricLink = ClosureRule(.asymmetricLink) { m in
        guard let dl = m.downloadMbps, let ul = m.uploadMbps, ul > 0, dl / ul > 20, ul < 10, !(dl > 100 && ul < 3) else { return nil }
        return DiagnosticFinding(code: .asymmetricLink, severity: .info, title: "上下行不對稱",
            detail: "下載是上傳的 \(Int(dl / ul)) 倍。",
            recommendation: "直播、視訊會議或上傳大檔時可能受上行限制。")
    }

    /// idle latency < 30 ms AND jitter > 80 ms → low latency but extremely unstable.
    public static let lowLatencyHighJitter = ClosureRule(.lowLatencyHighJitter) { m in
        guard let lat = m.idleLatencyMs, let j = m.jitterMs, lat < 30, j > 80 else { return nil }
        return DiagnosticFinding(code: .lowLatencyHighJitter, severity: .critical, title: "延遲低但極度不穩定",
            detail: "基準延遲 \(fmt(lat)) ms，但抖動高達 \(fmt(j)) ms。線路本身很近，但封包排隊或無線干擾造成劇烈波動。",
            recommendation: "改用有線或 5 GHz / 6 GHz Wi-Fi，並檢查路由器是否啟用 SQM / QoS。")
    }

    /// jitter > 30 ms → warning (> 60 critical).
    public static let highJitter = ClosureRule(.highJitter) { m in
        guard let j = m.jitterMs, j > 30 else { return nil }
        return DiagnosticFinding(code: .highJitter, severity: j > 60 ? .critical : .warning, title: "抖動偏高",
            detail: "抖動 \(fmt(j)) ms。語音與遊戲會出現斷斷續續或延遲忽高忽低。",
            recommendation: "減少同網段的大流量傳輸，靠近路由器或改用有線連線。")
    }

    /// loss > 5 % → critical.
    public static let severePacketLoss = ClosureRule(.severePacketLoss) { m in
        guard let loss = m.lossPercent, loss > 5 else { return nil }
        return DiagnosticFinding(code: .severePacketLoss, severity: .critical, title: "嚴重封包遺失",
            detail: "封包遺失率 \(fmt(loss))%。超過 5% 時幾乎所有即時應用都會明顯受影響。",
            recommendation: "檢查訊號強度、線材與路由器，若持續發生請聯絡 ISP。")
    }

    /// 1 % < loss ≤ 5 % → warning.
    public static let moderatePacketLoss = ClosureRule(.moderatePacketLoss) { m in
        guard let loss = m.lossPercent, loss > 1 else { return nil }
        return DiagnosticFinding(code: .moderatePacketLoss, severity: .warning, title: "封包遺失",
            detail: "封包遺失率 \(fmt(loss))%。",
            recommendation: "遊戲與語音可能出現瞬間卡頓。")
    }

    /// Burst or mixed loss pattern with burst loss ≥ 0.5 %.
    public static let burstLoss = ClosureRule(.burstLoss) { m in
        guard let pattern = m.lossPattern, pattern == .burst || pattern == .mixed,
              let burst = m.burstLossPercent, burst >= 0.5 else { return nil }
        return DiagnosticFinding(code: .burstLoss, severity: .warning, title: "連續性封包遺失",
            detail: "有 \(fmt(burst))% 的封包是連續遺失（burst loss），而非零星隨機遺失。",
            recommendation: "連續遺失通常來自佇列溢出、Wi-Fi 漫遊或基地台切換，而非單純訊號雜訊。")
    }

    static func bloat(_ code: DiagnosticCode, _ label: String, _ value: Double?) -> DiagnosticFinding? {
        guard let v = value, v > 100 else { return nil }
        return DiagnosticFinding(code: code, severity: v > 300 ? .critical : .warning, title: "\(label) Bufferbloat",
            detail: "\(label)滿載時延遲增加 \(fmt(v, 0)) ms（等級 \(BufferbloatGrade.from(increaseMs: v).rawValue)）。",
            recommendation: "在路由器啟用 SQM（fq_codel / CAKE）並將頻寬限制設為實測值的 90–95%。")
    }

    /// Loaded latency increase > 100 ms → warning, > 300 ms → critical.
    public static let downloadBufferbloat = ClosureRule(.downloadBufferbloat) { bloat(.downloadBufferbloat, "下載", $0.downloadBloatMs) }
    public static let uploadBufferbloat = ClosureRule(.uploadBufferbloat) { bloat(.uploadBufferbloat, "上傳", $0.uploadBloatMs) }

    /// idle latency > 100 ms → warning.
    public static let highLatency = ClosureRule(.highLatency) { m in
        guard let lat = m.idleLatencyMs, lat > 100 else { return nil }
        return DiagnosticFinding(code: .highLatency, severity: .warning, title: "延遲偏高",
            detail: "閒置延遲 \(fmt(lat)) ms。",
            recommendation: "改選較近的測速伺服器確認，或檢查 VPN / Proxy 是否繞遠路。")
    }

    /// stability < 60 → warning.
    public static let unstableDownload = ClosureRule(.unstableDownload) { m in
        guard let s = m.downloadStability, s < 60 else { return nil }
        return DiagnosticFinding(code: .unstableDownload, severity: .warning, title: "下載速度不穩定",
            detail: "下載穩定度 \(Int(s))/100，速度曲線波動大。",
            recommendation: "串流可能頻繁切換畫質。檢查 Wi-Fi 干擾或尖峰時段壅塞。")
    }

    public static let unstableUpload = ClosureRule(.unstableUpload) { m in
        guard let s = m.uploadStability, s < 60 else { return nil }
        return DiagnosticFinding(code: .unstableUpload, severity: .warning, title: "上傳速度不穩定",
            detail: "上傳穩定度 \(Int(s))/100。",
            recommendation: "直播建議使用較低且固定的位元率。")
    }

    /// download < 10 Mbps → warning.
    public static let lowDownload = ClosureRule(.lowDownload) { m in
        guard let dl = m.downloadMbps, dl < 10 else { return nil }
        return DiagnosticFinding(code: .lowDownload, severity: .warning, title: "下載速度偏低",
            detail: "下載僅 \(fmt(dl)) Mbps。",
            recommendation: "高畫質串流與大型下載可能受影響。")
    }

    /// system DNS median − best alternative median > 30 ms → info.
    public static let slowSystemDNS = ClosureRule(.slowSystemDNS) { m in
        guard let sys = m.systemDNSMs, let best = m.bestDNSMs, sys - best > 30 else { return nil }
        return DiagnosticFinding(code: .slowSystemDNS, severity: .info, title: "系統 DNS 較慢",
            detail: "系統 DNS 中位數 \(fmt(sys, 0)) ms，\(m.bestDNSName ?? "其他解析器") 僅 \(fmt(best, 0)) ms。",
            recommendation: "可考慮在 iOS 設定或路由器改用較快的 DNS。")
    }

    public static let ipv6Unavailable = ClosureRule(.ipv6Unavailable) { m in
        guard m.supportsIPv6 == false, m.supportsIPv4 == true else { return nil }
        return DiagnosticFinding(code: .ipv6Unavailable, severity: .info, title: "無 IPv6",
            detail: "目前網路僅支援 IPv4。",
            recommendation: "部分服務在 IPv6 下延遲較低，可向 ISP 或路由器確認 IPv6 設定。")
    }

    public static let vpnActive = ClosureRule(.vpnActive) { m in
        guard m.vpnDetected == true else { return nil }
        return DiagnosticFinding(code: .vpnActive, severity: .info, title: "偵測到 VPN",
            detail: "結果反映的是經過 VPN 通道後的品質（啟發式判斷）。",
            recommendation: "若要測試原生線路，請暫時關閉 VPN 後重測。")
    }

    public static let lowDataMode = ClosureRule(.lowDataMode) { m in
        guard m.isConstrained == true else { return nil }
        return DiagnosticFinding(code: .lowDataMode, severity: .warning, title: "低數據模式已開啟",
            detail: "iOS 低數據模式可能限制背景流量並影響測速結果。",
            recommendation: "在設定中關閉低數據模式後重測。")
    }

    public static let expensiveNetwork = ClosureRule(.expensiveNetwork) { m in
        guard m.isExpensive == true else { return nil }
        return DiagnosticFinding(code: .expensiveNetwork, severity: .info, title: "計量網路",
            detail: "目前為行動網路或個人熱點，測速會消耗數據流量。",
            recommendation: "注意數據用量上限。")
    }

    /// ≥ 3 spikes → warning.
    public static let latencySpikes = ClosureRule(.latencySpikes) { m in
        guard let n = m.spikeCount, n >= 3 else { return nil }
        return DiagnosticFinding(code: .latencySpikes, severity: .warning, title: "延遲突波",
            detail: "監測期間偵測到 \(n) 次延遲突波。",
            recommendation: "突波常見於 Wi-Fi 掃描、背景同步或頻道干擾。")
    }

    /// ≥ 1 drop → critical.
    public static let networkDrops = ClosureRule(.networkDrops) { m in
        guard let n = m.dropCount, n >= 1 else { return nil }
        return DiagnosticFinding(code: .networkDrops, severity: .critical, title: "網路中斷",
            detail: "監測期間發生 \(n) 次連線中斷（連續多個封包無回應）。",
            recommendation: "檢查路由器日誌、線路狀態或行動訊號覆蓋。")
    }

    public static let http3Unavailable = ClosureRule(.http3Unavailable) { m in
        guard m.http3Supported == false else { return nil }
        return DiagnosticFinding(code: .http3Unavailable, severity: .info, title: "未使用 HTTP/3",
            detail: "與伺服器的連線未協商出 HTTP/3 (QUIC)，可能是伺服器不支援或 UDP 443 被阻擋。",
            recommendation: "若網路封鎖 UDP，QUIC 會自動退回 HTTP/2，一般不影響使用。")
    }

    /// TLS handshake > 150 ms → info.
    public static let slowTLS = ClosureRule(.slowTLS) { m in
        guard let t = m.tlsHandshakeMs, t > 150 else { return nil }
        return DiagnosticFinding(code: .slowTLS, severity: .info, title: "TLS 交握偏慢",
            detail: "TLS 交握 \(fmt(t, 0)) ms。",
            recommendation: "高延遲或封包遺失會放大交握時間。")
    }

    /// path MTU < 1400 → info (tunnel / PPPoE overhead).
    public static let reducedMTU = ClosureRule(.reducedMTU) { m in
        guard let mtu = m.pathMTU, mtu < 1400 else { return nil }
        return DiagnosticFinding(code: .reducedMTU, severity: .info, title: "路徑 MTU 偏小",
            detail: "路徑 MTU 為 \(mtu) bytes（標準乙太網路為 1500）。",
            recommendation: "常見於 VPN、PPPoE 或行動網路通道；若有連線異常可調整 MSS clamping。")
    }

    public static let all: [any DiagnosticRule] = [
        uplinkCongestion, asymmetricLink, lowLatencyHighJitter, highJitter, severePacketLoss, moderatePacketLoss,
        burstLoss, downloadBufferbloat, uploadBufferbloat, highLatency, unstableDownload, unstableUpload, lowDownload,
        slowSystemDNS, ipv6Unavailable, vpnActive, lowDataMode, expensiveNetwork, latencySpikes, networkDrops,
        http3Unavailable, slowTLS, reducedMTU,
    ]
}

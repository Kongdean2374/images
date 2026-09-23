# ChaiNet（iOS）

Network Diagnostics · Speed Test · Gaming Network Analyzer · Stability Monitoring · Root Cause Diagnostics。
Swift 6 / SwiftUI / Swift Concurrency / Network.framework / URLSession / SwiftData / Swift Charts / CoreLocation / MapKit，**無第三方相依套件**。

> Beginners can understand it. Power users can control it. Engineers can inspect it. AI can analyze it.

## 專案結構

```
ChaiNet/
├─ project.yml                     XcodeGen 規格（CI 產生 .xcodeproj）
├─ Packages/ChaiNetKit/            所有非 UI 程式（可獨立 swift test）
│  ├─ Sources/ChaiNetCore/         純運算：模型、統計、評分、診斷、根因分析、匯出（無網路）
│  │  ├─ Statistics/               Percentile / Jitter / PacketLoss / Speed / Stability / Bufferbloat / 突波 / 斷線
│  │  ├─ Models/                   TestResult、NetworkSnapshot、Availability（iOS 不提供 → unavailable）
│  │  ├─ Scoring/                  ScoreEngine（5 種情境權重 + 上限）
│  │  ├─ Diagnostics/              規則式快速發現（單次測試）
│  │  ├─ RootCause/                DiagnosticSession / Evidence / Hypothesis / RootCauseAnalyzer /
│  │  │                            CrossTestAnalyzer / AnomalyDetector / BaselineEngine / DiagnosticReportGenerator
│  │  ├─ Quality/                  Gaming / Voice（E-model）/ Streaming / OBS
│  │  ├─ Codecs/                   ICMP、DNS wire format
│  │  ├─ Product/                  速度單位、測試項目 / 設定檔、疑難排解規劃、AppSettings、歷史儀表板
│  │  └─ Export/                   CSV（RFC 4180）/ JSON
│  ├─ Sources/ChaiNetEngines/      量測引擎（每個都有 Protocol，可 Mock）
│  │  ├─ Speed/                    多連線 URLSession 測速（2/4/8/16 自適應，資料只在記憶體）
│  │  ├─ Latency/                  HTTP / TCP / TLS / QUIC / UDP echo / ICMP 探測 + 固定速率取樣器
│  │  ├─ DNS/ Protocols/ Route/    DNS（系統 / UDP / DoH）、HTTP 時序、Traceroute、MTU
│  │  ├─ NetworkInfo/              NWPathMonitor、getifaddrs、VPN 啟發式、CoreTelephony 制式
│  │  ├─ Compare/                  多端點交叉驗證、IPv4/IPv6、Wi-Fi/行動網路同時比較
│  │  ├─ Monitor/                  連續 Ping、突波 / 斷線 / 路徑變更
│  │  ├─ Runner/                   TestRunner：執行任意 TestItem 組合 → TestResult
│  │  └─ Mocks/                    測試與預覽用（不會被當成量測資料）
│  └─ Tests/                       XCTest（所有公式、診斷規則、根因假設皆有測試）
├─ ChaiNet/                        App（Feature-based MVVM）
│  ├─ App/                         組合根 AppContainer、TaskRegistry、背景檢查
│  ├─ DesignSystem/                Dark-first 色票、卡片、圖表元件
│  ├─ Persistence/                 SwiftData（StoredResult / StoredSession）、設定
│  ├─ Services/                    位置（選用、只存本機）、匯出
│  └─ Features/                    Home / SpeedTest / Tools / Diagnostics / History / Settings / Results
└─ ChaiNetTests/                   App 層 XCTest（ViewModel、取消行為、SwiftData）
```

## 關鍵設計

| 需求 | 實作 |
| --- | --- |
| 完整速度 timeline | 每 100 ms 取樣共享位元組計數器；保留全部樣本；平均為時間加權；峰值為 3 樣本移動平均最大值 |
| Adaptive parallel streams | `StreamScalingPolicy`：<25 Mbps→2、<100→4、<400→8、≥400→16，前 40% 時間每秒評估、只增不減；每條 stream 使用獨立 URLSession（避免 HTTP/2 多工成單一連線） |
| 下載不寫入磁碟 | `URLSessionDataDelegate` 收到即計數並丟棄；ephemeral session、無 cache、不使用 download task |
| 上傳 | 記憶體產生的隨機（不可壓縮）payload |
| 封包遺失 | UDP echo（自架伺服器）或 ICMP；TCP 會重傳隱藏遺失所以不用 TCP；區分隨機 / 連續遺失並計算 Gilbert–Elliott p/r |
| Bufferbloat | 閒置中位數 vs 下載時 / 上傳時中位數（另開連線同時量測） |
| 評分 | 五種情境不同權重 + 致命指標上限（例如遺失 > 5% 遊戲最多 25 分） |
| 根因診斷 | 證據 → 假設（log-odds 加權、上限、排除條件、缺少資料則「證據不足」）；跨伺服器 / IP 版本 / 網路類型 / 歷史基準交叉比較 |
| 可取消 | 所有 engine 以 `AsyncThrowingStream` + `onTermination` 取消；停止、離開頁面、進入背景（`TaskRegistry.cancelAll()`）都會取消並保留部分結果 |

## iOS 平台限制與替代方式

| 功能 | 狀態 | 替代方式 |
| --- | --- | --- |
| RSRP / RSRQ / SINR / NR 頻段 / Cell ID | iOS 不提供 → 顯示「無法取得」 | 電話 App `*3001#12345#*` Field Test |
| LTE / 5G NSA / 5G SA | 可取得（CoreTelephony 制式字串） | — |
| 強制切換 LTE / 5G | 不可 | 使用者於設定切換後加入同一診斷工作階段 |
| Wi-Fi RSSI | 不提供 | 路由器介面 |
| SSID | 需特殊授權（未簽名版本無） | — |
| VPN 偵測 | 無公開 API → 啟發式並標示方法 | — |
| Traceroute / MTU | ICMP datagram socket，僅 IPv4 | IPv6 保留於架構中 |
| 背景持續監控 | 不可；僅 BGAppRefresh（系統排程、短時間） | 前景監測 |
| 下載 / 上傳指定 IPv4/IPv6 | URLSession 不支援 | 延遲 / 遺失測試可指定 |

## 建置

CI（`.github/workflows/ios.yml`）在 macOS runner 上：選擇 Xcode → `xcodegen generate` → `xcodebuild -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO` → 驗證 `.app` → `Payload/ChaiNet.app` → `ChaiNet-unsigned.ipa` → upload-artifact；失敗時保留完整 `xcodebuild.log`。不需要任何憑證、Team ID 或 Provisioning Profile。

本機：

```sh
brew install xcodegen
cd ChaiNet && xcodegen generate && open ChaiNet.xcodeproj
swift test --package-path Packages/ChaiNetKit     # 核心與引擎單元測試
```

## 預設伺服器

內建 Cloudflare 公用測速端點（`speed.cloudflare.com/__down`、`/__up`，ICMP 以 1.1.1.1 量測遺失），開箱即可使用。
自架伺服器請部署 `backend/`，並在「設定 › 伺服器」加入 URL 與 UDP echo port。

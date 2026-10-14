# GPSTracker 整合修改交付（2026-10-14）

修改基底：`claude/fix-health-import-route-playback-20261004`，原 HEAD `ce634b6970b2e49405219a3e1b85f7866d977b77`。

這份交付包含實際程式修改及本機測試。依使用者最新指示，上傳完整修改檔到此開發分支，**不使用雲端 Mac、不建置 IPA、不發布**。`ios-build.yml` 移除 push 觸發，保留 `workflow_dispatch`；交付提交另含 `[skip ci]`。

**驗收狀態：本機核心及可攜式整合檢查通過；尚未經 Xcode 編譯、SwiftData 真實裝置遷移或 iPhone 驗收，不能視為已通過完整 iOS 發行驗收。**

## 30 項施工對照

| 項 | 程式狀態及對應實作 |
|---|---|
| 1 | 已實作：MeasurementEvidence 及 CalibrationEligibility；僅確認的獨立 GPS／外部實測距離可成為候選。 |
| 2 | 已實作：同步 workout、距離 sample、route 的場次 UUID／距離方法 metadata；回流逐一核對來源、時間、關聯與方法。估值及遺失證據皆不訓練。 |
| 3 | 已實作：校正入口完全不呼叫每日資料；dailyStrideSamples 保留統計用途，workoutStrideSamples 不再直接生成未審核樣本。 |
| 4 | 已實作：GPS 與 stepAssistedDistance 分開保存；混合全場不回訓。現有計步器沒有可靠 GPS 子段步數時，整場保守排除。 |
| 5 | 已實作：軌跡點數不再決定距離來源；HealthKit 查距離 sample、步數 sample、route 來源及 metadata。第三方缺方法證據保留未知，不能靠 App 名稱白名單猜測 GPS。 |
| 6 | 已實作：同場次 UUID、同源樣本及完整時間窗檢查；本機暫停邊界計步回報延遲超過 5 秒標記未確認對齊。 |
| 7 | 已實作：原始 WorkoutSession 保留；每筆 calibrationDecisionJSON 持久化資格、版本、品質與理由。訓練資料集引用場次，不複製／刪除原始路線。 |
| 8 | 已實作：精度、缺口、時間倒流、重複點、速度／加速度／遠距跳點及起終覆蓋分析；原始收到座標保留，分析不改寫原始位置。 |
| 9 | 已實作：步幅、類型、步頻、有效秒數、速度、GPS 覆蓋、來源及個人分布檢查，走跑合理範圍分開。 |
| 10 | 已實作：以個人中位數／MAD 偵測顯著差異，標待確認，沒有宣稱屬於他人。 |
| 11 | 已實作：穩定 UUID／來源場次優先，另檢查完整起訖、活動類別、98% 時間重疊及 2% 距離差；取消／失敗不推進匯入游標。 |
| 12 | 已實作：A/B/C/D 及機器 reasonCode／繁中理由，主分類互斥，原因可多標籤。 |
| 13 | 已實作：至少 6 個可信場次，較早訓練、較晚至少 2 場留出；均值及最差誤差均須改善／不退化，變動超過 25% 不套用；模型快照可回退。 |
| 14 | 已實作：真實計步 callback 的增量步數 × 該窗基礎步幅累加，記錄 EstimateWindow，不重算已走區段或製造逐秒資料。 |
| 15 | 已實作保守降級：CoreMotion 走跑證據、步頻平滑、8 秒滯後切換基礎 Profile。沒有足夠對齊真值時，不建立步頻曲線或假裝可靠辨識快走／快跑；維持走／跑／未知。 |
| 16 | 已實作：ruck 獨立 Profile，不進 running；不足時用既有步行基礎，畫面明示未充分校正。 |
| 17 | 已實作：負重 Optional，未知為 nil；略過直接開始；上次值須明確選擇，熱量只計一次負重，不線性改步幅。 |
| 18 | 已實作保守降級：未知、手持、揮臂、口袋標籤可選；未感測／未驗證則無自動辨識或情境修正。 |
| 19 | 已實作：步頻平滑與類別滯後；可靠 stationary／automotive／cycling 證據下抑制增量。無可靠感測時不能保證區分每一個假步數，採保守基準。 |
| 20 | 已實作：既有個人／行軍步行基礎 → 系統距離增量 → 預設步幅；只對新區段切換來源。缺權限／不支援提供可見提示。 |
| 21 | 已實作：一鍵權限、全歷史完整匯入、分析、驗證、套用／保留及保存報告；進度、階段及安全取消。 |
| 22 | 已實作：最近 20 份報告、本機掃描分類分母、HealthKit 掃描／已有／新增、來源、各 Profile 候選數、理由及模型差異。 |
| 23 | 已實作：單筆品質與訓練資格頁，來源、時間、GPS 覆蓋、步幅、負重、理由及選擇排除；取消排除不能繞過安全門檻。 |
| 24 | 已實作：資料充分程度與獨立誤差分開，更新設定頁及詞彙，移除虛構固定 3–5%／5–10% 誤差。驗證不足明示尚無驗證。 |
| 25 | 已實作：首次分析後新保存／匯入資料自動候選分析；自動流程重用既有品質判斷，場次 UUID 冪等，保留手動全量重算。 |
| 26 | 已實作：動作分段裁切至本次有效區間，暫停關閉區段；session 保存有效／走／跑／未知時間與 pauseLog，配速／熱量／同步共用有效時間。 |
| 27 | 已實作：暫停停止計步更新，恢復新 epoch；generation 排除延遲 callback、重複／倒退回報不重算。有效步數用於 GPS Live Activity 與 session。 |
| 28 | 已實作：只新增 optional／有預設欄位；新版備份保存證據、品質、行軍、報告、快照、暫停與完整路線，舊版 Codable 可讀；資料庫失敗不刪除／搬走／重建原 store，還原採無損合併。 |
| 29 | 已實作：成功檔案物件驅動 sheet(item:)，直接 UIActivityViewController；TCX 必要欄位、跳脫與無 GPS 摘要；失敗 Alert。 |
| 30 | 已實作：單次 CSV 含 43 欄摘要及真實 route／window 列，無 GPS 仍有 summary；未知空白、RFC 欄位跳脫、獨立暫存路徑、背景匯出；歷史／分析／設定／PDF／備份共用分享元件。 |

## 資料保護與來源規則

- 不使用使用者的實際 108 筆資料做破壞性測試。本機測試只使用合成 fixture；既有 state 的 sampleCount 不因新版本重設。
- 新增欄位皆為 optional 或預設 `false`；原路線關聯保留，HealthKit 匯入不再抽稀，也不再以 HKWorkout 總距離縮放原始點累積距離。
- 大型資料庫匯入、分析與單次檔案生成使用在 detached executor 建立的 ModelActor。逐場保存，失敗回滾該筆；取消不套用半成品模型。
- 舊資料缺來源證據不事後補成 GPS 真值；保留原始歷史及模型，等待有效獨立新資料驗證。
- 「同時有距離＋步數」不代表可信：本 App strideEstimate 回寫 metadata 後，匯回仍為估算；metadata 遺失為 unknown；兩者皆不訓練。
- 每次的候選只在早期場次訓練，以後期獨立場次驗證，沒有把驗證集重新混入最終候選計算。新舊狀態及驗證摘要納入備份。

## 測試證據與可重跑命令

```sh
swift test
python3 Scripts/test_portable_integration.py
python3 Scripts/generate_xcodeproj.py
# Syntax-only; this does not validate Apple SDK types or linkage.
swiftc -frontend -parse $(rg --files GPSTracker GPSTrackerWidgets -g '*.swift')
git diff --check
```

本次用本機 Swift 6.0.3 Linux 工具鏈。23 個 XCTest 通過／0 失敗。可攜式整合腳本使用實際 Foundation 資料模型／CSV／TCX／備份程式（只移除 SwiftData 註記與替換非測試範圍的 iOS 型別），驗證：

- 無 GPS CSV 有摘要，TCX 可解析且沒有捏造 Position。
- 7,001 原始位置在 GPX／TCX／CSV 全數保留；獨立 Python csv／XML 解析通過，CSV 7,002 筆資料列（含摘要）、43 欄寬度一致，未知負重空白。
- 舊版 SessionBackup 缺新增欄位可讀；舊版 StrideState 保留 108 樣本；手動變更後回退恢復原值；報告分類合計對齊。
- 所有 120 個 app／widget Swift 檔通過語法解析；Xcode project 重新生成，包括 115 個 app source（widget 6，含 1 共享檔）。

**沒有個人真實 GPS 留出資料可在本次環境評估距離準確度；不提供杜撰百分比。** 合成 fixture 的候選驗證結果只代表算法行為，不代表個人運動誤差。

## 尚需 Xcode／實機驗收

Apple SDK 型別檢查及完整 iOS 編譯、真實 SwiftData store 的輕量遷移、CoreMotion 步頻及暫停邊界延遲、GPS 背景批次／中斷、螢幕關閉、HealthKit 讀寫權限與 sample／route 關聯、原有 108 筆資料保存、系統分享「儲存到檔案」、iPad 分享呈現，以及個人運動距離實測。

依使用者指示本次不執行 macOS Actions，也沒有產出 IPA。未來可由使用者自行在 GitHub Actions 選取此分支並手動 Run workflow，或在自己的 Mac 用 Xcode 建置；本次交付不代為啟動。

# MoneyLeft — 個人化記帳 App

把記帳的問題從「我花了多少」翻轉成 **「我今天還能花多少」**。
完全本地化、無廣告、無訂閱、不上傳任何資料，側載自簽安裝。

---

## 功能對照（依計劃書）

| 計劃書章節 | 狀態 | 實作位置 |
|---|---|---|
| §1-1 手動快速記帳 + 快速加值按鈕 | ✅ | `MoneyLeft/Views/ExpenseEditorView.swift` |
| §1-2 動態島 / Live Activity 記帳 | ✅ | `MoneyLeft/Services/LiveActivityController.swift`、`MoneyLeftWidget/ExpenseLiveActivity.swift`、`Shared/LiveActivityIntents.swift` |
| §1-3 Siri / App Intents 語音記帳 | ✅ | `MoneyLeft/Intents/AddExpenseIntent.swift` |
| §2-1 相機拍照辨識 | ✅ | `MoneyLeft/Views/Receipt/PhotoPicker.swift`（`CameraPicker`） |
| §2-2 相簿批次匯入辨識 | ✅ | `PhotoPicker`（PHPicker，可多選）+ `ReceiptFlowView` 佇列 |
| §2-3 Vision 本地 OCR + 確認畫面 | ✅ | `MoneyLeft/Services/ReceiptScanner.swift` |
| §3 剩餘可花額度 + Widget | ✅ | `HomeView`、`MoneyLeftWidget/RemainingBudgetWidget.swift` |
| §4 燒錢速度儀表 + 理想/實際軌跡 | ✅ | `BurnGaugeView`、`StatsView`（Swift Charts） |
| §5 消費情緒標籤 + 圓餅圖 | ✅ | `EmotionTag`、`StatsView`（SectorMark） |
| §6 分類系統（含**子分類**） | ✅ | `SpendingCategory`（self-referential）、`CategoryManagerView` |
| §7 SwiftData 本地資料庫 + 隱私說明 | ✅ | `Shared/Persistence.swift`、`PrivacyView` |
| §8 iCloud 私人同步（**可選**） | ✅ | 設定頁開關 → `ModelConfiguration(cloudKitDatabase: .private(...))`，失敗自動退回本機 |
| §9 CSV 匯出 | ✅ | `MoneyLeft/Services/CSVExporter.swift` |
| §10 統計報表（月/週/自訂） | ✅ | `MoneyLeft/Views/StatsView.swift` |
| §六 GitHub Actions 產未簽名 ipa | ✅ | `.github/workflows/build-unsigned-ipa.yml` |

### 計劃書裡標成「可選 / 選填 / 非必要」的，這版全部做了

- **iCloud 私人同步**（§8）：設定頁一個開關，走使用者自己的 CloudKit 私有資料庫。所有 Model 都照 CloudKit 規則設計（屬性有預設值、關聯皆 optional、不用 unique constraint）。沒有 iCloud 權限時自動退回本機，不會閃退。
- **子分類**（§6）：分類可以有父子兩層（餐飲 → 早餐/午餐/晚餐/飲料/宵夜），統計時自動歸戶到頂層分類。
- **收據原圖保存**（§資料模型 `receiptImageData` 選填）：OCR 後可保留原圖（externalStorage 儲存，設定頁可關）。
- **自訂情緒標籤**（§5「可自訂新增標籤」）：內建必要/衝動/享受，可自行新增顏色與名稱。
- **備註、店名選填欄位**：記帳與 OCR 都會帶。
- **快速加值金額自訂**（§1-1「+咖啡價」）：設定頁可增刪。
- **Live Activity 自動關閉**（§1-2「或設定自動於 N 小時後關閉」）：可選 1/2/4/8/12/24 小時或永不。

---

## 專案結構

```
project.yml                  # XcodeGen 專案定義（取代手寫 .xcodeproj）
Shared/                      # App 與 Widget 共用：Model、計算、Live Activity Intents
MoneyLeft/                   # 主 App（SwiftUI）
MoneyLeftWidget/             # WidgetKit Extension（主畫面小工具 + Live Activity UI）
.github/workflows/           # CI：產出未簽名 ipa
```

## 在本機開啟專案

```bash
brew install xcodegen
xcodegen generate
open MoneyLeft.xcodeproj
```

## 取得未簽名 ipa

1. push 到 `main` 或 `claude/**` 分支，或在 Actions 頁手動觸發 **Build unsigned IPA**
2. 等 workflow 跑完，下載 Artifact `MoneyLeft-unsigned-ipa`
3. 解壓得到 `MoneyLeft-unsigned.ipa`

CI 環境中 **不存放任何憑證或 provisioning profile**，簽名完全在你自己的電腦上做。

## 自行簽名安裝（側載）

用你慣用的工具（Sideloadly / AltStore / ESign / `codesign` 手動簽）對 ipa 重簽即可。
手動簽名時要注意：**主 App 和 Widget Extension 都要簽**，而且 Bundle ID 要有對應關係：

- App：`com.moneyleft.app`
- Widget：`com.moneyleft.app.widget`
- App Group：`group.com.moneyleft.app`

要換成自己的 Bundle ID，改這四個地方：
`project.yml`、`Shared/AppGroup.swift`、`MoneyLeft/MoneyLeft.entitlements`、`MoneyLeftWidget/MoneyLeftWidget.entitlements`。

### 側載的能力限制（先講清楚，免得以為是 bug）

| 功能 | 免費 Apple ID 自簽 | 有付費開發者帳號 |
|---|---|---|
| 記帳、OCR、報表、CSV | ✅ | ✅ |
| 主畫面 Widget | ✅（需 App Group entitlement 一起簽） | ✅ |
| 動態島 / Live Activity | ✅ | ✅ |
| Siri / App Intents | ✅ | ✅ |
| **iCloud 同步** | ❌ iCloud entitlement 需要付費帳號 | ✅ |

沒有 iCloud 權限時，App 會自動維持在本機模式，設定頁的「目前狀態」會顯示「僅存在本機」。

## 隱私

- 資料只寫在裝置本機（App Group 容器內的 SwiftData 資料庫）
- OCR 用 Apple Vision 在本機跑，照片不離開裝置
- 沒有帳號系統、沒有自家後端、沒有任何第三方 SDK
- 開啟 iCloud 同步時，資料只在你自己的 Apple 帳號私有資料庫裡流動

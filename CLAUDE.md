# MoneyLeft — 給 AI 開發者的專案規則

## 每次改動都必須做的事

1. **更新版本號**（使用者靠這個確認有沒有裝到新版）
   - `project.yml` 的 `MARKETING_VERSION`：功能有變 +0.1，大改版 +1.0
   - build number 由 CI 以 `github.run_number` 覆寫，不要寫死
   - ipa 與 Artifact 檔名要帶版本號
   - 回報時直接講「這是 vX.Y build N」

2. **更新 `ROADMAP.md`**：做完的項目標 ✅ 並註明完成版本；新發現的待辦補進去

3. **推到 `claude/optional-content-implementation-or6hrh` 分支**，等 CI 綠燈再回報；
   沒綠燈不算完成

## 專案原則（不可違背）

- **完全本機、零連網**：不得引入任何會連外的 SDK、API 或服務
- **不使用第三方套件**：只用 Apple 原生框架，降低 CI 與自簽出錯機率
- **不做雲端同步**：iCloud 已明確移除，不要再加回來
- **側載自簽友善**：任何需要付費開發者帳號才有的 entitlement 都不要用；
  必須確保缺權限時 App 仍能正常啟動（不可閃退）
- **辨識結果一律先給使用者確認**，不自動寫入資料庫

## 技術基本盤

- Swift + SwiftUI + SwiftData，最低 iOS 17
- 專案用 XcodeGen 由 `project.yml` 產生，不要提交 `.xcodeproj`
- App 與 Widget 共用的程式碼放 `Shared/`
- 資料庫在 App Group 容器內，Widget 透過 `BudgetSnapshotStore` 讀快照

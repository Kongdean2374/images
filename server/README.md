# chaihome-stats 後端部署指南

端對端加密統計的伺服器端。整台伺服器只存密文，沒有任何解密能力。

- 網域：`chaihome.cc`（在 Cloudflare 購買，Nameserver 已經是 Cloudflare 的，不需要另外改）
- API 位址：`https://api.chaihome.cc/v1`
- 架構：Cloudflare Workers（API）+ D1（SQLite 資料庫）
- 費用：以「一個人使用、每天數筆到數十筆」的量級，完全落在 Cloudflare 免費額度內
  （Workers 每天 10 萬次請求、D1 每天 500 萬次讀取 / 10 萬次寫入、5 GB 儲存）

---

## 一次性設定（照順序做，大約 10 分鐘）

### 0. 安裝工具

需要電腦上有 Node.js。開終端機：

```bash
cd server
npx wrangler login
```

瀏覽器會跳出 Cloudflare 授權頁，按同意即可。
（這一步是用你自己的瀏覽器登入，不需要把 API Token 交給任何人。）

### 1. 建立 D1 資料庫

```bash
npx wrangler d1 create chaihome-stats
```

指令會印出一段像這樣的內容：

```
[[d1_databases]]
binding = "DB"
database_name = "chaihome-stats"
database_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

把那串 `database_id` 複製起來，貼進 `wrangler.toml` 裡 `PUT-YOUR-D1-DATABASE-ID-HERE` 的位置。

### 2. 建立資料表

```bash
npx wrangler d1 execute chaihome-stats --remote --file=./schema.sql
```

### 3. 設定同步密鑰（建議做，但不是必要）

```bash
npx wrangler secret put SYNC_TOKEN
```

它會要你輸入一段字串，自己想一組長一點的亂碼即可（例如 40 個隨機字元）。
這組密鑰**不是**加密金鑰，只是用來擋掉不認識的請求；就算外流，對方拿到的還是解不開的密文。

設定好之後，要把同一組字串填進 App 的「設定 → 端對端加密 → 存取密鑰」。
如果不設定這個 secret，API 就不檢查授權（單人使用、URL 沒外流的情況下也堪用）。

### 4. 部署

```bash
npx wrangler deploy
```

部署成功後，Wrangler 會自動幫 `api.chaihome.cc` 建好 DNS 記錄與 SSL 憑證。

### 5. 確認有活著

```bash
curl https://api.chaihome.cc/v1/health
# 應該回傳：{"ok":true,"service":"chaihome-stats"}
```

### 6. 在 App 裡設定

打開 App →「設定 → 端對端加密」：

1. 「伺服器位址」填 `https://api.chaihome.cc/v1`
2. 如果第 3 步有設 `SYNC_TOKEN`，把同一組字串填進「存取密鑰」
3. 打開「啟用同步」
4. 按「上傳」，再按「下載」，看到解密後的數字就代表整條路都通了

---

## 之後要更新程式碼

改完 `src/index.js` 之後，重新跑一次：

```bash
npx wrangler deploy
```

就這樣，不用做別的。

---

## API 規格

所有端點都在 `https://api.chaihome.cc/v1` 底下。
若有設定 `SYNC_TOKEN`，除了 `/health` 之外都要帶 `Authorization: Bearer <token>`。

| 方法 | 路徑 | 說明 |
|---|---|---|
| GET | `/v1/health` | 健康檢查，不需授權 |
| POST | `/v1/stats` | 上傳一筆密文封包 |
| GET | `/v1/stats?device=X` | 取回該裝置最新一筆密文 |
| GET | `/v1/stats/history?device=X&limit=30` | 取回歷史清單 |
| DELETE | `/v1/stats?device=X` | 刪除該裝置的全部密文 |

上傳的 JSON 格式（與 App 的 `EncryptedEnvelope` 一致）：

```json
{
  "deviceID": "隨機 UUID，不含個資",
  "timestamp": "2026-09-16T09:00:00Z",
  "iv": "Base64",
  "ciphertext": "Base64",
  "version": 1
}
```

---

## 伺服器看得到什麼

| 欄位 | 內容 | 伺服器讀得懂嗎 |
|---|---|---|
| `device_id` | App 隨機產生的 UUID | 讀得懂，但不含任何個資 |
| `client_ts` | 上傳時間 | 讀得懂 |
| `received_at` | 收到時間 | 讀得懂 |
| `iv` | 初始化向量 | 讀得懂，但單獨沒有用 |
| `ciphertext` | 統計資料密文 | **讀不懂**，金鑰只在你手機裡 |

要親眼確認的話：

```bash
npx wrangler d1 execute chaihome-stats --remote \
  --command="SELECT device_id, client_ts, substr(ciphertext,1,60) FROM stats_blobs LIMIT 5;"
```

會看到一堆 Base64 亂碼，這就是重點。

---

## 防濫用設定

- 每支裝置只保留最近 60 筆（`MAX_ROWS_PER_DEVICE`），超過自動刪最舊的
- 單一封包上限 64 KB（`MAX_BODY_BYTES`）
- `iv` 與 `ciphertext` 都會驗證是否為合法 Base64，`device` 必須是 UUID 格式
- 兩個參數都能在 `wrangler.toml` 的 `[vars]` 直接改

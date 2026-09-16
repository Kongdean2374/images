-- 端對端加密統計：D1 資料表結構
-- 重點：這張表裡沒有任何可讀的內容，ciphertext 欄位是 AES-256-GCM 密文，
-- 伺服器沒有金鑰，永遠解不開。

CREATE TABLE IF NOT EXISTS stats_blobs (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  -- App 隨機產生的裝置識別碼，不含個資
  device_id    TEXT    NOT NULL,
  -- App 端的時間戳記（ISO8601 字串，由客戶端提供）
  client_ts    TEXT    NOT NULL,
  -- 伺服器收到的時間（Unix 秒），用來排序與清理
  received_at  INTEGER NOT NULL,
  -- 密文封包格式版本，日後換演算法時相容舊資料用
  version      INTEGER NOT NULL DEFAULT 1,
  -- 這次加密用的初始化向量（Base64）
  iv           TEXT    NOT NULL,
  -- 密文本體 + GCM 驗證標籤（Base64）
  ciphertext   TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_stats_device_time
  ON stats_blobs (device_id, received_at DESC);

-- 每支裝置只保留最近 N 筆的清理，用排程或手動執行：
-- DELETE FROM stats_blobs WHERE id NOT IN (
--   SELECT id FROM stats_blobs WHERE device_id = ?1 ORDER BY received_at DESC LIMIT 60
-- ) AND device_id = ?1;

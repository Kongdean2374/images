/**
 * chaihome-stats — 端對端加密統計 API（Cloudflare Workers + D1）
 *
 * 這支 Worker 的職責只有一件事：搬運與保存密文。
 * 它沒有、也永遠不會有解密用的 Key A，所以就算整台伺服器被拿走，
 * 拿到的也只是一堆無法還原的 Base64 字串。
 *
 * 端點（掛在 https://api.chaihome.cc/v1 底下）：
 *   GET    /v1/health           健康檢查
 *   POST   /v1/stats            上傳一筆密文封包
 *   GET    /v1/stats?device=X   取回該裝置最新的一筆密文
 *   GET    /v1/stats/history?device=X&limit=30  取回歷史清單
 *   DELETE /v1/stats?device=X   刪除該裝置的全部密文
 */

const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
  'x-content-type-options': 'nosniff'
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function error(message, status) {
  return json({ error: message }, status);
}

/** 只接受 Base64，長度也擋一下，避免有人塞奇怪的東西進來 */
function isBase64(value, maxLength) {
  return typeof value === 'string'
    && value.length > 0
    && value.length <= maxLength
    && /^[A-Za-z0-9+/]+={0,2}$/.test(value);
}

/** 裝置識別碼由 App 隨機產生，格式固定為 UUID */
function isDeviceID(value) {
  return typeof value === 'string'
    && /^[0-9A-Fa-f-]{16,64}$/.test(value);
}

/**
 * 若有設定 SYNC_TOKEN，所有請求都要帶 Authorization: Bearer <token>。
 * 用長度固定的比較，避免時間側通道。
 */
function authorized(request, env) {
  const expected = env.SYNC_TOKEN;
  if (!expected) return true;

  const header = request.headers.get('authorization') || '';
  const provided = header.startsWith('Bearer ') ? header.slice(7) : '';
  if (provided.length !== expected.length) return false;

  let diff = 0;
  for (let i = 0; i < expected.length; i += 1) {
    diff |= provided.charCodeAt(i) ^ expected.charCodeAt(i);
  }
  return diff === 0;
}

async function handleUpload(request, env) {
  const maxBody = Number(env.MAX_BODY_BYTES || 65536);
  const raw = await request.text();
  if (raw.length > maxBody) return error('封包過大', 413);

  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return error('JSON 格式不正確', 400);
  }

  const { deviceID, timestamp, iv, ciphertext } = body;
  const version = Number.isInteger(body.version) ? body.version : 1;

  if (!isDeviceID(deviceID)) return error('deviceID 格式不正確', 400);
  if (typeof timestamp !== 'string' || timestamp.length > 64) return error('timestamp 格式不正確', 400);
  if (!isBase64(iv, 64)) return error('iv 格式不正確', 400);
  if (!isBase64(ciphertext, maxBody)) return error('ciphertext 格式不正確', 400);

  const now = Math.floor(Date.now() / 1000);
  await env.DB.prepare(
    `INSERT INTO stats_blobs (device_id, client_ts, received_at, version, iv, ciphertext)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)`
  ).bind(deviceID, timestamp, now, version, iv, ciphertext).run();

  // 每支裝置只留最近 N 筆，超過的自動清掉
  const keep = Number(env.MAX_ROWS_PER_DEVICE || 60);
  await env.DB.prepare(
    `DELETE FROM stats_blobs
      WHERE device_id = ?1
        AND id NOT IN (
          SELECT id FROM stats_blobs
           WHERE device_id = ?1
           ORDER BY received_at DESC
           LIMIT ?2
        )`
  ).bind(deviceID, keep).run();

  return json({ ok: true, storedAt: now });
}

async function handleLatest(url, env) {
  const deviceID = url.searchParams.get('device');
  if (!isDeviceID(deviceID)) return error('device 參數不正確', 400);

  const row = await env.DB.prepare(
    `SELECT device_id, client_ts, version, iv, ciphertext
       FROM stats_blobs
      WHERE device_id = ?1
      ORDER BY received_at DESC
      LIMIT 1`
  ).bind(deviceID).first();

  if (!row) return error('這個裝置還沒有任何資料', 404);

  // 回傳格式與 App 的 EncryptedEnvelope 完全一致
  return json({
    deviceID: row.device_id,
    timestamp: row.client_ts,
    iv: row.iv,
    ciphertext: row.ciphertext,
    version: row.version
  });
}

async function handleHistory(url, env) {
  const deviceID = url.searchParams.get('device');
  if (!isDeviceID(deviceID)) return error('device 參數不正確', 400);

  const limit = Math.min(Math.max(Number(url.searchParams.get('limit') || 30), 1), 100);
  const result = await env.DB.prepare(
    `SELECT client_ts, received_at, version, iv, ciphertext
       FROM stats_blobs
      WHERE device_id = ?1
      ORDER BY received_at DESC
      LIMIT ?2`
  ).bind(deviceID, limit).all();

  return json({
    deviceID,
    count: result.results.length,
    items: result.results.map((row) => ({
      timestamp: row.client_ts,
      receivedAt: row.received_at,
      iv: row.iv,
      ciphertext: row.ciphertext,
      version: row.version
    }))
  });
}

async function handleDelete(url, env) {
  const deviceID = url.searchParams.get('device');
  if (!isDeviceID(deviceID)) return error('device 參數不正確', 400);

  const result = await env.DB.prepare(
    'DELETE FROM stats_blobs WHERE device_id = ?1'
  ).bind(deviceID).run();

  return json({ ok: true, deleted: result.meta?.changes ?? 0 });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Cloudflare 前面已經強制 HTTPS，這裡再擋一次
    if (url.protocol !== 'https:') {
      return error('只接受 HTTPS', 400);
    }

    if (url.pathname === '/v1/health') {
      return json({ ok: true, service: 'chaihome-stats' });
    }

    if (!authorized(request, env)) {
      return error('未授權', 401);
    }

    if (url.pathname === '/v1/stats') {
      if (request.method === 'POST') return handleUpload(request, env);
      if (request.method === 'GET') return handleLatest(url, env);
      if (request.method === 'DELETE') return handleDelete(url, env);
      return error('不支援的方法', 405);
    }

    if (url.pathname === '/v1/stats/history' && request.method === 'GET') {
      return handleHistory(url, env);
    }

    return error('找不到這個端點', 404);
  }
};

// 精簡版 Worker（功能與 index.js 相同，只是把註解與歷史查詢拿掉，方便在手機上貼）
const H = { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' };
const J = (b, s = 200) => new Response(JSON.stringify(b), { status: s, headers: H });
const ok = (v, n) => typeof v === 'string' && v.length > 0 && v.length <= n && /^[A-Za-z0-9+/]+={0,2}$/.test(v);
const dev = (v) => typeof v === 'string' && /^[0-9A-Fa-f-]{16,64}$/.test(v);

export default {
  async fetch(req, env) {
    const u = new URL(req.url);
    if (u.pathname === '/v1/health') return J({ ok: true, service: 'chaihome-stats' });

    if (env.SYNC_TOKEN) {
      const t = (req.headers.get('authorization') || '').replace('Bearer ', '');
      if (t !== env.SYNC_TOKEN) return J({ error: '未授權' }, 401);
    }
    if (u.pathname !== '/v1/stats') return J({ error: '找不到這個端點' }, 404);

    if (req.method === 'POST') {
      const raw = await req.text();
      if (raw.length > 65536) return J({ error: '封包過大' }, 413);
      let b;
      try { b = JSON.parse(raw); } catch { return J({ error: 'JSON 格式不正確' }, 400); }
      if (!dev(b.deviceID) || !ok(b.iv, 64) || !ok(b.ciphertext, 65536)) {
        return J({ error: '欄位格式不正確' }, 400);
      }
      const now = Math.floor(Date.now() / 1000);
      await env.DB.prepare(
        'INSERT INTO stats_blobs (device_id, client_ts, received_at, version, iv, ciphertext) VALUES (?1,?2,?3,?4,?5,?6)'
      ).bind(b.deviceID, String(b.timestamp || ''), now, b.version || 1, b.iv, b.ciphertext).run();
      await env.DB.prepare(
        'DELETE FROM stats_blobs WHERE device_id = ?1 AND id NOT IN (SELECT id FROM stats_blobs WHERE device_id = ?1 ORDER BY received_at DESC LIMIT 60)'
      ).bind(b.deviceID).run();
      return J({ ok: true, storedAt: now });
    }

    const d = u.searchParams.get('device');
    if (!dev(d)) return J({ error: 'device 參數不正確' }, 400);

    if (req.method === 'GET') {
      const r = await env.DB.prepare(
        'SELECT device_id, client_ts, version, iv, ciphertext FROM stats_blobs WHERE device_id = ?1 ORDER BY received_at DESC LIMIT 1'
      ).bind(d).first();
      if (!r) return J({ error: '這個裝置還沒有任何資料' }, 404);
      return J({ deviceID: r.device_id, timestamp: r.client_ts, iv: r.iv, ciphertext: r.ciphertext, version: r.version });
    }

    if (req.method === 'DELETE') {
      const r = await env.DB.prepare('DELETE FROM stats_blobs WHERE device_id = ?1').bind(d).run();
      return J({ ok: true, deleted: r.meta?.changes ?? 0 });
    }

    return J({ error: '不支援的方法' }, 405);
  }
};

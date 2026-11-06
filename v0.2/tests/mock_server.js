// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 ChefDeCode
// 模拟服务端（只用于客户端测试）：只监听 127.0.0.1，回放 server-0.2.0.json 里真实服务端代码生成的响应；不是正式服务端，不装任何依赖
// 用法：node mock_server.js [端口=8811]；测试控制：POST /__approve（模拟用户在浏览器里点了「允许」）、POST /__mode?ent=normal|trial|exhausted
const http = require('http'), fs = require('fs'), path = require('path');
const port = +(process.argv[2] || 8811), origin = `http://127.0.0.1:${port}`;
const fx = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'server-0.2.0.json'), 'utf8'));
const fx2 = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'client-release-0.3.0.json'), 'utf8')); let upd = 'none';
const H = fx.http, rew = o => JSON.parse(JSON.stringify(o).split('http://127.0.0.1:8810').join(origin));
let approved = false, signedIn = false, ent = 'normal', ai = 'ok', polls = 0, lastAi = null; const hits = {};
const TOKEN = 'mock-token-not-secret';
function send(res, r) { const j = rew(r.json); res.writeHead(r.status, { 'content-type': 'application/json; charset=utf-8' }); res.end(JSON.stringify(j)); }
function err(res, status, code, message) { send(res, { status, json: { error: { code, message, retryable: false } } }); }
http.createServer((req, res) => {
  let body = ''; req.on('data', c => body += c); req.on('end', () => {
    const u = new URL(req.url, origin), p = u.pathname, m = req.method; hits[`${m} ${p}`] = (hits[`${m} ${p}`] || 0) + 1;
    const auth = (req.headers.authorization || '') === `Bearer ${TOKEN}` && signedIn;
    const need = () => { if (!auth) { send(res, H.no_token); return false } return true };
    if (p === '/__approve') { approved = true; return send(res, { status: 200, json: { ok: true } }) }
    if (p === '/__mode') { ent = u.searchParams.get('ent') || ent; ai = u.searchParams.get('ai') || ai; upd = u.searchParams.get('upd') || upd; return send(res, { status: 200, json: { ent, ai } }) }
    if (p === '/v1/client/latest') { const k = upd === 'update' ? 'latest_update' : upd === 'required' ? 'latest_required' : upd === 'uptodate' ? 'latest_up_to_date' : 'latest_none'; return send(res, fx2.http[k]) }
    { const mr = p.match(/^\/v1\/client\/releases\/([^/]+)\/([^/]+)\/package$/); if (mr) { const pk = fx2.packages[decodeURIComponent(mr[2])]; if (!pk) return send(res, fx2.http.package_withdrawn_404); res.writeHead(200, { 'content-type': 'application/zip' }); return res.end(Buffer.from(pk.zip_b64, 'base64')) } }
    if (p === '/__lastai') return send(res, { status: 200, json: lastAi || {} });
    if (p === '/v1/ai/messages' && m === 'POST') { if (!need()) return; try { lastAi = JSON.parse(body) } catch { lastAi = { bad: true } }
      if (ai === 'quota_daily') return send(res, H.ai_quota_daily); if (ai === 'quota_lifetime') return send(res, H.ai_quota_lifetime); if (ai === 'bad_model') return send(res, H.ai_bad_model);
      let sse = fx.sse_ok;
      if (ai === 'tool' && !JSON.stringify(lastAi.messages || []).includes('tool_result')) {   // 合成的一段（服务端测试数据里没有），只用来测工具循环：先要求调用 get_today
        const done = { stop_reason: 'tool_use', model: 'claude-sonnet-5-5', content: [{ type: 'tool_use', id: 'toolu_mock1', name: 'get_today', input: {} }], usage: { input_tokens: 50, output_tokens: 10 } };
        sse = 'event: start\ndata: {"model": "claude-sonnet-5-5"}\n\nevent: done\ndata: ' + JSON.stringify(done) + '\n\n' }
      res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8' }); return res.end(sse) }
    if (p === '/__hits') { return send(res, { status: 200, json: { hits, signedIn } }) }
    if (p === '/healthz') return send(res, H.healthz);
    if (p === '/v1/meta') return send(res, H.meta);
    if (p === '/v1/plans') return send(res, H.plans);
    if (p === '/device' || p === '/upgrade' || p === '/account' || p === '/signup') { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); return res.end('<p>模拟页面</p>') }
    if (p === '/v1/device/code' && m === 'POST') { approved = false; polls = 0; return send(res, H.device_code) }
    if (p === '/v1/device/token' && m === 'POST') { polls++; if (!approved) return send(res, H.device_token_pending); signedIn = true; const r = rew(H.device_token_ok); r.json.access_token = TOKEN; return send(res, r) }
    if (p === '/v1/me') return need() && send(res, H.me);
    if (p === '/v1/entitlements') return need() && send(res, ent === 'trial' ? H.entitlements_trial : ent === 'exhausted' ? H.entitlements_daily_exhausted : H.entitlements);
    if (p.startsWith('/v1/usage')) return need() && send(res, H.usage);
    if (p === '/v1/devices/self' && m === 'DELETE') { if (!need()) return; signedIn = false; return send(res, H.logout_self) }
    if (p === '/v1/billing/checkout') return need() && send(res, H.checkout);
    if (p === '/v1/store/permissions') return send(res, H.store_permissions);
    if (p === '/v1/store/plugins') return need() && send(res, H.catalog);
    let mm = p.match(/^\/v1\/store\/plugins\/([^/]+)$/); if (mm) return need() && (mm[1] === 'wechat-desktop' ? send(res, H.detail) : err(res, 404, 'not_found', '没有这个插件'));
    mm = p.match(/^\/v1\/store\/plugins\/([^/]+)\/versions\/([^/]+)\/(package|signature)$/);
    if (mm) { if (!need()) return; const k = `${decodeURIComponent(mm[1])}-${decodeURIComponent(mm[2])}`, pk = fx.packages[k]; if (!pk) return send(res, H.package_withdrawn_404);
      if (mm[3] === 'signature') return send(res, { status: 200, json: pk.signature });
      const zip = Buffer.from(pk.zip_b64, 'base64'); res.writeHead(200, { 'content-type': 'application/zip', 'x-package-sha256': pk.signature.statement.sha256 }); return res.end(zip) }
    if (p === '/v1/store/updates' && m === 'POST') return need() && send(res, H.updates_up_to_date);
    if (p === '/v1/store/events' || p.endsWith('/reports')) return need() && send(res, { status: 200, json: { ok: true } });
    err(res, 404, 'not_found', '模拟服务端没有这个接口');
  });
}).listen(port, '127.0.0.1', () => console.log(`mock server on ${origin}`));

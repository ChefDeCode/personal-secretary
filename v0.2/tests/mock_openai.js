// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 ChefDeCode
// 模拟的 OpenAI 兼容接口（只用于测试翻译层，全部是假的回答）：第一次要求调用 propose_send，拿到工具结果后回一句话
const http = require('http'); const port = +(process.argv[2] || 8821); let last = null;
http.createServer((req, res) => { let b = ''; req.on('data', c => b += c); req.on('end', () => {
  if (req.url === '/__last') { res.writeHead(200, { 'content-type': 'application/json' }); return res.end(JSON.stringify(last || {})) }
  if (req.headers.authorization !== 'Bearer sk-test-mock-key-0123456789') { res.writeHead(401, { 'content-type': 'application/json' }); return res.end(JSON.stringify({ error: { message: 'Incorrect API key provided' } })) }
  if (req.url.endsWith('/models')) { res.writeHead(200, { 'content-type': 'application/json' }); return res.end(JSON.stringify({ data: [{ id: 'mock-model-a' }, { id: 'mock-model-b' }] })) }
  let j = {}; try { j = JSON.parse(b) } catch {} last = j;
  const hasTool = (j.messages || []).some(m => m.role === 'tool');
  const msg = (!hasTool && j.tools) ? { role: 'assistant', content: null, tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'propose_send', arguments: JSON.stringify({ as_said: '文件传输助手', text: '【测试】你好' }) } }] }
                                    : { role: 'assistant', content: '好的，请在卡片上确认。' };
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ id: 'x', model: j.model, choices: [{ index: 0, message: msg, finish_reason: msg.tool_calls ? 'tool_calls' : 'stop' }], usage: { prompt_tokens: 10, completion_tokens: 5 } }));
}) }).listen(port, '127.0.0.1');

// Regression tests for mcp/web-tools.mjs (adversarial review 2026-11-16, findings C2 and C8).
// Run: node --test tests/web-tools.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { networkInterfaces } from 'node:os';
import { fileURLToPath } from 'node:url';
import { blockedReason, htmlToText } from '../mcp/web-tools.mjs';

const SERVER = fileURLToPath(new URL('../mcp/web-tools.mjs', import.meta.url));

test('loopback in every notation is blocked (also in lab mode)', () => {
  for (const ip of ['127.0.0.1', '127.1.2.3', '0.0.0.0', '::1', '::', '::ffff:127.0.0.1', '::ffff:7f00:1',
    '0:0:0:0:0:ffff:7f00:0001', '::ffff:0.0.0.0', '::7f00:1', '64:ff9b::7f00:1', '2002:7f00:1::1', '[::1]']) {
    assert.ok(blockedReason(ip, true), `${ip} must be blocked`);
  }
});

test('link-local / metadata / multicast are blocked', () => {
  for (const ip of ['169.254.169.254', 'fe80::1', 'ff02::1', '224.0.0.1', '::ffff:a9fe:a9fe']) assert.ok(blockedReason(ip, true), ip);
});

test('private ranges: blocked by default, allowed in lab', () => {
  for (const ip of ['10.0.0.1', '172.16.0.1', '192.168.1.5', '100.64.0.1', 'fd00::1', '::ffff:c0a8:105']) {
    assert.ok(blockedReason(ip, false), `${ip} blocked without LAN`);
    assert.equal(blockedReason(ip, true), null, `${ip} allowed in lab`);
  }
});

test("this Mac's own addresses are blocked even in lab", () => {
  for (const list of Object.values(networkInterfaces())) {
    for (const i of list || []) assert.ok(blockedReason(i.address, true), `own ${i.address}`);
  }
});

test('public addresses pass', () => {
  for (const ip of ['8.8.8.8', '1.1.1.1', '2a00:1450:4001::1', '::ffff:8.8.8.8']) assert.equal(blockedReason(ip, false), null, ip);
});

test('htmlToText is linear on hostile input (20k unclosed <script>, 4 MB)', () => {
  const hostile = '<script>'.repeat(20000) + 'x'.repeat(4_000_000);
  const t0 = performance.now();
  htmlToText(hostile);
  assert.ok(performance.now() - t0 < 1500, `took ${performance.now() - t0} ms`);
  const normal = htmlToText('<html><head><title>T</title></head><body><!-- c --><script>bad()</script><p>Привет&nbsp;мир</p></body></html>');
  assert.equal(normal.title, 'T');
  assert.equal(normal.text, 'Привет мир');
});

test('htmlToText is linear on unclosed "<" and "<li" floods (review C8 retest)', () => {
  for (const hostile of ['<'.repeat(200000), '<li'.repeat(100000), '<br'.repeat(100000) + 'x', '<title'.repeat(50000)]) {
    const t0 = performance.now();
    htmlToText(hostile);
    assert.ok(performance.now() - t0 < 1500, `${hostile.slice(0, 5)}… took ${performance.now() - t0} ms`);
  }
});

test('web_fetch never reaches a local receiver (IPv6-mapped, localhost, redirect via own IP)', async () => {
  let hits = 0;
  const srv = http.createServer((req, res) => { hits++; res.end('LEAK'); }).listen(0, '127.0.0.1');
  await new Promise((r) => srv.once('listening', r));
  const port = srv.address().port;
  const urls = [`http://[::ffff:7f00:1]:${port}/?d=CANARY`, `http://127.0.0.1:${port}/`, `http://localhost:${port}/`,
    `http://[0:0:0:0:0:ffff:7f00:0001]:${port}/`, `http://127.1:${port}/`, `http://2130706433:${port}/`];
  const child = spawn(process.execPath, [SERVER], { stdio: ['pipe', 'pipe', 'inherit'], env: { ...process.env, WEB_TOOLS_ALLOW_LAN: '1' } });
  const replies = [];
  child.stdout.on('data', (d) => replies.push(...d.toString().trim().split('\n')));
  urls.forEach((url, i) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: i + 1, method: 'tools/call', params: { name: 'web_fetch', arguments: { url } } }) + '\n'));
  await new Promise((r) => { const t = setInterval(() => { if (replies.length >= urls.length) { clearInterval(t); r(); } }, 50); });
  child.kill();
  srv.close();
  assert.equal(hits, 0, 'receiver must never be hit');
  for (const line of replies) assert.ok(JSON.parse(line).result.isError, line);
});

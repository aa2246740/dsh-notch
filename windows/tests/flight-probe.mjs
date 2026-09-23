/* Compare the success and failure outcome flights on the real page.

   Phase 4's assertion "the failure outcome is drawn, not faded in" expects a
   SHORT arc at 0.25 s of the flight, and the success case beside it still passes.
   This probe measures both paths frame by frame so the difference can be read as
   numbers instead of guessed at.

   Usage: node windows/tests/flight-probe.mjs */
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { readFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', 'DshNotchWin', 'Assets', 'notch');
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8' };
const server = createServer(async (req, res) => {
  const rel = decodeURIComponent(new URL(req.url, 'http://x').pathname).replace(/^\/+/, '') || 'index.html';
  const file = path.join(root, rel);
  if (!file.startsWith(root) || !existsSync(file)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' });
  res.end(await readFile(file));
});
await new Promise((r) => server.listen(8793, '127.0.0.1', r));

const edge = ['C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe'].find((p) => existsSync(p));
const profile = path.join(process.env.TEMP || '.', 'notch-flight-probe-' + process.pid);
const child = spawn(edge, ['--headless=new', '--disable-gpu', '--no-first-run', '--remote-debugging-port=9334',
  `--user-data-dir=${profile}`, '--window-size=560,760', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let page;
for (let i = 0; i < 60 && !page; i++) {
  try {
    const list = await (await fetch('http://127.0.0.1:9334/json/list')).json();
    page = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
  } catch { /* wait */ }
  if (!page) await sleep(250);
}
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
let nextId = 1;
const pending = new Map();
ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
  }
};
const send = (method, params) => {
  const id = nextId++;
  ws.send(JSON.stringify({ id, method, params: params || {} }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
};
const evaluate = async (expression) => {
  const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  return r.exceptionDetails ? { error: r.exceptionDetails.exception?.description } : r.result.value;
};

await send('Runtime.enable');
await send('Page.enable');
await send('Page.addScriptToEvaluateOnNewDocument', {
  source: `(() => {
    const listeners = [];
    window.chrome = { webview: { postMessage: () => {}, addEventListener: (t, f) => { if (t === 'message') listeners.push(f); } } };
    window.__harness = { send: (m) => { for (const f of listeners) f({ data: m }); } };
  })();`,
});
await send('Page.navigate', { url: 'http://127.0.0.1:8793/index.html' });
await sleep(400);
await evaluate(`__harness.send(${JSON.stringify({ type: 'geometry', expanded: false, settled: true, edge: 'right', width: 720, height: 66, scale: 1.5, radius: 16, hovered: false, motion: true })})`);
await sleep(500);

const busy = `{"type":"snapshot","generatedAt":1,"counts":{"busy":1,"completed":0,"failed":0,"decision":0,"rows":1},"rows":[{"id":"b","title":"x","child":false,"busy":true,"unread":false,"needsAction":false,"failed":false}]}`;
const done = `{"type":"snapshot","generatedAt":2,"counts":{"busy":1,"completed":1,"failed":0,"decision":0,"rows":2},"rows":[{"id":"b","title":"x","child":false,"busy":false,"unread":true,"needsAction":false,"failed":false,"lastTurn":{"at":1,"kind":"completed","failed":false}},{"id":"b2","title":"y","child":false,"busy":true,"unread":false,"needsAction":false,"failed":false}]}`;
const fail = `{"type":"snapshot","generatedAt":3,"counts":{"busy":1,"completed":0,"failed":1,"decision":0,"rows":2},"rows":[{"id":"b","title":"x","child":false,"busy":false,"unread":false,"needsAction":false,"failed":true,"lastTurn":{"at":2,"kind":"error","failed":true}},{"id":"b2","title":"y","child":false,"busy":true,"unread":false,"needsAction":false,"failed":false}]}`;

async function run(label, snap, colour) {
  await evaluate('__notchOrbit.probe.reset()');
  await evaluate('__notchOrbit.probe.hold(false)');
  await evaluate(`__harness.send(${JSON.stringify(JSON.parse(busy))})`);
  await sleep(150);
  await evaluate('__notchOrbit.probe.hold(true)');
  await evaluate(`__harness.send(${JSON.stringify(JSON.parse(snap))})`);
  await sleep(80);
  const frames = [];
  for (const at of [0.05, 0.15, 0.25, 0.4, 0.5, 0.7, 0.95]) {
    await evaluate(`__notchOrbit.probe.frameAt(${at})`);
    await sleep(80);
    const ink = await evaluate('__notchOrbit.probe.ink()');
    const st = await evaluate('__notchOrbit.probe.state()');
    frames.push({
      at,
      ink: ink[colour] ? ink[colour].n : 0,
      box: ink[colour] ? `${ink[colour].minX},${ink[colour].minY}..${ink[colour].maxX},${ink[colour].maxY}` : '-',
      distance: st.motion ? st.motion.distance : null,
      tail: st.motion ? st.motion.tail : null,
      tint: st.motion ? st.motion.tint : null,
      arrived: st.motion ? st.motion.arrived : null,
      angle: st.flight ? +st.flight.elapsed.toFixed(3) : null,
    });
  }
  console.log('== ' + label);
  for (const f of frames) console.log(JSON.stringify(f));
  return frames;
}

await run('success', done, 'green');
await run('failure', fail, 'red');

ws.close();
child.kill();
server.close();
await rm(profile, { recursive: true, force: true }).catch(() => {});
process.exit(0);

/* One-shot robot diagnostic: run the real page in headless Edge, drive the
   scheduler to a clip phase and print exactly what the robot state machine and
   the canvas are doing. Used while building Phase 5. */
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { readFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', 'DshNotchWin', 'Assets', 'notch');
const server = createServer(async (req, res) => {
  const rel = decodeURIComponent(new URL(req.url, 'http://x').pathname).replace(/^\/+/, '') || 'index.html';
  const file = path.join(root, rel);
  if (!file.startsWith(root) || !existsSync(file)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'content-type': rel.endsWith('.js') ? 'text/javascript' : 'text/html', 'cache-control': 'no-store' });
  res.end(await readFile(file));
});
await new Promise((r) => server.listen(8794, '127.0.0.1', r));

const edge = ['C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe'].find((p) => existsSync(p));
const profile = path.join(process.env.TEMP || '.', 'notch-robot-probe-' + process.pid);
const child = spawn(edge, ['--headless=new', '--disable-gpu', '--no-first-run', '--remote-debugging-port=9335',
  `--user-data-dir=${profile}`, '--window-size=560,760', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let page;
for (let i = 0; i < 60 && !page; i++) {
  try {
    const list = await (await fetch('http://127.0.0.1:9335/json/list')).json();
    page = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
  } catch { /* wait */ }
  if (!page) await sleep(250);
}
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
let nextId = 1;
const pending = new Map();
const errors = [];
ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    return;
  }
  if (msg.method === 'Runtime.exceptionThrown') {
    errors.push(msg.params.exceptionDetails.exception?.description || msg.params.exceptionDetails.text);
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
  source: `(() => { const l = [];
    window.chrome = { webview: { postMessage: () => {}, addEventListener: (t, f) => { if (t === 'message') l.push(f); } } };
    window.__harness = { send: (m) => { for (const f of l) f({ data: m }); } }; })();`,
});
await send('Page.navigate', { url: 'http://127.0.0.1:8794/index.html' });
await sleep(500);
await evaluate(`__harness.send(${JSON.stringify({ type: 'geometry', expanded: false, settled: true, edge: 'right', width: 720, height: 66, scale: 1.5, radius: 16, hovered: false, motion: true })})`);
await sleep(300);

const idle = `{"type":"snapshot","generatedAt":960002,"counts":{"busy":0,"completed":0,"failed":0,"decision":0,"rows":1},"rows":[{"id":"r","title":"x","child":false,"busy":false,"unread":false,"needsAction":false,"failed":false}]}`;
await evaluate(`__harness.send(${JSON.stringify(JSON.parse(idle))})`);
await sleep(300);

const out = {};
out.idle = await evaluate(`(() => { __notchOrbit.probe.reset(); return __notchOrbit.probe.snapshotOf(); })()`);
await sleep(200);
out.idleAfter = await evaluate(`__notchOrbit.probe.snapshotOf()`);
out.idleRobot = await evaluate(`__notchOrbit.probe.robot()`);

for (const [clip, phase] of [['blink', 0.6], ['blink', 1.26], ['hop', 1.9], ['dance', 1.0], ['sleep', 3.0]]) {
  await evaluate(`__notchOrbit.probe.pin(500)`);
  await evaluate(`__notchOrbit.probe.robotAction(${JSON.stringify(clip)}, ${phase})`);
  await evaluate(`__notchOrbit.probe.pin(500)`);
  await sleep(150);
  out[clip + '@' + phase] = await evaluate(`(() => {
    const r = __notchOrbit.probe.robot();
    const e = __notchOrbit.probe.robotEngine(${JSON.stringify(clip)}, ${phase});
    const ink = __notchOrbit.probe.robotInk();
    return {
      snap: __notchOrbit.probe.snapshotOf(),
      action: r.action, vis: r.visibility, live: r.live,
      bbox: r.bbox, fill: e.fill, dLen: e.dLength, eyes: e.eyes,
      body: ink.body ? ink.body.n : 0, eye: ink.eye ? ink.eye.n : 0,
      white: undefined,
    };
  })()`);
}

out.errors = errors.slice(0, 20);
console.log(JSON.stringify(out, null, 1));
ws.close();
child.kill();
server.close();
await rm(profile, { recursive: true, force: true }).catch(() => {});
process.exit(0);

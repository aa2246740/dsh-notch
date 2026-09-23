/* One-shot departure diagnostic: replay the Phase 5 self-test's "the robot
   shrinks into the tiny point" sequence in headless Edge and print, for every
   pinned sample, the whole presence state, the last robot paint record and the
   canvas pixels. This exists because the self-test measures 359 -> 218 -> 218
   and the question is whether the page failed to paint, or the host measured a
   frame that predates the pin. */
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
await new Promise((r) => server.listen(8796, '127.0.0.1', r));

const edge = ['C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe'].find((p) => existsSync(p));
const profile = path.join(process.env.TEMP || '.', 'notch-depart-probe-' + process.pid);
const child = spawn(edge, ['--headless=new', '--disable-gpu', '--no-first-run', '--remote-debugging-port=9337',
  `--user-data-dir=${profile}`, '--window-size=560,760', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let page;
for (let i = 0; i < 60 && !page; i++) {
  try {
    const list = await (await fetch('http://127.0.0.1:9337/json/list')).json();
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
await send('Page.navigate', { url: 'http://127.0.0.1:8796/index.html' });
await sleep(500);
await evaluate(`__harness.send(${JSON.stringify({ type: 'geometry', expanded: false, settled: true, edge: 'right', width: 720, height: 66, scale: 1.5, radius: 16, hovered: false, motion: true })})`);
await sleep(300);

const idle = `{"type":"snapshot","generatedAt":960002,"counts":{"busy":0,"completed":0,"failed":0,"decision":0,"rows":1},"rows":[{"id":"r","title":"x","child":false,"busy":false,"unread":false,"needsAction":false,"failed":false}]}`;
const busy = `{"type":"snapshot","generatedAt":960003,"counts":{"busy":1,"completed":0,"failed":0,"decision":0,"rows":1},"rows":[{"id":"r","title":"x","child":false,"busy":true,"unread":false,"needsAction":false,"failed":false}]}`;

const sample = () => evaluate(`(() => {
  const p = __notchOrbit.probe;
  const r = p.robot(), s = p.state(), pt = p.paint(), ink = p.robotInk();
  return { now: s.now, pinned: s.pinned, flightStart: s.flightStart, animating: s.animating,
           height: s.height, depart: r.depart, departProgress: r.departProgress,
           departAt: r.departAt, entryAt: r.entryAt, vis: r.visibility, live: r.live,
           display: r.display, reason: r.reason, action: r.action,
           canvas: p.robotInk().w + 'x' + p.robotInk().h,
           body: ink.body ? ink.body.n : 0, eye: ink.eye ? ink.eye.n : 0,
           pen: p.pen(), paint: pt };
})()`);

const out = {};
await evaluate(`__notchOrbit.probe.hold(true)`);
await evaluate(`__notchOrbit.probe.reduce(false)`);
await evaluate(`__notchOrbit.probe.reset()`);
await evaluate(`__notchOrbit.probe.soloRobot(true)`);
await evaluate(`__notchOrbit.probe.robotAction('blink', 0.6)`);
await evaluate(`__harness.send(${JSON.stringify(JSON.parse(idle))})`);
await sleep(200);
/* Headless Edge does not run a reliable rAF loop, so the presence machine is
   stepped by hand: `pin` runs the whole presentation step. The first step has
   to happen while the pill is EMPTY, or the robot never registers as idle and
   the departure edge cannot fire at all. */
await evaluate(`__notchOrbit.probe.pin(performance.now() / 1000)`);
await sleep(120);
out.beforeDeparture = await sample();

await evaluate(`__harness.send(${JSON.stringify(JSON.parse(busy))})`);
await sleep(60);
/* Step again at the live instant: the lamp has arrived and the presence edge
   has to fire. */
await evaluate(`__notchOrbit.probe.pin(performance.now() / 1000)`);
await sleep(60);
const live = await sample();
out.liveAfterLamp = live;

const base = live.depart > 0 || live.departAt ? live.departAt : live.now;
out.base = { departAt: live.departAt, flightStart: live.flightStart, now: live.now };
for (const off of [0.0, 0.06, 0.30, 0.45, 0.51, 0.61, 0.70, 1.30]) {
  await evaluate(`__notchOrbit.probe.pin(${base + off})`);
  await sleep(90);
  out['pin+' + off] = await sample();
}

/* The same sample, but with a forced repaint after the pin: does the frame
   come back? */
await evaluate(`__notchOrbit.probe.pin(${base + 0.70})`);
await evaluate(`(() => { const c = document.getElementById('orbit'); c.style.width = c.clientWidth + 'px'; return true; })()`);
await sleep(120);
out['pin+0.70 after repaint nudge'] = await sample();

out.errors = errors.slice(0, 10);
console.log(JSON.stringify(out, null, 1));
ws.close();
child.kill();
server.close();
await rm(profile, { recursive: true, force: true }).catch(() => {});
process.exit(0);

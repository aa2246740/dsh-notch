/* Headless probe for the notch page (development aid for the Phase 5 robot).

   Runs the REAL page in headless Edge, drives the real `__notchOrbit.probe`
   surface — including the host's own `geometry` message, which is what keeps the
   collapsed rest block visible — prints the robot state as JSON and writes a
   screenshot. The WPF self-test cannot show artwork while it is being built, and
   a broken picture there is indistinguishable from a broken assertion.

   Usage: node windows/tests/page-probe.mjs [outDir] */
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', 'DshNotchWin', 'Assets', 'notch');
const outDir = process.argv[2] ? path.resolve(process.argv[2]) : path.resolve(here, '..', 'shots');
await mkdir(outDir, { recursive: true });

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.png': 'image/png',
};
const server = createServer(async (req, res) => {
  const rel = decodeURIComponent(new URL(req.url, 'http://x').pathname).replace(/^\/+/, '') || 'index.html';
  const file = path.join(root, rel);
  if (!file.startsWith(root) || !existsSync(file)) { res.writeHead(404); res.end('missing'); return; }
  res.writeHead(200, {
    'content-type': MIME[path.extname(file)] || 'application/octet-stream',
    // Never let the probe serve a stale page: the whole point is to see the edit
    // that was just made. (Phase 2 learned this the hard way, twice.)
    'cache-control': 'no-store, no-cache, must-revalidate',
  });
  res.end(await readFile(file));
});
await new Promise((resolve) => server.listen(8791, '127.0.0.1', resolve));

const edge = [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
].find((p) => existsSync(p));
if (!edge) { console.error('no Edge found'); process.exit(2); }

const profile = path.join(process.env.TEMP || '.', 'notch-page-probe-' + process.pid);
const child = spawn(edge, [
  '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
  '--remote-debugging-port=9333', `--user-data-dir=${profile}`,
  '--window-size=560,760', 'about:blank',
], { stdio: 'ignore' });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const cleanup = async () => { try { child.kill(); } catch { /* gone */ } server.close(); };

async function firstPage() {
  for (let i = 0; i < 60; i++) {
    try {
      const list = await (await fetch('http://127.0.0.1:9333/json/list')).json();
      const page = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
      if (page) return page;
    } catch { /* not up yet */ }
    await sleep(250);
  }
  throw new Error('devtools never came up');
}

const page = await firstPage();
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });

let nextId = 1;
const pending = new Map();
const consoleLines = [];
ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    if (msg.error) reject(new Error(JSON.stringify(msg.error)));
    else resolve(msg.result);
    return;
  }
  if (msg.method === 'Runtime.consoleAPICalled') {
    consoleLines.push(msg.params.type + ': ' + msg.params.args.map((a) => a.value ?? a.description).join(' '));
  }
  if (msg.method === 'Runtime.exceptionThrown') {
    consoleLines.push('EXCEPTION: ' + (msg.params.exceptionDetails.exception?.description
      || msg.params.exceptionDetails.text));
  }
};

function send(method, params) {
  const id = nextId++;
  ws.send(JSON.stringify({ id, method, params: params || {} }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

async function evaluate(expression) {
  const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (result.exceptionDetails) {
    return { error: result.exceptionDetails.exception?.description || result.exceptionDetails.text };
  }
  return result.result.value;
}

await send('Runtime.enable');
await send('Page.enable');
// The page talks to the host through chrome.webview's message event. Installing
// a stub before it loads lets this probe be a host: it can send the same
// `geometry` message the real one does (which is what un-hides #rest) and it can
// collect everything the page tries to send back.
await send('Page.addScriptToEvaluateOnNewDocument', {
  source: `(() => {
    const outbox = [];
    const listeners = [];
    window.chrome = { webview: {
      postMessage: (msg) => { outbox.push(msg); },
      addEventListener: (type, fn) => { if (type === 'message') listeners.push(fn); },
    } };
    window.__harness = {
      outbox,
      send: (msg) => { for (const fn of listeners) fn({ data: msg }); },
    };
  })();`,
});
await send('Page.navigate', { url: 'http://127.0.0.1:8791/index.html' });
await sleep(300);

async function hostMessage(msg, settle = 120) {
  await evaluate(`__harness.send(${JSON.stringify(msg)})`);
  await sleep(settle);
}

// The real host reports the window in physical pixels at 150% scaling; that is
// what the page's CSS-pixel maths is written against.
await hostMessage({
  type: 'geometry', expanded: false, settled: true, edge: 'right',
  width: 720, height: 44 * 1.5, scale: 1.5, radius: 16, hovered: false, motion: true,
}, 400);

const report = {};
report.harness = await evaluate(`({
  listeners: typeof __harness,
  outbox: __harness.outbox.length,
  lastMessages: __harness.outbox.slice(-6),
})`);
report.boot = await evaluate(`(() => {
  const c = document.getElementById('orbit');
  return {
    canvas: c ? c.clientWidth + 'x' + c.clientHeight : null,
    bodyClass: document.body.className,
    restDisplay: getComputedStyle(document.getElementById('rest')).display,
    probe: typeof __notchOrbit,
    robotReady: (() => { try { return __notchOrbit.probe.robot().ready; } catch (e) { return 'err: ' + e.message; } })(),
  };
})()`);

report.engine = await evaluate(`__notchOrbit.probe.robotEngine('blink', 0)`);
report.rest = await evaluate(`(() => { __notchOrbit.probe.reset(); __notchOrbit.probe.robotAction('blink', 0.6); __notchOrbit.probe.pin(1); return { robot: __notchOrbit.probe.robot(), ink: __notchOrbit.probe.robotInk() }; })()`);
report.advance = await evaluate(`(() => { const a = __notchOrbit.probe.robot().actionElapsed; __notchOrbit.probe.advance(0.4); return { before: a, after: __notchOrbit.probe.robot().actionElapsed }; })()`);
report.blinkOpen = await evaluate(`(() => { __notchOrbit.probe.robotAction('blink', 0.6); __notchOrbit.probe.pin(1); return __notchOrbit.probe.robotInk(); })()`);
report.blinkClosed = await evaluate(`(() => { __notchOrbit.probe.robotAction('blink', 1.26); __notchOrbit.probe.pin(1); return __notchOrbit.probe.robotInk(); })()`);
report.hop = await evaluate(`(() => { __notchOrbit.probe.robotAction('hop', 1.9); __notchOrbit.probe.pin(1); return { bbox: __notchOrbit.probe.robot().bbox, ink: __notchOrbit.probe.robotInk() }; })()`);
report.danceA = await evaluate(`(() => { __notchOrbit.probe.robotAction('dance', 1.0); __notchOrbit.probe.pin(1); return { fill: __notchOrbit.probe.robotEngine('dance', 1.0).fill, ink: __notchOrbit.probe.robotInk() }; })()`);
report.danceB = await evaluate(`(() => { __notchOrbit.probe.robotAction('dance', 4.0); __notchOrbit.probe.pin(1); return { fill: __notchOrbit.probe.robotEngine('dance', 4.0).fill, ink: __notchOrbit.probe.robotInk() }; })()`);

const shot = await send('Page.captureScreenshot', { format: 'png', clip: { x: 0, y: 0, width: 60, height: 90, scale: 3 } });
await writeFile(path.join(outDir, 'p5-page-rest.png'), Buffer.from(shot.data, 'base64'));

report.console = consoleLines.slice(0, 30);
console.log(JSON.stringify(report, null, 1));
await cleanup();
await rm(profile, { recursive: true, force: true }).catch(() => {});
process.exit(0);

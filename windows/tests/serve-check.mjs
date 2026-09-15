/* Serve the notch page's assets over HTTP the way the page sees them, and
   report whether they load. Development aid for the Phase 5 page work. */
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', 'DshNotchWin', 'Assets', 'notch');

const server = createServer(async (req, res) => {
  const rel = decodeURIComponent(new URL(req.url, 'http://x').pathname).replace(/^\/+/, '') || 'index.html';
  const file = path.join(root, rel);
  const ok = file.startsWith(root) && existsSync(file);
  console.log('GET', rel, ok ? 'ok' : 'MISSING');
  if (!ok) { res.writeHead(404); res.end('missing'); return; }
  const ext = path.extname(file);
  res.writeHead(200, { 'content-type': ext === '.js' ? 'text/javascript' : ext === '.html' ? 'text/html' : 'application/octet-stream' });
  res.end(await readFile(file));
});

await new Promise((r) => server.listen(8792, '127.0.0.1', r));
for (const rel of ['index.html', 'robot-pose.js', 'idle/renderer.js', 'idle/motions.js']) {
  const text = await (await fetch('http://127.0.0.1:8792/' + rel)).text();
  console.log(rel, text.length, 'bytes');
  if (rel === 'index.html') {
    console.log('  script tags:', (text.match(/<script[^>]*>/g) || []).join(' '));
    console.log('  has #grid section:', text.includes('id="grid"'));
  }
}
server.close();

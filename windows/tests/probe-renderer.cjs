/* Explore the transition clips' geometry (Phase 5 reconnaissance).
   Run: node windows/tests/probe-renderer.cjs */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const src = fs.readFileSync(path.resolve(__dirname, '..', '..', 'tools', 'idle', 'renderer.js'), 'utf8');
const sandbox = {
  module: { exports: {} }, exports: {}, self: null, console, Math, Set, Object, Array,
  JSON, Number, String, Boolean, Error, parseInt, parseFloat, isNaN,
};
sandbox.self = sandbox;
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(src, sandbox, { filename: 'renderer.js' });
const O = sandbox.module.exports;
const projector = new O.SvgProjector({ viewportSize: 280 });

const ease = (x) => { x = Math.max(0, Math.min(1, x)); return x * x * x * (x * (x * 6 - 15) + 10); };

function poseFor(id, time) {
  if (id === 'cube-in') {
    const result = O.getBot5State(2.22 + Math.min(time, 1.05));
    result.bot.visible = true;
    result.bot.scale = Math.max(0.015, result.bot.scale);
    return result;
  }
  if (id === 'satellite-out' || id === 'satellite-in') {
    const t = id === 'satellite-out' ? 2 + Math.min(time, 0.8) : 7.04 + Math.min(time, 0.82);
    const result = O.getBot7State(t);
    if (id === 'satellite-out') {
      const turn = ease((time - 0.20) / 0.38);
      result.bot.pitch = -Math.PI * 2 * turn;
      result.bot.yaw = 0.26 * Math.sin(Math.PI * turn);
      result.bot.scale = 1 - 0.48 * ease((time - 0.40) / 0.22);
      result.bot.y += 0.065 * Math.sin(Math.PI * turn);
    }
    return result;
  }
  return O.getBot1State(time);
}

function bbox(pathStr) {
  if (!pathStr) return null;
  const nums = pathStr.match(/-?[0-9.]+/g) || [];
  let minX = 1e9, maxX = -1e9, minY = 1e9, maxY = -1e9;
  for (let i = 0; i + 1 < nums.length; i += 2) {
    const x = +nums[i], y = +nums[i + 1];
    if (x < minX) minX = x; if (x > maxX) maxX = x;
    if (y < minY) minY = y; if (y > maxY) maxY = y;
  }
  return [minX, maxX, minY, maxY].map(v => +v.toFixed(1)).join(',');
}

for (const [id, times] of [['cube-in', [0, 0.25, 0.6, 1.05]],
                           ['satellite-out', [0, 0.3, 0.55, 0.8]],
                           ['satellite-in', [0, 0.3, 0.6, 0.82]],
                           ['blink', [0, 1.2, 3.0]],
                           ['dance', [0, 1.0, 2.5]]]) {
  console.log('===', id);
  for (const t of times) {
    const st = poseFor(id, t);
    const r = projector.projectRoundedCube(st.bot);
    console.log('  t=' + t.toFixed(2),
      'visible=' + r.visible,
      'scale=' + (st.bot.scale === undefined ? 1 : st.bot.scale).toFixed(3),
      'bbox=' + bbox(r.bodyPath),
      'eyes=' + (r.eyes ? r.eyes.length : 0),
      'dots=' + (st.dots ? st.dots.filter(d => d.visible).length : 0));
  }
}

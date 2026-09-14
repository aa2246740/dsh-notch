// StatusOrbit maths — verified straight out of the shipped page.
//
// The compact pill is painted by index.html (Phase 4). Its arithmetic is a port
// of macos/Sources/StatusOrbit.swift, and a port is exactly the kind of code
// where a transposed sign or a missing easing term looks plausible on screen and
// is invisible in a screenshot. This harness therefore EXTRACTS the marked
// `orbit-math` section from the shipped file and asserts the numbers the page
// draws with — the same relationship macos/Tests/MotionProbe.swift has to the
// Swift sources.
//
//   node windows/tests/orbit-math.test.mjs
//
// Exit code = number of failures. No dependencies, no browser, no build.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const page = join(here, '..', 'DshNotchWin', 'Assets', 'notch', 'index.html');
const html = readFileSync(page, 'utf8');

let failures = 0;
const check = (name, ok, detail) => {
  if (!ok) failures++;
  console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${name.padEnd(46)} ${detail}`);
};

// ---------------------------------------------------------------------------
// 0. the whole inline script must parse (a syntax error there is a blank pill)
// ---------------------------------------------------------------------------
{
  const script = html.match(/<script>([\s\S]*?)<\/script>/);
  let ok = false;
  let detail = 'no <script> block found';
  if (script) {
    try {
      new Function(script[1]);
      ok = true;
      detail = `${script[1].split('\n').length} lines parse`;
    } catch (err) {
      detail = err.message;
    }
  }
  check('page script parses', ok, detail);
}

// ---------------------------------------------------------------------------
// 1. extract the maths
// ---------------------------------------------------------------------------
const start = html.indexOf('// ---- orbit-math:start');
const end = html.indexOf('// ---- orbit-math:end');
if (start < 0 || end < 0) {
  console.log('  [FAIL] orbit-math markers                                   missing');
  process.exit(1);
}

const source = html.slice(start, end);
const exported = [
  'BLUE', 'GREEN', 'RED', 'AMBER', 'ease', 'smooth', 'clamp01', 'mixN', 'mixRGB',
  'FLIGHT_DURATION', 'RETURN_DURATION', 'SPIN_DURATION', 'RUNNING_VELOCITY',
  'layout', 'layTotal', 'layHeight', 'layMiddleY', 'layBottomY', 'layMix', 'layFlight',
  'brushRoute', 'routePoints', 'motionFrame', 'strokePoints', 'returnFrame',
  'returnStrokePoints', 'spinPosition', 'spinVelocity', 'decisionMorph',
  'decisionClosing', 'separationOpacity',
];
const M = new Function(`${source}\nreturn {${exported.join(',')}};`)();

const near = (a, b, tol = 1e-6) => Math.abs(a - b) <= tol;

// ---------------------------------------------------------------------------
// 2. the brush route: five phases, in order, on the right side of the pill
// ---------------------------------------------------------------------------
for (const failed of [false, true]) {
  const name = failed ? 'failure' : 'success';
  const r = M.brushRoute(failed, 0);
  check(`route phases ordered (${name})`,
    r.departure > 0 && r.sourceExit > r.departure && r.arrival > r.sourceExit
      && r.resultDrawn > r.arrival && r.returned > r.resultDrawn && r.total > r.returned,
    `${r.departure.toFixed(1)} < ${r.sourceExit.toFixed(1)} < ${r.arrival.toFixed(1)} `
      + `< ${r.resultDrawn.toFixed(1)} < ${r.returned.toFixed(1)} < ${r.total.toFixed(1)}`);

  // The destination circle is one lamp pitch above (success) or below (failure)
  // the source rim, and the whole route stays inside the 30 pt frame's x range.
  const destinationY = failed ? 28 : -28;
  const circle = r.points.filter((_, i) => r.lengths[i] >= r.arrival - 1e-9 && r.lengths[i] <= r.resultDrawn + 1e-9);
  const ys = circle.map(p => p[1]);
  const xs = r.points.map(p => p[0]);
  check(`destination circle is one pitch ${failed ? 'down' : 'up'} (${name})`,
    near(Math.min(...ys), destinationY - 9.5, 0.05) && near(Math.max(...ys), destinationY + 9.5, 0.05)
      && near(Math.min(...xs), -9.5, 0.05) && near(Math.max(...xs), 9.5, 0.05),
    `y ${Math.min(...ys).toFixed(2)}..${Math.max(...ys).toFixed(2)} (expect ${destinationY - 9.5}..${destinationY + 9.5}), `
      + `x ${Math.min(...xs).toFixed(2)}..${Math.max(...xs).toFixed(2)}`);
}

// ---------------------------------------------------------------------------
// 3. the head's timeline: monotone, inside the route, and it ends where the
//    stroke is supposed to settle
// ---------------------------------------------------------------------------
for (const failed of [false, true]) {
  for (const returning of [false, true]) {
    const name = `${failed ? 'failure' : 'success'}${returning ? '/returning' : '/settling'}`;
    const route = M.brushRoute(failed, 0.7);
    const limit = returning ? route.total : route.resultDrawn;

    let last = -1, monotone = true, ordered = true, settled = null;
    for (let i = 0; i <= 200; i++) {
      const f = M.motionFrame(i / 200, failed, returning, 0.7);
      if (f.distance < last - 1e-9) monotone = false;
      if (f.tailLength > f.distance + 1e-9 || f.distance > limit + 1e-9) ordered = false;
      if (f.tint < -1e-9 || f.tint > 1 + 1e-9) ordered = false;
      last = f.distance;
      settled = f;
    }
    check(`head monotone, tail behind it (${name})`, monotone && ordered,
      `ends at ${last.toFixed(2)} of ${limit.toFixed(2)}`);
    check(`head settles on the outcome slot (${name})`,
      returning ? settled.returned && near(settled.distance, route.total, 0.05)
                : near(settled.distance, route.resultDrawn, 0.05) && settled.arrived && !settled.returning,
      `distance=${settled.distance.toFixed(2)} returned=${settled.returned} arrived=${settled.arrived}`);
    // A brush that settles in the outcome slot must END in the outcome colour;
    // one that returns must end blue again.
    check(`ink ends ${returning ? 'blue' : 'in the outcome colour'} (${name})`,
      returning ? settled.tint < 0.02 : settled.tint > 0.98,
      `tint=${settled.tint.toFixed(3)}`);
    check(`tail is a stroke, not a ring (${name})`,
      settled.tailLength >= 0 && settled.tailLength <= 18 + route.departure + 1,
      `tailLength=${settled.tailLength.toFixed(2)}`);
  }
}

// ---------------------------------------------------------------------------
// 4. the layout timeline is what the window height follows
// ---------------------------------------------------------------------------
{
  // Running -> success while another task keeps running: one slot becomes two.
  const from = M.layout(0, 1, 0, 0);
  const to = M.layout(1, 1, 0, 0);
  const flight = { failed: false, returnsToRunning: true, destinationBefore: 0, angle: 0 };
  let last = -1, monotone = true;
  for (let i = 0; i <= 200; i++) {
    const h = M.layHeight(M.layFlight(from, to, i / 200, flight));
    if (h < last - 1e-9) monotone = false;
    last = h;
  }
  check('flight grows the shell monotonically',
    monotone && near(M.layHeight(M.layFlight(from, to, 0, flight)), 20, 1e-9)
      && near(M.layHeight(M.layFlight(from, to, 1, flight)), 48, 1e-9),
    `20 -> 48 pt (final ${last.toFixed(2)})`);

  // The last running task finishing INTO an existing RED result: two slots
  // become one. This is the case docs/motion-continuity.md:15 is about — the red
  // disk's displacement must equal the shell height change on every frame,
  // because both read the same OrbitLayout sample. (When the surviving slot is
  // above the collapsing one its y is already pinned by the slot formula; the
  // red disk is the one that has to travel.)
  const two = M.layout(0, 1, 1, 0);
  const one = M.layout(0, 0, 1, 0);
  const closing = { failed: false, returnsToRunning: false, destinationBefore: 1, angle: 0 };
  const height0 = M.layHeight(two), bottom0 = M.layBottomY(two);
  let previous = height0;
  let shrinking = true, diskTracks = true, moved = 0;
  for (let i = 1; i <= 400; i++) {
    const l = M.layFlight(two, one, i / 400, closing);
    const h = M.layHeight(l), bottomY = M.layBottomY(l);
    if (h > previous + 1e-9) shrinking = false;
    if (Math.abs((h - height0) - (bottomY - bottom0)) > 1e-9) diskTracks = false;
    moved = bottomY - bottom0;
    previous = h;
  }
  check('last task shrinks the shell monotonically', shrinking,
    `48 -> ${M.layHeight(M.layFlight(two, one, 1, closing)).toFixed(2)} pt`);
  check('disk displacement equals the height change', diskTracks && near(moved, -28, 1e-6),
    `red disk moves ${moved.toFixed(2)} pt while the shell loses 28 pt`);

  // Slot geometry: the documented 1/2/3/4-lamp stack.
  const mixed = M.layout(1, 1, 1, 1);
  check('four slots stack on a 28 pt pitch',
    M.layHeight(mixed) === 104 && M.layMiddleY(mixed) === 66 && M.layBottomY(mixed) === 94
      && M.layHeight(M.layout(0, 1, 0, 0)) === 20 && M.layHeight(M.layout(0, 0, 0, 0)) === 20,
    `height=${M.layHeight(mixed)} middle=${M.layMiddleY(mixed)} bottom=${M.layBottomY(mixed)}`);
}

// ---------------------------------------------------------------------------
// 5. the reply: 0.98 s, and its drawing clock lands on the running velocity
// ---------------------------------------------------------------------------
{
  const route = M.brushRoute(false, 0.3);
  let last = -1, monotone = true, inRange = true;
  for (let i = 0; i <= 300; i++) {
    const f = M.returnFrame(i / 300, 0.3);
    if (f.distance < last - 1e-9) monotone = false;
    if (f.distance > route.total + 1e-9) inRange = false;
    last = f.distance;
  }
  check('reply travel is monotone to the source', monotone && inRange,
    `${route.resultDrawn.toFixed(1)} -> ${last.toFixed(1)} of ${route.total.toFixed(1)}`);
  const a = M.returnFrame(0, 0.3), z = M.returnFrame(1, 0.3);
  check('reply clears the amber before drawing',
    near(a.fill, 1, 1e-9) && near(a.strokeOpacity, 0, 1e-9) && near(z.fill, 0, 1e-9) && near(z.strokeOpacity, 1, 1e-9),
    `fill ${a.fill.toFixed(2)}->${z.fill.toFixed(2)}, stroke ${a.strokeOpacity.toFixed(2)}->${z.strokeOpacity.toFixed(2)}`);
  check('reply hands the count over at the end',
    near(a.countMix, 0, 1e-9) && near(z.countMix, 1, 1e-9) && near(z.collapse, 1, 1e-9),
    `countMix ${a.countMix.toFixed(2)}->${z.countMix.toFixed(2)}, collapse ${z.collapse.toFixed(2)}`);
  check('reply duration is 0.98 s', M.RETURN_DURATION === 0.98, `${M.RETURN_DURATION}`);
}

// ---------------------------------------------------------------------------
// 6. the spin: continuous velocity, no jump at the handover
// ---------------------------------------------------------------------------
{
  const spin = { began: 10, angle: -Math.PI / 2, initialVelocity: M.RUNNING_VELOCITY,
                 finalVelocity: M.RUNNING_VELOCITY, delay: 0 };
  check('spin starts and ends at the running speed',
    near(M.spinVelocity(spin, 10), M.RUNNING_VELOCITY, 1e-9)
      && near(M.spinVelocity(spin, 10 + M.SPIN_DURATION), M.RUNNING_VELOCITY, 1e-9),
    `${M.spinVelocity(spin, 10).toFixed(4)} -> ${M.spinVelocity(spin, 10 + M.SPIN_DURATION).toFixed(4)} rad/s`);

  // A deceleration into amber: the position's finite difference must match the
  // analytic velocity everywhere (that is the "no reversal" contract). The
  // clamp at t=0 is real — the spin cannot have run before it began — so the
  // centred difference starts one step in.
  const down = { began: 0, angle: 0, initialVelocity: M.RUNNING_VELOCITY, finalVelocity: 0, delay: 0 };
  let worst = 0;
  for (let i = 1; i < 60; i++) {
    const t = i * M.SPIN_DURATION / 60;
    const numeric = (M.spinPosition(down, t + 1e-5) - M.spinPosition(down, t - 1e-5)) / 2e-5;
    worst = Math.max(worst, Math.abs(numeric - M.spinVelocity(down, t)));
  }
  const launch = (M.spinPosition(down, 1e-6) - M.spinPosition(down, 0)) / 1e-6;
  check('spin velocity matches its position', worst < 1e-3,
    `max error ${worst.toExponential(2)} rad/s over 59 samples`);
  check('spin launches at its initial velocity', Math.abs(launch - M.RUNNING_VELOCITY) < 0.01,
    `${launch.toFixed(4)} vs ${M.RUNNING_VELOCITY.toFixed(4)} rad/s`);

  const held = M.spinPosition(down, M.SPIN_DURATION + 5) - M.spinPosition(down, M.SPIN_DURATION);
  check('a stopped spin really stops', Math.abs(held) < 1e-9, `drift after handover ${held.toExponential(2)}`);
}

// ---------------------------------------------------------------------------
// 7. the solo blue <-> amber morph
// ---------------------------------------------------------------------------
{
  const blue = M.decisionMorph(0), amber = M.decisionMorph(1);
  check('running arc is 70 % at amount 0',
    near(blue.trim, 0.70, 1e-9) && near(blue.fill, 0, 1e-9) && near(blue.flip, 0, 1e-9),
    `trim=${blue.trim.toFixed(3)} fill=${blue.fill.toFixed(3)} flip=${blue.flip.toFixed(3)}`);
  check('amber disk is solid at amount 1',
    near(amber.trim, 0, 1e-9) && near(amber.fill, 1, 1e-9) && near(amber.flip, 1, 1e-9),
    `trim=${amber.trim.toFixed(3)} fill=${amber.fill.toFixed(3)} flip=${amber.flip.toFixed(3)}`);
  // The gap may not open before the centre is cleared, and neither channel may
  // go backwards in the direction it moves (docs/motion-continuity.md:51).
  let fillMonotone = true, flipMonotone = true;
  for (let i = 1; i <= 100; i++) {
    if (M.decisionMorph(i / 100).fill < M.decisionMorph((i - 1) / 100).fill - 1e-9) fillMonotone = false;
    if (M.decisionMorph(i / 100).flip < M.decisionMorph((i - 1) / 100).flip - 1e-9) flipMonotone = false;
  }
  check('morph channels are monotone', fillMonotone && flipMonotone, 'fill and flip');

  const closing = M.decisionClosing(1), open = M.decisionClosing(0);
  check('closing reaches a full ring',
    near(open.trim, 0.70, 1e-9) && near(closing.trim, 1, 1e-9) && near(closing.fill, 1, 1e-9)
      && near(closing.tint, 1, 1e-9) && near(closing.flip, 1, 1e-9),
    `trim=${closing.trim.toFixed(3)} fill=${closing.fill.toFixed(3)} tint=${closing.tint.toFixed(3)}`);
}

// ---------------------------------------------------------------------------
// 8. separation: two lamps may not touch
// ---------------------------------------------------------------------------
check('lamps fade between 20 and 28 pt',
  M.separationOpacity(1, 20) === 0 && M.separationOpacity(1, 28) === 1
    && near(M.separationOpacity(0.5, 24), 0.25, 1e-9) && M.separationOpacity(1, 19) === 0,
  'opacity(20)=0 opacity(24)=0.25 opacity(28)=1');

console.log('');
console.log(failures === 0 ? 'RESULT: PASS' : `RESULT: FAIL (${failures} check(s))`);
process.exit(failures);

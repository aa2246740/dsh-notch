/* ---------------------------------------------------------------------------
   Phase 5 — the idle robot (macos/Sources/IdleRobot.swift, 423 lines).

   UPSTREAM IS THE RENDERER. `tools/idle/renderer.js` (OpenBotMotion) already
   builds the mascot as SVG DOM from `poseFor(id, time)` in `tools/idle/motions.js`,
   and both files are vendored here BYTE-IDENTICAL: this file never re-implements
   the 3D projector, the hull, the eye rig or the twelve-colour dance cycle.
   PLAN §7.3 assumed exactly this ("机器人动画的 JS 源码自包含可复用").

   What this file adds is the one thing the Swift port needed the 9.4 MB of baked
   JSON for: the frames must become *our* pixels, so that
     · the caps' own canvas is the only visible surface (one compositor layer,
       no SVG filter/AA differences between the DOM and the canvas), and
     · `getImageData` can still assert what was really painted (Phase 2-4 rule).
   So every frame we pull the LIVE path/eye/dot attributes the renderer just
   wrote and re-draw them with Canvas 2D. The renderer stays the source of truth;
   it is simply rasterised into our canvas instead of the browser's.

   The scheduler (`RobotDirector`) is a port of `IdleDirector` (IdleRobot.swift:79-203)
   and the transition machinery (`RobotDeparture`, `IdlePresence`) a port of
   IdleRobot.swift:293-378, with the timings and easings taken verbatim.
   --------------------------------------------------------------------------- */
(function () {
  'use strict';

  const DPR_MAX = 2;

  /* ------------------------------------------------------------------ maths */
  const clamp01 = (t) => (t < 0 ? 0 : t > 1 ? 1 : t);
  /* IdleInterpolation.smooth (IdleRobot.swift:58-60). */
  const smooth = (t) => { const x = clamp01(t); return x * x * x * (x * (x * 6 - 15) + 10); };
  /* maps.js: ease() in motions.js is the same quintic. */
  const mixN = (a, b, t) => a + (b - a) * t;

  /* The renderer's `d` attributes are "M x y L x y A rx ry rot large sweep x y
     ... Z" — a rounded convex hull (renderer.js:371-385), so the polygon is the
     M/L points plus each arc's END point. A hand-rolled state machine avoids the
     ~180 substring pairs a `split`/`match` would allocate on every frame. */
  function eachPoint(d, visit) {
    if (!d) return 0;
    const token = /[MLAZmlazHhVv]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/g;
    const counts = { M: 2, L: 2, A: 7, H: 1, V: 1, Z: 0 };
    let command = '', left = 0, x = 0, y = 0, n = 0;
    const args = [];
    let match;
    while ((match = token.exec(d)) !== null) {
      const text = match[0];
      if (text.length === 1 && /[A-Za-z]/.test(text)) {
        command = text.toUpperCase();
        left = counts[command] === undefined ? 0 : counts[command];
        args.length = 0;
        continue;
      }
      if (left === 0) continue;
      args.push(parseFloat(text));
      left--;
      if (left > 0) continue;
      if (command === 'M' || command === 'L') {
        x = args[0]; y = args[1]; visit(x, y); n++;
      } else if (command === 'A') {
        /* rx ry rotation large-arc sweep x y — only the endpoint is a vertex. */
        x = args[5]; y = args[6]; visit(x, y); n++;
      } else if (command === 'H') {
        x = args[0]; visit(x, y); n++;
      } else if (command === 'V') {
        y = args[0]; visit(x, y); n++;
      }
      args.length = 0;
      left = counts[command] === undefined ? 0 : counts[command];
    }
    return n;
  }

  /* The renderer writes `translate(x, y) rotate(deg)` on the eyes
     (renderer.js:1500). Returned as a matrix so the same value can be mixed
     between two frames and applied to a canvas. */
  function parseTransform(value) {
    const out = { a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 };
    if (!value) return out;
    const fn = /(\w+)\s*\(([^)]*)\)/g;
    let call;
    while ((call = fn.exec(value)) !== null) {
      const name = call[1];
      const nums = (call[2].match(/-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/g) || []).map(Number);
      if (name === 'translate') {
        out.e += nums[0] || 0;
        out.f += nums[1] || 0;
      } else if (name === 'rotate') {
        const r = (nums[0] || 0) * Math.PI / 180;
        const cos = Math.cos(r), sin = Math.sin(r);
        const a = out.a * cos + out.c * sin, b = out.b * cos + out.d * sin;
        const c = out.a * -sin + out.c * cos, d = out.b * -sin + out.d * cos;
        out.a = a; out.b = b; out.c = c; out.d = d;
      } else if (name === 'scale') {
        out.a *= nums[0] === undefined ? 1 : nums[0];
        out.d *= nums[1] === undefined ? (nums[0] === undefined ? 1 : nums[0]) : nums[1];
      } else if (name === 'matrix' && nums.length === 6) {
        const a = out.a * nums[0] + out.c * nums[1], b = out.b * nums[0] + out.d * nums[1];
        const c = out.a * nums[2] + out.c * nums[3], d = out.b * nums[2] + out.d * nums[3];
        out.e += out.a * nums[4] + out.c * nums[5];
        out.f += out.b * nums[4] + out.d * nums[5];
        out.a = a; out.b = b; out.c = c; out.d = d;
      }
    }
    return out;
  }

  /* The eye rect fills and the dots layer are irrelevant here: the Swift canvas
     paints the body 0xe5e5e7 / the dance pigment, the eyes a fixed ink, and the
     dots charcoal (IdleRobot.swift:261-287). The vendored SVG sets the eyes to
     WHITE (`eyeFill = colorToCss(pose.eyeColor, '#ffffff')`), which is not the
     mascot, so the eye ink is overridden — the one place where this file
     deliberately does not inherit the renderer's palette. */
  const INK_BODY_NEUTRAL = '#e5e5e7';
  const INK_EYE = '#171719';
  const INK_DOTS = '#222126';

  /* The renderer hands the body fill over as `#rrggbb` (the SVG attribute), and
     the departure's colour handoff re-expresses it as `rgba(...)`. Both have to
     come back as RGB, because the robot's own pixel probe matches against
     whichever one was painted last. */
  const hexRGB = (value, fallback) => {
    if (typeof value === 'string') {
      const hex = /^#([0-9a-f]{6})$/i.exec(value);
      if (hex) {
        const n = parseInt(hex[1], 16);
        return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255];
      }
      const rgba = /^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)/i.exec(value);
      if (rgba) return [+rgba[1] / 255, +rgba[2] / 255, +rgba[3] / 255];
    }
    return fallback;
  };

  /* Two matrices, element-wise. Enough for the eye's translate+rotate, and it
     keeps a carried or blended frame's transform consistent with its geometry. */
  const mixMatrix = (a, b, t) => (!a ? b : !b ? a : {
    a: mixN(a.a, b.a, t), b: mixN(a.b, b.b, t), c: mixN(a.c, b.c, t),
    d: mixN(a.d, b.d, t), e: mixN(a.e, b.e, t), f: mixN(a.f, b.f, t),
  });

  /* `parseTransform` keeps its result as a matrix so a carried or blended frame
     can interpolate the eye's placement along with its geometry. */
  const applyMatrix = (ctx, m) => {
    if (m) ctx.transform(m.a, m.b, m.c, m.d, m.e, m.f);
  };

  /* ------------------------------------------------------------------ engine */
  const RobotPose = (() => {
    const state = {
      ready: false,
      error: 'not initialised',
      host: null,
      svg: null,
      body: null,
      eyesGroup: null,
      dots: null,
      bodyPath: null,
      bodyPathD: null,
      lastGood: null,
    };

    function init(options) {
      const opts = options || {};
      try {
        if (!state.host) {
          state.host = document.createElement('div');
          state.host.id = 'robot-host';
          /* Off-screen but still laid out: WebView2 will not paint (and with it
             will not run the animation) in a display:none subtree. */
          state.host.style.cssText =
            'position:fixed;left:-2000px;top:0;width:280px;height:280px;opacity:0;pointer-events:none;';
          document.body.appendChild(state.host);
        }
        if (!state.ready) {
          if (!window.OpenBotMotion || typeof window.OpenBotMotion.mount !== 'function') {
            throw new Error('OpenBotMotion missing (Assets/notch/idle/renderer.js)');
          }
          if (typeof window.poseFor !== 'function') {
            throw new Error('poseFor missing (Assets/notch/idle/motions.js)');
          }
          state.host.dataset.motion = 'blink';
          state.bot = window.OpenBotMotion.mount(state.host, { bot: 1, size: 280, autoplay: false, loop: false });
          state.svg = state.host.querySelector('svg');
          /* The LAST body path, not the first: the renderer creates the two
             ghost nodes (bot #6's split bodies) before the center one, and they
             are left with no `d` and `display:none` (renderer.js:1446-1448). */
          const bodies = state.svg && state.svg.querySelectorAll('.bodies-layer path');
          state.body = bodies && bodies.length ? bodies[bodies.length - 1] : null;
          /* The eyes layer holds three groups for the same reason: ghost-left,
             ghost-right, then the center bot's. Ours is the LAST one. */
          const eyeGroups = state.svg && state.svg.querySelectorAll('.eyes-layer g');
          state.eyesGroup = eyeGroups && eyeGroups.length ? eyeGroups[eyeGroups.length - 1] : null;
          state.dots = state.svg && state.svg.querySelector('.dots-layer');
          if (!state.svg || !state.body) throw new Error('renderer produced no body path');
          state.ready = true;
          state.error = null;
        }
        /* Force a pose so the very first frame has geometry even if the caller
           never samples (the self-test asserts the bbox on the first paint). */
        setMotion(opts.clip || 'blink');
        frame(opts.clip || 'blink', 0);
        return true;
      } catch (err) {
        state.error = String((err && err.message) || err);
        return false;
      }
    }

    /* The player's own clock would immediately overwrite the pose (`tick`), so
       `previewTime` is what drives every frame here (renderer.js:1510). */
    function setMotion(clip) {
      if (!state.ready) return false;
      if (state.host.dataset.motion !== clip) state.host.dataset.motion = clip;
      return true;
    }

    /* The renderer's clip id is not our action id: motions.js re-bases the time
       for the three transition clips (cube-in 2.22 s, satellite 2.00 s / 7.04 s)
       and clamps it itself, so "elapsed" is the generic 0..0.1 s-scale time and
       `staticTime` is what the pose is actually sampled at. */
    function staticTime(clip, t) {
      if (clip === 'cube-in') return 2.22 + Math.min(t, 1.05);
      if (clip === 'satellite-out') return 2 + Math.min(t, 0.8);
      if (clip === 'satellite-in') return 7.04 + Math.min(t, 0.82);
      return t;
    }

    /* `IdleDirector.displayFrame` natural blinking (IdleRobot.swift:96-116):
       3.7/4.9/3.2/4.6/4.1/3.5 s cycle (docs/motion-continuity.md:17), 90 ms to
       close and 190 ms to reopen, and it is not applied while the open-eye
       actions (sleep / blink / sneeze) are running. */
    const BLINK_DURATIONS = [3.7, 4.9, 3.2, 4.6, 4.1, 3.5];
    const BLINK_CYCLE = BLINK_DURATIONS.reduce((a, b) => a + b, 0);
    function blinkClosure(elapsed) {
      let phase = Math.max(0, elapsed) % BLINK_CYCLE;
      for (const duration of BLINK_DURATIONS) {
        if (phase < duration) {
          const t = phase - (duration - 0.28);
          if (t < 0) return 0;
          return t < 0.09 ? smooth(t / 0.09) : 1 - smooth((t - 0.09) / 0.19);
        }
        phase -= duration;
      }
      return 0;
    }

    function frame(clip, t) {
      if (!state.ready) return null;
      setMotion(clip);
      window.previewTime = staticTime(clip, t);
      try { state.bot.seek(window.previewTime); } catch (err) { state.error = String(err); return null; }
      const pose = sample();
      if (pose && pose.d) state.lastGood = pose;
      return pose;
    }

    /* What the renderer actually wrote into the DOM, before any of our drawing.
       This is the evidence that the vendored engine is alive and that our
       attribute assumptions (polyline `d`, translate+rotate eyes) hold. */
    function inspect(clip, t) {
      if (!state.ready) return { ready: false, error: state.error };
      const pose = frame(clip === undefined ? 'blink' : clip, t === undefined ? 0 : t);
      const raw = state.eyesGroup && state.eyesGroup.children[0];
      return {
        ready: true, error: null,
        clip: state.host.dataset.motion,
        previewTime: window.previewTime,
        dLength: state.body.getAttribute('d') ? state.body.getAttribute('d').length : 0,
        dHead: (state.body.getAttribute('d') || '').slice(0, 40),
        fill: state.body.getAttribute('fill'),
        eyes: pose ? pose.eyes.length : 0,
        eyeTransform: raw ? raw.getAttribute('transform') : null,
        eyeW: raw ? raw.getAttribute('width') : null,
        dots: pose ? pose.dots.length : 0,
        lastGood: !!state.lastGood,
      };
    }

    /* `IdleRobotCanvas`'s dance envelope (IdleRobot.swift:223-224): the dance
       clip is the LONG one, so it alone blends in and out through the neutral
       body over 0.35 s / 0.45 s. Every other clip has weight 1. */
    function danceBlend(duration, elapsed) {
      if (!(duration > 10)) return 1;
      const edge = clamp01(Math.min(elapsed / 0.35, (duration - elapsed) / 0.45));
      return edge * edge * (3 - 2 * edge);
    }

    function sample() {
      const pose = {
        d: state.body.getAttribute('d') || '',
        body: state.body.getAttribute('fill') || INK_BODY_NEUTRAL,
        eyes: [],
        dots: [],
      };
      const group = state.eyesGroup;
      if (group && group.style.display !== 'none') {
        const kids = group.children;
        for (let i = 0; i < kids.length; i++) {
          const r = kids[i];
          pose.eyes.push({
            x: parseFloat(r.getAttribute('x')) || 0,
            y: parseFloat(r.getAttribute('y')) || 0,
            w: parseFloat(r.getAttribute('width')) || 0,
            h: parseFloat(r.getAttribute('height')) || 0,
            rx: parseFloat(r.getAttribute('rx')) || 0,
            opacity: parseFloat(r.getAttribute('opacity')),
            t: parseTransform(r.getAttribute('transform')),
          });
        }
      }
      if (state.dots && state.dots.style.display !== 'none') {
        const kids = state.dots.children;
        for (let i = 0; i < kids.length; i++) {
          const c = kids[i];
          if (c.style.display === 'none') continue;
          pose.dots.push({
            x: parseFloat(c.getAttribute('cx')) || 0,
            y: parseFloat(c.getAttribute('cy')) || 0,
            r: parseFloat(c.getAttribute('r')) || 0,
          });
        }
      }
      return pose;
    }

    /* `IdleInterpolation.carry` (IdleRobot.swift:47-57), piecewise: points and
       eye centres extrapolate the previous frame's delta at 240 Hz; the
       non-negative channels (eye w/h/r, opacity, and here the radius) clamp a
       shrinking delta at zero. It is what makes an interrupted transition keep
       its velocity instead of snapping. */
    function carry(pose, previous, seconds) {
      if (!previous || !previous.d || !pose.d) return pose;
      const distance = seconds * 240;
      if (!(distance > 0)) return pose;
      const out = { d: pose.d, body: pose.body, eyes: [], dots: [], transform: null };
      const cache = new Map();
      const prev = (tag) => {
        let p = cache.get(tag);
        if (!p) { p = []; eachPoint(tag, (x, y) => p.push(x, y)); cache.set(tag, p); }
        return p;
      };
      /* `d` is shared between the body and every clip path, so the tag IS the
         string; the eyes get their own tag from their geometry. */
      const self = prev(pose.d), was = prev(previous.d);
      if (self.length === was.length && self.length >= 4) {
        let out2 = '';
        for (let i = 0; i < self.length; i += 2) {
          out2 += (i ? 'L' : 'M') + (self[i] + (self[i] - was[i]) * distance).toFixed(2)
            + ' ' + (self[i + 1] + (self[i + 1] - was[i + 1]) * distance).toFixed(2);
        }
        out.d = out2 + 'Z';
      }
      for (let i = 0; i < pose.eyes.length; i++) {
        const a = pose.eyes[i], b = previous.eyes[i];
        if (!b) { out.eyes.push(a); continue; }
        const grow = (v, pv) => Math.max(0, v + (v - pv) * distance);
        out.eyes.push({
          x: a.x + (a.x - b.x) * distance,
          y: a.y + (a.y - b.y) * distance,
          w: grow(a.w, b.w), h: grow(a.h, b.h), rx: grow(a.rx, b.rx),
          opacity: clamp01(a.opacity + (a.opacity - b.opacity) * distance),
          t: a.t && b.t
            ? { a: a.t.a + (a.t.a - b.t.a) * distance, b: a.t.b + (a.t.b - b.t.b) * distance,
                c: a.t.c + (a.t.c - b.t.c) * distance, d: a.t.d + (a.t.d - b.t.d) * distance,
                e: a.t.e + (a.t.e - b.t.e) * distance, f: a.t.f + (a.t.f - b.t.f) * distance }
            : a.t,
        });
      }
      for (let i = 0; i < pose.dots.length; i++) {
        const a = pose.dots[i], b = previous.dots[i];
        if (!b) { out.dots.push(a); continue; }
        out.dots.push({
          x: a.x + (a.x - b.x) * distance,
          y: a.y + (a.y - b.y) * distance,
          r: Math.max(0, a.r + (a.r - b.r) * distance),
        });
      }
      return out;
    }

    function mix(a, b, t) {
      if (!a || !a.d) return b;
      if (!b || !b.d) return a;
      const w = clamp01(t);
      const out = { d: '', body: w < 0.5 ? a.body : b.body, eyes: [], dots: [], transform: null };
      const A = [], B = [];
      eachPoint(a.d, (x, y) => A.push(x, y));
      eachPoint(b.d, (x, y) => B.push(x, y));
      if (A.length === B.length && A.length >= 4) {
        let d = '';
        for (let i = 0; i < A.length; i += 2) {
          d += (i ? 'L' : 'M') + mixN(A[i], B[i], w).toFixed(2) + ' ' + mixN(A[i + 1], B[i + 1], w).toFixed(2);
        }
        out.d = d + 'Z';
      } else {
        out.d = w < 0.5 ? a.d : b.d;
      }
      const n = Math.min(a.eyes.length, b.eyes.length);
      for (let i = 0; i < n; i++) {
        const e = a.eyes[i], f = b.eyes[i];
        out.eyes.push({
          x: mixN(e.x, f.x, w), y: mixN(e.y, f.y, w),
          w: mixN(e.w, f.w, w), h: mixN(e.h, f.h, w), rx: mixN(e.rx, f.rx, w),
          opacity: mixN(e.opacity, f.opacity, w),
          t: mixMatrix(e.t, f.t, w),
        });
      }
      const m = Math.min(a.dots.length, b.dots.length);
      for (let i = 0; i < m; i++) {
        const p = a.dots[i], q = b.dots[i];
        out.dots.push({ x: mixN(p.x, q.x, w), y: mixN(p.y, q.y, w), r: mixN(p.r, q.r, w) });
      }
      return out;
    }

    /* The canvas box, in CSS px, that the artwork is rasterised into. The host
       window is 30 pt wide while collapsed (NotchGeometry.RestWidth), and the
       renderer's viewBox is 280 units centred on the origin — the same mapping
       IdleRobotCanvas expresses as `40 / 280` inside a 30x42 frame. */
    function draw(ctx, cssW, cssH, cx, cy, unit, pose) {
      if (!state.ready || !pose || !pose.d) return false;
      const s = unit / 280;
      if (!(s > 0)) return false;
      if (pose.dots.length > 0) {
        ctx.save();
        ctx.fillStyle = INK_DOTS;
        for (const d of pose.dots) {
          if (!(d.r > 0.01)) continue;
          ctx.beginPath();
          ctx.arc(cx + d.x * s, cy + d.y * s, d.r * s, 0, Math.PI * 2);
          ctx.fill();
        }
        ctx.restore();
      }
      ctx.save();
      ctx.translate(cx, cy);
      ctx.scale(s, s);
      /* Path2D is immutable, so the path object is rebuilt only when the live
         `d` string changes — which is every frame while an action plays, and
         never on the settled idle frame. */
      if (state.bodyPathD !== pose.d) {
        state.bodyPath = new Path2D(pose.d);
        state.bodyPathD = pose.d;
      }
      const shape = state.bodyPath;
      ctx.fillStyle = pose.body || INK_BODY_NEUTRAL;
      ctx.fill(shape);
      if (pose.eyes.length > 0) {
        ctx.save();
        ctx.clip(shape);
        ctx.fillStyle = INK_EYE;
        for (const e of pose.eyes) {
          if (!(e.w > 0.05) || !(e.h > 0.05)) continue;
          ctx.save();
          ctx.globalAlpha = e.opacity === e.opacity ? e.opacity : 1;
          applyMatrix(ctx, e.t);
          ctx.beginPath();
          const rx = Math.max(0, Math.min(e.rx, Math.min(e.w, e.h) / 2));
          if (rx > 0.01 && ctx.roundRect) ctx.roundRect(-e.w / 2, -e.h / 2, e.w, e.h, rx);
          else ctx.rect(-e.w / 2, -e.h / 2, e.w, e.h);
          ctx.fill();
          ctx.restore();
        }
        ctx.restore();
      }
      ctx.restore();
      return true;
    }

    /* The painted bounds in viewBox units, read back from the LIVE path string
       (not from a pose table), so the self-test asserts the drawn geometry. */
    function bbox(pose) {
      if (!pose || !pose.d) return null;
      let minX = 1e9, maxX = -1e9, minY = 1e9, maxY = -1e9;
      const n = eachPoint(pose.d, (x, y) => {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      });
      if (!n) return null;
      return { minX, maxX, minY, maxY, w: maxX - minX, h: maxY - minY, points: n };
    }

    return {
      init, frame, sample, setMotion, staticTime, blinkClosure, danceBlend,
      carry, mix, draw, bbox, inspect,
      /* Last-resort neutral geometry for callers that must never get null. */
      neutralFallback() { return state.lastGood || neutral(); },
      get ready() { return state.ready; },
      get error() { return state.error; },
      get svg() { return state.svg; },
      get host() { return state.host; },
      neutral() { return frame('blink', 0); },
    };
  })();

  /* ---------------------------------------------------------------- director */
  /* `IdleDirector` (IdleRobot.swift:79-203). Only advances while the robot is
     visible; Reduce Motion holds it at rest and no action is ever scheduled. */
  const BASIC_ACTIONS = ['blink', 'scan', 'tilt', 'nod', 'stretch', 'hop', 'balance', 'sneeze', 'sleep'];
  /* `IdleLibrary` clip durations, measured from the baked resources (the Swift
     library reads the same numbers out of the JSON headers). */
  const CLIP_DURATION = {
    blink: 7, scan: 7, tilt: 7, nod: 7, stretch: 7, hop: 7, balance: 7,
    sneeze: 7, sleep: 9, 'cube-in': 1.05, 'satellite-out': 0.8, 'satellite-in': 0.82,
  };
  const DANCE_DURATION = 20.783;

  function Random() { return Math.random(); }

  class RobotDirector {
    constructor(now) {
      this.now = now || (() => performance.now() / 1000);
      this.running = false;
      this.action = 'blink';
      this.began = 0;
      this.duration = CLIP_DURATION.blink;
      this.previous = 'blink';
      this.asleep = false;
      this.reduceMotion = false;
      this.blend = null;          // { source, began }
      this.blendPrevious = null;
      this.blinkEpoch = 0;
      this.cache = { at: null, pose: null };
      this.lastFast = null;
      this.lastAt = null;
      this.rest = 0;
      this.nextBasic = 0;
      this.nextRare = 0;
      this.sequence = 0;
    }

    /* `IdleDirector.restDuration` — a fresh 5..10 s gap each time. */
    static restDuration() { return 5 + Random() * 5; }

    start(playImmediately) {
      this.running = true;
      this.reduceMotion = false;
      this.blend = null;
      this.blendPrevious = null;
      this.duration = CLIP_DURATION.blink;
      this.began = this.now();
      this.blinkEpoch = this.began;
      this.action = playImmediately === false ? null : 'blink';
      this.rest = RobotDirector.restDuration();
      this.nextBasic = this.began + this.rest;
      this.nextRare = this.began + 1200 + Random() * 1200;
    }

    stop() {
      this.running = false;
      this.action = null;
      this.blend = null;
      this.blendPrevious = null;
    }

    /* Reduce Motion: `tick` collapses to "no action, no blend" and `play` is a
       no-op (IdleRobot.swift:167,182). Turning it back off resumes scheduling
       without touching a clip that is already running. */
    setReduce(on) {
      const next = !!on;
      if (next === this.reduceMotion) return;
      this.reduceMotion = next;
      if (next) { this.blend = null; this.action = null; }
    }

    sleeping() { return this.asleep; }
    setAsleep(on) {
      const next = !!on;
      if (next === this.asleep) return;
      this.asleep = next;
      if (next) { this.action = null; this.blend = null; }
      else if (this.running) { this.began = this.now(); this.rest = RobotDirector.restDuration(); this.nextBasic = this.began + this.rest; }
    }

    currentClip() { return this.blend && this.blend.source ? this.blend.clip : (this.action || 'blink'); }

    elapsed(at) {
      const t = at === undefined ? this.now() : at;
      return this.action ? Math.max(0, t - this.began) : 0;
    }

    /* One cache slot: the renderer samples the SVG, so asking twice in a frame
       would re-render it twice. */
    poseAt(at) {
      if (!RobotPose.ready) return null;
      const t = at === undefined ? this.now() : at;
      if (this.cache.at === t && this.cache.pose) return this.cache.pose;
      const pose = this.buildPose(t);
      this.cache.at = t;
      this.cache.pose = pose;
      return pose;
    }

    buildPose(t) {
      const neutral = RobotPose.frame('blink', 0);
      if (!neutral) return null;
      let target = neutral;
      if (this.action) {
        const elapsed = Math.max(0, t - this.began);
        let pose = RobotPose.frame(this.action, elapsed);
        if (!pose) return neutral;
        if (this.action === 'dance') {
          /* Dance enters and leaves through the neutral body, at its original
             bounce speed (IdleRobot.swift:124-127). */
          const weight = smooth(Math.min(elapsed / 0.35, (this.duration - elapsed) / 0.45));
          pose = RobotPose.mix(neutral, pose, weight);
        }
        target = pose;
      }
      if (this.blend) {
        const elapsed = Math.max(0, t - this.blend.began);
        const moving = RobotPose.carry(this.blend.source, this.blendPrevious,
                                       0.06 * (1 - Math.exp(-elapsed / 0.06)));
        return RobotPose.mix(moving, target, smooth(elapsed / 0.35));
      }
      return target;
    }

    /* `beginBlend` (:136-139): capture the pose one 240 Hz frame ago so the
       outgoing geometry can carry its velocity into the new clip. */
    beginBlend(source, at) {
      this.blendPrevious = this.buildPose(at - 1 / 240);
      this.blend = { source: source, began: at, clip: this.action || 'blink' };
    }

    /* Any retarget has to drop the one-slot sample cache: the pose at instant
       `t` is about to change, and a stale hit would freeze the artwork while the
       clock (and every other observable) moved on. */
    invalidate() {
      this.cache.at = null;
      this.cache.pose = null;
    }

    play(id, at) {
      if (this.asleep || this.reduceMotion) return false;
      if (!(id in CLIP_DURATION) && id !== 'dance') return false;
      const t = at === undefined ? this.now() : at;
      const source = this.poseAt(t);
      this.beginBlend(source, t);
      this.duration = id === 'dance' ? 3 + Random() * 2 : CLIP_DURATION[id];
      this.previous = id;
      this.began = t;
      this.action = id;
      if (id === 'dance') this.nextRare = this.began + 1200 + Random() * 1200;
      this.invalidate();
      return true;
    }

    /* `resume(_:elapsed:from:)` (:190-195) — used when the entry transition
       lands, so the clip continues from the phase the transition was showing. */
    resume(id, elapsed, source, at) {
      if (this.reduceMotion || this.asleep) return false;
      const t = at === undefined ? this.now() : at;
      this.beginBlend(source === undefined ? this.poseAt(t) : source, t);
      this.blendPrevious = source === undefined ? null : source;
      this.duration = id === 'dance' ? 3 + Random() * 2 : CLIP_DURATION[id];
      this.previous = id;
      this.action = id;
      this.began = t - elapsed;
      this.invalidate();
      return true;
    }

    tryNext() { this.play(BASIC_ACTIONS[this.sequence % BASIC_ACTIONS.length]); this.sequence++; }

    tick(at) {
      const t = at === undefined ? this.now() : at;
      if (!this.running) return;
      if (this.asleep || this.reduceMotion) { this.blend = null; this.action = null; return; }
      if (this.blend && t - this.blend.began >= 0.35) this.blend = null;
      if (this.action) {
        if (t - this.began >= this.duration) {
          const source = this.poseAt(t);
          this.beginBlend(source, t);
          this.action = null;
          this.nextBasic = t + RobotDirector.restDuration();
        }
        return;
      }
      if (t >= this.nextRare) {
        this.play('dance', t);
        this.nextRare = t + 1200 + Random() * 1200;
      } else if (t >= this.nextBasic) {
        /* Never the same basic action twice in a row (IdleRobot.swift:178). */
        const pool = BASIC_ACTIONS.filter((a) => a !== this.previous);
        this.play(pool[Math.floor(Random() * pool.length)] || 'blink', t);
      }
    }

    /* `displayFrame` (:110-116): the sampled clip plus the independent natural
       blink, which is skipped for the actions that own their eyelids. */
    displayPose(at) {
      const t = at === undefined ? this.now() : at;
      const pose = this.poseAt(t);
      if (!pose) return null;
      if (this.reduceMotion || this.action === 'sleep' || this.action === 'blink' || this.action === 'sneeze') return pose;
      const close = RobotPose.blinkClosure(t - this.blinkEpoch);
      if (!(close > 0)) return pose;
      const eyes = pose.eyes.map((e) => {
        const h = Math.max(0.5, e.h * (1 - 0.95 * close));
        return { x: e.x, y: e.y, w: e.w, h: h, rx: Math.min(e.rx, h / 2), opacity: e.opacity, t: e.t };
      });
      return { d: pose.d, body: pose.body, eyes: eyes, dots: pose.dots };
    }

    speed() {
      const previous = this.lastFast;
      const pose = this.displayPose();
      this.lastFast = pose;
      this.lastAt = this.now();
      if (!previous || !pose) return null;
      return { previous: previous, pose: pose };
    }
  }

  /* --------------------------------------------------------------- departure */
  /* `RobotDeparture` (IdleRobot.swift:293-301). Note the deliberate reuse of
     the STATUS birth clock: `robotProgress` stretches the 1.22 s status
     sequence into the 0.9 s the robot actually gets, which is why the tiny
     point, the colour handoff and StatusBirth line up at 0.666 s. */
  const DEPARTURE_DURATION = 1.22;
  function departure(progress) {
    const p = clamp01(progress);
    const robotProgress = p * DEPARTURE_DURATION / 0.9;
    const statusProgress = p;
    return {
      progress: p,
      scale: 1 - 0.94 * smooth((robotProgress - 0.48) / 0.20),
      opacity: 1 - smooth((robotProgress - 0.68) / 0.06),
      /* 1 - the colour channel: `visibility` in Swift, so it is also the ink
         blend towards the incoming status colour. */
      colorMix: smooth((robotProgress - 0.68) / 0.06),
      statusOpacity: smooth((robotProgress - 0.68) / 0.06),
      statusScale: clamp01((statusProgress * DEPARTURE_DURATION - 0.666) / (DEPARTURE_DURATION - 0.666)),
    };
  }

  /* `StatusBirth` (StatusOrbit.swift:461-470): the departure's tiny point
     travels to the rim, becomes the pen, and the arc draws at the pen's own
     speed. The gate is inverted relative to the other progress values in the
     page, so it is handed over already untangled. */
  function statusBirth(gate) {
    const progress = clamp01(gate);
    return {
      gate: progress,
      blueDraw: clamp01((progress - 0.24) / 0.76),
      travel: smooth(progress / 0.24),
      draw: smooth((progress - 0.24) / 0.48),
      fill: smooth((progress - 0.72) / 0.18),
      text: smooth((progress - 0.86) / 0.14),
    };
  }

  window.NotchRobot = {
    DPR_MAX, BASIC_ACTIONS, CLIP_DURATION, DANCE_DURATION, DEPARTURE_DURATION,
    RobotPose, RobotDirector, departure, statusBirth, smooth, clamp01, blinkClosure: RobotPose.blinkClosure,
  };
})();

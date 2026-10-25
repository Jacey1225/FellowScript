import { describe, test, expect } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  VERSE_D, VERSE_Z, VERSE_FADE_Z, VERSE_OFFSETS, VERSE_VP, VERSE_BF_Z, PARALLAX, verseStep, verseProgress, verseState, depthZ,
  springStep, springOmega, parallaxTarget, SPRING_T63,
} from './verseDescent.js';
import { COMMUNITY_VERSES } from './communityVerses.js';
import { VERSE_START_P, VERSE_SPAN_P, P_END } from './adamHands/driver.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const bible = JSON.parse(fs.readFileSync(path.resolve(here, '../../../data/bible.json'), 'utf8'));

// bible.json chapters are one string: "10:1 text2text3text..." (verse numbers inline).
function webVerses(book, chapter, from, to) {
  const s = bible[book].find((c) => c.startsWith(`${chapter}:1 `));
  if (!s) throw new Error(`no ${book} ${chapter}`);
  const idx = { 1: `${chapter}:1 `.length };
  let cur = 1;
  for (;;) {
    const m = new RegExp(`(?<=[^\\d])${cur + 1}(?=[^\\d\\s])`).exec(s.slice(idx[cur] + 1));
    if (!m) break;
    cur += 1; idx[cur] = idx[cur - 1] + 1 + m.index;
  }
  const out = [];
  for (let v = from; v <= to; v++) {
    const start = idx[v] + (v === 1 ? 0 : String(v).length);
    out.push(s.slice(start, idx[v + 1] ?? s.length).trim());
  }
  return out.join(' ');
}

describe('community verses are exact World English Bible text', () => {
  const cases = [
    ['Hebrews 10:24-25', 'Hebrews', 10, 24, 25],
    ['Proverbs 27:17', 'Proverbs', 27, 17, 17],
    ['Ecclesiastes 4:9-12', 'Ecclesiastes', 4, 9, 12],
    ['Acts 2:44-45', 'Acts', 2, 44, 45],
    ['1 Thessalonians 5:11', '1 Thessalonians', 5, 11, 11],
  ];
  test('list matches the planned references in order', () => {
    expect(COMMUNITY_VERSES.map((v) => v.ref)).toEqual(cases.map((c) => c[0]));
    expect(COMMUNITY_VERSES.length).toBeGreaterThanOrEqual(3);
  });
  test.each(cases)('%s matches data/bible.json', (ref, book, ch, a, z) => {
    const v = COMMUNITY_VERSES.find((x) => x.ref === ref);
    expect(v.text).toBe(webVerses(book, ch, a, z));
    expect(v.text.split(/\s+/).length).toBeLessThanOrEqual(80);
  });
});

describe('verse depth maths', () => {
  const N = 5;
  const sweep = (fn, mobile = false) => {
    const end = mobile ? P_END.mobile : P_END.desktop;
    for (let p = VERSE_START_P - 0.05; p <= end + 0.05; p += 0.005) fn(p);
  };
  test('step and progress', () => {
    expect(verseStep(5)).toBeCloseTo((1 - VERSE_D.desktop) / 4, 9);
    expect(verseStep(5, VERSE_D.mobile)).toBeCloseTo((1 - VERSE_D.mobile) / 4, 9);
    expect(VERSE_D).toEqual({ desktop: 0.45, mobile: 0.30 });
    // last card finishes exactly at v = 1 in both layouts
    for (const d of [VERSE_D.desktop, VERSE_D.mobile]) expect(4 * verseStep(5, d) + d).toBeCloseTo(1, 9);
    expect(verseProgress(VERSE_START_P, false)).toBe(0);
    expect(verseProgress(VERSE_START_P - 1, true)).toBe(0);
    expect(verseProgress(P_END.desktop, false)).toBeCloseTo(1, 9);
    expect(verseProgress(P_END.mobile, true)).toBeCloseTo(1, 9);
    expect(verseProgress(99, false)).toBe(1);
  });
  test('depth is geometric between near and far and monotone in u', () => {
    for (const m of [false, true]) {
      const [zn, zf] = VERSE_Z[m ? 'mobile' : 'desktop'];
      expect(depthZ(0, m)).toBeCloseTo(zn, 9);
      expect(depthZ(1, m)).toBeCloseTo(zf, 9);
      let prev = 0;
      for (let u = 0; u <= 1; u += 0.05) { const z = depthZ(u, m); expect(z).toBeGreaterThan(prev); prev = z; }
    }
  });
  test('cards enter near the camera: u=0 is bigger than the reading plane and centred inside the stage', () => {
    for (const m of [false, true]) {
      const [zn] = VERSE_Z[m ? 'mobile' : 'desktop'];
      for (let i = 0; i < N; i++) {
        // pick p where card i has just begun (u ~ 0+)
        const k = m ? 'mobile' : 'desktop';
        const p = VERSE_START_P + (i * verseStep(N, VERSE_D[k]) + 1e-4) * VERSE_SPAN_P[k];
        const s = verseState(i, N, p, m);
        expect(s.u).toBeGreaterThan(0); expect(s.u).toBeLessThan(0.01);
        expect(s.z).toBeCloseTo(zn, 2);
        expect(s.scale).toBeCloseTo(1, 2);
        expect(s.xPct).toBeGreaterThan(5); expect(s.xPct).toBeLessThan(95);
        expect(s.yPct).toBeGreaterThan(5); expect(s.yPct).toBeLessThan(95);
      }
    }
    expect(VERSE_Z.desktop[0]).toBeLessThan(1);
  });
  test('scale monotonically decreases and position converges to the vanishing point as p grows', () => {
    for (const m of [false, true]) {
      for (let i = 0; i < N; i++) {
        let prevScale = Infinity; let prevDist = Infinity;
        sweep((p) => {
          const s = verseState(i, N, p, m);
          expect(s.scale).toBeLessThanOrEqual(prevScale + 1e-12); prevScale = s.scale;
          const d = Math.hypot(s.xPct - VERSE_VP.x, s.yPct - VERSE_VP.y);
          expect(d).toBeLessThanOrEqual(prevDist + 1e-9); prevDist = d;
        }, m);
      }
    }
  });
  test('opacity is exactly 0 at Z >= the gone-by depth and when not started; widgets hidden before and after the phase', () => {
    for (const m of [false, true]) {
      for (let i = 0; i < N; i++) {
        for (const p of [VERSE_START_P - 0.3, VERSE_START_P, P_END.desktop + 0.5, P_END.mobile + 0.5]) {
          const s = verseState(i, N, p, m);
          if (s.u === 0 || s.z >= VERSE_FADE_Z.op[1]) { expect(s.opacity).toBe(0); expect(s.visible).toBe(false); }
        }
        sweep((p) => {
          const s = verseState(i, N, p, m);
          if (s.z >= VERSE_FADE_Z.op[1]) { expect(s.opacity).toBe(0); expect(s.visible).toBe(false); }
          expect(s.opacity).toBeGreaterThanOrEqual(0); expect(s.opacity).toBeLessThanOrEqual(1);
        }, m);
      }
    }
    // the last card (full travel) is fully gone at the end of the phase
    expect(verseState(N - 1, N, P_END.desktop, false).visible).toBe(false);
  });
  test('blur grows with distance, 0 while near, within caps (9px desktop / 6px mobile), quantised to 0.5px', () => {
    for (const m of [false, true]) {
      const cap = m ? 6 : 9;
      let prev = -1;
      for (let u = 0; u <= 1.0001; u += 0.01) {
        const p = VERSE_START_P + Math.min(1, u * VERSE_D[m ? 'mobile' : 'desktop']) * VERSE_SPAN_P[m ? 'mobile' : 'desktop'];
        const s = verseState(0, N, p, m);
        expect(s.blur).toBeGreaterThanOrEqual(prev); prev = s.blur;
        expect(s.blur).toBeLessThanOrEqual(cap);
        expect((s.blur * 2) % 1).toBeCloseTo(0, 9);
        if (s.z <= VERSE_FADE_Z.blur[0]) expect(s.blur).toBe(0);
      }
      expect(prev).toBeGreaterThan(cap * 0.8);
    }
  });
  test('glass backdrop only while near on desktop, never on mobile; fill alpha steps up with distance', () => {
    let sawOn = false; let sawOff = false;
    sweep((p) => {
      const d = verseState(0, N, p, false); const mo = verseState(0, N, p, true);
      expect(d.backdrop).toBe(d.z <= VERSE_BF_Z); expect(mo.backdrop).toBe(false);
      if (d.backdrop) sawOn = true; else if (d.u > 0) sawOff = true;
      expect(mo.alpha).toBe(0.93);
    });
    expect(sawOn && sawOff).toBe(true);
    expect(verseState(0, N, VERSE_START_P + 1e-3, false).alpha).toBeCloseTo(0.72, 2);
    expect(verseState(0, N, VERSE_START_P + 0.6 * VERSE_SPAN_P.desktop, false).alpha).toBeCloseTo(0.86, 2);
  });
  test('cards run in order and only a few are visible at once', () => {
    let maxVisible = 0; let maxBlurred = 0;
    sweep((p) => {
      const vis = Array.from({ length: N }, (_, i) => verseState(i, N, p, false)).filter((s) => s.visible);
      maxVisible = Math.max(maxVisible, vis.length);
      maxBlurred = Math.max(maxBlurred, vis.filter((s) => s.blur > 0).length);
    });
    expect(maxVisible).toBeGreaterThanOrEqual(2);
    expect(maxVisible).toBeLessThanOrEqual(N); // the faint tail of card 1 can coexist with card 5
    expect(maxBlurred).toBeLessThanOrEqual(4); // perf ceiling from the design spec
    for (let i = 0; i < N - 1; i++) {
      const a = verseState(i, N, 1.9, false); const b = verseState(i + 1, N, 1.9, false);
      expect(a.u).toBeGreaterThanOrEqual(b.u);
    }
  });
  test('reverse scroll returns the identical state (pure function of p)', () => {
    const ps = [1.45, 1.6, 1.9, 2.3, 2.7, 1.9, 1.6, 1.45];
    const snap = (p) => JSON.stringify(Array.from({ length: N }, (_, i) => verseState(i, N, p, false)));
    const first = new Map();
    for (const p of ps) { const j = snap(p); if (first.has(p)) expect(j).toBe(first.get(p)); else first.set(p, j); }
  });
  test('layout tables cover every card and stay inside the stage', () => {
    for (const k of ['desktop', 'mobile']) {
      expect(VERSE_OFFSETS[k].ox.length).toBeGreaterThanOrEqual(N);
      expect(VERSE_OFFSETS[k].oy.length).toBeGreaterThanOrEqual(N);
    }
  });
  test('Family headline is gone before the first widget has receded noticeably', () => {
    const s = verseState(0, N, 1.46, false);
    expect(s.z).toBeLessThan(1.2);
  });
});

describe('every card goes through the same fade and blur ramp (pure function of depth)', () => {
  const N = 5;
  const K = (m) => (m ? 'mobile' : 'desktop');
  // p at which card i has own travel u
  const pAt = (i, u, m) => VERSE_START_P + (i * verseStep(N, VERSE_D[K(m)]) + u * VERSE_D[K(m)]) * VERSE_SPAN_P[K(m)];
  // depth where a predicate first holds, scanning the card's own travel finely
  const firstZ = (i, m, pred) => {
    for (let u = 0.001; u <= 1.0001; u += 0.001) { const s = verseState(i, N, pAt(i, u, m), m); if (pred(s)) return s.z; }
    return null;
  };
  test.each([[false], [true]])('mobile=%s: opacity and blur are identical at the same depth for every card index', (m) => {
    for (let u = 0.01; u <= 1; u += 0.01) {
      const ref = verseState(0, N, pAt(0, u, m), m);
      for (let i = 1; i < N; i++) {
        const s = verseState(i, N, pAt(i, u, m), m);
        expect(s.z).toBeCloseTo(ref.z, 9);
        expect(s.opacity).toBeCloseTo(ref.opacity, 9);
        expect(s.blur).toBe(ref.blur);
      }
    }
  });
  test.each([[false], [true]])('mobile=%s: per-card table, start of fade, start of blur and gone-by depth are the same for all cards', (m) => {
    const rows = Array.from({ length: N }, (_, i) => ({
      blurStart: firstZ(i, m, (s) => s.blur > 0),
      fadeStart: firstZ(i, m, (s) => s.u > 0.2 && s.opacity < 0.995),
      gone: firstZ(i, m, (s) => s.u > 0.2 && !s.visible),
    }));
    for (const r of rows) { expect(r.blurStart).not.toBeNull(); expect(r.fadeStart).not.toBeNull(); expect(r.gone).not.toBeNull(); }
    for (const key of ['blurStart', 'fadeStart', 'gone']) for (const r of rows) expect(r[key]).toBeCloseTo(rows[0][key], 6);
    // blur starts first, then the fade, then the card is gone, all strictly inside the card's travel
    const [zn, zf] = VERSE_Z[K(m)];
    expect(rows[0].blurStart).toBeLessThan(rows[0].fadeStart);
    expect(rows[0].fadeStart).toBeLessThan(rows[0].gone);
    expect(rows[0].gone).toBeLessThan(zf);
    expect(rows[0].blurStart).toBeGreaterThan(zn);
    // the pinned numbers: blur from just past the reading plane, fade from ~1.2, gone by 3.9
    expect(rows[0].blurStart).toBeLessThan(1.15);
    expect(rows[0].fadeStart).toBeGreaterThan(VERSE_FADE_Z.op[0]); expect(rows[0].fadeStart).toBeLessThan(1.5);
    expect(rows[0].gone).toBeGreaterThan(3.5); expect(rows[0].gone).toBeLessThanOrEqual(VERSE_FADE_Z.op[1]);
  });
  test.each([[false], [true]])('mobile=%s: the ramp is gradual, so a card is visibly soft for a long stretch of scroll before it is gone', (m) => {
    // scroll distance (in p) a card spends between "blur >= 1px" and "gone", and between "opacity < 0.9" and "gone"
    const span = (a, b) => (VERSE_SPAN_P[K(m)] * VERSE_D[K(m)]) * (b - a);
    let uBlur1 = null; let uFade = null; let uGone = null;
    for (let u = 0; u <= 1.0001; u += 0.001) {
      const s = verseState(2, N, pAt(2, u, m), m);
      if (uBlur1 === null && s.blur >= 1) uBlur1 = u;
      if (uFade === null && s.opacity < 0.9) uFade = u;
      if (uGone === null && !s.visible && u > 0.2) uGone = u;
    }
    expect(span(uBlur1, uGone)).toBeGreaterThan(0.6); // was about 0.15 before the slow-down
    expect(span(uFade, uGone)).toBeGreaterThan(0.5); // was about 0.12
    // opacity falls by at most 8% over any 0.02 p of scroll (no snap)
    let prev = null;
    for (let p = pAt(2, 0.15, m); p <= pAt(2, 1, m); p += 0.02) {
      const o = verseState(2, N, p, m).opacity;
      if (prev !== null) expect(Math.abs(o - prev)).toBeLessThan(0.08);
      prev = o;
    }
  });
  test('the last card is visible well into the runway and fully gone before the end of the scroll', () => {
    for (const m of [false, true]) {
      const last = N - 1;
      expect(verseState(last, N, P_END[K(m)] - 0.5, m).visible).toBe(true);
      expect(verseState(last, N, P_END[K(m)], m).visible).toBe(false);
      let firstGoneP = null;
      for (let p = P_END[K(m)] - 1; p <= P_END[K(m)]; p += 0.001) if (!verseState(last, N, p, m).visible) { firstGoneP = p; break; }
      expect(firstGoneP).toBeLessThan(P_END[K(m)] - 0.05);
    }
  });
});

describe('cursor spring maths', () => {
  const run = (w, seconds, hz, x0 = 0, target = 1) => {
    let x = x0; let v = 0; let max = x0; const dt = 1 / hz;
    for (let i = 0; i < Math.round(seconds * hz); i++) { [x, v] = springStep(x, v, target, w, dt); max = Math.max(max, x); }
    return { x, v, max };
  };
  const t63 = (w, hz) => {
    let x = 0; let v = 0; const dt = 1 / hz;
    for (let i = 1; i < 20 * hz; i++) { [x, v] = springStep(x, v, 1, w, dt); if (x >= 1 - Math.exp(-1)) return i * dt; }
    return Infinity;
  };
  test('springStep converges to the target without exploding', () => {
    for (const z of [0.72, 1.5, 4.2]) {
      const { x, v } = run(springOmega(z, false), 10, 60, 0, 10);
      expect(x).toBeCloseTo(10, 2); expect(Math.abs(v)).toBeLessThan(1e-2);
    }
  });
  test('no overshoot beyond tolerance, from rest and from a moving start', () => {
    for (const w of [PARALLAX.wFar, PARALLAX.wNear, PARALLAX.wFar * PARALLAX.returnScale]) {
      expect(run(w, 8, 60).max).toBeLessThanOrEqual(1 + 1e-9);
      let x = 0; let v = 0; let max = 0; // target jumps mid-flight, still bounded
      for (let i = 0; i < 480; i++) { [x, v] = springStep(x, v, i < 20 ? 1 : 0.5, w, 1 / 60); max = Math.max(max, x); }
      expect(max).toBeLessThanOrEqual(1 + 1e-9);
    }
  });
  test('time constants: near ~0.45 s, far ~0.65 s, all inside 0.4 to 0.7 s', () => {
    const near = SPRING_T63 / PARALLAX.wNear; const far = SPRING_T63 / PARALLAX.wFar;
    expect(near).toBeGreaterThanOrEqual(0.4); expect(far).toBeLessThanOrEqual(0.7); expect(near).toBeLessThan(far);
    expect(t63(PARALLAX.wNear, 240)).toBeCloseTo(near, 1);
    expect(t63(PARALLAX.wFar, 240)).toBeCloseTo(far, 1);
  });
  test('frame-rate independent: 30, 60 and 120 Hz agree to a hair', () => {
    for (const w of [PARALLAX.wNear, PARALLAX.wFar]) {
      const a = run(w, 0.5, 30).x; const b = run(w, 0.5, 60).x; const c = run(w, 0.5, 120).x;
      expect(Math.abs(a - b)).toBeLessThan(1e-9); expect(Math.abs(b - c)).toBeLessThan(1e-9);
    }
  });
  test('return to neutral is slower than the follow', () => {
    expect(PARALLAX.returnScale).toBeLessThan(0.75);
    for (const w of [PARALLAX.wNear, PARALLAX.wFar]) {
      expect(t63(w * PARALLAX.returnScale, 120)).toBeGreaterThan(t63(w, 120) * 1.4);
    }
  });
  test('large dt is safe (tab refocus does not blow up)', () => {
    const [x, v] = springStep(0, 0, 1, 2, 5);
    expect(Number.isFinite(x) && Number.isFinite(v)).toBe(true); expect(x).toBeLessThanOrEqual(1);
  });
  test('near cards are snappier than far cards and move more for the same pointer', () => {
    expect(springOmega(0.72, false)).toBeGreaterThan(springOmega(4.2, false));
    expect(springOmega(0.72, false)).toBeCloseTo(PARALLAX.wNear, 6);
    expect(springOmega(4.2, false)).toBeCloseTo(PARALLAX.wFar, 6);
    const [nx] = parallaxTarget(1, 0, 0.72); const [fx] = parallaxTarget(1, 0, 4.2);
    expect(Math.abs(nx)).toBeGreaterThan(Math.abs(fx));
    expect(parallaxTarget(0, 0, 1)).toEqual([0, 0]);
    expect(parallaxTarget(-1, 1, 2)).toEqual([-PARALLAX.amp / 2, PARALLAX.amp / 2]);
  });
});

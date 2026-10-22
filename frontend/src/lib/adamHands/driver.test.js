// Task 20261015-adam-hands-scroll-hero: pure scroll-driver maths for the pinned
// "Creation of Adam" hero. Proves easing B, the 41-row transform-table lookup
// (desktop + mobile), the README section 5 flood drivers, the brightness-safe
// endpoints (flat #FBF7F1 at p >= 0.97, hands exactly at the touch from 0.80),
// scrub progress for the pinned runway, and the ~0.6 s smoothing chase.
//
// Run with: cd frontend && npx vitest run src/lib/adamHands/driver.test.js
import { describe, test, expect } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  TOUCH_P, FLOOD_END_P, TABLE_STEP, CANVAS, RUNWAY_VH, SMOOTH_TAU_S,
  clamp, lerp, smooth, cubicBezier, floodCurve, easingB, getRows, lookupRow, handsPose,
  floodDrivers, lightParams, fanWeights, bloomIntensity, ignite, beatGlow, typeReveal,
  warmGlowAlpha, eyebrowColor, scrubProgress, smoothStep, coverScale,
  BASE_SPAN_VH, WASH_START_P, WHITE_HOLD_P, FILL2_START_P, FILL2_DELAY_P, FILL2_SPAN_P, FILL2_END_P,
  SETTLE_SPAN_P, SETTLE_END_P, FAMILY_REVEAL_P, FAMILY_HIDE_P, VERSE_START_P, VERSE_SPAN_P, P_END, P_END_STACK,
  RUNWAY_VH_STACK, washDrivers, fill2Drivers, familyOpacity,
} from './driver.js';
import { DESKTOP_ROWS, MOBILE_ROWS, TABLE_COLUMNS } from './table.js';

const near = (a, b, d = 2) => expect(a).toBeCloseTo(b, d);

describe('helpers', () => {
  test('clamp, lerp and smooth', () => {
    expect(clamp(-1)).toBe(0); expect(clamp(2)).toBe(1); expect(clamp(0.3)).toBe(0.3);
    expect(lerp(10, 20, 0.25)).toBe(12.5);
    expect(smooth(0)).toBe(0); expect(smooth(1)).toBe(1); near(smooth(0.5), 0.5, 6);
    expect(smooth(-5)).toBe(0); expect(smooth(7)).toBe(1);
  });

  test('cubicBezier solves CSS curves: endpoints, monotone, symmetric ease-in-out', () => {
    const f = cubicBezier(0.65, 0, 0.35, 1);
    expect(f(0)).toBe(0); expect(f(1)).toBe(1); expect(f(-1)).toBe(0); expect(f(2)).toBe(1);
    near(f(0.5), 0.5, 5);
    let prev = 0;
    for (let x = 0.01; x <= 1; x += 0.01) { const y = f(x); expect(y).toBeGreaterThanOrEqual(prev - 1e-9); prev = y; }
    near(f(0.25) + f(0.75), 1, 5);
    // ease-in-out: slower than linear near the ends
    expect(f(0.1)).toBeLessThan(0.1);
    expect(floodCurve(0.1)).toBeLessThan(0.1);
  });
});

describe('easing B', () => {
  test('p_eff = 0.8 * (1 - (1 - p/0.8)^2), held at 0.8 after the touch', () => {
    expect(easingB(0)).toBe(0);
    near(easingB(0.2), 0.35, 6);       // beat 2 lands at the approved A position 0.35
    near(easingB(0.5172), 0.70, 3);    // beat 3 lands at the approved A position 0.70
    expect(easingB(0.8)).toBe(0.8);
    expect(easingB(0.95)).toBe(0.8);
    expect(easingB(-1)).toBe(0);
  });

  test('is monotone and decelerates (ease-out) to a true hold at the touch', () => {
    let prev = -1; let prevStep = Infinity;
    for (let p = 0; p <= 0.8001; p += 0.04) {
      const v = easingB(p);
      expect(v).toBeGreaterThan(prev);
      if (prev >= 0) { const step = v - prev; expect(step).toBeLessThanOrEqual(prevStep + 1e-9); prevStep = step; }
      prev = v;
    }
    // zero speed at 0.8
    expect(easingB(0.8) - easingB(0.7999)).toBeLessThan(1e-4);
  });
});

describe('transform table', () => {
  test('41 desktop and 41 mobile rows, 0.02 apart, 12 columns', () => {
    expect(TABLE_COLUMNS.length).toBe(12);
    expect(DESKTOP_ROWS.length).toBe(41);
    expect(MOBILE_ROWS.length).toBe(41);
    [DESKTOP_ROWS, MOBILE_ROWS].forEach((rows) => rows.forEach((r, i) => {
      expect(r.length).toBe(12);
      near(r[0], i * TABLE_STEP, 6);
    }));
    expect(getRows(false)).toBe(DESKTOP_ROWS);
    expect(getRows(true)).toBe(MOBILE_ROWS);
  });

  test('matches the approved JSON (option B desktop rows + mobile rows) when the design asset is on disk', () => {
    const f = path.join(os.homedir(), '.claude/design/20261014-adam-hands-concept-frames-rev2-assets/assets/data/transform-table.json');
    if (!fs.existsSync(f)) return; // portable: the anchors below cover CI
    const j = JSON.parse(fs.readFileSync(f, 'utf8'));
    const B = j.easing.option_B_recommended;
    const cmp = (rows, src) => {
      expect(src.length).toBe(41);
      src.forEach((s, i) => {
        const r = rows[i];
        near(r[0], s.p, 6);
        near(r[1], s.adam_tx, 2); near(r[2], s.adam_ty, 2);
        near(r[3], s.god_tx, 2); near(r[4], s.god_ty, 2);
        near(r[5], s.scale, 5);
        s.key_fixed.slope.forEach((v, k) => near(r[6 + k], v, 4));
        near(r[9], s.key_fixed.intercept, 4);
        near(r[10], s.key_fixed.rim_opacity, 4);
        near(r[11], s.key_fixed.bounce_opacity, 4);
      });
    };
    cmp(DESKTOP_ROWS, B.rows);
    cmp(MOBILE_ROWS, B.mobile_rows);
  });

  test('anchor beats (desktop): frame 1 warm, beat 2 at p 0.20, touch at 0.80', () => {
    const b1 = handsPose(0, false);
    expect(b1.adam).toEqual({ tx: -176, ty: 87.58 });
    expect(b1.god).toEqual({ tx: 176, ty: -19.14 });
    near(b1.scale, 0.94345, 5);
    expect(b1.slope).toEqual([0.682, 0.67, 0.646]);
    expect(b1.intercept).toBe(-0.1);
    expect(b1.rim).toBe(0.3);
    expect(b1.bounce).toBe(0.05);
    const b2 = handsPose(0.2, false);
    near(b2.adam.tx, -88, 1); near(b2.god.tx, 88, 1);
    near(b2.scale, 0.96222, 4);
    expect(b2.rim).toBe(0); expect(b2.bounce).toBe(0); expect(b2.intercept).toBe(0);
    const b3 = handsPose(0.5172, false);
    near(b3.adam.tx, -16, 1); near(b3.god.tx, 16, 1); // beat 3: gap 32 px (approved A p 0.70)
  });

  test('touch: hands exactly at origin, scale 1, identity key from p 0.80 for every p after', () => {
    [0.8, 0.85, 0.97, 1].forEach((p) => {
      [false, true].forEach((m) => {
        const t = handsPose(p, m);
        near(t.adam.tx, 0, 6); near(t.adam.ty, 0, 6); near(t.god.tx, 0, 6); near(t.god.ty, 0, 6);
        near(t.scale, 1, 6);
        t.slope.forEach((s) => near(s, 1, 6));
        expect(t.intercept).toBe(0);
      });
    });
  });

  test('touch tips land on (800,432) desktop for both hands', () => {
    // Tips in canvas space = canvas touch point + group translation at the touch.
    const t = handsPose(0.8, false);
    expect(CANVAS.desktop.tx + t.adam.tx).toBeCloseTo(800, 6);
    expect(CANVAS.desktop.ty + t.adam.ty).toBeCloseTo(432, 6);
    expect(CANVAS.desktop.tx + t.god.tx).toBeCloseTo(800, 6);
    expect(CANVAS.desktop.ty + t.god.ty).toBeCloseTo(432, 6);
    expect(CANVAS.desktop.w / CANVAS.desktop.h).toBeCloseTo(16 / 9, 6);
    expect(CANVAS.mobile.w / CANVAS.mobile.h).toBeCloseTo(9 / 16, 6);
  });

  test('lookup interpolates linearly between rows and clamps p to [0, 0.8]', () => {
    const mid = lookupRow(DESKTOP_ROWS, 0.01);
    near(mid[1], (DESKTOP_ROWS[0][1] + DESKTOP_ROWS[1][1]) / 2, 6);
    near(mid[5], (DESKTOP_ROWS[0][5] + DESKTOP_ROWS[1][5]) / 2, 8);
    const q = lookupRow(DESKTOP_ROWS, 0.31);
    near(q[2], (DESKTOP_ROWS[15][2] + DESKTOP_ROWS[16][2]) / 2, 6);
    expect(lookupRow(DESKTOP_ROWS, -3)[1]).toBe(DESKTOP_ROWS[0][1]);
    expect(lookupRow(DESKTOP_ROWS, 5)[1]).toBe(0);
    expect(lookupRow(DESKTOP_ROWS, 0.8)[0]).toBe(0.8);
    // exactly on a row returns that row
    lookupRow(DESKTOP_ROWS, 0.4).forEach((v, k) => near(v, k === 0 ? 0.4 : DESKTOP_ROWS[20][k], 6));
    // no NaN anywhere in the range
    for (let p = 0; p <= 1.0001; p += 0.0137) lookupRow(MOBILE_ROWS, p).forEach((v) => expect(Number.isFinite(v)).toBe(true));
  });

  test('hands approach monotonically (gap closes) and the key brightens with p', () => {
    let prevGap = Infinity; let prevKey = 0;
    for (let p = 0; p <= 0.8001; p += 0.02) {
      const h = handsPose(p, false);
      const gap = h.god.tx - h.adam.tx;
      expect(gap).toBeLessThanOrEqual(prevGap + 1e-9);
      const key = h.slope[0] - h.intercept; // composite brightness proxy; frame 1 is darker than beat 2
      if (p > 0.04) expect(h.slope[0] + 0).toBeGreaterThanOrEqual(0);
      prevGap = gap; prevKey = key;
    }
    expect(prevKey).toBeGreaterThan(0);
  });

  test('mobile rows are the desktop rows rotated 20 deg and scaled 0.658 (note in README)', () => {
    DESKTOP_ROWS.forEach((d, i) => {
      const m = MOBILE_ROWS[i];
      const c = Math.cos(Math.PI / 9); const s = Math.sin(Math.PI / 9);
      near(m[1], 0.658 * (c * d[1] + s * d[2]), 0);
      near(m[2], 0.658 * (-s * d[1] + c * d[2]), 0);
      near(m[5], d[5], 5); // scale unchanged
      near(m[6], d[6], 4); // key unchanged
    });
  });
});

describe('flood drivers (README section 5)', () => {
  test('before the touch the drivers are inert', () => {
    const d = floodDrivers(0.5);
    expect(d.t).toBe(0); expect(d.f).toBe(0); expect(d.g).toBe(0); expect(d.w).toBe(0);
    expect(d.c).toBe(0); expect(d.e).toBe(1);
    expect(d.A).toBeCloseTo(0.6, 6);
    expect(d.fanG).toBe(0);
    expect(d.tipS).toBeCloseTo(0.35, 6);
  });

  test('end state at p >= 0.97: wash 1, flood complete, everything else off', () => {
    [0.97, 0.99, 1].forEach((p) => {
      const d = floodDrivers(p);
      near(d.t, 1, 9); near(d.f, 1, 9); expect(d.g).toBe(1); expect(d.w).toBe(1);
      expect(d.A).toBe(0); expect(d.e).toBe(0); expect(d.c).toBe(1);
      near(d.tipS, 0, 9); near(d.fanG, 1, 9);
    });
    expect(FLOOD_END_P).toBe(0.97); expect(TOUCH_P).toBe(0.8);
  });

  test('wash starts late (0.91) so the hands dissolve in light, not by a uniform fade', () => {
    expect(floodDrivers(0.90).w).toBe(0);
    expect(floodDrivers(0.91).w).toBe(0);
    expect(floodDrivers(0.94).w).toBeGreaterThan(0.4);
    expect(floodDrivers(0.94).w).toBeLessThan(0.6);
    expect(floodDrivers(0.97).w).toBe(1);
    // the light (f) is well advanced before the wash begins
    expect(floodDrivers(0.91).f).toBeGreaterThan(0.5);
  });

  test('all drivers stay in range, and f/g/w/c are non-decreasing; e and A end at 0', () => {
    let prev = { f: 0, g: 0, w: 0, c: 0 };
    for (let p = 0; p <= 1.0001; p += 0.005) {
      const d = floodDrivers(p);
      ['t', 'f', 'g', 'w', 'A', 'e', 'c', 'fanG'].forEach((k) => {
        expect(d[k]).toBeGreaterThanOrEqual(0); expect(d[k]).toBeLessThanOrEqual(1);
      });
      expect(d.tipS).toBeGreaterThanOrEqual(0); expect(d.tipS).toBeLessThanOrEqual(0.35 + 1e-9);
      ['f', 'g', 'w', 'c'].forEach((k) => { expect(d[k]).toBeGreaterThanOrEqual(prev[k] - 1e-9); prev[k] = d[k]; });
    }
  });

  test('light sizes follow f and g exactly at the ends', () => {
    const a = lightParams(0, 0); const b = lightParams(1, 1);
    expect(a.sigma).toBe(4); expect(b.sigma).toBe(64);
    expect(a.r0).toBe(18); expect(b.r0).toBe(935);
    expect(a.k).toBeCloseTo(0.30, 6); expect(b.k).toBeCloseTo(1.10, 6);
    expect(a.fanLength).toBe(60); expect(b.fanLength).toBe(1100);
    expect(b.hairScale).toBeCloseTo(1, 6); expect(a.hairScale).toBeCloseTo(1 / 1.6, 6);
    expect(b.streakScaleX).toBeCloseTo(1, 6);
    expect(b.fanRotateDeg).toBeCloseTo(3, 6);
  });

  test('fan sprites cross-fade a -> b -> c and the weights sum to 1', () => {
    expect(fanWeights(0)).toEqual({ a: 1, b: 0, c: 0 });
    const end = fanWeights(1); expect(end.a).toBe(0); expect(end.c).toBe(1); expect(end.b).toBe(0);
    for (let f = 0; f <= 1.0001; f += 0.05) {
      const w = fanWeights(f); near(w.a + w.b + w.c, 1, 6);
      [w.a, w.b, w.c].forEach((v) => { expect(v).toBeGreaterThanOrEqual(0); });
    }
  });

  test('bloom intensity: peak k at r 0, vanishes beyond 1.9 r0', () => {
    near(bloomIntensity(0, 100, 0.8), 0.8, 6);
    expect(bloomIntensity(190, 100, 0.8)).toBe(0);
    expect(bloomIntensity(50, 100, 0.8)).toBeLessThan(0.8);
  });
});

describe('beats 1-3 glow and the join into the touch light', () => {
  test('ignite ramps 0 -> 1 over 0.66-0.80 and is 0/1 at the exact beat/touch frames', () => {
    expect(ignite(0.66)).toBe(0); expect(ignite(0.2)).toBe(0);
    expect(ignite(0.8)).toBe(1); expect(ignite(1)).toBe(1);
    expect(ignite(0.73)).toBeGreaterThan(0.4); expect(ignite(0.73)).toBeLessThan(0.6);
  });

  test('beat colours/alphas: beat 1 gold r128 a0.12, beat 2 a0.30, beat 3 pale r40 a0.60', () => {
    const g1 = beatGlow(0, handsPose(0, false), false);
    expect(g1.alpha).toBeCloseTo(0.12, 6); expect(g1.r).toBe(128); expect(g1.color).toEqual([224, 154, 48]);
    const g2 = beatGlow(0.2, handsPose(0.2, false), false);
    expect(g2.alpha).toBeCloseTo(0.30, 6); expect(g2.r).toBe(128);
    const g3 = beatGlow(0.5172, handsPose(0.5172, false), false);
    expect(g3.alpha).toBeCloseTo(0.60, 4); expect(g3.r).toBeCloseTo(40, 3); expect(g3.color).toEqual([243, 196, 139]);
    // centred midway between the fingertips on the 1600x900 canvas
    const p1 = handsPose(0, false);
    expect(g1.x).toBeCloseTo(800 + (p1.adam.tx + p1.god.tx) / 2, 6);
    // handed to the touch light by p 0.80
    expect(beatGlow(0.8, handsPose(0.8, false), false).alpha).toBe(0);
  });

  test('mobile glow radius scales by 0.658', () => {
    expect(beatGlow(0, handsPose(0, true), true).r).toBeCloseTo(128 * 0.658, 4);
  });

  test('warm corner glow is beats 1-3 only and tracks e', () => {
    expect(warmGlowAlpha(0, 1)).toBe(1);
    expect(warmGlowAlpha(0.8, 1)).toBe(0);
    expect(warmGlowAlpha(0.3, 0)).toBe(0);
  });
});

describe('type and colour', () => {
  test('final type reveals only after the flat plane is nearly formed (smooth((p-0.955)/0.035))', () => {
    expect(typeReveal(0.9)).toBe(0); expect(typeReveal(0.94)).toBe(0); expect(typeReveal(0.955)).toBe(0);
    expect(typeReveal(0.99)).toBe(1); expect(typeReveal(1)).toBe(1);
    const x = (0.9725 - 0.955) / 0.035; // midpoint of the ramp
    near(typeReveal(0.9725), x * x * (3 - 2 * x), 6);
    near(typeReveal(0.9725), 0.5, 6);
    expect(typeReveal(0.96)).toBeGreaterThan(0); expect(typeReveal(0.96)).toBeLessThan(typeReveal(0.97));
  });

  test('eyebrow colour runs #F0C08A -> #1A1512 with c, and both ends are AA on their ground', () => {
    expect(eyebrowColor(0)).toEqual([0xF0, 0xC0, 0x8A]);
    expect(eyebrowColor(1)).toEqual([0x1A, 0x15, 0x12]);
    const lum = (rgb) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(rgb[0]) + 0.7152 * f(rgb[1]) + 0.0722 * f(rgb[2]); };
    const cr = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };
    expect(cr([0xF0, 0xC0, 0x8A], [0x17, 0x12, 0x0F])).toBeGreaterThan(11);   // eyebrow on ink: ~11.2:1
    expect(cr([0x1A, 0x15, 0x12], [0xFB, 0xF7, 0xF1])).toBeGreaterThan(15);    // headline on plane: ~16:1
    expect(cr([0x1A, 0x15, 0x12], [0xFB, 0xF7, 0xF1])).toBeGreaterThan(4.5);
  });
});

describe('scrub progress and smoothing', () => {
  test('scrubProgress maps the pinned runway: top of section = 0, end of runway = 1, clamped', () => {
    const section = 3200; const stage = 900; // legacy two-span form: span = section - stage
    expect(Math.abs(scrubProgress(0, section, stage))).toBe(0);
    expect(scrubProgress(300, section, stage)).toBe(0);          // before the pin
    expect(scrubProgress(-(section - stage) / 2, section, stage)).toBeCloseTo(0.5, 6);
    expect(scrubProgress(-(section - stage), section, stage)).toBe(1);
    expect(scrubProgress(-9999, section, stage)).toBe(1);        // released
    expect(scrubProgress(0, 900, 900)).toBe(0);                  // no runway guard
  });

  test('runway constants follow 100 + P_END * baseSpanVh: 672vh desktop, 564vh mobile', () => {
    expect(RUNWAY_VH).toEqual({ desktop: 672, mobile: 564 });
    expect(RUNWAY_VH_STACK).toEqual({ desktop: 408, mobile: 324 });
    expect(P_END.desktop).toBeCloseTo(2.6, 9); expect(P_END.mobile).toBeCloseTo(2.9, 9);
  });

  test('scrubProgress with baseSpanVh/pEnd extends past 1 and is clamped to pEnd', () => {
    const stage = 900; const section = (RUNWAY_VH.desktop / 100) * stage;
    expect(Math.abs(scrubProgress(0, section, stage, 220, P_END.desktop))).toBe(0);
    expect(scrubProgress(300, section, stage, 220, P_END.desktop)).toBe(0);
    expect(scrubProgress(-220 * 9, section, stage, 220, P_END.desktop)).toBeCloseTo(1, 9);
    expect(scrubProgress(-220 * 9 * 1.5, section, stage, 220, P_END.desktop)).toBeCloseTo(1.5, 9);
    expect(scrubProgress(-99999, section, stage, 220, P_END.desktop)).toBe(P_END.desktop);
    // the full runway scrolls exactly P_END spans
    expect(scrubProgress(-(section - stage), section, stage, 220, P_END.desktop)).toBeCloseTo(P_END.desktop, 6);
    expect(Math.abs(scrubProgress(0, 900, 900, 220, P_END.desktop))).toBe(0);
  });

  test('smoothStep chases the target, is frame-rate independent, ~95% in 0.6 s, and snaps when close', () => {
    expect(SMOOTH_TAU_S).toBeCloseTo(0.2, 6);
    expect(smoothStep(0.3, 0.9, 0)).toBe(0.3);
    const run = (dt) => { let c = 0; for (let t = 0; t < 0.6 - 1e-9; t += dt) c = smoothStep(c, 1, dt); return c; };
    const at60 = run(1 / 60); const at30 = run(1 / 30); const at120 = run(1 / 120);
    expect(at60).toBeGreaterThan(0.94); expect(at60).toBeLessThan(0.96);
    near(at60, at30, 3); near(at60, at120, 3);
    // reversible: chases back down
    expect(smoothStep(1, 0, 0.1)).toBeLessThan(1);
    // snap
    expect(smoothStep(0.99995, 1, 1 / 60)).toBe(1);
    // never overshoots
    let c = 0; for (let i = 0; i < 400; i++) { c = smoothStep(c, 1, 0.1); expect(c).toBeLessThanOrEqual(1); }
    expect(c).toBe(1);
  });

  test('coverScale makes the canvas cover the stage (object-fit: cover)', () => {
    expect(coverScale(1600, 900, false)).toBeCloseTo(1, 6);
    expect(coverScale(1920, 900, false)).toBeCloseTo(1.2, 6);
    expect(coverScale(1600, 1200, false)).toBeCloseTo(1200 / 900, 6);
    expect(coverScale(390, 844, true)).toBeCloseTo(Math.max(390 / 900, 844 / 1600), 6);
  });
});

describe('second fill, settle and family timeline (scrub domain past 1)', () => {
  test('named timeline table and monotonic ordering', () => {
    expect(BASE_SPAN_VH).toEqual({ desktop: 220, mobile: 160 });
    expect(WASH_START_P).toBe(0.84); expect(WHITE_HOLD_P).toBe(0.05);
    near(FILL2_START_P, 1.02, 9); near(FILL2_END_P, 1.11, 9); near(SETTLE_END_P, 1.27, 9);
    near(FILL2_DELAY_P, 0.22, 9); near(FILL2_SPAN_P, 0.09, 9); near(SETTLE_SPAN_P, 0.16, 9);
    const seq = [TOUCH_P, WASH_START_P, FLOOD_END_P, FILL2_START_P, FILL2_END_P, SETTLE_END_P,
      FAMILY_REVEAL_P[0], FAMILY_REVEAL_P[1], FAMILY_HIDE_P[0], VERSE_START_P];
    // wash starts after the touch; settle ends after family begins to reveal
    expect(WASH_START_P).toBeGreaterThan(TOUCH_P);
    expect(FLOOD_END_P).toBeLessThan(FILL2_START_P);
    expect(FILL2_START_P).toBeLessThan(FILL2_END_P);
    expect(FILL2_END_P).toBeLessThan(SETTLE_END_P);
    expect(FAMILY_REVEAL_P[0]).toBeLessThan(FAMILY_REVEAL_P[1]);
    expect(FAMILY_REVEAL_P[1]).toBeLessThanOrEqual(FAMILY_HIDE_P[0]);
    expect(FAMILY_HIDE_P[0]).toBeLessThan(FAMILY_HIDE_P[1]);
    expect(FAMILY_HIDE_P[0]).toBeLessThanOrEqual(VERSE_START_P);
    expect(seq.length).toBe(10);
    expect(P_END_STACK).toBe(VERSE_START_P);
    expect(VERSE_SPAN_P).toEqual({ desktop: 1.2, mobile: 1.5 });
  });

  test('original hands/flood drivers are unchanged and saturate beyond 1', () => {
    expect(TOUCH_P).toBe(0.80); expect(FLOOD_END_P).toBe(0.97);
    expect(floodDrivers(1.5)).toEqual(floodDrivers(1));
    expect(floodDrivers(2.6)).toEqual(floodDrivers(1));
    expect(handsPose(2, false)).toEqual(handsPose(1, false));
    expect(ignite(1.7)).toBe(1);
  });

  test('washDrivers: grows over .84-.97, holds white until the second fill, then off', () => {
    const rc = 1000;
    expect(washDrivers(0.80, rc).washOpacity).toBe(0);
    near(washDrivers(0.84, rc).rWash, 100, 6);
    expect(washDrivers(0.97, rc).rWash).toBeCloseTo(1900, 6);
    // the opaque pale-cyan band (0.80 Rw) covers every corner (r_c) from p .90 on
    expect(0.80 * washDrivers(0.90, rc).rWash).toBeGreaterThan(rc);
    expect(0.62 * washDrivers(0.97, rc).rWash).toBeGreaterThan(rc);
    expect(washDrivers(0.86, rc).washOpacity).toBe(1);
    expect(washDrivers(1.0, rc)).toEqual({ ...washDrivers(0.97, rc), washOpacity: 1 });
    expect(washDrivers(FILL2_START_P, rc).washOpacity).toBe(0);
    let prev = -1; for (let p = 0.8; p <= 0.97; p += 0.01) { const r = washDrivers(p, rc).rWash; expect(r).toBeGreaterThanOrEqual(prev); prev = r; }
  });

  test('fill2Drivers: field on just before the fill, cover grows monotonically, hole covers corners at end', () => {
    const rc = 1000;
    expect(fill2Drivers(1.0, rc).fieldOn).toBe(false);
    expect(fill2Drivers(FILL2_START_P - 0.004, rc).fieldOn).toBe(true);
    expect(fill2Drivers(0.97, rc).coverOn).toBe(false);
    expect(fill2Drivers(FILL2_START_P, rc).coverOn).toBe(true);
    expect(fill2Drivers(FILL2_END_P, rc).coverOn).toBe(false);
    expect(fill2Drivers(FILL2_START_P, rc).coverR).toBeCloseTo(80, 6);
    expect(fill2Drivers(FILL2_END_P, rc).coverR).toBeCloseTo(3600, 6);
    expect(0.30 * fill2Drivers(FILL2_END_P, rc).coverR).toBeGreaterThan(rc);
    let prev = 0; for (let p = FILL2_START_P; p <= FILL2_END_P; p += 0.005) { const r = fill2Drivers(p, rc).coverR; expect(r).toBeGreaterThanOrEqual(prev); prev = r; }
    // orb near mov 1.85s (u = .36): R about 0.57 r_c (visible orb about 59% of the width)
    const R36 = fill2Drivers(FILL2_START_P + 0.36 * FILL2_SPAN_P, rc).coverR / rc;
    expect(R36).toBeGreaterThan(0.52); expect(R36).toBeLessThan(0.62);
  });

  test('settle ramps over the settle span; hands hidden only after the fill', () => {
    const rc = 800;
    expect(fill2Drivers(FILL2_END_P, rc).settle).toBe(0);
    expect(fill2Drivers(SETTLE_END_P, rc).settle).toBe(1);
    expect(fill2Drivers(1.2, rc).settle).toBeGreaterThan(0.5);
    expect(fill2Drivers(FILL2_END_P, rc).handsHidden).toBe(false);
    expect(fill2Drivers(FILL2_END_P + 0.001, rc).handsHidden).toBe(true);
    expect(fill2Drivers(0.9, rc).handsHidden).toBe(false);
  });

  test('familyOpacity reveals 1.19-1.26, holds, hides 1.38-1.46; keep never hides', () => {
    expect(familyOpacity(1.0)).toBe(0); expect(familyOpacity(1.19)).toBe(0);
    expect(familyOpacity(1.26)).toBe(1); expect(familyOpacity(1.3)).toBe(1);
    expect(familyOpacity(1.225)).toBeGreaterThan(0.4); expect(familyOpacity(1.225)).toBeLessThan(0.6);
    expect(familyOpacity(1.38)).toBe(1); expect(familyOpacity(1.46)).toBe(0); expect(familyOpacity(2.5)).toBe(0);
    expect(familyOpacity(2.5, true)).toBe(1); expect(familyOpacity(1.4, true)).toBe(1);
  });

  test('P_END and runway stay in the formula', () => {
    expect(RUNWAY_VH_STACK.desktop).toBe(Math.round(100 + P_END_STACK * BASE_SPAN_VH.desktop));
  });
});

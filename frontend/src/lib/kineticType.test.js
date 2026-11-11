// Task 20261111-kinetic-type-marble, testing gate: the pure scroll maths of the kinetic .hm-fam head.
// Every expected number is derived by hand from the constants in lib/kineticType.js and lib/adamHands/driver.js:
//   units = eyebrow + ten words = 11; Q_START .04; Q_END .74; DUR .30; STAGGER = (.74 - .04 - .30) / 10 = .04.
//
// Run with: cd frontend && npx vitest run src/lib/kineticType.test.js
import { describe, test, expect } from 'vitest';
import {
  KINETIC_UNITS, Q_START, Q_END, DUR, STAGGER, CIRCLE_Q, SCRIM_Q, SCRIM_START_Q, settleEase, unitStart, unitEnd, unitT, unitE,
  unitStyle, unitCss, circleP, sceneProgress, scrimOpacity,
} from './kineticType.js';
import { P_END, TYPE_START_P, BASE_SPAN_VH, KINETIC_SPAN_VH, RUNWAY_VH, smooth } from './adamHands/driver.js';

const near = (a, b, d = 9) => expect(a).toBeCloseTo(b, d);
const UNITS = Array.from({ length: KINETIC_UNITS }, (_, i) => i);

describe('timeline constants', () => {
  test('11 units, 0.04 stagger, the last unit lands exactly at Q_END', () => {
    expect(KINETIC_UNITS).toBe(11);
    near(Q_START, 0.04); near(Q_END, 0.74); near(DUR, 0.30);
    near(STAGGER, 0.04);
    near(unitStart(0), 0.04); near(unitEnd(0), 0.34);
    near(unitStart(10), 0.44); near(unitEnd(10), Q_END);
    for (let i = 1; i < KINETIC_UNITS; i++) near(unitStart(i) - unitStart(i - 1), STAGGER);
  });
  test('the stagger is real: neighbouring units overlap in time (DUR > STAGGER) but never finish out of order', () => {
    expect(DUR).toBeGreaterThan(STAGGER);
    for (let i = 1; i < KINETIC_UNITS; i++) expect(unitEnd(i)).toBeGreaterThan(unitEnd(i - 1));
  });
  test('there is a hold between the last landing and the unpin (Q_END < 1) and a lead-in before the first start', () => {
    expect(Q_END).toBeLessThan(1); expect(Q_START).toBeGreaterThan(0);
  });
});

describe('per-unit progress: unitT / unitE', () => {
  test('t is 0 before the unit starts, 1 after it ends, linear in between', () => {
    for (const i of UNITS) {
      expect(unitT(i, unitStart(i) - 0.001)).toBe(0);
      expect(unitT(i, unitStart(i))).toBe(0);
      near(unitT(i, unitEnd(i)), 1); // (q - start) / DUR floats to 0.9999999999999998 at the exact end
      expect(unitT(i, unitEnd(i) + 0.5)).toBe(1);
      near(unitT(i, unitStart(i) + DUR / 2), 0.5);
    }
  });
  test('e is monotone non-decreasing in q, runs 0 -> 1, and is an ease-out (never linear): e(t = 0.5) > 0.5', () => {
    expect(settleEase(0)).toBe(0); near(settleEase(1), 1, 6);
    expect(settleEase(0.5)).toBeGreaterThan(0.5);
    expect(settleEase(0.25)).toBeGreaterThan(0.25);
    for (const i of UNITS) {
      let prev = -1;
      for (let q = 0; q <= 1.0001; q += 0.005) { const e = unitE(i, q); expect(e).toBeGreaterThanOrEqual(prev - 1e-12); prev = e; }
      near(unitE(i, unitStart(i) + DUR / 2), settleEase(0.5), 9);
    }
  });
});

describe('unitStyle (full power)', () => {
  test('q = 0: every unit is fully hidden', () => {
    for (const i of UNITS) expect(unitStyle(i, 0).opacity).toBe(0);
  });
  test('q >= Q_END: every unit is at its final static pose (opacity 1, no offset, scale 1, no blur, no glow)', () => {
    for (const i of UNITS) for (const q of [Q_END, 0.9, 1]) {
      const s = unitStyle(i, q);
      expect(s.opacity).toBe(1);
      near(s.x, 0, 9); near(s.y, 0, 6); near(s.scale, 1, 6); near(s.blur, 0, 6); near(s.glow, 0, 9);
    }
  });
  test('start pose of a word: y 0.55em down, x 0.18em (alternating side), scale .96, blur 14px, full glow; the eyebrow has no x, scale, blur or glow', () => {
    const w1 = unitStyle(1, 0); const w2 = unitStyle(2, 0);
    near(w1.y, 0.55); near(w1.x, -0.18); near(w2.x, 0.18); near(w1.scale, 0.96); near(w1.blur, 14); near(w1.glow, 1);
    const eb = unitStyle(0, 0);
    near(eb.y, 0.55); expect(eb.x).toBe(0); expect(eb.scale).toBe(1); expect(eb.blur).toBe(0); expect(eb.glow).toBe(0);
  });
  test('opacity leads the travel: opacity is smooth(t / 0.45), so it is 1 once 45% of the unit has run', () => {
    const i = 4; const q = unitStart(i) + 0.45 * DUR;
    near(unitStyle(i, q).opacity, 1, 9);
    near(unitStyle(i, unitStart(i) + 0.225 * DUR).opacity, smooth(0.5), 9);
    expect(unitStyle(i, q).y).toBeGreaterThan(0.01); // ...while it is still travelling
  });
  test('opacity and travel are monotone in q for every unit (reversible, no overshoot)', () => {
    for (const i of UNITS) {
      let po = -1; let py = Infinity;
      for (let q = 0; q <= 1; q += 0.005) {
        const s = unitStyle(i, q);
        expect(s.opacity).toBeGreaterThanOrEqual(po - 1e-12); expect(s.y).toBeLessThanOrEqual(py + 1e-12);
        expect(s.opacity).toBeLessThanOrEqual(1); expect(s.y).toBeGreaterThanOrEqual(0);
        po = s.opacity; py = s.y;
      }
    }
  });
  test('pure function of q: the same q gives the same style on the way back (scroll is reversible)', () => {
    for (const q of [0.1, 0.37, 0.6]) expect(unitStyle(5, q)).toEqual(unitStyle(5, q));
  });
});

describe('unitStyle / unitCss (low power: opacity + translateY only)', () => {
  test('low power never produces x, scale, blur or glow, with the same opacity and y as full power', () => {
    for (const i of UNITS) for (let q = 0; q <= 1; q += 0.05) {
      const lo = unitStyle(i, q, true); const hi = unitStyle(i, q, false);
      expect(lo.x).toBe(0); expect(lo.scale).toBe(1); expect(lo.blur).toBe(0); expect(lo.glow).toBe(0);
      expect(lo.opacity).toBe(hi.opacity); expect(lo.y).toBe(hi.y);
    }
  });
  test('low power CSS: no filter, no text-shadow, transform is translateY only, at every q', () => {
    for (const i of UNITS) for (let q = 0; q <= 1; q += 0.02) {
      const c = unitCss(i, q, true);
      expect(c.filter).toBe('none'); expect(c.textShadow).toBe('none');
      expect(c.transform === 'none' || /^translateY\(-?[\d.]+em\)$/.test(c.transform)).toBe(true);
    }
  });
});

describe('unitCss (full power)', () => {
  test('before the start: opacity "0"; after the end: opacity "1.000" with transform/filter/text-shadow all "none" (a resting word carries no filter cost)', () => {
    for (const i of UNITS) {
      expect(unitCss(i, 0).opacity).toBe('0');
      const f = unitCss(i, 1);
      expect(f).toEqual({ opacity: '1.000', transform: 'none', filter: 'none', textShadow: 'none' });
    }
  });
  test('while travelling: blur and glow are emitted for words, never for the eyebrow', () => {
    const q = unitStart(3) + DUR * 0.2;
    const c = unitCss(3, q);
    expect(c.filter).toMatch(/^blur\([\d.]+px\)$/);
    expect(c.textShadow).toMatch(/^0 0 [\d.]+px rgba\(255,226,170,[\d.]+\)$/);
    expect(c.transform).toMatch(/^translate\(-?[\d.]+em, [\d.]+em\) scale\([\d.]+\)$/);
    const e = unitCss(0, unitStart(0) + DUR * 0.2);
    expect(e.filter).toBe('none'); expect(e.textShadow).toBe('none');
  });
  test('words arrive in reading order: at any mid q an earlier word is at least as far along as a later one', () => {
    for (let q = 0.05; q < 0.74; q += 0.03) for (let i = 1; i < KINETIC_UNITS; i++) {
      expect(unitE(i - 1, q)).toBeGreaterThanOrEqual(unitE(i, q) - 1e-12);
    }
  });
});

describe('circle around "family": circleP', () => {
  test('0 until q = 0.68, 1 from q = 0.88, eased and monotone between', () => {
    near(CIRCLE_Q[0], 0.68); near(CIRCLE_Q[1], 0.88);
    expect(circleP(0)).toBe(0); expect(circleP(0.68)).toBe(0); expect(circleP(0.88)).toBe(1); expect(circleP(1)).toBe(1);
    let prev = 0;
    for (let q = 0.68; q <= 0.88; q += 0.005) { const c = circleP(q); expect(c).toBeGreaterThanOrEqual(prev - 1e-12); prev = c; }
    near(circleP(0.78), 0.5, 6); // the in-out curve is symmetric
  });
  test('the circle only starts once the word "family" (unit 10) is opaque, and it ends after the last word lands', () => {
    // unit 10 reaches opacity 1 at unitStart(10) + 0.45 * DUR = 0.575 < 0.68; it lands at Q_END = 0.74 < 0.88
    expect(unitStart(10) + 0.45 * DUR).toBeLessThan(CIRCLE_Q[0]);
    expect(CIRCLE_Q[1]).toBeGreaterThan(Q_END);
    expect(CIRCLE_Q[1]).toBeLessThan(1);
  });
});

describe('sceneProgress(rectTop, rectHeight, headHeight)', () => {
  test('0 before the head pins, 1 when it unpins, linear between, clamped outside', () => {
    const H = 2700; const vh = 900; // scene = (100 + KINETIC_SPAN_VH 200) vh = 300vh on a 900px viewport
    expect(sceneProgress(500, H, vh)).toBe(0);
    expect(Math.abs(sceneProgress(0, H, vh))).toBe(0); // -0 is fine
    near(sceneProgress(-900, H, vh), 0.5);
    expect(sceneProgress(-(H - vh), H, vh)).toBe(1);
    expect(sceneProgress(-99999, H, vh)).toBe(1);
  });
  test('no scrollable span (scene no taller than the head) gives 0, not NaN', () => {
    expect(sceneProgress(-50, 900, 900)).toBe(0);
    expect(sceneProgress(-50, 0, 0)).toBe(0);
  });
  test('is identical to (p - TYPE_START_P) / (P_END - TYPE_START_P) of the hero scrub in the pinned region (one formula, desktop and mobile)', () => {
    for (const x of ['desktop', 'mobile']) {
      const base = BASE_SPAN_VH[x];
      const runway = 100 + P_END[x] * base; // unrounded runway in vh
      const sceneTop = runway - (100 + KINETIC_SPAN_VH); // scene starts here, measured from the pin top, in vh
      for (const S of [sceneTop - 20, sceneTop, sceneTop + 40, sceneTop + 100, sceneTop + 160, sceneTop + KINETIC_SPAN_VH, sceneTop + 260]) {
        const p = Math.min(P_END[x], Math.max(0, S / base));
        const viaP = Math.min(1, Math.max(0, (p - TYPE_START_P) / (P_END[x] - TYPE_START_P)));
        const viaRect = sceneProgress(sceneTop - S, 100 + KINETIC_SPAN_VH, 100);
        near(viaRect, viaP, 6); // TYPE_START_P and P_END are rounded to 6 decimals in driver.js (r6), so 1e-6 is the exact tolerance
      }
      // the integer-rounded runway (RUNWAY_VH) shifts the head by under half a vh: at most 0.0025 of q
      expect(Math.abs(RUNWAY_VH[x] - runway) / KINETIC_SPAN_VH).toBeLessThan(0.0025);
    }
  });
});

describe('scrimOpacity (dark backstop only once the head is pinned)', () => {
  test('0 until the light has left the text zone (q <= SCRIM_START_Q, else the scrim greys the white hold), 1 by SCRIM_START_Q + SCRIM_Q, smooth and monotone', () => {
    near(SCRIM_Q, 0.08); near(SCRIM_START_Q, 0.07);
    expect(scrimOpacity(0)).toBe(0); expect(scrimOpacity(-1)).toBe(0); expect(scrimOpacity(SCRIM_START_Q)).toBe(0);
    expect(scrimOpacity(SCRIM_START_Q + SCRIM_Q)).toBe(1); expect(scrimOpacity(1)).toBe(1);
    let prev = 0;
    for (let q = 0; q <= 0.2; q += 0.002) { const o = scrimOpacity(q); expect(o).toBeGreaterThanOrEqual(prev - 1e-12); prev = o; }
  });
});

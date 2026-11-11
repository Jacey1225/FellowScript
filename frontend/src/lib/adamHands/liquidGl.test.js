import { describe, test, expect, vi } from 'vitest';
import {
  liquidRamp, liquidZone, internalSize, flowDelta, fragmentSource, createLiquidGl,
  LIQUID_I_ZONE_MAX, RIBBON_SOFTNESS, RIBBON_SOFT_REF, ribbonCompensation, RIBBON_LINE_W, LIQUID_RES, LIQUID_RAMP, LIQUID_SCROLL,
  RIBBON_SCALE, ribbonUvScale, ribbonFlow, LIQUID_SCALE, LIQUID_FLOW,
} from './liquidGl.js';
import { FIELD_ZONE_MAX, hexRgb, relLuminance, LIGHT_BG, LEAK_HONEY } from './field.js';

const lumOf = (rgb01) => relLuminance(rgb01.map((v) => v * 255));

describe('liquid shader config (warm ribbon field)', () => {
  test('ramp is warm: red >= green >= blue at every intensity', () => {
    for (let I = 0; I <= 1.0001; I += 0.05) { const [r, g, b] = liquidRamp(I); expect(r).toBeGreaterThanOrEqual(g - 1e-9); expect(g).toBeGreaterThanOrEqual(b - 1e-9); }
    expect(liquidRamp(0)).toEqual(hexRgb(LIQUID_RAMP[0].c).map((v) => v / 255));
  });
  test('zone luminance cap: ribbon at I_ZONE_MAX is no lighter than FIELD_ZONE_MAX (text stays legible)', () => {
    expect(lumOf(liquidRamp(LIQUID_I_ZONE_MAX))).toBeLessThanOrEqual(relLuminance(hexRgb(FIELD_ZONE_MAX)) + 1e-9);
  });
  test('zone rectangle is a valid sub-rect of uv space for both layouts', () => {
    for (const m of [false, true]) { const [x0, x1, y0, y1] = liquidZone(m); expect(x0).toBeLessThan(x1); expect(y0).toBeLessThan(y1); [x0, x1, y0, y1].forEach((v) => { expect(v).toBeGreaterThanOrEqual(0); expect(v).toBeLessThanOrEqual(1); }); }
  });
  test('internal resolution is low and capped, DPR never raises it', () => {
    const [w, h] = internalSize(1920, 1080, false, 3);
    expect(w).toBeLessThanOrEqual(LIQUID_RES.desktop.maxW); expect(h).toBeLessThanOrEqual(LIQUID_RES.desktop.maxH);
    expect(internalSize(1920, 1080, false, 3)).toEqual(internalSize(1920, 1080, false, 1));
    const [mw, mh] = internalSize(390, 844, true, 3);
    expect(mw).toBeLessThanOrEqual(LIQUID_RES.mobile.maxW); expect(mh).toBeLessThanOrEqual(LIQUID_RES.mobile.maxH);
    expect(mw * mh).toBeLessThan(390 * 844 * 0.2);
    expect(LIQUID_RES.mobile.fps).toBe(30);
    expect(internalSize(0, 0, false)[0]).toBeGreaterThanOrEqual(2);
  });
  test('flow speed boost from scroll is capped at 2.5x and dt is clamped', () => {
    expect(flowDelta(1 / 60, 0)).toBeCloseTo(1 / 60, 9);
    expect(flowDelta(1 / 60, 1e9)).toBeCloseTo((1 / 60) * (1 + LIQUID_SCROLL.maxBoost), 9);
    expect(1 + LIQUID_SCROLL.maxBoost).toBe(2.5);
    expect(flowDelta(10, 0)).toBeCloseTo(1 / 20, 9);
    expect(flowDelta(1 / 60, -3000)).toBe(flowDelta(1 / 60, 3000));
  });
  test('fragment source builds for both configs, differs in octaves, and stays WebGL1', () => {
    const d = fragmentSource(LIQUID_RES.desktop); const m = fragmentSource(LIQUID_RES.mobile);
    for (const src of [d, m]) { expect(src).toContain('void main'); expect(src).toContain('gl_FragColor'); expect(src).not.toMatch(/#version\s+300/); expect(src).not.toMatch(/NaN/); }
    expect(d).not.toBe(m); expect(d.length).toBeGreaterThan(m.length - 1);
  });
  test('RIBBON_SOFTNESS knob softens the bands: widens the falloff, original at 1.0, same peak', () => {
    expect(RIBBON_SOFTNESS).toBeGreaterThan(1);
    const base = fragmentSource({ ...LIQUID_RES.desktop, softness: 1 });
    const soft = fragmentSource(LIQUID_RES.desktop);
    expect(base).toContain('#define RIBBON_SOFTNESS 1.000'); expect(base).toContain(`pow(d / ${RIBBON_LINE_W.toFixed(4)}, 2.0)`);
    expect(soft).toContain(`#define RIBBON_SOFTNESS ${RIBBON_SOFTNESS.toFixed(3)}`);
    expect(soft).toContain(`pow(d / ${(RIBBON_LINE_W * RIBBON_SOFTNESS).toFixed(4)}, 2.0)`);
    expect(soft).toContain(`* ${Math.pow(RIBBON_SOFTNESS, -0.4).toFixed(4)} +`); expect(base).toContain('* 1.0000 +');
    expect(base).toContain('(prof * 1.0000 + 0.0000) * env'); // no compensation at or below the reference
    expect(soft).toContain('0.0, 1.0);'); // peak and cap path untouched (I still clamped, then zone-capped)
    expect(fragmentSource(LIQUID_RES.mobile)).toContain('#define RIBBON_SOFTNESS');
  });
  test('ribbonCompensation restores the gap level and peak of the 2.4 look as softness grows', () => {
    expect(RIBBON_SOFTNESS).toBe(7.2);
    expect(ribbonCompensation(1)).toEqual({ gain: 1, offset: 0 });
    expect(ribbonCompensation(RIBBON_SOFT_REF)).toEqual({ gain: 1, offset: 0 });
    const prof = (d, S) => Math.pow(S, -0.4) * Math.exp(-((d / (RIBBON_LINE_W * S)) ** 2)) + 0.22 * Math.exp(-((d / (0.55 * Math.sqrt(S))) ** 2));
    let prevGain = 1;
    for (const S of [3, 4.8, 7.2, 10]) {
      const c = ribbonCompensation(S);
      expect(c.gain).toBeGreaterThan(prevGain); prevGain = c.gain; // more softness, more contrast stretch
      expect(prof(1, S) * c.gain + c.offset).toBeCloseTo(prof(1, RIBBON_SOFT_REF), 6); // gaps as dark as the 2.4 look
      expect(prof(0, S) * c.gain + c.offset).toBeCloseTo(prof(0, RIBBON_SOFT_REF), 6); // peak as bright as the 2.4 look (zone cap still applies in the shader)
      expect(fragmentSource({ ...LIQUID_RES.desktop, softness: S })).toContain(`(prof * ${c.gain.toFixed(4)} + ${c.offset.toFixed(4)}) * env`);
    }
  });
  test('RIBBON_SCALE knob: bigger waves, same apparent flow speed, identical shader math at 1.0', () => {
    expect(RIBBON_SCALE).toBe(2);
    const one = fragmentSource({ ...LIQUID_RES.desktop, scale: 1 });
    expect(one).toContain('* 1.35;'); expect(one).toContain('uTime * 0.045;'); expect(one).toContain('#define RIBBON_SCALE 1.000');
    const two = fragmentSource(LIQUID_RES.desktop);
    expect(two).toContain('* 0.675;'); expect(two).toContain('uTime * 0.0225;'); expect(two).toContain(`#define RIBBON_SCALE ${RIBBON_SCALE.toFixed(3)}`);
    // everything else (bands, compensation, zone cap, palette) is byte-identical apart from the three scale lines
    const strip = (src) => src.split('\n').filter((l) => !/RIBBON_SCALE|\* [0-9.]+;$|uTime \*/.test(l)).join('\n');
    expect(strip(two)).toBe(strip(one));
    expect(fragmentSource({ ...LIQUID_RES.mobile, scale: 3 })).toContain('* 0.45;');
  });
  test('speed correction: screen px/s of feature motion is independent of RIBBON_SCALE', () => {
    // noise units per screen height = ribbonUvScale; noise drift per second = ribbonFlow (x fixed octave factor). px/s ~ drift / uvScale.
    for (const s of [1, 1.5, 2, 3, 4]) expect(ribbonFlow(s) / ribbonUvScale(s)).toBeCloseTo(LIQUID_FLOW / LIQUID_SCALE, 12);
    expect(ribbonUvScale(1)).toBe(LIQUID_SCALE); expect(ribbonFlow(1)).toBe(LIQUID_FLOW);
    expect(ribbonUvScale(2)).toBeCloseTo(LIQUID_SCALE / 2, 12); // fold size is 2x on screen
  });
  test('createLiquidGl returns null without WebGL (jsdom / no canvas) so the CSS blobs remain', () => {
    expect(createLiquidGl(null)).toBeNull();
    expect(createLiquidGl(document.createElement('canvas'))).toBeNull();
  });
});

// Task 20261111-kinetic-type-marble, testing gate: the hand-off (uH) and the resolve-to-cream block of the marble shader.
// GLSL cannot run in jsdom, so the maths is checked by parsing the constants out of the generated source and mirroring the
// formulas in JS; the real-GPU look was verified by the frontend gate in Chrome (swiftshader).
const smoothstep = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
const cfgs = [['desktop oct 4 / warp2', LIQUID_RES.desktop], ['mobile oct 3', LIQUID_RES.mobile]];

describe('hand-off uniform uH and the iso-contour veil', () => {
  test.each(cfgs)('%s: declares uH, gates the hand-off block on it, and compiles-shaped (balanced braces, one main, no WebGL2 syntax)', (_n, cfg) => {
    const src = fragmentSource(cfg);
    expect(src).toContain('uniform float uH;');
    expect(src).toContain('if (uH < 0.999) {');
    expect(src.split('void main').length).toBe(2);
    expect((src.match(/\{/g) || []).length).toBe((src.match(/\}/g) || []).length);
    expect((src.match(/\(/g) || []).length).toBe((src.match(/\)/g) || []).length);
    expect(src).not.toMatch(/#version|\bin vec|\bout vec|texture\(/);
    expect(src).toContain(`#define OCT ${cfg.oct}`);
  });
  test('desktop and mobile share the same hand-off and resolve code (only octaves / warp differ)', () => {
    const block = (src) => src.slice(src.indexOf('if (uH < 0.999)'));
    expect(block(fragmentSource(LIQUID_RES.desktop))).toBe(block(fragmentSource(LIQUID_RES.mobile)));
  });
  test('the light leaves by a spatial iso-contour of a key field: veil = smoothstep(T - w, T + w, key), never an opacity ramp on the layer', () => {
    const src = fragmentSource(LIQUID_RES.desktop);
    expect(src).toMatch(/float veil = smoothstep\(T - vw, T \+ vw, key\);/); // vw = the edge softness, see the width test below
    expect(src).toMatch(/float key = Lf \+ 0\.80 \* \(0\.5 \* \(q\.x \+ q\.y\) - 0\.5\) \+ 0\.12 \* \(fc - 0\.5\) \+ 0\.12 \* I;/); // radial falloff, coarse warp q, folds f, ribbon intensity I
    expect(src).toContain('(1.0 - rr)'); // radial falloff
    expect(src).not.toMatch(/float key = [^;]*ray/); // no spokes in the key: the contour is smooth, no spiky blob
    expect(src).toMatch(/rim = 4\.0 \* veil \* \(1\.0 - veil\)/); // gold rim only on the contour
    // uH is only ever read to move the threshold T (and the warp bend), never multiplied into the output alpha
    expect(src).not.toMatch(/gl_FragColor\s*=[^;]*uH/);
    expect(src).not.toMatch(/\bal\s*\*=\s*[^;]*uH|\brgb\s*\*=\s*[^;]*uH/);
  });
  // JS mirror of the shader's threshold sweep T(h) and veil edge half-width vw(h) (polish pass 20261111).
  // T = -0.40 + 0.70 ss(0, .03, h) + .22 lin(.03, .12) + .13 lin(.12, .24) + .215 lin(.24, .50) + .205 lin(.50, .70) + .33 lin(.70, .85) + 1.33 ss(.85, 1, h).
  // The rates were fitted from measured frames (mean luminance per 0.005 of scroll progress) so the white leaves at an even pace:
  // a fast first 3% crosses the empty band where no key is low enough to show anything yet, then 0.8 to 2.4 per unit of h through the body,
  // and an eased tail that carries the white core out slowly (the core used to vanish inside 20 px of scroll).
  const lin = (a, b, h) => Math.min(1, Math.max(0, (h - a) / (b - a)));
  const Tof = (h) => -0.40 + 0.70 * smoothstep(0, 0.03, h) + 0.22 * lin(0.03, 0.12, h) + 0.13 * lin(0.12, 0.24, h) + 0.215 * lin(0.24, 0.50, h)
    + 0.205 * lin(0.50, 0.70, h) + 0.33 * lin(0.70, 0.85, h) + 1.33 * smoothstep(0.85, 1.0, h);
  const vwOf = (h) => 0.20 + 0.45 * smoothstep(0.55, 1.0, h);
  test('threshold sweep T(h): the shader text carries the same terms as the JS mirror; T(0) = -0.40, T(1) = 2.73, monotone, no step bigger than the eased rates allow', () => {
    const src = fragmentSource(LIQUID_RES.desktop);
    expect(src).toContain('float T = -0.40 + 0.70 * smoothstep(0.0, 0.03, uH) + 0.22 * clamp((uH - 0.03) / 0.09, 0.0, 1.0) + 0.13 * clamp((uH - 0.12) / 0.12, 0.0, 1.0)');
    expect(src).toContain('+ 0.215 * clamp((uH - 0.24) / 0.26, 0.0, 1.0) + 0.205 * clamp((uH - 0.50) / 0.20, 0.0, 1.0) + 0.33 * clamp((uH - 0.70) / 0.15, 0.0, 1.0)');
    expect(src).toContain('+ 1.33 * smoothstep(0.85, 1.0, uH);');
    expect(src).toContain('float vw = 0.20 + 0.45 * smoothstep(0.55, 1.0, uH);');
    expect(Tof(0)).toBeCloseTo(-0.40, 9);
    expect(Tof(1)).toBeCloseTo(2.73, 9); // -0.40 + 0.70 + 0.22 + 0.13 + 0.215 + 0.205 + 0.33 + 1.33
    let prev = Tof(0); let maxStep = 0;
    for (let h = 0.005; h <= 1.0001; h += 0.005) { const t = Tof(h); expect(t).toBeGreaterThanOrEqual(prev); if (h > 0.035) maxStep = Math.max(maxStep, t - prev); prev = t; }
    // 0.005 of h is about 0.001 of scroll progress p: the steepest part is the eased tail (peak about 1.5 * 1.33 / 0.15 = 13 per unit h)
    expect(maxStep).toBeLessThan(13.5 * 0.005 + 1e-9);
    // The fast first 3% (peak 35 per unit h, about 19 px of scroll) only crosses the band where no key is low enough to show a pixel change.
    // After it the body never moves faster than 2.4 per unit h (the old design pushed 0.70 of T through the first 4%, which popped the frame border).
    for (let h = 0.04; h <= 0.60; h += 0.005) expect(Tof(h + 0.005) - Tof(h)).toBeLessThan(2.5 * 0.005);
    expect(Tof(0.03)).toBeCloseTo(0.30, 9);
    expect(vwOf(0)).toBeCloseTo(0.20, 9); expect(vwOf(1)).toBeCloseTo(0.65, 9);
  });
  test('threshold range: every key sits above T(0) + w at h = 0 (all veil, so the first GL frame is the lens frame) and below T(1) - w at h = 1 (no veil)', () => {
    // Hand-derived bounds of key. Lf = 1.15 - rr + 0.35 (1 - rr)^2, rr in [0, 1]; q.x, q.y, fc, I in [0, 1]:
    // key = Lf + 0.80 (0.5 (qx + qy) - 0.5) + 0.12 (fc - 0.5) + 0.12 I.
    let kMin = Infinity; let kMax = -Infinity;
    for (let rr = 0; rr <= 1.0001; rr += 0.01) for (const qm of [0, 1]) for (const fc of [0, 1]) for (const I of [0, 1]) {
      const key = 1.15 - rr + 0.35 * (1 - rr) ** 2 + 0.80 * (qm - 0.5) + 0.12 * (fc - 0.5) + 0.12 * I;
      kMin = Math.min(kMin, key); kMax = Math.max(kMax, key);
    }
    // fbm of the warp stays in about 0.15 .. 0.85 in practice (measured keys: about -0.17 .. 1.95); the mathematically
    // extreme q = 0 / 1 corners are looser than that, so test the realistic q range 0.15 .. 0.85 for the guarantees.
    let rMin = Infinity; let rMax = -Infinity;
    for (let rr = 0; rr <= 1.0001; rr += 0.01) for (const qm of [0.15, 0.85]) for (const fc of [0, 1]) for (const I of [0, 1]) {
      const key = 1.15 - rr + 0.35 * (1 - rr) ** 2 + 0.80 * (qm - 0.5) + 0.12 * (fc - 0.5) + 0.12 * I;
      rMin = Math.min(rMin, key); rMax = Math.max(rMax, key);
    }
    expect(kMin).toBeLessThan(rMin); expect(kMax).toBeGreaterThan(rMax);
    expect(smoothstep(Tof(0) - vwOf(0), Tof(0) + vwOf(0), rMin)).toBe(1);
    expect(smoothstep(Tof(1) - vwOf(1), Tof(1) + vwOf(1), rMax)).toBe(0);
    // in between the contour sweeps through: high-key pixels are still lit while low-key ones are already bare marble
    const mid = Tof(0.5); const w = vwOf(0.5);
    expect(smoothstep(mid - w, mid + w, rMax)).toBeGreaterThan(0.9);
    expect(smoothstep(mid - w, mid + w, rMin)).toBeLessThan(0.1);
  });
  test('the light survives on fold crests and bright ribbons: key rises with f, I and the warp q at fixed radius (spatial structure, not a flat fade)', () => {
    const key = (rr, qm, fc, I) => 1.15 - rr + 0.35 * (1 - rr) ** 2 + 0.80 * (qm - 0.5) + 0.12 * (fc - 0.5) + 0.12 * I;
    expect(key(0.5, 0.5, 0.9, 0.2)).toBeGreaterThan(key(0.5, 0.5, 0.1, 0.2));
    expect(key(0.5, 0.5, 0.5, 0.9)).toBeGreaterThan(key(0.5, 0.5, 0.5, 0.1));
    expect(key(0.5, 0.7, 0.5, 0.2)).toBeGreaterThan(key(0.5, 0.3, 0.5, 0.2));
    expect(key(0.2, 0.5, 0.5, 0.2)).toBeGreaterThan(key(0.8, 0.5, 0.5, 0.2)); // centre stays lit longest
  });
  test('veil colour IS the lens frame at h = 0, not a flat fill: honey edge (#F6D496) rising to pure white by the radial lens fit, rays only landscape, rim gold', () => {
    const src = fragmentSource(LIQUID_RES.desktop);
    expect(src).toContain('vec3 lcol = mix(vec3(0.9647,0.8314,0.5882), vec3(1.0), sh);');
    expect(src).toContain('exp(-pow(max(rc - 0.12, 0.0) / 0.45, 1.5))'); // radial fit to the measured lens ring means
    expect(src).toContain('smoothstep(0.9, 1.0, ax)'); // the lens has no spokes on portrait / mobile
    expect(src).toContain('lcol += vec3(0.8784,0.6039,0.1882) * rim * 0.30;');
    const sh = (rc) => Math.exp(-((Math.max(rc - 0.12, 0) / 0.45) ** 1.5));
    expect(sh(0)).toBe(1); expect(sh(0.12)).toBe(1);
    expect(sh(0.3)).toBeGreaterThan(0.7); expect(sh(0.3)).toBeLessThan(0.85); // lens ring mean at rc .3 is about s .76
    expect(sh(0.6)).toBeLessThan(0.4); expect(sh(1)).toBeLessThan(0.1); // the corners are honey, not cream
  });
  test('the resolve to cream is gated by the veil only at h = 0 (the lens frame owns the stage edge), then forms uniformly under it as h grows', () => {
    const src = fragmentSource(LIQUID_RES.desktop);
    expect(src).toContain('float vl = 0.0;');
    expect(src).toContain('vl = veil;');
    expect(src).toContain('* (1.0 - vl * (1.0 - smoothstep(0.03, 0.30, uH)));');
    // gate(h): 1 - vl (1 - ss(.03, .3, h)): at h = 0 it is 1 - vl (pixel-equal to the lens frame while veil = 1), and for h >= 0.30 it is exactly 1
    const gate = (vl, h) => 1 - vl * (1 - smoothstep(0.03, 0.30, h));
    expect(gate(1, 0)).toBe(0); expect(gate(0, 0)).toBe(1);
    expect(gate(1, 0.30)).toBe(1); expect(gate(0.7, 0.5)).toBe(1);
    for (let h = 0; h < 0.3; h += 0.01) expect(gate(1, h + 0.01)).toBeGreaterThanOrEqual(gate(1, h) - 1e-12);
  });
});

describe('resolve to cream: no honey strip', () => {
  const src = fragmentSource(LIQUID_RES.desktop);
  const cream = `vec3(${hexRgb(LIGHT_BG).map((v) => (v / 255).toFixed(4)).join(',')})`;
  test('the stage bottom mixes to the LIGHT_BG token (#FBF7F1) with alpha 1, and no honey / #EBC480 colour exists in the shader', () => {
    expect(LIGHT_BG).toBe('#FBF7F1');
    expect(cream).toBe('vec3(0.9843,0.9686,0.9451)');
    expect(src).toContain(`rgb = mix(rgb, ${cream}, m);`);
    expect(src).toContain('al = mix(al, 1.0, m);');
    expect(src).not.toContain('0.9216,0.7686,0.5020'); // LEAK_HONEY / #EBC480
    expect(LEAK_HONEY).toBe('#EBC480');
  });
  test('the cream band is a smooth gradient of the stage row (no dependence on the fine ribbon intensity I, which made the top edge ragged): exactly 1 for the last 3%, exactly 0 above the band, monotone', () => {
    expect(src).toContain('float qm = 0.5 * (q.x + q.y);');
    expect(src).toContain('float rz = smoothstep(0.80 + 0.07 * (0.5 - qm), 0.985, yb);');
    expect(src).toContain('float m = clamp(rz * rz * (3.0 - 2.0 * rz) + smoothstep(0.96, 0.985, yb), 0.0, 1.0) * (1.0 - vl * (1.0 - smoothstep(0.03, 0.30, uH)));');
    // I must not appear in the resolve expression any more
    const line = src.split('\n').find((l) => l.includes('float m = clamp('));
    expect(line).not.toMatch(/\bI\b/);
    const m = (yb, qm) => Math.min(1, Math.max(0, (() => { const r = smoothstep(0.80 + 0.07 * (0.5 - qm), 0.985, yb); return r * r * (3 - 2 * r); })() + smoothstep(0.96, 0.985, yb)));
    for (const qm of [0.15, 0.5, 0.85]) {
      expect(m(0.985, qm)).toBe(1); expect(m(1, qm)).toBe(1); expect(m(0.5, qm)).toBe(0); expect(m(0.72, qm)).toBe(0);
      let prev = 0; for (let yb = 0.7; yb <= 1; yb += 0.0025) { const v = m(yb, qm); expect(v).toBeGreaterThanOrEqual(prev - 1e-12); prev = v; }
    }
    // the edge position only moves by the coarse warp: +-0.0245 of the stage height between the extreme qm values, never a per-pixel wobble
    expect(0.07 * (0.5 - 0.15)).toBeCloseTo(0.0245, 6);
    // smoothness: the largest step between neighbouring rows (0.1% of height) stays small, so no ragged or stepped edge
    let maxStep = 0; for (let yb = 0.78; yb <= 1; yb += 0.001) maxStep = Math.max(maxStep, m(yb + 0.001, 0.5) - m(yb, 0.5));
    expect(maxStep).toBeLessThan(0.06);
  });
});

describe('createLiquidGl passes the hand-off h to the shader each draw', () => {
  function fakeGl() {
    const calls = [];
    const gl = new Proxy({ calls }, {
      get(t, k) {
        if (k in t) return t[k];
        if (k === 'getShaderParameter' || k === 'getProgramParameter') return () => true;
        if (k === 'isContextLost') return () => false;
        if (k === 'getUniformLocation') return (_p, name) => ({ name });
        if (k === 'getExtension') return () => null;
        if (/^[A-Z_0-9]+$/.test(String(k))) return 1;
        return (...a) => { calls.push([String(k), ...a]); return {}; };
      },
    });
    return gl;
  }
  test('draw(t, h) writes uTime then uH; h defaults to 0 (pure white veil); shader compiled from fragmentSource', () => {
    const gl = fakeGl();
    const canvas = document.createElement('canvas');
    canvas.getContext = () => gl;
    const ua = vi.spyOn(navigator, 'userAgent', 'get').mockReturnValue('Mozilla/5.0 test-browser');
    const api = createLiquidGl(canvas, { mobile: false });
    ua.mockRestore();
    expect(api).toBeTruthy();
    const src = gl.calls.filter((c) => c[0] === 'shaderSource').map((c) => c[2]);
    expect(src.some((x) => x === fragmentSource(LIQUID_RES.desktop))).toBe(true);
    api.resize(1000, 600, 1);
    gl.calls.length = 0;
    api.draw(37, 0.25);
    const u = gl.calls.filter((c) => c[0] === 'uniform1f').map((c) => [c[1].name, c[2]]);
    expect(u).toEqual([['uTime', 37], ['uH', 0.25]]);
    gl.calls.length = 0;
    api.draw(37);
    expect(gl.calls.filter((c) => c[0] === 'uniform1f').map((c) => [c[1].name, c[2]])).toEqual([['uTime', 37], ['uH', 0]]);
    api.destroy();
  });
  test('mobile config compiles the 3-octave, single-warp variant', () => {
    const gl = fakeGl(); const canvas = document.createElement('canvas'); canvas.getContext = () => gl;
    const ua = vi.spyOn(navigator, 'userAgent', 'get').mockReturnValue('Mozilla/5.0 test-browser');
    const api = createLiquidGl(canvas, { mobile: true }); ua.mockRestore();
    expect(api).toBeTruthy();
    const src = gl.calls.filter((c) => c[0] === 'shaderSource').map((c) => c[2]);
    expect(src.some((x) => x.includes('#define OCT 3') && x.includes('vec2 r = q;'))).toBe(true);
    api.destroy();
  });
});

import { describe, test, expect } from 'vitest';
import {
  liquidRamp, liquidZone, internalSize, flowDelta, fragmentSource, createLiquidGl,
  LIQUID_I_ZONE_MAX, RIBBON_SOFTNESS, RIBBON_SOFT_REF, ribbonCompensation, RIBBON_LINE_W, LIQUID_RES, LIQUID_RAMP, LIQUID_SCROLL,
  RIBBON_SCALE, ribbonUvScale, ribbonFlow, LIQUID_SCALE, LIQUID_FLOW,
} from './liquidGl.js';
import { FIELD_ZONE_MAX, hexRgb, relLuminance } from './field.js';

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

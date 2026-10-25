// Layout helpers added in loop 1: edge clamping and occlusion dimming.
import { describe, test, expect } from 'vitest';
import { PARALLAX } from '../lib/verseDescent.js';
import { clampCentre, occlusionFactor, entryFactor, VERSE_EDGE_MARGIN, VERSE_OCC, VERSE_OCC_SOFT, paintVerses, createVerseRig } from './VerseDescent.jsx';

describe('clampCentre', () => {
  const W = 1440;
  test('leaves a centred card alone', () => {
    expect(clampCentre(720, 600, W)).toBe(720);
  });
  test('keeps a card off the right edge by the margin', () => {
    const c = clampCentre(1300, 778, W);
    expect(c + 778 / 2).toBeLessThanOrEqual(W - VERSE_EDGE_MARGIN + 1e-9);
    expect(c).toBe(W - VERSE_EDGE_MARGIN - 389);
  });
  test('keeps a card off the left edge by the margin', () => {
    const c = clampCentre(100, 778, W);
    expect(c - 389).toBeGreaterThanOrEqual(VERSE_EDGE_MARGIN - 1e-9);
    expect(c).toBe(VERSE_EDGE_MARGIN + 389);
  });
  test('card wider than the usable area centres on the stage', () => {
    expect(clampCentre(10, 400, 430)).toBe(215);
    expect(clampCentre(10, 390, 390)).toBe(195);
  });
  test('honours a custom margin and never moves a card that already fits', () => {
    expect(clampCentre(50, 100, 400, 0)).toBe(50);
    expect(clampCentre(10, 100, 400, 0)).toBe(50);
  });
  test('is idempotent', () => {
    const once = clampCentre(1500, 700, W);
    expect(clampCentre(once, 700, W)).toBe(once);
  });
});

describe('occlusionFactor', () => {
  const rect = [0, 0, 100, 100];
  test('no nearer cards means full opacity', () => {
    expect(occlusionFactor(rect, [])).toBe(1);
  });
  test('non-overlapping nearer card means full opacity', () => {
    expect(occlusionFactor(rect, [[200, 200, 300, 300, 1]])).toBe(1);
  });
  test('zero-area rect returns 1', () => {
    expect(occlusionFactor([0, 0, 0, 0], [[0, 0, 10, 10, 1]])).toBe(1);
  });
  test('sliver below the start threshold does not dim', () => {
    // 0.2% covered < VERSE_OCC.from (0.4%)
    expect(occlusionFactor(rect, [[0, 99.8, 100, 200, 1]])).toBe(1);
  });
  test('covered cards vanish entirely (no floor) once the cover passes the soft range', () => {
    expect(VERSE_OCC.keep).toBe(0);
    expect(VERSE_OCC_SOFT.keep).toBe(0);
    expect(occlusionFactor(rect, [[0, 70, 100, 200, 1]])).toBe(0); // 30% covered
  });
  test('light cover dims gradually instead of snapping the card off', () => {
    const f = [2, 5, 10, 15, 20].map((h) => occlusionFactor(rect, [[0, 100 - h, 100, 200, 1]]));
    for (let i = 1; i < f.length; i++) expect(f[i]).toBeLessThan(f[i - 1]);
    expect(f[0]).toBeGreaterThan(0.9); // 2% corner overlap: barely touched
    expect(f[2]).toBeGreaterThan(0.2); // 10%: still partly there
    expect(f[2]).toBeLessThan(0.8);
  });
  test('fully covered by an opaque card drops to the keep floor', () => {
    expect(occlusionFactor(rect, [[-10, -10, 110, 110, 1]])).toBeCloseTo(VERSE_OCC.keep, 10);
  });
  test('partial cover beyond the end threshold also hits the floor', () => {
    // 30% covered > VERSE_OCC_SOFT.to
    expect(occlusionFactor(rect, [[0, 70, 100, 200, 1]])).toBeCloseTo(VERSE_OCC.keep, 10);
  });
  test('monotone: more coverage never raises opacity', () => {
    let prev = 2;
    for (let h = 0; h <= 100; h += 5) {
      const f = occlusionFactor(rect, [[0, 100 - h, 100, 200, 1]]);
      expect(f).toBeLessThanOrEqual(prev + 1e-12);
      expect(f).toBeGreaterThanOrEqual(VERSE_OCC.keep - 1e-12);
      expect(f).toBeLessThanOrEqual(1);
      prev = f;
    }
  });
  test('a faded (transparent) nearer card covers proportionally less', () => {
    const opaque = occlusionFactor(rect, [[-10, -10, 110, 110, 1]]);
    const faint = occlusionFactor(rect, [[-10, -10, 110, 110, 0.03]]);
    expect(faint).toBeGreaterThan(opaque);
    expect(occlusionFactor(rect, [[-10, -10, 110, 110, 0]])).toBe(1);
  });
});

describe('entryFactor', () => {
  const rect = [0, 0, 100, 100];
  const far = [[0, 50, 100, 200, 1]];
  test('no farther cards or fully opaque: untouched', () => {
    expect(entryFactor(rect, 0.2, [])).toBe(1);
    expect(entryFactor(rect, 1, far)).toBe(1);
  });
  test('a faint card overlapping a solid farther card is hidden', () => {
    expect(entryFactor(rect, 0.17, far)).toBeCloseTo(0, 10);
  });
  test('a faint card that clears the farther card is untouched', () => {
    expect(entryFactor(rect, 0.17, [[0, 150, 100, 250, 1]])).toBe(1);
  });
  test('nearly opaque card takes over', () => {
    expect(entryFactor(rect, 0.95, far)).toBeGreaterThan(0.8);
  });
});

describe('paintVerses occlusion and z-order', () => {
  const mk = (w, h) => {
    const el = document.createElement('div');
    Object.defineProperty(el, 'offsetWidth', { value: w });
    Object.defineProperty(el, 'offsetHeight', { value: h });
    return el;
  };
  test('a nearer card that is still faint does not ghost over a solid farther card (mobile)', () => {
    // pure helper at the layout level: farther card solid, nearer card entering at low opacity
    const rect = [0, 0, 360, 215];
    expect(entryFactor(rect, 0.17, [[0, 20, 360, 235, 1]])).toBeCloseTo(0, 10);
  });
  test('mobile hand-over: the front card is already soft and half gone when the next arrives, so nothing ghosts', () => {
    const els = [0, 1, 2, 3, 4].map(() => mk(360, 215));
    paintVerses(els, 2.1, true, 390, 844);
    expect(Number(els[0].style.opacity)).toBeLessThan(0.5);
    expect(els[0].style.filter).toMatch(/blur\(/);
    expect(Number(els[1].style.opacity)).toBeLessThan(0.6);
    expect(Number(els[2].style.opacity)).toBe(0);
  });
  test('a card behind and overlapped by a nearer solid card is fully hidden', () => {
    const els = [0, 1, 2, 3, 4].map(() => mk(360, 215));
    paintVerses(els, 2.4, true, 390, 844);
    expect(Number(els[1].style.opacity)).toBeGreaterThan(0.8);
    expect(Number(els[0].style.opacity)).toBeLessThan(0.02);
  });
  test('no ghosting at any scroll position: opacity-weighted overlap under a nearer card stays tiny', () => {
    const rectOf = (el) => {
      const m = /translate3d\(([-\d.]+)px, ([-\d.]+)px.*scale\(([\d.]+)\)/.exec(el.style.transform);
      const [x, y, sc] = [Number(m[1]), Number(m[2]), Number(m[3])];
      return [x - (el.w * sc) / 2, y - (el.h * sc) / 2, x + (el.w * sc) / 2, y + (el.h * sc) / 2];
    };
    for (const [mobile, W, H, w, h, end] of [[true, 390, 844, 360, 215, 5], [false, 1440, 900, 778, 300, 4]]) {
      for (let p = 1.4; p <= end; p += 0.02) {
        const els = [0, 1, 2, 3, 4].map(() => { const e = mk(w, h); e.w = w; e.h = h; return e; });
        paintVerses(els, p, mobile, W, H);
        for (let j = 0; j < 5; j++) {
          const oj = Number(els[j].style.opacity);
          if (oj <= 0.02 || !els[j].style.transform) continue;
          const a = rectOf(els[j]);
          for (let k = j + 1; k < 5; k++) {
            if (Number(els[k].style.opacity) <= 0.02 || !els[k].style.transform) continue;
            const b = rectOf(els[k]);
            const ow = Math.min(a[2], b[2]) - Math.max(a[0], b[0]); const oh = Math.min(a[3], b[3]) - Math.max(a[1], b[1]);
            if (ow <= 0 || oh <= 0) continue;
            const ok = Number(els[k].style.opacity);
            const fracFar = (ow * oh) / ((a[2] - a[0]) * (a[3] - a[1])); // share of the farther card that sits under the nearer one
            const fracNear = (ow * oh) / ((b[2] - b[0]) * (b[3] - b[1])); // share of the nearer card over the farther one
            expect(oj * fracFar * ok).toBeLessThan(0.1); // farther text showing through a solid nearer card
            expect(ok * fracNear * oj).toBeLessThan(0.1); // faint nearer text ghosting over a solid farther card
          }
        }
      }
    }
  });
  test('z-index follows list order so nearer cards are strictly above', () => {
    const els = [0, 1, 2, 3, 4].map(() => mk(360, 215));
    paintVerses(els, 2.4, true, 390, 844);
    const z = els.filter((e) => e.style.zIndex !== '').map((e) => Number(e.style.zIndex));
    expect(z.length).toBeGreaterThanOrEqual(2);
    expect(z.every((v, i) => i === 0 || v > z[i - 1])).toBe(true);
  });
});

describe('paintVerses keeps cards inside the stage', () => {
  const mk = (w, h) => {
    const el = document.createElement('div');
    Object.defineProperty(el, 'offsetWidth', { value: w });
    Object.defineProperty(el, 'offsetHeight', { value: h });
    return el;
  };
  test('at every near-range scroll position the scaled card stays within the margin (desktop)', () => {
    const W = 1440; const H = 900;
    for (let p = 1.4; p <= 2.0; p += 0.05) {
      const els = [mk(778, 300), mk(778, 300), mk(778, 300), mk(778, 300)];
      paintVerses(els, p, false, W, H);
      for (const el of els) {
        if (el.style.visibility !== 'visible') continue;
        const m = /translate3d\(([-\d.]+)px, ([-\d.]+)px.*scale\(([\d.]+)\)/.exec(el.style.transform);
        const [x, y, sc] = [Number(m[1]), Number(m[2]), Number(m[3])];
        expect(x - (778 * sc) / 2).toBeGreaterThanOrEqual(VERSE_EDGE_MARGIN - 0.1);
        expect(x + (778 * sc) / 2).toBeLessThanOrEqual(W - VERSE_EDGE_MARGIN + 0.1);
        expect(y - (300 * sc) / 2).toBeGreaterThanOrEqual(VERSE_EDGE_MARGIN - 0.1);
        expect(y + (300 * sc) / 2).toBeLessThanOrEqual(H - VERSE_EDGE_MARGIN + 0.1);
      }
    }
  });
});

describe('createVerseRig cursor follow', () => {
  const settle = (rig, secs, hz) => { for (let i = 0; i < secs * hz; i++) rig.step(1 / hz); };
  test('follows without overshoot and returns slower than it follows', () => {
    const rig = createVerseRig(false); rig.z = [1.0];
    rig.pointer(1, 0);
    const target = PARALLAX.amp / 1.0; let max = 0; let tFollow = 0;
    for (let i = 1; i <= 600; i++) { rig.step(1 / 120); max = Math.max(max, rig.x[0]); if (!tFollow && rig.x[0] >= target * 0.632) tFollow = i / 120; }
    expect(max).toBeLessThanOrEqual(target + 1e-6);
    rig.pointer(null, null);
    let tBack = 0;
    for (let i = 1; i <= 1200; i++) { rig.step(1 / 120); expect(rig.x[0]).toBeGreaterThanOrEqual(-1e-6); if (!tBack && rig.x[0] <= target * 0.368) tBack = i / 120; }
    expect(tFollow).toBeGreaterThan(0.35);
    expect(tBack).toBeGreaterThan(tFollow * 1.4);
  });
  test('same lag at 30 and 120 Hz and sleeps when settled', () => {
    const a = createVerseRig(false); const b = createVerseRig(false); a.z = [1.5]; b.z = [1.5];
    a.pointer(0.5, -0.5); b.pointer(0.5, -0.5);
    settle(a, 0.6, 30); settle(b, 0.6, 120);
    expect(Math.abs(a.x[0] - b.x[0])).toBeLessThan(1e-6); expect(Math.abs(a.y[0] - b.y[0])).toBeLessThan(1e-6);
    let active = true; for (let i = 0; i < 2400 && active; i++) active = a.step(1 / 120);
    expect(active).toBe(false);
  });
});

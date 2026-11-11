// Task 20261015-adam-hands-scroll-hero: fallback rendering of the pinned Adam
// section. The server/prerender markup (and the first client render, so there
// is no hydration mismatch) must be the fallback only: touch-frame still + live
// eyebrow + 24svh gradient, data-live="false", no pinned runway, no live layer
// stack, no JS-dependent hidden state. Also checks the scrub wiring: the
// component paints a frame from the section rect on scroll and cleans up.
//
// Run with: cd frontend && npx vitest run src/components/AdamHands.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, cleanup, act } from '@testing-library/react';
import { renderToString, renderToStaticMarkup } from 'react-dom/server';
import { LENS_CSS, LOBE_GRAD } from './LensBloom.jsx';
import { LENS_LOBES, P_END, P_END_STACK, HANDOFF_START_P, HANDOFF_END_P, handoffH, RUNWAY_VH, RUNWAY_VH_STACK, floodCurve } from '../lib/adamHands/driver.js';
import LiquidField, { LIQUID_CSS } from './LiquidField.jsx';
import AdamHands, { ADAM_CSS, ADAM_EYEBROW, ADAM_KEY_FILTER_ID, FIELD_INK, LIGHT_BG, FIELD_BASE, FIELD_CAP, FIELD_UNDER, FIELD_BLOBS, FALLBACK_GRADIENT, ADAM_ZONE, ADAM_ZONE_L_MAX, ADAM_STAGES, FIELD_ZONE_MAX, relLuminance, blobLift, blobInZone, zoneLift, swirlLift, adamPhase, FIELD_WHITE } from './AdamHands.jsx';

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

function mm({ reduce = false, mobile = false, stack = false } = {}) {
  window.matchMedia = vi.fn().mockImplementation((q) => ({
    matches: (reduce && q.includes('prefers-reduced-motion')) || (mobile && q.includes('max-width')) || (stack && q.includes('max-height: 520px')),
    media: q, onchange: null,
    addListener: () => {}, removeListener: () => {},
    addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => false,
  }));
}

describe('AdamHands server / no-JS markup', () => {
  const html = renderToStaticMarkup(<AdamHands />);

  test('is the fallback: not live, still image, gradient strip, eyebrow text', () => {
    expect(html).toContain('data-live="false"');
    expect(html).toContain('/adam/fallback-touch-desktop-1600x900.webp');
    expect(html).toContain('/adam/fallback-touch-mobile-900x1600.webp');
    expect(html).toContain('class="adam-grad"');
    expect(html).toContain(ADAM_EYEBROW);
  });

  test('emits none of the live stack and no filter, canvas or light layers', () => {
    const body = html.replace(/<style>[\s\S]*?<\/style>/, '');
    expect(body).not.toContain('adam-canvas');
    expect(body).not.toContain('data-adam="lens"');
    expect(body).not.toContain('data-adam="lens-lobe-0"');
    expect(body).not.toContain('data-adam="leaks"');
    expect(body).not.toContain('data-adam="field"');
    expect(body).not.toContain('<filter');
    expect(body).not.toContain(ADAM_KEY_FILTER_ID);
  });

  test('fallback keeps the eyebrow text, has no Family headline, no verses, and no frozen field (the marble backdrop lives in Home .hm-fam-backdrop)', () => {
    expect(html).toContain(ADAM_EYEBROW);
    expect(html).not.toContain('Family');
    expect(html).not.toContain('Welcoming scripture');
    expect(html).not.toContain('data-adam="final"');
    expect(html).not.toContain('adam-final');
    expect(html).not.toContain('Brothers and sisters show up');
    // removed by task 20261111-kinetic-type-marble: the frozen marble under the still, and the whole verse stack
    expect(html).not.toContain('adam-fbfield');
    expect(html).not.toContain('adam-fallback-field');
    const body = html.replace(/<style>[\s\S]*?<\/style>/, '');
    expect(body).not.toContain('adam-liquid');
    expect(body).not.toContain('verse-stack');
    expect(html).not.toMatch(/blockquote/);
  });

  test('still is decorative (alt empty, aria-hidden), lazy and low priority so the hero stays LCP', () => {
    const img = html.match(/<img[^>]*adam-fb-img[^>]*>/)[0];
    expect(img).toMatch(/alt=""/);
    expect(img).toMatch(/aria-hidden="true"/);
    expect(img).toMatch(/loading="lazy"/);
    expect(img).toMatch(/fetchPriority="low"|fetchpriority="low"/);
    expect(img).toMatch(/width="1600"/); expect(img).toMatch(/height="900"/);
  });

  test('renderToString and static markup agree on the structure (hydration-safe)', () => {
    const a = renderToString(<AdamHands />).replace(/<!-- -->/g, '');
    expect(a).toBe(html);
  });

  test('CSS: runway only under data-live (538vh / 364vh stack from the one formula), 24svh gradient, stage 100svh with 100vh fallback, no honey join', () => {
    // Hand-derived from driver.js: 100 + P_END * base. desktop 100 + 1.989091 * 220 = 537.6 -> 538; stack 100 + 1.2 * 220 = 364.
    expect(RUNWAY_VH.desktop).toBe(538); expect(RUNWAY_VH_STACK.desktop).toBe(364);
    expect(ADAM_CSS).toMatch(/\.adam-pin\[data-live="true"\] \{ height: 538vh; \}/);
    expect(ADAM_CSS).toMatch(/\.adam-pin\[data-live="true"\]\[data-stack="true"\] \{ height: 364vh; \}/);
    expect(ADAM_CSS).not.toMatch(/height: (935|980|900|408|363|324)vh/); // old runways are gone
    expect(ADAM_CSS).toMatch(/\.adam-grad \{ position: relative; height: 24svh;/);
    // FIELD_UNDER is the dark marble underlay: it ends on FIELD_DEEP, not on a honey join colour
    expect(FIELD_UNDER).toMatch(/#2C1706 100%\)$/);
    expect(FIELD_UNDER).not.toMatch(/#EBC480/);
    expect(FIELD_CAP).toBe('#FFF4DC'); // warm white: the bloom's white end stop is never clamped
    expect(ADAM_CSS).toMatch(/height: 100vh; height: 100svh;/);
    expect(ADAM_CSS).not.toMatch(/\.adam-pin \{[^}]*height:\s*\d+vh/);
    expect(ADAM_CSS).toMatch(/position: sticky; top: 0/);
  });

  test('CSS: eyebrow never below 12px on mobile, no pure white, no serif display font', () => {
    expect(ADAM_CSS).toMatch(/font-size: max\(2\.89cqw, 12px\)/);
    expect(ADAM_CSS).not.toMatch(/#fff(fff)?\b/i);
    expect(ADAM_CSS).not.toMatch(/Playfair|Georgia|Times/);
  });
});

describe('AdamHands client behaviour', () => {
  test('reduced motion keeps the fallback and never schedules a frame', () => {
    mm({ reduce: true });
    const raf = vi.spyOn(window, 'requestAnimationFrame');
    const { container } = render(<AdamHands />);
    expect(container.querySelector('section').dataset.live).toBe('false');
    expect(container.querySelector('.adam-canvas')).toBeNull();
    expect(raf).not.toHaveBeenCalled();
  });

  test('live: paints beat 1 at the top of the section (hands at frame-1 offsets, flat false)', () => {
    mm();
    const { container } = render(<AdamHands />);
    const stage = container.querySelector('.adam-stage');
    expect(stage.dataset.p).toBe('0.000');
    expect(stage.dataset.flat).toBe('false');
    const adam = container.querySelector('[data-adam="adam-group"]');
    expect(adam.style.transform).toMatch(/translate\(-176\.00px, 87\.58px\) scale\(0\.943/);
    const kr = container.querySelector('[data-adam="kr"]');
    expect(parseFloat(kr.getAttribute('slope'))).toBeCloseTo(0.682, 4);
    expect(container.querySelector('[data-adam="field"]').style.opacity).toBe('0');
    expect(container.querySelector('[data-adam="final"]')).toBeNull();
  });

  test('live: scrolling to the end of the runway holds the hand-off end state; scrolling back restores', () => {
    mm();
    const rafQ = [];
    vi.stubGlobal('requestAnimationFrame', (cb) => { rafQ.push(cb); return rafQ.length; });
    vi.stubGlobal('cancelAnimationFrame', () => {});
    const { container } = render(<AdamHands />);
    const section = container.querySelector('section');
    const stage = container.querySelector('.adam-stage');
    Object.defineProperty(stage, 'clientHeight', { configurable: true, value: 900 });
    let top = 0;
    const H = (RUNWAY_VH.desktop / 100) * 900; // 538vh on a 900px stage
    section.getBoundingClientRect = () => ({ top, height: H, bottom: top + H, left: 0, right: 0, width: 0, x: 0, y: top });
    const run = (frames) => { let t = 0; for (let i = 0; i < frames; i++) { t += 100; const q = rafQ.splice(0); q.forEach((cb) => cb(t)); } };
    const field = () => container.querySelector('[data-adam="field"]');

    top = -(1.3 * 1980); // p = 1.3: past HANDOFF_END_P, marble fully revealed
    act(() => { document.dispatchEvent(new Event('scroll')); run(80); });
    expect(parseFloat(stage.dataset.p)).toBeCloseTo(1.3, 2);
    expect(stage.dataset.flat).toBe('true'); // hands hidden under the field
    expect(field().style.opacity).toBe('1');
    expect(field().dataset.live).toBe('true');
    expect(field().dataset.h).toBe('1.000'); // hand-off complete
    expect(container.querySelector('[data-adam="hilite"]')).toBeNull(); // the hilite wash was removed
    expect(container.querySelector('[data-adam="lens"]').style.visibility).toBe('hidden');
    expect(container.querySelector('[data-adam="eyebrow"]').style.visibility).toBe('hidden');

    top = -(9999); // end of runway: p clamps to P_END
    act(() => { document.dispatchEvent(new Event('scroll')); run(80); });
    expect(parseFloat(stage.dataset.p)).toBeCloseTo(P_END.desktop, 2); // 1.989
    expect(container.querySelector('[data-adam="verse"]')).toBeNull(); // no verse layer exists any more
    expect(field().dataset.h).toBe('1.000');

    top = 0; // fully reversible
    act(() => { document.dispatchEvent(new Event('scroll')); run(60); });
    expect(parseFloat(stage.dataset.p)).toBeLessThan(0.01);
    expect(stage.dataset.flat).toBe('false');
    expect(field().dataset.live).toBe('false');
    expect(field().dataset.h).toBe('0.000');
  }, 30000);

  test('live: scroll is smoothed, not instant (one frame after a jump is short of the target)', () => {
    mm();
    const rafQ = [];
    vi.stubGlobal('requestAnimationFrame', (cb) => { rafQ.push(cb); return rafQ.length; });
    vi.stubGlobal('cancelAnimationFrame', () => {});
    const { container } = render(<AdamHands />);
    const section = container.querySelector('section');
    const stage = container.querySelector('.adam-stage');
    Object.defineProperty(stage, 'clientHeight', { configurable: true, value: 900 });
    section.getBoundingClientRect = () => ({ top: -(1980 * 0.5), height: 4842, bottom: 0, left: 0, right: 0, width: 0, x: 0, y: 0 });
    act(() => { document.dispatchEvent(new Event('scroll')); rafQ.splice(0).forEach((cb) => cb(16)); });
    const p1 = parseFloat(stage.dataset.p);
    expect(p1).toBeGreaterThan(0);
    expect(p1).toBeLessThan(0.5);
  });

  test('unmount removes listeners and cancels the frame', () => {
    mm();
    const rm = vi.spyOn(document, 'removeEventListener');
    const cancel = vi.spyOn(window, 'cancelAnimationFrame');
    const { unmount } = render(<AdamHands />);
    unmount();
    expect(rm.mock.calls.some(([t]) => t === 'scroll')).toBe(true);
    expect(cancel).toBeDefined();
  });

  test('mobile breakpoint switches to the 9:16 stack', () => {
    mm({ mobile: true });
    const { container } = render(<AdamHands />);
    const cv = container.querySelector('.adam-canvas');
    expect(cv.style.width).toBe('900px'); expect(cv.style.height).toBe('1600px');
  });
});

describe('rev 2: centred text, font constant, exact subtitle, reduced-motion no-drift', () => {
  const css = ADAM_CSS;
  const rule = (sel) => { const m = css.match(new RegExp('^' + sel.replace(/[.[\]]/g, '\\$&') + ' \\{([^}]*)\\}', 'm')); return m ? m[1] : ''; };
  const html = renderToStaticMarkup(<AdamHands />);

  test('palette: warm brown base, fields share the exported constants', () => {
    expect(FIELD_BASE).toBe('#5C3509');
    expect(FIELD_UNDER).toContain(FIELD_BASE);
    expect(css).toContain(`background: ${FIELD_UNDER}`);
    expect(FALLBACK_GRADIENT.endsWith(`${FIELD_BASE} 100%`)).toBe(true);
    expect(FIELD_BLOBS.every((b) => /^#[0-9A-F]{6}$/i.test(b.c))).toBe(true);
  });

  test('drift is transform-only, paused unless live, and off under reduced motion and when frozen', () => {
    expect(css).toMatch(/@keyframes adam-drift/);
    const kf = css.match(/@keyframes adam-drift .*$/m)[0];
    expect(kf).toMatch(/transform/);
    expect(kf).not.toMatch(/\b(left|top|width|height|margin)\s*:/);
    expect(rule('.adam-blob')).toMatch(/animation-play-state: paused/);
    expect(css).toMatch(/\.adam-field\[data-live="true"\]\[data-onscreen="true"\] \.adam-blob[^{]*\{ animation-play-state: running/);
    expect(css).toMatch(/\.adam-liquid-frozen \.adam-blob \{ animation: none; \}/);
    expect(css).toMatch(/@media \(prefers-reduced-motion: reduce\) \{ \.adam-blob, \.adam-swirl \{ animation: none; \} \}/);
  });

  test('fallback markup: AdamHands renders no liquid field at all (the frozen copy is the .hm-fam-backdrop LiquidField)', () => {
    expect(html.replace(/<style>[\s\S]*?<\/style>/, '')).not.toMatch(/adam-liquid/);
    // the frozen LiquidField (used by Home's backdrop) has no drift class and is aria-hidden
    const frozen = renderToStaticMarkup(<LiquidField />);
    expect(frozen).toContain('adam-liquid-frozen');
    expect(frozen).not.toMatch(/class="adam-liquid adam-field"/);
    expect(frozen.match(/<div[^>]*adam-liquid-frozen[^>]*>/)[0]).toMatch(/aria-hidden="true"/);
    expect(frozen).not.toContain('<canvas'); // no WebGL canvas in the frozen copy
    expect(frozen).toContain('adam-resolve'); // CSS resolve into cream
  });

  test('client reduced motion: AdamHands renders no live field and no frozen field of its own', () => {
    mm({ reduce: true });
    const { container } = render(<AdamHands />);
    expect(container.querySelector('.adam-field')).toBeNull();
    expect(container.querySelector('.adam-liquid')).toBeNull();
    expect(container.querySelector('.adam-blob')).toBeNull();
  });

  test('live: drift is on the field element only, and gets data-live once the field is visible', () => {
    mm();
    const { container } = render(<AdamHands />);
    const f = container.querySelector('[data-adam="field"]');
    expect(f.getAttribute('aria-hidden')).toBe('true');
    expect(f.className).toContain('adam-field');
    expect(f.dataset.live).toBe('false'); // p = 0: field invisible, drift paused
    expect(container.querySelectorAll('.adam-field').length).toBe(1);
  });
});

describe('rev 2 contrast (WCAG AA), cream ink on the brown field, worst-case grain', () => {
  const rgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  const lumRgb = (c) => { const [r, g, b] = c.map((v) => v / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
  const ratio = (a, b) => { const [x, y] = [lumRgb(a), lumRgb(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };
  const scale = (c, k) => c.map((v) => Math.min(255, Math.round(v * k)));
  const over = (top, a, bot) => top.map((v, i) => Math.round(v * a + bot[i] * (1 - a)));
  const ink = rgb(FIELD_INK);

  test('ink on the brown base with grain lightening up to 15%', () => {
    expect(ratio(ink, scale(rgb(FIELD_BASE), 1.15))).toBeGreaterThanOrEqual(4.5);
  });

  test('.hm-fam body ink sits on the cream (#FBF7F1) rest block; the marble resolves to that same LIGHT_BG', () => {
    expect(LIGHT_BG).toBe('#FBF7F1');
    expect(ratio(rgb('#1A1512'), rgb(LIGHT_BG))).toBeGreaterThanOrEqual(4.5);
    expect(ratio(rgb('#5C3509'), rgb(LIGHT_BG))).toBeGreaterThanOrEqual(4.5);
    // the kinetic head type is cream: it must clear AA on the DARK marble stops it sits on (FIELD_BASE .. FIELD_DEEP), not the cream
    expect(ratio(ink, rgb(FIELD_BASE))).toBeGreaterThanOrEqual(4.5);
  });
});

describe('rev 3: no halo, luminance rule from the blob table, variety, client-only phase', () => {
  const css = ADAM_CSS;
  const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
  const LB = relLuminance(hex(FIELD_BASE));
  const lum = (h) => relLuminance(hex(h));
  const viewports = [['desktop', false], ['mobile', true], ['landscape', true]];
  const subset = (mobile) => FIELD_BLOBS.filter((b) => !mobile || b.m);

  test('halo is gone: no .adam-liquid-calm, no FIELD_CALM, no --calm vars, no centred radial dark shape', async () => {
    const mod = await import('./AdamHands.jsx');
    expect(mod.FIELD_CALM).toBeUndefined();
    expect(css).not.toMatch(/adam-liquid-calm|calm-rx|calm-ry|--calm/);
    expect(renderToStaticMarkup(<AdamHands />)).not.toContain('adam-liquid-calm');
    mm();
    const { container } = render(<AdamHands />);
    expect(container.querySelector('.adam-liquid-calm')).toBeNull();
  });

  test('table size: 6 blobs (the 4 s:true highlight blobs were removed), 3 on mobile, sizes in the spec ranges', () => {
    // Derived from the table in lib/adamHands/field.js: 6 entries, of which m:true are #2A1606, #6E4214, #1C0E03.
    expect(FIELD_BLOBS.length).toBe(6);
    expect(subset(true).length).toBe(3);
    expect(FIELD_BLOBS.filter((b) => b.s).length).toBe(0); // no highlight blobs remain
  });

  test('luminance rule: every blob that can reach the text zone is dark or a low lift, summed lift stays in the bound', () => {
    for (const [name, mobile] of viewports) {
      const [W, H] = ADAM_STAGES[name];
      const budget = ADAM_ZONE_L_MAX - LB;
      expect(budget).toBeGreaterThan(0);
      const inZone = subset(mobile).filter((b) => blobInZone(b, mobile, W, H));
      let sum = 0;
      for (const b of inZone) {
        const lift = blobLift(b);
        // either it never lightens (colour no lighter than base) or its peak alpha-weighted lift is tiny
        if (lum(b.c) > LB) expect(lift).toBeLessThan(budget);
        else expect(lift).toBe(0);
        sum += lift;
      }
      // blobs plus the swirls (desktop only, worst case overlapping the zone) fit one budget
      expect(sum + (mobile ? 0 : swirlLift())).toBeLessThanOrEqual(budget + 1e-9);
      expect(zoneLift(mobile, W, H)).toBeCloseTo(sum, 9);
      // contrast budget: ink at the zone's worst luminance clears 6.8:1 raw; soft-light grain adds at most ~.01 L
      const ratio = (lum(FIELD_INK) + 0.05) / (ADAM_ZONE_L_MAX + 0.05);
      expect(ADAM_ZONE_L_MAX).toBe(0.13);
      expect(ratio).toBeGreaterThanOrEqual(5.4);
      expect((lum(FIELD_INK) + 0.05) / (ADAM_ZONE_L_MAX + 0.01 + 0.05)).toBeGreaterThanOrEqual(4.5); // AA even with the grain's extra lift
      // nothing lighter than FIELD_ZONE_MAX may reach the zone at all
      for (const b of inZone) expect(lum(b.c)).toBeLessThanOrEqual(lum(FIELD_ZONE_MAX) + 1e-9);
    }
  });

  test('no light blob (amber/honey) can reach the text zone at full alpha', () => {
    for (const [name, mobile] of viewports) {
      const [W, H] = ADAM_STAGES[name];
      for (const b of subset(mobile)) {
        if (lum(b.c) > 0.2 && b.a >= 0.4) expect(blobInZone(b, mobile, W, H)).toBe(false);
      }
    }
  });

  test('rule catches a regression: a bright honey blob parked on the text fails the bound', () => {
    const bad = { c: '#EBC480', a: 0.8, x: 50, y: 50, w: 40, h: 30, r: 0, t: 40, dx: 0, dy: 0, dr: 0, m: true, g: 1 };
    const [W, H] = ADAM_STAGES.desktop;
    expect(blobInZone(bad, false, W, H)).toBe(true);
    expect(zoneLift(false, W, H, [...FIELD_BLOBS, bad])).toBeGreaterThan(ADAM_ZONE_L_MAX - LB);
  });

  test('some blobs do cross behind the text and some centres sit well off-centre', () => {
    const [W, H] = ADAM_STAGES.desktop;
    expect(FIELD_BLOBS.filter((b) => blobInZone(b, false, W, H)).length).toBeGreaterThanOrEqual(2);
    // off-centre by blob centre (x offsets 12, 22, 8, 36, 42, 47 -> four are 20 or more from the middle)
    expect(FIELD_BLOBS.filter((b) => Math.abs(b.x - 50) >= 20).length).toBeGreaterThanOrEqual(3);
  });

  test('asymmetric and varied: no mirrored pairs, wide size range, distinct periods, colours and rotations, varied drift', () => {
    for (let i = 0; i < FIELD_BLOBS.length; i++) {
      for (let j = i + 1; j < FIELD_BLOBS.length; j++) {
        const a = FIELD_BLOBS[i]; const b = FIELD_BLOBS[j];
        const mirrored = Math.abs(a.x + b.x - 100) < 4 && Math.abs(a.y - b.y) < 4 && Math.abs(a.w - b.w) < 6;
        expect(mirrored).toBe(false);
      }
    }
    const ws = FIELD_BLOBS.map((b) => b.w);
    expect(Math.min(...ws)).toBeLessThanOrEqual(20);
    expect(Math.max(...ws)).toBeGreaterThanOrEqual(70);
    const ts = FIELD_BLOBS.map((b) => b.t);
    expect(new Set(ts).size).toBe(ts.length);
    expect(Math.min(...ts)).toBeGreaterThanOrEqual(12); // r2 drift is about 0.45x the original half-cycle
    expect(Math.max(...ts)).toBeLessThanOrEqual(27);
    // every blob has its own colour and rotation (was >= 7 colours / >= 8 rotations of 10 blobs; all-distinct is the same rule on 6)
    expect(new Set(FIELD_BLOBS.map((b) => b.c.toUpperCase())).size).toBe(FIELD_BLOBS.length);
    expect(new Set(FIELD_BLOBS.map((b) => b.r)).size).toBe(FIELD_BLOBS.length);
    const amp = FIELD_BLOBS.map((b) => Math.max(Math.abs(b.dx), Math.abs(b.dy)));
    expect(Math.max(...amp)).toBeGreaterThanOrEqual(12);
    // drift amplitudes vary (smallest is 8, largest 18: the old <= 7 floor belonged to the removed small highlight blobs)
    expect(Math.min(...amp)).toBe(8);
    expect(Math.max(...amp) / Math.min(...amp)).toBeGreaterThanOrEqual(1.5);
    expect(Math.max(...FIELD_BLOBS.map((b) => Math.abs(b.dr)))).toBeGreaterThanOrEqual(20);
    expect(FIELD_BLOBS.filter((b) => b.l).length).toBeGreaterThanOrEqual(2); // non-elliptical silhouettes (3 -> 2 with the highlight blobs gone)
  });

  test('no light highlight blobs remain: every blob is dark umber or a low lift, none lighter than FIELD_ZONE_MAX', () => {
    for (const b of FIELD_BLOBS) expect(lum(b.c)).toBeLessThanOrEqual(lum(FIELD_ZONE_MAX) + 1e-9);
    expect(FIELD_BLOBS.some((b) => 's' in b)).toBe(false);
  });

  test('no honey strip: no ::before bottom fade, no 84% mask on the gl or blobs, no #EBC480 join anywhere in the stage CSS', () => {
    const stageCss = ADAM_CSS; // includes LIQUID_CSS and LENS_CSS
    expect(stageCss).not.toMatch(/\.adam-liquid::before/);
    expect(stageCss).not.toMatch(/mask-image: linear-gradient\(180deg, #000 0, #000 60%/);
    expect(stageCss).not.toMatch(/#EBC480|EBC480/i);
    expect(stageCss).not.toMatch(/adam-hilite|adam-fbfield|adam-teal|#7CC3D4/);
  });

  test('adamPhase maps a unit random to [0, 2t] and is deterministic', () => {
    expect(adamPhase(40, 0)).toBe(0);
    expect(adamPhase(40, 1)).toBe(80);
    expect(adamPhase(40, 0.5)).toBe(40);
    expect(adamPhase(31, 0.25)).toBe(adamPhase(31, 0.25));
    expect(css).toMatch(/animation-delay: calc\(var\(--ph, 0\) \* -1s\)/);
  });

  test('SSR / prerender / fallback render: no --ph and Math.random is never called during render', () => {
    const rnd = vi.spyOn(Math, 'random');
    const html = renderToStaticMarkup(<AdamHands />);
    renderToString(<AdamHands />);
    renderToStaticMarkup(<LiquidField />);
    expect(rnd).not.toHaveBeenCalled();
    expect(html.replace(/<style>[\s\S]*?<\/style>/, '')).not.toContain('--ph');
  });

  test('client reduced motion: no field, random never used, no blob animated by AdamHands', () => {
    mm({ reduce: true });
    const rnd = vi.spyOn(Math, 'random');
    const { container } = render(<AdamHands />);
    expect(rnd).not.toHaveBeenCalled();
    expect(container.querySelector('.adam-field')).toBeNull();
    container.querySelectorAll('.adam-blob').forEach((el) => expect(el.style.getPropertyValue('--ph')).toBe(''));
    expect(css).toMatch(/@media \(prefers-reduced-motion: reduce\) \{ \.adam-blob, \.adam-swirl \{ animation: none; \} \}/);
  });

  test('live client: --ph is set only after mount on the live field blobs (random 0.5 -> exactly t)', () => {
    mm();
    vi.spyOn(Math, 'random').mockReturnValue(0.5);
    const { container } = render(<AdamHands />);
    const live = container.querySelectorAll('.adam-field .adam-blob');
    expect(live.length).toBe(FIELD_BLOBS.length);
    live.forEach((el, i) => expect(parseFloat(el.style.getPropertyValue('--ph'))).toBeCloseTo(FIELD_BLOBS[i].t, 1));
  });

  test('text: the stage carries the eyebrow only (its own colour), no headline CSS; the cream ink belongs to Home .hm-fam', () => {
    expect(css).toMatch(/\.adam-eyebrow \{[^}]*color: #F0C08A/);
    expect(css).not.toMatch(/\.adam-final/);
    expect(css).not.toContain(`color: ${FIELD_INK}`); // the stage CSS no longer styles any cream text
  });

  test('live and frozen LiquidField render the same blob geometry from the one table', () => {
    mm();
    const { container } = render(<AdamHands />);
    const geo = (el) => ['--x', '--y', '--w', '--h', '--r', '--t'].map((k) => el.style.getPropertyValue(k)).join();
    const live = [...container.querySelectorAll('.adam-field .adam-blob')].map(geo);
    cleanup();
    const r2 = render(<LiquidField />);
    const frozen = [...r2.container.querySelectorAll('.adam-liquid-frozen .adam-blob')].map(geo);
    expect(frozen.length).toBe(FIELD_BLOBS.length);
    expect(frozen).toEqual(live);
  });
});

describe('lens bloom, hand-off, onscreen pause and landscape stack', () => {
  const setup = (opts) => {
    mm(opts);
    const rafQ = [];
    vi.stubGlobal('requestAnimationFrame', (cb) => { rafQ.push(cb); return rafQ.length; });
    vi.stubGlobal('cancelAnimationFrame', () => {});
    const r = render(<AdamHands />);
    const section = r.container.querySelector('section');
    const stage = r.container.querySelector('.adam-stage');
    Object.defineProperty(stage, 'clientHeight', { configurable: true, value: 900 });
    Object.defineProperty(stage, 'clientWidth', { configurable: true, value: 1600 });
    let top = 0;
    section.getBoundingClientRect = () => ({ top, height: 4842, bottom: top + 4842, left: 0, right: 0, width: 0, x: 0, y: top });
    const goto = (p) => { top = -p * 1980; act(() => { document.dispatchEvent(new Event('scroll')); for (let i = 0; i < 80; i++) rafQ.splice(0).forEach((cb) => cb(i * 100 + 100)); }); };
    return { ...r, stage, goto };
  };

  test('lens bloom: centre-origin lobes grow from p .86 and HOLD the full white beat to HANDOFF_START_P, then one-step off (no recede)', () => {
    const { container, goto } = setup();
    const lens = container.querySelector('[data-adam="lens"]');
    const lobe = (i) => container.querySelector(`[data-adam="lens-lobe-${i}"]`);
    const field = () => container.querySelector('[data-adam="field"]');
    const flat = () => parseFloat(container.querySelector('[data-adam="lens-flat"]').style.opacity);
    const scaleOf = (el) => parseFloat(el.style.transform.match(/scale\(([\d.]+)\)/)[1]);
    goto(0.5);
    expect(lens.style.visibility).toBe('hidden');
    goto(0.9);
    expect(lens.style.visibility).toBe('visible');
    expect(lens.querySelectorAll('.lens-lobe').length).toBe(6);
    expect(lobe(0).style.willChange).toBe('');
    expect(lens.dataset.on).toBe('true');
    const s9 = scaleOf(lobe(0));
    expect(s9).toBeGreaterThan(0.05);
    expect(field().dataset.live).toBe('false');
    goto(0.95);
    expect(scaleOf(lobe(0))).toBeGreaterThan(s9); // grows outward
    // white hold: fully grown, flat solid, and the marble field is already drawing UNDER it from HANDOFF_START_P - 0.02 = 1.00
    goto(1.01);
    expect(lens.dataset.on).toBe('true');
    expect(flat()).toBe(1);
    expect(field().dataset.live).toBe('true');
    expect(field().dataset.h).toBe('0.000'); // GL veil is still pure white: pixel-equal to the lens
    const s101 = scaleOf(lobe(0));
    expect(s101).toBeGreaterThan(0.99);
    goto(1.018); // still inside the hold: the lobes have NOT receded (the old behaviour scaled them down from 1.02)
    expect(scaleOf(lobe(0))).toBeGreaterThanOrEqual(s101 - 1e-3);
    expect(flat()).toBe(1);
    // one step off at HANDOFF_START_P: lens hidden and display none, not faded
    goto(HANDOFF_START_P + 0.01);
    expect(lens.dataset.on).toBe('false');
    expect(lens.style.visibility).toBe('hidden');
    expect(lens.style.display).toBe('none');
    expect(container.querySelector('.adam-stage').dataset.flat).toBe('true');
    expect(field().dataset.live).toBe('true');
    // reverse scroll is exact: same p, same transform
    goto(0.9);
    expect(scaleOf(lobe(0))).toBeCloseTo(s9, 3);
    expect(field().dataset.live).toBe('false');
    // nothing in the lens writes a vertical wipe: no translateY travel, no band element
    expect(container.querySelector('[data-adam="lk-band"]')).toBeNull();
    expect(container.querySelector('[data-adam="leaks"]')).toBeNull();
  }, 30000);

  test('hand-off: field data-h follows handoffH(p) (0 at the hold, eased, 1 at HANDOFF_END_P) and never an opacity ramp', () => {
    const { container, goto } = setup();
    const field = container.querySelector('[data-adam="field"]');
    const ps = [1.0, 1.02, 1.05, 1.1, 1.15, 1.2, 1.5];
    let prev = -1;
    for (const p of ps) {
      goto(p);
      const h = parseFloat(field.dataset.h);
      if (p >= 1.02) expect(field.style.opacity).toBe('1'); // fully opaque for the whole hand-off: light leaves by the shader, not by fading the field
      expect(h).toBeCloseTo(handoffH(p), 3);
      expect(h).toBeGreaterThanOrEqual(prev); prev = h;
    }
    expect(handoffH(HANDOFF_START_P + (HANDOFF_END_P - HANDOFF_START_P) / 2)).toBeCloseTo(0.5, 6);
    expect(floodCurve(0.5)).toBeCloseTo(0.5, 6);
  }, 30000);

  test('no-GL hand-off path: the CSS mask veil + gold rim grow a clear centre (--vr 74% -> 0) over the hand-off and are gone after', () => {
    const { container, goto } = setup(); // jsdom has no WebGL, so data-gl is never set and the CSS veil is the live path
    const veil = container.querySelector('[data-adam="veil"]'); const rim = container.querySelector('[data-adam="veil-rim"]');
    const field = container.querySelector('[data-adam="field"]');
    expect(field.dataset.gl).toBeUndefined();
    goto(1.0);
    expect(veil.style.display).toBe('none'); // before the hold ends the lens itself is the white
    const vr = (el) => parseFloat(el.style.getPropertyValue('--vr'));
    let prev = Infinity;
    for (const p of [1.03, 1.06, 1.1, 1.15, 1.19]) {
      goto(p);
      expect(veil.style.display).toBe('block'); expect(rim.style.display).toBe('block');
      const expected = 74 * (1 - handoffH(p)); // VR_FROM 74% lerped to 0 by the same handoffH the shader reads
      expect(vr(veil)).toBeCloseTo(expected, 1); expect(vr(rim)).toBeCloseTo(expected, 1);
      expect(vr(veil)).toBeLessThan(prev); prev = vr(veil);
    }
    goto(1.3);
    expect(veil.style.display).toBe('none'); expect(rim.style.display).toBe('none');
    // CSS: a spatial radial mask (never an opacity ramp), hidden whenever the GL canvas draws the hand-off itself
    const css = ADAM_CSS;
    expect(css).toMatch(/\.adam-veil \{[^}]*mask-image: radial-gradient\(ellipse 100% 100% at 50% 50%, #000 0, #000 var\(--vr\)/);
    expect(css).toMatch(/\.adam-field\[data-gl="true"\] ~ \.adam-veil, \.adam-field\[data-gl="true"\] ~ \.adam-veil-rim \{ display: none !important; \}/);
    expect(css).not.toMatch(/\.adam-veil \{[^}]*transition/);
  }, 30000);

  test('lens lobes are offset from the centre origin and each is scaled/rotated independently (irregular union, no circle)', () => {
    const { container, goto } = setup();
    goto(0.93);
    const tf = [0, 1, 2, 3, 4, 5].map((i) => container.querySelector(`[data-adam="lens-lobe-${i}"]`).style.transform);
    expect(new Set(tf).size).toBe(6);
    for (const t of tf) expect(t).toMatch(/translate\(-50%, -50%\) translate\(calc\(-?[\d.]+ \* var\(--u\)\), calc\(-?[\d.]+ \* var\(--u\)\)\) rotate\(-?[\d.]+deg\) scale\([\d.]+\)/);
    // the origin wrapper is the stage centre
    expect(LENS_CSS).toMatch(/\.lens-o \{[^}]*left: 50%; top: 50%/);
    // wider lobes have unequal radii
    expect(LENS_LOBES.every((l) => l.rx !== l.ry)).toBe(true);
    expect(container.querySelector('[data-adam="lens-streak"]')).not.toBeNull();
    expect(container.querySelectorAll('[data-adam^="lens-ghost-"]').length).toBe(3);
    expect(container.querySelector('[data-adam="lens-rays"]')).not.toBeNull();
  }, 30000);

  test('mobile lens keeps 4 lobes, no ghosts and no rays', () => {
    const { container, goto } = setup({ mobile: true });
    goto(0.93 * (1440 / 1980)); // mobile runs on a 160vh base span (1440px on a 900px stage)
    expect(container.querySelector('[data-adam="lens"]').style.visibility).toBe('visible');
    expect(container.querySelectorAll('.lens-lobe').length).toBe(4);
    expect(container.querySelectorAll('.lens-ghost').length).toBe(0);
    expect(container.querySelector('[data-adam="lens-rays"]')).toBeNull();
  }, 30000);

  test('no circles in the transition layers: gradients are ellipse-shaped, no border-radius, no 50% radius; old band is gone', () => {
    expect(LENS_CSS).not.toMatch(/border-radius/);
    expect(LOBE_GRAD).toMatch(/^radial-gradient\(ellipse /);
    for (const g of LENS_CSS.match(/radial-gradient\([^,]*,/g) || []) expect(g).not.toMatch(/circle(?! closest-side)/);
    // the wash mask is smooth radial gradients on a stage-sized box: no SVG noise image (its facets read as hard grey polygons)
    expect(LENS_CSS).not.toMatch(/feTurbulence/);
    expect(LENS_CSS).toMatch(/\.lens-wash \{ position: absolute; inset: 0; -webkit-mask-image: radial-gradient/);
    expect(ADAM_CSS).not.toMatch(/adam-wash|adam-cover|lk-band|adam-leaks/);
    const { container, goto } = setup();
    for (const p of [0.86, 0.92, 1.0, 1.01]) {
      goto(p);
      container.querySelectorAll('.adam-lens, .adam-lens *').forEach((el) => {
        // gradients are static (CSS, or the fixed ghost-glint inline fill), never rewritten per frame
        if (el.classList.contains('lens-ghost')) expect(el.style.background).toMatch(/^radial-gradient\(/); else expect(el.style.background || '').toBe('');
        expect(el.style.background || '').not.toMatch(/circle/);
        expect(el.style.borderRadius || '').toBe('');
      });
    }
    expect(container.querySelector('[data-adam="wash"]')).toBeNull();
    expect(container.querySelector('[data-adam="cover"]')).toBeNull();
  }, 30000);

  test('lens is a warm-white hold: flat layer is FIELD_WHITE, hidden under reduced motion', () => {
    expect(FIELD_WHITE).toBe('#FFF4DC');
    expect(LENS_CSS).toMatch(/\.lens-flat \{[^}]*background: #FFF4DC/);
    expect(LENS_CSS).toMatch(/@media \(prefers-reduced-motion: reduce\) \{ \.adam-lens \{ display: none; \} \}/);
    expect(LENS_CSS).toMatch(/\.adam-lens \{[^}]*visibility: hidden/);
    expect(LENS_CSS).toMatch(/\.adam-lens \{[^}]*pointer-events: none/);
  });

  test('liquid drift runs only while on screen: IntersectionObserver toggles data-onscreen', () => {
    let cb = null;
    vi.stubGlobal('IntersectionObserver', class { constructor(fn) { cb = fn; } observe() {} disconnect() {} });
    const { container } = setup();
    const f = container.querySelector('[data-adam="field"]');
    expect(f.dataset.onscreen).toBe('true');
    act(() => { cb([{ isIntersecting: false }]); });
    expect(f.dataset.onscreen).toBe('false');
    act(() => { cb([{ isIntersecting: true }]); });
    expect(f.dataset.onscreen).toBe('true');
    expect(ADAM_CSS).toMatch(/\[data-onscreen="true"\] \.adam-swirl/);
  });

  test('swirl mask is intersected with a closest-side radial so the rotating box edge never shows', () => {
    const rule = ADAM_CSS.match(/\.adam-swirl \{[^}]*\}/)[0];
    expect(rule).toMatch(/radial-gradient\(closest-side, #000 70%, transparent 100%\)/);
    expect(rule).toMatch(/mask-composite: intersect/);
    expect(rule).toMatch(/-webkit-mask-composite: source-in/);
  });

  test('desktop live renders both swirl layers; mobile renders none and keeps only m:true blobs visible by CSS', () => {
    const d = setup();
    expect(d.container.querySelectorAll('.adam-swirl').length).toBe(2);
    cleanup();
    const m = setup({ mobile: true });
    expect(m.container.querySelectorAll('.adam-swirl').length).toBe(0);
    expect(ADAM_CSS).toMatch(/\.adam-blob-d, \.adam-swirl \{ display: none; \}/);
  });

  test('landscape-phone stack mode: live hero, no pinned descent, shorter runway, no verse stack after the section', () => {
    const { container } = setup({ stack: true });
    const section = container.querySelector('section');
    expect(section.dataset.live).toBe('true');
    expect(section.dataset.stack).toBe('true');
    expect(container.querySelector('[data-adam="verses"]')).toBeNull();
    expect(container.querySelector('[data-testid="verse-stack"]')).toBeNull();
    expect(section.nextElementSibling).toBeNull(); // AdamHands renders nothing after its own section (Home adds .hm-fam)
  });

  test('stack mode ends the shorter runway at HANDOFF_END_P (1.20) with the hand-off complete and no Family layer', () => {
    const { container, goto } = setup({ stack: true });
    goto(5);
    expect(P_END_STACK).toBe(HANDOFF_END_P);
    expect(parseFloat(container.querySelector('.adam-stage').dataset.p)).toBeCloseTo(HANDOFF_END_P, 2);
    expect(container.querySelector('[data-adam="field"]').dataset.h).toBe('1.000');
    expect(container.querySelector('[data-adam="final"]')).toBeNull();
  }, 30000);

  test('no verse symbols remain in the AdamHands module, its CSS or its markup', async () => {
    const mod = await import('./AdamHands.jsx');
    expect(Object.keys(mod).filter((k) => /verse|thread/i.test(k))).toEqual([]);
    expect(ADAM_CSS).not.toMatch(/\bverses?\b|verse-|thread|hilite/i);
    mm();
    const { container } = render(<AdamHands />);
    expect(container.innerHTML).not.toMatch(/\bverses?\b|verse-/i);
    expect(container.querySelector('[data-adam="verses"], [data-adam="verse"], .verse-sr, [data-testid="verse-stack"]')).toBeNull();
  });
});

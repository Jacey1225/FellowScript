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
import AdamHands, { ADAM_CSS, ADAM_EYEBROW, ADAM_KEY_FILTER_ID, ADAM_FINAL_SUBTITLE, FIELD_END, FIELD_INK, FIELD_BASE, FIELD_CAP, FIELD_UNDER, FIELD_BLOBS, ADAM_FINAL_FONT, FALLBACK_GRADIENT, ADAM_ZONE, ADAM_ZONE_L_MAX, ADAM_STAGES, FIELD_ZONE_MAX, relLuminance, blobLift, blobInZone, zoneLift, adamPhase } from './AdamHands.jsx';

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

  test('emits none of the live stack and no filter, canvas or wash', () => {
    const body = html.replace(/<style>[\s\S]*?<\/style>/, '');
    expect(body).not.toContain('adam-canvas');
    expect(body).not.toContain('data-adam="wash"');
    expect(body).not.toContain('data-adam="field"');
    expect(body).not.toContain('<filter');
    expect(body).not.toContain(ADAM_KEY_FILTER_ID);
  });

  test('fallback shows real text: Family + the exact subtitle (typo preserved) on the honey block', () => {
    expect(ADAM_FINAL_SUBTITLE).toBe('Welcoming scripture into a deeper comunity.');
    expect(html).toContain('data-testid="adam-fallback-field"');
    expect(html).toContain('>Family</span>');
    expect(html).toContain('>Welcoming scripture into a deeper comunity.</span>');
    expect(html).not.toContain('Brothers and sisters show up');
    const block = html.match(/<div class="adam-fbfield-in"[\s\S]*$/)[0];
    expect(block).not.toMatch(/aria-hidden/);
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

  test('CSS: runway only under data-live, 24svh gradient ending on FIELD_END, stage 100svh with 100vh fallback', () => {
    expect(ADAM_CSS).toMatch(/\.adam-pin\[data-live="true"\] \{ height: 672vh; \}/);
    expect(ADAM_CSS).toMatch(/height: 564vh/);
    expect(ADAM_CSS).toMatch(/\[data-stack="true"\] \{ height: 408vh; \}/);
    expect(ADAM_CSS).toMatch(/\.adam-grad \{ position: relative; height: 24svh;/);
    expect(FIELD_END).toBe('#0E2144');
    expect(FIELD_UNDER).toMatch(/#0E2144 100%\)$/);
    expect(FIELD_CAP).toBe('#FCFFFC'); // the bloom can never clamp lighter than the white flash
    expect(ADAM_CSS).toMatch(/\.adam-final-h \{[^}]*Schibsted Grotesk[^}]*font-weight: 600/);
    expect(ADAM_CSS).toContain(`color: ${FIELD_INK}`);
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
    expect(parseFloat(container.querySelector('[data-adam="final"]').style.opacity)).toBe(0);
  });

  test('live: scrolling to the end of the runway paints the flat plane and the final type; scrolling back restores', () => {
    mm();
    const rafQ = [];
    vi.stubGlobal('requestAnimationFrame', (cb) => { rafQ.push(cb); return rafQ.length; });
    vi.stubGlobal('cancelAnimationFrame', () => {});
    const { container } = render(<AdamHands />);
    const section = container.querySelector('section');
    const stage = container.querySelector('.adam-stage');
    Object.defineProperty(stage, 'clientHeight', { configurable: true, value: 900 });
    let top = 0;
    const H = 6048; // 672vh on a 900px stage
    section.getBoundingClientRect = () => ({ top, height: H, bottom: top + H, left: 0, right: 0, width: 0, x: 0, y: top });
    const run = (frames) => { let t = 0; for (let i = 0; i < frames; i++) { t += 100; const q = rafQ.splice(0); q.forEach((cb) => cb(t)); } };

    top = -(1.3 * 1980); // p = 1.3: settled navy field, Family fully revealed
    act(() => { document.dispatchEvent(new Event('scroll')); run(80); });
    expect(parseFloat(stage.dataset.p)).toBeCloseTo(1.3, 2);
    expect(stage.dataset.flat).toBe('true'); // hands hidden under the opaque navy
    expect(container.querySelector('[data-adam="field"]').style.opacity).toBe('1');
    expect(container.querySelector('[data-adam="field"]').dataset.live).toBe('true');
    expect(parseFloat(container.querySelector('[data-adam="teal"]').style.opacity)).toBeCloseTo(1, 2);
    expect(container.querySelector('[data-adam="wash"]').style.visibility).toBe('hidden');
    expect(container.querySelector('[data-adam="cover"]').style.visibility).toBe('hidden');
    expect(parseFloat(container.querySelector('[data-adam="final"]').style.opacity)).toBeCloseTo(1, 2);
    expect(container.querySelector('[data-adam="eyebrow"]').style.visibility).toBe('hidden');

    top = -(9999); // end of runway: p clamps to P_END, verses have all passed, Family is gone
    act(() => { document.dispatchEvent(new Event('scroll')); run(80); });
    expect(parseFloat(stage.dataset.p)).toBeCloseTo(2.6, 2);
    expect(parseFloat(container.querySelector('[data-adam="final"]').style.opacity)).toBe(0);
    container.querySelectorAll('[data-adam="verse"]').forEach((el) => expect(el.style.visibility).toBe('hidden'));

    top = -(1.8 * 1980); // mid verse phase: at least one widget on screen, in the stage's pixel space
    act(() => { document.dispatchEvent(new Event('scroll')); run(80); });
    const shown = [...container.querySelectorAll('[data-adam="verse"]')].filter((el) => el.style.visibility === 'visible');
    expect(shown.length).toBeGreaterThanOrEqual(1);
    shown.forEach((el) => expect(el.style.transform).toMatch(/translate3d\(/));

    top = 0; // fully reversible
    act(() => { document.dispatchEvent(new Event('scroll')); run(60); });
    expect(parseFloat(stage.dataset.p)).toBeLessThan(0.01);
    expect(stage.dataset.flat).toBe('false');
    expect(parseFloat(container.querySelector('[data-adam="final"]').style.opacity)).toBe(0);
    expect(container.querySelector('[data-adam="field"]').dataset.live).toBe('false');
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
    section.getBoundingClientRect = () => ({ top: -(1980 * 0.5), height: 6048, bottom: 0, left: 0, right: 0, width: 0, x: 0, y: 0 });
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

  test('live .adam-final is flex-centred on both axes with text-align center; old left/top anchoring is gone', () => {
    const r = rule('.adam-final');
    expect(r).toMatch(/inset: 0/);
    expect(r).toMatch(/display: flex/);
    expect(r).toMatch(/flex-direction: column/);
    expect(r).toMatch(/align-items: center/);
    expect(r).toMatch(/justify-content: center/);
    expect(r).toMatch(/text-align: center/);
    expect(r).not.toMatch(/\bleft:\s*10cqw|top:\s*31\.5cqh|top:\s*34svh/);
    expect(css).not.toMatch(/left: 10cqw; top: 31\.5cqh/);
    expect(css).not.toMatch(/top: 34svh/);
  });

  test('fallback block centres its content (grid place-items center, text-align center, inner centred)', () => {
    const r = rule('.adam-fbfield');
    expect(r).toMatch(/place-items: center/);
    expect(r).toMatch(/text-align: center/);
    expect(rule('.adam-fbfield-in')).toMatch(/text-align: center/);
    expect(rule('.adam-fbfield .adam-final-b')).toMatch(/margin-inline: auto/);
  });

  test('headline is a single line and subtitle wraps balanced', () => {
    expect(rule('.adam-final-h')).toMatch(/white-space: nowrap/);
    expect(rule('.adam-final-b')).toMatch(/text-wrap: balance/);
  });

  test('ADAM_FINAL_FONT is Schibsted Grotesk and is the only face used for the headline (live + fallback)', () => {
    expect(ADAM_FINAL_FONT).toBe("'Schibsted Grotesk', sans-serif");
    expect(rule('.adam-final-h')).toContain(`font-family: ${ADAM_FINAL_FONT}`);
    expect(rule('.adam-final-h')).toMatch(/font-weight: 600/);
    expect(rule('.adam-final-b')).toContain(`font-family: ${ADAM_FINAL_FONT}`);
    // fallback headline only overrides size, so it inherits the same family/weight rule
    expect(rule('.adam-fbfield .adam-final-h')).not.toMatch(/font-family/);
    expect(css).not.toMatch(/Playfair|Georgia|Times|Inter\b/);
  });

  test('exact subtitle (typo kept) and headline in prerender markup', () => {
    expect(ADAM_FINAL_SUBTITLE).toBe('Welcoming scripture into a deeper comunity.');
    expect(html).toContain('>Welcoming scripture into a deeper comunity.</span>');
    expect(html).toContain('>Family</span>');
  });

  test('palette: navy base, fields share the exported constants', () => {
    expect(FIELD_BASE).toBe('#1B3B64');
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

  test('fallback markup: liquid field is the frozen copy (no drift class), aria-hidden', () => {
    const block = html.match(/<div class="adam-fbfield"[\s\S]*$/)[0];
    expect(block).toContain('adam-liquid-frozen');
    expect(block).not.toMatch(/class="adam-liquid adam-field"/);
    const liquid = block.match(/<div[^>]*adam-liquid-frozen[^>]*>/)[0];
    expect(liquid).toMatch(/aria-hidden="true"/);
  });

  test('client reduced motion: no live field, no running drift element', () => {
    mm({ reduce: true });
    const { container } = render(<AdamHands />);
    expect(container.querySelector('.adam-field')).toBeNull();
    expect(container.querySelector('.adam-liquid-frozen')).not.toBeNull();
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

  test('ink on the navy base with grain lightening up to 15%', () => {
    expect(ratio(ink, scale(rgb(FIELD_BASE), 1.15))).toBeGreaterThanOrEqual(4.5);
  });

  test('.hm-fam eyebrow and body ink sit on the cream (#FBF7F1), past the short navy ramp', () => {
    expect(FIELD_END).toBe('#0E2144');
    expect(ratio(rgb('#5C3509'), rgb('#FBF7F1'))).toBeGreaterThanOrEqual(4.5);
    expect(ratio(rgb('#1A1512'), rgb('#FBF7F1'))).toBeGreaterThanOrEqual(4.5);
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

  test('table size: 10 desktop, 5 on mobile, sizes in the spec ranges', () => {
    expect(FIELD_BLOBS.length).toBe(10);
    expect(subset(true).length).toBe(5);
    expect(FIELD_BLOBS.filter((b) => b.s).length).toBeGreaterThanOrEqual(3);
    expect(FIELD_BLOBS.length).toBeGreaterThanOrEqual(8);
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
      expect(sum).toBeLessThanOrEqual(budget + 1e-9);
      expect(zoneLift(mobile, W, H)).toBeCloseTo(sum, 9);
      // ink at that worst luminance clears AA (5.6:1 pre-grain at L .13; grain budget keeps it >= 4.5)
      const ratio = (lum(FIELD_INK) + 0.05) / (ADAM_ZONE_L_MAX + 0.05);
      expect(ratio).toBeGreaterThanOrEqual(5.5);
      expect(ratio / 1.0).toBeGreaterThan(4.5);
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

  test('some blobs do cross behind the text and some sit off-centre', () => {
    const [W, H] = ADAM_STAGES.desktop;
    expect(FIELD_BLOBS.filter((b) => blobInZone(b, false, W, H)).length).toBeGreaterThanOrEqual(2);
    expect(FIELD_BLOBS.filter((b) => !blobInZone(b, false, W, H)).length).toBeGreaterThanOrEqual(3);
  });

  test('asymmetric and varied: no mirrored pairs, wide size range, distinct periods and colours, varied drift', () => {
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
    expect(Math.min(...ts)).toBeGreaterThanOrEqual(14);
    expect(Math.max(...ts)).toBeLessThanOrEqual(27);
    expect(new Set(FIELD_BLOBS.map((b) => b.c.toUpperCase())).size).toBeGreaterThanOrEqual(7);
    const amp = FIELD_BLOBS.map((b) => Math.max(Math.abs(b.dx), Math.abs(b.dy)));
    expect(Math.max(...amp)).toBeGreaterThanOrEqual(12);
    expect(Math.min(...amp)).toBeLessThanOrEqual(7);
    expect(Math.max(...FIELD_BLOBS.map((b) => Math.abs(b.dr)))).toBeGreaterThanOrEqual(20);
    expect(FIELD_BLOBS.filter((b) => b.l).length).toBeGreaterThanOrEqual(3); // non-elliptical silhouettes
    expect(new Set(FIELD_BLOBS.map((b) => b.r)).size).toBeGreaterThanOrEqual(8);
  });

  test('deep navy dominates by area; teal highlights are the accent', () => {
    const area = (b) => b.w * b.h;
    const dark = (b) => !b.s;
    const d = FIELD_BLOBS.filter(dark).reduce((s, b) => s + area(b), 0);
    const total = FIELD_BLOBS.reduce((s, b) => s + area(b), 0);
    expect(d / total).toBeGreaterThan(0.6);
    expect(d / total).toBeLessThan(0.95);
  });

  test('teal highlights sit in the top band, clear of the headline zone and the join', () => {
    for (const b of FIELD_BLOBS.filter((x) => x.s)) expect(b.y).toBeLessThanOrEqual(12);
    expect(css).toMatch(/transparent 84%/);
    expect(css).toMatch(/\.adam-liquid::before \{[^}]*FIELD_END|\.adam-liquid::before \{[^}]*#0E2144/);
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
    expect(rnd).not.toHaveBeenCalled();
    expect(html.replace(/<style>[\s\S]*?<\/style>/, '')).not.toContain('--ph');
    expect(html).toContain('adam-liquid-frozen');
  });

  test('client reduced motion: frozen block has no --ph, random never used, blobs not animated', () => {
    mm({ reduce: true });
    const rnd = vi.spyOn(Math, 'random');
    const { container } = render(<AdamHands />);
    expect(rnd).not.toHaveBeenCalled();
    expect(container.querySelector('.adam-field')).toBeNull();
    container.querySelectorAll('.adam-blob').forEach((el) => expect(el.style.getPropertyValue('--ph')).toBe(''));
    expect(css).toMatch(/@media \(prefers-reduced-motion: reduce\) \{ \.adam-blob, \.adam-swirl \{ animation: none; \} \}/);
  });

  test('live client: --ph is set only after mount on the live field blobs, within [0, 2t]; frozen block untouched', () => {
    mm();
    vi.spyOn(Math, 'random').mockReturnValue(0.5);
    const { container } = render(<AdamHands />);
    const live = container.querySelectorAll('.adam-field .adam-blob');
    expect(live.length).toBe(FIELD_BLOBS.length);
    live.forEach((el, i) => expect(parseFloat(el.style.getPropertyValue('--ph'))).toBeCloseTo(FIELD_BLOBS[i].t, 1));
    container.querySelectorAll('.adam-liquid-frozen .adam-blob').forEach((el) => expect(el.style.getPropertyValue('--ph')).toBe(''));
  });

  test('text: centred, ADAM_FINAL_FONT headline/subtitle, exact subtitle, ink colour', () => {
    expect(ADAM_FINAL_SUBTITLE).toBe('Welcoming scripture into a deeper comunity.');
    const html = renderToStaticMarkup(<AdamHands />);
    expect(html).toContain('>Welcoming scripture into a deeper comunity.</span>');
    const r = (sel) => { const m = css.match(new RegExp('^' + sel.replace(/[.[\]]/g, '\\$&') + ' \\{([^}]*)\\}', 'm')); return m ? m[1] : ''; };
    expect(r('.adam-final')).toMatch(/align-items: center/);
    expect(r('.adam-final')).toMatch(/justify-content: center/);
    expect(r('.adam-final')).toMatch(/text-align: center/);
    expect(r('.adam-final-h')).toContain(`font-family: ${ADAM_FINAL_FONT}`);
    expect(r('.adam-final-b')).toContain(`font-family: ${ADAM_FINAL_FONT}`);
    expect(css).toContain(`color: ${FIELD_INK}`);
  });

  test('all surfaces share one blob table: live and frozen render the same geometry', () => {
    mm();
    const { container } = render(<AdamHands />);
    const geo = (el) => ['--x', '--y', '--w', '--h', '--r', '--t'].map((k) => el.style.getPropertyValue(k)).join();
    const live = [...container.querySelectorAll('.adam-field .adam-blob')].map(geo);
    cleanup();
    mm({ reduce: true });
    const r2 = render(<AdamHands />);
    const frozen = [...r2.container.querySelectorAll('.adam-liquid-frozen .adam-blob')].map(geo);
    expect(frozen.length).toBe(FIELD_BLOBS.length);
    expect(frozen).toEqual(live);
  });
});

describe('second fill, wash, onscreen pause and landscape-stack verses', () => {
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
    section.getBoundingClientRect = () => ({ top, height: 6048, bottom: top + 6048, left: 0, right: 0, width: 0, x: 0, y: top });
    const goto = (p) => { top = -p * 1980; act(() => { document.dispatchEvent(new Event('scroll')); for (let i = 0; i < 80; i++) rafQ.splice(0).forEach((cb) => cb(i * 100 + 100)); }); };
    return { ...r, stage, goto };
  };

  test('wash covers the stage at p .95; white hold at p 1.0 (field still hidden); cover hole opens at p 1.06', () => {
    const { container, goto } = setup();
    goto(0.95);
    const wash = container.querySelector('[data-adam="wash"]');
    expect(wash.style.visibility).toBe('visible');
    expect(wash.style.background).toMatch(/radial-gradient/);
    expect(container.querySelector('[data-adam="cover"]').style.visibility).toBe('hidden');
    goto(1.0);
    expect(container.querySelector('[data-adam="field"]').dataset.live).toBe('false');
    expect(wash.style.visibility).toBe('visible');
    goto(1.06);
    expect(container.querySelector('[data-adam="cover"]').style.visibility).toBe('visible');
    expect(wash.style.visibility).toBe('hidden');
    expect(container.querySelector('[data-adam="field"]').dataset.live).toBe('true');
    expect(container.querySelector('[data-adam="cover"]').style.background).toMatch(/radial-gradient\(circle/);
    // hands still composited until the fill completes
    expect(container.querySelector('.adam-stage').dataset.flat).toBe('false');
    goto(1.2);
    expect(container.querySelector('.adam-stage').dataset.flat).toBe('true');
  }, 30000);

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

  test('desktop live renders both swirl layers; mobile renders none and keeps only m:true blobs visible by CSS', () => {
    const d = setup();
    expect(d.container.querySelectorAll('.adam-swirl').length).toBe(2);
    cleanup();
    const m = setup({ mobile: true });
    expect(m.container.querySelectorAll('.adam-swirl').length).toBe(0);
    expect(ADAM_CSS).toMatch(/\.adam-blob-d, \.adam-swirl \{ display: none; \}/);
  });

  test('landscape-phone stack mode: live hero, no pinned descent, verses stacked after the section, shorter runway', () => {
    const { container } = setup({ stack: true });
    const section = container.querySelector('section');
    expect(section.dataset.live).toBe('true');
    expect(section.dataset.stack).toBe('true');
    expect(container.querySelector('[data-adam="verses"]')).toBeNull();
    expect(container.querySelector('[data-testid="verse-stack"]')).not.toBeNull();
    expect(section.nextElementSibling.dataset.testid).toBe('verse-stack');
  });

  test('stack mode keeps Family visible at the end of the shorter runway', () => {
    const { container, goto } = setup({ stack: true });
    goto(5);
    expect(parseFloat(container.querySelector('.adam-stage').dataset.p)).toBeCloseTo(1.4, 2);
    expect(parseFloat(container.querySelector('[data-adam="final"]').style.opacity)).toBeCloseTo(1, 2);
  }, 30000);
});

// Pure verse-descent maths (design spec section 6). The widgets are painted by
// direct style writes from the hero's paint loop; nothing here touches the DOM.
import { clamp, lerp, smooth, VERSE_START_P, VERSE_SPAN_P } from './adamHands/driver.js';

export const VERSE_D = 0.40; // per-widget travel window in verse progress v (0..1)
export const VERSE_Y_FROM_VH = -20; // widget centre, % of stage height, at u = 0
export const VERSE_Y_TO_VH = 120; // ... at u = 1 (fully off-screen both ends)
export const VERSE_X = { desktop: [30, 68, 36, 64, 50], mobile: [50, 52, 48, 52, 50] }; // centre, % of stage width
export const VERSE_FADE = 0.12;
export const VERSE_STACK_QUERY = '(prefers-reduced-motion: reduce), (max-height: 520px) and (orientation: landscape)';
export const VERSE_LABEL = 'Scripture on community';

export const verseStep = (n, d = VERSE_D) => (n > 1 ? (1 - d) / (n - 1) : 0);

// Verse-phase progress v in [0, 1] from the hero scrub p.
export const verseProgress = (p, mobile) => clamp((p - VERSE_START_P) / VERSE_SPAN_P[mobile ? 'mobile' : 'desktop']);

// Per-widget state: u (own travel 0..1), yVh (centre, % of stage height), opacity, visible, xPct.
export function verseState(i, n, p, mobile) {
  const v = verseProgress(p, mobile);
  const u = clamp((v - i * verseStep(n)) / VERSE_D);
  const xs = mobile ? VERSE_X.mobile : VERSE_X.desktop;
  return {
    u,
    yVh: lerp(VERSE_Y_FROM_VH, VERSE_Y_TO_VH, u),
    opacity: smooth(u / VERSE_FADE) * smooth((1 - u) / VERSE_FADE),
    visible: u > 0 && u < 1,
    xPct: xs[i % xs.length],
  };
}

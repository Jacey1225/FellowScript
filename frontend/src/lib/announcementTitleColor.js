// Announcement title color: palette, strict hex validation and contrast helpers
// (task 20260929-announcement-title-color-crop-layer-fix). Mirrors the iOS
// AnnouncementTitleColor.swift. A server/user string only reaches a style
// attribute through bannerColor()/surfaceColor(), which require strict #RRGGBB.

export const TITLE_COLOR_DEFAULT = '#F2F2F2';

export const TITLE_COLOR_SWATCHES = [
  { name: 'Parchment (default)', hex: '#F2F2F2' },
  { name: 'White', hex: '#FFFFFF' },
  { name: 'Gold', hex: '#FFC61A' },
  { name: 'Light gold', hex: '#FFD966' },
  { name: 'Sky', hex: '#9CD3FF' },
  { name: 'Mint', hex: '#9BE7B4' },
  { name: 'Rose', hex: '#FFB3C1' },
  { name: 'Lavender', hex: '#CDB8FF' },
  { name: 'Coral', hex: '#FF9E80' },
];

// Worst-case banner backdrop (pure white photo under the 0.72 scrim) and app surfaces.
export const SCRIM_WORST_CASE = '#474747';
export const SURFACE_DARK = '#1A1A1A';
export const SURFACE_LIGHT = '#FFFFFF';
export const MIN_CONTRAST = 4.5;

const HEX = /^#[0-9A-Fa-f]{6}$/;

export const isValidHex = (v) => typeof v === 'string' && HEX.test(v);
export const normalizeHex = (v) => (isValidHex(v) ? v.toUpperCase() : null);
export const isDefaultColor = (v) => { const n = normalizeHex(v); return !n || n === TITLE_COLOR_DEFAULT; };

export function luminance(hex) {
  const n = normalizeHex(hex);
  if (!n) return null;
  const c = [1, 3, 5].map((i) => parseInt(n.slice(i, i + 2), 16) / 255)
    .map((x) => (x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4));
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

export function contrastRatio(a, b) {
  const la = luminance(a); const lb = luminance(b);
  if (la == null || lb == null) return null;
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

export function needsLegibilityWarning(hex) {
  const n = normalizeHex(hex);
  if (!n) return false;
  const r = contrastRatio(n, SCRIM_WORST_CASE);
  return r != null && r < MIN_CONTRAST;
}

export const colorName = (hex) => {
  const n = normalizeHex(hex);
  if (!n) return 'Parchment (default)';
  return TITLE_COLOR_SWATCHES.find((s) => s.hex === n)?.name || `Custom color ${n}`;
};

// Banner-face title color: chosen (validated) color, else the default.
export const bannerColor = (hex) => normalizeHex(hex) || TITLE_COLOR_DEFAULT;

function isLightTheme() {
  if (typeof document === 'undefined') return false;
  const el = document.documentElement;
  return el.getAttribute('data-theme') === 'light' || el.classList.contains('light') || document.body?.classList.contains('light');
}

// Title on the app surface (list row / viewer): chosen color only if it meets
// AA against the current surface; otherwise undefined (inherit theme text).
export function surfaceColor(hex, light = isLightTheme()) {
  const n = normalizeHex(hex);
  if (!n || n === TITLE_COLOR_DEFAULT) return undefined;
  const r = contrastRatio(n, light ? SURFACE_LIGHT : SURFACE_DARK);
  return r != null && r >= MIN_CONTRAST ? n : undefined;
}

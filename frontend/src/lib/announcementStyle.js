// Shared announcement appearance + extras contract (task
// 20261010-web-announcements-parity). Mirrors the iOS AnnouncementBgTheme,
// AnnouncementTitleFont and AnnouncementExtras*.swift. The server stores only
// the allowlisted KEYS; the colors and fonts below are client design tokens.
// One module feeds the chat widget, the detail viewer and the form preview so
// the three can never drift. Unknown/legacy keys resolve to the pre-feature
// look (never an error).
import { contrastRatio, luminance, isValidHex } from './announcementTitleColor.js';

// ── Server flags (GET /app/capabilities `features`) ──────────────────────────
export const ANNOUNCEMENT_FLAGS = {
  titleFont: 'announcement_title_font',
  bgTheme: 'announcement_bg_theme',
  links: 'announcement_links',
  gallery: 'announcement_gallery',
  payments: 'announcement_payments',
  rsvp: 'announcement_rsvp',
  location: 'announcement_location',
};

// ── Background themes ────────────────────────────────────────────────────────
const t = (name, ...stops) => ({ name, stops });
export const BG_THEMES = {
  none: { name: 'None', stops: [] },
  ember: t('Ember', '#2A1A0C', '#4A2A10'),
  dusk: t('Dusk', '#1D1A33', '#3A2748'),
  forest: t('Forest', '#10241A', '#1E3A2A'),
  ocean: t('Ocean', '#0F2233', '#1B3B52'),
  plum: t('Plum', '#2B1530', '#4A2450'),
  slate: t('Slate', '#1B1F26', '#343B46'),
  espresso: t('Espresso', '#2A1F16'),
  moss: t('Moss', '#1F2B1E'),
  navy: t('Navy', '#16213A'),
  wine: t('Wine', '#3A1A22'),
  graphite: t('Graphite', '#25262B'),
  ink: t('Ink', '#101010'),
};
export const BG_THEME_GRADIENTS = ['ember', 'dusk', 'forest', 'ocean', 'plum', 'slate'];
export const BG_THEME_SOLIDS = ['espresso', 'moss', 'navy', 'wine', 'graphite', 'ink'];

export const PARCHMENT_HEX = '#F5EAD0';
export const WHITE_HEX = '#FFFFFF';

// Strict allowlist lookup: nil, unknown or legacy -> 'none'.
export const resolveBgTheme = (key) => (typeof key === 'string' && Object.hasOwn(BG_THEMES, key) ? key : 'none');
// The key to send: null for none (server NULL).
export const bgThemeStoredKey = (key) => { const k = resolveBgTheme(key); return k === 'none' ? null : k; };
export const bgThemeStops = (key) => BG_THEMES[resolveBgTheme(key)].stops;
export const bgThemeName = (key) => BG_THEMES[resolveBgTheme(key)].name;
export const bgThemeIsGradient = (key) => bgThemeStops(key).length > 1;
export const bgThemeLabel = (key) => {
  const k = resolveBgTheme(key);
  return k === 'none' ? 'No background theme' : `${BG_THEMES[k].name} ${bgThemeIsGradient(k) ? 'gradient' : 'solid'}`;
};

// CSS background for a theme, or null for none (top-left to bottom-right, as iOS).
export function bgThemeCss(key) {
  const stops = bgThemeStops(key);
  if (!stops.length) return null;
  if (stops.length === 1) return stops[0];
  return `linear-gradient(135deg, ${stops.join(', ')})`;
}

// The lightest stop: the worst case for light text.
export function bgThemeWorstCaseHex(key) {
  const stops = bgThemeStops(key);
  if (!stops.length) return null;
  return stops.reduce((a, b) => ((luminance(b) ?? 0) > (luminance(a) ?? 0) ? b : a));
}

// Parchment, or white if it wins over the worst-case stop. None sits on the app surface.
export function bgThemeReadableText(key) {
  const bg = bgThemeWorstCaseHex(key);
  if (!bg) return PARCHMENT_HEX;
  return (contrastRatio(WHITE_HEX, bg) ?? 0) > (contrastRatio(PARCHMENT_HEX, bg) ?? 0) ? WHITE_HEX : PARCHMENT_HEX;
}

// ── Title fonts ──────────────────────────────────────────────────────────────
// `family` falls back to a generic of the same character if the web font is
// blocked or offline (the Google Fonts <link> lives in index.html).
export const TITLE_FONTS = {
  default: { name: 'Default', hint: 'sans serif', family: null, scale: 1 },
  playfair: { name: 'Playfair', hint: 'serif', family: "'Playfair Display', Georgia, serif", weight: 700, scale: 1 },
  schibsted: { name: 'Schibsted', hint: 'grotesque', family: "'Schibsted Grotesk', 'Helvetica Neue', Arial, sans-serif", weight: 600, scale: 1 },
  lora: { name: 'Lora', hint: 'warm serif', family: "'Lora', Georgia, serif", weight: 600, scale: 1 },
  oswald: { name: 'Oswald', hint: 'condensed', family: "'Oswald', 'Arial Narrow', Impact, sans-serif", weight: 600, scale: 1.04 },
  dancing: { name: 'Dancing Script', hint: 'script', family: "'Dancing Script', 'Brush Script MT', cursive", weight: 700, scale: 1.12 },
  nunito: { name: 'Nunito', hint: 'rounded', family: "'Nunito', 'Trebuchet MS', sans-serif", weight: 800, scale: 1 },
  bebas: { name: 'Bebas Neue', hint: 'heavy capitals', family: "'Bebas Neue', Impact, 'Arial Narrow', sans-serif", weight: 400, scale: 1.15 },
};
export const TITLE_FONT_KEYS = Object.keys(TITLE_FONTS);

export const resolveTitleFont = (key) => (typeof key === 'string' && Object.hasOwn(TITLE_FONTS, key) ? key : 'default');
export const titleFontStoredKey = (key) => { const k = resolveTitleFont(key); return k === 'default' ? null : k; };
export const titleFontLabel = (key) => { const f = TITLE_FONTS[resolveTitleFont(key)]; return `${f.name}, ${f.hint}`; };

// Inline-style fragment for a title: {} for the default face so the CSS class
// keeps the exact pre-feature look.
export function titleFontStyle(key) {
  const f = TITLE_FONTS[resolveTitleFont(key)];
  if (!f.family) return {};
  return { fontFamily: f.family, fontWeight: f.weight, '--title-font-scale': f.scale };
}

// ── Extras: limits and validation (mirrors the server; the server is the source of truth) ──
export const EXTRAS_LIMITS = {
  maxLinks: 5,
  maxLinkLength: 500,
  maxLabelLength: 60,
  maxGallery: 6,
  maxHandleLength: 64,
  maxLocationLength: 120,
  capacityMin: 1,
  capacityMax: 9999,
  capacityDefault: 20,
  paymentDisclaimer: 'Payments happen outside FellowScript. FellowScript never handles money. Only pay people you know.',
};

export const PAYMENT_PROVIDERS = [
  { key: 'venmo', title: 'Venmo', placeholder: '@username' },
  { key: 'cashapp', title: 'Cash App', placeholder: '$cashtag' },
  { key: 'paypal', title: 'PayPal', placeholder: 'PayPal.Me name' },
  { key: 'zelle', title: 'Zelle', placeholder: 'Email or phone' },
];
export const paymentProvider = (key) => PAYMENT_PROVIDERS.find((p) => p.key === key) || null;

// Parsed, scheme-checked URL string or null. Only http/https with a dotted
// host, no credentials, no whitespace/control characters. A missing scheme is
// treated as https. This is the ONLY path a user-supplied link reaches an href.
export function parseLink(raw) {
  if (typeof raw !== 'string') return null;
  let s = raw.trim();
  if (!s || s.length > EXTRAS_LIMITS.maxLinkLength) return null;
  // eslint-disable-next-line no-control-regex
  if (/[\s\u0000-\u001f\u007f]/.test(s)) return null;
  if (!s.includes('://')) s = `https://${s}`;
  let u;
  try { u = new URL(s); } catch { return null; }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  if (u.username || u.password) return null;
  const host = u.hostname;
  if (!host.includes('.') || host.startsWith('.') || host.endsWith('.')) return null;
  return u.href;
}

// Host shown beside every link so the real destination is visible.
export function linkDisplayHost(url) {
  try { return new URL(url).hostname.toLowerCase().replace(/^www\./, ''); } catch { return ''; }
}

// Internationalized/punycode hosts can imitate a familiar domain.
export function isLookalikeHost(host) {
  return /[^\x00-\x7f]/.test(host) || host.split('.').some((l) => l.startsWith('xn--')); // eslint-disable-line no-control-regex
}

export function linkError(raw) {
  const s = (raw || '').trim();
  if (!s) return null;
  return parseLink(s) ? null : 'Enter a web address like example.com.';
}

export function handleError(raw) {
  const h = (raw || '').trim();
  if (!h) return null;
  if (h.length > EXTRAS_LIMITS.maxHandleLength) return 'Too long.';
  // Mirrors the server: never accept something that looks like a card or account number.
  if ((h.match(/\d/g) || []).length >= 13) return 'Enter a username, email or phone, not a card or account number.';
  return null;
}

// eslint-disable-next-line no-control-regex
export const hasControlChars = (s) => /[\u0000-\u001f\u007f-\u009f]/.test(s || '');
export function locationError(raw) {
  if (hasControlChars(raw)) return "Location can't contain control characters.";
  return null;
}

// Map search for a free-text place. Search only; no geocoding or permission.
export function locationMapsUrl(place) {
  const q = (place || '').trim();
  if (!q) return null;
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(q)}`;
}

// Title color a banner/theme face can show, same helper the viewer uses against a theme.
export function titleColorOnTheme(hex, themeKey, fallback) {
  const bg = bgThemeWorstCaseHex(themeKey);
  if (!bg || !isValidHex(hex)) return fallback;
  const r = contrastRatio(hex, bg);
  return r != null && r >= 4.5 ? hex.toUpperCase() : fallback;
}

// Shared build-time <head> tag builder (used by vite.config.js for Home and
// scripts/prerender.mjs for the downloads page). Output for Home is
// byte-identical to the previous inline implementation in vite.config.js.
export function escapeAttr(value) {
  return String(value).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

export function escapeText(value) {
  return String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

export function buildSeoTags({ title, description, canonical, ogImage, jsonLd }) {
  return [
    `<meta name="description" content="${escapeAttr(description)}" data-rh="true">`,
    `<link rel="canonical" href="${escapeAttr(canonical)}" data-rh="true">`,
    `<meta name="robots" content="index, follow" data-rh="true">`,
    `<meta property="og:type" content="website" data-rh="true">`,
    `<meta property="og:title" content="${escapeAttr(title)}" data-rh="true">`,
    `<meta property="og:description" content="${escapeAttr(description)}" data-rh="true">`,
    `<meta property="og:url" content="${escapeAttr(canonical)}" data-rh="true">`,
    `<meta property="og:site_name" content="FellowScript" data-rh="true">`,
    `<meta property="og:image" content="${escapeAttr(ogImage)}" data-rh="true">`,
    `<meta name="twitter:card" content="summary_large_image" data-rh="true">`,
    `<meta name="twitter:title" content="${escapeAttr(title)}" data-rh="true">`,
    `<meta name="twitter:description" content="${escapeAttr(description)}" data-rh="true">`,
    `<meta name="twitter:image" content="${escapeAttr(ogImage)}" data-rh="true">`,
    ...jsonLd.map((block) => `<script type="application/ld+json" data-rh="true">${JSON.stringify(block)}</script>`),
  ].join('\n    ');
}

import React, { useRef } from 'react';
import { useParallaxBlobs } from '../hooks/useParallaxBlobs.js';

// Shared decorative background layer for Reader/Account (design-notes.md
// §1a) — reuses Home's own useParallaxBlobs hook/mechanism (no new
// mechanism) so the gold bloom drifts subtly with scroll/cursor instead of
// sitting frozen like the static --bloom-primary/--bloom-secondary layer
// from §1, plus a subtle grain/parchment texture over it. Purely
// decorative: fixed, pointer-events: none, z-index behind all interactive
// content — never intercepts panel docking, form inputs, or any element
// with a JS state hook. `variant` drives the context-aware bloom intensity
// (§1a.4): dimmer/cooler behind Reader's scripture text, brighter on
// Account. Respects prefers-reduced-motion via useParallaxBlobs itself.
export default function AppBloom({ variant = 'account' }) {
  const ref = useRef(null);
  useParallaxBlobs([ref]);

  return (
    <div ref={ref} className={`fs-app-bloom fs-app-bloom--${variant}`} aria-hidden="true">
      <div data-fs-blob="1" data-fs-depth="0.05" className="fs-app-bloom-blob fs-app-bloom-blob--primary" />
      <div data-fs-blob="2" data-fs-depth="-0.08" className="fs-app-bloom-blob fs-app-bloom-blob--secondary" />
      <div className="fs-app-bloom-grain" />
    </div>
  );
}

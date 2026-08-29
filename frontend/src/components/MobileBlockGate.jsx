import React from 'react';
import { Link } from 'react-router-dom';
import { isMobileUserAgent } from '../lib/deviceGate.js';

// Client-side only — UX, not enforcement. See deviceGate.js for why a UA
// check is an acceptable gate for this specific case (no sensitive data
// behind it, just a layout that assumes a desktop-sized dockview canvas).
// Evaluated once per mount rather than reactively: unlike the old
// useIsDesktopViewport()-driven mobile layout this replaced, this route
// simply isn't meant to work in a narrow viewport at all, so there's no
// "switch layouts on resize" case to support — a phone that starts on
// /reader is turned away regardless of how the window is later resized.
export default function MobileBlockGate({ children }) {
  if (isMobileUserAgent()) {
    return (
      <div
        style={{
          minHeight: '100vh',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          textAlign: 'center',
          padding: '2rem',
          background: 'var(--bg-page)',
          fontFamily: "'Lora', serif",
        }}
      >
        <div style={{ fontFamily: "'Playfair Display', serif", fontSize: '1.6rem', fontWeight: 700, color: 'var(--parchment)', marginBottom: '0.75rem' }}>
          The reader isn't available on mobile yet
        </div>
        <p style={{ maxWidth: 420, lineHeight: 1.85, color: 'rgba(244,228,193,0.75)', fontSize: '0.95rem', marginBottom: '1.5rem' }}>
          FellowScript's reader is built for a desktop-sized screen. Please open it on a desktop or laptop browser instead.
        </p>
        <Link to="/" style={{ color: 'var(--gold)', textDecoration: 'none', fontSize: '0.9rem' }}>Back to Home</Link>
      </div>
    );
  }

  return children;
}

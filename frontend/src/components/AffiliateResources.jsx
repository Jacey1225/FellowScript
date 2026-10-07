import React, { useEffect, useState, useCallback } from 'react';
import { Button, Spin } from 'antd';
import { fetchAffiliateFile, getAffiliateResources } from '../lib/affiliatesApi.js';
import { STORY_TEXT, SCRIPT_TEXT } from '../lib/affiliateScript.js';

// Task 20261007-affiliates-page. Promotion resource panels for the side menu.
// Files are session-gated, so they are fetched as blobs and shown/downloaded
// through object URLs (revoked on unmount). Items the server omits are skipped.
export const RESOURCE_SECTIONS = [
  { key: 'logos', label: 'Logos' },
  { key: 'guides', label: 'Study guides' },
  { key: 'ads', label: 'Mini ads' },
  { key: 'links', label: 'Links and QR codes' },
  { key: 'script', label: 'Talk script and story' },
];

const MUTED = { fontFamily: "'Inter', sans-serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.55)' };
const TILE = {
  background: 'rgba(244,228,193,0.9)', borderRadius: 12, minHeight: 90, display: 'flex',
  alignItems: 'center', justifyContent: 'center', overflow: 'hidden',
};

export function CopyButton({ text, label = 'Copy' }) {
  const [done, setDone] = useState(false);
  useEffect(() => {
    if (!done) return undefined;
    const t = setTimeout(() => setDone(false), 2000);
    return () => clearTimeout(t);
  }, [done]);
  const copy = async () => {
    try { await navigator.clipboard.writeText(text); setDone(true); } catch { /* clipboard unavailable */ }
  };
  return (
    <Button shape="round" onClick={copy} style={{ minHeight: 44 }} aria-live="polite">
      {done ? 'Copied' : label}
    </Button>
  );
}

async function saveBlob(res) {
  const blob = await fetchAffiliateFile(res.url);
  const href = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = href;
  a.download = res.label.replace(/[^\w.-]+/g, '-');
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(href), 1000);
}

function DownloadButton({ res, label = 'Download', open = false }) {
  const [failed, setFailed] = useState(false);
  const go = async () => {
    try {
      if (open) {
        const href = URL.createObjectURL(await fetchAffiliateFile(res.url));
        window.open(href, '_blank', 'noopener');
        setTimeout(() => URL.revokeObjectURL(href), 60000);
      } else await saveBlob(res);
    } catch { setFailed(true); }
  };
  if (failed) return <span style={MUTED}>Unavailable</span>;
  return <Button shape="round" onClick={go} style={{ minHeight: 44 }}>{label}</Button>;
}

function Thumb({ res }) {
  const [src, setSrc] = useState(null);
  const [failed, setFailed] = useState(false);
  const isImg = res.content_type.startsWith('image/') && res.content_type !== 'image/svg+xml';
  useEffect(() => {
    if (!isImg) return undefined;
    let live = true;
    let href = null;
    fetchAffiliateFile(res.url).then((b) => {
      href = URL.createObjectURL(b);
      if (live) setSrc(href); else URL.revokeObjectURL(href);
    }).catch(() => { if (live) setFailed(true); });
    return () => { live = false; if (href) URL.revokeObjectURL(href); };
  }, [res.url, isImg]);
  return (
    <div style={TILE}>
      {isImg && src && <img src={src} alt={res.label} style={{ maxWidth: '100%', maxHeight: 160, objectFit: 'contain' }} />}
      {isImg && !src && !failed && <Spin size="small" />}
      {isImg && failed && <span style={{ ...MUTED, color: '#14110D' }}>Unavailable</span>}
      {!isImg && <span style={{ ...MUTED, color: '#14110D' }}>{res.content_type === 'image/svg+xml' ? 'SVG file' : 'File'}</span>}
    </div>
  );
}

function Grid({ items, min }) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: `repeat(auto-fill, minmax(${min}px, 1fr))`, gap: '0.9rem' }}>
      {items.map((r) => (
        <div key={r.key} data-testid={`res-${r.key}`}>
          <Thumb res={r} />
          <div style={{ ...MUTED, margin: '0.35rem 0' }}>{r.label}</div>
          <DownloadButton res={r} />
        </div>
      ))}
    </div>
  );
}

function TextBlock({ title, text }) {
  return (
    <section style={{ marginBottom: '1.25rem' }}>
      <h3 className="fs-eyebrow" style={{ margin: '0 0 0.4rem' }}>{title}</h3>
      <p style={{ ...MUTED, color: 'rgba(244,228,193,0.85)', whiteSpace: 'pre-wrap', lineHeight: 1.65, margin: '0 0 0.6rem' }}>{text}</p>
      <CopyButton text={text} label={`Copy ${title.toLowerCase()}`} />
    </section>
  );
}

export default function AffiliateResources({ section, codes, onClose }) {
  const [state, setState] = useState({ status: 'idle', items: [] });

  const load = useCallback(() => {
    setState({ status: 'loading', items: [] });
    getAffiliateResources()
      .then((d) => setState({ status: 'ok', items: Array.isArray(d?.resources) ? d.resources : [] }))
      .catch(() => setState({ status: 'error', items: [] }));
  }, []);

  const needsFiles = section !== 'script';
  useEffect(() => {
    if (needsFiles && state.status === 'idle') load();
  }, [needsFiles, state.status, load]);

  const by = (s) => state.items.filter((r) => r.section === s);
  const title = RESOURCE_SECTIONS.find((s) => s.key === section)?.label;

  let body = null;
  if (needsFiles && (state.status === 'idle' || state.status === 'loading')) body = <Spin />;
  else if (needsFiles && state.status === 'error') {
    body = (
      <div role="alert" style={MUTED}>
        Couldn't load resources. <Button size="small" onClick={load}>Try again</Button>
      </div>
    );
  } else if (section === 'logos') body = <Grid items={by('logos')} min={140} />;
  else if (section === 'ads') body = <Grid items={by('ads')} min={180} />;
  else if (section === 'guides') {
    body = by('guides').map((r) => (
      <div key={r.key} data-testid={`res-${r.key}`} style={{ display: 'flex', alignItems: 'center', gap: '0.75rem', padding: '0.4rem 0', flexWrap: 'wrap' }}>
        <span style={{ flex: 1, minWidth: 160, color: 'var(--parchment)', fontFamily: "'Inter', sans-serif" }}>{r.label}</span>
        <DownloadButton res={r} label="Open PDF" open />
        <DownloadButton res={r} />
      </div>
    ));
  } else if (section === 'links') {
    const ordered = [...codes].sort((a, b) => Number(b.active) - Number(a.active));
    const qr = by('qr');
    body = (
      <>
        {ordered.map((c) => (
          <div key={c.code} style={{ display: 'flex', gap: '0.6rem', alignItems: 'center', marginBottom: '0.6rem', flexWrap: 'wrap' }}>
            <input readOnly value={c.link} aria-label={`Link for code ${c.code}`}
              onFocus={(e) => e.target.select()}
              style={{ flex: 1, minWidth: 200, minHeight: 44, padding: '0 0.8rem', borderRadius: 12, fontFamily: 'monospace',
                background: 'rgba(0,0,0,0.25)', color: 'var(--parchment)', border: '1px solid rgba(200,134,26,0.3)' }} />
            <CopyButton text={c.link} />
          </div>
        ))}
        <div style={{ maxWidth: 260, marginTop: '1rem' }}>
          <Grid items={qr} min={200} />
        </div>
        <p style={{ ...MUTED, marginTop: '0.75rem' }}>
          This QR opens fellowscript.com; add your code link in your caption or bio.
        </p>
      </>
    );
  } else if (section === 'script') {
    body = (
      <>
        <TextBlock title="The story of FellowScript" text={STORY_TEXT} />
        <TextBlock title="Talk script" text={SCRIPT_TEXT} />
      </>
    );
  }

  return (
    <div data-testid="resource-panel">
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '0.75rem' }}>
        <h2 className="fs-eyebrow" style={{ margin: 0 }}>Resources: {title}</h2>
        <Button type="text" onClick={onClose} style={{ minHeight: 44 }}>Close</Button>
      </div>
      {body}
    </div>
  );
}

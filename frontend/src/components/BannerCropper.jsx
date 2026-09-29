import React, { useState, useRef, useEffect, useCallback } from 'react';
import { Spin } from 'antd';
import { MinusOutlined, PlusOutlined } from '@ant-design/icons';
import { ANNOUNCEMENT_LIMITS } from '../lib/announcementsApi.js';
import {
  resolveCropSource, coverScale, centeredOffset, clampOffset, zoomAround, cropRect, cropToFile, frameHeight,
} from '../lib/cropBanner.js';

// Fixed-aspect pan/zoom crop step for announcement banners (design-notes.md,
// "Crop UI"). `source` is { file } or { url }. onConfirm(File) receives the
// baked 3:1 JPEG; onCancel leaves the caller's banner untouched. Failures are
// shown inline and never fall back to an uncropped upload.

const ZOOM_STEP = 0.25;
const NUDGE = 8;

export default function BannerCropper({ source, onConfirm, onCancel }) {
  const [phase, setPhase] = useState('loading'); // loading | ready | error
  const [error, setError] = useState(null);
  const [attempt, setAttempt] = useState(0);
  const [objectUrl, setObjectUrl] = useState(null);
  const [nat, setNat] = useState(null);           // { w, h }
  const [frameW, setFrameW] = useState(0);
  const [view, setView] = useState({ zoom: 1, offset: { x: 0, y: 0 } });
  const [encoding, setEncoding] = useState(false);
  const frameRef = useRef(null);
  const imgRef = useRef(null);
  const nameRef = useRef('banner.jpg');
  const dragRef = useRef(null);
  const mountedRef = useRef(true);
  useEffect(() => { mountedRef.current = true; return () => { mountedRef.current = false; }; }, []);

  const frameH = frameHeight(frameW);
  const zoomMax = ANNOUNCEMENT_LIMITS.cropZoomMax;

  // Resolve the source to a canvas-safe object URL.
  useEffect(() => {
    let live = true;
    let created = null;
    setPhase('loading'); setError(null); setNat(null); setObjectUrl(null);
    resolveCropSource(source)
      .then((res) => {
        if (res.owned !== false) created = res.objectUrl;
        if (!live) { if (created) URL.revokeObjectURL?.(created); return; }
        nameRef.current = res.name;
        setObjectUrl(res.objectUrl);
      })
      .catch((err) => { if (live) { setError(err.message || "Couldn't open this photo."); setPhase('error'); } });
    return () => { live = false; if (created) URL.revokeObjectURL?.(created); };
  }, [source, attempt]);

  // Measure the frame width (responsive).
  useEffect(() => {
    const el = frameRef.current;
    if (!el) return undefined;
    const measure = () => setFrameW(el.clientWidth || el.getBoundingClientRect().width || 300);
    measure();
    if (typeof ResizeObserver === 'undefined') return undefined;
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Once both the image and frame are measured, start cover-centered; on
  // resize keep the same zoom and re-clamp.
  useEffect(() => {
    if (!nat || !frameW) return;
    setView((v) => ({ zoom: v.zoom, offset: clampOffset(v.offset.x === 0 && v.offset.y === 0 ? centeredOffset(nat.w, nat.h, frameW, frameH, v.zoom) : v.offset, nat.w, nat.h, frameW, frameH, v.zoom) }));
  }, [nat, frameW, frameH]);

  const onImgLoad = (e) => {
    const w = e.currentTarget.naturalWidth; const h = e.currentTarget.naturalHeight;
    if (!w || !h) { setError("Couldn't read this photo. Choose a JPG, PNG, or WebP."); setPhase('error'); return; }
    setNat({ w, h });
    setView({ zoom: 1, offset: { x: 0, y: 0 } });
    setPhase('ready');
  };
  const onImgError = () => { setError("Couldn't read this photo. Choose a JPG, PNG, or WebP."); setPhase('error'); };

  const ready = phase === 'ready' && nat && frameW > 0;
  const apply = useCallback((next) => setView(next), []);

  const setZoom = (z, anchor) => {
    if (!ready) return;
    const a = anchor || { x: frameW / 2, y: frameH / 2 };
    apply(zoomAround(view, z, a, nat.w, nat.h, frameW, frameH, zoomMax));
  };
  const nudge = (dx, dy) => {
    if (!ready) return;
    apply({ zoom: view.zoom, offset: clampOffset({ x: view.offset.x + dx, y: view.offset.y + dy }, nat.w, nat.h, frameW, frameH, view.zoom) });
  };
  const reset = () => {
    if (!ready) return;
    apply({ zoom: 1, offset: centeredOffset(nat.w, nat.h, frameW, frameH, 1) });
  };

  const onPointerDown = (e) => {
    if (!ready || (e.button != null && e.button !== 0)) return;
    dragRef.current = { x: e.clientX, y: e.clientY, offset: view.offset, zoom: view.zoom };
    e.currentTarget.setPointerCapture?.(e.pointerId);
  };
  const onPointerMove = (e) => {
    const d = dragRef.current;
    if (!d || !ready) return;
    apply({ zoom: d.zoom, offset: clampOffset({ x: d.offset.x + e.clientX - d.x, y: d.offset.y + e.clientY - d.y }, nat.w, nat.h, frameW, frameH, d.zoom) });
  };
  const endDrag = () => { dragRef.current = null; };

  // Wheel zoom must be non-passive to preventDefault the page scroll.
  const wheelRef = useRef(null);
  wheelRef.current = (e) => {
    if (!ready) return;
    e.preventDefault();
    const rect = frameRef.current.getBoundingClientRect();
    setZoom(view.zoom * (e.deltaY < 0 ? 1.1 : 1 / 1.1), { x: e.clientX - rect.left, y: e.clientY - rect.top });
  };
  useEffect(() => {
    const el = frameRef.current;
    if (!el) return undefined;
    const h = (e) => wheelRef.current?.(e);
    el.addEventListener('wheel', h, { passive: false });
    return () => el.removeEventListener('wheel', h);
  }, []);

  const onKeyDown = (e) => {
    if (!ready) return;
    const step = e.shiftKey ? NUDGE * 4 : NUDGE;
    const map = { ArrowLeft: [step, 0], ArrowRight: [-step, 0], ArrowUp: [0, step], ArrowDown: [0, -step] };
    if (map[e.key]) { e.preventDefault(); nudge(...map[e.key]); }
    else if (e.key === '+' || e.key === '=') { e.preventDefault(); setZoom(view.zoom + ZOOM_STEP); }
    else if (e.key === '-' || e.key === '_') { e.preventDefault(); setZoom(view.zoom - ZOOM_STEP); }
    else if (e.key === 'Home') { e.preventDefault(); reset(); }
  };

  // Escape cancels (unless encoding).
  useEffect(() => {
    const onKey = (e) => {
      if (e.key !== 'Escape' || e.defaultPrevented || encoding) return;
      e.preventDefault(); e.stopPropagation(); onCancel();
    };
    document.addEventListener('keydown', onKey, true);
    return () => document.removeEventListener('keydown', onKey, true);
  }, [onCancel, encoding]);

  const done = async () => {
    if (!ready || encoding) return;
    setEncoding(true); setError(null);
    try {
      const rect = cropRect(view, nat.w, nat.h, frameW, frameH);
      const file = await cropToFile(imgRef.current, rect, nameRef.current);
      if (mountedRef.current) onConfirm(file);
    } catch (err) {
      if (mountedRef.current) setError(err.message || "Couldn't save the crop. Try again.");
    } finally {
      if (mountedRef.current) setEncoding(false);
    }
  };

  const scale = ready ? coverScale(nat.w, nat.h, frameW, frameH) * view.zoom : 1;
  const imgStyle = ready
    ? { width: nat.w * scale, height: nat.h * scale, left: view.offset.x, top: view.offset.y }
    : { visibility: 'hidden' };

  return (
    <div className="banner-cropper" role="dialog" aria-modal="true" aria-label="Crop banner">
      <div className="banner-cropper-bar">
        <button type="button" className="group-info-text-btn" onClick={onCancel} disabled={encoding}>Cancel</button>
        <h3 className="group-info-announcements-title">Crop banner</h3>
        <button type="button" className="group-info-pill" onClick={done} disabled={!ready || encoding}>
          {encoding ? <Spin size="small" /> : 'Done'}
        </button>
      </div>

      <div className="banner-cropper-stage">
        <div ref={frameRef} className="banner-cropper-frame" tabIndex={0} role="application"
          aria-label="Banner crop area. Arrow keys move, plus and minus zoom."
          data-testid="banner-crop-frame"
          style={{ aspectRatio: String(ANNOUNCEMENT_LIMITS.bannerAspect) }}
          onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={endDrag} onPointerCancel={endDrag}
          onKeyDown={onKeyDown}>
          {objectUrl && (
            <img ref={imgRef} className="banner-cropper-img" src={objectUrl} alt="" draggable={false}
              style={imgStyle} onLoad={onImgLoad} onError={onImgError} />
          )}
          <span className="banner-cropper-mask" aria-hidden="true" />
          <span className="banner-cropper-guides" aria-hidden="true" />
          {phase === 'loading' && <Spin className="banner-cropper-spin" />}
        </div>
      </div>

      {error && (
        <div className="group-info-banner banner-cropper-error" role="alert">
          <span>{error}</span>
          {phase === 'error' && (
            <button type="button" className="group-info-text-btn" onClick={() => setAttempt(a => a + 1)}>Try again</button>
          )}
        </div>
      )}

      <p className="group-info-helper banner-cropper-help">Drag to position. Scroll or use the slider to zoom.</p>
      <div className="banner-cropper-controls">
        <button type="button" className="group-info-icon-btn" aria-label="Zoom out" disabled={!ready} onClick={() => setZoom(view.zoom - ZOOM_STEP)}><MinusOutlined /></button>
        <input type="range" className="banner-cropper-slider" aria-label="Zoom" min={1} max={zoomMax} step={0.01}
          value={view.zoom} disabled={!ready} onChange={(e) => setZoom(parseFloat(e.target.value))} />
        <button type="button" className="group-info-icon-btn" aria-label="Zoom in" disabled={!ready} onClick={() => setZoom(view.zoom + ZOOM_STEP)}><PlusOutlined /></button>
        <button type="button" className="group-info-text-btn" disabled={!ready} onClick={reset}>Reset</button>
      </div>
    </div>
  );
}

import React, { useId, useRef, useState, useEffect } from 'react';
import { createPortal } from 'react-dom';
import BannerCropper from '../BannerCropper.jsx';
import { precheckImage, uploadListingImage } from '../../lib/listingMediaApi.js';
import { describeOwnerError } from './manageStatus.js';

// Task 20261002-explorer-listing-media step 4. One upload control, used for
// the listing photo, the banner and description images. Pick a file (type and
// size are prechecked here, the server re-checks everything), optionally crop
// (banner), give alt text where it is required, then upload: presign -> direct
// POST to S3 -> confirm. Progress and errors are announced in a status region.
// `onDone(item)` receives the server's media item.
export default function MediaUploader({
  userId, groupId, kind, label, mediaOptions, altRequired = false, crop = false, disabled = false,
  onDone, onError, children,
}) {
  const uid = useId();
  const inputRef = useRef(null);
  const mounted = useRef(true);
  // Latest callbacks, so a slow upload never completes against a stale form.
  const onDoneRef = useRef(onDone);
  onDoneRef.current = onDone;
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  const [file, setFile] = useState(null);
  const [cropSource, setCropSource] = useState(null);
  const [alt, setAlt] = useState('');
  const [stage, setStage] = useState(null); // null | uploading | processing
  const [pct, setPct] = useState(0);
  const [error, setError] = useState(null);
  const [pendingKey, setPendingKey] = useState(null); // S3 has the file; only confirm is left
  const altMax = mediaOptions?.alt_max_length || 300;
  const accept = (mediaOptions?.allowed_mime || ['image/jpeg', 'image/png', 'image/webp']).join(',');
  const busy = !!stage;

  const reset = () => { setFile(null); setAlt(''); setPendingKey(null); setError(null); setPct(0); setStage(null); };

  const onPick = (e) => {
    const f = e.target.files?.[0];
    e.target.value = '';
    if (!f) return;
    const bad = precheckImage(f, mediaOptions);
    if (bad) { setError(bad); setFile(null); return; }
    setError(null); setPendingKey(null);
    if (crop) setCropSource({ file: f }); else setFile(f);
  };

  const start = async () => {
    if (!file || busy) return;
    if (altRequired && !alt.trim()) { setError('Describe the image for people who cannot see it.'); return; }
    setError(null); setPct(0);
    try {
      const item = await uploadListingImage({
        userId, groupId, kind, file, altText: alt.trim() || null, mediaOptions,
        resume: pendingKey ? { objectKey: pendingKey } : undefined,
        onStage: (s) => mounted.current && setStage(s),
        onProgress: (p) => mounted.current && setPct(p),
        onUploaded: (k) => mounted.current && setPendingKey(k),
      });
      if (!mounted.current) return;
      reset();
      onDoneRef.current?.(item);
    } catch (err) {
      if (!mounted.current) return;
      setStage(null);
      const d = describeOwnerError(err);
      setError(d.message);
      onError?.(err);
    }
  };

  const statusText = stage === 'uploading' ? `Uploading ${pct}%`
    : stage === 'processing' ? 'Processing the image' : '';

  return (
    <div className="ex-uploader">
      <input ref={inputRef} id={`${uid}-file`} type="file" accept={accept} className="ex-sr-only"
        tabIndex={-1} aria-hidden="true" onChange={onPick} disabled={disabled || busy} />
      <div className="ex-uploader-row">
        <button type="button" className="ex-btn ex-btn--pill" onClick={() => inputRef.current?.click()}
          disabled={disabled || busy}>{label}</button>
        {children}
      </div>
      {file && (
        <div className="ex-uploader-staged">
          <p className="ex-hint">Selected: {file.name || 'image'}</p>
          {(altRequired || kind === 'image') && (
            <label className="ex-field">
              <span>Describe this image{altRequired ? '' : ' (optional)'}</span>
              <input type="text" value={alt} maxLength={altMax} required={altRequired} autoComplete="off"
                aria-describedby={`${uid}-alt-hint`} onChange={(e) => setAlt(e.target.value)} disabled={busy} />
              <span id={`${uid}-alt-hint`} className="ex-hint">
                For people who use a screen reader or cannot load the picture. {alt.length} of {altMax}.
              </span>
            </label>
          )}
          <div className="ex-block-actions">
            <button type="button" className="ex-btn ex-btn--primary" onClick={start}
              disabled={busy || disabled || (altRequired && !alt.trim())}>
              {error && pendingKey ? 'Retry' : error ? 'Try again' : 'Upload'}
            </button>
            <button type="button" className="ex-btn ex-btn--quiet" onClick={reset} disabled={busy}>Cancel</button>
          </div>
          {stage === 'uploading' && (
            <progress className="ex-progress" max="100" value={pct} aria-label={`Upload progress ${pct}%`} />
          )}
        </div>
      )}
      <div className="ex-sr-only" role="status" aria-live="polite">{statusText}</div>
      {statusText && <p className="ex-hint" aria-hidden="true">{statusText}</p>}
      {error && <p className="ex-error" role="alert">{error}</p>}
      {cropSource && createPortal(
        <BannerCropper source={cropSource}
          onConfirm={(f) => { setCropSource(null); setFile(f); }}
          onCancel={() => setCropSource(null)} />,
        document.body,
      )}
    </div>
  );
}

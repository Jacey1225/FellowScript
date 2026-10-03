import React, { useState, useEffect, useLayoutEffect, useRef, useCallback } from 'react';
import { createPortal } from 'react-dom';
import { Button, Avatar, Typography, Input, Popover, Modal, Spin, message as antMessage } from 'antd';
import {
  SendOutlined, ArrowLeftOutlined, TeamOutlined, PlusOutlined,
  PictureOutlined, FileOutlined, SmileOutlined, PlayCircleOutlined,
  DownloadOutlined, CloseCircleFilled, SearchOutlined,
  BranchesOutlined, CopyOutlined, DeleteOutlined, ExclamationCircleOutlined,
} from '@ant-design/icons';
import { SessionCard } from './SessionWidget.jsx';
import SessionsMenu from './SessionsMenu.jsx';
import GroupInfoPanel from './GroupInfoPanel.jsx';
import GroupAnnouncementWidget from './GroupAnnouncementWidget.jsx';
import { ANNOUNCEMENTS_ENABLED } from '../lib/announcementsApi.js';
import ActionableBubble from './MessageActionMenu.jsx';
import { useCapabilities } from '../hooks/useCapabilities.js';
import { DEFAULT_UNDO_SECONDS } from '../lib/threadsApi.js';

const { Text } = Typography;

// Task 20260904-messaging-attachments — security step 1's concrete per-kind
// limits (advisory client-side pre-flight only; real enforcement is the
// presigned POST policy's content-length-range condition, S3-side).
const ATTACHMENT_LIMITS = {
  image: { maxBytes: 15  * 1024 * 1024, accept: 'image/jpeg,image/png,image/webp,image/heic', oversizeCopy: 'Photos can be up to 15MB.' },
  video: { maxBytes: 250 * 1024 * 1024, accept: 'video/mp4,video/quicktime',                    oversizeCopy: 'Videos can be up to 250MB.' },
  file:  { maxBytes: 50  * 1024 * 1024, accept: '.pdf,.txt,.doc,.docx,.xlsx',                   oversizeCopy: 'Files can be up to 50MB.' },
};

function kindForFile(file) {
  if (file.type.startsWith('image/')) return 'image';
  if (file.type.startsWith('video/')) return 'video';
  return 'file';
}

function prefersReducedMotion() {
  return typeof window !== 'undefined' && !!window.matchMedia &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

// ── Tap-to-expand attachment lightbox (task 20260905-attachment-lightbox,
// design gate §5/§6/§7) — a single shared overlay serving both the image and
// gif branches of AttachmentContent below, per the design note's "one
// ChatThread.jsx-local viewer" component shape. Portaled to document.body:
// ChatThread renders inside .dockview-theme-abyss's .dv-groupview, whose own
// backdrop-filter is confirmed (per global.css's .chat-overlay comment) to
// silently suppress a descendant's independent backdrop-filter — the same
// bug already fixed for .chat-overlay / .notes-filter-panel the same way.
// No pinch/pan here (design gate §2 — out of scope for this pass); GIFs
// restart from frame 0 via their own fresh <img> mount (design gate §3)
// rather than sharing playback phase with the inline instance.
function AttachmentLightbox({ kind, url, originX, originY, onClose }) {
  const [closing, setClosing] = useState(false);
  const reducedMotion = prefersReducedMotion();

  const requestClose = useCallback(() => {
    if (reducedMotion) {
      onClose();
      return;
    }
    setClosing(true);
  }, [reducedMotion, onClose]);

  useEffect(() => {
    if (!closing) return undefined;
    // Matches the exit-motion duration below (~200ms, faster than the
    // ~280ms entrance per design gate §6's "exit faster than enter").
    const timer = window.setTimeout(onClose, 200);
    return () => window.clearTimeout(timer);
  }, [closing, onClose]);

  const style = {
    '--lightbox-origin-x': `${originX ?? 50}%`,
    '--lightbox-origin-y': `${originY ?? 50}%`,
  };

  return createPortal(
    <div
      className={`attachment-lightbox-overlay${closing ? ' attachment-lightbox-closing' : ''}`}
      style={style}
      onClick={requestClose}
      role="dialog"
      aria-modal="true"
      aria-label={kind === 'gif' ? 'Expanded GIF attachment' : 'Expanded image attachment'}
    >
      <button
        type="button"
        className="attachment-lightbox-close"
        onClick={requestClose}
        aria-label="Close"
      >
        <CloseCircleFilled />
      </button>
      {/* Fresh mount (design gate §3) — a distinct instance from whatever
          inline <img> triggered this, so an animated GIF always starts at
          frame 0 rather than inheriting the inline element's playback phase. */}
      <img
        key={url}
        src={url}
        alt={kind === 'gif' ? 'GIF attachment, expanded' : 'Photo attachment, expanded'}
        className="attachment-lightbox-media"
      />
    </div>,
    document.body
  );
}

// ── Per-kind attachment rendering inside the existing message bubble (design gate §4) ──
function meta0Ratio(m) {
  const w = Number(m && m.width);
  const h = Number(m && m.height);
  return w > 0 && h > 0 ? w / h : null;
}

function AttachmentContent({ message }) {
  const [videoPlaying, setVideoPlaying] = useState(false);
  const [gifTapped, setGifTapped] = useState(false);
  const [failed, setFailed] = useState(false);
  // Natural media ratio, from attachment metadata when present, else measured
  // on load; applied as inline aspect-ratio so media keeps its true shape
  // (and reserves space before load when metadata supplies dimensions).
  const metaRatio = meta0Ratio(message.attachmentMeta);
  const [naturalRatio, setNaturalRatio] = useState(null);
  const ratioStyle = (naturalRatio || metaRatio) ? { aspectRatio: String(naturalRatio || metaRatio) } : undefined;
  const onMediaLoad = (e) => {
    const t = e.currentTarget;
    const w = t.naturalWidth || t.videoWidth;
    const h = t.naturalHeight || t.videoHeight;
    if (w && h) setNaturalRatio(w / h);
  };
  // Lightbox state lifted one level above the per-kind branches (design gate
  // §"Component shape") so a single lightbox instance serves both the image
  // and gif branches of this same message, rather than duplicating overlay
  // logic per attachment kind.
  const [lightboxAttachment, setLightboxAttachment] = useState(null);
  const kind = message.attachmentKind;
  const meta = message.attachmentMeta || {};

  // Approximates "expand from where you tapped" (design gate §6) off the
  // triggering click's viewport position, without full geometry tracking —
  // a cheap transform-origin bias rather than a shared-element/FLIP measurement.
  const openLightbox = useCallback((openKind, url, event) => {
    setLightboxAttachment({
      kind: openKind,
      url,
      originX: event ? (event.clientX / window.innerWidth) * 100 : 50,
      originY: event ? (event.clientY / window.innerHeight) * 100 : 50,
    });
  }, []);
  const closeLightbox = useCallback(() => setLightboxAttachment(null), []);

  if (!kind) return null;

  let content = null;

  if (kind === 'image') {
    content = (failed || !message.attachmentUrl)
      ? <div className="attachment-unavailable">Image unavailable</div>
      : (
        <img
          src={message.attachmentUrl}
          alt="photo attachment"
          className="attachment-media attachment-media-expandable"
          style={ratioStyle}
          onLoad={onMediaLoad}
          onError={() => setFailed(true)}
          onClick={(e) => openLightbox('image', message.attachmentUrl, e)}
        />
      );
  } else if (kind === 'video') {
    if (failed || !message.attachmentUrl) {
      content = <div className="attachment-unavailable">Video unavailable</div>;
    } else if (videoPlaying) {
      content = (
        // eslint-disable-next-line jsx-a11y/media-has-caption
        <video src={message.attachmentUrl} className="attachment-media" style={ratioStyle} onLoadedMetadata={onMediaLoad} controls autoPlay onError={() => setFailed(true)} />
      );
    } else {
      content = (
        <button
          type="button"
          className="attachment-media attachment-video-placeholder"
          style={ratioStyle}
          onClick={() => setVideoPlaying(true)}
          aria-label="video attachment, tap to play"
        >
          <PlayCircleOutlined style={{ fontSize: 40, color: 'var(--gold)' }} />
        </button>
      );
    }
  } else if (kind === 'gif') {
    const playableUrl = meta.url || message.attachmentUrl;
    if (failed || !playableUrl) {
      content = <div className="attachment-unavailable">Image unavailable</div>;
    } else if (prefersReducedMotion() && !gifTapped) {
      // The one place reduced-motion changes default behavior, not just
      // disables a decorative transition (design gate §4/§6) — browsers
      // auto-loop an animated <img> gif with no OS-level pause mechanism, so
      // this is handled at the app level: a static preview frame + tap-to-play
      // affordance instead of the looping original. The lightbox trigger
      // below only fires once the GIF is already rendering (post-tap here,
      // or immediately when motion is allowed) — per the design gate, this
      // first tap starts inline playback, it doesn't open the lightbox.
      content = (
        <button
          type="button"
          className="attachment-media attachment-gif-static"
          style={ratioStyle}
          onClick={() => setGifTapped(true)}
          aria-label="GIF attachment, tap to play"
        >
          <img src={meta.preview_url || playableUrl} alt="" className="attachment-media" style={ratioStyle} onLoad={onMediaLoad} onError={() => setFailed(true)} />
          <PlayCircleOutlined className="attachment-gif-play-badge" />
        </button>
      );
    } else {
      content = (
        <img
          src={playableUrl}
          alt="GIF attachment"
          className="attachment-media attachment-media-expandable"
          style={ratioStyle}
          onLoad={onMediaLoad}
          onError={() => setFailed(true)}
          onClick={(e) => openLightbox('gif', playableUrl, e)}
        />
      );
    }
  } else if (kind === 'file') {
    const filename = meta.filename || 'File';
    content = (
      <a
        href={message.attachmentUrl || undefined}
        target="_blank" rel="noreferrer"
        className="attachment-file-row"
        aria-label={`file attachment, ${filename}, download`}
      >
        <FileOutlined style={{ color: 'var(--gold)' }} />
        <span className="attachment-file-name">{filename}</span>
        <DownloadOutlined style={{ color: 'rgba(242,242,242,0.55)' }} />
      </a>
    );
  }

  if (!content) return null;

  return (
    <>
      {content}
      {lightboxAttachment && (
        <AttachmentLightbox
          kind={lightboxAttachment.kind}
          url={lightboxAttachment.url}
          originX={lightboxAttachment.originX}
          originY={lightboxAttachment.originY}
          onClose={closeLightbox}
        />
      )}
    </>
  );
}

// ── GIF picker grid cell (task 20260905-gif-picker-grid-polish, design gate
// §1/§2/§4) ───────────────────────────────────────────────────────────────
// A plain <img src={gif.preview_url}> already animates natively in-browser
// (the backend's preview_url is confirmed to be an animated rendition, not
// a "_still" variant — see gif_search.py's `_shape_giphy`/`_shape_tenor`),
// so no treatment change is needed for standard playback beyond the fixed
// 1:1 crop box in global.css. This component only adds: (a) an eased
// opacity fade-in once the preview has a decoded frame to show, closing the
// black-cell gap reported against the previous static-<img> grid, and (b) a
// reduced-motion path, since CSS has no way to freeze frame advancement on
// a plain animated <img> (that's the browser's own GIF decoder, not a CSS
// animation) — a one-time canvas snapshot on load is the only client-side
// way to present a genuinely static frame. Best-effort: if the provider's
// CDN response taints the canvas (no permissive CORS headers), snapshotting
// throws and this falls back to the plain animated <img> rather than
// blocking the picker on it — respecting reduced motion here is a nice-to-
// have relative to the picker's core job, not a hard requirement (design
// gate §4). Deliberately no play-badge/tap-to-play affordance in the
// reduced-motion state (unlike AttachmentContent's sent-GIF pattern): a
// picker cell's whole tap target already means "select this GIF", so a
// second overlaid affordance the tap doesn't perform would be misleading.
function GifSheetCell({ gif, onPick }) {
  const [loaded, setLoaded] = useState(false);
  const [frozenSrc, setFrozenSrc] = useState(null);
  const imgRef = useRef(null);
  // Read once per mount rather than re-checking on every render — the grid
  // is short-lived (a modal sheet) and the setting doesn't change mid-browse.
  const reducedMotionRef = useRef(prefersReducedMotion());

  const handleLoad = useCallback(() => {
    setLoaded(true);
    if (!reducedMotionRef.current || frozenSrc) return;
    const imgEl = imgRef.current;
    if (!imgEl) return;
    try {
      const canvas = document.createElement('canvas');
      canvas.width = imgEl.naturalWidth || 1;
      canvas.height = imgEl.naturalHeight || 1;
      const ctx = canvas.getContext('2d');
      ctx.drawImage(imgEl, 0, 0);
      setFrozenSrc(canvas.toDataURL());
    } catch (err) {
      // Tainted canvas (no permissive CORS on the provider's CDN response) —
      // best-effort only, keep showing the plain animated <img> (design
      // gate §4).
    }
  }, [frozenSrc]);

  return (
    <button
      type="button"
      className="gif-sheet-cell"
      onClick={() => onPick(gif)}
      aria-label="GIF result"
    >
      <img
        ref={imgRef}
        src={frozenSrc || gif.preview_url}
        alt=""
        className={loaded ? 'gif-sheet-cell-loaded' : undefined}
        onLoad={handleLoad}
      />
    </button>
  );
}

// ── GIF-search sheet (design gate §2) ────────────────────────────────────────
// Task 20260905-gif-picker-default-browse: default/trending "browse" results
// are kept in a state slice fully separate from search `results` (design
// gate §1) — that's what lets clearing the query revert to the browse grid
// instantly from already-held state (§3) instead of refetching.
function GifSearchModal({ open, onClose, onSearchGifs, onBrowseGifs, onSelect }) {
  const [query, setQuery]     = useState('');
  const [results, setResults] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError]     = useState(null);
  const debounceRef = useRef(null);

  const [browseResults, setBrowseResults]     = useState([]);
  const [browseNextToken, setBrowseNextToken] = useState(null);
  const [browseHasMore, setBrowseHasMore]     = useState(false);
  const [browseLoading, setBrowseLoading]     = useState(false);
  const [browseError, setBrowseError]         = useState(false);
  const [loadMoreLoading, setLoadMoreLoading] = useState(false);
  const [loadMoreError, setLoadMoreError]     = useState(false);

  const trimmedQuery = query.trim();
  const showSearch = trimmedQuery.length > 0;

  const fetchBrowse = useCallback(async () => {
    setBrowseLoading(true);
    setBrowseError(false);
    try {
      const { results: gifs, nextPageToken, hasMore } = await onBrowseGifs();
      setBrowseResults(gifs);
      setBrowseNextToken(nextPageToken);
      setBrowseHasMore(hasMore);
    } catch (err) {
      console.error('GIF browse failed:', err);
      setBrowseError(true);
    } finally {
      setBrowseLoading(false);
    }
  }, [onBrowseGifs]);

  useEffect(() => {
    if (!open) {
      setQuery(''); setResults([]); setError(null); setLoading(false);
      setBrowseResults([]); setBrowseNextToken(null); setBrowseHasMore(false);
      setBrowseError(false); setBrowseLoading(false);
      setLoadMoreLoading(false); setLoadMoreError(false);
      return;
    }
    // Fire the default-browse fetch as soon as the sheet opens (design gate
    // §1) — no query field interaction required.
    fetchBrowse();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  useEffect(() => {
    clearTimeout(debounceRef.current);
    setError(null);
    if (!showSearch) { setResults([]); setLoading(false); return; }
    // Debounce ~350ms (design gate §2) — the endpoint is rate-limited
    // server-side at 30/min, so this isn't merely a UX nicety.
    debounceRef.current = setTimeout(async () => {
      setLoading(true);
      try {
        const gifs = await onSearchGifs(trimmedQuery);
        setResults(gifs);
      } catch (err) {
        console.error('GIF search failed:', err);
        setError("Couldn't load GIFs right now — try again in a moment.");
      } finally {
        setLoading(false);
      }
    }, 350);
    return () => clearTimeout(debounceRef.current);
  }, [trimmedQuery, showSearch, onSearchGifs]);

  const handleLoadMore = async () => {
    if (loadMoreLoading) return;
    setLoadMoreLoading(true);
    setLoadMoreError(false);
    try {
      const { results: gifs, nextPageToken, hasMore } = await onBrowseGifs(browseNextToken);
      // Appended, not replaced (design gate §2) — and the grid keeps its
      // current scroll position, no scroll-jump back to the top.
      setBrowseResults(prev => [...prev, ...gifs]);
      setBrowseNextToken(nextPageToken);
      setBrowseHasMore(hasMore);
    } catch (err) {
      console.error('GIF load-more failed:', err);
      setLoadMoreError(true);
    } finally {
      setLoadMoreLoading(false);
    }
  };

  const renderCell = (gif) => (
    <GifSheetCell
      key={gif.id}
      gif={gif}
      onPick={(picked) => { onSelect(picked); onClose(); }}
    />
  );

  return (
    <Modal open={open} onCancel={onClose} footer={null} title="Search GIFs" destroyOnHidden className="gif-sheet-modal">
      <Input
        prefix={<SearchOutlined style={{ color: 'rgba(242,242,242,0.55)' }} />}
        placeholder="Search GIFs"
        value={query}
        onChange={e => setQuery(e.target.value)}
        autoFocus
        style={{ marginBottom: '0.75rem' }}
      />
      {showSearch && loading && (
        <div className="gif-sheet-centered"><Spin /></div>
      )}
      {showSearch && !loading && error && (
        <div className="gif-sheet-centered"><Text style={{ color: 'rgba(242,242,242,0.55)', fontSize: '0.8rem', textAlign: 'center' }}>{error}</Text></div>
      )}
      {showSearch && !loading && !error && results.length === 0 && (
        <div className="gif-sheet-centered">
          <Text style={{ color: 'rgba(242,242,242,0.55)', fontSize: '0.8rem' }}>No results</Text>
        </div>
      )}
      {showSearch && !loading && !error && results.length > 0 && (
        <div className="gif-sheet-grid">
          {results.map(renderCell)}
        </div>
      )}

      {/* Default/trending browse (task 20260905-gif-picker-default-browse) —
          shown whenever no query is typed, including the instant a typed
          query is cleared (from already-held state, no refetch — §3). */}
      {!showSearch && browseLoading && (
        <div className="gif-sheet-centered"><Spin /></div>
      )}
      {!showSearch && !browseLoading && browseError && (
        <div
          className="gif-sheet-centered"
          role="button"
          tabIndex={0}
          onClick={fetchBrowse}
          onKeyDown={e => { if (e.key === 'Enter' || e.key === ' ') fetchBrowse(); }}
          style={{ cursor: 'pointer' }}
        >
          <Text style={{ color: 'rgba(242,242,242,0.55)', fontSize: '0.8rem', textAlign: 'center' }}>
            Couldn't load GIFs right now — try again in a moment.
          </Text>
        </div>
      )}
      {!showSearch && !browseLoading && !browseError && browseResults.length === 0 && (
        <div className="gif-sheet-centered">
          <Text style={{ color: 'rgba(242,242,242,0.55)', fontSize: '0.8rem' }}>No trending GIFs right now.</Text>
        </div>
      )}
      {!showSearch && !browseLoading && !browseError && browseResults.length > 0 && (
        <div className="gif-sheet-grid">
          {browseResults.map(renderCell)}
          {browseHasMore && (
            <Button
              type="text"
              block
              className="gif-sheet-loadmore"
              loading={loadMoreLoading}
              disabled={loadMoreLoading}
              onClick={handleLoadMore}
              aria-label="Load more GIFs"
            >
              {/* AntD's `loading` prop prepends a spinner to whatever
                  children are given — pass no label while loading so the
                  spinner fully replaces the label (design gate §2) rather
                  than showing both side by side. */}
              {loadMoreLoading ? null : (loadMoreError ? "Couldn't load more — tap to retry" : 'Load more')}
            </Button>
          )}
        </div>
      )}
    </Modal>
  );
}

// ── Staged (pre-send) attachment preview chip (design gate §3) ──────────────
function StagedAttachmentChip({ staged, onRemove, onRetry }) {
  const label = staged.kind === 'file' ? (staged.fileName || 'File')
    : staged.kind === 'image' ? 'Photo'
    : staged.kind === 'video' ? 'Video'
    : 'GIF';
  return (
    <div className="staged-attachment-chip">
      <div className="staged-attachment-thumb">
        {staged.kind === 'image' && staged.previewUrl && <img src={staged.previewUrl} alt="" />}
        {staged.kind === 'video' && staged.previewUrl && (
          // eslint-disable-next-line jsx-a11y/media-has-caption
          <video src={staged.previewUrl} muted />
        )}
        {staged.kind === 'gif' && staged.previewUrl && <img src={staged.previewUrl} alt="" />}
        {staged.kind === 'file' && <FileOutlined style={{ color: 'var(--gold)' }} />}
      </div>
      <div className="staged-attachment-meta">
        <Text style={{ fontSize: '0.7rem', color: 'rgba(242,242,242,0.55)' }}>{label}</Text>
        {staged.uploadState === 'failed' && (
          <button type="button" className="staged-attachment-retry" onClick={onRetry}>
            Couldn't send — tap to retry
          </button>
        )}
      </div>
      {staged.uploadState === 'uploading' && <Spin size="small" />}
      <button
        type="button"
        className="staged-attachment-remove"
        onClick={onRemove}
        aria-label="Remove attachment"
      >
        <CloseCircleFilled style={{ color: 'rgba(242,242,242,0.55)' }} />
      </button>
    </div>
  );
}

// ── Message actions (task 20261001-message-threads) ──────────────────────────
// What a message can offer, by where it is shown:
//  - thread message: Copy only (there is no delete route for thread messages);
//  - group-chat message: Start thread (threads on), Copy, Delete (author only,
//    message_delete on); DMs: Copy only.
// Copy is hidden for image/video/file; a GIF copies its URL.
export function copyTextFor(m) {
  if (m.attachmentKind === 'gif') return (m.attachmentMeta && m.attachmentMeta.url) || m.attachmentUrl || '';
  if (m.attachmentKind) return '';
  return m.text ? String(m.text) : '';
}

async function copyToClipboard(text) {
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch (err) {
    // Fall through to the legacy path.
  }
  try {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand && document.execCommand('copy');
    document.body.removeChild(ta);
    return !!ok;
  } catch (err) {
    return false;
  }
}

// Undo toast stack for deleted messages (design: "Message deleted  [Undo]",
// role=status, a real button, auto-dismiss after the server's undo window).
function UndoToasts({ toasts, onUndo, onExpire }) {
  return (
    <div className="msg-undo-stack" role="status" aria-live="polite">
      {toasts.map(t => <UndoToast key={t.id} toast={t} onUndo={onUndo} onExpire={onExpire} />)}
    </div>
  );
}

function UndoToast({ toast, onUndo, onExpire }) {
  useEffect(() => {
    const timer = setTimeout(() => onExpire(toast.id), toast.seconds * 1000);
    return () => clearTimeout(timer);
  }, [toast.id, toast.seconds, onExpire]);
  return (
    <div className="msg-undo-toast">
      <span>Message deleted</span>
      <button type="button" className="msg-undo-btn" onClick={() => onUndo(toast.id)}>Undo</button>
    </div>
  );
}

// ── Chat thread (iMessage style) ──────────────────────────────────────────────

export default function ChatThread({
  contact, messages, groupMembers, user, onBack, onSend,
  onRequestUploadUrl, onUploadToS3, onSearchGifs, onBrowseGifs,
  sessions, activeSessionId, talkingUserId,
  onJoinSession, onLeaveSession, onOpenSessionCreator,
  joinError, onClearJoinError,
  onEditSession, onDeleteSession, onNavigateVerse,
  videoEnabled, videoTiles, onToggleVideo, bindVideoTile,
  onGroupChanged, onGroupGone,
  // Task 20261001-chat-pagination: { paged, hasMore, loading, error,
  // loadedCount, loadedTick } for the open thread plus the older-page loader.
  // Both optional: absent means a legacy full-history thread.
  olderPage, onLoadOlder,
  // Task 20261001-message-threads. `thread` set = this view is a thread over
  // the group chat (one level deep): `messages`/`olderPage`/`onSend` are then
  // the thread's. threadLoad: 'idle' | 'loading' | 'error'. restoredDraft:
  // { tick, text } hands a failed send's text back to the composer.
  thread, threadLoad, onRetryThread, restoredDraft,
  onStartThread, onDeleteMessage, onRestoreMessage,
  // Task 20261003-web-reader-ios-parity: friends + add-members for group info.
  friends, onAddGroupMembers, onRetryMessage,
}) {
  const inThread = !!thread;
  const caps = useCapabilities();
  const features = (caps && caps.features) || {};
  const threadHeadingRef = useRef(null);
  const [undoToasts, setUndoToasts] = useState([]);
  const [text, setText]               = useState('');
  // Task 20260929-group-info-panel: replaces the old inline showMembers strip;
  // the member list is hosted inside GroupInfoPanel.
  const [showGroupInfo, setShowGroupInfo] = useState(false);
  const [panelLightbox, setPanelLightbox] = useState(null);
  const groupInfoBtnRef = useRef(null);
  const messageInputRef = useRef(null);
  const [showAttachMenu, setShowAttachMenu] = useState(false);
  const [showGifSheet, setShowGifSheet]     = useState(false);
  const [staged, setStaged]                 = useState(null); // { kind, file, previewUrl, fileName, meta, uploadState, objectKey }
  const [attachmentError, setAttachmentError] = useState(null);
  const endRef = useRef(null);
  const photoVideoInputRef = useRef(null);
  const fileInputRef       = useRef(null);

  const scrollerRef = useRef(null);
  // Scroll anchor captured when an older page is requested: the first visible
  // message (by id) and its offset from the scroller's top.
  const anchorRef = useRef(null);
  const prevLastKeyRef = useRef(null);
  const nearBottomRef = useRef(true);
  const [newBelow, setNewBelow] = useState(false);
  const paged = !!olderPage?.paged;
  const hasMore = !!olderPage?.hasMore;
  const loadingOlder = !!olderPage?.loading;
  const olderError = !!olderPage?.error;

  const lastKeyOf = (list) => {
    const last = list[list.length - 1];
    return last ? (last.key ?? `n${list.length}`) : null;
  };

  const captureAnchor = useCallback(() => {
    const sc = scrollerRef.current;
    if (!sc) return;
    const top = sc.getBoundingClientRect().top;
    const els = sc.querySelectorAll('[data-msg-id]');
    for (const el of els) {
      const r = el.getBoundingClientRect();
      if (r.bottom > top) {
        anchorRef.current = { id: el.getAttribute('data-msg-id'), offset: r.top - top };
        return;
      }
    }
    anchorRef.current = null;
  }, []);

  const requestOlder = useCallback(() => {
    if (!onLoadOlder || !hasMore || loadingOlder) return;
    captureAnchor();
    onLoadOlder();
  }, [onLoadOlder, hasMore, loadingOlder, captureAnchor]);

  // Keep the viewport still when an older page is prepended (anchor by message
  // id); otherwise scroll to the newest message only when the thread was just
  // opened, the user sent it, or they are already near the bottom. A live
  // message that arrives while scrolled up raises the "New messages" pill.
  useLayoutEffect(() => {
    const sc = scrollerRef.current;
    const anchor = anchorRef.current;
    if (anchor && sc) {
      anchorRef.current = null;
      const el = Array.from(sc.querySelectorAll('[data-msg-id]')).find(e => e.getAttribute('data-msg-id') === anchor.id);
      if (el) {
        const delta = (el.getBoundingClientRect().top - sc.getBoundingClientRect().top) - anchor.offset;
        if (delta) sc.scrollTop += delta;
        return;
      }
    }
    const lastKey = lastKeyOf(messages);
    const prevKey = prevLastKeyRef.current;
    prevLastKeyRef.current = lastKey;
    if (lastKey === prevKey) return;
    const last = messages[messages.length - 1];
    const firstLoad = prevKey === null;
    if (firstLoad || nearBottomRef.current || last?.mine) {
      endRef.current?.scrollIntoView?.({ behavior: (firstLoad || prefersReducedMotion()) ? 'auto' : 'smooth' });
      setNewBelow(false);
    } else {
      setNewBelow(true);
    }
  }, [messages]);

  // Thread view: focus moves to the thread heading on open (screen readers
  // announce where they are), then to the composer once an empty thread loads.
  useEffect(() => {
    if (inThread) threadHeadingRef.current?.focus?.({ preventScroll: true });
  }, [inThread, thread?.id]);
  useEffect(() => {
    if (inThread && threadLoad === 'idle' && messages.length === 0) messageInputRef.current?.focus?.();
  }, [inThread, threadLoad, messages.length]);

  // A failed thread send gives its text back (never lose what was typed).
  useEffect(() => {
    if (restoredDraft && restoredDraft.text) {
      setText(prev => prev || restoredDraft.text);
      messageInputRef.current?.focus?.();
    }
  }, [restoredDraft]);

  // A finished (or failed) older-page request never leaves a stale anchor.
  useEffect(() => { if (!loadingOlder) anchorRef.current = null; }, [loadingOlder]);

  // A new thread starts clean.
  useEffect(() => {
    prevLastKeyRef.current = null;
    nearBottomRef.current = true;
    anchorRef.current = null;
    setNewBelow(false);
  }, [contact?.id]);

  // Content too short to scroll still needs to be able to reach older pages.
  useEffect(() => {
    const sc = scrollerRef.current;
    if (!sc || !paged || !hasMore || loadingOlder || olderError) return;
    if (sc.scrollHeight <= sc.clientHeight) requestOlder();
  }, [messages, paged, hasMore, loadingOlder, olderError, requestOlder]);

  const handleScroll = useCallback((e) => {
    const sc = e.currentTarget;
    const nearBottom = sc.scrollHeight - sc.scrollTop - sc.clientHeight < 80;
    nearBottomRef.current = nearBottom;
    if (nearBottom) setNewBelow(false);
    if (paged && sc.scrollTop < 120) requestOlder();
  }, [paged, requestOlder]);

  const jumpToNewest = useCallback(() => {
    endRef.current?.scrollIntoView?.({ behavior: prefersReducedMotion() ? 'auto' : 'smooth' });
    setNewBelow(false);
  }, []);

  // Screen-reader announcement after an older page lands.
  const loadedAnnouncement = olderPage?.loadedTick
    ? `${olderPage.loadedCount} earlier message${olderPage.loadedCount === 1 ? '' : 's'} loaded`
    : '';

  // Staged previewUrl is a `URL.createObjectURL(file)` blob URL — release it
  // once no longer staged/replaced, so this doesn't leak memory across a long
  // session.
  useEffect(() => () => {
    if (staged?.previewUrl && staged.kind !== 'gif') URL.revokeObjectURL(staged.previewUrl);
  }, [staged]);

  const startUpload = useCallback((attachment) => {
    setStaged(prev => (prev && prev.id === attachment.id) ? { ...prev, uploadState: 'uploading' } : prev);
    onRequestUploadUrl(attachment.kind, attachment.file.type, attachment.file.size)
      .then(info => onUploadToS3(info, attachment.file).then(() => info))
      .then(info => {
        setStaged(prev => (prev && prev.id === attachment.id) ? { ...prev, uploadState: 'uploaded', objectKey: info.object_key } : prev);
      })
      .catch(err => {
        console.error('Attachment upload failed:', err);
        setStaged(prev => (prev && prev.id === attachment.id) ? { ...prev, uploadState: 'failed' } : prev);
      });
  }, [onRequestUploadUrl, onUploadToS3]);

  const stageFile = useCallback((file, forcedKind) => {
    const kind = forcedKind || kindForFile(file);
    const limits = ATTACHMENT_LIMITS[kind];
    if (limits && file.size > limits.maxBytes) {
      setAttachmentError(limits.oversizeCopy);
      return;
    }
    setAttachmentError(null);
    // A blob: URL works directly as an <img>/<video> src with no upload
    // round trip — used for both the staged-preview chip and (for image/
    // video) the sender's own optimistic echo, since the server's freshly
    // presigned attachment_url is only ever resolved after a real upload +
    // round trip, and the WS self-echo guard means this client never gets
    // its own message delivered back to it (ChatThread.jsx's design gate
    // §4 rendering falls back to this local URL when attachmentUrl is
    // absent, matching iOS's LocalAttachmentPreview approach).
    const previewUrl = (kind === 'image' || kind === 'video') ? URL.createObjectURL(file) : null;
    const meta = kind === 'file' ? { filename: file.name } : {};
    const attachment = {
      id: `${Date.now()}-${Math.random()}`,
      kind, file, previewUrl, fileName: file.name, meta,
      uploadState: 'uploading', objectKey: null,
    };
    setStaged(attachment);
    startUpload(attachment);
  }, [startUpload]);

  const handlePhotoVideoChange = (e) => {
    const file = e.target.files?.[0];
    e.target.value = '';
    if (file) stageFile(file);
  };

  const handleFileChange = (e) => {
    const file = e.target.files?.[0];
    e.target.value = '';
    if (file) stageFile(file, 'file');
  };

  const handleGifSelected = (gif) => {
    setAttachmentError(null);
    setStaged({
      id: `${Date.now()}-${Math.random()}`,
      kind: 'gif', file: null, previewUrl: gif.preview_url, fileName: null,
      meta: { url: gif.url, preview_url: gif.preview_url, width: gif.width, height: gif.height },
      uploadState: 'idle', objectKey: null,
    });
  };

  const canSend = (() => {
    const hasText = !!text.trim();
    if (!staged) return hasText;
    if (staged.uploadState === 'uploading' || staged.uploadState === 'failed') return false;
    return true;
  })();

  const handleSend = () => {
    if (!canSend) return;
    const trimmed = text.trim();
    if (!trimmed && !staged) return;
    if (staged) {
      const attachment = {
        kind: staged.kind,
        meta: staged.meta,
        objectKey: staged.objectKey,
        localUrl: (staged.kind === 'image' || staged.kind === 'video') ? staged.previewUrl : null,
      };
      onSend(trimmed, attachment);
    } else {
      // No second argument for a plain text-only send — keeps `onSend`'s
      // call shape identical to before this feature for the common case
      // (useMessaging.js's `sendMessage(text, attachment = null)` already
      // defaults the omitted param).
      onSend(trimmed);
    }
    setText('');
    setStaged(null);
    setAttachmentError(null);
  };

  const isGroup = contact?.type === 'group';
  // Who a joined caller can ring (task 20261003-web-reader-ios-parity):
  // the group's other members, or the one friend in a DM. The server
  // re-validates every target against the real roster.
  const ringCandidates = isGroup
    ? (groupMembers || [])
    : (contact?.type === 'friend' && contact.toUsers?.[0]
      ? [{ user_id: contact.toUsers[0], username: contact.name }]
      : []);
  const dismissToast = useCallback((id) => setUndoToasts(prev => prev.filter(t => t.id !== id)), []);

  const handleDelete = useCallback(async (m) => {
    if (!onDeleteMessage) return;
    messageInputRef.current?.focus?.();
    const res = await onDeleteMessage(m);
    if (res) {
      setUndoToasts(prev => [...prev, { id: res.id, seconds: res.undoSeconds || DEFAULT_UNDO_SECONDS }]);
    }
  }, [onDeleteMessage]);

  const handleUndo = useCallback(async (id) => {
    dismissToast(id);
    if (onRestoreMessage) await onRestoreMessage(id);
  }, [dismissToast, onRestoreMessage]);

  const actionsFor = (m) => {
    const list = [];
    const settled = !!m.id && !m.pending;
    if (!inThread && isGroup && features.threads === true && settled && onStartThread) {
      list.push({ key: 'thread', label: 'Start thread', icon: <BranchesOutlined />, onSelect: () => onStartThread(m) });
    }
    const copyText = copyTextFor(m);
    if (copyText) {
      list.push({
        key: 'copy', label: 'Copy', icon: <CopyOutlined />,
        onSelect: async () => {
          const ok = await copyToClipboard(copyText);
          if (ok) antMessage.success({ content: 'Copied', key: 'fs-copy', duration: 1.5 });
          else antMessage.error({ content: "Couldn't copy that message.", key: 'fs-copy', duration: 2 });
        },
      });
    }
    if (!inThread && isGroup && features.message_delete === true && m.mine && settled && onDeleteMessage) {
      list.push({ key: 'delete', label: 'Delete', icon: <DeleteOutlined />, destructive: true, onSelect: () => handleDelete(m) });
    }
    return list;
  };

  // Task 20260904-attach-picker-layout-polish: same gold-gradient pill
  // treatment already used inline for NotesPanel.jsx's "New Note"/"New" and
  // AgentChatPanel.jsx's "New Agent Chat" buttons -- reused verbatim here
  // rather than a new button style, per Q1/Q12 (hold to the established
  // system once it exists).
  const attachPillStyle = {
    background: 'linear-gradient(135deg, var(--gold-light), var(--gold) 60%, var(--gold-dim))',
    border: 'none',
    color: 'var(--ink)',
    fontFamily: "'Space Grotesk', sans-serif",
    fontWeight: 600,
    borderRadius: 999,
    minHeight: 44,
  };

  const attachMenuContent = (
    <div className="attach-menu">
      <Button className="attach-menu-row" icon={<PictureOutlined />} style={attachPillStyle}
        onClick={() => { setShowAttachMenu(false); photoVideoInputRef.current?.click(); }}>
        Photo &amp; Video
      </Button>
      <Button className="attach-menu-row" icon={<FileOutlined />} style={attachPillStyle}
        onClick={() => { setShowAttachMenu(false); fileInputRef.current?.click(); }}>
        File
      </Button>
      <Button className="attach-menu-row" icon={<SmileOutlined />} style={attachPillStyle}
        onClick={() => { setShowAttachMenu(false); setShowGifSheet(true); }}>
        GIF
      </Button>
    </div>
  );

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', overflow: 'hidden', position: 'relative' }}>
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem', padding: '0.8rem 1rem', borderBottom: '1px solid rgba(255,255,255,0.09)', flexShrink: 0 }}>
        <Button type="text" icon={<ArrowLeftOutlined />} onClick={onBack}
          aria-label={inThread ? `Back to ${contact?.name || 'group chat'}` : undefined}
          style={{ color: 'rgba(255,198,26,0.65)', padding: '0 4px', minWidth: 44, minHeight: 44 }} />
        {inThread ? (
          <h2
            ref={threadHeadingRef}
            tabIndex={-1}
            className="thread-header-title"
            aria-label={`Thread: ${thread.title || 'Thread'}`}
          >
            <span className="thread-header-group">{contact?.name}</span>
            <span className="thread-header-name">{thread.title || 'Thread'}</span>
          </h2>
        ) : contact?.type === 'group' ? (
          <button
            ref={groupInfoBtnRef}
            type="button"
            className="group-info-header-btn"
            aria-haspopup="dialog"
            aria-expanded={showGroupInfo}
            aria-label={`Group info, ${contact.name}`}
            onClick={() => setShowGroupInfo(v => !v)}
          >
            <Avatar size={32} src={contact.photoUrl} style={{ background: 'rgba(255,198,26,0.12)', color: 'var(--gold)', flexShrink: 0 }}>
              {(contact.name || '?')[0].toUpperCase()}
            </Avatar>
            <span className="group-info-header-name">{contact.name}</span>
            {/* Visible label (task 20261003-web-reader-ios-parity step 5): the lone icon
                was easy to miss, and group info holds members, invite links,
                announcements, threads and Add friends. */}
            <span className="group-info-header-hint"><TeamOutlined aria-hidden="true" /> Group info</span>
          </button>
        ) : (
          <Text
            strong
            style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.88rem', color: 'var(--parchment)', flex: 1 }}
          >
            {contact?.name}
          </Text>
        )}
        {!inThread && <SessionsMenu
          sessions={sessions}
          activeSessionId={activeSessionId}
          joinError={joinError}
          onClearJoinError={onClearJoinError}
          onJoin={onJoinSession}
          onLeave={onLeaveSession}
          onEdit={onEditSession}
          onDelete={onDeleteSession}
          onOpenSessionCreator={onOpenSessionCreator}
          user={user}
          talkingUserId={talkingUserId}
          onNavigateVerse={onNavigateVerse}
          videoEnabled={videoEnabled}
          videoTiles={videoTiles}
          onToggleVideo={onToggleVideo}
          bindVideoTile={bindVideoTile}
          ringCandidates={ringCandidates}
        />}
      </div>

      {inThread && (
        <div className="thread-root-card" role="group" aria-label="Original message">
          <span className="thread-root-chip">Thread</span>
          {thread.root_deleted
            ? <p className="thread-root-text thread-root-deleted">Original message deleted</p>
            : <p className="thread-root-text">{thread.root_preview || ''}</p>}
        </div>
      )}

      {/* Task 20260929-announcement-push-widget: groups only, directly under the header. */}
      {!inThread && ANNOUNCEMENTS_ENABLED && contact?.type === 'group' && user?.user_id && (
        <GroupAnnouncementWidget
          userId={user.user_id}
          groupId={contact.id}
          onAfterDismiss={() => messageInputRef.current?.focus?.()}
        />
      )}

      {/* Joined session stays pinned (always mounted) so call tiles/controls survive the Sessions menu closing. */}
      {!inThread && (() => {
        const pinned = (sessions || []).find(x => x.id === activeSessionId);
        return pinned ? (
          <SessionCard
            session={pinned}
            user={user}
            activeSessionId={activeSessionId}
            talkingUserId={talkingUserId}
            onJoin={onJoinSession}
            onLeave={onLeaveSession}
            joinError={joinError}
            onClearJoinError={onClearJoinError}
            onEdit={onEditSession}
            onDelete={onDeleteSession}
            onNavigateVerse={onNavigateVerse}
            videoEnabled={videoEnabled}
            videoTiles={videoTiles}
            onToggleVideo={onToggleVideo}
            bindVideoTile={bindVideoTile}
            ringCandidates={ringCandidates}
          />
        ) : null;
      })()}

      {/* Messages */}
      <div style={{ flex: 1, minHeight: 0, position: 'relative', display: 'flex', flexDirection: 'column' }}>
      <div
        ref={scrollerRef}
        onScroll={handleScroll}
        style={{ flex: 1, overflowY: 'auto', padding: '0.75rem 0.85rem', display: 'flex', flexDirection: 'column', gap: '0.45rem' }}
      >
        <div
          role="status"
          aria-live="polite"
          style={{ position: 'absolute', width: 1, height: 1, overflow: 'hidden', clip: 'rect(0 0 0 0)', whiteSpace: 'nowrap' }}
        >
          {loadedAnnouncement}
        </div>
        {paged && loadingOlder && (
          <div style={{ textAlign: 'center', padding: '0.25rem 0' }} aria-label="Loading earlier messages">
            <Spin size="small" />
          </div>
        )}
        {paged && olderError && !loadingOlder && (
          <div style={{ textAlign: 'center', padding: '0.25rem 0' }}>
            <Button type="link" size="small" onClick={requestOlder} style={{ color: 'rgba(255,198,26,0.75)', fontSize: '0.72rem' }}>
              Couldn't load earlier messages. Retry
            </Button>
          </div>
        )}
        {paged && !hasMore && !loadingOlder && !olderError && messages.length > 0 && (
          <div style={{ textAlign: 'center', padding: '0.25rem 0' }}>
            <Text style={{ fontSize: '0.68rem', color: 'rgba(242,242,242,0.3)', fontFamily: "'Inter', sans-serif" }}>Start of conversation</Text>
          </div>
        )}
        {inThread && threadLoad === 'loading' && messages.length === 0 && (
          <div style={{ textAlign: 'center', padding: '2rem 1rem' }} aria-label="Loading thread"><Spin size="small" /></div>
        )}
        {inThread && threadLoad === 'error' && (
          <div style={{ textAlign: 'center', padding: '1.5rem 1rem' }}>
            <Button type="link" size="small" onClick={onRetryThread} style={{ color: 'rgba(255,198,26,0.75)', fontSize: '0.72rem' }}>
              Couldn't load this thread. Retry
            </Button>
          </div>
        )}
        {messages.length === 0 && !(inThread && threadLoad !== 'idle') && (
          <div style={{ textAlign: 'center', padding: '2rem 1rem' }}>
            <Text style={{ fontSize: '0.72rem', color: 'rgba(242,242,242,0.22)', fontFamily: "'Inter', sans-serif" }}>
              {inThread ? 'Start the conversation' : 'No messages yet. Say hello!'}
            </Text>
          </div>
        )}
        {messages.map((m, i) => {
          // Task 20260923-chat-phantom-empty-bubbles: belt-and-suspenders
          // render guard. useMessaging.js's WS onmessage handler now
          // explicitly discriminates ping/error control frames before they
          // ever reach `messages`, but this skips rendering any entry that
          // still has no text, no attachment, and no timestamp -- so any
          // other future source of a content-less entry fails safe as no
          // bubble at all, rather than a small empty/borderless-content one.
          if (!(m.text && String(m.text).trim()) && !m.attachmentKind && !m.timestamp) {
            return null;
          }
          const isMedia = ['image', 'video', 'gif'].includes(m.attachmentKind);
          const ariaLabel = m.attachmentKind === 'image' ? `${m.sender || 'You'}: photo attachment`
            : m.attachmentKind === 'video' ? `${m.sender || 'You'}: video attachment, tap to play`
            : m.attachmentKind === 'gif'   ? `${m.sender || 'You'}: GIF attachment`
            : m.attachmentKind === 'file'  ? `${m.sender || 'You'}: file attachment, ${m.attachmentMeta?.filename || 'file'}, download`
            : undefined;
          return (
            <ActionableBubble
              key={m.key ?? `i${i}`}
              data-msg-id={m.key ?? undefined}
              className={`msg-bubble ${m.mine ? 'sent' : 'received'} ${isMedia ? 'msg-bubble-media' : ''}${m.failed ? ' msg-bubble-failed' : ''}`}
              aria-label={ariaLabel}
              mine={!!m.mine}
              actions={actionsFor(m)}
            >
              {!m.mine && m.sender && !isMedia && <div className="msg-bubble-sender">{m.sender}</div>}
              {m.attachmentKind ? <AttachmentContent message={m} /> : m.text}
              {m.attachmentKind && m.text && (
                <div className={isMedia ? 'attachment-caption' : undefined}>{m.text}</div>
              )}
              {m.failed ? (
                <button
                  type="button"
                  className="msg-retry-btn"
                  onClick={() => onRetryMessage?.(m)}
                  disabled={!onRetryMessage}
                  aria-label="Message not sent. Tap to retry"
                >
                  <ExclamationCircleOutlined aria-hidden="true" /> Couldn&apos;t send. Tap to retry
                </button>
              ) : m.timestamp && (
                <div className="msg-bubble-meta">
                  {new Date(m.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                </div>
              )}
            </ActionableBubble>
          );
        })}
        <div ref={endRef} />
      </div>
      {newBelow && (
        <Button
          size="small"
          onClick={jumpToNewest}
          style={{ position: 'absolute', bottom: 8, left: '50%', transform: 'translateX(-50%)', zIndex: 2 }}
        >
          New messages
        </Button>
      )}
      {undoToasts.length > 0 && <UndoToasts toasts={undoToasts} onUndo={handleUndo} onExpire={dismissToast} />}
      </div>

      {/* Staged attachment + inline error */}
      {staged && (
        <StagedAttachmentChip
          staged={staged}
          onRemove={() => { setStaged(null); setAttachmentError(null); }}
          onRetry={() => startUpload(staged)}
        />
      )}
      {attachmentError && (
        <div style={{ padding: '0 0.9rem', color: 'rgba(242,242,242,0.55)', fontSize: '0.7rem' }}>{attachmentError}</div>
      )}

      {/* Input */}
      <div style={{ display: 'flex', gap: '0.4rem', padding: '0.65rem 0.8rem', flexShrink: 0, alignItems: 'flex-end' }}>
        <Popover
          open={showAttachMenu}
          onOpenChange={setShowAttachMenu}
          trigger="click"
          placement="top"
          content={attachMenuContent}
          overlayClassName="attach-menu-popover"
        >
          <Button
            type="text"
            icon={<PlusOutlined />}
            aria-label="Attach a photo, video, file, or GIF"
            style={{ color: 'rgba(255,198,26,0.75)', flexShrink: 0, width: 44, height: 44 }}
          />
        </Popover>
        {/* Task 20260917-desktop-gif-image-render-bug (send-side): these two
            inputs used to be `style={{ display: 'none' }}`. That's a known
            WebKit gotcha -- a `display: none` <input type="file"> doesn't
            reliably invoke the native open-panel when `.click()`'d
            programmatically, because a `display: none` element is removed
            from the render tree entirely, and some WKWebView versions skip
            wiring the click through to WKUIDelegate's
            runOpenPanelWithParameters for an element that was never laid
            out/painted -- even though the same code fires the panel fine in
            Chrome/Firefox (web), which don't share that restriction. The
            desktop app embeds exactly this WKWebView (see
            src-tauri/src/lib.rs), so this is the most likely explanation for
            "attach menu opens, but clicking Photo & Video / File does
            nothing" being desktop-only despite byte-identical frontend code.
            Fix: keep the input out of layout flow and invisible via
            `.hidden-file-input` (position: absolute, 1x1px, opacity: 0,
            overflow hidden -- see global.css) instead of `display: none`, so
            the element is still laid out/painted (just imperceptibly) and
            `.click()` reaches the native panel consistently. No visual or
            behavioral change on web/iOS. */}
        <input ref={photoVideoInputRef} type="file" accept="image/*,video/*" className="hidden-file-input" onChange={handlePhotoVideoChange} />
        <input ref={fileInputRef} type="file" accept={ATTACHMENT_LIMITS.file.accept} className="hidden-file-input" onChange={handleFileChange} />

        <Input
          ref={messageInputRef}
          value={text}
          onChange={e => setText(e.target.value)}
          onPressEnter={handleSend}
          placeholder="Message…"
          style={{ flex: 1, borderRadius: 20, fontSize: '0.82rem' }}
        />
        <Button
          type="primary" shape="circle" icon={<SendOutlined />}
          onClick={handleSend}
          disabled={!canSend}
          aria-label="Send message"
          style={{ flexShrink: 0 }}
        />
      </div>

      {!inThread && <GroupInfoPanel
        open={showGroupInfo && contact?.type === 'group'}
        onClose={() => { setShowGroupInfo(false); groupInfoBtnRef.current?.focus(); }}
        contact={contact}
        user={user}
        groupMembers={groupMembers}
        friends={friends}
        onAddMembers={onAddGroupMembers}
        onGroupChanged={onGroupChanged}
        onGroupGone={() => { setShowGroupInfo(false); onGroupGone?.(contact); }}
        onOpenLightbox={(kind, url, e) => setPanelLightbox({
          kind, url,
          originX: e ? (e.clientX / window.innerWidth) * 100 : 50,
          originY: e ? (e.clientY / window.innerHeight) * 100 : 50,
        })}
      />}
      {panelLightbox && (
        <AttachmentLightbox
          kind={panelLightbox.kind}
          url={panelLightbox.url}
          originX={panelLightbox.originX}
          originY={panelLightbox.originY}
          onClose={() => setPanelLightbox(null)}
        />
      )}

      <GifSearchModal
        open={showGifSheet}
        onClose={() => setShowGifSheet(false)}
        onSearchGifs={onSearchGifs}
        onBrowseGifs={onBrowseGifs}
        onSelect={handleGifSelected}
      />
    </div>
  );
}

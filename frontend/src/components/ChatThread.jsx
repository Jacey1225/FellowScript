import React, { useState, useEffect, useRef, useCallback } from 'react';
import { Button, Avatar, Typography, Input, Popover, Modal, Spin } from 'antd';
import {
  SendOutlined, ArrowLeftOutlined, TeamOutlined, PlusOutlined,
  PictureOutlined, FileOutlined, SmileOutlined, PlayCircleOutlined,
  DownloadOutlined, CloseCircleFilled, SearchOutlined,
} from '@ant-design/icons';
import SessionWidget from './SessionWidget.jsx';

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

// ── Per-kind attachment rendering inside the existing message bubble (design gate §4) ──
function AttachmentContent({ message }) {
  const [videoPlaying, setVideoPlaying] = useState(false);
  const [gifTapped, setGifTapped] = useState(false);
  const [failed, setFailed] = useState(false);
  const kind = message.attachmentKind;
  const meta = message.attachmentMeta || {};

  if (!kind) return null;

  if (kind === 'image') {
    if (failed || !message.attachmentUrl) {
      return <div className="attachment-unavailable">Image unavailable</div>;
    }
    return (
      <img
        src={message.attachmentUrl}
        alt="photo attachment"
        className="attachment-media"
        onError={() => setFailed(true)}
      />
    );
  }

  if (kind === 'video') {
    if (failed || !message.attachmentUrl) {
      return <div className="attachment-unavailable">Video unavailable</div>;
    }
    if (videoPlaying) {
      return (
        // eslint-disable-next-line jsx-a11y/media-has-caption
        <video src={message.attachmentUrl} className="attachment-media" controls autoPlay onError={() => setFailed(true)} />
      );
    }
    return (
      <button
        type="button"
        className="attachment-media attachment-video-placeholder"
        onClick={() => setVideoPlaying(true)}
        aria-label="video attachment, tap to play"
      >
        <PlayCircleOutlined style={{ fontSize: 40, color: 'var(--gold)' }} />
      </button>
    );
  }

  if (kind === 'gif') {
    const playableUrl = meta.url || message.attachmentUrl;
    if (failed || !playableUrl) {
      return <div className="attachment-unavailable">Image unavailable</div>;
    }
    // The one place reduced-motion changes default behavior, not just
    // disables a decorative transition (design gate §4/§6) — browsers
    // auto-loop an animated <img> gif with no OS-level pause mechanism, so
    // this is handled at the app level: a static preview frame + tap-to-play
    // affordance instead of the looping original.
    if (prefersReducedMotion() && !gifTapped) {
      return (
        <button
          type="button"
          className="attachment-media attachment-gif-static"
          onClick={() => setGifTapped(true)}
          aria-label="GIF attachment, tap to play"
        >
          <img src={meta.preview_url || playableUrl} alt="" className="attachment-media" onError={() => setFailed(true)} />
          <PlayCircleOutlined className="attachment-gif-play-badge" />
        </button>
      );
    }
    return <img src={playableUrl} alt="GIF attachment" className="attachment-media" onError={() => setFailed(true)} />;
  }

  if (kind === 'file') {
    const filename = meta.filename || 'File';
    return (
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

  return null;
}

// ── GIF-search sheet (design gate §2) ────────────────────────────────────────
function GifSearchModal({ open, onClose, onSearchGifs, onSelect }) {
  const [query, setQuery]     = useState('');
  const [results, setResults] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError]     = useState(null);
  const debounceRef = useRef(null);

  useEffect(() => {
    if (!open) { setQuery(''); setResults([]); setError(null); setLoading(false); }
  }, [open]);

  useEffect(() => {
    clearTimeout(debounceRef.current);
    setError(null);
    const trimmed = query.trim();
    if (!trimmed) { setResults([]); setLoading(false); return; }
    // Debounce ~350ms (design gate §2) — the endpoint is rate-limited
    // server-side at 30/min, so this isn't merely a UX nicety.
    debounceRef.current = setTimeout(async () => {
      setLoading(true);
      try {
        const gifs = await onSearchGifs(trimmed);
        setResults(gifs);
      } catch (err) {
        console.error('GIF search failed:', err);
        setError("Couldn't load GIFs right now — try again in a moment.");
      } finally {
        setLoading(false);
      }
    }, 350);
    return () => clearTimeout(debounceRef.current);
  }, [query, onSearchGifs]);

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
      {loading && (
        <div className="gif-sheet-centered"><Spin /></div>
      )}
      {!loading && error && (
        <div className="gif-sheet-centered"><Text style={{ color: 'rgba(242,242,242,0.55)', fontSize: '0.8rem', textAlign: 'center' }}>{error}</Text></div>
      )}
      {!loading && !error && results.length === 0 && (
        <div className="gif-sheet-centered">
          <Text style={{ color: 'rgba(242,242,242,0.55)', fontSize: '0.8rem' }}>
            {query.trim() ? 'No results' : 'Search for a GIF to send.'}
          </Text>
        </div>
      )}
      {!loading && !error && results.length > 0 && (
        <div className="gif-sheet-grid">
          {results.map(gif => (
            <button
              type="button"
              key={gif.id}
              className="gif-sheet-cell"
              onClick={() => { onSelect(gif); onClose(); }}
              aria-label="GIF result"
            >
              <img src={gif.preview_url} alt="" />
            </button>
          ))}
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

// ── Chat thread (iMessage style) ──────────────────────────────────────────────

export default function ChatThread({
  contact, messages, groupMembers, user, onBack, onSend,
  onRequestUploadUrl, onUploadToS3, onSearchGifs,
  sessions, activeSessionId, talkingUserId,
  onJoinSession, onLeaveSession, onOpenSessionCreator,
  joinError, onClearJoinError,
  onEditSession, onDeleteSession, onNavigateVerse,
  videoEnabled, videoTiles, onToggleVideo, bindVideoTile,
}) {
  const [text, setText]               = useState('');
  const [showMembers, setShowMembers] = useState(false);
  const [showAttachMenu, setShowAttachMenu] = useState(false);
  const [showGifSheet, setShowGifSheet]     = useState(false);
  const [staged, setStaged]                 = useState(null); // { kind, file, previewUrl, fileName, meta, uploadState, objectKey }
  const [attachmentError, setAttachmentError] = useState(null);
  const endRef = useRef(null);
  const photoVideoInputRef = useRef(null);
  const fileInputRef       = useRef(null);

  useEffect(() => { endRef.current?.scrollIntoView({ behavior: 'smooth' }); }, [messages]);

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
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', overflow: 'hidden' }}>
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem', padding: '0.8rem 1rem', borderBottom: '1px solid rgba(255,255,255,0.09)', flexShrink: 0 }}>
        <Button type="text" icon={<ArrowLeftOutlined />} onClick={onBack}
          style={{ color: 'rgba(255,198,26,0.65)', padding: '0 4px' }} />
        <Text
          strong
          style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.88rem', color: 'var(--parchment)', flex: 1, cursor: contact?.type === 'group' ? 'pointer' : 'default' }}
          onClick={() => contact?.type === 'group' && setShowMembers(v => !v)}
        >
          {contact?.name}
          {contact?.type === 'group' && <TeamOutlined style={{ marginLeft: 6, fontSize: '0.72rem', color: 'rgba(255,198,26,0.5)' }} />}
        </Text>
        <button
          onClick={onOpenSessionCreator}
          style={{
            background: 'rgba(255,198,26,0.08)',
            border: 'none',
            borderRadius: 6,
            color: 'rgba(255,198,26,0.75)',
            cursor: 'pointer',
            fontSize: '0.62rem',
            letterSpacing: '0.06em',
            fontFamily: "'Inter', sans-serif",
            padding: '0.22rem 0.55rem',
            whiteSpace: 'nowrap',
            transition: 'background 0.15s, border-color 0.15s, color 0.15s',
          }}
          onMouseEnter={e => { e.currentTarget.style.background = 'rgba(255,198,26,0.16)'; e.currentTarget.style.borderColor = 'rgba(255,255,255,0.33)'; e.currentTarget.style.color = 'var(--gold)'; }}
          onMouseLeave={e => { e.currentTarget.style.background = 'rgba(255,198,26,0.08)'; e.currentTarget.style.borderColor = 'rgba(255,255,255,0.168)'; e.currentTarget.style.color = 'rgba(255,198,26,0.75)'; }}
        >
          + Session
        </button>
      </div>

      {/* Session island widgets */}
      <SessionWidget
        sessions={sessions}
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
      />

      {/* Group members panel */}
      {showMembers && contact?.type === 'group' && (
        <div style={{ padding: '0.7rem 1rem', borderBottom: '1px solid rgba(255,255,255,0.072)', background: 'rgba(255,198,26,0.04)', maxHeight: 160, overflowY: 'auto', flexShrink: 0 }}>
          <Text style={{ fontSize: '0.55rem', letterSpacing: '0.18em', textTransform: 'uppercase', color: 'rgba(255,198,26,0.45)', display: 'block', marginBottom: '0.4rem' }}>Members</Text>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.45rem', marginBottom: '0.3rem' }}>
            <Avatar size={22} src={user?.profile_photo_url} style={{ background: 'rgba(255,198,26,0.12)', border: 'none', color: 'var(--gold)', fontSize: '0.55rem' }}>
              {(user?.username || 'Y')[0].toUpperCase()}
            </Avatar>
            <Text style={{ fontSize: '0.72rem', color: 'var(--gold)', fontFamily: "'Inter', sans-serif" }}>{user?.username} (you)</Text>
          </div>
          {groupMembers.map((m, i) => {
            const uname = m.username || m.user_id?.slice(0, 8) || '?';
            return (
              <div key={i} style={{ display: 'flex', alignItems: 'center', gap: '0.45rem', marginBottom: '0.3rem' }}>
                <Avatar size={22} src={m.photoUrl} style={{ background: 'rgba(255,198,26,0.12)', border: 'none', color: 'var(--gold)', fontSize: '0.55rem' }}>
                  {uname[0].toUpperCase()}
                </Avatar>
                <Text style={{ fontSize: '0.72rem', color: 'rgba(242,242,242,0.65)', fontFamily: "'Inter', sans-serif" }}>{uname}</Text>
              </div>
            );
          })}
        </div>
      )}

      {/* Messages */}
      <div style={{ flex: 1, overflowY: 'auto', padding: '0.75rem 0.85rem', display: 'flex', flexDirection: 'column', gap: '0.45rem' }}>
        {messages.length === 0 && (
          <div style={{ textAlign: 'center', padding: '2rem 1rem' }}>
            <Text style={{ fontSize: '0.72rem', color: 'rgba(242,242,242,0.22)', fontFamily: "'Inter', sans-serif" }}>No messages yet. Say hello!</Text>
          </div>
        )}
        {messages.map((m, i) => {
          const isMedia = ['image', 'video', 'gif'].includes(m.attachmentKind);
          const ariaLabel = m.attachmentKind === 'image' ? `${m.sender || 'You'}: photo attachment`
            : m.attachmentKind === 'video' ? `${m.sender || 'You'}: video attachment, tap to play`
            : m.attachmentKind === 'gif'   ? `${m.sender || 'You'}: GIF attachment`
            : m.attachmentKind === 'file'  ? `${m.sender || 'You'}: file attachment, ${m.attachmentMeta?.filename || 'file'}, download`
            : undefined;
          return (
            <div
              key={i}
              className={`msg-bubble ${m.mine ? 'sent' : 'received'} ${isMedia ? 'msg-bubble-media' : ''}`}
              aria-label={ariaLabel}
            >
              {!m.mine && m.sender && !isMedia && <div className="msg-bubble-sender">{m.sender}</div>}
              {m.attachmentKind ? <AttachmentContent message={m} /> : m.text}
              {m.attachmentKind && m.text && (
                <div className={isMedia ? 'attachment-caption' : undefined}>{m.text}</div>
              )}
              {m.timestamp && (
                <div className="msg-bubble-meta">
                  {new Date(m.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                </div>
              )}
            </div>
          );
        })}
        <div ref={endRef} />
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
        <input ref={photoVideoInputRef} type="file" accept="image/*,video/*" style={{ display: 'none' }} onChange={handlePhotoVideoChange} />
        <input ref={fileInputRef} type="file" accept={ATTACHMENT_LIMITS.file.accept} style={{ display: 'none' }} onChange={handleFileChange} />

        <Input
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

      <GifSearchModal
        open={showGifSheet}
        onClose={() => setShowGifSheet(false)}
        onSearchGifs={onSearchGifs}
        onSelect={handleGifSelected}
      />
    </div>
  );
}

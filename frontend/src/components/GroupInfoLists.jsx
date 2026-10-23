import React, { useState, useEffect, useRef, useCallback } from 'react';
import { Spin } from 'antd';
import { RightOutlined, PlayCircleFilled } from '@ant-design/icons';
import { fetchAnnouncements } from '../lib/announcementsApi.js';
import { listThreads, relativeTime } from '../lib/threadsApi.js';
import { fetchGroupMedia, mediaColumns, mediaCellLabel, fullDateTime, formatDuration } from '../lib/groupMediaApi.js';

// Task 20261023-group-info-row. The four list bodies shown in the bottom
// submenu (Announcements, Threads, Media; Pinned reuses PinnedListBody).
// Shared rules (design-spec section 5): a plain spinner on the first fetch, a
// warm one-line error with "Try again" when there is nothing to show, and the
// last good list kept (with a muted note) when a refresh fails. Lists fetch
// when their body mounts, i.e. on first open, never on row render. The cache is
// per group and kept for the session so reopening a chip paints at once.

const cache = new Map();
export function _clearGroupInfoListCaches() { cache.clear(); }

const EMPTY_STATE = { items: [], cursor: null, hasMore: false, status: 'loading', stale: false, moreLoading: false };

// load(cursor) -> { items, hasMore, cursor }. A first-page fetch replaces the
// list; a failure keeps whatever is on screen and flips `stale`.
function useList(cacheKey, load, idOf) {
  const loadRef = useRef(load);
  loadRef.current = load;
  const [state, setState] = useState(() => {
    const hit = cache.get(cacheKey);
    return hit ? { ...EMPTY_STATE, ...hit, status: 'ready' } : EMPTY_STATE;
  });
  const seq = useRef(0);
  const stateRef = useRef(state);
  stateRef.current = state;

  const refresh = useCallback(async () => {
    const s = ++seq.current;
    const hadData = cache.has(cacheKey);
    setState((p) => ({ ...p, status: hadData ? 'ready' : 'loading', stale: false }));
    try {
      const page = await loadRef.current(null);
      if (s !== seq.current) return;
      const next = { items: page.items, cursor: page.cursor, hasMore: page.hasMore };
      cache.set(cacheKey, next);
      setState({ ...EMPTY_STATE, ...next, status: 'ready' });
    } catch (err) {
      if (s !== seq.current) return;
      console.error('Group info list failed to load:', err);
      setState((p) => (cache.has(cacheKey) || p.items.length
        ? { ...p, status: 'ready', stale: true }
        : { ...p, status: 'error' }));
    }
  }, [cacheKey]);

  useEffect(() => {
    refresh();
    return () => { seq.current += 1; };
  }, [refresh]);

  const loadMore = useCallback(async () => {
    const cur = stateRef.current;
    if (!cur.hasMore || cur.moreLoading || !cur.cursor) return;
    const s = seq.current;
    setState((p) => ({ ...p, moreLoading: true }));
    try {
      const page = await loadRef.current(cur.cursor);
      if (s !== seq.current) return;
      setState((p) => {
        const have = new Set(p.items.map(idOf));
        const items = [...p.items, ...page.items.filter((i) => !have.has(idOf(i)))];
        cache.set(cacheKey, { items, cursor: page.cursor, hasMore: page.hasMore });
        return { ...p, items, cursor: page.cursor, hasMore: page.hasMore, moreLoading: false };
      });
    } catch (err) {
      if (s !== seq.current) return;
      console.error('Group info list failed to page:', err);
      setState((p) => ({ ...p, moreLoading: false, stale: true }));
    }
  }, [cacheKey, idOf]);

  return { ...state, refresh, loadMore };
}

function StateLine({ noun, onRetry }) {
  return (
    <div className="group-info-panel-state">
      <p>{`We couldn't load ${noun} just now.`}</p>
      <button type="button" className="pins-text-btn" onClick={onRetry}>Try again</button>
    </div>
  );
}
function Empty({ line, sub }) {
  return (
    <div className="group-info-panel-state">
      <p>{line}</p>
      <p className="group-info-panel-sub">{sub}</p>
    </div>
  );
}
function StaleNote({ onRetry }) {
  return (
    <p className="group-info-panel-stale" role="status">
      Couldn&apos;t refresh. Showing what we had.{' '}
      <button type="button" className="pins-text-btn" onClick={onRetry}>Try again</button>
    </p>
  );
}
function Loading({ label }) {
  return <div className="group-info-panel-state" role="status" aria-label={label}><Spin /></div>;
}

// ── Announcements ────────────────────────────────────────────────────────────
const annId = (a) => a.id;
export function sortAnnouncements(list) {
  return list
    .filter((a) => a && a.id && a.published !== false)
    .slice()
    .sort((a, b) => (Date.parse(b.publish_at) || 0) - (Date.parse(a.publish_at) || 0));
}

export function AnnouncementsList({ userId, groupId, groupName, onOpen }) {
  const load = useCallback(async () => {
    const res = await fetchAnnouncements(userId, groupId);
    if (!res || !Array.isArray(res.announcements)) throw new Error('bad announcements body');
    return { items: sortAnnouncements(res.announcements), hasMore: false, cursor: null };
  }, [userId, groupId]);
  const list = useList(`announcements:${groupId}`, load, annId);

  if (list.status === 'loading') return <Loading label="Loading announcements" />;
  if (list.status === 'error') return <StateLine noun="announcements" onRetry={list.refresh} />;
  return (
    <>
      {list.stale && <StaleNote onRetry={list.refresh} />}
      {list.items.length === 0 ? (
        <Empty line="No announcements yet." sub="When a leader posts one, it will show up here." />
      ) : (
        <ul className="group-info-ann-list">
          {list.items.map((a) => (
            <li key={a.id}>
              <button type="button" className="group-info-ann-card" onClick={() => onOpen(a)}
                aria-label={`Announcement: ${a.title}. Open`}>
                {a.banner_url && (
                  <img className="group-info-ann-banner" src={a.banner_url} alt="" loading="lazy"
                    onError={(e) => { e.currentTarget.style.display = 'none'; }} />
                )}
                <span className="group-info-ann-group">{groupName}</span>
                <span className="group-info-ann-title">{a.title}</span>
                <span className="group-info-ann-date">{fullDateTime(a.publish_at)}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </>
  );
}

// ── Threads ──────────────────────────────────────────────────────────────────
const threadId = (t) => t.id;
export function ThreadsList({ userId, groupId, onOpenThread }) {
  const load = useCallback(async (cursor) => {
    const page = await listThreads(userId, groupId, cursor);
    return { items: page.threads, hasMore: page.hasMore, cursor: page.cursor };
  }, [userId, groupId]);
  const list = useList(`threads:${groupId}`, load, threadId);

  if (list.status === 'loading') return <Loading label="Loading threads" />;
  if (list.status === 'error') return <StateLine noun="threads" onRetry={list.refresh} />;
  return (
    <>
      {list.stale && <StaleNote onRetry={list.refresh} />}
      {list.items.length === 0 ? (
        <Empty line="No threads yet." sub="Start one from any message to keep a conversation tidy." />
      ) : (
        <ul className="group-info-thread-list">
          {list.items.map((t) => {
            const n = Number(t.reply_count) || 0;
            const when = relativeTime(t.last_activity_at);
            return (
              <li key={t.id}>
                <button type="button" className="group-info-thread-row" onClick={() => onOpenThread(t)}>
                  <span className="group-info-thread-main">
                    <span className="group-info-thread-title">{t.title || 'Thread'}</span>
                    <span className="group-info-thread-meta">
                      {`${n} ${n === 1 ? 'reply' : 'replies'}`}{when ? ` · ${when}` : ''}
                    </span>
                  </span>
                  <RightOutlined className="group-info-thread-chevron" aria-hidden="true" />
                </button>
              </li>
            );
          })}
        </ul>
      )}
      {list.hasMore && (
        <button type="button" className="pins-text-btn group-info-more" disabled={list.moreLoading} onClick={list.loadMore}>
          {list.moreLoading ? 'Loading…' : 'Show more'}
        </button>
      )}
    </>
  );
}

// ── Media ────────────────────────────────────────────────────────────────────
const mediaId = (m) => m.messageId;

function MediaCell({ item, onOpenImage, onShowInChat }) {
  const label = mediaCellLabel(item, fullDateTime(item.createdAt));
  const isVideo = item.kind === 'video';
  const src = item.thumbUrl || (item.kind === 'image' ? item.url : null);
  const dur = isVideo ? formatDuration(item.duration) : '';
  return (
    <div className="group-info-media-cell" role="listitem">
      <button
        type="button"
        className="group-info-media-btn"
        aria-label={label}
        onClick={(e) => (isVideo ? onShowInChat(item) : onOpenImage(item, e))}
      >
        {src && <img src={src} alt="" loading="lazy" draggable="false" />}
        {isVideo && (
          <span className="group-info-media-badge" aria-hidden="true">
            <PlayCircleFilled />{dur && <span>{dur}</span>}
          </span>
        )}
        {item.kind === 'gif' && <span className="group-info-media-badge" aria-hidden="true">GIF</span>}
      </button>
      {!isVideo && (
        <button type="button" className="group-info-media-show" onClick={() => onShowInChat(item)}
          aria-label={`Show in chat: ${label}`}>
          Show in chat
        </button>
      )}
    </div>
  );
}

export function MediaGrid({ userId, groupId, width, onOpenImage, onShowInChat }) {
  const load = useCallback((cursor) => fetchGroupMedia(userId, groupId, cursor), [userId, groupId]);
  const list = useList(`media:${groupId}`, load, mediaId);
  const sentinelRef = useRef(null);
  const { hasMore, moreLoading, status, loadMore } = list;

  useEffect(() => {
    const el = sentinelRef.current;
    if (!el || !hasMore || typeof IntersectionObserver === 'undefined') return undefined;
    const io = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) loadMore();
    }, { rootMargin: '100% 0px' });
    io.observe(el);
    return () => io.disconnect();
  }, [hasMore, status, loadMore, list.items.length]);

  if (list.status === 'loading') return <Loading label="Loading media" />;
  if (list.status === 'error') return <StateLine noun="media" onRetry={list.refresh} />;
  return (
    <>
      {list.stale && <StaleNote onRetry={list.refresh} />}
      {list.items.length === 0 ? (
        <Empty line="No photos or videos yet." sub="Anything shared in this chat will gather here." />
      ) : (
        <div className="group-info-media-grid" role="list" aria-label="Media"
          style={{ gridTemplateColumns: `repeat(${mediaColumns(width)}, minmax(0, 1fr))` }}>
          {list.items.map((m) => (
            <MediaCell key={m.messageId} item={m} onOpenImage={onOpenImage} onShowInChat={onShowInChat} />
          ))}
        </div>
      )}
      {hasMore && <div ref={sentinelRef} className="group-info-media-sentinel" aria-hidden="true" />}
      {moreLoading && <div className="group-info-panel-state"><Spin size="small" /></div>}
    </>
  );
}

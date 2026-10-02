import React, { useState, useEffect, useRef, useCallback } from 'react';
import { RightOutlined } from '@ant-design/icons';
import { listThreads, relativeTime } from '../lib/threadsApi.js';
import { useMessagingPanel } from '../context/ReaderPanelContexts.jsx';

// Task 20261001-message-threads step 8. "Threads" section of the group info
// panel, mounted through the groupInfoSections.js registry at order 30 (after
// Join requests, before Members). Rendered only when the server reports the
// `threads` capability (the registry's isVisible; off or missing = nothing).
//
// Last-known-good rows are cached per group and kept on screen when a refresh
// fails (preserve-cache-on-failed-refresh); only the inline retry line changes.
// Tapping a row opens that thread straight away through the messaging panel
// context's onOpenThread (which also unmounts this panel).

const threadsCache = new Map();
export function _clearThreadsCache() { threadsCache.clear(); }

export function threadRowLabel(t) {
  const n = Number(t.reply_count) || 0;
  const replies = `${n} ${n === 1 ? 'reply' : 'replies'}`;
  const when = relativeTime(t.last_activity_at);
  return `${t.title || 'Thread'}, ${replies}${when ? `, ${when}` : ''}`;
}

export default function GroupThreadsSection({ userId, groupId, onOpenThread: onOpenThreadProp }) {
  const panel = useMessagingPanel();
  const onOpenThread = onOpenThreadProp || panel?.onOpenThread;
  const cached = threadsCache.get(groupId);
  const [rows, setRows] = useState(cached ? cached.rows : null);
  const [cursor, setCursor] = useState(cached ? cached.cursor : null);
  const [hasMore, setHasMore] = useState(cached ? cached.hasMore : false);
  const [loading, setLoading] = useState(!cached);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState(false);
  const seqRef = useRef(0);

  const refresh = useCallback(async () => {
    const seq = ++seqRef.current;
    setError(false);
    if (!threadsCache.get(groupId)) setLoading(true);
    try {
      const page = await listThreads(userId, groupId, null);
      if (seq !== seqRef.current) return;
      threadsCache.set(groupId, { rows: page.threads, cursor: page.cursor, hasMore: page.hasMore });
      setRows(page.threads);
      setCursor(page.cursor);
      setHasMore(page.hasMore);
    } catch (err) {
      if (seq !== seqRef.current) return;
      console.error('Failed to load threads:', err);
      setError(true);
    } finally {
      if (seq === seqRef.current) setLoading(false);
    }
  }, [userId, groupId]);

  useEffect(() => {
    refresh();
    return () => { seqRef.current += 1; };
  }, [refresh]);

  const loadMore = async () => {
    if (!cursor || loadingMore) return;
    setLoadingMore(true);
    setError(false);
    try {
      const page = await listThreads(userId, groupId, cursor);
      setRows(prev => {
        const have = new Set((prev || []).map(t => t.id));
        const next = [...(prev || []), ...page.threads.filter(t => !have.has(t.id))];
        threadsCache.set(groupId, { rows: next, cursor: page.cursor, hasMore: page.hasMore });
        return next;
      });
      setCursor(page.cursor);
      setHasMore(page.hasMore);
    } catch (err) {
      console.error('Failed to load more threads:', err);
      setError(true);
    } finally {
      setLoadingMore(false);
    }
  };

  const list = rows || [];
  return (
    <section aria-labelledby="group-threads-h" className="group-threads">
      <h3 id="group-threads-h" className="group-info-label">Threads{list.length ? ` · ${list.length}${hasMore ? '+' : ''}` : ''}</h3>

      {loading && rows === null && (
        <div aria-busy="true" aria-label="Loading threads">
          {[0, 1, 2].map(i => <div key={i} className="group-info-skeleton-grid group-threads-skeleton" />)}
        </div>
      )}

      {rows !== null && list.length === 0 && !error && (
        <p className="group-info-empty">No threads yet. Press and hold a message to start one.</p>
      )}

      {list.length > 0 && (
        <ul className="group-threads-list">
          {list.map((t) => (
            <li key={t.id}>
              <button
                type="button"
                className="group-threads-row"
                aria-label={threadRowLabel(t)}
                onClick={() => onOpenThread?.(t)}
              >
                <span className="group-threads-main">
                  <span className="group-threads-title">{t.title || 'Thread'}</span>
                  <span className={`group-threads-snippet${t.root_deleted ? ' group-threads-snippet-deleted' : ''}`}>
                    {t.root_deleted ? 'Original message deleted' : (t.root_preview || '')}
                  </span>
                </span>
                <span className="group-threads-meta">
                  <span>{Number(t.reply_count) || 0} {(Number(t.reply_count) || 0) === 1 ? 'reply' : 'replies'}</span>
                  <span>{relativeTime(t.last_activity_at)}</span>
                </span>
                <RightOutlined className="group-threads-chevron" aria-hidden="true" />
              </button>
            </li>
          ))}
        </ul>
      )}

      {error && (
        <p className="group-info-error" role="alert">
          Couldn't load threads.{' '}
          <button type="button" className="group-info-text-btn" onClick={refresh}>Retry</button>
        </p>
      )}

      {hasMore && !loading && (
        <div className="group-info-rename-actions">
          <button type="button" className="group-info-secondary-pill" onClick={loadMore} disabled={loadingMore}>
            {loadingMore ? 'Loading…' : 'Show more'}
          </button>
        </div>
      )}
    </section>
  );
}

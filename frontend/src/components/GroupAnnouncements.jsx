import { surfaceColor } from '../lib/announcementTitleColor.js';
import React, { useState, useEffect, useRef, useCallback } from 'react';
import { PlusOutlined, MoreOutlined } from '@ant-design/icons';
import {
  fetchAnnouncements, createAnnouncement, updateAnnouncement, deleteAnnouncement,
} from '../lib/announcementsApi.js';
import GroupAnnouncementForm from './GroupAnnouncementForm.jsx';
import GroupAnnouncementViewer, { formatDateTime } from './GroupAnnouncementViewer.jsx';

// Task 20260929-group-announcements (design-notes.md). Hosted inside
// GroupInfoPanel as an in-panel sub-view. All network calls throw; nothing
// here fabricates a list: a failed refresh keeps the last cached list
// (module-level map below) and shows a Retry banner instead.

const UNDO_MS = 8000;
const SWIPE_PX = 72;

// Last-known-good { announcements, gate, truncated } keyed by group.
const listCache = new Map();
export function _clearAnnouncementCaches() { listCache.clear(); }

function GateCard({ gate, onUpgrade, onDismiss }) {
  return (
    <div className="group-info-announcements-gate" role="region" aria-label="Announcement limit reached">
      <strong>You've used this week's announcement</strong>
      <p className="group-info-helper">
        Free plans can post {gate?.limit ?? 1} announcement every 7 days. Upgrade for unlimited announcements.
      </p>
      <div className="group-info-rename-actions">
        <button type="button" className="group-info-pill" onClick={onUpgrade}>See plans</button>
        {onDismiss && <button type="button" className="group-info-text-btn" onClick={onDismiss}>Not now</button>}
      </div>
    </div>
  );
}

function Row({ item, onOpen, onEdit, onDelete }) {
  const [menu, setMenu] = useState(false);
  const [revealed, setRevealed] = useState(false);
  const start = useRef(null);

  const onPointerDown = (e) => { if (e.pointerType === 'touch') start.current = { x: e.clientX, y: e.clientY }; };
  const onPointerUp = (e) => {
    const s = start.current; start.current = null;
    if (!s || !item.can_edit) return;
    const dx = e.clientX - s.x; const dy = Math.abs(e.clientY - s.y);
    if (dx > SWIPE_PX && dy < 40) setRevealed(true);
    else if (dx < -SWIPE_PX / 2) setRevealed(false);
  };

  return (
    <li className="group-info-announcements-item">
      {item.can_edit && revealed && (
        <button type="button" className="group-info-announcements-swipe-delete" onClick={() => onDelete(item)}
          aria-label={`Delete ${item.title}`}>Delete</button>
      )}
      <div className={`group-info-announcements-row${revealed ? ' group-info-announcements-row-swiped' : ''}`}
        onPointerDown={onPointerDown} onPointerUp={onPointerUp}>
        <button type="button" className="group-info-announcements-open" onClick={() => (revealed ? setRevealed(false) : onOpen(item))}>
          {item.banner_url && <img className="group-info-announcements-thumb" src={item.banner_url} alt="" loading="lazy" />}
          <span className="group-info-announcements-text">
            <span className="group-info-announcements-row-title" style={{ color: surfaceColor(item.title_color) }}>{item.title}</span>
            <span className="group-info-announcements-preview">{item.description}</span>
            <span className="group-info-helper">
              {!item.published && <span className="group-info-announcements-chip">Scheduled {formatDateTime(item.publish_at)}</span>}{' '}
              {item.creator_username || 'a member'} · {formatDateTime(item.publish_at)}
            </span>
          </span>
        </button>
        {item.can_edit && (
          <div className="group-info-announcements-kebab">
            <button type="button" className="group-info-icon-btn" aria-haspopup="menu" aria-expanded={menu}
              aria-label={`More actions for ${item.title}`} onClick={() => setMenu(v => !v)}>
              <MoreOutlined />
            </button>
            {menu && (
              <div className="group-info-menu group-info-announcements-menu" role="menu">
                <button type="button" role="menuitem" className="group-info-text-btn" onClick={() => { setMenu(false); onEdit(item); }}>Edit</button>
                <button type="button" role="menuitem" className="group-info-text-btn group-info-danger" onClick={() => { setMenu(false); onDelete(item); }}>Delete</button>
              </div>
            )}
          </div>
        )}
      </div>
    </li>
  );
}

export default function GroupAnnouncements({ userId, groupId, onBack, onGroupGone, onUpgrade, onOpenLightbox }) {
  const initial = listCache.get(groupId) || null;
  const [data, setData] = useState(initial);            // last server-confirmed list
  const [loading, setLoading] = useState(!initial);
  const [loadError, setLoadError] = useState(null);     // string | null
  const [route, setRoute] = useState({ name: 'list' }); // list | view | form
  const [hidden, setHidden] = useState([]);             // ids removed locally, pending delete
  const [snack, setSnack] = useState(null);             // { id, title }
  const [notice, setNotice] = useState(null);
  const [gatePrompt, setGatePrompt] = useState(false);
  const [gateHit, setGateHit] = useState(false);
  const headingRef = useRef(null);
  const mountedRef = useRef(true);
  const pendingRef = useRef(new Map());                 // id -> { timer, item }
  const dataRef = useRef(data);
  dataRef.current = data;

  const handleFailure = useCallback((err) => {
    if (err?.status === 403 && !err.gate) { onGroupGone?.(); return true; }
    return false;
  }, [onGroupGone]);

  const commit = useCallback((next) => { listCache.set(groupId, next); setData(next); }, [groupId]);

  const load = useCallback(() => {
    let cancelled = false;
    setLoadError(null);
    if (!listCache.get(groupId)) setLoading(true);
    fetchAnnouncements(userId, groupId)
      .then((res) => { if (!cancelled) commit(res); })
      .catch((err) => { if (!cancelled && !handleFailure(err)) setLoadError(err.status === 404 ? 'Announcements are not available right now.' : "Couldn't load announcements."); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [userId, groupId, commit, handleFailure]);

  useEffect(() => load(), [load]);

  // Flush any grace-period deletes when the sub-view closes: the user has
  // moved on, so the delete they confirmed by not pressing Undo goes through.
  useEffect(() => {
    mountedRef.current = true;
    const pending = pendingRef.current;
    return () => {
    mountedRef.current = false;
    pending.forEach(({ timer, item }) => {
      clearTimeout(timer);
      deleteAnnouncement(userId, groupId, item.id).then(() => listCache.delete(groupId)).catch(() => {});
    });
    pending.clear();
    };
  }, [userId, groupId]);

  useEffect(() => { headingRef.current?.focus(); }, [route.name]);

  useEffect(() => {
    if (route.name !== 'list') return undefined;
    const onKey = (e) => { if (e.key === 'Escape' && !e.defaultPrevented) { e.preventDefault(); onBack(); } };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [route.name, onBack]);

  const items = (data?.announcements || []).filter(a => !hidden.includes(a.id));
  const scheduled = items.filter(a => !a.published);
  const published = items.filter(a => a.published);
  const gate = data?.gate || null;
  const limitReached = !!gate && gate.allowed === false;

  const finishDelete = async (item) => {
    pendingRef.current.delete(item.id);
    try {
      await deleteAnnouncement(userId, groupId, item.id);
      if (!mountedRef.current) return;
      commit({ ...dataRef.current, announcements: (dataRef.current?.announcements || []).filter(a => a.id !== item.id) });
      setHidden(h => h.filter(id => id !== item.id));
    } catch (err) {
      if (!mountedRef.current) return;
      setHidden(h => h.filter(id => id !== item.id)); // restore the row
      if (err.status === 404) { setNotice('That announcement is no longer available.'); load(); }
      else if (!handleFailure(err)) setNotice("That announcement couldn't be deleted. Please try again.");
    } finally {
      if (mountedRef.current) setSnack(s => (s?.id === item.id ? null : s));
    }
  };

  const startDelete = (item) => {
    // One grace window at a time: a new delete commits the previous one.
    pendingRef.current.forEach(({ timer, item: prev }) => { clearTimeout(timer); finishDelete(prev); });
    setNotice(null);
    setHidden(h => [...h, item.id]);
    setSnack({ id: item.id, title: item.title });
    setRoute({ name: 'list' });
    const timer = setTimeout(() => finishDelete(item), UNDO_MS);
    pendingRef.current.set(item.id, { timer, item });
  };

  const undoDelete = () => {
    if (!snack) return;
    const p = pendingRef.current.get(snack.id);
    if (p) clearTimeout(p.timer);
    pendingRef.current.delete(snack.id);
    setHidden(h => h.filter(id => id !== snack.id));
    setSnack(null);
  };

  const openNew = () => {
    setNotice(null);
    if (limitReached) { setGatePrompt(true); return; }
    setGateHit(false); setGatePrompt(false);
    setRoute({ name: 'form', item: null });
  };

  const submit = async (body) => {
    const editing = route.item;
    try {
      const saved = editing
        ? await updateAnnouncement(userId, groupId, editing.id, body)
        : await createAnnouncement(userId, groupId, body);
      const list = dataRef.current?.announcements || [];
      const nextList = editing ? list.map(a => (a.id === saved.id ? saved : a)) : [saved, ...list];
      commit({ ...(dataRef.current || {}), announcements: nextList });
      if (!editing) load(); // refresh gate/usage; cache already holds the created item
      setRoute({ name: 'view', id: saved.id });
    } catch (err) {
      if (err.status === 403 && err.gate) {
        setGateHit(true);
        commit({ ...(dataRef.current || {}), gate: err.gate });
        throw err;
      }
      if (err.status === 404 && editing) {
        setNotice('That announcement is no longer available.');
        setRoute({ name: 'list' });
        load();
        return;
      }
      if (handleFailure(err)) return;
      throw err;
    }
  };

  const goUpgrade = () => onUpgrade?.();
  const viewing = route.name === 'view' ? items.find(a => a.id === route.id) || (data?.announcements || []).find(a => a.id === route.id) : null;

  if (route.name === 'form') {
    return (
      <GroupAnnouncementForm
        key={route.item?.id || 'new'}
        userId={userId} groupId={groupId} item={route.item} gate={gate} gateHit={gateHit}
        upgrade={<GateCard gate={gate} onUpgrade={goUpgrade} />}
        onSubmit={submit}
        onCancel={() => setRoute(route.item ? { name: 'view', id: route.item.id } : { name: 'list' })}
        headingRef={headingRef}
      />
    );
  }

  if (route.name === 'view' && viewing) {
    return (
      <GroupAnnouncementViewer
        item={viewing} headingRef={headingRef}
        onBack={() => setRoute({ name: 'list' })}
        onEdit={(it) => setRoute({ name: 'form', item: it })}
        onDelete={startDelete}
        onOpenLightbox={onOpenLightbox}
      />
    );
  }

  const renderRow = (it) => (
    <Row key={it.id} item={it}
      onOpen={(x) => setRoute({ name: 'view', id: x.id })}
      onEdit={(x) => setRoute({ name: 'form', item: x })}
      onDelete={startDelete} />
  );

  return (
    <div className="group-info-announcements">
      <div className="group-info-announcements-bar">
        <button type="button" className="group-info-text-btn" onClick={onBack} aria-label="Back to group info">Back</button>
        <h3 ref={headingRef} tabIndex={-1} className="group-info-announcements-title">Announcements</h3>
        <button type="button" className="group-info-pill group-info-announcements-new" onClick={openNew} aria-label="New announcement">
          <PlusOutlined /> New
        </button>
      </div>

      {gatePrompt && <GateCard gate={gate} onUpgrade={goUpgrade} onDismiss={() => setGatePrompt(false)} />}
      {notice && <p className="group-info-error" role="alert">{notice}</p>}

      {loadError && data && (
        <div className="group-info-banner" role="status">
          <span>Couldn't refresh. Showing your last loaded list.</span>
          <button type="button" className="group-info-text-btn" onClick={load}>Retry</button>
        </div>
      )}

      <div aria-live="polite">
        {loading && !data && <div className="group-info-skeleton-grid" aria-label="Loading announcements" />}
        {loadError && !data && (
          <p className="group-info-error" role="alert">
            {loadError}{' '}<button type="button" className="group-info-text-btn" onClick={load}>Retry</button>
          </p>
        )}
        {data && items.length === 0 && <p className="group-info-empty">No announcements yet.</p>}
      </div>

      {scheduled.length > 0 && (
        <>
          <h4 className="group-info-label">Scheduled</h4>
          <ul className="group-info-announcements-list">{scheduled.map(renderRow)}</ul>
        </>
      )}
      {published.length > 0 && <ul className="group-info-announcements-list">{published.map(renderRow)}</ul>}
      {data?.truncated && <p className="group-info-helper">Showing the most recent announcements.</p>}

      {snack && (
        <div className="group-info-toast" role="status" aria-live="polite">
          <span>Announcement deleted.</span>
          <button type="button" className="group-info-text-btn" onClick={undoDelete}>Undo</button>
        </div>
      )}
    </div>
  );
}

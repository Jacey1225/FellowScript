import React, { useState, useRef } from 'react';
import { createPortal } from 'react-dom';
import { Button, Input, Select, Typography } from 'antd';
import { ArrowLeftOutlined } from '@ant-design/icons';
import { useHostRect } from '../../../hooks/useHostRect.js';

const { Text } = Typography;

// ── Filter panel ──────────────────────────────────────────────────────────────
export default function FilterPanel({ onApply, onClear, onClose, groupUsernames }) {
  const [sortVal,    setSortVal]    = useState('');
  const [filterType, setFilterType] = useState('');
  const [filterVal,  setFilterVal]  = useState('');

  // createPortal'd to document.body (see useHostRect's own comment) so this
  // full-bleed overlay escapes .dv-groupview's own backdrop-filter, which
  // otherwise suppresses this panel's independent backdrop-filter from
  // blurring the notes list behind it regardless of blur radius --
  // root-caused live (20260826-notes-filter-panel-blur-increase), not a
  // values-only fix. `position: fixed` + the tracked rect replace the old
  // `position: absolute; inset: 0`, which relied on being a normal
  // descendant of the (now bypassed) `.notes-sidebar` positioned ancestor.
  //
  // The host to track is `.notes-sidebar` -- FilterPanel's own original,
  // never-portaled parent -- found via a zero-size, non-portaled anchor
  // rendered in FilterPanel's normal (non-portaled) output position rather
  // than via a new prop, so the component's existing onApply/onClear/onClose/
  // groupUsernames signature is untouched.
  const hostRef = useRef(null);
  const rect = useHostRect(true, hostRef);

  const panel = (
    <div
      className="notes-filter-panel"
      style={{
        position: 'fixed',
        top: rect?.top ?? 0,
        left: rect?.left ?? 0,
        width: rect?.width ?? '100%',
        height: rect?.height ?? '100%',
        // Was z-index: 4, enough to beat this panel's own local siblings.
        // Now a document.body-level sibling of .reader-dock-container
        // (z-index: 10) and the dock rail (z-index: 15) instead of a local
        // descendant of .notes-sidebar -- needs to clear both to still
        // visually cover the panel it's portaled out of.
        zIndex: 50,
        display: 'flex',
        flexDirection: 'column',
        visibility: rect ? 'visible' : 'hidden',
      }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.65rem', padding: '0.55rem 0.6rem', borderBottom: '1px solid rgba(255,255,255,0.09)' }}>
        <Button type="text" icon={<ArrowLeftOutlined />} onClick={onClose} style={{ color: 'rgba(255,198,26,0.6)' }} />
        <Text strong style={{ fontFamily: "'Space Grotesk', sans-serif", fontSize: '0.95rem', color: 'var(--parchment)', flex: 1 }}>Filter & Sort</Text>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '0.85rem 0.6rem', display: 'flex', flexDirection: 'column', gap: '1rem' }}>
        <div>
          <Text style={{ fontSize: '0.58rem', letterSpacing: '0.22em', textTransform: 'uppercase', color: 'rgba(255,198,26,0.5)', display: 'block', marginBottom: 8 }}>Sort by date</Text>
          <Select value={sortVal || undefined} placeholder="— No sort —" onChange={setSortVal} style={{ width: '100%' }}
            options={[{ value: '', label: '— No sort —' }, { value: 'desc', label: 'Newest first' }, { value: 'asc', label: 'Oldest first' }]}
          />
        </div>
        <div>
          <Text style={{ fontSize: '0.58rem', letterSpacing: '0.22em', textTransform: 'uppercase', color: 'rgba(255,198,26,0.5)', display: 'block', marginBottom: 8 }}>Filter by</Text>
          <Select value={filterType || undefined} placeholder="— No filter —" onChange={v => { setFilterType(v); setFilterVal(''); }}
            style={{ width: '100%', marginBottom: 8 }}
            options={[{ value: '', label: '— No filter —' }, { value: 'book', label: 'Book' }, { value: 'title', label: 'Title' }, { value: 'date', label: 'Date' }, { value: 'user', label: 'User' }]}
          />
          {filterType === 'user'
            ? <Select value={filterVal || undefined} placeholder="Select user" onChange={setFilterVal} style={{ width: '100%' }}
                options={groupUsernames.map(n => ({ value: n, label: n }))} />
            : filterType
              ? <Input type={filterType === 'date' ? 'date' : 'text'} placeholder={filterType === 'book' ? 'e.g. Genesis' : 'Search…'} value={filterVal} onChange={e => setFilterVal(e.target.value)} />
              : null
          }
        </div>
      </div>
      <div style={{ padding: '0.6rem 0.6rem', borderTop: '1px solid rgba(255,255,255,0.072)', display: 'flex', gap: '0.5rem' }}>
        <Button type="primary" onClick={() => onApply({ sortVal, filterType, filterVal })} style={{ flex: 1 }}>Apply</Button>
        <Button onClick={() => { setSortVal(''); setFilterType(''); setFilterVal(''); onClear(); }} style={{ flex: 1 }}>Clear</Button>
      </div>
    </div>
  );

  return (
    <>
      <span ref={el => { hostRef.current = el ? el.parentElement : null; }} style={{ display: 'none' }} aria-hidden="true" />
      {createPortal(panel, document.body)}
    </>
  );
}

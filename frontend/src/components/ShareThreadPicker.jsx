// Task 20261030-thread-share-notes-verses. Secondary "Threads" list shown under
// the selected group in ShareToChatModal: recent threads of that group. A failed
// load shows a retry line (no guessed list). Choosing none sends to the group chat.
import React, { useCallback, useEffect, useState } from 'react';
import { Spin } from 'antd';
import { CheckOutlined } from '@ant-design/icons';
import { loadShareThreads, shareThreadLabel } from '../lib/threadShare.js';

export default function ShareThreadPicker({ userId, groupId, selectedId, onSelect }) {
  const [state, setState] = useState({ status: 'loading', threads: [] });

  const load = useCallback(() => {
    let live = true;
    setState({ status: 'loading', threads: [] });
    loadShareThreads(userId, groupId)
      .then((threads) => { if (live) setState({ status: 'ready', threads }); })
      .catch(() => { if (live) setState({ status: 'error', threads: [] }); });
    return () => { live = false; };
  }, [userId, groupId]);

  useEffect(() => load(), [load]);

  if (state.status === 'loading') return <div style={{ textAlign: 'center', padding: '0.4rem' }}><Spin size="small" /></div>;
  if (state.status === 'error') {
    return (
      <p className="ring-empty" role="status">
        {"Couldn't load threads. "}
        <button type="button" className="ring-row-name" onClick={load}>Try again</button>
      </p>
    );
  }
  if (state.threads.length === 0) return null;
  return (
    <ul className="ring-list share-modal-threads" aria-label="Threads in this group">
      <li>
        <button type="button" role="radio" aria-checked={!selectedId} aria-label={`Group chat. ${!selectedId ? 'Selected' : 'Not selected'}`}
          className="ring-row" onClick={() => onSelect(null)}>
          <span className="ring-row-text"><span className="ring-row-name">Main chat</span></span>
          <span className="ring-row-trailing">{!selectedId && <CheckOutlined style={{ color: 'var(--gold)' }} aria-hidden="true" />}</span>
        </button>
      </li>
      {state.threads.map((t) => {
        const on = selectedId === t.id;
        const label = shareThreadLabel(t);
        return (
          <li key={t.id}>
            <button type="button" role="radio" aria-checked={on} aria-label={`Thread ${label}. ${on ? 'Selected' : 'Not selected'}`}
              className="ring-row" onClick={() => onSelect(t)}>
              <span className="ring-row-text"><span className="ring-row-name">{label}</span></span>
              <span className="ring-row-trailing">{on && <CheckOutlined style={{ color: 'var(--gold)' }} aria-hidden="true" />}</span>
            </button>
          </li>
        );
      })}
    </ul>
  );
}

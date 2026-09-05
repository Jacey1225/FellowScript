import React, { useState } from 'react';
import { Button, Input, Typography, Spin, Divider } from 'antd';
import { ArrowLeftOutlined } from '@ant-design/icons';
import { NoteBody } from '../../RichText.jsx';
import VerseChip from './VerseChip.jsx';
import { validVerses } from './noteFormat.js';

const { TextArea } = Input;
const { Text } = Typography;

// ── Note detail ───────────────────────────────────────────────────────────────
export default function NoteDetail({ note, noteId, onBack, canReply, onReply, replies, repliesLoading, onNavigateVerse }) {
  const [replyText, setReplyText] = useState('');
  const [replying,  setReplying]  = useState(false);
  const verses = validVerses(note?.verses);

  const handleReply = async () => {
    if (!replyText.trim()) return;
    setReplying(true);
    await onReply(noteId, replyText);
    setReplyText('');
    setReplying(false);
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', flex: 1, overflow: 'hidden' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.65rem', padding: '0.55rem 0.6rem', borderBottom: '1px solid rgba(255,255,255,0.09)', flexShrink: 0 }}>
        <Button type="text" icon={<ArrowLeftOutlined />} onClick={onBack} style={{ color: 'rgba(255,198,26,0.6)', padding: '0 4px' }} />
        <Text strong style={{ fontFamily: "'Space Grotesk', sans-serif", fontSize: '0.95rem', color: 'var(--parchment)', flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {note?.title || 'Note'}
        </Text>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '0.85rem 0.6rem', display: 'flex', flexDirection: 'column', gap: '0.75rem' }}>
        <NoteBody html={note?.text} />
        {verses.length > 0 && (
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.3rem' }}>
            {verses.map((v, i) => (
              <VerseChip key={i} verse={v} onNavigateVerse={onNavigateVerse} bordered />
            ))}
          </div>
        )}
        {canReply && (
          <>
            <Divider />
            <Text style={{ fontSize: '0.58rem', letterSpacing: '0.2em', textTransform: 'uppercase', color: 'rgba(255,198,26,0.45)' }}>Replies</Text>
            {repliesLoading
              ? <Spin size="small" />
              : replies.length === 0
                ? <Text style={{ fontSize: '0.72rem', color: 'rgba(242,242,242,0.25)' }}>No replies yet.</Text>
                : replies.map((r, i) => (
                    <div key={i} style={{ padding: '0.35rem 0.5rem', borderLeft: '2px solid rgba(255,255,255,0.12)' }}>
                      <Text style={{ fontSize: '0.62rem', color: 'var(--gold)', opacity: 0.7, display: 'block' }}>{r.user}</Text>
                      <Text style={{ fontSize: '0.75rem', color: 'rgba(242,242,242,0.6)', lineHeight: 1.5 }}>{r.text}</Text>
                    </div>
                  ))
            }
            <TextArea rows={2} value={replyText} onChange={e => setReplyText(e.target.value)} placeholder="Write a reply…" style={{ resize: 'none' }} />
            <Button type="default" size="small" onClick={handleReply} loading={replying} style={{ alignSelf: 'flex-end' }}>Reply</Button>
          </>
        )}
      </div>
    </div>
  );
}

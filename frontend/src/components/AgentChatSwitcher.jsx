import React, { useEffect, useRef, useState } from 'react';
import { Button, Popover, Spin, Tooltip, Typography } from 'antd';
import { CheckCircleFilled, MessageOutlined, PlusOutlined, LoadingOutlined } from '@ant-design/icons';
import { chatActivityIso, chatDateLabel, chatDisplayTitle } from '../lib/agentChats.js';

const { Text } = Typography;

const SECONDARY = 'rgba(242,242,242,0.6)';
const GOLD = 'rgba(255,198,26,0.65)';

function ChatRow({ chat, active, focused, onSelect, rowRef }) {
  const untitled = !(chat.title || '').trim();
  const [hover, setHover] = useState(false);
  return (
    <div
      ref={rowRef}
      role="option"
      aria-selected={active}
      tabIndex={focused ? 0 : -1}
      onClick={() => onSelect(chat.id)}
      onKeyDown={e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onSelect(chat.id); } }}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        minHeight: 44, display: 'flex', alignItems: 'center', gap: '0.5rem', cursor: 'pointer',
        padding: '0.35rem 0.6rem', borderRadius: 8, boxSizing: 'border-box',
        background: hover ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.045)',
        border: active ? '1.5px solid var(--gold)' : '1.5px solid transparent',
      }}
    >
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{
          fontFamily: "'Inter', sans-serif", fontSize: '0.8rem', overflow: 'hidden',
          textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          color: untitled ? SECONDARY : 'var(--parchment)',
        }}>
          {chatDisplayTitle(chat)}
        </div>
        <div style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.68rem', color: SECONDARY }}>
          {chatDateLabel(chatActivityIso(chat))}
        </div>
      </div>
      {active && <CheckCircleFilled aria-hidden style={{ color: 'var(--gold)' }} />}
    </div>
  );
}

function ChatList({ chatUi, agentName, onClose }) {
  const { chats, chatsLoading, chatsError, activeChatId, creatingChat, onSelectChat, onCreateChat, onRefreshChats } = chatUi;
  const [focusIdx, setFocusIdx] = useState(() => Math.max(0, chats.findIndex(c => c.id === activeChatId)));
  const rowRefs = useRef([]);

  useEffect(() => { rowRefs.current[focusIdx]?.focus(); }, [focusIdx]);

  const onKeyDown = (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); setFocusIdx(i => Math.min(chats.length - 1, i + 1)); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setFocusIdx(i => Math.max(0, i - 1)); }
  };

  const select = (id) => { onClose(); onSelectChat(id); };
  const create = async () => { const c = await onCreateChat(); if (c) onClose(); };

  const loadingFirst = chatsLoading && chats.length === 0 && !chatsError;
  return (
    <div style={{ width: 280, maxHeight: 'min(320px, 60vh)', display: 'flex', flexDirection: 'column', gap: '0.35rem' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: '0.4rem', padding: '0 0.2rem' }}>
        <Text strong style={{ fontSize: '0.8rem', color: 'var(--parchment)' }}>Chats</Text>
        <Text style={{ fontSize: '0.7rem', color: SECONDARY, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{agentName}</Text>
      </div>

      {chatsError && chats.length > 0 && (
        <div role="status" aria-live="polite" style={{ fontSize: '0.7rem', color: SECONDARY, padding: '0 0.2rem' }}>
          Couldn't refresh chats
        </div>
      )}

      <div role="listbox" aria-label={`Chats with ${agentName}`} onKeyDown={onKeyDown}
        style={{ overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 4, minHeight: 0 }}>
        {loadingFirst && (
          <div aria-label="Loading chats" role="status" style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            {[0, 1, 2].map(i => <div key={i} style={{ height: 44, borderRadius: 8, background: 'rgba(255,255,255,0.05)' }} />)}
          </div>
        )}
        {chatsError && chats.length === 0 && (
          <div role="alert" style={{ padding: '0.6rem', textAlign: 'center' }}>
            <Text style={{ display: 'block', fontSize: '0.74rem', color: SECONDARY, marginBottom: 6 }}>Couldn't load chats</Text>
            <Button size="small" onClick={() => onRefreshChats()}>Try again</Button>
          </div>
        )}
        {!loadingFirst && !chatsError && chats.length === 0 && (
          <div style={{ padding: '0.6rem', textAlign: 'center' }}>
            <Text style={{ display: 'block', fontSize: '0.74rem', color: SECONDARY, marginBottom: 6 }}>No chats yet</Text>
            <Button size="small" onClick={create}>Start a chat</Button>
          </div>
        )}
        {chats.map((c, i) => (
          <ChatRow key={c.id} chat={c} active={c.id === activeChatId} focused={i === focusIdx}
            rowRef={el => { rowRefs.current[i] = el; }} onSelect={select} />
        ))}
      </div>

      <Button size="small" type="text" icon={creatingChat ? <LoadingOutlined /> : <PlusOutlined />}
        disabled={creatingChat} onClick={create}
        style={{ color: GOLD, alignSelf: 'flex-start', opacity: creatingChat ? 0.45 : 1 }}>
        New chat
      </Button>
    </div>
  );
}

// Thread-header controls for the multi-chat dock (flag `agent_chats`): a Chats
// popover plus an icon-only New chat button. Rendered only when the flag is on.
export default function AgentChatSwitcher({ chatUi, agentName }) {
  const [open, setOpen] = useState(false);
  const btnRef = useRef(null);
  const { creatingChat, onCreateChat, onRefreshChats } = chatUi;

  const close = () => { setOpen(false); btnRef.current?.focus(); };
  const onOpenChange = (next) => {
    setOpen(next);
    if (next) onRefreshChats();
  };

  return (
    <div style={{ display: 'inline-flex', alignItems: 'center', gap: 2, flexShrink: 0 }}
      onKeyDown={e => { if (e.key === 'Escape' && open) { e.stopPropagation(); close(); } }}>
      <Popover
        open={open}
        onOpenChange={onOpenChange}
        trigger="click"
        placement="bottomRight"
        arrow={false}
        content={<ChatList chatUi={chatUi} agentName={agentName} onClose={close} />}
      >
        <Button ref={btnRef} type="text" icon={<MessageOutlined />}
          aria-label={`Chats with ${agentName}`} aria-haspopup="listbox" aria-expanded={open}
          style={{ color: GOLD, minWidth: 32, minHeight: 32, fontSize: '0.74rem' }}>
          <span className="agent-chats-label">Chats</span>
        </Button>
      </Popover>
      <Tooltip title="New chat">
        <Button type="text" aria-label={`New chat with ${agentName}`}
          icon={creatingChat ? <Spin size="small" /> : <PlusOutlined />}
          disabled={creatingChat} onClick={onCreateChat}
          style={{ color: GOLD, minWidth: 32, minHeight: 32, opacity: creatingChat ? 0.45 : 1 }} />
      </Tooltip>
    </div>
  );
}

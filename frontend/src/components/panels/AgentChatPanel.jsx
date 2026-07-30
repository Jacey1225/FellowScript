import React from 'react';
import { Button, Typography } from 'antd';
import { PlusOutlined, RobotOutlined } from '@ant-design/icons';
import AgentChatThread from '../AgentChatThread.jsx';
import { useAgentChatPanel } from '../../context/ReaderPanelContexts.jsx';

const { Text } = Typography;

function agentLabel(agent) {
  if (agent?.name) return agent.name;
  if (!agent?.role || agent.role.startsWith('You are a spiritual')) return 'Spiritual Guide';
  const firstLine = agent.role.split('\n').find(l => l.trim());
  return (firstLine || '').slice(0, 26) || 'Agent';
}

function AgentChip({ agent, active, onClick }) {
  return (
    <button
      onClick={onClick}
      style={{
        display: 'inline-flex', alignItems: 'center', gap: '0.35rem',
        padding: '0.32rem 0.7rem', borderRadius: 100, flexShrink: 0,
        background: active ? 'rgba(200,134,26,0.2)' : 'rgba(200,134,26,0.08)',
        border: `1px solid ${active ? 'rgba(200,134,26,0.55)' : 'rgba(200,134,26,0.2)'}`,
        color: active ? 'var(--gold)' : 'rgba(244,228,193,0.65)',
        cursor: 'pointer', fontSize: '0.72rem', fontFamily: "'Inter', sans-serif",
        transition: 'background 0.15s, border-color 0.15s, color 0.15s',
        whiteSpace: 'nowrap',
      }}
    >
      <RobotOutlined style={{ fontSize: '0.68rem' }} />
      {agentLabel(agent)}
    </button>
  );
}

// Dockview panel: Agent Chat, split fully apart from Messaging. Docked
// bottom-and-wide by default (like an integrated terminal), so a horizontal
// agent switcher fits better here than the vertical list used when this was
// cramped into the shared Messaging slide-over.
export default function AgentChatPanel() {
  const {
    user, agents, agentMessages, activeAgent, agentThinking,
    onOpenAgent, onCloseAgent, onNewAgent, sendAgentMessage,
    curBook, curChapter, curVerse, allNotes, onNavigateVerse,
  } = useAgentChatPanel() || {};

  const enabledAgents = (agents || []).filter(a => a.enabled !== false);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', overflow: 'hidden' }}>
      <div style={{
        display: 'flex', alignItems: 'center', gap: '0.4rem',
        padding: '0.5rem 0.7rem', borderBottom: '1px solid rgba(200,134,26,0.15)',
        overflowX: 'auto', flexShrink: 0,
      }}>
        {enabledAgents.map(agent => (
          <AgentChip key={agent.id} agent={agent} active={activeAgent?.id === agent.id} onClick={() => onOpenAgent?.(agent)} />
        ))}
        <Button type="text" size="small" icon={<PlusOutlined />} onClick={onNewAgent}
          style={{ color: 'rgba(200,134,26,0.55)', flexShrink: 0 }}>
          New
        </Button>
      </div>

      <div style={{ flex: 1, minHeight: 0, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
        {activeAgent ? (
          <AgentChatThread
            agent={activeAgent}
            messages={agentMessages || []}
            user={user}
            onBack={onCloseAgent}
            onSend={sendAgentMessage}
            agentThinking={agentThinking}
            curBook={curBook}
            curChapter={curChapter}
            curVerse={curVerse}
            allNotes={allNotes}
            onNavigateVerse={onNavigateVerse}
          />
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', height: '100%', padding: '1.2rem', textAlign: 'center', gap: '0.8rem' }}>
            <RobotOutlined style={{ fontSize: 22, color: 'rgba(200,134,26,0.35)' }} />
            <Text style={{ fontSize: '0.72rem', color: 'rgba(244,228,193,0.35)', lineHeight: 1.6 }}>
              {enabledAgents.length === 0
                ? 'Start a conversation with your spiritual guide.'
                : 'Choose an agent above to continue chatting.'}
            </Text>
            {enabledAgents.length === 0 && (
              <Button size="small" icon={<PlusOutlined />} onClick={onNewAgent}
                style={{ borderColor: 'rgba(200,134,26,0.4)', color: 'var(--gold)' }}>
                New Agent Chat
              </Button>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

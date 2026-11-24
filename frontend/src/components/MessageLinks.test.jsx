// Task 20261124-clickable-message-links: component-level checks for rendering
// of http/https links in chat text (rel/target, XSS, scheme filtering,
// mention coexistence, markdown href filtering, ChatThread integration).
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import { CapabilitiesContext } from '../context/CapabilitiesContext.jsx';
import MentionText from './MentionText.jsx';
import LinkifiedText from './LinkifiedText.jsx';
import { AgentMessage } from './RichText.jsx';

vi.mock('./GroupInfoPanel.jsx', () => ({ default: () => null }));
import ChatThread from './ChatThread.jsx';

afterEach(() => { cleanup(); vi.restoreAllMocks(); });

describe('LinkifiedText / MentionText', () => {
  test('plain https url becomes an anchor with exact text, target and rel', () => {
    const { container } = render(<MentionText text="see https://example.com/path?q=1#x now" />);
    const a = container.querySelector('a');
    expect(a.textContent).toBe('https://example.com/path?q=1#x');
    expect(a.getAttribute('href')).toBe('https://example.com/path?q=1#x');
    expect(a.getAttribute('target')).toBe('_blank');
    const rel = a.getAttribute('rel').split(/\s+/);
    expect(rel).toEqual(expect.arrayContaining(['noopener', 'noreferrer', 'nofollow']));
    expect(container.textContent).toBe('see https://example.com/path?q=1#x now');
  });

  test('text without a url renders unchanged and has no anchors', () => {
    const { container } = render(<MentionText text="hello there" />);
    expect(container.querySelector('a')).toBeNull();
    expect(container.textContent).toBe('hello there');
  });

  test.each([
    'javascript:alert(1)', 'data:text/html,<b>x</b>', 'file:///etc/passwd',
    'ftp://x.com/a', 'HTTPS//x.com', '//evil.com', 'example.com', 'www.example.com',
  ])('%s is not linked', (s) => {
    const { container } = render(<MentionText text={`go ${s} ok`} />);
    expect(container.querySelector('a')).toBeNull();
  });

  test('XSS payloads inside text/url never create elements', () => {
    const payload = 'https://x.com/"><img src=x onerror=alert(1)><script>alert(2)</script>';
    const { container } = render(<MentionText text={payload} />);
    expect(container.querySelector('img')).toBeNull();
    expect(container.querySelector('script')).toBeNull();
    const a = container.querySelector('a');
    expect(a).not.toBeNull();
    expect(a.getAttribute('href')).not.toMatch(/onerror|<script/i);
    expect(container.textContent).toBe(payload);
  });

  test('link next to a mention: mention stays bold, link is anchor, text preserved', () => {
    const text = '@Matthew look https://example.com/a.';
    const { container } = render(
      <MentionText text={text} mentions={[{ userId: 'a', start: 0, length: 8, username: 'Matthew' }]} />,
    );
    expect(container.querySelector('strong.msg-mention')).not.toBeNull();
    const a = container.querySelector('a[href="https://example.com/a"]');
    expect(a).not.toBeNull();
    expect(container.textContent).toBe(text);
  });

  test('suspicious link (userinfo) is intercepted and not opened until confirmed', () => {
    const open = vi.spyOn(window, 'open').mockImplementation(() => null);
    const { container } = render(<LinkifiedText text="https://user@evil.com/x" />);
    const a = container.querySelector('a');
    const ev = new MouseEvent('click', { bubbles: true, cancelable: true });
    a.dispatchEvent(ev);
    expect(ev.defaultPrevented).toBe(true);
    expect(open).not.toHaveBeenCalled();
  });

  test('ordinary link click is not prevented (browser opens it)', () => {
    const { container } = render(<LinkifiedText text="https://example.com/ok" />);
    const ev = new MouseEvent('click', { bubbles: true, cancelable: true });
    container.querySelector('a').dispatchEvent(ev);
    expect(ev.defaultPrevented).toBe(false);
  });
});

describe('AgentMessage', () => {
  test('user text is linkified', () => {
    const { container } = render(<AgentMessage text="open https://example.com/z" isMine />);
    expect(container.querySelector('a').getAttribute('href')).toBe('https://example.com/z');
  });
  test('markdown javascript: href is not clickable', () => {
    const { container } = render(<AgentMessage text="[click](javascript:alert(1)) and [ok](https://example.com)" isMine={false} />);
    const hrefs = [...container.querySelectorAll('a')].map((a) => a.getAttribute('href'));
    expect(hrefs).toEqual(['https://example.com']);
    expect(container.textContent).toContain('click');
  });
  test('markdown data: href is not clickable', () => {
    const { container } = render(<AgentMessage text="[x](data:text/html,hi)" isMine={false} />);
    expect(container.querySelector('a')).toBeNull();
  });
});

describe('ChatThread integration', () => {
  beforeEach(() => {
    Element.prototype.scrollIntoView = vi.fn();
    window.matchMedia = vi.fn(() => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }));
  });
  test('message body and attachment caption render links', () => {
    const base = { id: 'm1', key: 'm1', mine: false, sender: 'ada', timestamp: '2026-10-17T10:00:00Z' };
    const features = {};
    render(
      <CapabilitiesContext.Provider value={{ features, isEnabled: () => false, refresh: vi.fn(), reactionEmoji: { quick: [], more: [] } }}>
        <ChatThread contact={{ id: 'f1', name: 'Ada', type: 'friend', toUsers: ['f1'] }}
          messages={[
            { ...base, text: 'read https://example.com/one' },
            { ...base, id: 'm2', key: 'm2', text: 'cap https://example.com/two', attachmentKind: 'file', attachmentMeta: { filename: 'x.pdf' } },
          ]}
          groupMembers={[]} user={{ user_id: 'u1', username: 'me' }} sessions={[]} activeSessionId={null}
          talkingUserId={null} onJoinSession={vi.fn()} onLeaveSession={vi.fn()} onOpenSessionCreator={vi.fn()}
          onEditSession={vi.fn()} onDeleteSession={vi.fn()} onNavigateVerse={vi.fn()} videoEnabled={false}
          videoTiles={{}} onToggleVideo={vi.fn()} bindVideoTile={vi.fn()} onSend={vi.fn()} onBack={vi.fn()} />
      </CapabilitiesContext.Provider>,
    );
    const hrefs = [...document.querySelectorAll('a.msg-link')].map((a) => a.getAttribute('href'));
    expect(hrefs).toEqual(['https://example.com/one', 'https://example.com/two']);
    document.querySelectorAll('a.msg-link').forEach((a) => {
      expect(a.getAttribute('target')).toBe('_blank');
      expect(a.getAttribute('rel')).toContain('noopener');
    });
  });
});

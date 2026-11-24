import React from 'react';
import { Modal } from 'antd';
import { linkifySegments, linkInfo } from '../lib/linkify.js';

// Task 20261124-clickable-message-links. http/https URLs in chat text become
// real anchors. The visible text is exactly what was typed; the href is the
// parsed URL. Links open in a new tab (desktop: the shell routes new windows to
// the system browser). Suspicious links (userinfo, raw IP, non-default port,
// IDN host) ask first and show the ASCII host. No dangerouslySetInnerHTML:
// every run is a React text node or element.

export function openExternal(href) {
  window.open(href, '_blank', 'noopener,noreferrer');
}

export function confirmThenOpen(href, host) {
  Modal.confirm({
    title: "You're leaving FellowScript",
    content: (
      <div>
        <div>Open <strong>{host}</strong>?</div>
        <div style={{ marginTop: 8, wordBreak: 'break-all', overflowWrap: 'anywhere', opacity: 0.75, fontSize: '0.85em' }}>{href}</div>
      </div>
    ),
    okText: 'Open',
    cancelText: 'Cancel',
    onOk: () => openExternal(href),
  });
}

export function MessageLink({ url }) {
  const info = linkInfo(url);
  if (!info) return <>{url}</>;
  const guard = (e) => {
    if (!info.suspicious) return;
    e.preventDefault();
    confirmThenOpen(info.href, info.host);
  };
  return (
    <a
      className="msg-link"
      href={info.href}
      target="_blank"
      rel="noopener noreferrer nofollow"
      title={info.href}
      onClick={guard}
      onAuxClick={guard}
    >
      {url}
    </a>
  );
}

// Plain text with links. Returns the string untouched when it has no URL.
export default function LinkifiedText({ text }) {
  const segs = linkifySegments(text);
  if (segs.length === 1 && segs[0].type === 'text') return <>{segs[0].text}</>;
  return (
    <>
      {segs.map((s, i) => (s.type === 'link'
        ? <MessageLink key={i} url={s.text} />
        : <React.Fragment key={i}>{s.text}</React.Fragment>))}
    </>
  );
}

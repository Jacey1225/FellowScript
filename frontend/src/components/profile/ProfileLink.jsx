import React from 'react';
import { Link, useInRouterContext } from 'react-router-dom';
import { profilePath } from '../../lib/profileId.js';

// Task 20261030-profile-everywhere: the one shared "open this user's profile"
// tap target. Renders a real link (keyboard operable, 44px minimum hit area,
// "View {name}'s profile" label; the id is never shown or announced). With no
// valid user id, or a placeholder name, it renders the children untouched:
// no link, no role, no handler.
const NON_USER_LABELS = new Set(['', 'someone', 'a member', 'them', 'you', 'system', 'announcement']);

export default function ProfileLink({ userId, username, children, style, className }) {
  const inRouter = useInRouterContext();
  const to = inRouter ? profilePath(userId) : null;
  const name = (username || '').trim();
  if (!to || NON_USER_LABELS.has(name.toLowerCase())) return <>{children}</>;
  return (
    <Link
      to={to}
      className={className}
      aria-label={`View ${name}'s profile`}
      onClick={(e) => e.stopPropagation()}
      style={{
        display: 'inline-flex', alignItems: 'center', minWidth: 44, minHeight: 44,
        color: 'inherit', textDecoration: 'none', cursor: 'pointer', ...style,
      }}
    >
      {children}
    </Link>
  );
}

import React, { useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { Layout, Menu, Drawer, Button, Tooltip, Avatar } from 'antd';
import { MenuOutlined, ReadOutlined, HomeOutlined, UserOutlined, BulbOutlined, BulbFilled } from '@ant-design/icons';
import { useAuth } from '../context/AuthContext.jsx';
import { useTheme } from '../hooks/useTheme.js';

const { Header } = Layout;

// The desktop top-right no longer shows the Home/Read/Account text Menu or
// the Reader-only "Jump or Ask" command trigger (dropped entirely per
// 20260825-header-nav-profile-icon's architecture step 1) — just the profile
// avatar (below) and the unchanged theme toggle. The mobile hamburger
// `Drawer` keeps its own Home/Read/Account Menu untouched (desktop-only
// scope, confirmed), so `items`/`onMenuClick`/`accountLabel` below still
// serve that Menu.
export default function AppNav() {
  const { user } = useAuth();
  const location = useLocation();
  const navigate = useNavigate();
  const [drawerOpen, setDrawerOpen] = useState(false);
  const { isDark, toggleTheme } = useTheme();

  const accountLabel = user ? (user.username || 'Account') : 'Sign In';
  const accountHref  = user ? '/account' : '/signin';

  // Reader-scoped only (design-notes.md §2): removes the header's own
  // background fill so it sits on the same flat --bg-page canvas as the rest
  // of the Reader page. Admin/Account routes keep the opaque --nav-bg band —
  // AppNav is shared by 4 routes and only Reader's visual spec calls for the
  // unified background.
  const isReaderRoute = location.pathname === '/reader';

  const currentKey = location.pathname === '/reader'  ? 'reader'
                   : location.pathname === '/account' ? 'account'
                   : location.pathname === '/signin'  ? 'account'
                   : '';

  const items = [
    { key: 'home',    label: 'Home',        icon: <HomeOutlined /> },
    { key: 'reader',  label: 'Read',        icon: <ReadOutlined /> },
    { key: 'account', label: accountLabel,  icon: <UserOutlined /> },
  ];

  const onMenuClick = ({ key }) => {
    const paths = { home: '/', reader: '/reader', account: accountHref };
    navigate(paths[key] || '/');
    setDrawerOpen(false);
  };

  return (
    <Header className={`fs-nav${isReaderRoute ? ' fs-nav--unified' : ''}`}>
      <Link to="/" className="nav-logo">
        <span className="fellow">Fellow</span>
        <span className="script">Script</span>
      </Link>

      {/* Right-side controls */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem', flexShrink: 0 }}>
        <Tooltip title={user ? (accountLabel || 'Account') : 'Sign in'} placement="bottom">
          <Link to={accountHref} className="nav-profile-link" aria-label={user ? 'Account' : 'Sign in'}>
            <Avatar
              size={32}
              icon={!user ? <UserOutlined /> : undefined}
              // Task 20260905-profile-photo: antd's Avatar falls back to the
              // icon/children below automatically both when `src` is
              // falsy (no photo set) and when the image itself fails to
              // load (e.g. an expired presigned URL) -- no extra
              // onError wiring needed here for the initials fallback.
              src={user ? user.profile_photo_url : undefined}
              style={{
                background: user ? 'rgba(200,134,26,0.12)' : 'transparent',
                border: '1.5px solid var(--gold)',
                color: 'var(--gold)',
                fontFamily: "'Inter', sans-serif",
                fontWeight: 600,
                fontSize: '0.8rem',
                cursor: 'pointer',
              }}
              className="nav-profile-avatar"
            >
              {user ? (user.username || 'A')[0].toUpperCase() : null}
            </Avatar>
          </Link>
        </Tooltip>

        <Tooltip title={isDark ? 'Light mode' : 'Dark mode'} placement="bottom">
          <Button
            type="text"
            icon={isDark ? <BulbOutlined /> : <BulbFilled />}
            onClick={toggleTheme}
            style={{ color: 'var(--gold)', fontSize: '1rem' }}
            className="theme-toggle-btn"
          />
        </Tooltip>

        <Button
          type="text"
          icon={<MenuOutlined />}
          onClick={() => setDrawerOpen(true)}
          style={{ color: 'var(--gold)' }}
          className="hamburger-btn"
        />
      </div>

      <Drawer
        title={<Link to="/" className="nav-logo" onClick={() => setDrawerOpen(false)}>
          <span className="fellow">Fellow</span><span className="script">Script</span>
        </Link>}
        placement="right"
        open={drawerOpen}
        onClose={() => setDrawerOpen(false)}
        width={240}
        styles={{ header: { borderBottom: '1px solid rgba(200,134,26,0.15)' } }}
      >
        <Menu
          theme="dark"
          mode="inline"
          selectedKeys={[currentKey]}
          items={items}
          onClick={onMenuClick}
          style={{ background: 'transparent', border: 'none' }}
        />
        <div style={{ position: 'absolute', bottom: '1.5rem', left: '1.5rem', display: 'flex', gap: '1rem' }}>
          <Link to="/privacy" onClick={() => setDrawerOpen(false)}
            style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.7rem', color: 'rgba(244,228,193,0.35)', textDecoration: 'none' }}>
            Privacy
          </Link>
          <Link to="/terms" onClick={() => setDrawerOpen(false)}
            style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.7rem', color: 'rgba(244,228,193,0.35)', textDecoration: 'none' }}>
            Terms
          </Link>
        </div>
      </Drawer>
    </Header>
  );
}

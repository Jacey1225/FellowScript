import React, { useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { Layout, Menu, Drawer, Button, Tooltip } from 'antd';
import { MenuOutlined, ReadOutlined, HomeOutlined, UserOutlined, BulbOutlined, BulbFilled } from '@ant-design/icons';
import { useAuth } from '../context/AuthContext.jsx';
import { useTheme } from '../hooks/useTheme.js';
import CommandTrigger from './CommandTrigger.jsx';

const { Header } = Layout;

// `commandTrigger` is optional and only ever passed by Reader.jsx (the
// "Jump or Ask" pill + overlay wires into Reader's own useBible/useAgentChat
// state — see design-notes.md §4-5 and intake-spec.md's confirmed scope).
// AppNav itself stays shared/unaware of Reader's data on the other 3 routes.
export default function AppNav({ commandTrigger }) {
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

      {/* Desktop menu */}
      <Menu
        theme="dark"
        mode="horizontal"
        selectedKeys={[currentKey]}
        items={items}
        onClick={onMenuClick}
        style={{ flex: 1, justifyContent: 'flex-end', minWidth: 0 }}
        className="desktop-menu"
      />

      {/* Right-side controls */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem', flexShrink: 0 }}>
        {isReaderRoute && commandTrigger && <CommandTrigger {...commandTrigger} />}

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

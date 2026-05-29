import React, { useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { Layout, Menu, Drawer, Button } from 'antd';
import { MenuOutlined, ReadOutlined, HomeOutlined, UserOutlined } from '@ant-design/icons';
import { useAuth } from '../context/AuthContext.jsx';
import { useTheme } from '../hooks/useTheme.js';

const { Header } = Layout;

export default function AppNav() {
  const { user } = useAuth();
  const location = useLocation();
  const navigate = useNavigate();
  const [drawerOpen, setDrawerOpen] = useState(false);
  const { isDark, toggleTheme } = useTheme();

  const accountLabel = user ? (user.username || 'Account') : 'Sign In';
  const accountHref  = user ? '/account' : '/signin';

  const currentKey = location.pathname === '/'        ? 'home'
                   : location.pathname === '/reader'  ? 'reader'
                   : location.pathname === '/account' ? 'account'
                   : location.pathname === '/signin'  ? 'account'
                   : 'home';

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
    <Header className="fs-nav">
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

      {/* Theme toggle */}
      <button
        onClick={toggleTheme}
        title={isDark ? 'Switch to light mode' : 'Switch to dark mode'}
        style={{
          background: 'none', border: '1px solid rgba(200,134,26,0.25)', borderRadius: '100px',
          color: 'rgba(200,134,26,0.7)', cursor: 'pointer', padding: '0.3rem 0.65rem',
          fontSize: '0.82rem', lineHeight: 1, marginRight: '0.5rem', transition: 'border-color 0.2s',
        }}
        onMouseEnter={e => e.currentTarget.style.borderColor = 'rgba(200,134,26,0.6)'}
        onMouseLeave={e => e.currentTarget.style.borderColor = 'rgba(200,134,26,0.25)'}
      >
        {isDark ? '☀' : '☾'}
      </button>

      {/* Mobile hamburger */}
      <Button
        type="text"
        icon={<MenuOutlined />}
        onClick={() => setDrawerOpen(true)}
        style={{ color: 'var(--gold)', display: 'none' }}
        className="hamburger-btn"
      />

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
      </Drawer>
    </Header>
  );
}

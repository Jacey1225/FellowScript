import React, { useEffect, useRef } from 'react';
import { Link, Outlet, useLocation, useMatch } from 'react-router-dom';
import {
  LineChartOutlined, BugOutlined, UserSwitchOutlined, GiftOutlined,
} from '@ant-design/icons';
import AdminGate from './AdminGate.jsx';
import AppBloom from './AppBloom.jsx';
import AppNav from './AppNav.jsx';
import Seo from './Seo.jsx';

// Task 20261001-admin-account-redesign: layout route for the hidden admin
// area. Labeled sidebar on desktop, scrollable tab strip on phones (pure CSS
// switch on the same <nav>). Authz is unchanged: AdminGate is UX-only and the
// server's `require_admin` is the real enforcement. Not linked from AppNav.
export const ADMIN_SECTIONS = [
  { to: '/admin/trends',   label: 'Trends',          title: 'Trends',          Icon: LineChartOutlined },
  { to: '/admin/errors',   label: 'Error logs',      title: 'Error logs',      Icon: BugOutlined },
  { to: '/admin/accounts', label: 'Account actions', title: 'Account actions', Icon: UserSwitchOutlined },
  { to: '/admin/promo',    label: 'Promo codes',     title: 'Promo codes',     Icon: GiftOutlined },
];

export function AdminPageHeader({ title, children }) {
  return (
    <div className="fs-admin__head">
      <span className="fs-eyebrow">Admin</span>
      <h1 className="fs-heading" tabIndex={-1} data-admin-heading>{title}</h1>
      {children}
    </div>
  );
}

export default function AdminShell() {
  const { pathname } = useLocation();
  const onDetail = !!useMatch('/admin/detections/*');
  const mainRef = useRef(null);
  const first = useRef(true);

  // Move focus to the new section's h1 on route change so keyboard and screen
  // reader users land on the content (skipped on first mount).
  useEffect(() => {
    if (first.current) { first.current = false; return; }
    const h = mainRef.current && mainRef.current.querySelector('[data-admin-heading]');
    if (h) h.focus();
  }, [pathname]);

  return (
    <AdminGate>
      <Seo title="Admin — FellowScript" description="Admin" path="/admin" noindex />
      <AppBloom variant="account" />
      <AppNav />
      <div className="fs-admin">
        <nav aria-label="Admin sections" className="fs-admin__nav">
          <span className="fs-eyebrow">Admin</span>
          <ul>
            {ADMIN_SECTIONS.map(({ to, label, Icon }) => {
              // Computed here (not via NavLink) so aria-current is set even on
              // /admin/detections/:id, where react-router drops the prop.
              const current = pathname === to || pathname.startsWith(`${to}/`)
                || (onDetail && to === '/admin/errors');
              return (
                <li key={to}>
                  <Link to={to} aria-current={current ? 'page' : undefined}>
                    <Icon style={{ fontSize: 18 }} aria-hidden="true" />
                    {label}
                  </Link>
                </li>
              );
            })}
          </ul>
        </nav>
        <main id="admin-main" className="fs-admin__main" ref={mainRef}>
          <Outlet />
        </main>
      </div>
    </AdminGate>
  );
}

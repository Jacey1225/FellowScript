// Task 20261118-public-membership-page: public membership purchase page
// (/#/membership). Reachable signed out, on phones and desktop browsers; it is
// deliberately NOT wrapped by ReaderWebRedirect / MobileBlockGate and never
// links to /download or /reader. Signed in, it renders the existing
// SubscriptionCard (same Stripe Checkout call, server-side pricing, Apple /
// 409 handling); signed out, it carries the seat choice through sign-in via
// lib/pendingPurchase.js, then the visitor taps "Continue to checkout"
// themselves (subscribe=1 is prefill only, never an auto-start).
import React, { useEffect, useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { Button, InputNumber } from 'antd';
import { CheckOutlined } from '@ant-design/icons';
import AppBloom from '../components/AppBloom.jsx';
import Seo from '../components/Seo.jsx';
import SubscriptionCard from '../components/SubscriptionCard.jsx';
import { useWarmCanvas } from '../hooks/useWarmCanvas.js';
import { useAuth } from '../context/AuthContext.jsx';
import { SEAT_PRICING, seatPriceCents } from '../lib/seatPricing.js';
import { clampSeats, setPendingPurchase, clearPendingPurchase } from '../lib/pendingPurchase.js';

const BODY = { fontFamily: "'Lora', serif", color: 'rgba(244,228,193,0.85)', lineHeight: 1.65 };
const MUTED = { fontFamily: "'Inter', sans-serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.6)' };
const CARD = {
  background: 'rgba(26,20,15,0.85)', border: '1px solid rgba(200,134,26,0.16)',
  backdropFilter: 'blur(14px)', borderRadius: 20, padding: '1.25rem 1.4rem', marginBottom: '1.5rem',
};
const INCLUDED = [
  'Unlimited notes',
  'Unlimited scheduled devotions',
  'Hosted sessions and session summaries',
  'Explorer publishing',
  'Shared access for every member you add',
];
const money = (cents) => `$${((cents || 0) / 100).toFixed(2)}`;

export default function Membership() {
  useWarmCanvas();
  const { user } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const initialSeats = clampSeats(new URLSearchParams(location.search).get('seats'));
  const [seats, setSeats] = useState(initialSeats);

  // A signed-in visitor has arrived where the sign-in handoff pointed: the
  // pending purchase is consumed (it only ever carried a seat count).
  useEffect(() => { if (user) clearPendingPurchase(); }, [user]);

  const price = seatPriceCents(seats);
  const goSignIn = (tab) => {
    setPendingPurchase(seats);
    navigate('/signin', tab ? { state: { tab } } : undefined);
  };

  return (
    <div style={{ minHeight: '100vh', padding: '1.25rem 1rem 3rem' }}>
      <Seo
        title="Membership - FellowScript"
        description="Choose your FellowScript membership and check out securely with Stripe."
        path="/membership"
        noindex
      />
      <AppBloom variant="account" />
      <div style={{ maxWidth: 560, margin: '0 auto', position: 'relative' }}>
        <header style={{ padding: '0.5rem 0 1.5rem', textAlign: 'center' }}>
          <Link to="/" className="fs-wordmark" aria-label="FellowScript home"
            style={{ fontFamily: "'Schibsted Grotesk', sans-serif", fontWeight: 600, fontSize: '1.3rem', color: '#FFF8EE', textDecoration: 'none' }}>
            FellowScript
          </Link>
        </header>

        <main>
          <h1 className="fs-heading" style={{ fontFamily: "'Playfair Display', serif", color: 'var(--parchment)', fontSize: '2rem', margin: '0 0 0.5rem', textAlign: 'center' }}>
            FellowScript membership
          </h1>
          <p style={{ ...BODY, textAlign: 'center', margin: '0 0 1.5rem' }}>
            One plan for you and your group. Choose how many members, then check out securely with Stripe.
          </p>

          {user ? (
            <>
              <SubscriptionCard userId={user.user_id} initialSeats={initialSeats} />
              <p style={{ textAlign: 'center', margin: '0 0 1.5rem' }}>
                <Link to="/account" style={{ ...MUTED, color: 'var(--gold)', textDecoration: 'underline' }}>Go to your account</Link>
              </p>
            </>
          ) : (
            <section style={CARD} aria-label="Choose your membership">
              <div style={{ fontFamily: "'DM Serif Display', serif", fontSize: '1.9rem', color: 'var(--gold)', lineHeight: 1 }} aria-live="polite">
                {price == null
                  ? <span role="alert" style={{ fontSize: '0.95rem' }}>Price unavailable right now. Please try again.</span>
                  : <>{money(price)}<span style={{ fontSize: '0.85rem', color: 'rgba(244,228,193,0.6)' }}>/mo</span></>}
              </div>
              <label htmlFor="membership-seats" style={{ ...MUTED, display: 'block', margin: '0.9rem 0 0.35rem' }}>Members</label>
              <InputNumber id="membership-seats" min={SEAT_PRICING.minMembers} max={SEAT_PRICING.maxMembers} precision={0}
                value={seats} onChange={(v) => setSeats(clampSeats(v))} size="large" style={{ width: '100%' }} />
              <div style={{ ...MUTED, margin: '0.4rem 0 1rem' }}>Choose 1 to {SEAT_PRICING.maxMembers} members</div>

              <ul style={{ listStyle: 'none', margin: '0 0 1.25rem', padding: 0 }}>
                {INCLUDED.map((t) => (
                  <li key={t} style={{ ...BODY, fontSize: '0.9rem', display: 'flex', gap: 8, padding: '0.2rem 0' }}>
                    <CheckOutlined aria-hidden="true" style={{ color: 'var(--gold)', marginTop: 5 }} />{t}
                  </li>
                ))}
              </ul>

              <Button type="primary" block size="large" disabled={price == null} onClick={() => goSignIn()}
                style={{ minHeight: 44, borderRadius: 999, fontFamily: "'Inter', sans-serif" }}>
                Sign in to continue
              </Button>
              <div style={{ textAlign: 'center', marginTop: '0.75rem' }}>
                <Button type="link" onClick={() => goSignIn('signup')} disabled={price == null} style={{ minHeight: 44 }}>
                  New here? Create an account
                </Button>
              </div>
            </section>
          )}
        </main>

        <footer style={{ textAlign: 'center', ...MUTED }}>
          <div style={{ marginBottom: 6 }}>Payments are processed by Stripe.</div>
          <Link to="/terms" style={{ color: 'rgba(244,228,193,0.6)' }}>Terms</Link>{' · '}
          <Link to="/privacy" style={{ color: 'rgba(244,228,193,0.6)' }}>Privacy</Link>
        </footer>
      </div>
    </div>
  );
}

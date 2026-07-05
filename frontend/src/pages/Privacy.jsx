import React from 'react';
import { Link } from 'react-router-dom';
import { Typography } from 'antd';

const { Title } = Typography;

const S = {
  page: {
    minHeight: '100vh',
    background: 'var(--bg-page)',
    fontFamily: "'Lora', serif",
  },
  nav: {
    position: 'sticky', top: 0, zIndex: 10,
    background: 'var(--nav-bg)',
    borderBottom: '1px solid rgba(200,134,26,0.18)',
    padding: '0 2rem', height: 56,
    display: 'flex', alignItems: 'center', justifyContent: 'space-between',
  },
  navLogo: { textDecoration: 'none', fontFamily: "'Playfair Display', serif", fontSize: '1.25rem' },
  fellow: { color: 'var(--parchment)' },
  script: { color: 'var(--gold)', fontStyle: 'italic' },
  navBack: { color: 'rgba(244,228,193,0.45)', textDecoration: 'none', fontSize: '0.85rem' },
  main: { maxWidth: 760, margin: '0 auto', padding: '3rem 2rem 5rem' },
  pageTitle: {
    fontFamily: "'Playfair Display', serif",
    fontSize: '2.2rem', fontWeight: 700,
    color: 'var(--parchment)', marginBottom: '0.4rem',
  },
  effectiveDate: {
    fontSize: '0.82rem', color: 'rgba(244,228,193,0.45)',
    marginBottom: '2.5rem', paddingBottom: '1.5rem',
    borderBottom: '1px solid rgba(200,134,26,0.18)',
  },
  section: { marginBottom: '2.5rem' },
  h2: {
    fontFamily: "'Playfair Display', serif",
    fontSize: '1.15rem', fontWeight: 700,
    color: 'var(--gold)', marginBottom: '0.75rem',
  },
  p: { lineHeight: 1.85, color: 'rgba(244,228,193,0.85)', marginBottom: '0.75rem', fontSize: '0.95rem' },
  ul: { paddingLeft: '1.4rem', marginBottom: '0.75rem' },
  li: { lineHeight: 1.85, fontSize: '0.95rem', marginBottom: '0.3rem', color: 'rgba(244,228,193,0.85)' },
  strong: { color: 'var(--parchment)' },
  a: { color: 'var(--gold)', textDecoration: 'none' },
  contactBox: {
    marginTop: '3rem', padding: '1.5rem',
    border: '1px solid rgba(200,134,26,0.22)',
    borderRadius: 12,
    background: 'rgba(8,5,2,0.92)',
  },
  footer: {
    textAlign: 'center', padding: '2rem',
    fontSize: '0.8rem', color: 'rgba(244,228,193,0.35)',
    borderTop: '1px solid rgba(200,134,26,0.12)',
  },
};

export default function Privacy() {
  return (
    <div style={S.page}>
      <nav style={S.nav}>
        <Link to="/" style={S.navLogo}>
          <span style={S.fellow}>Fellow</span><span style={S.script}>Script</span>
        </Link>
        <Link to="/" style={S.navBack}>&larr; Back to App</Link>
      </nav>

      <main style={S.main}>
        <h1 style={S.pageTitle}>Privacy Policy</h1>
        <p style={S.effectiveDate}>Effective Date: June 1, 2025 &nbsp;&middot;&nbsp; Last Updated: June 1, 2025</p>

        <div style={S.section}>
          <h2 style={S.h2}>1. Introduction</h2>
          <p style={S.p}>FellowScript ("we," "our," or "us") is a faith-based Bible study platform designed to foster meaningful connections between believers. This Privacy Policy explains how we collect, use, and protect your personal information when you use our iOS application and website (collectively, the "Service").</p>
          <p style={S.p}>By creating an account, you agree to the collection and use of your information as described in this policy. If you do not agree, please do not use the Service.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>2. Information We Collect</h2>
          <p style={{ ...S.p, marginBottom: '0.4rem' }}><strong style={S.strong}>Account Information</strong></p>
          <ul style={S.ul}>
            <li style={S.li}>Username and email address (required to create an account)</li>
            <li style={S.li}>Password (stored as a secure cryptographic hash — never in plain text)</li>
          </ul>
          <p style={{ ...S.p, marginTop: '0.75rem', marginBottom: '0.4rem' }}><strong style={S.strong}>Content You Create</strong></p>
          <ul style={S.ul}>
            <li style={S.li}>Bible study notes (public and private)</li>
            <li style={S.li}>Verse highlights and bookmarks</li>
            <li style={S.li}>Messages sent within groups or direct conversations</li>
            <li style={S.li}>AI agent interaction history</li>
          </ul>
          <p style={{ ...S.p, marginTop: '0.75rem', marginBottom: '0.4rem' }}><strong style={S.strong}>Usage Information</strong></p>
          <ul style={S.ul}>
            <li style={S.li}>Bible passages you read and chapters you visit</li>
            <li style={S.li}>Feature interactions within the app</li>
            <li style={S.li}>Device type and operating system (for compatibility purposes only)</li>
          </ul>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>3. How We Use Your Information</h2>
          <p style={S.p}>We use the information we collect to:</p>
          <ul style={S.ul}>
            <li style={S.li}>Create and manage your account</li>
            <li style={S.li}>Sync your notes, highlights, and reading activity across sessions</li>
            <li style={S.li}>Enable community features (group messaging, shared highlights, friend connections)</li>
            <li style={S.li}>Power AI-assisted Bible study features</li>
            <li style={S.li}>Send important account or service notices</li>
            <li style={S.li}>Improve platform performance and user experience</li>
          </ul>
          <p style={S.p}>We do not use your data for advertising and we do not build advertising profiles.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>4. Data Sharing</h2>
          <p style={S.p}><strong style={S.strong}>We do not sell your personal information.</strong></p>
          <p style={S.p}>We may share your information only in these limited circumstances:</p>
          <ul style={S.ul}>
            <li style={S.li}><strong style={S.strong}>With other users:</strong> Content you mark as "public" (notes, highlights) is visible to your connections. Private content is visible only to you.</li>
            <li style={S.li}><strong style={S.strong}>Service providers:</strong> We use third-party infrastructure providers (cloud hosting) to operate the Service. These providers are bound by confidentiality obligations and may not use your data for their own purposes.</li>
            <li style={S.li}><strong style={S.strong}>Legal requirements:</strong> We may disclose information if required by law, court order, or to protect the rights and safety of our users.</li>
          </ul>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>5. Children's Privacy (COPPA)</h2>
          <p style={S.p}>FellowScript is not directed to children under the age of 13. We do not knowingly collect personal information from anyone under 13. If you are under 13, please do not create an account or submit any personal information.</p>
          <p style={S.p}>If we learn that we have collected personal information from a child under 13 without verifiable parental consent, we will promptly delete it. To report a concern, contact us at <a href="mailto:support@fellowscript.com" style={S.a}>support@fellowscript.com</a>.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>6. Data Security</h2>
          <p style={S.p}>We implement industry-standard security measures including encrypted data transmission (HTTPS/TLS) and cryptographic password hashing. However, no method of transmission over the Internet is 100% secure. We encourage you to use a strong, unique password and keep it confidential.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>7. Your Rights and Controls</h2>
          <p style={S.p}>You have the right to:</p>
          <ul style={S.ul}>
            <li style={S.li}><strong style={S.strong}>Access:</strong> View all content and account data from within the app at any time</li>
            <li style={S.li}><strong style={S.strong}>Edit:</strong> Update your username, email, or password in Account settings</li>
            <li style={S.li}><strong style={S.strong}>Delete:</strong> Permanently delete your account and all associated data from Account settings. Deletion is immediate and irreversible.</li>
            <li style={S.li}><strong style={S.strong}>Visibility control:</strong> Choose whether individual notes and highlights are public or private on a per-item basis</li>
          </ul>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>8. Data Retention</h2>
          <p style={S.p}>We retain your account data for as long as your account is active. When you delete your account, your personal information, notes, messages, and highlights are permanently removed from our systems within 30 days.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>9. Third-Party Services</h2>
          <p style={S.p}>The Service may reference Bible translations or external resources. These third-party websites have their own privacy policies, and we are not responsible for their content or practices.</p>
          <p style={S.p}>Our AI study assistant feature uses third-party AI infrastructure. Conversations with AI agents are processed to generate responses and may be used to improve model quality in accordance with our provider's terms. We do not link AI conversation data to your identity outside of the Service.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>10. Changes to This Policy</h2>
          <p style={S.p}>We may update this Privacy Policy from time to time. When we do, we will update the "Last Updated" date at the top of this page. Continued use of the Service after changes are posted constitutes your acceptance of the updated policy.</p>
        </div>

        <div style={S.contactBox}>
          <h2 style={{ ...S.h2, marginBottom: '0.5rem' }}>Contact Us</h2>
          <p style={S.p}>If you have questions about this Privacy Policy or how we handle your data:</p>
          <p style={S.p}><a href="mailto:support@fellowscript.com" style={S.a}>support@fellowscript.com</a></p>
          <p style={{ ...S.p, marginTop: '0.5rem', color: 'rgba(244,228,193,0.4)', fontSize: '0.85rem', marginBottom: 0 }}>
            FellowScript &mdash; A Digital Scripture Community
          </p>
        </div>
      </main>

      <footer style={S.footer}>&copy; 2025 FellowScript &nbsp;&middot;&nbsp; A Digital Scripture Community</footer>
    </div>
  );
}

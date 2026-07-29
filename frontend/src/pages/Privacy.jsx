import React from 'react';
import { Link } from 'react-router-dom';

const S = {
  page: { minHeight: '100vh', background: 'var(--bg-page)', fontFamily: "'Lora', serif" },
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
        <p style={S.effectiveDate}>Effective Date: June 1, 2025 &nbsp;&middot;&nbsp; Last Updated: July 27, 2026</p>

        {/* 1 */}
        <div style={S.section}>
          <h2 style={S.h2}>1. Introduction</h2>
          <p style={S.p}>FellowScript ("we," "our," or "us") is a faith-based Bible study platform designed to foster meaningful connections between believers. This Privacy Policy explains how we collect, use, disclose, and protect your personal information when you use our iOS application and website (collectively, the "Service").</p>
          <p style={S.p}>By creating an account or using the Service, you agree to the collection and use of your information as described in this policy. If you do not agree, please do not use the Service.</p>
        </div>

        {/* 2 */}
        <div style={S.section}>
          <h2 style={S.h2}>2. Information We Collect</h2>

          <p style={{ ...S.p, marginBottom: '0.4rem' }}><strong style={S.strong}>Account Information</strong></p>
          <ul style={S.ul}>
            <li style={S.li}>Username and email address (required to create an account)</li>
            <li style={S.li}>Password (stored as a secure cryptographic hash — never in plain text) — only if you sign up with a password</li>
            <li style={S.li}>If you use <strong style={S.strong}>Sign in with Apple</strong> or <strong style={S.strong}>Sign in with Google</strong>: a stable account identifier from that provider, and your name/email if you grant it (Apple and Google only share your name and email on your first authorization)</li>
            <li style={S.li}>Your selected timezone (used only to schedule your nightly data backup — see Section 9 — and never used to infer your physical location)</li>
            <li style={S.li}>If you enable optional two-factor authentication, a flag noting it's on, and short-lived, single-use codes emailed to you at login (each expires within 10 minutes and is deleted from active use immediately after it's verified or expires)</li>
            <li style={S.li}>If you request a password reset, a short-lived, single-use reset link is emailed to your account address (expires within 30 minutes)</li>
            <li style={S.li}>The date you accepted our Terms of Service and which version you accepted, so we can ask you to review material updates (such as our zero-tolerance content policy)</li>
          </ul>

          <p style={{ ...S.p, marginTop: '0.75rem', marginBottom: '0.4rem' }}><strong style={S.strong}>Subscription and Billing Information</strong></p>
          <ul style={S.ul}>
            <li style={S.li}>Subscription plan type and status (free or group, with a selected member count of 1-8; active, trialing, or canceled)</li>
            <li style={S.li}>Display-only card metadata (card brand and last 4 digits) and an opaque billing-processor reference — we never receive, see, or store your full card number, CVC, or bank details. Full payment handling is performed entirely by Stripe (web) or Apple's App Store (iOS); see Section 5.</li>
          </ul>

          <p style={{ ...S.p, marginTop: '0.75rem', marginBottom: '0.4rem' }}><strong style={S.strong}>Content You Create</strong></p>
          <ul style={S.ul}>
            <li style={S.li}>Bible study notes (public and private)</li>
            <li style={S.li}>Verse highlights and bookmarks</li>
            <li style={S.li}>Messages sent within groups or direct conversations</li>
            <li style={S.li}>AI agent conversation history and custom agent configurations</li>
            <li style={S.li}>Custom notification schedules and reminder prompts you configure</li>
          </ul>

          <p style={{ ...S.p, marginTop: '0.75rem', marginBottom: '0.4rem' }}><strong style={S.strong}>Reports and Safety Data</strong></p>
          <ul style={S.ul}>
            <li style={S.li}>If you report content or another user, we retain the report details (a copy of the reported content at the time it was reported, your stated reason, and any additional details you provide) so we can investigate and act on it</li>
            <li style={S.li}>If you block another user, we record that block to enforce it (hiding their content from you and preventing future contact) and are notified so we can review the situation</li>
          </ul>

          <p style={{ ...S.p, marginTop: '0.75rem', marginBottom: '0.4rem' }}><strong style={S.strong}>Device and Notification Data</strong></p>
          <ul style={S.ul}>
            <li style={S.li}>APNs device token (a unique identifier assigned by Apple used to deliver push notifications to your device). This token is collected only after you grant notification permission and is used solely to send you notifications from FellowScript.</li>
            <li style={S.li}>Device type and operating system version (collected for compatibility and debugging purposes only)</li>
          </ul>

          <p style={{ ...S.p, marginTop: '0.75rem', marginBottom: '0.4rem' }}><strong style={S.strong}>Usage Information</strong></p>
          <ul style={S.ul}>
            <li style={S.li}>Your current Bible reading position (book and chapter) is saved locally on your device only, so the app can resume where you left off. It is not transmitted to or stored on our servers.</li>
            <li style={S.li}>Standard server access logs (IP address, timestamp, and requested endpoint) generated automatically by our hosting infrastructure — used only for security monitoring and diagnosing technical issues. We do not operate any analytics or feature-interaction tracking system.</li>
          </ul>

          <p style={{ ...S.p, marginTop: '0.75rem', marginBottom: '0.4rem' }}><strong style={S.strong}>Information We Do NOT Collect</strong></p>
          <ul style={S.ul}>
            <li style={S.li}>Location data of any kind</li>
            <li style={S.li}>Contacts or address book data</li>
            <li style={S.li}>Camera or microphone data (except during optional video call sessions, which are not recorded)</li>
            <li style={S.li}>Advertising identifiers (IDFA or GAID)</li>
            <li style={S.li}>Browsing history outside of the Service</li>
          </ul>
        </div>

        {/* 3 */}
        <div style={S.section}>
          <h2 style={S.h2}>3. How We Use Your Information</h2>
          <p style={S.p}>We use the information we collect solely to operate and improve the Service:</p>
          <ul style={S.ul}>
            <li style={S.li}>Create and manage your account</li>
            <li style={S.li}>Sync your notes, highlights, and reading progress across sessions</li>
            <li style={S.li}>Enable community features (group messaging, shared highlights, friend connections)</li>
            <li style={S.li}>Power AI-assisted Bible study features via our AI infrastructure provider</li>
            <li style={S.li}>Send push notifications you have configured (reminders, devotionals, chat messages)</li>
            <li style={S.li}>Send important account or service notices</li>
            <li style={S.li}>Diagnose technical issues and improve platform performance</li>
          </ul>
          <p style={S.p}><strong style={S.strong}>We do not use your data for advertising, and we do not build advertising profiles.</strong> We do not engage in cross-context behavioral advertising.</p>
        </div>

        {/* 4 */}
        <div style={S.section}>
          <h2 style={S.h2}>4. Push Notifications</h2>
          <p style={S.p}>FellowScript uses Apple Push Notification service (APNs) to deliver notifications to your iOS device. To send notifications, we store an APNs device token on our servers. This token is tied to your account and is used only to deliver notifications from FellowScript.</p>
          <p style={S.p}>We send two types of push notifications:</p>
          <ul style={S.ul}>
            <li style={S.li}><strong style={S.strong}>Message notifications:</strong> Sent when a friend or group member sends you a chat message and you are not currently active in the app.</li>
            <li style={S.li}><strong style={S.strong}>Scheduled reminders:</strong> Bible study reminders or devotional notifications you set up in the Notifications section of your account.</li>
          </ul>
          <p style={S.p}>You can disable push notifications at any time in your iOS device settings under <strong style={S.strong}>Settings &rarr; Notifications &rarr; FellowScript</strong>. Disabling notifications does not affect your ability to use any other feature of the Service.</p>
        </div>

        {/* 5 */}
        <div style={S.section}>
          <h2 style={S.h2}>5. Data Sharing and Disclosure</h2>
          <p style={S.p}><strong style={S.strong}>We do not sell your personal information.</strong></p>
          <p style={S.p}>We may share your information only in these limited circumstances:</p>
          <ul style={S.ul}>
            <li style={S.li}><strong style={S.strong}>With other users:</strong> Content you mark as "public" (notes, highlights) is visible to your connections. Private content is visible only to you. Your username is visible to friends and group members.</li>
            <li style={S.li}><strong style={S.strong}>Infrastructure providers:</strong> We use Amazon Web Services (AWS) for cloud hosting and video calling infrastructure. AWS processes data on our behalf under a data processing agreement and may not use your data for their own purposes.</li>
            <li style={S.li}><strong style={S.strong}>AI provider:</strong> Conversations with AI agents and notification prompt content are sent to OpenRouter (our AI infrastructure provider) to generate responses. OpenRouter processes this data under their privacy policy. We do not send personally identifiable account information (name, email) to OpenRouter alongside AI queries.</li>
            <li style={S.li}><strong style={S.strong}>Payment processors:</strong> On the web, subscription and one-time payments are processed by <strong style={S.strong}>Stripe</strong>, which receives your email address and payment method details directly — we never see or store your full card number. On iOS, purchases are processed entirely by <strong style={S.strong}>Apple's App Store</strong> (StoreKit) under Apple's own privacy policy.</li>
            <li style={S.li}><strong style={S.strong}>Sign-in providers:</strong> If you choose to sign in with <strong style={S.strong}>Apple</strong> or <strong style={S.strong}>Google</strong>, that provider authenticates you and shares a stable account identifier (and, on first authorization only, your name/email) with us, governed by Apple's or Google's own privacy policy.</li>
            <li style={S.li}><strong style={S.strong}>Apple push notifications:</strong> Push notification delivery is facilitated by Apple's APNs infrastructure. Apple receives your device token and notification payload to deliver notifications. Apple's handling of this data is governed by Apple's Privacy Policy.</li>
            <li style={S.li}><strong style={S.strong}>Email delivery:</strong> Password-reset links and two-factor authentication codes are sent via Amazon Simple Email Service (SES), part of the same AWS infrastructure described above. Only your email address and the message content (a reset link or one-time code) are transmitted for this purpose.</li>
            <li style={S.li}><strong style={S.strong}>Legal requirements:</strong> We may disclose information if required by law, court order, or to protect the rights, property, or safety of FellowScript, our users, or the public.</li>
          </ul>
        </div>

        {/* 6 */}
        <div style={S.section}>
          <h2 style={S.h2}>6. Children's Privacy (COPPA)</h2>
          <p style={S.p}>FellowScript is not directed to children under the age of 13. We do not knowingly collect personal information from anyone under 13. If you are under 13, please do not create an account or submit any personal information.</p>
          <p style={S.p}>If we learn that we have collected personal information from a child under 13 without verifiable parental consent, we will promptly delete that information. To report a concern, contact us at <a href="mailto:support@fellowscript.com" style={S.a}>support@fellowscript.com</a>.</p>
        </div>

        {/* 7 */}
        <div style={S.section}>
          <h2 style={S.h2}>7. Data Security</h2>
          <p style={S.p}>We implement industry-standard security measures to protect your information:</p>
          <ul style={S.ul}>
            <li style={S.li}>All data transmitted between your device and our servers is encrypted using HTTPS/TLS</li>
            <li style={S.li}>Passwords are stored using cryptographic hashing and are never stored or transmitted in plain text</li>
            <li style={S.li}>Our servers are hosted on AWS infrastructure with access controls and monitoring</li>
          </ul>
          <p style={S.p}>No method of transmission over the Internet is 100% secure. While we strive to protect your data, we cannot guarantee absolute security. We encourage you to use a strong, unique password and keep your credentials confidential.</p>
        </div>

        {/* 8 */}
        <div style={S.section}>
          <h2 style={S.h2}>8. Your Rights and Controls</h2>
          <p style={S.p}>You have the following rights with respect to your personal data:</p>
          <ul style={S.ul}>
            <li style={S.li}><strong style={S.strong}>Access:</strong> View all content and account data from within the app at any time.</li>
            <li style={S.li}><strong style={S.strong}>Correction:</strong> Update your username, email, or password in Account settings.</li>
            <li style={S.li}><strong style={S.strong}>Deletion:</strong> Permanently delete your account and all associated data from the Account settings page. Deletion is immediate and irreversible. Your data is purged from our systems within 30 days.</li>
            <li style={S.li}><strong style={S.strong}>Notification control:</strong> Disable push notifications in iOS Settings at any time.</li>
            <li style={S.li}><strong style={S.strong}>Visibility control:</strong> Choose whether individual notes and highlights are public or private on a per-item basis.</li>
          </ul>
          <p style={S.p}><strong style={S.strong}>To request deletion of your data by email:</strong> Send a request to <a href="mailto:support@fellowscript.com" style={S.a}>support@fellowscript.com</a> from the email address associated with your account. Include "Data Deletion Request" in the subject line. We will process your request within 30 days.</p>
        </div>

        {/* 9 */}
        <div style={S.section}>
          <h2 style={S.h2}>9. Data Retention</h2>
          <p style={S.p}>We retain your account data for as long as your account is active. As a security measure, a copy of your notes, highlights, bookmarks, and basic profile information is mirrored nightly (at 3am in your selected timezone) to a separate backup system, so your data can be restored in the event of accidental loss or data corruption.</p>
          <p style={S.p}>When you delete your account — either through the app or by submitting a request to us — your personal information, notes, messages, highlights, bookmarks, device tokens, AI conversation history, <strong style={S.strong}>and the corresponding copy in our backup system</strong> are permanently removed from our systems within 30 days.</p>
          <p style={S.p}>Aggregated, anonymized usage statistics that cannot identify you may be retained for longer periods to improve the Service.</p>
        </div>

        {/* 10 */}
        <div style={S.section}>
          <h2 style={S.h2}>10. California Consumer Privacy Act (CCPA)</h2>
          <p style={S.p}>If you are a California resident, you have additional rights under the CCPA including the right to know what personal information we collect, the right to request deletion, and the right to opt out of the sale of your personal information. We do not sell personal information. To exercise your rights, contact us at <a href="mailto:support@fellowscript.com" style={S.a}>support@fellowscript.com</a>.</p>
        </div>

        {/* 11 */}
        <div style={S.section}>
          <h2 style={S.h2}>11. International Users (GDPR)</h2>
          <p style={S.p}>If you are located in the European Economic Area (EEA) or United Kingdom, you have rights under the General Data Protection Regulation (GDPR) including the right to access, rectification, erasure, restriction of processing, and data portability. Our lawful basis for processing your data is the performance of a contract (providing you with the Service) and your consent (for push notifications).</p>
          <p style={S.p}>To exercise your GDPR rights, contact us at <a href="mailto:support@fellowscript.com" style={S.a}>support@fellowscript.com</a>. We will respond within 30 days.</p>
        </div>

        {/* 12 */}
        <div style={S.section}>
          <h2 style={S.h2}>12. Third-Party Links and Services</h2>
          <p style={S.p}>The Service may reference Bible translations or external theological resources. These third-party websites operate under their own privacy policies and we are not responsible for their practices.</p>
          <p style={S.p}>Our video calling feature is powered by Amazon Chime SDK. Audio and video streams during calls are not recorded or stored by FellowScript.</p>
        </div>

        {/* 13 */}
        <div style={S.section}>
          <h2 style={S.h2}>13. Changes to This Policy</h2>
          <p style={S.p}>We may update this Privacy Policy from time to time. When we do, we will update the "Last Updated" date at the top of this page and, where changes are material, notify you via the app or email. Continued use of the Service after changes are posted constitutes your acceptance of the updated policy.</p>
        </div>

        <div style={S.contactBox}>
          <h2 style={{ ...S.h2, marginBottom: '0.5rem' }}>Contact Us</h2>
          <p style={S.p}>For questions about this Privacy Policy, data deletion requests, or how we handle your information:</p>
          <p style={S.p}>
            <a href="mailto:support@fellowscript.com" style={S.a}>support@fellowscript.com</a>
          </p>
          <p style={{ ...S.p, marginTop: '0.5rem', color: 'rgba(244,228,193,0.4)', fontSize: '0.85rem', marginBottom: 0 }}>
            FellowScript &mdash; A Digital Scripture Community
          </p>
        </div>
      </main>

      <footer style={S.footer}>&copy; 2026 FellowScript &nbsp;&middot;&nbsp; A Digital Scripture Community</footer>
    </div>
  );
}

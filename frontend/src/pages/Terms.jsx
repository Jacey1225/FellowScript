import React from 'react';
import { Link } from 'react-router-dom';

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

export default function Terms() {
  return (
    <div style={S.page}>
      <nav style={S.nav}>
        <Link to="/" style={S.navLogo}>
          <span style={S.fellow}>Fellow</span><span style={S.script}>Script</span>
        </Link>
        <Link to="/" style={S.navBack}>&larr; Back to App</Link>
      </nav>

      <main style={S.main}>
        <h1 style={S.pageTitle}>Terms of Service</h1>
        <p style={S.effectiveDate}>Effective Date: June 1, 2025 &nbsp;&middot;&nbsp; Last Updated: June 1, 2025</p>

        <div style={S.section}>
          <h2 style={S.h2}>1. Acceptance of Terms</h2>
          <p style={S.p}>By accessing or using FellowScript (the "Service"), you agree to be bound by these Terms of Service ("Terms"). If you do not agree to these Terms, you may not use the Service. FellowScript is operated by the FellowScript team ("we," "us," or "our").</p>
          <p style={S.p}>We reserve the right to update these Terms at any time. Continued use of the Service after changes are posted constitutes your acceptance of the updated Terms.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>2. Eligibility</h2>
          <p style={S.p}>You must be at least 13 years old to use FellowScript. By creating an account, you confirm that you meet this age requirement. If you are between 13 and 18, you confirm that a parent or guardian has reviewed and agreed to these Terms on your behalf.</p>
          <p style={S.p}>We do not knowingly allow children under 13 to use the Service. If we discover that an account belongs to someone under 13, we will terminate that account immediately.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>3. Account Responsibilities</h2>
          <p style={S.p}>You are responsible for:</p>
          <ul style={S.ul}>
            <li style={S.li}>Maintaining the confidentiality of your account credentials</li>
            <li style={S.li}>All activity that occurs under your account</li>
            <li style={S.li}>Ensuring your account information is accurate and up to date</li>
            <li style={S.li}>Notifying us immediately of any unauthorized access to your account</li>
          </ul>
          <p style={S.p}>You may not create accounts on behalf of others without their permission, or create multiple accounts to circumvent restrictions.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>4. Acceptable Use</h2>
          <p style={S.p}>FellowScript is a faith-based community. You agree to use the Service in a manner consistent with its purpose of building up believers and fostering meaningful spiritual connections. You agree not to:</p>
          <ul style={S.ul}>
            <li style={S.li}>Post content that is hateful, harassing, threatening, or abusive toward any individual or group</li>
            <li style={S.li}>Share content that is sexually explicit, violent, or otherwise inappropriate for a faith community</li>
            <li style={S.li}>Impersonate another person or misrepresent your affiliation with any organization</li>
            <li style={S.li}>Attempt to gain unauthorized access to any part of the Service or other users' accounts</li>
            <li style={S.li}>Use the Service to distribute spam, malware, or any unauthorized commercial messages</li>
            <li style={S.li}>Scrape, crawl, or extract data from the Service without our written permission</li>
            <li style={S.li}>Violate any applicable local, national, or international law or regulation</li>
          </ul>
          <p style={S.p}>We reserve the right to remove content and suspend or terminate accounts that violate these guidelines, at our sole discretion.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>5. User Content</h2>
          <p style={S.p}>You retain ownership of the content you create on FellowScript (notes, highlights, messages). By posting content, you grant us a non-exclusive, royalty-free license to store, display, and distribute your content solely for the purpose of operating and improving the Service.</p>
          <p style={S.p}>You represent that you have the right to share any content you post, and that your content does not infringe on the intellectual property rights of any third party.</p>
          <p style={S.p}>Content you mark as "public" is visible to other users of the Service. Content you mark as "private" is accessible only to you. We do not intentionally share private content with other users.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>6. Intellectual Property</h2>
          <p style={S.p}>The FellowScript name, logo, design, and all related technology are the intellectual property of FellowScript and may not be used without our express written permission.</p>
          <p style={S.p}>Bible translations available through the Service are used under applicable licensing terms. Scripture quotations are the property of their respective copyright holders.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>7. AI Features</h2>
          <p style={S.p}>FellowScript offers AI-powered Bible study assistance ("AI Agents"). These features are provided for personal study enrichment. AI responses are generated automatically and may not always be accurate, complete, or theologically authoritative. You should not rely solely on AI-generated content for matters of faith, doctrine, or spiritual guidance.</p>
          <p style={S.p}>By using AI features, you agree that your conversation inputs may be processed by our AI infrastructure provider to generate responses.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>8. Service Availability</h2>
          <p style={S.p}>We strive to keep FellowScript available at all times, but we do not guarantee uninterrupted access. We may modify, suspend, or discontinue any part of the Service at any time without prior notice. We will not be liable for any downtime or service interruption.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>9. Disclaimer of Warranties</h2>
          <p style={S.p}>The Service is provided "as is" and "as available" without warranties of any kind, express or implied, including but not limited to warranties of merchantability, fitness for a particular purpose, and non-infringement. We make no warranty that the Service will meet your requirements or be error-free.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>10. Limitation of Liability</h2>
          <p style={S.p}>To the fullest extent permitted by law, FellowScript and its team members shall not be liable for any indirect, incidental, special, consequential, or punitive damages arising from your use of the Service, including but not limited to loss of data, loss of profits, or any unauthorized access to your account.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>11. Termination</h2>
          <p style={S.p}>You may terminate your account at any time from the Account settings page within the app. We may suspend or terminate your account if you violate these Terms, engage in harmful behavior, or if we cease operations.</p>
          <p style={S.p}>Upon termination, your right to use the Service ends immediately. Sections regarding intellectual property, disclaimer of warranties, and limitation of liability survive termination.</p>
        </div>

        <div style={S.section}>
          <h2 style={S.h2}>12. Governing Law</h2>
          <p style={S.p}>These Terms are governed by the laws of the United States, without regard to conflict of law principles. Any disputes arising from these Terms or your use of the Service shall be resolved through good-faith negotiation or, if necessary, binding arbitration.</p>
        </div>

        <div style={S.contactBox}>
          <h2 style={{ ...S.h2, marginBottom: '0.5rem' }}>Contact Us</h2>
          <p style={S.p}>Questions about these Terms or how they apply to your use of FellowScript:</p>
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

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
        <p style={S.effectiveDate}>Effective Date: June 1, 2025 &nbsp;&middot;&nbsp; Last Updated: July 27, 2026</p>

        {/* 1 */}
        <div style={S.section}>
          <h2 style={S.h2}>1. Acceptance of Terms</h2>
          <p style={S.p}>By accessing or using FellowScript (the "Service"), you agree to be bound by these Terms of Service ("Terms"). If you do not agree to these Terms, you may not use the Service. FellowScript is operated by the FellowScript team ("we," "us," or "our").</p>
          <p style={S.p}>We reserve the right to update these Terms at any time. We will notify you of material changes via the app or email. Continued use of the Service after changes are posted constitutes your acceptance of the updated Terms.</p>
        </div>

        {/* 2 */}
        <div style={S.section}>
          <h2 style={S.h2}>2. Eligibility</h2>
          <p style={S.p}>You must be at least 13 years old to use FellowScript. By creating an account, you confirm that you meet this age requirement. If you are between 13 and 18, you confirm that a parent or guardian has reviewed and agreed to these Terms on your behalf.</p>
          <p style={S.p}>We do not knowingly allow children under 13 to use the Service. If we discover that an account belongs to someone under 13, we will terminate that account immediately and delete associated data.</p>
        </div>

        {/* 3 */}
        <div style={S.section}>
          <h2 style={S.h2}>3. Account Responsibilities</h2>
          <p style={S.p}>You are responsible for:</p>
          <ul style={S.ul}>
            <li style={S.li}>Maintaining the confidentiality of your account credentials</li>
            <li style={S.li}>All activity that occurs under your account</li>
            <li style={S.li}>Ensuring your account information is accurate and up to date</li>
            <li style={S.li}>Notifying us immediately of any unauthorized access to your account at <a href="mailto:support@fellowscript.com" style={S.a}>support@fellowscript.com</a></li>
          </ul>
          <p style={S.p}>You may not create accounts on behalf of others without their permission, or create multiple accounts to circumvent restrictions.</p>
        </div>

        {/* 4 */}
        <div style={S.section}>
          <h2 style={S.h2}>4. Acceptable Use &amp; Zero-Tolerance Policy</h2>
          <p style={S.p}><strong style={S.strong}>FellowScript has zero tolerance for objectionable content and abusive behavior of any kind.</strong> This is not a discretionary guideline — it is a binding commitment we make to every member of this community.</p>
          <p style={S.p}>You agree not to:</p>
          <ul style={S.ul}>
            <li style={S.li}>Post or send content that is hateful, harassing, threatening, abusive, or discriminatory toward any individual or group</li>
            <li style={S.li}>Share content that is sexually explicit, violent, or otherwise inappropriate for a faith community</li>
            <li style={S.li}>Impersonate another person or misrepresent your affiliation with any organization</li>
            <li style={S.li}>Attempt to gain unauthorized access to any part of the Service or another user's account</li>
            <li style={S.li}>Use the Service to distribute spam, malware, or any unauthorized commercial messages</li>
            <li style={S.li}>Scrape, crawl, or extract data from the Service without our written permission</li>
            <li style={S.li}>Use the Service to facilitate illegal activity of any kind</li>
            <li style={S.li}>Violate any applicable local, national, or international law or regulation</li>
          </ul>
          <p style={S.p}><strong style={S.strong}>Reporting and blocking.</strong> Every note, message, devotion prompt, group, and user profile on FellowScript can be reported directly within the app. You may also block any user, which immediately (a) prevents that user from contacting you or adding you as a friend going forward, and (b) removes their existing content from your view. Blocking a user automatically notifies us so we can review the situation.</p>
          <p style={S.p}><strong style={S.strong}>Our commitment.</strong> We review every report within 24 hours of submission. Where we confirm a violation of this policy, we will remove the offending content and eject the responsible user from the Service — through suspension or permanent account termination, at our discretion based on severity — within that same 24-hour window. This zero-tolerance commitment applies to all users, regardless of when their account was created.</p>
          <p style={S.p}>Violations may be reported in-app or by emailing <a href="mailto:support@fellowscript.com" style={S.a}>support@fellowscript.com</a>. We reserve the right to take any of the above actions immediately and without prior notice when a report is substantiated.</p>
        </div>

        {/* 5 */}
        <div style={S.section}>
          <h2 style={S.h2}>5. User Content</h2>
          <p style={S.p}>You retain ownership of the content you create on FellowScript (notes, highlights, messages). By posting content, you grant us a non-exclusive, royalty-free, worldwide license to store, display, and distribute your content solely for the purpose of operating and improving the Service.</p>
          <p style={S.p}>You represent that you have the right to share any content you post, and that your content does not infringe on the intellectual property rights of any third party.</p>
          <p style={S.p}>Content you mark as "public" is visible to other users of the Service. Content you mark as "private" is accessible only to you. We do not intentionally share private content with other users.</p>
        </div>

        {/* 6 */}
        <div style={S.section}>
          <h2 style={S.h2}>6. Intellectual Property</h2>
          <p style={S.p}>The FellowScript name, logo, design, and all related technology are the intellectual property of FellowScript and may not be used without our express written permission.</p>
          <p style={S.p}>Bible translations available through the Service are used under applicable licensing terms. Scripture quotations are the property of their respective copyright holders. FellowScript does not claim ownership of any biblical text.</p>
        </div>

        {/* 7 */}
        <div style={S.section}>
          <h2 style={S.h2}>7. AI Features</h2>
          <p style={S.p}>FellowScript offers AI-powered Bible study assistance ("AI Agents") and AI-generated notification content. These features are provided for personal study enrichment only. AI responses are generated automatically and may not always be accurate, complete, or theologically authoritative.</p>
          <p style={S.p}><strong style={S.strong}>You should not rely solely on AI-generated content for matters of faith, doctrine, or spiritual guidance.</strong> Always consult Scripture, qualified clergy, or reputable theological resources for authoritative guidance.</p>
          <p style={S.p}>By using AI features, you agree that your conversation inputs and notification prompts may be sent to our AI infrastructure provider (OpenRouter) to generate responses, as described in our Privacy Policy.</p>
        </div>

        {/* 8 */}
        <div style={S.section}>
          <h2 style={S.h2}>8. Push Notifications</h2>
          <p style={S.p}>FellowScript may send push notifications to your device for chat messages and scheduled Bible study reminders you configure. You may grant or revoke notification permission at any time through your device's system settings. Revoking notification permission does not affect your access to any other feature of the Service.</p>
        </div>

        {/* 9 */}
        <div style={S.section}>
          <h2 style={S.h2}>9. In-App Purchases and Subscriptions</h2>
          <p style={S.p}>FellowScript is currently provided free of charge. We do not offer in-app purchases, paid subscriptions, or premium tiers at this time. If we introduce paid features in the future, we will update these Terms and provide advance notice to users.</p>
        </div>

        {/* 10 */}
        <div style={S.section}>
          <h2 style={S.h2}>10. Service Availability</h2>
          <p style={S.p}>We strive to keep FellowScript available at all times, but we do not guarantee uninterrupted access. We may modify, suspend, or discontinue any part of the Service at any time without prior notice. We will not be liable for any downtime or service interruption.</p>
        </div>

        {/* 11 */}
        <div style={S.section}>
          <h2 style={S.h2}>11. Disclaimer of Warranties</h2>
          <p style={S.p}>The Service is provided "as is" and "as available" without warranties of any kind, express or implied, including but not limited to warranties of merchantability, fitness for a particular purpose, and non-infringement. We make no warranty that the Service will meet your requirements or be error-free.</p>
        </div>

        {/* 12 */}
        <div style={S.section}>
          <h2 style={S.h2}>12. Limitation of Liability</h2>
          <p style={S.p}>To the fullest extent permitted by applicable law, FellowScript and its team members shall not be liable for any indirect, incidental, special, consequential, or punitive damages arising from your use of or inability to use the Service, including but not limited to loss of data, loss of profits, or any unauthorized access to your account.</p>
          <p style={S.p}>Our total liability to you for any claim arising from the Service shall not exceed the amount you paid us in the twelve months preceding the claim (which, as the Service is free, is zero dollars).</p>
        </div>

        {/* 13 */}
        <div style={S.section}>
          <h2 style={S.h2}>13. Termination</h2>
          <p style={S.p}>You may terminate your account at any time from the Account settings page within the app. We may suspend or terminate your account if you violate these Terms, engage in harmful behavior, or if we cease operations.</p>
          <p style={S.p}>Upon termination, your right to use the Service ends immediately. Sections 6 (Intellectual Property), 7 (AI Features), 11 (Disclaimer of Warranties), 12 (Limitation of Liability), and 14 (Governing Law) survive termination.</p>
        </div>

        {/* 14 */}
        <div style={S.section}>
          <h2 style={S.h2}>14. Governing Law and Dispute Resolution</h2>
          <p style={S.p}>These Terms are governed by the laws of the United States, without regard to conflict of law principles. Any disputes arising from these Terms or your use of the Service shall first be attempted to be resolved through good-faith negotiation. If negotiation fails, disputes shall be resolved through binding arbitration conducted in accordance with the American Arbitration Association rules.</p>
          <p style={S.p}>You waive any right to participate in a class action lawsuit or class-wide arbitration against FellowScript.</p>
        </div>

        {/* 15 — Apple EULA clause (required for App Store) */}
        <div style={S.section}>
          <h2 style={S.h2}>15. Apple App Store — Additional Terms</h2>
          <p style={S.p}>The following terms apply to your use of the FellowScript iOS application obtained through the Apple App Store:</p>
          <ul style={S.ul}>
            <li style={S.li}><strong style={S.strong}>Parties:</strong> These Terms are an agreement between you and FellowScript only — not with Apple, Inc. Apple is not a party to these Terms and is not responsible for the FellowScript application or its content.</li>
            <li style={S.li}><strong style={S.strong}>License scope:</strong> Your license to use the iOS application is a non-transferable license to use FellowScript on any Apple-branded device you own or control, subject to the Usage Rules set forth in the Apple Media Services Terms and Conditions.</li>
            <li style={S.li}><strong style={S.strong}>Maintenance and support:</strong> FellowScript is solely responsible for providing maintenance and support services for the application. Apple has no obligation whatsoever to furnish any maintenance or support services with respect to FellowScript.</li>
            <li style={S.li}><strong style={S.strong}>Warranty:</strong> In the event the application fails to conform to any applicable warranty, you may notify Apple, and Apple will refund the purchase price (if any) to you. To the maximum extent permitted by applicable law, Apple will have no other warranty obligation with respect to the application.</li>
            <li style={S.li}><strong style={S.strong}>Product claims:</strong> FellowScript, not Apple, is responsible for addressing any claims by you or any third party relating to the application or your possession or use of the application, including product liability claims, consumer protection claims, intellectual property infringement claims, and claims under consumer protection or privacy regulation.</li>
            <li style={S.li}><strong style={S.strong}>Third-party beneficiary:</strong> Apple and Apple's subsidiaries are third-party beneficiaries of these Terms. Upon your acceptance of these Terms, Apple will have the right (and will be deemed to have accepted the right) to enforce these Terms against you as a third-party beneficiary thereof.</li>
            <li style={S.li}><strong style={S.strong}>App Store compliance:</strong> You represent and warrant that (i) you are not located in a country that is subject to a U.S. government embargo, or that has been designated by the U.S. government as a "terrorist supporting" country; and (ii) you are not listed on any U.S. government list of prohibited or restricted parties.</li>
          </ul>
        </div>

        {/* 16 */}
        <div style={S.section}>
          <h2 style={S.h2}>16. Entire Agreement</h2>
          <p style={S.p}>These Terms, together with our <Link to="/privacy" style={S.a}>Privacy Policy</Link>, constitute the entire agreement between you and FellowScript with respect to the Service and supersede all prior agreements and understandings.</p>
        </div>

        <div style={S.contactBox}>
          <h2 style={{ ...S.h2, marginBottom: '0.5rem' }}>Contact Us</h2>
          <p style={S.p}>Questions about these Terms, how they apply to your use of FellowScript, or to report a violation:</p>
          <p style={S.p}><a href="mailto:support@fellowscript.com" style={S.a}>support@fellowscript.com</a></p>
          <p style={{ ...S.p, marginTop: '0.5rem', color: 'rgba(244,228,193,0.4)', fontSize: '0.85rem', marginBottom: 0 }}>
            FellowScript &mdash; A Digital Scripture Community
          </p>
        </div>
      </main>

      <footer style={S.footer}>&copy; 2026 FellowScript &nbsp;&middot;&nbsp; A Digital Scripture Community</footer>
    </div>
  );
}

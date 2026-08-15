# Research Plan: FellowScript Marketing Methods

## Topic / Claim

What are the most promising methods for marketing FellowScript — a faith-based Bible study platform (web + iOS) — given its actual purpose, theme, and functionality as documented in its own codebase? Recommendations must be grounded in what the app concretely is (features, design language, audience implied by those features), not generic app-marketing advice bolted on afterward.

## Scope

**In bounds:**
- Reading and synthesizing FellowScript's own documentation (README, mkdocs `docs/` tree) to establish: core purpose/mission, feature set, target user/audience signals, platforms (web React + iOS Swift), monetization model (Stripe/Apple IAP subscriptions), and design/brand identity (parchment-and-gold, reverent-but-modern editorial tone).
- External research into marketing channels, tactics, and case studies specifically relevant to: faith-based / Christian apps, Bible study / devotional apps, community-driven social apps, subscription (freemium) mobile app growth, and small/indie app marketing (this appears to be a single-developer or small-team project based on repo structure — confirm from docs rather than assume).
- Channel-specific research: App Store Optimization (ASO) for religious/lifestyle apps, church/ministry partnership channels, Christian social media communities (e.g., faith-focused creators, church small-group leaders), content marketing angles tied to actual features (highlighting, notes, groups, AI devotional check-ins), referral/community-driven growth mechanics suited to a group-based product.
- Competitive landscape: how comparable apps (e.g., YouVersion/Bible App, Glorify, Abide, Hallow, faith-based community apps) approach marketing and community growth, to the extent this informs differentiation — not an exhaustive competitor audit.

**Out of bounds:**
- General app marketing theory disconnected from FellowScript's specific features/theme.
- Any file in the FellowScript repo containing credentials or secrets: `.env`, `AuthKey_4SRZ3YTAAN.p8`, `fellowscript-ec2-key.pem`, and similar. These are irrelevant to marketing research and must not be opened or referenced.
- Deep technical/architecture research beyond what's needed to describe features and platforms in marketing terms (e.g., no need to trace API implementation details in `api/` or `frontend/` source code — the docs describe functionality sufficiently).
- Legal/compliance deep-dive (e.g., religious-app App Store policy nuances) unless it directly affects a marketing channel's viability.

**Narrowing note:** The request doesn't specify a budget, timeline, or whether marketing is pre-launch or post-launch. Absent that detail, this plan scopes broadly across paid, organic, community, and partnership channels, and treats the app as pre-launch-or-early-stage (small existing user base) based on repo signals (single dev structure, no visible marketing artifacts in repo). If mid-research this assumption proves wrong, note it in findings rather than re-scoping.

## Constraints

- **Required first step (non-negotiable):** Before any external marketing research, read FellowScript's own documentation to ground findings:
  - `/Users/jaceysimpson/Vscode/FellowScript/README.md`
  - `/Users/jaceysimpson/Vscode/FellowScript/docs/index.md`
  - `/Users/jaceysimpson/Vscode/FellowScript/docs/design/overview.md`, `docs/design/home-page.md`, `docs/design/community.md`, `docs/design/account.md`, `docs/design/notes.md`, `docs/design/bible-reader.md`
  - `/Users/jaceysimpson/Vscode/FellowScript/docs/architecture/overview.md` (for platform/tech context only, not implementation depth)
  - `/Users/jaceysimpson/Vscode/FellowScript/mkdocs.yml` (site nav, may reveal additional docs pages)
  - Explicitly skip/avoid: `.env`, `*.p8`, `*.pem`, and anything else that looks like a credential or key file anywhere in this repo.
- Source types: mix of the app's own documentation (primary/internal source) and external secondary sources (marketing case studies, ASO guides, faith-app industry pieces, competitor positioning). No requirement for academic sources.
- Depth: moderate — enough to produce a prioritized, actionable set of marketing recommendations tied to specific features/themes, not an exhaustive marketing strategy document.
- Time period: prioritize current/recent (last 2-3 years) marketing and ASO guidance where dated tactics may be stale (e.g., App Store algorithm changes, social platform shifts).

## Research Steps

1. What is FellowScript's stated mission/purpose and target audience, per its own docs (README + docs/index.md + docs/design/overview.md)?
2. What are the concrete features (Bible reader, highlighting, rich notes, groups, friends/messaging, devotions, AI devotional check-ins, subscriptions) and which of these are most differentiating vs. generic Bible apps?
3. What is the brand/design identity (parchment-and-gold, reverent-but-modern, editorial typography) and what does it suggest about tone-of-voice for marketing creative?
4. What monetization model does the app use (free tier + Individual/Group paid plans via Stripe/Apple IAP) and how does that shape which growth channels are cost-effective (e.g., group-based virality vs. paid acquisition)?
5. What marketing channels and tactics are proven or commonly recommended for faith-based / Bible study / devotional apps specifically?
6. What ASO tactics apply to religious/lifestyle app categories on iOS App Store (and Google Play if relevant)?
7. What community/partnership channels exist that map to FellowScript's group-and-relationship-centric features (churches, small groups, campus ministries, faith influencers/creators)?
8. How do comparable apps (YouVersion, Abide, Hallow, Glorify, or similar community/devotional apps) market themselves, and what gaps or differentiation opportunities does that suggest for FellowScript?
9. Given the group/social/AI-devotional feature set, what referral or virality mechanics are most promising (e.g., invite-a-friend into a group, shareable public highlights/notes)?

## User-Provided Sources

(none provided verbatim in the request — user pointed to the codebase location as the required grounding source rather than pasting text/links)

- Codebase path: `/Users/jaceysimpson/Vscode/FellowScript` — README.md, docs/ (mkdocs site), api/, frontend/, ios/ directories.

## Success Criteria

Sourcing stage is sufficient when it has produced:
- A clear, accurate internal summary of FellowScript's purpose, features, audience signals, and brand identity drawn directly from its own docs (with specific doc citations).
- At least 3-5 credible external sources per major channel category researched (ASO, community/partnership, content/social, referral mechanics) covering faith-app-specific or closely analogous (subscription community app) marketing guidance.
- Enough material to support a prioritized list of marketing recommendations, each explicitly tied back to a specific FellowScript feature, theme, or design element rather than generic advice.
- No credential/secret files opened or referenced.

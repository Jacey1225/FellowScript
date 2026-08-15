# Research Brief: FellowScript Marketing Methods

## Summary

### 1. Mission, purpose, and audience signals (per FellowScript's own docs)

FellowScript describes itself as a "community-driven Bible reading app" whose mission is "building impactful relationships that fan into flame the gift of God" (README.md). The public-facing tagline is "A Digital Scripture Community — Read · Reflect · Connect" (docs/index.md), and the existing landing page already closes on a Scripture-quote CTA (2 Timothy 1:6) (docs/design/home-page.md). Together these establish that FellowScript positions itself as a *relational/communal* Bible product first, and a reading-tool product second — the mission statement foregrounds relationships, not personal devotional discipline alone. This distinguishes it from single-user devotional/meditation framing.

### 2. Concrete features and differentiators

Core features per docs/index.md and the design docs: digital Bible reader, verse highlighting (six-color palette, per-user and per-group visibility — docs/design/bible-reader.md), rich notes with a public/private toggle and gold badge for shared notes (docs/design/notes.md), bookmarks, groups, friends, real-time messaging/DMs (WebSocket-based — docs/design/community.md), devotions, AI devotional/agent check-ins, notifications, and subscriptions.

The most differentiating elements versus generic Bible apps are: (a) the group/social layer being load-bearing rather than bolted on — group chat, friend requests, and colored-highlight overlays visible to groupmates are core, not an afterthought (docs/design/community.md); (b) the desktop Reader's dockable, freely-arranged multi-panel workspace (Bible, Notes, Highlights, Messaging, Agent Chat) — an unusually power-user-oriented, "VSCode-style" UX choice among Bible apps (docs/design/bible-reader.md); and (c) the public-note/shareable-highlight mechanic, which is a built-in content-sharing surface (docs/design/notes.md, docs/design/community.md).

### 3. Brand/design identity and tone implications

The visual identity is explicitly described in the docs as evoking "the warmth and reverence of handwritten scripture — candlelight on parchment — while remaining clean and modern" (docs/design/overview.md). Concrete tokens: a warm parchment-and-gold palette, Playfair Display/Space Grotesk for headings, Lora for body text, and IM Fell English for verse/pull-quote text (README.md; docs/design/overview.md). This suggests marketing creative should favor reverent, editorial, "handwritten-manuscript-adjacent" visual language over the bright, gamified, meditation-app aesthetic common to competitors — and favor authentic/testimonial tone over polished-ad tone, which independently matches external guidance that faith audiences respond better to authentic storytelling than slick production (Christian Post Advertising; FrontGate Media, creator-partnership piece).

### 4. Monetization model and its implications for channel selection

**Internal-docs discrepancy (see Risks):** docs/index.md and docs/design/home-page.md describe a 3-tier model (Free / Individual $4.99 / Group $9.99), while docs/design/account.md — the most implementation-detailed doc, referencing live view-model wiring — describes a single Group-only paid tier (1–8 members, priced by member count, no standalone Individual plan), billed via Stripe Checkout (web) and StoreKit 2 (iOS). account.md is treated as the more current/authoritative source per the source-gathering agent's assessment, but this is flagged as unresolved, not settled.

Under either reading, the paid tier is inherently multiplayer/group-priced. This means group invites carry *direct revenue upside* (an invited user who joins a paid group directly expands billable seats), not just engagement upside — which argues for prioritizing group-invite and referral mechanics over generic single-user paid acquisition. This is reinforced by general (non-faith-specific) subscription-app research: referred users show ~25% higher LTV and 83% higher trust than non-referred users, and double-sided referral rewards are the dominant proven pattern (Adapty).

### 5. Channels/tactics proven for faith-based and Bible/devotional apps

Three well-documented faith-app growth patterns emerged, each independently corroborated:

- **Church/parish/diocese partnerships as a distribution channel.** Hallow partnered with 2,500+ parishes; QR codes on parish materials contributed ~9% of overall growth, and 2024 Catholic-organization collaborations correlated with a 30% user increase (Branch.io case study; Contrary Research). YouVersion similarly built church-partnership tooling that turns congregations into distribution channels, and church-tech trade press treats church-facing engagement tools as a standard growth lever industry-wide (growthcasestudies.com; ChurchTechToday).
- **Church-calendar-timed campaigns dramatically outperform generic timing.** Hallow saw 412% install/purchase growth during Lent and 230% during Easter versus 300% from general testing-program gains; February 2024 (Lent) alone drove 2M installs and a brief #1 App Store ranking (Phiture case study; Branch.io case study; Consumer Startups).
- **Verse-sharing and social/reading-plan mechanics build organic referral culture.** YouVersion's shareable verse-image cards drove a "Global Share the Bible Day" campaign (1M installs in 11 days, Dec 2010) and 535M cumulative verse-shares by 2021; reading plans done "together" create a referral culture because non-users must install the app to participate (growthcasestudies.com; LinkedIn/Okoro analysis). This maps directly onto FellowScript's existing public-note/shared-highlight mechanic.

Investor interest in the category (Glorify's $40M SoftBank/celebrity-backed round, corroborated independently by techstartups.com and religionnews.com) further signals that faith-app community/content strategies are viewed as scalable, though this is market-context rather than a specific tactic.

### 6. ASO tactics for religious/lifestyle apps

No faith-specific ASO source was found; guidance gathered is general ASO best practice, corroborated across 4+ independent sources (Udonis, AppRadar, ASOmobile, Semrush): title keywords carry the strongest indexation weight; apps under a 4.0-star rating struggle for organic traction; screenshot galleries should tell a visual story rather than show static UI; and Custom Product Pages (CPPs) — especially following July 2025 organic-search eligibility — are one of the most significant recent ASO developments, relevant to testing FellowScript listing variants by audience segment (e.g., small-group leaders vs. individual devotional readers). No Google Play–specific religious-app ASO guidance was found, but this gap is likely moot since FellowScript is web + iOS only today, with no Android client documented (docs/architecture/overview.md).

### 7. Community/partnership channels mapped to FellowScript's group features

Multiple independent sources confirm a recognized "apps/tools for church small groups" market category and buyer intent distinct from single-user devotional apps (faith.tools/small-groups), which FellowScript's group-centric feature set maps onto directly. Pastor- and church-leadership-facing publications actively curate and recommend Bible-study-app lists (TheLeadPastor, corroborated by faith.tools and SmartGroups' positioning), confirming pastor/leader outreach and "best-of" list placement as a real, targetable discovery channel — not merely hypothetical. Campus-ministry coalition apps are a live, precedented model (EveryCampus, 100+ campus ministries), though evangelical campus-outreach practitioners caution that relational/on-the-ground tactics outperform broad digital advertising in this specific sub-audience (TheGospelCoalition), with a ministry-marketing agency (Reliant Creative) corroborating that campus ministries need distinctly scoped messaging rather than general-church tactics.

A close direct competitor, SmartGroups, already combines AI-assisted tools with pastor dashboards and small-group management — confirming the AI+group combination FellowScript occupies is a validated but contested space, not unproven territory (smartgroups.app).

### 8. Comparable-app positioning and differentiation gaps

- **Hallow** (Catholic-leaning, 20M+ downloads, $400M+ valuation) wins primarily through celebrity/high-reach partnerships (Mark Wahlberg Super Bowl spot) and parish-institutional distribution, and explicitly favors celebrity/high-reach content over local-church content because "people might scroll past a post from their local church" (Hallow's own blog; Consumer Startups; Branch.io).
- **YouVersion** (1B+ installs, dominant scale) wins through SEO/domain authority (Bible.com acquisition, per-verse indexed pages), habit-loop mechanics (streaks, badges), and deep church-partnership tooling.
- **Glorify** pursues a multi-channel mix (content, SEO/ASO, social, influencer, paid) per a low-reliability source, backed by celebrity-investor PR as a credibility mechanic in itself.
- **Abide** is the most established Christian-meditation competitor by pricing/positioning ($39.99/yr, free tier of shorter meditations), but no source in this round documented its actual acquisition tactics — a genuine, flagged gap (faith.tools).
- **SmartGroups** is the closest direct feature-analog (AI + small-group + pastor dashboard) already in-market.

None of the major comparable apps combine FellowScript's specific bundle: group-priced (not individual-priced) subscriptions, a power-user dockable multi-panel Reader, and a public-note/shared-highlight social layer as core (not bolted-on) mechanics. This bundle is the clearest basis for differentiated positioning, though this synthesis is the brief's own inference from the sourced feature/competitor facts rather than a claim any single source makes directly.

### 9. Referral/virality mechanics given the group/social/AI feature set

General (non-faith-specific but independently well-corroborated, 4+ sources each) viral-loop and referral literature supports several mechanics directly applicable to FellowScript: double-sided referral rewards are the dominant proven pattern (Adapty, citing Dropbox/Uber/Airbnb precedent); progress-bar gamification ("Invite 5 friends, you've invited 3") increases referral-goal completion (Reteno); and social-recognition loops (leaderboards, spotlighting top referrers) work as a non-monetary alternative to cash incentives (Tapp) — notably relevant to FellowScript because cash incentives could clash with its reverent brand voice, while social recognition would not. Given the group-seat-priced monetization model, group-invite flows carry direct revenue upside beyond engagement, reinforcing referral/virality as a more cost-effective growth channel than paid acquisition for a small/single-developer team — a framing corroborated by indie-app-marketing sources recommending 2-3 consistently-executed low-cost channels (ASO, content, community) over broad paid spend for capacity-constrained teams (Octospark; IndieHackers; ApsteQ).

## Citations

Internal (primary, user-provided) sources — all under `/Users/jaceysimpson/Vscode/FellowScript/`:
- README.md
- docs/index.md
- docs/design/overview.md
- docs/design/home-page.md
- docs/design/community.md
- docs/design/account.md
- docs/design/notes.md
- docs/design/bible-reader.md
- docs/architecture/overview.md
- mkdocs.yml

External sources (see `sources.json` for full reliability notes and corroboration counts):
- https://www.branch.io/resources/case-study/how-hallow-drove-2-million-app-installs-and-became-1-on-the-app-store/
- https://hallow.com/blog/our-partnership-philosophy/
- https://phiture.com/success-stories/hallow/
- https://research.contrary.com/company/hallow
- https://www.consumerstartups.com/p/hallow-building-a-9-figure-prayer-app
- https://www.stjohns.edu/news-media/news/2026-03-04/hallow-app-partners-st-johns-foster-community-prayer
- https://growthcasestudies.com/p/youversion
- https://www.linkedin.com/pulse/growth-hacks-led-youversion-500-million-downloads-okoro
- https://churchtechtoday.com/youversion-bible-app-engagement-surges-how-should-churches-take-advantage-in-2024/
- https://techstartups.com/2021/12/02/softbank-celebrities-back-40-million-investment-christian-worship-meditation-app-glorify/
- https://religionnews.com/2021/12/02/michael-buble-kris-jenner-invest-in-christian-mediation-app-glorify/
- https://businessmodelcanvastemplate.com/blogs/marketing-strategy/glorify-marketing-strategy (low reliability, used only for generic multi-channel claim)
- https://faith.tools/app/29-abide?category=prayer
- https://faith.tools/small-groups
- https://theleadpastor.com/tools/best-bible-study-apps/
- https://smartgroups.app/
- https://apps.apple.com/us/app/everycampus/id6754179691
- https://www.thegospelcoalition.org/article/reach-college/
- https://reliantcreative.org/campus-ministry/
- https://www.caylor-solutions.com/faith-based-enrollment-marketing-strategies/
- https://www.frontgatemedia.com/christian-creator-partnership-strategy/
- https://www.frontgatemedia.com/faith-based-creators-youtube-tiktok/
- https://advertising.christianpost.com/blog/15-essential-marketing-tips-to-carry-your-strategy-through-the-end-of-2025
- https://www.blog.udonis.co/mobile-marketing/mobile-apps/complete-guide-to-app-store-optimization
- https://appradar.com/academy/apple-app-store-optimization-aso
- https://asomobile.net/en/blog/aso-in-2026-the-complete-guide-to-app-optimization/
- https://www.semrush.com/blog/app-store-optimization
- https://www.molfar.io/blog/viral-loops
- https://adapty.io/blog/mobile-app-referral-program/
- https://reteno.com/blog/viral-loops-encourage-users-to-promote-your-app
- https://www.tapp.so/blog/viral-loop-examples/
- https://referralrock.com/blog/viral-loop/
- https://octospark.ai/blog/bootstrapped-indie-app-growth-strategies-zero-to-100k
- https://www.indiehackers.com/post/why-indie-hackers-should-rethink-mobile-app-marketing-in-2025-8bc7b2998c
- https://apsteq.com/blog/indie-app-marketing/

## Risks

- **Unresolved internal pricing discrepancy.** docs/index.md and docs/design/home-page.md describe a 3-tier Free/Individual-$4.99/Group-$9.99 model; docs/design/account.md (more implementation-detailed) describes a single Group-only tier (1-8 members, priced by member count), with no standalone Individual plan. This brief treats account.md as more likely current per the source-gathering agent's assessment, but the discrepancy is not resolved at the source level. Any recommendation that assumes a specific pricing structure (e.g., "solo users have a cost-effective standalone paid path" vs. "all paid users are inherently group-priced") is contingent on which doc is correct, and this should be verified against the live product before being treated as settled fact downstream.
- **Faith-app-specific sourcing skews heavily toward two dominant players (Hallow, YouVersion).** Most of the strongest, most-corroborated tactical claims (parish partnerships, Lent/Easter timing, verse-sharing virality) come from these two apps' well-documented growth stories. It is not established that these tactics generalize to a smaller, group/study-centric (rather than meditation/devotional-reading) product like FellowScript — this is an extrapolation the brief and downstream stages should treat as a hypothesis, not a proven pattern for FellowScript's specific niche.
- **Abide's actual acquisition/marketing tactics are undocumented.** Only competitive-positioning/pricing data was found (faith.tools); no source confirms which channels drove Abide's scale, despite it being named in the plan as a comparable app.
- **Several sources are commercially motivated (vendor blogs, marketing agencies) rather than independent.** ASO guidance (Udonis, AppRadar, ASOmobile), referral/virality guidance (Adapty, Reteno, Tapp, ReferralRock, Molfar), and faith-creator guidance (FrontGate Media, Christian Post Advertising) are all written by vendors or agencies with a commercial interest in the tactics they promote. Corroboration counts (2-4 independent sources per claim) partially mitigate this, but none of these claims come from disinterested academic or regulatory sources.
- **One low-reliability source used narrowly.** businessmodelcanvastemplate.com (Glorify's marketing-strategy piece) is an unsourced/bylineless content-mill site; it was used only for a generic, low-risk claim (multi-channel mix) and should not be treated as authoritative if cited further downstream.
- **Single-instance claims presented as precedent rather than pattern.** The St. John's/Hallow university partnership and the EveryCampus coalition-app model are each supported by exactly one source (a press release and an App Store listing, respectively) — useful as existence proofs that these channel types are viable, but not evidence of typical results or replicability.
- **No Google Play–specific ASO research was conducted.** Treated as low-risk since FellowScript has no documented Android client, but if Android is added later this gap would need to be closed.

## Open Questions

- Which pricing structure is actually live in production — the 3-tier model in docs/index.md/home-page.md or the Group-only model in docs/design/account.md — and how does that change which growth channels are genuinely cost-effective (solo-user paid acquisition may or may not be viable depending on the answer)?
- Do Hallow's and YouVersion's parish/diocese/church-partnership and calendar-timed-campaign tactics actually transfer to a smaller, group-study-centric (vs. personal-devotional/meditation) product, or does FellowScript's group-first model call for a different partnership shape (e.g., small-group leaders and Bible-study coordinators specifically, rather than parish-wide institutional deals)?
- What does Abide — the plan's closest pricing/positioning comparable — actually do for acquisition? This remains unanswered and could materially change the competitive-differentiation analysis if surfaced.
- Given the reverent/parchment-and-gold brand identity, would monetary referral incentives (common in general SaaS/app referral programs) undermine trust with FellowScript's target audience, or is social-recognition-based referral (leaderboards, spotlighting) the only brand-safe option? The sourced material suggests social recognition is viable but doesn't test this specifically against a reverent/faith-editorial brand tone.
- Should FellowScript pursue campus-ministry-coalition partnerships (EveryCampus-style) given its small-team capacity constraints, or does the sourced caution against over-indexing on digital tactics for campus outreach (TheGospelCoalition) argue for deprioritizing this channel relative to lower-effort ASO/referral work?
- Is the AI devotional check-in feature a genuine differentiator worth marketing headline billing, given that SmartGroups already occupies a similar AI+group positioning — and if so, what specifically distinguishes FellowScript's implementation? No source in this brief resolves this; it is inferred only from feature-list comparison, not documented head-to-head.

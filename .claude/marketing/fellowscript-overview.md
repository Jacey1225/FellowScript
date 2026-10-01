# FellowScript — Project Overview (marketing planning reference)

Compiled 2026-09-10 from project docs and two prior `/research` runs. Purpose: a single reference
for building a FellowScript marketing plan without re-deriving what's already documented or
re-litigating research already done.

**Last refreshed 2026-09-13** — ran live competitive intelligence (see
`COMPETITOR-REPORT.md`) against the four named comparables. Updated: install-base/scale figures
for Hallow/YouVersion/Abide/SmartGroups, SmartGroups' church-tier pricing, and category-level
market-size figures (partial TAM data now sourced, see below). FellowScript-specific audience
data is still unmeasured — that gap did not close.

## What it is

A faith-based Bible study platform: read scripture, highlight/annotate, take rich notes, and study
with a group. Ships as a React web app and a native iOS app, both backed by a shared FastAPI +
Postgres server on AWS EC2. A Tauri-based macOS desktop wrapper also exists (signed/notarized,
shipped) — it's just a native window onto the live, cookie-authenticated web Reader, not a
separate build; Windows packaging hasn't started.

## Mission / positioning

Relational first, reading tool second: "foster meaningful connections between people who seek to
grow in their faith together" (README). The group/social layer is the core differentiator, not an
add-on to a digital Bible.

## Core features

- Digital Bible — all 66 books, chapter navigation, search
- Highlighting — multiple colors, persists per user
- Rich notes — bold/italic/underline/highlight/color formatting, linked to one or more verses,
  public or private
- Community highlights — view other members' public highlights in context
- Groups — create/join study groups; shared notes and highlights within the group
- Friends + real-time WebSocket messaging — group threads and 1-on-1 DMs
- Devotions — collaborative devotion plans shared across a group
- AI Agent — daily "heartbeat" check-ins generating devotional prompts/notes
- Bookmarks, notifications, account + subscription management
- Desktop app (macOS) — native window onto the live reader

## Differentiators (per prior research, sourced from internal docs)

- Dockable multi-panel Reader (scripture + notes + messaging side by side) — a "power user"
  reading surface no direct competitor matches
- Public-note/shared-highlight mechanic tied to real study groups, not a generic social feed
- Group-priced subscription (see Monetization) directly rewards group growth — the pricing model
  itself is a growth lever, not just a revenue mechanism. *Contested — see
  `target-audience-profile.md` §8: each added seat costs the host ~$9 more, so the free
  (uncapped) group layer is the growth lever and per-seat pricing is how it's monetized after.*
- Warm parchment-and-gold, reverent-editorial visual identity (Playfair Display / Lora / IM Fell
  English) — distinct from the flat/utility look of most Bible apps

## Monetization — resolved discrepancy

Two docs disagree; **`docs/design/account.md` (most current) is authoritative**:

- **Actually live in production**: one paid tier — **Group** (1–8 members), priced by member
  count. No separate "Individual" plan exists; a 1-member group covers that case. Free tier caps
  notes/week and agent-event usage. Billing: Stripe Checkout (web), StoreKit 2 (iOS).
- **Stale**: `docs/index.md` and the home page copy still describe a three-tier Free ($0) /
  Individual ($4.99/mo) / Group ($9.99/mo) structure. Do not build pricing messaging on this until
  someone confirms whether it's aspirational or just outdated docs.

## Audience / demographics

No user analytics or survey data exists anywhere in the repo — FellowScript-specific audience
data is still genuinely unmeasured, and the 2026-09-13 refresh did not close this gap (no
sourced way to get first-party data on a private product from outside). Everything below the
line is still inferred from product shape, not measured:

- Christians already doing structured Bible study, individually or in small groups — built around
  group study, not casual/solo devotional browsing
- Primary adoption decision-makers are **small-group leaders**, not individual end-users in
  isolation. Note the correction: the leader is an *adoption* gatekeeper (they have the relational
  authority to move a group), **not** an *access* gatekeeper — nothing in the group layer is
  actually paywalled. Pastors are a referral channel, not the buyer.
- Group cap of 8 members fits independent/non-denominational small groups and campus-adjacent
  study groups better than large parish/diocese structures — nothing in the product targets
  institutional/diocese-scale adoption today. Note the correction: the cap of 8 is on **paid plan
  seats**, not on group size — study groups themselves are uncapped.
- No age, geography, or denomination data collected or documented — a real gap, flag it rather
  than inventing numbers for a marketing plan

**→ Fuller ICP reasoning: [`target-audience-profile.md`](target-audience-profile.md)** (written
2026-09-13). Traces the best-fit audience to specific product facts — the real `GROUP_PRICE_CENTS`
table, where `check_limit` is and isn't enforced, the 66-book ESV-only text, the group-taggable
31-day heartbeat, the activity broadcast — and covers the primary ICP pair (preparing lay leader
as buyer / committed core member as conversion trigger), decision-maker vs end-user, secondary
segments, explicit non-fits, positioning consequences, and a lightweight validation plan.
**Same caveat applies in full there: it argues who the product is *built for*, not who uses it.
Still inferred, still unmeasured.** That file also corrects two claims this section previously
carried (the two "note the correction" points above) and one in Differentiators above — see its
§1.1, §1.2 and §8.

**Sourced category context (new, 2026-09-13)**: mass-market comparables skew heavily global and
broad — YouVersion reports 80%+ of its 1B+ installs come from outside the US, with India, Africa,
and Latin America prominent (per its own published milestones). That scale/geography profile is
not evidence about FellowScript's own likely audience — it describes a different product
category (solo daily-reading habit apps) from FellowScript's small-group/leader-first niche — but
it does confirm the mass-market segment is not where FellowScript is competing, which supports
the existing leader-first recommendation below rather than undermining it.

## Market / competitive context

- Comparable apps, with scale now sourced (2026-09-13, see `COMPETITOR-REPORT.md` for full
  detail):
  - **Hallow** — celebrity-backed, parish-partnership-driven. ~10-11M downloads total, ~220K/mo
    recent run-rate, 4.68/5 across ~120K ratings. Free with paid tier (not independently
    re-verified this pass — see report).
  - **YouVersion** — SEO/habit-loop dominant, by far the largest install base: passed 1 billion
    device installs (Nov 2025), 10-12M new installs/month, ~66K concurrent app-opens/second.
    Free, ad-free, no group-priced tier — not really a pricing comparable, more a gravity well.
  - **Abide** — closest pricing/positioning comparable. 20M+ downloads. Premium $9.99/mo or
    $39.99/yr (cheapest of the scaled competitors, family sharing included). Growth tactics
    beyond paid subscription still undocumented anywhere found.
  - **SmartGroups** — closest feature comparable (AI + group study). Free forever for one group,
    unlimited members. Church/multi-group upgrade **now confirmed at $59/month** (previously
    undocumented) for 2+ groups, branding, pastor dashboard, priority support — notably not
    per-member pricing, unlike FellowScript's group-priced model.
- No competitor combines FellowScript's specific bundle: group-priced subscriptions + a
  power-user Reader + a built-in social/sharing layer. That's the clearest basis for
  differentiated positioning — still the research's own inference, not a verified market gap, but
  nothing in this pass's competitor pricing/feature check contradicted it.
- **TAM/SAM — partially closed, treat cautiously.** Multiple market-research-vendor reports (not
  primary data, moderate confidence) size the category several different ways: the Bible Study
  Software market at ~$1.2B (2024) growing to ~$2.5B by 2033 (8.9% CAGR) per one vendor, versus
  ~$1.42B (2026) to ~$10.55B by 2035 per another — the two disagree substantially, which is itself
  worth flagging rather than picking whichever number is more flattering. The broader Spiritual
  Wellness Apps category is sized at ~$2.9B (2026) growing to ~$9.9B by 2035 (14.66% CAGR).
  None of these vendors publish methodology in the search-visible summaries, so treat these as
  directional (the category is real and growing double-digit%), not as defensible numbers for a
  client-facing deck without checking the underlying report.

## Prior research — read before starting anything new

Two full `/research` pipeline runs already cover this exact ground. Re-read their conclusions
before re-researching the same questions:

- `.claude/research/20260814-fellowscript-marketing/conclusion.md` — channels, monetization/
  referral strategy, comparable-app positioning, ASO. **Recommends**: prioritize group-invite/
  referral growth over paid acquisition; position on the group + Reader + sharing bundle; treat
  church-calendar timing as a secondary lever only, not a proven standalone driver.
  **Debunked, don't reuse**: the "83% higher referral trust" stat (misattributed) and the "30%
  user increase from Catholic-org partnerships" stat (untraceable).
- `.claude/research/20260815-fellowscript-outreach-tactics/conclusion.md` — gatekeeper/channel
  outreach specifically. **Recommends**: leader-first outreach — free-tier/pilot offers direct to
  small-group leaders and pastors, hands-on first-meeting onboarding, champion-sourcing through
  existing ministry networks — over diocese/institutional partnerships. **Defer** campus-ministry
  coalitions for now (small-team capacity risk; unproven, not disproven).

Both explicitly flag open questions worth resolving before finalizing a plan (their own "Open
questions" sections) — notably, no faith-specific precedent yet exists for the leader-first
strategy being recommended; it's currently an educated bet, not a proven playbook.

## Notes for building the marketing plan

- Don't put the three-tier pricing in customer-facing messaging — it's not what the app actually
  charges today.
- Don't cite the 83% referral-trust or 30% Catholic-partnership stats — both debunked.
- Strongest, least-contested asset to build a plan around: leader-first, referral/group-invite
  growth, positioned on the group + Reader + sharing bundle — not paid acquisition, not
  institutional/diocese partnerships.

---
Sources: `README.md`, `docs/index.md`, `docs/design/overview.md`, `docs/design/home-page.md`,
`docs/design/account.md`, `docs/architecture/overview.md`, `desktop/PROGRESS.md`,
`.claude/research/20260814-fellowscript-marketing/conclusion.md`,
`.claude/research/20260815-fellowscript-outreach-tactics/conclusion.md`,
`.claude/marketing/COMPETITOR-REPORT.md` (2026-09-13 refresh — Hallow/YouVersion/Abide/SmartGroups
scale and pricing, category market-size estimates). Note: `fellowscript.com` itself returned
HTTP 403 to automated fetch during the refresh and was not re-verified live — FellowScript's own
messaging claims above still rest on the local docs, not a live homepage check.

# FellowScript — Ideal Customer Profile / Best-Fit Audience Analysis

**Written 2026-09-13.** Companion to `fellowscript-overview.md` (the compact reference) and
`COMPETITOR-REPORT.md` (the competitive intel). This file holds the depth; the overview holds
the summary.

---

## Read this first: what this document is and is not

**This is a reasoned argument about who the product is *built for*, derived from what the product
actually does, charges, and excludes.** Every claim below is traced to a specific artifact in this
repo — a price table, a limit constant, a route, a docs section.

**This is NOT a claim about who is using FellowScript today.** There is still zero first-party
analytics, zero survey data, and zero usage telemetry anywhere in this repo. Nobody has measured a
single FellowScript user. That gap did not close for this document and is not closed by it. The
2026-09-13 competitor refresh did not close it either.

Keep the two ideas apart, permanently:

| Statement | Status |
|---|---|
| "The product's feature set, pricing, and exclusions point at segment X" | **Supported** — that's what this file argues |
| "Segment X is who uses FellowScript" | **Unsupported** — no data exists, do not claim this |
| "Segment X converts at N%" | **Fabrication** — do not produce numbers like this |

§9 below is the lightweight path to converting the inferred profile into a validated one.

---

## 1. Evidence base — the product facts this ICP rests on

These are the load-bearing findings. Three of them **sharpen or correct** what
`fellowscript-overview.md` currently says, so they're flagged as such.

### 1.1 The 8-member cap is a *billing-seat* cap, not a group-size cap — CORRECTION

`api/schemas/subscription.py` sets `MIN_MEMBERS = 1`, `MAX_MEMBERS = 8` on the **subscription**.
`api/backend/interactions/groups.py`'s `create_group()` and the `groups.users` column impose **no
member limit at all**, and `api/routes/groups.py` enforces none.

So a 30-person study group works fine on FellowScript. Only eight people can sit on one paid plan.
The overview's line — *"Group cap of 8 members fits independent/non-denominational small
groups"* — is directionally right about the target but describes the wrong constraint. The cap
governs **who is paid for**, not **who can participate**.

### 1.2 The paywall does not gate the group/social layer at all — CORRECTION, and the sharpest finding here

`check_limit` is called from exactly two places in the entire API: `api/routes/notes.py`
(lines 190, 233) and `api/routes/agent.py` (lines 185, 245, 295). The free-tier caps are
`FREE_LIMITS = {"notes": 10, "agent_events": 1}` over a rolling
`NOTES_WINDOW_DAYS = 7` (`api/schemas/subscription.py`).

Nothing else is gated. Groups, group chat, DMs, WebSocket real-time messaging, community
highlights, shared/public notes, bookmarks, attachments (S3 + GIF), devotion plans, and the
Amazon Chime study calls (`docs/design/community.md`) are **all free, uncapped, forever**.

This inverts the premise the overview currently reasons from. The overview says *"group-gated
features mean one leader's buy-in unlocks a whole group."* Against the code, that is not true:
**nothing in the group layer is behind the paywall.** What the paid plan actually sells is
*personal study capacity* — unlimited notes and unlimited AI heartbeats — purchased in bulk on
behalf of up to eight named people.

The consequence for the ICP is large and runs through the rest of this document: the buyer is a
**sponsor/benefactor**, not an access gatekeeper. A leader does not need to buy anything to run
their group here. They buy to remove a ceiling their most engaged members are hitting.

### 1.3 Real price points, and what they imply about who can afford this — SHARPENING

The server-authoritative table (`api/schemas/subscription.py`, `GROUP_PRICE_CENTS`):

| Seats | Price/mo | Marginal seat | Effective $/head |
|---|---|---|---|
| 1 | $10.00 | — | $10.00 |
| 2 | $17.99 | +$7.99 | $9.00 |
| 3 | $26.99 | +$9.00 | $9.00 |
| 4 | $35.99 | +$9.00 | $9.00 |
| 5 | $44.99 | +$9.00 | $9.00 |
| 6 | $53.99 | +$9.00 | $9.00 |
| 7 | $62.99 | +$9.00 | $9.00 |
| 8 | $71.99 | +$9.00 | $9.00 |

`TRIAL_MONTHS = 1` — every plan opens with a one-month free trial. `EXPIRY_GRACE_DAYS = 3`.
Price is never trusted from the client; the host picks a seat count and the server looks up the
price.

Set against `COMPETITOR-REPORT.md`: Abide is **$9.99/mo or $39.99/yr for an individual, with
family sharing included**. SmartGroups is **$0/mo for one group with unlimited members**, and
$59/mo flat for a multi-group church tier. A full 8-seat FellowScript plan is **$863.88/year** and
is the **most expensive per head of any comparable in the set** — for a paid delta of "unlimited
notes + unlimited AI check-ins," since everything social is already free.

This is not an argument that the price is wrong. It is an argument that **the ICP is narrow by
construction**: it has to be people who (a) genuinely write more than 10 notes a week, and (b) find
$9/head either trivial or emotionally worth it. Most Christians do neither. That is fine — it's a
niche product — but it must not be marketed as though the addressable audience is "Christians."

### 1.4 One English translation, 66 books, no selector

`api/backend/interactions/bible_data/bible.json` is a single bundled text keyed by book name.
Sampled text and section headings — Gen 1:1 *"In the beginning, God created the heavens and the
earth"*, the heading *"The Creation of the World"*, Gen 3:1 *"more crafty than any other beast of
the field"*, bracketed footnote markers — **match the ESV**. README confirms "all 66 books." No
translation-selection mechanism exists anywhere in the data layer, and no i18n framework is present
in either client (`frontend/src`, iOS source — the only matches are inside build-dependency
checkouts).

Three hard consequences: no deuterocanon (structurally excludes the Catholic 73-book and Orthodox
canons), no translation preference for KJV-only / NIV-preferring / NASB audiences, and no
non-English audience at all. Compare SmartGroups: 25+ languages.

**Action item, not a marketing claim:** if ESV text is being distributed in a paid app, Crossway's
licensing terms should be confirmed by someone before "ESV" appears in any public-facing
messaging. This document identifies the translation by text inspection; it makes no statement about
the license status.

### 1.5 The AI agent is deliberately interdenominational and pastoral

`api/backend/interactions/agent_prompt.txt` instructs the agent to *"acknowledge different
denominational perspectives fairly"* and to be *"a safe, supportive presence for users experiencing
distress, grief, doubt, or hardship."* Combined with §1.4, the product's theological posture is
**broad-tent Protestant / non-denominational**: no confessional specificity, but a Protestant canon.

### 1.6 The heartbeat is a curriculum-delivery mechanism for leaders

Per `docs/design/account.md`: a heartbeat fires on a schedule against a **31-day upfront timeline**
(each firing day covers planned new content, per `agent_prompt.txt`), can be **tagged to a group**
(2026-09-02), and the generated note **inherits that `group_id`** so group members see it through
the existing group-notes read path. iOS adds a manual force-fire button.

This is the single most leader-shaped feature in the product: schedule a month of content into your
group's shared feed. It is also the feature the free tier limits hardest — `agent_events: 1`.

### 1.7 The product broadcasts who is studying

`docs/design/community.md`: the WebSocket carries an `activity` event — *"Member is reading /
highlighting / noting (broadcast by server)."* Plus public notes, community highlights visible
in-context, and group highlight overlays on the scripture view.

FellowScript is an **accountability-and-visibility** product. That is a feature for a covenant
group and an active harm for someone who wants to read privately.

### 1.8 Desktop + three-panel Reader = prep behavior, not commute behavior

`docs/design/overview.md` documents the three-panel web grid (nav / scripture / notes-or-messaging).
`docs/design/home-page.md` §7 documents the shipped, signed-and-notarized macOS desktop app.
`fellowscript-overview.md` calls the dockable multi-panel Reader a power-user surface no competitor
matches.

Every comparable in `COMPETITOR-REPORT.md` — YouVersion, Hallow, Abide — is a **phone-first habit
app**. A desktop window with scripture, notes, and group chat side by side is a **sit-down
preparation session**. The people who sit down at a desk to study scripture with their notes open
are, overwhelmingly, people who are **studying in order to teach or lead**.

### 1.9 Synchronous group rhythm is supported

Devotion plans with participants (`api/backend/interactions/devotion.py`), push notifications,
and live Chime voice/video study sessions inside a thread (`docs/design/community.md`, 2026-09-04).
The product assumes a group that **meets**, not a loose feed of individuals.

### 1.10 A benefactor payment surface already exists

`api/routes/donation.py` accepts one-time Stripe donations from $1 to **$10,000**. Whether or not
it's promoted, the product already anticipates patron-shaped money — which is the same psychology
as sponsoring someone else's seat (§1.2).

---

## 2. The buying unit: a pair, not a person

The most accurate unit of analysis is not an individual. It is a **group with a leader**, and the
ICP is a *pair of roles inside it*.

```
                 ┌─────────────────────────────────────────────┐
                 │  THE BUYING UNIT: one recurring study group  │
                 └─────────────────────────────────────────────┘
                                     │
        ┌────────────────────────────┴────────────────────────────┐
        │                                                          │
  ICP-A: THE PREPARING LEADER                      ICP-B: THE COMMITTED CORE
  ─ chooses the tool (relational                   ─ 2–4 people per group who
    authority to move a group)                       actually read and write
  ─ preps weekly, high note volume                 ─ the ones who hit the
  ─ pays first (1 seat, $10)                         10-notes/week ceiling
  ─ later sponsors seats for the core              ─ the actual conversion trigger
        │                                                          │
        └──────────────► adoption flows down       ─────────────────┘
                         conversion pressure flows UP
```

Adoption flows **down** from ICP-A. Conversion pressure flows **up** from ICP-B. Miss either half
and the model doesn't work: a leader who adopts but whose members never write hits no cap and never
pays; an individual heavy note-taker with no group is paying $10/mo for a note editor with one
translation, and will churn.

---

## 3. Primary ICP

### ICP-A — The Preparing Leader *(decision-maker)*

**Who:** A lay small-group leader or volunteer Bible-study teacher in a non-denominational or
broadly evangelical Protestant church, leading a recurring group of roughly 6–15 people that meets
weekly or biweekly. Not clergy (see §4). Usually bivocational/volunteer — this is not their job,
which is why tooling friction matters to them.

**Behavior pattern (the part that actually qualifies them):**
- Prepares in a dedicated session at a desk or laptop, not in five-minute phone windows (§1.8)
- Writes substantially while preparing — outlines, questions, cross-references — well past 10
  notes a week (§1.3)
- Wants what they wrote to be *visible to the group*, not filed privately (public notes,
  §1.2/§1.7)
- Already has the relational authority to say "we're using this now" and have it stick

**Why the product points here — feature by feature:**

| Product fact | What it implies about ICP-A |
|---|---|
| Three-panel dockable Reader + macOS desktop app (§1.8) | Built for a seated prep session, not a commute — teaching prep, not devotional browsing |
| Group-taggable 31-day heartbeat whose notes land in the group feed (§1.6) | A curriculum-delivery tool. Only a leader has a reason to schedule a month of content *into someone else's feed* |
| `agent_events: 1` on free tier (§1.2) | The exact feature a leader needs most is the one the free tier restricts hardest — a precise conversion lever aimed at leaders |
| Public/shared notes + community highlights (§1.7) | Assumes someone whose study is *for others*. A private studier gets no value from making notes public |
| Chime study calls + devotion plans w/ participants (§1.9) | Assumes a group that meets on a rhythm, which implies someone convening it |
| Host-owned plan with request/approve seat enrollment (`create_request`/`accept_request`) | The plan structure literally models one person admitting others — an owner role, not a peer group |
| 66-book ESV, interdenominational agent (§1.4, §1.5) | Broad-tent Protestant; a church-adjacent lay leader, not a confessionally-specific one |

**Their purchase path:** buys **one seat at $10/mo** for themselves first, to lift their own note
cap and run more than one heartbeat. Expands to 3–5 seats later, to cover the core (§3, ICP-B) —
not to cover the whole group, which §1.3's economics make unattractive above ~5 people.

### ICP-B — The Committed Core Member *(end-user, and the actual conversion trigger)*

**Who:** The 2–4 people in any real study group who do the reading between meetings, journal, and
want to see what the leader and each other wrote. Any age; the qualifier is behavioral, not
demographic.

**Why they matter more than headcount suggests:** per §1.2, **the paid tier is bought for them, not
for the leader's convenience.** They are the ones who hit 10 notes in 7 days. The purchase event is
*their* friction, surfaced to the host. The Account page's own upgrade copy names it exactly:
*"Upgrade to unlock unlimited notes, AI check-ins, and notifications."*

**Why they stay:** community highlights and shared notes mean their study is seen and reciprocated.
The activity broadcast (§1.7) makes participation legible. This is the retention mechanic, and it is
free — which is why it works as a growth loop (§8).

### What "best fit" means in one sentence

> A weekly-meeting, non-denominational Protestant small group of 6–15 people, led by a lay leader
> who preps at a desk and writes a lot, containing 2–4 members engaged enough to hit a
> 10-note-per-week ceiling — where the leader is willing to pay ~$9/head to lift that ceiling for
> the core few, not for everyone.

Every clause is load-bearing, and each traces to §1.

---

## 4. Decision-maker vs end-user — testing "leader-first," and demoting "pastor"

The overview asserts: *"Primary adoption decision-makers are small-group leaders and pastors, not
individual end-users in isolation — group-gated features mean one leader's buy-in unlocks a whole
group."*

Tested against the product, that splits into one claim that holds and two that don't.

### Holds: the leader is the adoption decision-maker

Nothing in the product gets its value from a solo user. Public notes need readers; community
highlights need a community; devotions and Chime calls need participants; the activity broadcast
needs someone to broadcast to. A group arrives as a group, and groups move when the person
convening them moves. **Leader-first is correct.**

### Fails: "group-gated features mean one leader's buy-in unlocks a whole group"

Per §1.2 this is factually wrong against the code. **The leader is an adoption gatekeeper, not an
access gatekeeper.** Their buy-in unlocks nothing, because nothing in the group layer is locked.

This matters operationally, not just pedantically. Messaging built on "unlock your group" writes a
cheque the product refuses to cash: a leader who upgrades expecting to switch on group features
discovers they already had them, and that what they bought was note quota. That is a
disappointment at exactly the moment you least want one. The correct pitch is the opposite shape:
**"start free this week; upgrade when your people outgrow the cap."**

### Fails: pastors as decision-makers — demote to *channel*, not *buyer*

A senior or solo pastor is a **worse** buyer than a lay small-group leader, for three concrete
product reasons:

1. **FellowScript doesn't do sermon prep.** One translation, no lexicon, no commentaries, no
   cross-reference apparatus, no original languages (§1.4). Pastors prep in Logos/Accordance.
   FellowScript is not in that race and should not enter it.
2. **There is no product a pastor could buy for their church.** One host, one plan, eight seats max
   (§1.1, §1.3). No org tier, no multi-group admin, no pastor dashboard, no church branding, no
   per-church billing. A pastor covering six groups would need six separate plans at
   $71.99 = **$431.94/mo** — versus SmartGroups' **$59/mo** church tier, which explicitly includes
   the dashboard and branding a pastor would want (`COMPETITOR-REPORT.md`). Against a
   church-budget buyer, FellowScript loses on both price and feature surface, badly.
3. **No group-health instrumentation.** SmartGroups ships attendance, prayer, and group-health
   tracking. That's the pastor's actual job-to-be-done; FellowScript has none of it.

**So:** pastors are a **referral channel and credibility source** — they know every small-group
leader in the building and can bless a pilot. They are not the buyer. The prior research's
recommendation (`.claude/research/20260815-fellowscript-outreach-tactics/conclusion.md`) to run
leader-first outreach with champion-sourcing through ministry networks is **right**; this analysis
sharpens *why* — the pastor is the introduction, the lay leader is the decision, the core member is
the conversion.

### The three roles, cleanly separated

| Role | Who | What they actually do | What moves them |
|---|---|---|---|
| **Channel / blesser** | Pastor, campus staff worker, ministry-network peer | Introduces, lends credibility, green-lights a pilot | Trust, low risk, no budget ask, no admin burden |
| **Decision-maker / adopter** | Lay small-group leader (ICP-A) | Chooses the tool, moves the group, pays first | "My prep is scattered"; heartbeat curriculum; free to try |
| **End-user / conversion trigger** | Committed core members (ICP-B) | Read, write, hit the cap | Seeing others' notes; the 10-note ceiling |

---

## 5. Secondary / expansion segments — on the radar, not built for

Ordered by how close each is to being servable today.

**5.1 Campus and college ministry groups** *(good fit, blocked on price)*
InterVarsity/Cru/Navigators-shaped groups meet weekly, are laptop-native, write a lot, and are
comfortable with an ESV. The blocker is purely economic: students will not pay $9/head, the price
table has no student or bulk discount mechanism, and any purchase would need a staff-worker sponsor.
Prior research already deferred campus coalitions on small-team-capacity grounds; this analysis adds
a *second, independent* reason to defer — **the pricing model can't serve them as built.** Deferred,
not disproven.

**5.2 Geographically-scattered groups that cannot meet in person** *(genuinely under-served; not in the overview)*
Diaspora and expat groups, military families, homebound or chronically-ill members, and
cross-city friend groups. The Chime study call + shared async notes + real-time presence combination
is meaningfully differentiated **specifically for groups whose alternative is nothing**, and their
willingness to pay is structurally higher because there is no free physical substitute. Nothing in
the product targets this today and nothing blocks it. This is the most interesting untested
expansion bet found in this analysis and deserves a named place on the roadmap conversation.

**5.3 Couples and family devotions** *(weak)*
The 2-seat tier at $17.99/mo is the second-cheapest entry point and devotions/shared notes fit the
use case. But Abide bundles family sharing into $39.99/**year** — a ~5.4x annual gap
($215.88 vs $39.99). Don't build messaging here.

**5.4 Seminary cohorts and intensive discipleship programs** *(blocked on product, not audience)*
Note volume and prep behavior are ideal. They need multiple translations and original-language
tools that don't exist (§1.4). Revisit only if a translation layer ships.

**5.5 Church-staff discipleship tracking** *(explicitly not ready)*
Per §4, the org-tier product doesn't exist. Do not pursue until it does.

---

## 6. Explicit non-fits — who this is visibly not for

Naming these protects the budget. Each is a structural exclusion, not a preference.

1. **Catholic and Orthodox users and parishes.** 66-book ESV, no deuterocanon, no canon option
   (§1.4). This is a hard structural non-fit until a translation layer exists — and it means
   **Hallow's parish-partnership playbook is not transferable to FellowScript**, regardless of how
   attractive it looks in the competitor report. Prior research already deferred diocese
   partnerships; this is the underlying reason.

2. **Casual daily-devotional readers.** The free tier — 10 notes/week, forever, plus the entire
   uncapped social layer — already serves them completely (§1.2). They will never hit the cap and
   will never convert. YouVersion is free, ad-free, and better at habit loops at a billion-install
   scale. Acquiring this segment costs money and returns zero. **Do not spend on them.**

3. **Private, doubting, or deconstructing readers.** Activity broadcast, public notes, and
   community highlights (§1.7) make study *visible by design*. Someone processing doubt quietly, or
   in a family or country where visible Bible study carries risk, is actively anti-served by the
   core mechanic. Note the tension: the AI agent is explicitly built to meet doubt with care
   (§1.5), but the surrounding social layer is built on visibility. The agent invites the private
   struggler; the product then exposes them.

4. **Sermon-prep professionals and serious exegetes.** One translation, no lexicon, no commentary,
   no cross-references (§1.4). Logos and Accordance own this and FellowScript isn't competing.

5. **Large churches and institutional/multi-group buyers.** 8 seats, one host, no org billing, no
   multi-group admin, no dashboard, no branding (§1.1, §4). Structurally unable to serve the buyer
   SmartGroups' $59/mo tier is purpose-built for.

6. **Non-English and global mass-market audiences.** Single bundled English text, no i18n in either
   client (§1.4). YouVersion's profile — 80%+ of installs outside the US, India/Africa/Latin America
   prominent (`COMPETITOR-REPORT.md`) — describes a market FellowScript **cannot serve at all
   today**, not one it's merely choosing not to prioritize.

7. **Anyone price-shopping against a free alternative.** SmartGroups is $0 for one unlimited-member
   group with AI-generated lessons. A prospect who frames the choice as "which group Bible study app
   is cheapest" is lost before the conversation starts. This segment must be *reframed* (§8) or
   conceded.

---

## 7. Demographics — what can and cannot be said

**Can be said, with the product as evidence:**
- Protestant canon; broad-tent / non-denominational rather than confessionally specific (§1.4, §1.5)
- English-speaking (§1.4)
- Has a laptop or desktop and uses it for study (§1.8) — skews toward adults with a desk, and away
  from phone-only users
- Has both iOS and web available; macOS desktop shipped, **Windows not started**
  (`fellowscript-overview.md`) — a real coverage gap given Windows' share of home desktops
- Financially able to absorb $10–$72/mo discretionary (§1.3)

**Cannot be said, and must not be invented:** age, gender, income, region, church size, denomination
breakdown, education, tenure in faith. None of it is collected. If a marketing plan needs these
numbers, the honest answer is §9, not an estimate.

---

## 8. What this does to the existing positioning

The overview's standing recommendation: **leader-first, referral/group-invite growth, positioned on
the group + Reader + sharing bundle.** Sharpening the ICP changes three things about it.

### Reinforced: leader-first, and referral/invite growth

§3 and §4 support both. The invite loop is now *better* explained than before: group invites are
**free and uncapped** (§1.2), which is precisely what makes them viral-capable. A paywalled invite
would kill the loop. Keep the recommendation; the mechanism is sounder than the overview realized.

### Complicated: "group-priced subscription is a growth lever"

The overview lists as a differentiator that the group-priced subscription *"directly rewards group
growth — the pricing model itself is a growth lever, not just a revenue mechanism."*

Against §1.3, that's backwards. Each added seat **costs the host $9 more**. Growing the paid plan
makes the host's bill go up; it rewards nothing. What actually grows for free is *group membership*,
which is uncapped and unpriced.

Corrected framing, which is still a good story:
> **The free tier is the growth lever — the group layer is uncapped, so a group can grow without
> limit at zero cost. The per-seat price is how that free growth is monetized afterward, one
> engaged member at a time.**

That's honest, still differentiated (no comparable monetizes per-engaged-member inside a free
group), and it won't collapse the first time someone checks the price table.

### Re-aimed: the CTA and the success metric

- **Replace "unlock your group" with "start free this week."** Per §4, nothing is locked. The
  leader-facing ask is adoption, not purchase, and it should be **free, immediate, and
  zero-risk** — which also matches what the pastor-as-channel (§4) can comfortably bless.
- **Stop optimizing for signups; optimize for group activation.** A signup with no group is a
  non-fit by §2. The meaningful early metric is *a group with ≥3 members who have each written a
  note in the last 7 days* — the state that both retains (§3, ICP-B) and eventually converts.
- **Sell the paid tier as sponsorship, not as access.** "Cover your core" is the truthful frame
  (§1.2): a leader lifting the ceiling for the 3–4 people doing the most work. The existing
  donation surface (§1.10) suggests benefactor psychology is already anticipated in the product.
- **Say "small-group leader," not "pastor," in top-of-funnel copy** (§4) — until an org tier exists,
  pastor-facing copy promises a product that isn't there.

### The competitive line this ICP implies

Against SmartGroups (the nearest real competitor per `COMPETITOR-REPORT.md`), do not compete on
price — they're free and FellowScript is the most expensive per head in the set (§1.3). Compete on
the axis the products genuinely differ on:

> SmartGroups generates lessons **about** scripture. FellowScript is where a group **reads and marks
> up** scripture together — the text, the highlights, and each other's notes in one window.

That's defensible from §1.8 (the three-panel Reader has no equivalent among the four comparables)
and §1.7 (shared highlights in-context). It also avoids the price fight entirely.

### Two things this analysis says to stop carrying forward

- The claim that group features are gated behind the leader's purchase (§1.2 / §4) — it's wrong and
  it produces broken promises in copy.
- Any consideration of the Hallow parish playbook (§6.1) — the canon mismatch makes it inapplicable,
  not merely deprioritized.

---

## 9. Validating this — the lightweight path

The goal is to move the profile from *inferred* to *measured* without a research project. Almost
all of it is already sitting in the database.

### 9.1 Free today — derivable from existing tables, zero new collection

| Question | Where it already lives |
|---|---|
| **How big are real groups?** (tests §1.1 and the whole "6–15" assumption) | `groups.users` array length, distributed |
| **How many seats do hosts actually buy?** (tests §3's "3–5 seats, not 8") | `subscriptions.max_members` histogram |
| **Is sponsorship actually happening?** (tests §1.2's core inference) | Ratio of seat-holders to hosts — `users.subscription_id` grouped by plan vs `subscriptions.user_id` |
| **Who hits the cap, and how often?** (the real conversion trigger, §3 ICP-B) | `check_limit` already computes used-vs-limit; **log the denial event** — a one-line change in `api/backend/subscription/limits.py` |
| **Do groups activate?** (the metric proposed in §8) | Time from group creation to the 3rd distinct note author in that group |
| **Rough geography, free** | The **timezone** field already collected on the Account page (`docs/design/account.md`) is a usable region proxy with no new collection at all |

The cap-denial log is the single highest-value item on this list and is nearly free to add.

### 9.2 Two optional onboarding fields — ~10 seconds, resolves the central question

At signup, optional, skippable:

1. **"What brings you to FellowScript?"** → *I lead a group* / *I'm part of a group* / *I study on
   my own* / *I'm on church staff*
   This one field resolves the decision-maker-vs-end-user split (§4) — the crux of this entire
   document — and does it on day one.
2. **"Do you already meet with a group?"** → *Weekly* / *Monthly* / *Not yet*
   Tests §1.9's assumption that the ICP has an existing meeting rhythm, and separates ICP-A/B from
   the §6.2 non-fit.

One more, at **group creation** (`AddGroupSheet` / web create-group): a single dropdown for group
context — *church small group / campus / family / online-only / other*. That one field is what would
confirm or kill the §5.2 scattered-groups hypothesis.

### 9.3 What not to do

- **No demographic survey at signup.** Age, income, and education cost conversion and buy little
  here.
- **Don't ask denomination.** §1.4 answers it structurally — the product ships a Protestant canon,
  so the audience is Protestant by construction. Asking invites people the product can't serve.
- **Don't commission market research to size the segment.** `COMPETITOR-REPORT.md` already shows
  vendor TAM estimates diverging ~4x for nominally the same category. First-party data on a few
  hundred real groups is worth more than any of it.

### 9.4 Before shipping any of this

New optional profile fields are newly-collected personal data. Per the project's own
`security-compliance` skill, that warrants a review pass (privacy policy coverage, App Store privacy
disclosures, retention) before the field ships — not after.

---

## 10. Caveats and open questions

- **Everything here is inference from build artifacts.** Real users may look nothing like this.
  That is exactly what §9 exists to find out.
- **Docs drift from code, provably.** `docs/design/home-page.md` still advertises a Free /
  Individual $4.99 / Group $9.99 three-tier structure that does not match
  `api/schemas/subscription.py`'s actual `GROUP_PRICE_CENTS` table (§1.3) — the same discrepancy
  `fellowscript-overview.md` already flags. **This analysis prices from the code.** The live home
  page showing stale pricing is also a live conversion problem, independent of the ICP question.
- **The ESV identification is from text inspection**, not a license file or manifest. §1.4's action
  item stands.
- **fellowscript.com was not verified live** — it returned HTTP 403 to automated fetch during the
  2026-09-13 competitor refresh, so no claim here rests on the live site's current messaging.
- **Windows desktop is unstarted** (`fellowscript-overview.md`), which materially narrows the §1.8
  desktop-prep segment. Worth sizing before leaning hard on the desktop story.
- **Unresolved, and worth deciding deliberately:** the §6.3 tension — the AI agent is built to
  welcome doubt and grief, while the social layer is built on visibility. Those pull in opposite
  directions for the same person. Whether the answer is a private-by-default mode, clearer
  visibility controls, or an explicit decision to serve only the visible-study audience, it is a
  product decision with direct ICP consequences and should not be left implicit.

---

## Sources

**Repository — product facts (primary evidence):**
- `README.md` — mission, feature list, 66 books, mobile-first framing
- `api/schemas/subscription.py` — `GROUP_PRICE_CENTS`, `MIN_MEMBERS`/`MAX_MEMBERS`, `TRIAL_MONTHS`,
  `EXPIRY_GRACE_DAYS`, `FREE_LIMITS`, `NOTES_WINDOW_DAYS`
- `api/backend/subscription/subscriptions.py` — host-owned plans, seat enrollment via
  `create_request`/`accept_request`, `_member_count` cap enforcement
- `api/backend/subscription/limits.py`, `api/routes/notes.py`, `api/routes/agent.py` — the only
  `check_limit` call sites in the API (the basis for §1.2)
- `api/backend/interactions/groups.py`, `api/routes/groups.py` — no group-size cap
- `api/backend/interactions/devotion.py` — devotion sessions and participants
- `api/backend/interactions/agent_prompt.txt` — interdenominational/pastoral posture, 31-day
  heartbeat timeline, note-creation actions
- `api/backend/interactions/bible_data/bible.json` — single bundled English text, headings and
  wording matching the ESV
- `api/routes/donation.py` — $1–$10,000 one-time donation surface

**Repository — documentation:**
- `docs/design/account.md` — authoritative subscription model, free-tier caps, heartbeat events,
  group tagging, timezone field
- `docs/design/overview.md` — three-panel Reader grid, visual identity
- `docs/design/home-page.md` — landing-page sections, desktop cards, **stale** three-tier pricing
- `docs/design/community.md` — groups, DMs, activity broadcast, attachments, Chime study sessions
- `docs/architecture/overview.md` — clients, stack, billing paths, deployment

**Marketing references:**
- `.claude/marketing/fellowscript-overview.md` (2026-09-13 refresh) — the compact planning reference
  this file expands on
- `.claude/marketing/COMPETITOR-REPORT.md` (2026-09-13) — Hallow / YouVersion / Abide / SmartGroups
  scale, pricing, category sizing

**Prior research (conclusions reused, not re-derived):**
- `.claude/research/20260814-fellowscript-marketing/conclusion.md`
- `.claude/research/20260815-fellowscript-outreach-tactics/conclusion.md`

**Not used:** no external research, no web sources, and no usage or survey data — none of the last
exists.

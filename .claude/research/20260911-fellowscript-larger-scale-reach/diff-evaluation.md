# Diff Evaluation: Larger-Scale Reach Channels for FellowScript's Leader/Pastor Audience

Task: `20260911-fellowscript-larger-scale-reach` — evaluating-diffs stage, step 7

Inputs: `critique.md` (per-claim verdicts), `brief.md` + `sources.json` (original side),
`counter-claims.json` (opposing side). No new evidence is introduced here; every verdict is a
weighing of what those four files already contain.

Verdict labels used below:

- **Stronger-original** — the brief's claim holds; either uncontested or defended under critique.
- **Stronger-counter** — the counter side's evidence supersedes or materially corrects the brief.
- **Disproven** — directly and credibly contradicted by the other side's evidence.
- **Overstated** — not contradicted by evidence, but the claim reaches further than its own
  support allows. Distinct from disproven; the underlying finding may still be usable in a
  narrower form.
- **False** — contradicted by strong, reliable evidence with no credible support remaining.
- **Unresolved** — genuinely inconclusive after critique; carried forward as an open item.

An important caveat for the whole evaluation: the counter-evidence stage scoped only three
targets (RightNow reach, Planning Center install base/ranking, Lifeway podcast reach). Every other
section of the brief was uncontested. "Uncontested" means no one tried to knock it down, not that
it was verified — those claims keep the reliability their original sourcing gave them, no more.

---

## Step 1 — RightNow Media as a channel

**Stronger side: counter, on evidence; original, on framing.**

The counter side produced the only genuinely independent check in this whole section —
MinistryWatch's Form 990-derived ~$35.9M program service revenue. The original side's
"corroboration" (Wesleyan Church, Learn of Christ) was correctly identified by the brief itself as
vendor copy, and the counter side's Zippia figure (32,000) is more of the same. So on source
quality the counter side wins outright: financial filings beat marketing copy and beat sites that
repeat marketing copy.

But the counter side drew the wrong conclusion from its own evidence. Its "roughly consistent with
30,000+" reading requires every dollar of program revenue to be church subscriptions at the lowest
tier. The critique's re-run of the arithmetic — allowing for RightNow @Work corporate revenue,
conferences, and attendance-scaled pricing — lands at roughly 12,000-20,000 paying organizations,
which matches RightNow's own pricing-page figure (20,000+), not its Global Reach page (30,000+).
The brief's skeptical framing (flag the discrepancy, treat 30K as vendor-stated) was closer to
right than the counter side's conclusion, even though the brief had no independent evidence.

Resolved working figures for downstream use:

| Figure | Brief | After evaluation |
|---|---|---|
| Subscribing churches | 30,000+ vendor-stated; 20,000+ on pricing page, unreconciled | **~20,000+ paying (moderate confidence, estimate not finding); 30,000+ as ceiling** |
| Users | 4.5M+ vendor-stated, unit unknown | **Cumulative registrations, not active users (high confidence)** — iOS ~2.5M lifetime + Android bracket + web/TV is consistent with cumulative and not with monthly-active |
| Public vendor mechanism | Documented absence | **Unchanged** — not challenged; still closable only by a direct ask |

**Stronger-original (holds):**
- No public mechanism for third-party vendor access to RightNow's leader channels. Uncontested;
  remains a documented absence.
- Wesleyan / Learn of Christ are reproductions of vendor copy, not corroboration. Uncontested and
  reinforced (Zippia is the same pattern).
- Similarweb ~990.9K visits/month; the marketing site is not the reach channel. Uncontested.
- "Requires leverage" classification and "single most promising requires-leverage candidate"
  designation. Holds — even at ~20K paying churches, it is the largest on-persona
  subscribing-church base in the run.

**Stronger-counter:**
- 30,000+ → ~20,000+ paying. The Form 990 arithmetic is the strongest evidence either side has.
- 4.5M+ → cumulative. App-store lifetime-install proxies settle the unit question the brief left
  open (open question 3, second half).

**Disproven:** none on the original side.

**Overstated (counter side):**
- "Roughly consistent with the 30,000+ figure." The counter-claim's own evidence supports 20K
  under realistic assumptions. Direction of the finding is right; the stated conclusion is too
  generous to the vendor.

**False:** none.

**Unresolved:**
1. What the 20K/30K gap actually measures. The critique's reading (paying vs. paying-plus-
   subsidized/cumulative) is the most parsimonious, but no source states it.
2. The counter side's pricing input ($1,200-$5,000+/church/year) is uncited in
   `counter-claims.json`. The ~20K verdict is robust to moderate error in that range but the
   range must be pinned before "~20,000 paying churches" is quoted as a finding rather than an
   estimate.

---

## Step 2 — Denominational and cross-church networks

**Stronger side: original by default — uncontested, and the brief claimed very little.**

Nothing in this section was targeted. The brief's claims are almost entirely negative or
existential: DLN exists, is cross-church, has free membership and a partner section, publishes no
count; AG Disciple Well exists with no count; Discipleship.org exists with no count; 3DM is
hub-organized with no aggregate. These are low-stakes claims sourced from the organizations' own
sites, and no counter-evidence was gathered against them. They stand as stated.

**Stronger-original (holds, uncontested):** all four network characterizations; DLN's
"partially actionable" classification.

**Disproven / Overstated / False:** none.

**Unresolved (carried from the brief, untouched by critique):**
- DLN's actual scale and whether "Become A Partner" admits software vendors (brief open
  question 6). Still the only free, on-persona, cross-church network found, and still
  unquantified.

---

## Step 3 — Curriculum publishers and ministry media beyond RightNow Media

**Stronger side: split. Counter on Lifeway; original on the raw figures; critique reasoning
narrows the TGC characterization.**

### The Gospel Coalition

The brief's numbers hold (40M vendor-claimed; ~6.0M visits/month Similarweb) — neither was
contested. What does not hold as strongly is the brief's *characterization* of the gap as "an order
of magnitude below" and, in Risks, "a roughly 6-7x gap between the vendor claim and the
independent estimate." The critique's observation is well-taken: Similarweb reports monthly
*visits*, and 6M visits/month is ~72M visits/year, so a "40M active users" figure that is actually
annual uniques is a different unit, not a 7x inflation. This is reasoning, not new evidence, but
it is sound and it matters because the brief and the critique both lean on the "TGC pattern" when
discounting Lifeway. The defensible version of the pattern is "vendor figures use looser or
different units than they sound like," not "vendors inflate 6-7x."

- **Stronger-original:** TGC ad products, no published pricing, rep-gated access, 40M vendor
  figure, ~6M Similarweb read. All hold.
- **Overstated (original):** the "6-7x gap / order of magnitude inflation" characterization.
  Reframe as unit mismatch.
- **Unresolved:** what "40M active users" actually counts (brief open question 4, first half).
  Annual uniques is the most plausible reading but no source says so.

### Lifeway Leadership Podcast Network

This is where the counter side's null result turned out to matter more than it rated itself. The
counter-evidence pass could not find independent analytics for any of the three shows Lifeway
*currently* lists (Unseen Leadership, Ron Edmondson Leadership Podcast, The One Thing) and,
in the course of looking, established that the roster has changed since the 5 Leadership
Questions / Group Answers era. That removes the brief's only corroboration. The brief had
already discounted the ~2M cumulative downloads for being the wrong unit; it now also fails on
membership — it is evidence about a show that no longer contributes to the network.

The critique's additional point — that "200,000+ Christians, leaders, teams, and decision makers
reached monthly" on a platform ad-sales page plausibly bundles podcast, newsletter, site, and
social reach — is a reading of the source text both prior stages quoted, not new evidence, and it
is a fair reading. The brief's summary paraphrased it as "200,000+ listeners/month" in
`sources.json`, which the ad page as quoted does not say.

- **Stronger-original (literal claim):** "Lifeway claims 200,000+/month, vendor-stated,
  single-sourced, custom pricing." Holds exactly as written.
- **Stronger-counter (implied claim):** the counter side's roster finding and null result
  supersede the brief's "corroborating in kind" language.
- **Disproven (original):** "5 Leadership Questions ~2M cumulative downloads corroborates the
  network's general reach claim in kind." Contradicted by the counter side's current-roster read;
  the show is apparently not on the network, so it corroborates nothing about the network's
  current reach. This is the clearest evidence-based reversal in the section.
- **Unresolved:**
  - What "200,000+ reached monthly" counts (podcast-only vs. platform-wide).
  - Actual monthly podcast audience. The critique's estimate of "tens of thousands" is
    reasoned from the Rainer on Leadership range (10K-50K) and the unit pattern, not measured.
    Carry as a plausible order-of-magnitude, not a figure.
  - Pricing. "Requires budget" is still inferred from a custom-quote process, not from a price.

### Christianity Today / SmallGroups.com

Uncontested. 4.5M+ leaders/month, 1.25M uniques, 395K eblast subscribers, SmallGroups.com not
broken out — all vendor-stated, all stand as vendor-stated. The unit-mismatch caution from TGC
applies by analogy but was not tested here.

- **Stronger-original (holds):** all CT figures as vendor-stated; SmallGroups.com not separately
  quantified.
- **Unresolved:** whether CT's 4.5M+/month deserves the same unit discount (brief open question 4,
  second half). Not examined by either side.

**Step 3 classification ("requires budget" for all three):** holds. What changed is the expected
value of the Lifeway spend, not its category.

---

## Step 4 — ChMS marketplaces and integrations

**Stronger side: counter, decisively, on the Planning Center install-base number; original on
the developer-program mechanics; neither side on downstream reach.**

### Planning Center install base

The counter side checked three Planning Center product pages (Services, People, Church Center)
and found the same current first-party figure on all of them: "Trusted by over 78,000 churches."
That is primary, current, and consistent — the best source available for a vendor-stated count.

This produces the run's one cleanly **false** claim. The brief stated there was "no current
first-party figure" for Planning Center. As the critique notes, the brief's literal observation
(the *homepage* carries no total) was not contradicted — but the brief then generalized from the
homepage to the company, and that generalization is contradicted by three pages on the same site.
No credible support for "no first-party figure" remains. It is false, not merely outweighed.

The brief's framing of "73K vs. 100K+ from two conflicting third parties" is **disproven** as a
genuine two-source contest. The critique's independence check is correct: 73,000 (Apps Run The
World), 78,000+ (Planning Center now), and 80,000 (Apps Run The World's "customers" line on the
same page) are almost certainly one vendor figure captured at different dates. faith.tools'
100,000+ is the only outlier, it has no independent basis, and it fits the faith.tools inflation
pattern Part 1 documented. There was never a conflict between independent measurements — there
was one vendor number and one bad secondary.

The critique's denominator check (78,000 is ~21% of ~373,000 US congregations) is reasoning
applied to a denominator the counter side supplied for RightNow. It is a sound sanity check and its
conclusion is right: 78K is a ceiling on *organizations with an account* (including free-tier,
international, and dormant), not a count of engaged paying churches. But it is reasoning, not a
source, so it is carried here as a confidence downgrade rather than a disproof.

| Figure | Brief | After evaluation |
|---|---|---|
| Planning Center churches | 73K-100K+, contested, no first-party figure | **78,000+ vendor-stated, current, consistent across three pages** |
| faith.tools 100,000+ | one of two contested figures | **Discredited** |
| 78K as reachable/engaged churches | (not distinguished) | **Low confidence — an account ceiling, ~21% of all US congregations** |

### Planning Center "best actionable-now" designation

The designation rests on three legs, and they fare differently:

1. Free, self-serve OAuth registration against a public API — **holds** (primary, uncontested).
2. A directory-submission path for completed integrations — **holds as "the on-ramp exists"**
   (primary, single-source). The counter side's Vanco press release proves that integrations get
   built and announced, but Vanco is a large payments vendor, the release does not say whether it
   used the self-serve path, and it says nothing about what a listing yields. The critique is
   right that the counter side over-credited this. It moves nothing.
3. Largest install base in the ChMS set — **holds relatively** (G2/Capterra review-volume ratios,
   the one independent scale signal either side produced, agree).

What does not hold is the brief's phrasing "the largest install base in the ChMS set even at the
lower 73K figure" as the reason Planning Center beats the faith.tools baseline. The brief conflates
install base with reach. The integrations directory is structurally a directory listing — the same
channel type as faith.tools — attached to a much larger pool. Whether that pool ever looks at the
directory is unknown to both sides, and nobody found a single first-hand developer account of
directory-driven discovery. So: Planning Center is the best actionable-now *on-ramp* (free,
self-serve, largest pool), and whether it is a larger *reach channel* than faith.tools in practice
is unproven.

On the critique's suggestion that a Planning Center Groups integration (roster sync into a
small-group note-taking app) would carry product value independent of distribution value: this is
plausible product reasoning, but it appears in no source on either side and this stage does not
introduce evidence. It does not alter any reach verdict. It is worth carrying to the conclusion as
a *rationale for the engineering time being defensible even if the directory drives little
discovery*, clearly flagged as unsourced reasoning rather than a finding.

- **Stronger-original (holds):** free self-serve developer program; directory-submission path
  exists; largest relative scale in the ChMS set; "best actionable-now" as an on-ramp.
- **Stronger-counter:** 78,000+ replaces the contested range; faith.tools 100K+ discredited;
  Apps Run The World is internally inconsistent.
- **Disproven (original):** "73K vs. 100K+ as a genuine two-source contest" — one origin plus
  one bad secondary.
- **Overstated (original):** "largest install base … even at the lower 73K figure" as a reach
  argument — install base conflated with reach; 78K is an account ceiling.
- **Overstated (counter):** Vanco integration as support that the self-serve directory path
  works for a small consumer app.
- **False (original):** "no current first-party figure" for Planning Center.
- **Unresolved:**
  - Whether the integrations directory drives any discovery for a consumer-facing small-group
    app, and whether such an app would be accepted (brief open question 1). This is the single
    most decision-relevant unknown in the run and it is still open.
  - Whether 78K represents engaged, reachable churches or mostly accounts.

### Pushpay, CCB, ChurchTrac, Breeze

All uncontested. Pushpay's 14,000+ holds as vendor-stated, though the critique correctly notes its
`corroboration_count: 2` is effectively 1 (the second source is a directory listing repeating the
tagline) — the figure is not challenged, only its claimed corroboration. Pushpay's self-serve API
with no consumer-app partner program, CCB's ~10K combined base, and the ChurchTrac/Breeze
small-ecosystem finding all stand.

- **Stronger-original (holds):** Pushpay 14K+ (vendor-stated); Pushpay dev API, no consumer-app
  partner program; CCB 4,000+ / ~10K combined; ChurchTrac/Breeze non-marketplace ecosystems.
- **Overstated (original):** Pushpay `corroboration_count: 2` — effective corroboration is 1.

**Step 4 classification:** Planning Center actionable-now (as on-ramp), Pushpay partially
actionable, CCB/ChurchTrac/Breeze no scalable mechanism — all hold.

---

## Step 5 — Podcasts and YouTube channels

**Stronger side: counter, indirectly — its roster finding for Step 3 undercuts this section's
headline show.**

The brief carried Group Answers Podcast as "the most directly small-group-leader-specific show."
The brief's source is a live Lifeway page for the show, which establishes that the page exists,
not that the show is producing episodes. The counter side's read of Lifeway's *current* network
roster (Unseen Leadership, Ron Edmondson, The One Thing) does not include Group Answers. No source
explicitly confirms discontinuation, so this is unresolved rather than disproven — but it means
the brief's only on-persona podcast may not be a current sponsorship opportunity at all, and
therefore that no small-group-specific podcast channel may exist in this run's findings.

Everything else in the section is uncontested and stands: Rainer on Leadership 10K-50K (Feedspot,
wide) and 487 Apple ratings; Church Answers 1,800+ members; Discipleship Leaders Podcast 6 ratings;
no YouTube channel sourced.

The section's closing line — "the Lifeway network's 200,000+/month is the only sourced podcast
audience number that reaches the plan's bar, and it is vendor-stated" — holds and is now weaker
than the brief presented it, per Step 3.

- **Stronger-original (holds, uncontested):** Rainer on Leadership / Church Answers figures;
  Discipleship Leaders Podcast is small; no YouTube channel found; "requires budget"
  classification.
- **Unresolved:**
  - Whether Group Answers Podcast (and 5 Leadership Questions) are still active. Affects whether
    any small-group-specific podcast channel exists at all.
  - Actual audience of the current Lifeway roster (nothing found by either side).

---

## Step 6 — Facebook groups and online communities

**Stronger side: original, and strongly.**

The three direct platform reads (SGN 15.2K members / ~19 posts/month; Small Group Ministry Network
420; Church Communications 38.4K) are the highest-reliability source type in the run — a platform's
own displayed counters — and nothing in either file touches them. Church Communications has
directional external corroboration (30K-35K mentions). Katie Allred's list confirming SGN is the
only small-group-specific group among 14 is uncontested. The activity caveat (~19 posts/month, no
new members in the past week) is the right caveat and stands as a point-in-time snapshot.

- **Stronger-original (holds):** all three member counts; SGN activity snapshot; SGN is the only
  small-group-specific group on the Allred list; Church Communications is off-persona; no
  subreddit/Discord/Slack found.
- **Disproven / Overstated / False:** none.
- **Unresolved:** whether a 15.2K-member, low-activity group outperforms a hundreds-of-subscribers
  faith.tools listing in practice (brief open question 7). Member count and reachable audience are
  not the same thing, and neither side produced evidence on the conversion.

---

## Step 7 — App Store / Play Store faith-category placement

**Stronger side: original — five independent ASO-industry sources agree, uncontested.**

Apple's editorial featuring is nomination-based, quality-gated, not purchasable, not
faith-specific, and slow. This is the best-corroborated positive finding in the run
(`corroboration_count: 5`, genuinely independent sources) and it was not challenged.

- **Stronger-original (holds):** the featuring mechanism and its "actionable now, unreliable"
  classification.
- **Disproven / Overstated / False:** none.
- **Unresolved (carried):** Google Play faith-category dynamics; any recurring Apple curated
  "Bible study" collection (brief open question 8). Not investigated by either side.

---

## Step 8 — Synthesis

The two headline designations both survive, but each with a required requote:

**Planning Center as the single best actionable-now candidate — holds, narrowed.** It is the best
on-ramp found: free, self-serve, primary-sourced, attached to the largest pool in the ChMS set
(78,000+ accounts, vendor-stated). It is *not* established as a larger reach channel than the
faith.tools baseline. The brief's table row and diagram should read "78K+ churches
(vendor-stated; account ceiling incl. free/international)" and the ranking rationale should cite
cost and access, not install base.

**RightNow Media as the single most promising requires-leverage candidate — holds, requoted.**
Quote as "20,000+ paying / 30,000+ claimed; 4.5M cumulative users." Still the largest on-persona
subscribing-church base found; still no public vendor mechanism; still closable only by a direct
ask.

Required corrections to the Step 8 table and diagram:

| Row | Brief | Corrected |
|---|---|---|
| Planning Center | 73K-100K churches (two conflicting third parties; not on PC's own homepage) | 78K+ churches (vendor-stated, current; account ceiling incl. free/international); directory reach unproven |
| RightNow Media | 30K+ churches / 4.5M users (vendor-stated; 20K+ on pricing page) | ~20K+ paying / 30K+ claimed (Form 990 arithmetic); 4.5M cumulative registrations |
| Lifeway podcast ads | 200K+/mo (vendor-stated) | 200K+/mo "reached" (vendor-stated; likely platform-wide not podcast-only; uncorroborated for current roster; plausible podcast audience tens of thousands) |
| TGC ads | ~6M visits/mo (Similarweb) vs. 40M claimed | ~6M visits/mo (Similarweb); 40M is likely a different unit (annual uniques), not a 7x inflation |
| Group Answers Podcast | (implicit in Step 5 as the on-persona show) | Activity unverified; may not be a current channel |

Mermaid labels `RNM["RightNow Media (30K+ churches)"]` and `LW["Lifeway podcast ads (200K+/mo)"]`
should be updated to match.

Required corrections to the Risks section:
- Strike "no current first-party figure" for Planning Center (false).
- Reframe the TGC "6-7x gap" as a unit mismatch.
- Note Pushpay's effective corroboration is 1, not 2.

Status of the brief's nine open questions after critique:

| # | Question | Status |
|---|---|---|
| 1 | Is the PC integrations directory a real distribution channel? | **Unresolved** — most decision-relevant unknown in the run |
| 2 | Which PC figure (73K vs. 100K+) is closer; does the ranking survive? | **Resolved** — 78K+ vendor-stated; ranking survives as an on-ramp, not as a reach claim |
| 3 | RightNow 30K/20K — two metrics or inflation? 4.5M active or cumulative? | **Partially resolved** — 20K paying is the supported figure; gap's exact meaning unstated; 4.5M is cumulative |
| 4 | Is TGC's 40M cumulative; discount Lifeway/CT similarly? | **Partially resolved** — TGC most plausibly annual uniques (unit); Lifeway warrants the unit discount; CT untested |
| 5 | Are the budget channels priced within a lean team's range? | **Unresolved** — no pricing found by either side |
| 6 | Does DLN admit software vendors; at what scale? | **Unresolved** — untouched |
| 7 | Does a low-activity 15.2K FB group beat a faith.tools listing in practice? | **Unresolved** — untouched |
| 8 | Google Play / Apple curated Bible-study collections? | **Unresolved** — untouched |
| 9 | Missed channels (YouTube, newsletters, large conferences)? | **Unresolved** — untouched |

---

## Overall picture

The original brief held up well on what it *said* and less well on what it *implied*. Its
skeptical posture toward vendor figures was vindicated everywhere the counter side produced
independent evidence: RightNow's real paying base is closer to its own smaller number, Planning
Center's true figure is the vendor's own and not the inflated secondary, and Lifeway's reach
claim turned out to have even less behind it than the brief assumed. The direct platform reads
(Facebook) and the five-source ASO finding were never touched and remain the run's most reliable
material.

Three things went wrong on the original side. One claim was false: the sourcing agent stopped at
Planning Center's homepage and generalized "no first-party figure" from it, when three product
pages carried one. One claim was disproven: the 5 Leadership Questions download figure was
presented as corroboration for a network the show no longer appears to belong to. And in three
places the brief let a number do more work than it could bear — treating Planning Center's install
base as if it were reach, calling the TGC vendor/Similarweb gap a 6-7x inflation when it is
more plausibly a unit difference, and counting a repeated tagline as corroboration for Pushpay.

The counter side was thin by design (three targets, one of which returned a null) but the material
it did produce was of higher quality than the original's on the two contested numbers: a Form 990
filing and the vendor's own product pages beat marketing copy and secondary aggregators. Its two
weaknesses were interpretive — it under-read its own RightNow arithmetic and over-read the Vanco
press release.

Net effect on the two recommendations the brief made: both survive. Planning Center remains the
best actionable-now candidate, but as a free on-ramp to a large pool, not as a demonstrated reach
channel — whether it actually beats the faith.tools baseline in practice is the run's biggest
remaining unknown. RightNow Media remains the best requires-leverage candidate at roughly 20,000
paying churches rather than 30,000. The budget channels (Lifeway, TGC, CT) all remain real but
every one of their headline numbers should be read as a looser unit than the ad-sales copy
suggests, and none has a known price.

Tally: 22 original claims/clusters stronger-original (mostly uncontested); 4 stronger-counter;
2 original claims disproven; 5 overstated (3 original, 2 counter); 1 original claim false;
10 unresolved items carried forward.

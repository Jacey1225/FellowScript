# Critique: Larger-Scale Reach Channels for FellowScript's Leader/Pastor Audience

Task: `20260911-fellowscript-larger-scale-reach` — critiquing stage, step 6

Inputs: `brief.md` + `sources.json` (original side), `counter-evidence-plan.md` +
`counter-claims.json` (opposing side). Three target claims were scoped; all three received a
counter-evidence attempt with at least one independent-methodology source, so the opposing side is
thick enough to critique. No new sources were gathered in this step; everything below is
adjudication of what the two prior stages produced, plus arithmetic and independence checks the
prior stages left undone.

## Per-claim verdicts

### Claim 1 — RightNow Media's stated reach (30,000+ churches / 4.5M+ users)

**Original position.** Vendor-stated 30,000+ subscribing churches and 4.5M+ users; the two
"corroborating" sources (Wesleyan Church, Learn of Christ) merely reproduce vendor copy; the
pricing page's 20,000+ "partners" figure is an unreconciled internal discrepancy; no public
mechanism exists for a third-party app to reach RightNow's leader audience.

**Counter position.** No credible evidence of material inflation. MinistryWatch's Form 990-derived
~$35.9M program service revenue, divided by a $1,200-$5,000+/church/year pricing range, implies
roughly 7,000-30,000 paying churches — "the same order of magnitude." App-store install proxies
(~2.5M+ lifetime iOS downloads; a Google Play install bracket) are consistent with a multi-million
cumulative user base. 30,000 is ~8% of ~373,000 US congregations, a plausible share. A Zippia
profile adds a third vendor-adjacent figure (32,000). The 20K/30K gap remains unexplained.

**Scrutiny.**

The counter-evidence's revenue arithmetic is the only genuinely independent check either side
produced, and it deserves a harder read than the counter-claim gave it. $35.9M reaches 30,000
churches only if every dollar is church subscription revenue *and* every church pays the lowest
tier. Neither holds: RightNow Ministries' program revenue also covers RightNow @Work (corporate
subscriptions), conferences, and production work, and RightNow's pricing scales with church
attendance, so the blended average per church is above the floor. At a blended $1,800-$2,500 per
church, subscription revenue supports roughly 12,000-20,000 paying organizations. That lands on
the pricing page's 20,000+ "partners" figure, not the Global Reach page's 30,000+.

That does not make 30,000+ false — it makes the most parsimonious reading of the discrepancy:
20,000+ is the paying-customer count, and 30,000+ includes subsidized/free-access churches
(RightNow does offer donor-funded access internationally and to schools/ministries) or is a
cumulative ever-subscribed figure. Either way, the number a small team should carry forward as
"currently paying, reachable organizations" is the 20K figure, with 30K as a ceiling.

Two weaknesses on the counter side: the $1,200-$5,000+ pricing range is described as "found via
search" with no URL logged, so the arithmetic rests on an uncited input; and the Google Play
bracket is quoted as "e.g. 500,000+" — it is unclear whether that is the actual displayed bracket
or an illustrative example. Neither flaw changes the direction of the finding.

On the 4.5M "users": ~2.5M lifetime iOS installs plus a sub-1M-to-low-millions Android bracket plus
web/TV access is consistent with 4.5M *cumulative registrations*, and not with 4.5M active users.
Both sides now agree this is not a monthly-audience number. The brief's open question 3 is
effectively answered: read 4.5M as cumulative.

On the sponsorship mechanism: the counter-evidence pass did not attempt to overturn the brief's
"no public mechanism" finding (it was outside the three scoped targets), so that negative finding
stands unchallenged and remains a documented absence, closable only by a direct ask.

**Verdict.** The original claim survives in kind (RightNow is a real, tens-of-thousands-of-churches
channel) but is overstated in degree. The counter-claim's "roughly consistent with 30,000+"
framing is too generous to the vendor; the independent evidence favors ~20,000 paying
organizations. The "single most promising requires-leverage candidate" designation survives —
even at 20K paying churches it is the largest on-persona subscribing-church base found — but its
headline number should be quoted as "20,000+ paying / 30,000+ claimed."

### Claim 2 — Planning Center's install base and the "best actionable-now" designation

**Original position.** Install base contested between 73,000 (Apps Run The World) and 100,000+
(faith.tools) with "no current first-party figure"; the self-serve developer program plus
integrations-directory submission path makes Planning Center the single best actionable-now
channel, "the largest install base in the ChMS set even at the lower 73K figure."

**Counter position.** Planning Center's own product pages (Services, People, Church Center) all
currently state "Trusted by over 78,000 churches," so a current first-party figure does exist and
it sits near the low end of the contested range, discrediting faith.tools' 100K+. Apps Run The
World's own page is internally inconsistent (73,000 churches vs. 80,000 customers). A BusinessWire
release shows Vanco built and announced a real integration through Planning Center. G2/Capterra
review volumes (Capterra 1,137 vs. 183; G2 353 vs. 118, vs. Pushpay) confirm Planning Center's
relative scale lead. No first-hand account of the directory driving discovery was found.

**Scrutiny.**

*The "no first-party figure" premise is falsified, but narrowly.* The brief's literal statement —
that the *homepage* carries no total-churches figure — is not contradicted (the counter-evidence
checked product pages, not the homepage). The brief's inference from that, "no current first-party
figure," was an overreach: the sourcing agent stopped at the homepage. This is a correctable
overstatement, not a claim untraceable to its source, so it does not warrant bouncing to the brief.
The critique corrects it here: the working figure is 78,000+ (vendor-stated, current).

*The three figures are not independent.* 73,000 (Apps Run The World), 78,000+ (Planning Center
now), and 80,000 (Apps Run The World's "customers" line) are almost certainly the same vendor
claim captured at different dates as it grew. Their convergence is not corroboration; it is one
origin. The only truly independent scale signal in either file is the G2/Capterra review-volume
ratio, and that supports *relative* rank (Planning Center is the biggest ChMS in this set), not
the absolute 78K.

*The denominator check the plan asked for, applied.* The counter-evidence plan explicitly
requested the US-congregation sanity check for Planning Center; the counter-evidence pass ran it
for RightNow only. Applied here: 78,000 churches against ~373,000 US congregations is ~21% of all
US congregations of every size and tradition. That is a very large share for a paid SaaS product.
It is plausible only if "churches" counts international accounts (Planning Center is widely used
in Australia, the UK, and elsewhere), free-tier accounts (each Planning Center product has a free
plan for small usage), and dormant accounts. So 78K is a ceiling on *organizations with an
account*, not a count of engaged paying churches — the same "vendor figure measures something
looser than it sounds" pattern this run found for TGC and RightNow.

*Does the "best actionable-now" designation survive?* Its three legs fare differently:

1. Free, self-serve OAuth registration against a public API — primary-sourced, uncontested. Holds.
2. A directory-submission path for completed integrations — primary-sourced only. The Vanco press
   release proves integrations exist and get announced, but Vanco is a major payments vendor and
   the release does not say whether it used the self-serve path or a negotiated partnership. It is
   weak evidence that a two-person consumer-facing app would get listed, and zero evidence about
   what a listing yields. Holds as "the on-ramp exists," not as "the on-ramp reaches anyone."
3. Largest install base in the ChMS set — confirmed relatively by G2/Capterra. Holds.

What does not hold is the implicit equation of install base with reach. Planning Center's
integrations directory is, structurally, a directory listing — the same channel type as the
faith.tools listing this run was supposed to beat. The audience pool is far larger (tens of
thousands of accounts vs. hundreds of subscribers), but the conversion from "has a Planning Center
account" to "browses the integrations directory" is unknown to both sides, and nobody found a
single developer account of directory-driven traffic. The honest framing is: Planning Center is
the best actionable-now *on-ramp* because it is free, self-serve, and attached to the largest
pool; whether it is a *larger-scale reach channel* than faith.tools in practice is unproven.

One consideration neither side raised, offered here as reasoning rather than evidence: an
integration with Planning Center Groups (its small-groups product) would be a functional feature
for FellowScript — syncing group rosters into a small-group note-taking app — not just a listing.
That makes the engineering time defensible on product grounds even if the directory drives little
discovery. This should be tested in the evaluating-diffs stage, not assumed.

**Verdict.** The counter-evidence wins on the install-base number: 78,000+ (vendor-stated)
replaces "73K-100K contested," and faith.tools' 100K+ is discredited. The "best actionable-now"
designation survives on its on-ramp merits, but the brief's phrasing — which leans on the install
base as if it were reach — is overstated. Reframe as "best actionable-now on-ramp with an
unquantified downstream reach."

### Claim 3 — Lifeway Leadership Podcast Network's 200,000+/month reach

**Original position.** Vendor-stated 200,000+ reached monthly; Listen Notes ranks network shows
well; one show (5 Leadership Questions) has ~2M cumulative downloads, corroborating "in kind"
though not in unit.

**Counter position.** A good-faith attempt to find independent per-show analytics (Podchaser,
Rephonic, Apple ratings) for the network's *current* roster — Unseen Leadership, The Ron Edmondson
Leadership Podcast, The One Thing — found nothing. The roster has apparently changed since the
5 Leadership Questions / Group Answers era. Industry commentary treats podcast download/reach
figures as vanity metrics but does not name Lifeway.

**Scrutiny.**

The counter-evidence pass surfaced something more consequential than it flagged. If 5 Leadership
Questions is no longer on the network's current roster, then the brief's one piece of
"corroboration in kind" is for a show that no longer contributes to the network's reach. The
brief already discounted it for being a lifetime-downloads unit; it now also fails on
membership. The 200,000+/month figure is therefore not merely single-sourced — it has no
corroboration of any kind for the network as it exists today.

Both sides also missed a unit problem in the vendor claim itself. Lifeway's ad page says
"200,000+ Christians, leaders, teams, and decision makers reached monthly" — it does not say
"podcast listeners." "Reached" across a leadership platform plausibly bundles podcast downloads,
newsletter sends, site visits, and social impressions. Given the 6-7x vendor-to-independent gap
this run measured for TGC, and the wide 10K-50K estimate for a comparable general
church-leadership show (Rainer on Leadership), a plausible actual monthly podcast audience for a
three-show network is in the tens of thousands, not 200,000.

The roster change also affects the brief's Step 5. Group Answers Podcast was carried as "the most
directly small-group-leader-specific show." If it is no longer producing episodes, it is not a
current sponsorship opportunity at all. The brief's source (a live Lifeway page) confirms the page
exists, not that the show is active. This needs verification before anyone treats it as a channel.

The counter-claim's null result is honestly reported and its 0.15 confidence is appropriate — it
found no evidence against the figure, only an absence of evidence for it. The industry-skepticism
sources are genre-level and add little.

**Verdict.** The original claim as literally written (vendor claims 200K+, corroboration is weak)
holds. The implied reading — that ~200K leaders/month are reachable through host-read podcast
ads — does not hold: it is unverified in unit, uncorroborated for the current roster, and, by the
pattern established elsewhere in this run, likely several times too high. The "requires budget"
classification is unaffected; what changes is the expected value of spending that budget.

## Claims that hold

- **RightNow Media is a large, on-persona subscribing-church base with no public vendor on-ramp**
  (original). Independent financial data supports tens of thousands of paying organizations; the
  "no public mechanism" negative finding was not challenged.
- **The 4.5M "users" figure is cumulative, not active** (converged position). App-store lifetime
  install proxies from the counter side make this the only consistent reading.
- **Planning Center currently states 78,000+ churches** (counter). Three product pages checked
  independently; this supersedes the brief's contested 73K/100K range.
- **faith.tools' "100,000+ churches" for Planning Center is discredited** (counter). Consistent
  with Part 1's finding that faith.tools inflates.
- **Planning Center has the largest relative scale in the ChMS set** (both). The G2/Capterra
  review-volume ratio is the one independent signal and it agrees.
- **Planning Center's developer program is free and self-serve** (original). Primary-sourced,
  uncontested.
- **Planning Center is the best actionable-now on-ramp found** (original, narrowed). Survives on
  cost and access merits, not on demonstrated reach.
- **Lifeway's 200,000+/month is uncorroborated** (both). Strengthened by the roster-change finding.
- **Counter-claim 3's null result** (counter). Honest, correctly low-confidence.

## Claims that don't hold

- **"No current first-party figure" for Planning Center** (original). Falsified by the counter
  side's direct product-page reads. The sourcing agent checked only the homepage. Corrected to
  78,000+ (vendor-stated).
- **"73K vs. 100K+ from two conflicting third parties"** as a genuine two-source contest
  (original). The 73K/78K/80K figures share one vendor origin at different dates; only faith.tools'
  100K+ is a different (and worse) source. There was never a real conflict between independent
  measurements.
- **"Roughly consistent with the 30,000+ figure"** (counter, Claim 1). The revenue arithmetic
  reaches 30,000 only under the least realistic assumptions (all revenue from churches, all at the
  lowest tier). A realistic blended price and the existence of non-church program revenue put
  paying organizations near 20,000, matching RightNow's own pricing-page figure. The counter-claim
  understated what its own evidence shows.
- **"Largest install base ... even at the lower 73K figure" as a reach argument** (original). The
  install base is a ceiling on accounts (including free and international), ~21% of all US
  congregations; it is not evidence that the integrations directory reaches those churches.
  Install base and reach were conflated.
- **5 Leadership Questions' ~2M downloads as corroboration "in kind" for the Lifeway network**
  (original). Wrong unit *and*, per the counter side's roster check, apparently no longer a network
  show. It corroborates nothing about the current network.
- **The Vanco integration as support that the self-serve directory path works for a small app**
  (counter, partially claimed). The release does not establish that Vanco used the self-serve path,
  and Vanco's scale makes it a poor analogue for a two-person consumer app. It proves integrations
  get built and announced, nothing more.

## Confidence adjustments

| Claim (from `brief.md` unless noted) | Before | After | Reason |
|---|---|---|---|
| RightNow: 30,000+ subscribing churches | vendor-stated, unverified | **Moderate that the true paying count is ~20,000+; 30,000+ is a ceiling** | Form 990 revenue arithmetic; matches pricing-page figure |
| RightNow: 4.5M+ users | vendor-stated, unit unknown | **High that it is cumulative registrations, not active users** | iOS/Android lifetime-install proxies |
| RightNow: no public vendor mechanism | documented absence | **Unchanged** | Not challenged |
| RightNow as best requires-leverage candidate | asserted | **Holds; quote as "20K+ paying / 30K+ claimed"** | Still the largest on-persona subscriber base |
| Planning Center: 73K-100K+ contested | contested | **Replaced by 78,000+ vendor-stated; 100K+ discredited** | Three product pages; faith.tools pattern |
| Planning Center: 78,000+ as reachable churches | (new) | **Low — it is an account ceiling incl. free/international, ~21% of US congregations** | Denominator check |
| Planning Center: free self-serve developer program | primary, single source | **Unchanged (high)** | Uncontested |
| Planning Center: directory is a real distribution channel | open question | **Unchanged — still unknown; Vanco release does not answer it** | No first-hand account found |
| Planning Center as best actionable-now | asserted | **Holds as best on-ramp; downgraded as a reach claim** | Install base conflated with reach |
| Lifeway: 200,000+/month | vendor-stated, single source | **Lowered — uncorroborated for current roster; "reached" likely not podcast-only; plausible actual tens of thousands** | Roster change; unit ambiguity; TGC gap pattern |
| Lifeway: 2M downloads corroborates in kind | weak corroboration | **None — show apparently off the network** | Counter roster check |
| Group Answers Podcast as a current channel | assumed active | **Unresolved — needs an activity check** | Roster change |
| Counter-claim 1 (0.25) | 0.25 | **Direction correct, but should have been stated more strongly toward ~20K** | Its own arithmetic |
| Counter-claim 2 (0.55) | 0.55 | **Upheld on the number; over-credits Vanco** | See above |
| Counter-claim 3 (0.15) | 0.15 | **Upheld; the roster finding is more useful than the agent rated it** | See above |

### Observations on non-targeted claims (critic's own, no new counter-evidence)

- **TGC 40M vs. ~6M Similarweb.** The brief calls this "an order of magnitude below." Similarweb
  reports monthly *visits*; TGC's "40M active users" is most likely *annual unique users* (6M
  visits/month is ~72M visits/year, so 40M annual uniques is not inflated, just a different unit).
  The brief's inference that "the vendor figure is cumulative or loosely defined" is right; the
  characterization as a 6-7x inflation is too strong. This matters because the critique of Claim 3
  above uses the TGC gap as a pattern — treat it as "different unit" rather than "7x lie."
- **Pushpay 14,000+ with `corroboration_count: 2`.** The second source is a directory listing
  repeating the vendor tagline — the same one-origin pattern as RightNow and Planning Center.
  Effective corroboration is 1. The figure is not challenged, only its claimed corroboration.
- **Facebook direct reads (15.2K / 420 / 38.4K).** Highest-reliability source type in the run;
  nothing in either file undermines them. The SGN activity snapshot (~19 posts/month) is the
  right caveat and stands.
- **App Store featuring (5 ASO sources).** Genuinely independent, consistent; holds.

## Unresolved

1. **What the 20,000+ vs. 30,000+ RightNow gap actually measures.** The critique's reading (paying
   vs. paying-plus-subsidized) is the most parsimonious but no source states it. Only a direct ask
   or a RightNow annual report would settle it.
2. **Whether Planning Center's integrations directory drives any discovery for a consumer-facing
   small-group app.** Both sides searched; neither found a first-hand developer account. This is
   the single most decision-relevant unknown in the run and it remains open. The evaluating-diffs
   stage should treat "Planning Center = larger reach than faith.tools" as untested, and weigh the
   integration's product value (Groups roster sync) separately from its distribution value.
3. **What Lifeway's "200,000+ reached monthly" counts.** Podcast-only or platform-wide is not
   determinable from the ad page as quoted. Custom media-plan pricing is also still unknown, so
   "requires budget" remains inferred rather than priced.
4. **Whether Group Answers Podcast and 5 Leadership Questions are still active.** The counter
   side's current-roster read (Unseen Leadership, Ron Edmondson, The One Thing) implies not, but no
   source explicitly confirms discontinuation. Affects whether any small-group-specific podcast
   channel exists at all.
5. **The counter side's RightNow pricing input ($1,200-$5,000+).** Uncited in `counter-claims.json`.
   The Claim 1 verdict depends on the order of magnitude of this range, not its exact bounds, so
   the verdict is robust to moderate error — but the range itself should be pinned before any
   downstream document quotes "~20,000 paying churches" as a finding rather than an estimate.

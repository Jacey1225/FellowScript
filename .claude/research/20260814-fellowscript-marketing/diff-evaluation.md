# Diff Evaluation: FellowScript Marketing Research

Evaluates `critique.md`'s per-claim verdicts against the original (`brief.md` + `sources.json`) and opposing (`counter-claims.json`) sides, section by section per `brief.md`'s structure. Five claims were targeted for counter-evidence (per `counter-evidence-scope.json`); sections not touched by counter-evidence are noted as out-of-scope for this round and stand as originally sourced.

## Section-by-section verdicts

### Section 1 — Mission, purpose, audience signals
Not targeted by counter-evidence. All claims trace to primary, user-provided docs (README.md, docs/index.md, docs/design/home-page.md) with no external claims to contest. **No diff to evaluate; stands as-is.**

### Section 2 — Concrete features and differentiators
Not targeted by counter-evidence. Sourced entirely from primary internal docs. **Stands as-is.**

### Section 3 — Brand/design identity and tone implications
Contains the targeted "authenticity beats slick production" claim (Claim 3 in critique).
- **Stronger side:** Neither side outright wins; this is the critique's most genuinely mixed verdict. The counter-evidence's internal-contradiction argument is strong and well-grounded — the brief's own best-documented growth story (Hallow's Wahlberg/Roumie Super Bowl ad) directly contradicts the "authenticity over polish" framing stated a few sections later, and all three "authenticity" sources (Christian Post Advertising, FrontGate Media, and Salem Surround found in counter-evidence) are commercially-interested agencies in the same vendor category — the counter side's independence critique lands cleanly. But the critique itself surfaces the reconciling nuance neither side stated: `sources.json`'s Phiture entry shows Hallow's TikTok growth ran on UGC/authenticity while its Super Bowl/broadcast growth ran on celebrity polish — suggesting a channel-dependent split, not a flat win for either side.
- **Disproven:** None outright disproven — the counter-evidence undermines the *blanket, channel-agnostic* framing, not the underlying observation that authenticity works somewhere.
- **False:** The blanket claim "faith audiences respond better to authentic storytelling than slick production" as a general, unqualified rule is **false as stated** — it is directly contradicted by the brief's own strongest cited example and rests only on same-category vendor sourcing.
- **Unresolved:** Whether authenticity or high-production content performs better for FellowScript specifically remains untested by either side; the channel-dependent reconciliation is the critique's own inference, not something either source set directly proves.

### Section 4 — Monetization model and channel-selection implications
Contains the referral LTV/trust stats (Claim 4 in critique), reused again in Section 9.
- **Stronger side:** Counter-evidence wins decisively and constructively — it doesn't just attack the original claim, it improves it. The ~25% LTV figure is traced to a genuine peer-reviewed source (Schmitt, Skiera & Van den Bulte 2011, *Journal of Marketing*) that the original Adapty vendor blog only echoed without attribution; this is stronger, more independent evidence than the original brief had.
- **Disproven:** The "83% higher trust than non-referred users" figure is disproven — the counter-evidence traces it to an unrelated, widely-cited Nielsen general-word-of-mouth-trust statistic, not a referred-vs-non-referred comparison. This is a credible, well-reasoned identification of a likely source misattribution.
- **False:** "83% higher trust than non-referred users" should be treated as **false as cited** (misattributed statistic, not a real referred/non-referred comparison) — drop or correct wherever used downstream. "Double-sided referral rewards are the dominant proven pattern," stated as an unqualified default-safe recommendation, is **overstated to the point of being materially misleading**: the same peer-reviewed study the corrected LTV figure relies on documents real referral-abuse and channel-cannibalization failure modes.
- **Unresolved:** None — this is the most cleanly resolved claim cluster in the evaluation. The corrected version ("16-25% LTV lift, peer-reviewed; double-sided rewards are common and precedented but must be designed against abuse/cannibalization; drop the trust figure") should replace the original framing in Section 4 and Section 9 alike, since Section 4 leans on this same claim to justify prioritizing referral/group-invite mechanics over paid acquisition — that directional recommendation still holds even after the correction, since the corrected LTV figure alone supports it.

### Section 5 — Channels/tactics proven for faith-based/Bible apps
This section carries two of the five targeted claims and one untargeted one.

**Parish/diocese partnerships (Claim 1):**
- **Stronger side:** Original wins on the core, describable pattern; counter-evidence wins on one specific figure and raises a fair caution. The 2,500+ parishes / ~9% QR-code-attributed growth figure is well-sourced (Branch.io case study, corroboration_count 3, built on Hallow's own reported campaign data per `sources.json`) and is **not challenged** by the counter-evidence — it holds.
- **Disproven:** None of the core pattern is disproven.
- **False:** The "30% user increase" figure from 2024 Catholic-organization collaborations is **false as a citable statistic** — the counter-evidence agent's own attempt to re-source it via Contrary Research (the original's own citation) found no underlying data or methodology, meaning it was never more than a single unverified mention and should not be relied on as a hard number.
- **Unresolved:** The counter-evidence's structural-asymmetry argument (Catholic dioceses have centralized parish-management infrastructure like ParishStaq that Protestant/non-denominational churches largely lack) is a plausible mechanism for why the channel might not transfer to FellowScript's non-diocesan audience at similar density — but it is a reasoned caution, not falsifying evidence, since it doesn't test FellowScript's actual audience. Transferability to FellowScript remains unresolved.

**Church-calendar-timed campaigns (Claim 2):**
- **Stronger side:** Counter-evidence wins clearly and is the single strongest counter-argument across the whole evaluation (self-rated confidence 0.75, and it holds up on inspection). Independent religious press (Catholic News Agency, Catholic World Report) — not part of the marketing-case-study lineage (Phiture/Branch/Consumer Startups) that all describe the same event — establishes that Ash Wednesday and Super Bowl LVIII fell in the same week for the first time since 2008, and a vendor case study quotes Hallow's own marketing lead confirming a simultaneous celebrity Super Bowl ad and a 15x paid-spend increase across Meta/Google/Apple Search Ads, with the explicit admission that channels "don't operate in a vacuum."
- **Disproven:** The claim that the February 2024 spike (2M installs, brief #1 App Store ranking) demonstrates that calendar timing *in isolation* dramatically outperforms generic timing is disproven as stated — it is confounded by a rare, non-repeatable calendar coincidence plus a major celebrity ad plus a 15x paid-spend surge, all stacked in the same window.
- **False:** The specific causal framing "calendar timing alone drove this magnitude of result" is false; the raw magnitude figures (412%/230%/2M installs) remain accurately reported as *observed numbers* but should not be attributed to calendar timing alone.
- **Unresolved:** The critique correctly notes the counter-evidence targets the February 2024 spike more cleanly than the Phiture testing-program comparison (412% Lent vs. 230% Easter vs. 300% general, generated via a controlled multi-period program) — but that comparison isn't immune to the same confound either, since the celebrity ad/paid-spend surge fell inside the Lent testing window too. The softer, defensible claim — that faith-calendar-adjacent timing is worth planning around *as one lever among several, in combination with paid spend and major campaigns* — survives and should replace the "dramatically outperforms" framing.

**Verse-sharing/social mechanics (YouVersion, not targeted):**
Not counter-evidenced. Sourced from growthcasestudies.com (corroboration_count 3) and LinkedIn/Okoro analysis (corroboration_count 2), independent of each other. **Stands as-is**, though it should be read with the same general caution the Risks section already applies to Hallow/YouVersion-derived tactics (extrapolation risk to FellowScript's niche).

**Glorify investor-interest context:** Not targeted; independently corroborated by techstartups.com and religionnews.com (two separate outlets covering the same funding event). **Stands as-is.**

### Section 6 — ASO tactics
Not targeted by counter-evidence. Corroborated 3-4x independently across Udonis, AppRadar, ASOmobile, Semrush. **Stands as-is.**

### Section 7 — Community/partnership channels mapped to group features
Contains the extrapolation-risk framing addressed by Claim 5, and untargeted claims about pastor/leader outreach, campus-ministry coalitions, and the SmartGroups comparable.
- **Stronger side:** Neither side wins because there is nothing to adjudicate — the original brief itself already flagged this as an open hypothesis (Risks, Open Questions), not a settled finding, and the counter-evidence confirms rather than contests this framing.
- **Disproven / False:** None.
- **Unresolved:** Whether Hallow's/YouVersion's parish-partnership and calendar-timing tactics generalize to a smaller, group/study-centric (rather than personal-devotional) product like FellowScript remains genuinely unresolved. The counter-evidence searched honestly for niche-specific evidence and found none — SmartGroups (the closest comparable) has no public growth/marketing track record to check against. The adjacent-category evidence found (general startup positioning commentary suggesting broad, multi-feature products can face harder positioning/ASO-targeting than single-purpose competitors) is consistent with, but does not prove, the risk. This should remain flagged as a hypothesis, not forced into a verdict either way.
- Pastor/leader outreach, campus-ministry coalitions, and SmartGroups-as-comparable claims were not targeted for counter-evidence and stand as sourced (each independently corroborated at least once, with the single-instance caveats — EveryCampus, St. John's/Hallow partnership — already flagged in the brief's own Risks section).

### Section 8 — Comparable-app positioning and differentiation gaps
Not directly targeted, though it contains the Hallow Super Bowl ad example used as counter-evidence against Section 3's authenticity claim. As a standalone competitive-landscape summary, its facts (Hallow's celebrity/institutional wins, YouVersion's SEO/habit-loop wins, Glorify's low-reliability multi-channel claim, Abide's documented pricing gap, SmartGroups as closest analog) are not contested by the counter-evidence round. **Stands as-is**, with the existing caveat already in the brief (Glorify source is low-reliability, Abide's actual tactics remain undocumented).

### Section 9 — Referral/virality mechanics
Reuses the Adapty LTV/trust claim addressed under Section 4 above; same verdict applies (LTV figure holds and is now better-sourced; trust figure is false/misattributed; "dominant pattern" framing is overstated and needs failure-mode caveats). The other mechanics in this section — progress-bar gamification (Reteno), social-recognition loops (Tapp) — were not targeted for counter-evidence and stand as sourced (independently corroborated 2x each). The directional recommendation (prioritize referral/group-invite mechanics given group-seat-priced monetization) survives the correction to the LTV/trust figures, since the corrected 16-25% peer-reviewed LTV lift alone supports it.

## Overall picture

The original brief held up well on pattern-level claims but poorly on several specific statistics and blanket framings that outran their sourcing. Of the five claims that received dedicated counter-evidence:

- **1 claim corrected and strengthened by the counter side**: referral LTV lift (now traced to peer-reviewed research instead of a vendor blog) — the rare case where the counter-evidence process left the brief in a *better* evidentiary position than it started.
- **2 claims survive as directional patterns but lose their strongest specific figures**: parish partnerships (pattern holds, "30% increase" figure does not) and calendar-timed campaigns (pattern-as-one-lever holds, "calendar timing alone drove the spike" causal claim does not — this was the single most decisively won counter-argument in the set).
- **1 claim is false as an unqualified statement but not fully resolved**: authenticity-vs-production is contradicted by the brief's own best example and rests on same-category vendor sourcing on both the original and counter side; the real, likely channel-dependent answer is untested by either.
- **1 claim was already correctly self-flagged as unresolved and remains so**: tactic transferability to FellowScript's group/study-centric niche — no evidence on either side settles this.

No claim in the brief was found broadly fabricated or untraceable to a real source; the failures found were narrower — specific numbers cited past their evidentiary weight (30% figure, 83% trust figure), a causal claim overreaching a confounded event (February 2024 spike), and one unreconciled internal tension (authenticity vs. celebrity production) that the critique resolved by inference (channel-dependence) rather than either side resolving it directly. Sections untouched by counter-evidence (1, 2, 6, 8, and most of 7) remain supported at their original sourcing strength, which was independently multi-corroborated in the majority of cases per `sources.json`.

**Net effect on downstream use:** the brief's directional recommendations (prioritize group-invite/referral mechanics, plan around faith-calendar timing as one lever, pursue parish/institutional-style partnerships, differentiate on the group+AI+editorial bundle) all survive the critique. The specific numbers that should be dropped or corrected before further downstream use are: the "30% user increase" figure, the "83% higher trust" figure, the "calendar timing alone drove the Feb 2024 spike" causal framing, and the unqualified "authenticity beats production" and "double-sided rewards are simply the dominant pattern" blanket statements — all four should carry the caveats documented above rather than being cited as settled facts.

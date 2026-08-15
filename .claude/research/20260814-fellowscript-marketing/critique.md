# Critique: FellowScript Marketing Research

Cross-examination of `brief.md` (original) against `counter-claims.json` (opposing side) for all 5 target claims selected for counter-evidence. Sources checked against `sources.json`.

## Per-claim verdicts

### Claim 1 — Parish/diocese partnerships as a distribution channel

- **Original:** Hallow partnered with 2,500+ parishes; QR codes on parish materials drove ~9% of overall growth; 2024 Catholic-organization collaborations correlated with a 30% user increase.
- **Counter:** Catholic dioceses have centralized parish-management infrastructure (e.g. ParishStaq) that Protestant/non-denominational churches lack in equivalent form, so the channel may not transfer at similar density to FellowScript's broader audience; separately, the "30% user increase" figure can't be traced to any primary data or methodology beyond the single Contrary Research mention.
- **Verdict — splits into two sub-claims with different outcomes.** The 2,500+ parishes / ~9% QR-code figure (Branch.io case study, corroboration_count 3, built on Hallow's own reported campaign data) is **not challenged** by the counter-evidence and holds as a description of what happened at Hallow. The "30% user increase" figure **fails as stated** — the counter-evidence agent's own attempt to re-source it found nothing beyond the original single mention, meaning it should be downgraded from a citable statistic to "reported but unverifiable." The structural-asymmetry argument (centralized Catholic infrastructure vs. fragmented Protestant tooling) is a **plausible but unproven mechanism**, not itself evidence the channel fails for FellowScript — it's a reason for caution, not falsification. Net: the parish-partnership *pattern* survives as directionally real for Hallow; its *transferability* to FellowScript (which is not explicitly Catholic/diocesan) is weaker than the brief implies, and the 30% figure specifically should not be relied on.

### Claim 2 — Church-calendar-timed campaigns dramatically outperform generic timing

- **Original:** 412% install/purchase growth during Lent, 230% during Easter vs. 300% from general testing-program gains; February 2024 alone drove 2M installs and a brief #1 App Store ranking.
- **Counter:** The February 2024 spike coincides with a once-since-2008 confluence (Ash Wednesday falling in the same week as Super Bowl LVIII), plus Hallow simultaneously ran a celebrity Super Bowl ad and increased paid spend 15x across Meta/Google/Apple Search Ads — Hallow's own marketing lead is quoted saying channels "don't operate in a vacuum."
- **Verdict — the counter-evidence meaningfully wins on causal attribution, but doesn't erase the underlying pattern.** This is the strongest counter-argument in the set (counter-evidence self-rated confidence 0.75, and the reasoning holds up under scrutiny): attributing the 2M-install/#1-ranking spike to "calendar timing" in isolation is not supportable once a rare calendar coincidence, a national celebrity ad, and a 15x paid-spend increase are all stacked in the same window. However, the counter-evidence targets the *February 2024 spike specifically* (Branch.io/Consumer Startups' framing) more cleanly than it targets the Phiture testing-program comparison (412% Lent vs. 230% Easter vs. 300% general), which was generated through a controlled multi-period testing program rather than a single headline event — though that comparison is *also* not immune to the same Lent-2024 confound, since the celebrity ad and paid-spend surge fell inside the "Lent" testing window too. **The specific magnitude figures and the "isolated calendar effect" framing do not hold**; the weaker, defensible claim that "faith-calendar-adjacent campaign timing is worth planning around, in combination with other levers" survives.

### Claim 3 — Faith audiences respond better to authentic storytelling than slick production

- **Original:** Corroborated by Christian Post Advertising and FrontGate Media guidance.
- **Counter:** The brief's own best-documented growth event (Hallow's Wahlberg/Roumie Super Bowl ad) is maximally produced and celebrity-driven, directly undercutting the "authenticity beats production" framing elsewhere in the same brief; additionally, the cited sources (plus a third, Salem Surround, found during counter-evidence search) are all faith-marketing agencies with a commercial incentive to sell low-production "authentic" creator content, which they can broker, over expensive celebrity campaigns, which they generally cannot.
- **Verdict — original claim does not hold as a blanket statement; the truth is more nuanced than either side states.** The internal-contradiction critique is valid and damaging: the brief cites both "celebrity/polish wins" (Hallow's Super Bowl spot, its single best-documented growth driver) and "authenticity wins" (the vendor guidance) without reconciling them. But note that `sources.json`'s own Phiture entry states Hallow's *TikTok* growth was driven by "UGC, not polished ads" — which suggests the real pattern is **channel-dependent**: paid, high-reach broadcast placements (Super Bowl) benefit from celebrity/production, while organic social content (TikTok) benefits from authenticity/UGC. Neither the brief nor the counter-claim surfaces this reconciliation. As stated, the brief's blanket "authenticity beats production" recommendation should be downgraded and qualified by channel; the counter's vendor-bias critique holds and further weakens confidence in the unqualified version.

### Claim 4 — Referral LTV/trust stats and double-sided rewards as dominant pattern

- **Original (Adapty):** Referred users show ~25% higher LTV and 83% higher trust than non-referred users; double-sided referral rewards are the dominant proven pattern.
- **Counter:** The ~25% LTV figure traces to a real peer-reviewed study (Schmitt, Skiera & Van den Bulte 2011, *Journal of Marketing*, finding 16–25% higher CLV for referred customers) — legitimate, though the brief cites the top of a range as a fixed number. The 83% trust figure appears to be a conflation of an unrelated, widely-cited Nielsen statistic (83% of consumers trust word-of-mouth from friends/family generally) — not a referred-vs-non-referred comparison at all. "Dominant proven pattern" overstates consensus: the same 2011 study and independent commentary (Atticus Li, Andrew Chen) document real failure modes — referral abuse/low-quality referrals and channel cannibalization of organic conversions.
- **Verdict — the most decisively resolved claim in this set; splits cleanly.** LTV figure: **holds**, with correction (cite as 16–25%, not a single ~25% point estimate, and attribute to the peer-reviewed study rather than Adapty). Trust figure: **does not hold** — it is very likely a misattributed statistic and should be removed or explicitly caveated wherever the brief's findings are used downstream. "Dominant proven pattern": **overstated** — should be qualified as "a common, well-precedented pattern with known failure modes (referral quality, cannibalization) that must be designed against," not treated as a default-safe choice.

### Claim 5 — Do Hallow/YouVersion tactics generalize to a smaller group/study-centric product like FellowScript?

- **Original:** The brief itself already flags this as an unresolved extrapolation risk (Risks section, Open Questions), not a settled claim.
- **Counter:** No niche-specific evidence exists either way — SmartGroups (the closest comparable) has no public growth/marketing track record to check against. Adjacent-category evidence (general startup positioning commentary) suggests broad, multi-feature products can face harder positioning/ASO-targeting than single-purpose competitors, which is consistent with — but does not prove — the risk.
- **Verdict — genuinely unresolved, correctly so on both sides.** Since the original brief never asserted this as a proven finding (it self-flagged it as a hypothesis), there is nothing here to falsify. The counter-evidence search was thorough and honestly reports a null result rather than manufacturing false certainty. This should remain in the "Unresolved" bucket, not be forced into a pass/fail verdict.

## Claims that hold

- Hallow's parish-partnership scale and QR-code attribution (2,500+ parishes, ~9% of growth) — well-sourced, unchallenged by the counter-evidence.
- The ~16–25% LTV lift for referred users — now better-sourced (academic study) than the original brief's citation.
- Church-calendar-adjacent timing as *one input among several* worth planning around (downgraded from "dramatically outperforms in isolation" to "correlates with outperformance when combined with paid spend/major campaigns").
- The extrapolation risk itself (Hallow/YouVersion tactics may not transfer to a group/study-centric product) — correctly remains an open, honestly-flagged risk rather than a resolved claim either way.

## Claims that don't hold

- **"30% user increase" from 2024 Catholic-organization collaborations** (Claim 1) — untraceable to any primary data or methodology after a direct attempt; should not be cited as a hard figure downstream.
- **"February 2024 spike proves calendar-timing dramatically outperforms generic timing"** (Claim 2) — the spike is confounded by a rare Ash-Wednesday/Super-Bowl coincidence, a celebrity ad, and a 15x paid-spend increase; the causal claim as stated is not supportable.
- **"Faith audiences respond better to authentic storytelling than slick production" as a blanket, channel-agnostic claim** (Claim 3) — contradicted by the brief's own best example (Super Bowl celebrity ad) and sourced only from commercially-interested agencies; the real pattern is channel-dependent and unresolved as a general rule.
- **"83% higher trust than non-referred users"** (Claim 4) — almost certainly a misattributed statistic (general WOM trust, not a referred/non-referred comparison); should be dropped or corrected.
- **"Double-sided referral rewards are the dominant proven pattern"** as an unqualified statement (Claim 4) — overstated; real failure modes (abuse, cannibalization) are documented in the same academic source used to defend the LTV figure.

## Confidence adjustments

- **Section 5 (church/parish partnerships)** of brief.md: confidence should drop from "well-documented growth pattern" to "well-documented for Hallow specifically, transferability to FellowScript uncertain, and the 30% figure should be dropped as a cited statistic."
- **Section 5 (calendar-timed campaigns)**: confidence in the specific 412%/230%/2M-install figures should drop materially; the softer claim ("plan marketing pushes around Lent/Easter as one lever among several, not the primary lever") remains reasonably supported.
- **Section 3 (authenticity vs. production)**: confidence drops from "independently matches external guidance" to "contested — self-consistent vendor narrative not corroborated by disinterested sources, and contradicted by the brief's own best example without a channel-specific caveat."
- **Section 9 (referral/virality)**: LTV figure confidence rises slightly (now backed by peer-reviewed research instead of a vendor blog); trust figure confidence drops to near-zero (likely misattribution); "dominant pattern" framing should be presented with explicit failure-mode caveats rather than as an unqualified recommendation.
- **Section 7 / Risks (tactic transferability to FellowScript's niche)**: no change — correctly already flagged as unresolved in the original brief; the counter-evidence process confirms rather than changes this.

## Unresolved

- Whether Hallow's and YouVersion's parish/diocese and calendar-timing tactics generalize to a smaller, group/study-centric (rather than personal-devotional) product like FellowScript — no evidence on either side resolves this; remains a hypothesis to be tested, not a fact to act on.
- Whether authenticity or high-production/celebrity content performs better for FellowScript specifically — the brief and counter both surface real but incomplete evidence; the likely truth (channel-dependent) is not directly tested by any source found in either round.
- What specifically distinguishes FellowScript's AI+group combination from SmartGroups' — untouched by this critique round, carried over from the brief's own Open Questions.

## Bounce assessment

No bounce. All 5 target claims received genuine, substantive counter-evidence attempts with specific reasoning and traceable (or explicitly untraceable-and-flagged) sources — the opposing side was not too thin to critique. No claim in the brief was found to be untraceable to its cited source (the weaknesses found are in the *reliability* of what the cited sources themselves assert, which the brief's own Risks section already anticipated as a category of concern) — so there is no fundamental brief-level flaw requiring a bounce to research-brief.

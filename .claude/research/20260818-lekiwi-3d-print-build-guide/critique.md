# Critique: LeKiwi From-Scratch Build Walkthrough (3D-Printed Parts)

Five target claims (A–E, per `counter-evidence-scope.json`) were tested against genuine counter-evidence-gathering attempts recorded in `counter-claims.json`. Below, each is put side by side and stress-tested in both directions — including probing whether the counter-evidence actually contradicts the original claim, or merely adds nuance to it, and whether an absence of counter-evidence should raise or merely fail to lower confidence in the original.

## Per-claim verdicts

### A — "Print/assembly friction is thinly documented" / implied smooth build

- **Original (brief.md):** No independent, non-vendor account documents physical print/assembly friction (warping, tolerance mismatch, part breakage, heat-set-insert problems). The one independent builder account (Foxglove) reports the base "arrived pre-integrated," was "a breeze," with zero physical friction — all friction was software-side.
- **Counter (counter-claims.json):** Three independent GitHub artifacts on the official repo show real, externally-discovered design shortcomings: issue #17 (open, filed by a non-maintainer) documents a camera-mount cutout mirrored for the wrong side, requiring the user to hand-modify the STL; PR #9 (merged by a maintainer) replaced the drive-motor mount specifically for "enhanced structural rigidity" and to eliminate standoffs; PR #26 (open, unmerged) proposes a servo-mount redesign for "enhanced stability" and easier hex-nut installation.
- **Stress test:** Does this counter-evidence actually contradict the claim, or just add nuance? Splitting it out: none of the three artifacts documents warping, tolerance mismatch, part breakage, or a heat-set-insert problem — the specific failure modes the brief enumerated. On that narrow reading, the brief's enumerated list survives intact. But the brief's broader framing — "no independent account documenting physical friction" and the implicit "smooth build" impression — does not survive. Issue #17 is a first-hand, dated, specific fit failure with a stated workaround; PR #9's maintainer-accepted rigidity redesign is an implicit admission that the original mount had a real shortcoming (the PR text itself cites eliminating a design element, not just cosmetic preference). These are independent, non-vendor accounts of physical/mechanical friction that the brief's search did not surface, and they predate this task (issue #17: May 2025; PR #9: April 2025) — they were locatable, just missed by web/vendor-source-focused sourcing.
- **Verdict:** Partial win for counter-evidence. The brief's *specific* risk list (warping/tolerance/breakage/heat-set) is not contradicted. But the *general* "thinly documented, apparently smooth" framing is weakened and should not be read as "no evidence of any physical-build friction exists" — it should be read as "no evidence of *catastrophic or print-quality* friction exists, but *design-file-level* friction (mount rigidity, part-fit mismatches for at least one camera variant) is independently documented and has already prompted community/maintainer fixes." PR #26 remains weak (unmerged, unreviewed) and shouldn't be weighted equally with issue #17 or PR #9.

### B — No heat-set inserts (mechanical reliability implication)

- **Original:** SO-101 arm design explicitly uses no heat-set inserts (screws thread directly into plastic); LeKiwi base is silent on this, which the brief correctly flagged as not a confirmed absence either way.
- **Counter:** Targeted GitHub search across both repos for "heat-set," "stripped thread," "cracked" returned zero on-topic hits.
- **Stress test:** A negative search result on two repos' issue trackers is weak evidence of absence — stripped-thread problems are exactly the kind of failure a hobbyist would post to a forum or Reddit rather than file as a GitHub issue, and that broader search could not be executed (tooling gaps, named explicitly in both `source-gathering.json` and this round's search). The absence of hits neither confirms nor meaningfully weakens the original claim.
- **Verdict:** Holds, but on thin ice. Treat as genuinely unresolved rather than "confirmed safe" — the search that could have found real-world stripped-thread complaints (Reddit/forums) never ran.

### C — Print time (~34h) / assembly time (~2h) estimates

- **Original:** Vendor-sourced figures from `3DPrinting.md` and `Assembly.md`.
- **Counter:** Targeted GitHub search for independent print/assembly time reports found nothing.
- **Stress test:** Vendor time estimates are notoriously optimistic in the 3D-printing hobbyist world generally (slicer estimates vs. real print time, first-timer assembly friction vs. experienced builder). A single-source, single-sample time estimate with no independent corroboration is inherently soft, regardless of whether counter-evidence was found. The absence of contradiction is not the same as corroboration.
- **Verdict:** Holds as the only figure available, but confidence should not rise on the back of a negative search — it should be reported as vendor-estimate-only, unverified by any independent build log.

### D — Motor-ID assignment pitfall (7/8/9 → rear/left-front/right-front)

- **Original:** Sourced only to the independent Seeed Studio wiki; brief's own Risks section worried this might be a Seeed-specific kit-variant note rather than a universal requirement, since the primary Assembly.md doesn't mention it.
- **Counter:** Direct inspection of the official `huggingface/lerobot` driver source (`lekiwi.py`) shows the mapping is hardcoded in software (`base_left_wheel = Motor(7)`, `base_back_wheel = Motor(8)`, `base_right_wheel = Motor(9)`) — universal across all LeKiwi builds on the official stack, not vendor-specific. Independent GitHub issue #1243 (closed as stale, not resolved) corroborates that wheel-motor-ID setup is a real, recurring builder pain point.
- **Stress test:** Applying the same skepticism used against claim A's counter-evidence: is source-code inspection actually dispositive, or could physical kits differ from software defaults? Software enforcement of an ID mapping is about as strong as primary-source evidence gets for a software-configuration claim — a build using different physical wiring/positions but the stock software would simply be miswired, which is precisely the pitfall being warned about. This isn't circumstantial; it's the literal mechanism enforcing the claim.
- **Verdict:** Strengthened, not just held. This is the strongest resolution in this critique round — a single-sourced brief risk item is now corroborated by primary code plus an independent bug report. The brief's own hedge ("raises a small risk it reflects a Seeed-specific build variant") should be retracted.

### E — Real-world spend vs. $482–499 reference BOM baseline

- **Original:** $482 (12V) / $499 (5V), explicitly excluding print cost, treated as "the harder number" per prior research.
- **Counter:** No independent itemized real-spend account (shipping, duties, reprints, substitutions) was located; two of four planned GitHub queries hit rate limits before completing. The only other independent cost data point, orobot.io's $450-550 estimate, sits within/near the reference range rather than above it.
- **Stress test:** Is a rate-limited, incomplete search sufficient basis to hold the original claim at face value? No — this is the weakest-executed check of the five (2 of 4 queries never ran). The orobot.io figure is an estimate, not an actual-spend report, so it doesn't independently confirm real-world spend tracks the baseline either.
- **Verdict:** Genuinely unresolved, more so than claims B/C. The original $482-499 figure should be reported as an unverified vendor reference, not a real-world-confirmed baseline, and the search gap (incomplete due to rate-limiting, not just tooling absence) should be flagged more prominently than a simple "held" would suggest.

## Claims that hold

- **D (motor-ID mapping)** — holds and is strengthened; now primary-source-confirmed as universal, not vendor/kit-specific.
- **C (print/assembly time estimates)** — holds as the only available figure, but remains single-source and should not be treated as independently verified.
- **B (no heat-set inserts / silence on LeKiwi base)** — holds, but the negative search that could resolve it (Reddit/forums) never ran; treat as open, not confirmed-safe.
- **A's narrow claim (no evidence of warping, tolerance mismatch, breakage, or heat-set-insert failure specifically)** — holds; none of the counter-evidence found bears on these specific failure modes.

## Claims that don't hold

- **A's broader claim ("thinly documented" / implicit smooth-build impression, "no independent account documenting physical friction")** — does not hold as stated. Issue #17 (open, unresolved camera-mount fit mismatch) and PR #9 (maintainer-merged rigidity redesign, implying a real prior shortcoming) are independent, dated, non-vendor accounts of physical/design friction with the official print files. The brief's Risks section should be revised to distinguish "no print-quality failure reports" (still true) from "no friction reports of any kind" (now false).
- **The brief's Risks-section hedge on the motor-ID claim** ("raising a small risk it reflects a Seeed-specific build variant note rather than a universal requirement") — does not hold; directly contradicted by primary source code.

## Confidence adjustments

- **Claim A (build friction):** brief.md's implicit confidence in a "smooth, low-friction physical build" should move down. `counter-claims.json`'s own confidence score of 0.35 for this claim is a reasonable summary — enough independent counter-signal exists to caveat the "smooth build" framing in any downstream conclusion, without reversing it into "the build is friction-prone" (no failure of comparable severity to warping/breakage was found).
- **Claim D (motor-ID mapping):** should move up beyond `counter-claims.json`'s own 0.85 — this is effectively resolved. Confident enough to state as a hard build-risk fact in any downstream output, sourced primarily to the code, with Seeed wiki and issue #1243 as corroboration rather than sole support.
- **Claims B, C, E:** confidence stays low/unchanged (0.15 as scored in counter-claims.json is appropriate) — these are genuine "search attempted, nothing found" results, not corroboration. E in particular should be flagged as an *incomplete* search (rate-limited) rather than a clean negative, which is a slightly weaker basis than B or C.
- **Four-way cost figure inconsistency** ($482-499 / $660 / $770.47 / $450-550, from brief.md's Risks section): unaffected by this critique round — claim E's check was narrowly about real-world spend vs. the reference BOM, not full reconciliation, and remains explicitly out of scope. Confidence in any single cost figure should stay hedged in downstream output.

## Unresolved

- **Heat-set-insert failure risk on the LeKiwi base (claim B):** genuinely open — the search channel most likely to surface it (forums/Reddit) never ran.
- **Real-world total spend vs. reference BOM (claim E):** genuinely open, and the search was incomplete (rate-limited), not just narrow.
- **Whether print/assembly time estimates hold up in practice (claim C):** genuinely open — no independent build log exists to check the vendor figures against.
- **Severity of the design-file friction surfaced under claim A:** issue #17 is scoped to a specific alternate camera (Innomaker) rather than the default BOM camera, and it's unclear from available evidence whether a builder using the stock BOM parts would ever encounter it. This nuance was not resolved by either side and should be carried forward rather than treated as a general "expect fit problems" warning.

# Diff Evaluation: LeKiwi From-Scratch Build Walkthrough (3D-Printed Parts)

This evaluates `critique.md`'s five per-claim verdicts (A–E) against the full content of `brief.md` / `sources.json` (original side) and `counter-claims.json` (opposing side), organized by the brief's own section structure. No new evidence is introduced here — this is a weighing of what the critique already established.

## Section 1 — Official print files, location, printer requirements

Covers claim B (no heat-set inserts on the SO-101 arm; LeKiwi base is silent) and part of claim C (~34h print time).

- **Stronger side:** Original, by default — the counter-evidence side ran genuine, targeted searches (GitHub issue/PR search across both repos for "heat-set," "stripped thread," "cracked," and separately for print-time reports) and found nothing on-topic. No side produced evidence that *contradicts* the vendor figures; the only question is how much confidence a clean negative search should add.
- **Disproven:** None.
- **False:** None.
- **Unresolved:** Both claims. The critique is explicit that the searches most likely to surface real-world contradiction (Reddit/forums/build-log video) never ran — named as a tooling gap in `source-gathering.json` and again in this round's search. A GitHub-issue-tracker-only negative result is weak evidence of absence for exactly this kind of failure mode (stripped threads, longer-than-advertised print times), since hobbyists post such complaints to forums, not issue trackers. Treat the ~34h print time and the arm's no-heat-set-insert design as vendor-sourced and not independently verified, not as confirmed facts.

## Section 2 — Print-vs-buy split and BOM

Covers claim E ($482 (12V) / $499 (5V) baseline vs. real-world spend).

- **Stronger side:** Neither — this is the weakest-executed check of the five. Two of four planned GitHub queries hit rate limits before completing, which is a materially different (and worse) kind of gap than a clean negative search. The one other data point available, orobot.io's $450-550 estimate, is itself an estimate rather than an itemized actual-spend account, so it doesn't independently confirm the baseline either.
- **Disproven:** None.
- **False:** None.
- **Unresolved:** The core question (does real-world spend run meaningfully above the $482-499 reference BOM) is genuinely open, and more so than B or C because the search itself was incomplete rather than merely narrow. Report $482-499 as an unverified vendor reference figure, not a real-world-confirmed baseline. The brief's separately-flagged four-way cost inconsistency ($482-499 / $660 / $770.47 / $450-550) is untouched by this critique round — it was explicitly out of scope for claim E's narrower real-world-spend check — and should stay hedged in any downstream output.

## Section 3 — Phased assembly sequence

Covers claim D (motor-ID assignment pitfall, 7/8/9 → rear/left-front/right-front) and part of claim C (~2h assembly time, unresolved as above).

- **Stronger side:** Original claim's substance is confirmed and strengthened by the counter-evidence — but the brief's own self-imposed hedge on that claim is disproven. Direct inspection of the official `huggingface/lerobot` driver source (`lekiwi.py`) shows the motor-ID mapping is hardcoded in software, universal across all LeKiwi builds on the official stack — not a Seeed-wiki-specific kit-variant note as the brief's Risks section worried. Independent GitHub issue #1243 (real builder pain point, closed as stale rather than resolved) corroborates that this is a genuine, recurring friction point rather than a one-off.
- **Disproven:** The brief's Risks-section hedge — "raising a small risk it reflects a Seeed-specific build variant note rather than a universal requirement" — is directly contradicted by primary source code and should be retracted, not just softened.
- **False:** None (the underlying motor-ID claim itself was never false; only the brief's own qualifier about its scope was wrong).
- **Unresolved:** ~2h assembly-time estimate — same status as the print-time estimate in Section 1: no independent corroboration found, but no contradiction either; vendor-sourced and unverified.

## Sections 4-5 — Software/firmware setup phase

No claim from this section (A–E) was targeted by the counter-evidence round per `counter-evidence-scope.json`/`counter-claims.json`. Nothing in `critique.md` bears on the HF LeRobot install/calibration/teleoperation content or the Seeed-wiki-sourced software gotchas (USB permissions, `lerobot-find-port` cable-disconnect requirement, macOS Input Monitoring, SSH-off-by-default). These carry forward from the brief unchanged and untested by this critique round — not confirmed further, but not weakened either.

## Section 6 — Known friction points and build risks

Covers claim A (print/assembly friction thinly documented / implicit smooth-build impression) most directly, and restates the D and E findings above.

- **Stronger side:** Split verdict, and the split matters. On the brief's *narrow*, enumerated list of failure modes (warping, tolerance mismatch, part breakage, heat-set-insert problems), the original side is stronger — none of the counter-evidence documents any of these specific failures, so that list survives intact. On the brief's *broader* framing ("no independent account documenting physical friction," implicit "smooth build" impression), the counter-evidence side is stronger: three independent, non-vendor GitHub artifacts on the official repo (issue #17, PR #9, PR #26) were locatable and simply missed by the brief's web/vendor-focused sourcing.
- **Disproven:** The brief's broad claim that "no independent account documenting physical/design friction" exists is disproven as stated. Issue #17 is a first-hand, dated (May 2025), specific report of an actual print-file design flaw (camera-mount cutout mirrored for the wrong side) with a stated manual-STL-fix workaround — a genuine independent account of physical/design friction the brief's search did not surface. PR #9 (maintainer-merged, April 2025) is a second, independent data point: a structural-rigidity motor-mount redesign that implicitly concedes the original mount had a real shortcoming.
- **False:** No claim in this section is false outright — the narrow, specific failure-mode list (warping/tolerance/breakage/heat-set) remains uncontradicted, and PR #26 is weak, unmerged evidence that shouldn't be weighted as strongly as issue #17 or PR #9. The correct read is "disproven as broadly framed," not "false in its specifics."
- **Unresolved:** How severe or representative the design-file friction from claim A actually is. Issue #17 is scoped to an alternate (Innomaker) camera rather than the default BOM camera, and it's unclear whether a builder using stock BOM parts would ever encounter it — neither side resolved this, and it should be carried forward as a nuance rather than generalized into "expect fit problems." The Foxglove/Aditya Kamath account (single experienced builder, zero physical friction reported) still stands as the only first-hand full-build account and is not contradicted, just no longer the whole picture.

## Overall picture

The brief held up well on its narrow, carefully-scoped claims and was correctly self-aware about its own weakest points (it flagged the sparse print-friction data, the four-way cost inconsistency, and the motor-ID hedge as risks in its own Risks section before critique even ran). The counter-evidence round, despite real tooling gaps (rate limits, no forum/Reddit access), successfully located material the brief's search missed on GitHub itself — evidence that the brief's "thinly documented, apparently smooth" framing was too strong, and evidence that resolved one of the brief's own self-flagged uncertainties (the motor-ID hedge) definitively in the original claim's favor.

Net effect: one brief-authored hedge is disproven (motor-ID scope), one brief framing is disproven as too broad while its narrow form survives (print/assembly friction), and three claims (heat-set inserts, print/assembly time, real-world cost vs. baseline) remain genuinely unresolved rather than confirmed — the counter-evidence round's negative searches (especially the incomplete, rate-limited one for cost) should not be read as corroboration. No claim in the brief was shown to be flatly false; the strongest actual reversal is the retraction of the brief's own Seeed-specific-variant hedge on the motor-ID mapping, which the critique correctly upgrades from "held" to "strengthened."

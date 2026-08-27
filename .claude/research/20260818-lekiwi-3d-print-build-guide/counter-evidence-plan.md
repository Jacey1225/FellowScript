# Counter-Evidence Plan: LeKiwi From-Scratch Build Walkthrough

## Target claims

Selected because they are load-bearing for a builder actually attempting this from-scratch print build, and because `sources.json` / the brief's own Risks section show they rest on thin, single-lineage, or vendor-only corroboration.

### A. "Smooth, low-friction print/assembly build" (implicit claim)

Quoted from brief.md: "No independent, non-vendor builder account documenting physical print/assembly friction (tolerance issues, warping, part breakage, heat-set-insert problems...) was found in this round," and the one account located reports the base "arrived pre-integrated" and was "a breeze" to integrate, with "zero physical build/print friction reported."

Why it matters: this is the single most load-bearing claim for a first-time builder deciding whether to attempt the print path, and the brief's own Risks section already flags it as resting on one experienced builder (Foxglove/Aditya Kamath, who had prior SO-100 print/servo experience) — likely to understate friction for a less experienced builder. The brief also notes the WebSearch budget was exhausted before a planned Reddit/forum/video build-log search — a known, named coverage gap, not evidence of an actual absence of friction.

### B. "No heat-set inserts are used" / screws thread directly into printed plastic (SO-101 arm; base parts documented similarly by omission)

Quoted from brief.md: "notably — no heat-set inserts (screws thread directly into printed plastic)" (SO-101, sourced to `TheRobotStudio/SO-ARM100`), and for the base, "No... heat-set-insert guidance is given for the base parts specifically" (silence, not a confirmed absence).

Why it matters: this is a specific mechanical-reliability claim (screws-into-raw-PLA threads are a well-known 3D-printing failure mode for repeated disassembly/reassembly or vibration-loaded joints like wheel hubs) stated with more confidence than a single primary-source doc plus one vendor-tutorial corroboration (corroboration_count: 1 for the SO-ARM100 source) supports.

### C. Print-time and assembly-time estimates (~34 hours total print time for the base; ~2 hours total assembly)

Quoted from brief.md: "~34 hours total print time across 11+ parts" and Assembly.md's "~2 hours total" fastener-level sequence.

Why it matters: both figures come only from official/vendor documentation (SIGRobotics-UIUC repo), which has an incentive to present the build as approachable. These are exactly the kind of numbers a builder plans around (time budgeting), and neither has independent corroboration in `sources.json`.

### D. Motor-ID assignment pitfall (drive-motor IDs 7/8/9 -> rear/left-front/right-front)

Quoted from brief.md: "wheel drive-motor IDs 7/8/9 must be assigned to specific physical positions (8=rear, 7=left-front, 9=right-front), and mis-assignment is a documented pitfall" — sourced only to the independent Seeed Studio wiki, not confirmed or even mentioned by the official Assembly.md.

Why it matters: this is presented in the brief as a firm, actionable instruction a builder would follow exactly, but it is single-sourced and the brief itself flags in Risks that it "raises a small risk that it reflects a Seeed-specific build variant note rather than a universal requirement."

### E. "$482-499 as the harder/more reliable cost figure" (narrow slice, not full four-way reconciliation)

Quoted from brief.md: BOM.md "totals $482 (12V complete variant), $499 (5V complete variant)... explicitly excluding 3D-printing filament/time cost," carried forward from prior research's critique treating $482-499 "as the harder number."

Why it matters: full reconciliation of all four cost figures ($482-499 / $660 / $770.47 / $450-550) is explicitly out of bounds per `research-plan.md`. This target is narrower and in-bounds: whether real-world total spend by an actual from-scratch builder (including failed prints requiring reprint filament, shipping/import costs, price drift since the reference BOM was priced, or substitutions due to unavailable parts) runs meaningfully above the $482-499 reference figure even before factoring in the unreconciled $660/$770/$450-550 figures. This tests the confidence of the baseline number itself, not the cross-figure gap.

## Search angles

**A — smooth build claim**
- Look for: Reddit (r/robotics, r/3Dprinting, r/LocalLLaMA-adjacent hobbyist communities), YouTube build-log videos, personal blogs, Hackaday/Instructables-style writeups, and GitHub Issues/Discussions on both `SIGRobotics-UIUC/LeKiwi` and `huggingface/lerobot` that mention print warping, dimensional tolerance mismatches, wheel-hub/servo-horn fit problems, part breakage, or first-time-builder difficulty.
- Genuine counter-evidence here is a *specific documented failure or difficulty*, not just "no one else has written about it" (absence of further silence doesn't count). A single credible independent account of friction is enough to at least partially rebut this claim.
- Also worth checking: GitHub Issues/Discussions tabs directly (not just web search) since the brief only checked the Issues tracker for "print tolerance, part fit, or assembly problems" in one pass — a second look at Discussions (a distinct GitHub feature, easy to miss) or closed/resolved issues is cheap and was not explicitly ruled out.

**B — no heat-set inserts claim**
- Look for: builder accounts, forum threads, or repo issues describing stripped threads, cracked mounts, or the need to retrofit heat-set inserts against the documented design. General PLA/PLA+ self-tapping-screw failure-mode discussions (e.g., 3D-printing subreddits, Prusa/Bambu forums) that specifically reference SO-ARM100/SO-101 or LeKiwi parts would count; generic "PLA screw threads are fragile" commentary with no LeKiwi/SO-101 tie-in is weaker evidence and should be flagged as such rather than treated as a direct rebuttal.
- Prefer sources describing actual repeated assembly/disassembly (a real risk for a robot arm builder iterating on calibration) over one-time-assembly reports.

**C — time estimate claims**
- Look for: independent build logs (blog posts, forum threads, video timestamps/descriptions) that report actual elapsed print time or assembly time for LeKiwi or SO-101 parts, to compare against the official ~34 hour / ~2 hour figures. A single independent data point with a materially different number (e.g., "took me a weekend of failed prints" or "closer to 6 hours of assembly with cable routing") is sufficient counter-evidence to warrant hedging.
- Community slicer-estimate discussions (e.g., people posting their own sliced-time screenshots for the same STL set) also count as light corroboration/counter-evidence even without a full build log.

**D — motor-ID pitfall claim**
- Look for: the official `lerobot-setup-motors` documentation or the LeRobot GitHub repo (Issues/Discussions) for any confirmation, contradiction, or generalization of the 7/8/9 ID scheme — is it hardcoded in software (`lekiwi_host` or the base driver config), user-assigned during setup, or specific to Seeed's own kit variant? If it's software-enforced, that's a form of counter-evidence against the Seeed-specific-note theory (it would need to be universal, not vendor-specific). If it turns out to be arbitrary/configurable, that's counter-evidence against the pitfall being a fixed, universal requirement as stated.
- Any other independent builder account (forum, video) that assigns motor IDs differently and still gets a working build would materially weaken the claim as currently stated.

**E — real-world total spend claim**
- Look for: independent builder posts (forum, blog, Reddit) that itemize actual total spend including shipping, taxes/import duties (relevant given SIGRobotics-UIUC and Seeed Studio are US/China-based respectively — international builders may see materially different real costs), reprints due to failed prints, or part substitutions due to availability. Explicitly not chasing the $660/$770/$450-550 aggregator figures again — those are already covered and out of bounds to reconcile further; the angle here is "does anyone report paying meaningfully more than $482-499 in practice, and why."

## Constraints (inherited + counter-evidence-specific)

Inherited from `research-plan.md`:
- LeKiwi-specific only; do not chase non-LeKiwi builds (e.g., generic SO-ARM100-only or Sawppy/Bittle friction) except where directly cited as SO-ARM-family-applicable background already established by prior research.
- Recency: prefer current repo/doc state; flag anything that looks stale relative to the 2026-08-18 sourcing round.
- Do not re-litigate whether LeKiwi is the "best" hobbyist candidate, and do not attempt full reconciliation of the four cost figures — claim E is scoped narrowly to avoid this.
- Vendor/press-only sourcing should be treated with the same skepticism the prior critique applied; corroborate with at least one non-vendor source where possible — this applies doubly here since the whole point of this stage is to find non-vendor counter-evidence.

Counter-evidence-specific:
- A source that merely restates or links back to the same official docs (3DPrinting.md, Assembly.md, the Seeed wiki) does not count as counter-evidence, even if phrased differently — it must add independent observation (an actual build attempt, a differing data point, or a technical rebuttal), not just re-cite the primary claim.
- Distinguish "no counter-evidence found" (a genuine, reportable negative result — especially likely for claim A given the already-documented search-budget gap) from "counter-evidence found but weak/tangential" (e.g., generic PLA-screw-thread complaints with no LeKiwi/SO-101 tie-in for claim B) — both should be reported honestly rather than stretched to look more decisive than they are.
- Where a claim turns out to be well-supported even after a genuine counter-evidence search (e.g., if claim D turns out to be software-enforced and therefore solid), report that as a successful, resolved check — not a failure to find something to argue.
- Respect the same WebSearch/browser-automation tooling limits noted in `source-gathering.json` (the prior round hit HTTP 403 on two community-remix files and exhausted WebSearch budget before a planned forum search) — if a targeted search hits the same wall, note it explicitly as a tooling gap rather than silently dropping the claim.

## Success criteria

A good-faith counter-evidence effort for this topic:
- Makes at least one genuine, targeted attempt per claim (A-E) using the search angles above, prioritizing claim A first since it has the clearest documented coverage gap (the exhausted forum/Reddit/video search) and the highest practical stakes for a builder.
- Reports honest outcomes per claim: confirmed (counter-evidence found and credible), weakened (partial/tangential counter-evidence, e.g. generic-but-relevant complaints), or held (no credible counter-evidence found despite a real search) — not forced into a uniform "we found opposition" narrative.
- Any counter-evidence surfaced is itself sourced and dated, with enough detail (who, where, what specifically was observed) for the critique stage to weigh it against the original claim's sourcing.
- Does not introduce new out-of-scope material (non-LeKiwi builds, full cost-figure reconciliation, printer-buying advice) even if it surfaces during search.
- If tooling limits (WebSearch budget, browser automation) block a genuine attempt on a given claim, that is recorded as a distinct, named gap rather than conflated with "no counter-evidence exists."

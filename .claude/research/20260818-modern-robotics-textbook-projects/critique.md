# Critique: Modern Robotics Textbook — Chapter-Mapped Project Suggestions

Scope: the six target claims defined in `counter-evidence-plan.md`, each drawn
from Section 2 (candidate projects) and the Risks section of `brief.md`. The
textbook-structure claims in Section 1 are out of scope by design (single
primary source, no external corroboration possible or needed) and are not
re-litigated here.

## Per-claim verdicts

### 1. SO-ARM100 cost (~$115 single / ~$230 dual) and "thousands of builders"

- **Original (brief §2A):** ~$115 single arm, ~$230 dual-arm teleop, large
  active builder community, sourced to Seeed Studio (vendor) and Hackster.io
  (press).
- **Counter:** the $115 figure is a bare-frame-kit price; Seeed's own
  electronics-only listing is $200 "Without 3D Printed Parts," and
  cross-vendor pricing (nanocorp, WowRobo, PartaBot) converges on ~$229.88 for
  a complete single-arm BOM — roughly double the brief's headline number. Two
  open (one closed "not planned") GitHub issues on the official `lerobot`
  repo document real, unresolved calibration failures. "Thousands of
  builders" could not be independently confirmed or refuted anywhere.
- **Verdict: counter survives, original does not, on cost.** The vendor-page
  $115 figure the brief led with describes one component (a bare frame),
  not a complete buildable arm; the cross-vendor $200-230 figure is the more
  honest "what does it actually cost to build one" number and should replace
  or heavily caveat the brief's figure. The calibration-friction finding also
  survives — it comes from the project's own issue tracker (independent of
  vendor/press framing) and one report was explicitly closed without a fix,
  which is stronger evidence than the brief's smooth-build framing conveyed.
  The community-size claim is **unresolved**, not falsified: absence of
  independent confirmation is not evidence against it, only evidence that
  the number traces to a single press mention.

### 2. LeKiwi cost (~$660) and "documented, replicable BOM"

- **Original (brief §2B):** ~$660 total, sourced to two ostensibly
  independent aggregators (robotsthatexist.com, robotics.growbotics.ai).
- **Counter:** the actual upstream reference BOM linked from Hugging Face's
  own LeKiwi docs (SIGRobotics-UIUC/LeKiwi) totals $482-499, excluding
  3D-printing cost — lower than, and not cleanly reconcilable with, $660.
  An independent, non-affiliated builder (Foxglove/Aditya Kamath) reports
  the base kit worked "out of the box" with accurate odometry — this
  actively *supports* the buildability half of the claim. Whether
  robotsthatexist.com and growbotics.ai are genuinely independent verifiers
  of the $660 figure, or both mirror a single upstream number, could not be
  determined (both are JS-rendered pages the available tooling couldn't
  read).
- **Verdict: buildability holds; the specific cost figure is unresolved, not
  confirmed.** The brief's core claim — LeKiwi is a real, buildable platform
  with a documented BOM — survives and is now backed by a genuinely
  independent builder account, which is stronger evidence than either side
  had before this round. But the $660 headline figure sits meaningfully
  above the $482-499 reference BOM with no reconciling explanation (print
  cost and shipping could plausibly close some of the gap, but that's
  speculation, not confirmation), and the "independently documented"
  framing for the two aggregator sources remains unverified rather than
  established. Treat $660 as an upper-bound estimate, not a confirmed figure.

### 3. Dynamics/Ch.8 "structural gap" claim

- **Original (brief Risks):** all four candidates use position-controlled
  hobby servos, so none genuinely exercises Ch.8's Lagrangian/Newton-Euler
  dynamics formalism — flagged by the brief itself as an unsourced editorial
  judgment call.
- **Counter:** Feetech servos (used in SO-ARM100/LeKiwi) do expose a
  current-based torque-sensing capability in principle, but no documented
  default tutorial path for any of the four candidates uses it. Direct
  firmware inspection confirms OpenCat/Bittle runs on precomputed
  angle-lookup gait tables with no runtime dynamics computation.
- **Verdict: original claim holds and is now better-sourced than before.**
  This is the one target where the counter-evidence agent's own framing
  (correctly) treats a "nothing found" result as corroboration rather than a
  gap. The claim moves from "unsourced editorial judgment" to "editorial
  judgment now backed by primary firmware/hardware-doc evidence." This is a
  genuine confidence *increase*, not just a survival.

### 4. Bittle/OpenCat "genuine inverse kinematics, not pre-baked motions"

- **Original (brief §2D):** OpenCat's gait generation "genuinely requires
  per-leg IK to hit foot-placement targets, per the framework's own
  documentation" — sourced solely to the OpenCat GitHub README.
- **Counter:** direct inspection of `InstinctBittle.h` shows gait execution
  is playback of static precomputed joint-angle tables, not live per-step IK
  solving. A separate, independent community tool
  (`ger01d/kinematic-model-opencat`) confirms IK is computed *offline* on a
  development machine and the resulting angle sequences are baked into
  firmware — a design-time step, not a runtime behavior. Critically, the
  current OpenCat README (the brief's own sole citation) contains zero
  occurrences of "kinematic" or "IK" — the specific technical claim was
  more asserted than actually present in the cited source.
- **Verdict: does not hold as stated.** This is the clearest falsification in
  either direction this round. The counter-evidence is primary-source
  (actual running firmware code, independent of both vendor and brief
  framing) and directly contradicts the "genuinely exercises... not just
  pre-baked motions" language. The accurate framing is: IK is a real part of
  *how the gait tables were authored* (a legitimate Ch.6 connection at
  design time) but the robot's on-device behavior is closer to "pre-baked
  motions" than the brief's own words concede. The brief's chapter-mapping
  for Bittle → Ch.6 should be softened to reflect design-time IK use, not
  runtime IK execution — and the citation gap (claim not actually present in
  its own cited source) is a real sourcing weakness worth flagging
  independent of the technical finding.

### 5. Bittle currency ("actively sold, maintained product... not dead")

- **Original (brief §2D + Risks):** still actively sold as of research date;
  Kickstarter numbers are dated but the product line is not defunct.
- **Counter:** the current official README states the original Bittle
  (NyBoard/ATmega328P — the exact hardware the 2020 backers funded) is now
  "discontinued but still fully supported," superseded as the
  actively-marketed product by "Bittle X" (ESP32/BiBoard).
- **Verdict: partially holds, with a real qualification.** The brief's
  underlying point — this is not an abandoned, dead project — survives and
  is arguably strengthened (an actively developed successor is stronger
  evidence of a living ecosystem than a merely-still-listed original
  product would be). But "remains an actively sold... product" is not
  precisely true of the specific hardware tied to the cited $567,218/2,052
  backer numbers; that specific product is discontinued. The brief should
  distinguish "the Bittle lineage/brand is alive" from "the exact
  2020-funded product is still the current offering."

### 6. Blanket hobbyist-feasibility framing (all four candidates)

- **Original (implicit across §2A-D):** all candidates are buildable by an
  individual hobbyist at the stated cost/tool level, supported mostly by
  vendor/creator/press sources.
- **Counter:** independent, non-vendor sources (LeRobot GitHub issues,
  Hackaday.io Sawppy build logs, The Gadgeteer and Tom's Hardware reviews)
  consistently report real friction — calibration instability, heat-set
  insert tolerance problems, inadequate included tools, cost overruns beyond
  headline figures, and in Tom's Hardware's case a conditional
  value judgment ("probably not worth the investment" for a user who isn't
  after a coding platform). None of this evidence shows any candidate is
  *not* buildable.
- **Verdict: core claim holds, "turnkey" undertone does not.** Buildability
  survives across all three physically-inspected candidates. But the
  brief's largely vendor/press-sourced framing understates the skill floor,
  tool prerequisites, and real cost — this is a legitimate, evidence-backed
  correction to degree/tone, not a reversal of the underlying claim.

## Claims that hold

- **Dynamics/Ch.8 structural gap (#3)** — holds, and moves from unsourced
  judgment call to evidence-backed finding.
- **LeKiwi buildability (#2, buildability half)** — holds, now backed by a
  genuinely independent builder account (Foxglove blog) in addition to the
  original aggregator sources.
- **Bittle "not a dead project" (#5, core claim)** — holds; the ecosystem is
  demonstrably still active (an actively developed successor exists), even
  though the specific 2020 product is discontinued.
- **General hobbyist-feasibility (#6, core claim)** — holds; nothing found
  shows any candidate is actually unbuildable by an individual.

## Claims that don't hold

- **SO-ARM100 headline cost of ~$115 (#1)** — falls apart under scrutiny; it
  describes a component price, not a complete-build price. The cross-vendor
  ~$200-230 figure is the more defensible number for "what does building one
  actually cost."
- **Bittle "genuinely exercises IK, not pre-baked motions" (#4)** — falls
  apart under scrutiny; primary firmware inspection shows on-device
  execution is precomputed table playback, and the claim's own cited source
  doesn't currently contain the technical language attributed to it. IK is
  real but happens offline, at design time, not on the running robot.

## Confidence adjustments

- **Brief §2A (SO-ARM100 cost/community):** cost confidence down sharply —
  treat $200-230 as the realistic single-arm figure, not $115. Calibration
  friction should be added as a caveat. Community-size confidence stays
  unchanged (neither raised nor lowered — genuinely unverifiable).
- **Brief §2B (LeKiwi cost/BOM):** buildability confidence up (independent
  builder corroboration is new and strong). Specific $660 figure confidence
  down — treat as an unreconciled upper-bound estimate against a lower
  $482-499 reference BOM, and note the two "independent" aggregator sources'
  actual independence from each other/from HF is still unverified.
- **Brief Risks (Ch.8 dynamics gap):** confidence up — now backed by primary
  hardware-doc and firmware evidence rather than resting on editorial
  judgment alone.
- **Brief §2D (Bittle IK/chapter mapping to Ch.6):** confidence down — the
  brief's framing should be revised from "genuinely exercises... not just
  pre-baked motions" to "IK is used at design time to author gait tables;
  on-device execution is table playback." The Ch.6 mapping for Bittle is
  weaker than stated (arguably closer to Ch.9-style trajectory playback than
  live Ch.6 inverse-kinematics solving).
- **Brief §2D (Bittle currency):** confidence down modestly — "actively
  sold" needs a lineage/product-specific qualifier (the 2020-funded hardware
  is discontinued; a successor is current).
- **Brief §2A-D (blanket feasibility):** confidence down modestly on tone —
  buildability itself is intact, but the brief's implicit "straightforward
  weekend build" undertone is not well-supported; real skill/tool/cost
  friction is documented by independent sources across three of the four
  candidates.

## Unresolved

- **"Thousands of builders" for SO-ARM100** — no independent source confirms
  or refutes this; it traces to a single Hackster.io mention. Neither side
  produced evidence either way.
- **LeKiwi's $660 vs. $482-499 reconciliation** — plausible that print cost,
  shipping, or battery/controller extras close the gap, but this was not
  confirmed either way this round.
- **Independence of robotsthatexist.com and robotics.growbotics.ai** as
  verifiers rather than aggregators of a single upstream BOM — could not be
  resolved due to a tooling limitation (JS-rendered pages), not a finding of
  fact. This should be treated as an open sourcing caveat on both the
  SO-ARM100 and LeKiwi "independently documented" claims, not a confirmed
  problem.

## Note on source independence across the two sides

The brief's Section 2 sourcing leans heavily on vendor and creator-adjacent
channels (Seeed Studio, Hugging Face docs, Kickstarter, Petoi's own product
page) plus press coverage that in several cases (Hackster.io on the
Hugging-Face-backed SO-101) is itself close to the same ecosystem. The
counter-evidence round's strongest findings all come from sources with no
commercial or authorship stake in the specific project being challenged —
GitHub issue trackers, direct firmware source inspection, and independent
reviews (Foxglove, The Gadgeteer, Tom's Hardware) — which is exactly the
kind of genuine independence the counter-evidence plan asked for. Where the
counter round itself leaned on non-independent or unverifiable sources (the
cross-vendor cost aggregation, described as "not a single citable page"),
that is flagged above as unresolved rather than treated as confirmed.

## Bottom line

Of the six target claims: three hold essentially as stated (dynamics gap,
LeKiwi buildability, Bittle-not-dead), two do not hold as stated (SO-ARM100's
headline cost figure, Bittle's "genuine on-device IK" framing) and should be
corrected in any downstream recommendation, and one (blanket feasibility)
holds on substance but needs its tone tempered. No claim on either side was
found to be sourced from a single self-referential origin masquerading as
independent corroboration, though the independence of two LeKiwi-cost
aggregator sites remains an open question rather than a resolved one.

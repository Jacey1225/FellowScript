# Diff Evaluation: Modern Robotics Textbook — Chapter-Mapped Project Suggestions

Evaluates `critique.md`'s per-claim verdicts against the full original brief
(`brief.md` + `sources.json`) and the counter side (`counter-claims.json`),
section by section, following `brief.md`'s own structure. No new evidence is
introduced here — this is a weighing of material already produced by prior
stages.

## Section 1 — Confirmed textbook structure

Out of scope by design (single primary source — the user's own PDF, read
directly — with no meaningful external corroboration target). The
counter-evidence round correctly did not target this section, and nothing
here is contested. **No verdict needed; stands as reported.**

## Section 2A — SO-ARM100/101

**Cost claim (~$115 single arm / ~$230 dual-arm teleop):**
- **Stronger side: counter.** The brief's own cited vendor (Seeed Studio)
  has a second listing pricing the electronics/servo kit alone at $200
  "Without 3D Printed Parts," and independent cross-vendor pricing
  (nanocorp, WowRobo, PartaBot) converges on ~$229.88 for a complete
  single-arm BOM. This is the vendor's own contradictory pricing plus
  multi-vendor convergence — direct and hard to argue around.
- **Disproven / false:** The $115 headline as a "what does a complete arm
  cost" figure is false, not merely outweighed. It described a bare-frame
  component price, not a buildable arm, and the brief presented it without
  that qualifier. The realistic figure is ~$200-230.
- **Unresolved:** "Thousands of builders" — no independent evidence either
  confirms or refutes this; it traces to one Hackster.io mention. Correctly
  carried forward as unresolved rather than forced to a verdict.

**Calibration/build-smoothness undertone:**
- **Stronger side: counter.** Two GitHub issues on the official `lerobot`
  repo (one closed "not planned") document real, unresolved calibration
  failures — primary-source evidence independent of vendor/press framing,
  which the brief's vendor/press-sourced §2A did not surface.
- Not a "disproven" claim per se, since the brief never explicitly asserted
  a smooth build — but it's a real corrective the brief should absorb as a
  caveat.

## Section 2B — LeKiwi mobile manipulator

**Buildability / "documented, replicable BOM":**
- **Stronger side: original, and now stronger than before.** The core claim
  — LeKiwi is a real, buildable platform with a documented BOM — survives
  and is reinforced by a genuinely independent, non-affiliated builder
  account (Foxglove/Aditya Kamath) reporting an out-of-the-box working
  build with accurate odometry. This is the single clearest case this round
  of counter-evidence actively strengthening rather than weakening an
  original claim.

**Specific cost figure (~$660):**
- **Unresolved, not disproven.** The upstream reference BOM linked from
  Hugging Face's own LeKiwi docs (SIGRobotics-UIUC/LeKiwi) totals
  $482-499, excluding 3D-printing cost — meaningfully below the brief's
  $660 with no reconciling explanation available. This is a real gap
  between a well-sourced primary reference BOM and the brief's headline
  number, but since a plausible non-contradictory explanation (print cost,
  shipping, extras) exists and wasn't tested either way, this stays
  unresolved rather than becoming a false claim. Treat $660 as an
  unreconciled upper-bound estimate; the reference BOM is the harder
  number if a single figure is needed downstream.
- **Unresolved:** Whether robotsthatexist.com and robotics.growbotics.ai
  are genuinely independent verifiers of the $660 figure, or both mirror a
  single upstream number, could not be determined (tooling limitation, not
  a finding). This weakens confidence in the brief's "independently
  documented" framing without falsifying it.

## Section 2C — Sawppy rover

No dedicated counter-evidence claim targeted Sawppy individually; it was
folded into the blanket-feasibility claim (see below). The specific claims
in §2C (under-$500 parts cost from the creator's own repo, Hackaday.io
build-log community, JPL-derived rocker-bogie architecture) were not
directly disputed. The one piece of counter-evidence touching Sawppy —
Hackaday.io community reports of M3 heat-set-insert tolerance problems and
real builds commonly exceeding the "<$500" figure once accessories are
added — is genuine independent evidence but attacks the same
degree/tone issue as the blanket-feasibility claim below, not a specific
sourced assertion in §2C. **No individual verdict beyond the
blanket-feasibility treatment; §2C's core claims stand unchallenged.**

## Section 2D — Petoi Bittle

**"Genuinely exercises IK, not pre-baked motions" (chapter mapping to
Ch.6):**
- **Stronger side: counter, decisively.** Direct inspection of
  `InstinctBittle.h` (the actual running firmware) shows gait execution is
  playback of static precomputed joint-angle tables, not live per-step IK
  solving. An independent community tool
  (`ger01d/kinematic-model-opencat`) confirms IK is computed offline at
  design time and baked into firmware. This is primary-source evidence
  (actual code) against a brief claim that, on re-inspection, isn't even
  present in its own cited source (the current OpenCat README contains no
  occurrences of "kinematic" or "IK").
- **False, not merely outweighed:** The specific claim as worded — that
  Bittle "genuinely requires per-leg IK... not just pre-baked motions" on
  the running robot — is false. IK is real but happens offline at design
  time; the shipped robot's on-device behavior is precomputed table
  playback. The brief's Ch.6 chapter-mapping for Bittle should be revised
  to reflect design-time-only IK use (arguably closer to a Ch.9
  trajectory-playback framing than live Ch.6 inverse kinematics).

**Currency ("remains an actively sold, maintained product"):**
- **Mixed — stronger side depends on which claim.** The underlying point
  (Bittle is not a dead/abandoned project) holds and is arguably
  strengthened: an actively developed successor ("Bittle X," ESP32/BiBoard)
  exists, which is stronger evidence of a living ecosystem than a
  merely-still-listed original product. But the narrower claim — that the
  exact product tied to the cited $567,218/2,052-backer 2020 Kickstarter
  numbers remains the actively sold product — is **partially disproven**:
  the current official README states that specific hardware (NyBoard/
  ATmega328P) is now "discontinued but still fully supported." The brief
  should distinguish "the Bittle lineage/brand is alive" (true) from "the
  exact 2020-funded product is still the current offering" (false).

## Risks section — Ch.8 (Dynamics) structural gap

- **Stronger side: original, strengthened.** The brief flagged this itself
  as an unsourced editorial judgment call. The counter-evidence round found
  no credible contradiction and instead produced primary evidence
  supporting it: Feetech servos technically expose current-based
  torque-sensing capability, but no documented default tutorial path for
  any of the four candidates uses it, and direct firmware inspection
  confirms OpenCat runs on precomputed angle tables with no runtime
  dynamics computation. This is the one case where a "nothing found to
  contradict" result functions as genuine corroboration rather than a gap,
  because the counter-evidence agent actively searched for a contradiction
  and came back with supporting primary evidence instead. Confidence should
  move from "editorial judgment" to "evidence-backed finding."

## Blanket hobbyist-feasibility framing (implicit across §2A-D)

- **Core claim — stronger side: original, holds.** None of the
  counter-evidence found for any candidate rises to "not actually
  buildable" — buildability itself survives across all three
  physically-inspected candidates (SO-ARM100, Sawppy, Bittle).
- **Tone/degree — stronger side: counter.** Independent, non-vendor sources
  (LeRobot GitHub issues, Hackaday.io Sawppy build logs, The Gadgeteer and
  Tom's Hardware reviews) consistently document real friction — calibration
  instability, heat-set insert tolerance problems, inadequate included
  tools, cost overruns beyond headline figures, and (Tom's Hardware) an
  explicitly conditional value judgment ("probably not worth the
  investment" for a user not after a coding platform). This is a legitimate
  evidence-backed correction to the brief's largely vendor/press-sourced,
  implicitly turnkey framing — not a reversal of buildability itself.
  **Not disproven, but the brief's tone needs tempering.**

## Section 3 — Vibe/lifestyle fit

Explicitly flagged by the brief itself as an unsourced judgment call, not a
sourced claim, and the counter-evidence plan correctly did not target it
(no meaningful external sources exist for this category, per the gathering
stage). **Out of scope for this diff evaluation; untouched by either side.**

---

## Overall picture

The brief held up well on its structural and buildability claims but poorly
on two specific, checkable factual assertions. Of the claims actually put
to the test:

- **Original stronger (and in two cases strengthened, not just surviving):**
  LeKiwi buildability, the Ch.8 dynamics-gap risk note, Bittle's
  "not a dead project" core/lineage claim, and the core buildability half of
  the blanket-feasibility framing.
- **Counter stronger:** SO-ARM100's headline single-arm cost, and Bittle's
  "genuine on-device IK, not pre-baked motions" chapter-mapping claim.
- **Disproven/false as literally stated:** the SO-ARM100 $115 single-arm
  figure (it's a bare-frame component price, not a build cost — real figure
  ~$200-230), Bittle's on-device-IK framing (real IK use is offline/
  design-time, not runtime), and the narrower claim that the exact
  2020-Kickstarter Bittle hardware remains the actively sold product
  (discontinued, though the lineage lives on via Bittle X).
- **Unresolved, correctly not forced to a verdict:** SO-ARM100's "thousands
  of builders," the LeKiwi $660 headline figure against the lower
  $482-499 reference BOM, and the genuine independence of the
  robotsthatexist.com/growbotics.ai aggregator sources.

No claim on either side traced back to a single self-referential source
masquerading as independent corroboration — the strongest counter-evidence
throughout came from sources with no commercial stake in the project being
challenged (GitHub issue trackers, direct firmware inspection, independent
reviews), which is exactly the kind of evidence that should carry the most
weight in a diff like this. The practical upshot for any downstream
recommendation: keep SO-ARM100, LeKiwi, Sawppy, and Bittle as buildable
hobbyist candidates with intact chapter mappings for Ch.2-5, 9-13, but
(1) correct SO-ARM100's cost to ~$200-230 and note calibration friction,
(2) treat LeKiwi's $660 as an upper-bound estimate rather than a confirmed
figure, (3) soften Bittle's Ch.6 mapping to reflect design-time (not
runtime) IK use, (4) qualify Bittle's currency claim to the brand/lineage
rather than the exact 2020 product, and (5) temper the overall "turnkey
weekend build" undertone given consistent independent friction reports
across three of the four candidates.

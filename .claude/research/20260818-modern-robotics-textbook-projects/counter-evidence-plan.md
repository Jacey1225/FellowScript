# Counter-Evidence Plan: Modern Robotics Textbook — Chapter-Mapped Project Suggestions

## Scope note

The brief's textbook-structure claims (Section 1) are drawn directly from the
user's own PDF via `pdftotext` and are explicitly marked in the brief's Risks
as not needing external corroboration ("what this specific PDF's TOC says").
Counter-evidence effort is not directed at that section — there is no
meaningful "opposing source" for a primary document's own table of contents,
and attempting to manufacture one would waste the round. All targets below
come from Section 2 (candidate projects) and the Risks section, where claims
about real-world buildability, community size, cost, and pedagogical fit are
load-bearing for which project(s) get recommended.

## Target claims

1. **"SO-ARM100 has a large, active builder community ('thousands of
   builders')... Approximate cost: single arm ~$115, dual-arm teleop setup
   ~$230"** (brief §2A, sourced to Hackster.io / Seeed Studio).

2. **"LeKiwi is confirmed as an actually-built hobbyist platform, cost approx.
   $660 for the complete mobile-manipulator system"** and **"LeKiwi has a
   documented, replicable bill of materials and assembly process"** (brief
   §2B, sourced to robotsthatexist.com and robotics.growbotics.ai).

3. **"All four projects use position-controlled hobby servos rather than
   torque/force-controlled actuators, so none of them genuinely requires
   working through the book's Lagrangian/Newton-Euler dynamics formalism...
   This is a structural gap across the entire candidate set"** (brief Risks,
   stated as an unsourced editorial judgment call by the brief itself, not
   traced to any of the 17 sourced citations).

4. **"Bittle runs on OpenCat, an open-source... framework implementing
   inverse-kinematics-driven gait generation, servo control, and IMU
   integration — i.e. it genuinely exercises kinematics/control concepts,
   not just pre-baked motions"** (brief §2D, sourced solely to the OpenCat
   GitHub README — the creator's own self-description of its own software).

5. **"Bittle remains an actively sold, maintained product as of research
   date, not a dead Kickstarter-only project"** paired with the brief's own
   flagged risk that the underlying popularity numbers ($567,218/2,052
   backers) are from the 2020 campaign (brief §2D + Risks).

6. **Blanket hobbyist-feasibility framing** — that all four candidates are
   "buildable by an individual hobbyist" at the stated cost/tool level
   (implicit across §2A–D and the research plan's success criteria), which
   the brief supports only with vendor/creator/press sources, none of which
   have an incentive to surface build failures, hidden costs, or skill
   barriers.

## Search angles

**1. SO-ARM100 cost/community claims**
- Genuine counter-evidence: independent builder accounts (Reddit
  r/robotics, r/homeautomation, r/3Dprinting, maker forums, YouTube build
  logs from non-affiliated creators) reporting total realistic cost
  (servos, controller board, cables, print failures/re-prints are typically
  *not* included in a "$115 frame kit" price) and reporting real friction —
  calibration difficulty, servo burnout, backorder/supply issues, or
  community-support quality.
- Where to look: GitHub Issues/Discussions on TheRobotStudio/SO-ARM100 repo
  (bug reports, unresolved complaints indicate more friction than the vendor
  narrative suggests), independent YouTube reviews, Reddit search, Hacker
  News threads on the SO-101 launch (HN commenters are reliably skeptical of
  vendor claims).
- Not counter-evidence: another Seeed Studio or Hugging Face page repeating
  the same $115/"thousands of builders" figure — that's the same claim
  restated, not a challenge to it.

**2. LeKiwi cost/BOM claims**
- Genuine counter-evidence: check whether robotsthatexist.com and
  robotics.growbotics.ai are independent verifiers or aggregator/SEO sites
  that simply mirror the official Hugging Face BOM without their own
  build/verification — if so, the brief's "independently documented"
  framing is weaker than stated. Look for their About/methodology pages,
  and cross-check whether their BOM numbers actually differ at all from
  HF's own docs (identical figures across all four "corroborating" sources
  would suggest a single upstream source echoed multiple times, not
  independent corroboration).
- Where to look: independent build-log posts (personal blogs, Hackaday.io,
  Discord/forum screenshots referenced in blog posts) from someone who
  built a LeKiwi and reported actual total spend, including shipping,
  battery, and controller costs not in a bare BOM.

**3. Dynamics/Ch.8 "structural gap" claim**
- Genuine counter-evidence: search for whether the SO-ARM100/LeRobot,
  Bittle/OpenCat, or Sawppy communities have documented any
  torque-sensing, current-based force feedback, or compliant-control
  extensions (e.g. Feetech/Dynamixel servos with current-limit telemetry
  used for basic force estimation, or LeRobot's imitation-learning stack
  using force/torque signals from teleoperation) that would mean Ch.8
  concepts are exercised more than the brief's blanket dismissal implies.
- Where to look: LeRobot/Hugging Face technical docs on servo control
  modes, Dynamixel/Feetech datasheets and community discussion of
  current-based torque estimation, OpenCat firmware source for any
  dynamics/force terms (vs. pure angle-lookup gait tables).
- This is the one claim where the "counter-evidence" would actually
  strengthen the brief's usefulness (by identifying a real hands-on angle
  on Ch.8) rather than undermine a candidate — flag explicitly if nothing
  turns up, since that would corroborate the brief's existing risk note
  rather than contradict it.

**4. Bittle/OpenCat "genuine IK" claim**
- Genuine counter-evidence: independent technical teardown or critical
  discussion (not Petoi/OpenCat's own docs) of whether OpenCat's gait
  engine is truly solving inverse kinematics per step, versus using
  precomputed/interpolated gait tables with only nominal per-leg geometry
  math — this distinction matters for how much genuine Ch.6 exercise the
  build provides. Look at the actual OpenCat firmware source (not just the
  README) for the gait-generation code path, and any independent
  robotics-hobbyist commentary (Hackaday coverage of Bittle/Nybble,
  academic or hobbyist teardown blog posts) that characterizes the gait
  method critically.
- Where to look: OpenCat GitHub source code itself (as primary evidence,
  distinct from the README's self-description), Hackaday.io/Hackaday.com
  Bittle/Nybble coverage, independent STEM-education reviews of Bittle that
  discuss what students actually learn from it.

**5. Bittle currency/maintenance claim**
- Genuine counter-evidence: signs of declining support — sparse recent
  GitHub commit activity/issue responses, discontinued SKUs, negative
  recent (not 2020-era) reviews, forum posts about abandoned
  support/warranty problems.
- Where to look: GitHub commit history/issue response times on
  PetoiCamp/OpenCat, Petoi's own forum or Discord activity levels, recent
  (last 12–24 months) independent reviews or Reddit threads mentioning
  Bittle, rather than only the original 2020 Kickstarter/press coverage.

**6. General hobbyist-feasibility claim (all candidates)**
- Genuine counter-evidence: build-failure accounts, "harder than it looks"
  write-ups, skill/tool prerequisites understated by vendor marketing (e.g.
  needing a working 3D printer with tight tolerances, soldering, servo
  calibration, or debugging firmware) for any of the four candidates.
- Where to look: same independent-forum/YouTube/Reddit angle as above, per
  candidate. Sawppy is lower priority here since its primary corroboration
  (Hackaday.io build logs) is already genuinely independent multi-builder
  evidence rather than vendor/press framing.

## Constraints

Inherited from `research-plan.md`:
- No date constraint on the textbook itself; for project/community sources,
  prefer still-maintained/current evidence over dead links — this applies
  doubly to counter-evidence, since a critique built on stale complaints
  about a since-fixed problem is not a fair challenge.
- Source types: maker/hobbyist write-ups, open-source repos, kit/product
  pages, and community build logs/forums are all acceptable; academic
  papers are supporting evidence only, not load-bearing alone.
- Do not exceed the "suggestion-stage" scope — this round is about testing
  confidence in specific claims, not producing a new build guide or
  re-surveying the entire hobbyist-robotics landscape.

Specific to counter-evidence:
- **Avoid circular corroboration.** Do not count another Hugging Face
  ecosystem page (Seeed Studio, HF docs, HF-affiliated press) as
  counter-evidence to a Hugging Face ecosystem claim — that is the same
  source network restating itself, not an independent check. The same
  applies to Petoi/OpenCat's own channels for Bittle claims.
  Genuine counter-evidence must come from a source with no commercial or
  authorship stake in the specific project being challenged.
  aggregator sites of unclear independent-verification methodology
  (robotsthatexist.com, robotics.growbotics.ai) should be treated with
  caution as *counter*-evidence sources too — check what they actually do
  before leaning on them either way.
- **Distinguish "no counter-evidence found" from "claim confirmed."**
  Several of these targets (especially #3 and #5) may turn up little
  genuine opposing material because the candidates are, in fact, small
  and relatively uncontroversial hobbyist projects without much critical
  press. That absence should be reported honestly as a limits-of-search
  finding, not stretched into weak material (e.g. a single random negative
  Amazon-style review) just to manufacture a counterpoint.
- Do not re-litigate the textbook chapter list (see Scope note above).

## Success criteria

A good-faith counter-evidence effort for this topic:
- For at least the cost/community-size claims (#1, #2) and the
  self-sourced OpenCat IK claim (#4), makes a genuine attempt to find
  independent, non-vendor-affiliated voices — even if the outcome is "no
  meaningful independent criticism found," that attempt must actually have
  been made and reported, not skipped.
- For the dynamics/Ch.8 claim (#3), resolves it one way or the other with
  primary technical evidence (servo/firmware capabilities), since this is
  a claim the brief itself made without a specific citation.
- Reports honestly where a candidate's real-world-buildability claim holds
  up well under scrutiny (this is a legitimate and expected outcome for at
  least some of these targets, not a failure of the counter-evidence
  round) versus where a genuine, specific weakness (hidden cost, overstated
  community size, self-serving technical framing) is found.
- Does not manufacture opposition where none credibly exists, and does not
  treat "the vendor says X" repeated across two of its own channels as if
  it were two independent confirmations — that distinction should be
  explicit in `counter-claims.json`/`critique.md` downstream.

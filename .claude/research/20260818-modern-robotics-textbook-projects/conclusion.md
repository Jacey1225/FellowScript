# Conclusion: Modern Robotics Textbook — Chapter-Mapped Project Suggestions

## Bottom line

The PDF's real structure is confirmed directly from the file, not assumed: 13 chapters running Configuration Space through Wheeled Mobile Robots, plus four appendices, in the "updated first edition" (Dec 2019) printing. Four hobbyist candidates hold up as genuinely buildable and chapter-mappable: SO-ARM100/101, LeKiwi, Sawppy, and Petoi Bittle. None spans all 13 chapters alone; a two-project sequence (arm-family plus a wheeled or legged platform) is needed for near-full coverage, and Chapter 7 (closed chains) stays unexercised by any of them.

Two of the brief's specific numbers were checked and came back wrong. SO-ARM100's advertised ~$115 single-arm cost is a bare-frame component price, not a build cost — a real single arm runs ~$200-230. Bittle's chapter-mapping claim that it "genuinely requires per-leg IK, not pre-baked motions" is false as stated: the shipped firmware runs precomputed joint-angle tables: IK was solved once, offline, at design time, not live on the robot. Everything else — LeKiwi's buildability, the Ch.8 dynamics-gap risk note, Bittle's status as a live (if hardware-revised) product line, and the underlying buildability of all four candidates — held up or got stronger under scrutiny. The one consistent correction across the board: treat all four builds as real but rougher than the vendor/press framing suggests, not turnkey weekend projects.

## Per-section findings

**Textbook structure (research step 1).** Confirmed directly from `/Users/jaceysimpson/Downloads/MR-v2.pdf` via `pdftotext`, not the public syllabus. Single-source by design — it's the user's own file — and nothing in critique or counter-evidence touched it. Stands as reported: 13 chapters, four appendices, no fallback needed.

**Prerequisite ordering (research step 2).** The brief pulled real sequencing from the authors' own preface rather than assuming chapter-number order: Chapters 2-6 as minimum essentials, Chapter 8 as a prerequisite for the standard treatment of 9 and 11, with named course paths (kinematics-only, planning-focused, manipulation-focused, control-focused) showing how the material actually gets combined. No counter-evidence targeted this, and nothing in the evaluation contradicts it. Held.

**Chapter topics (research step 3).** Covered as part of the confirmed structure above and used consistently as the basis for every project-to-chapter mapping. Unchallenged.

**Project survey and feasibility mapping (research steps 4-5).**

SO-ARM100/101: real, buildable, actively maintained, with genuine chapter coverage from configuration/pose through inverse kinematics, trajectory generation, control, and grasping. The headline $115 cost is disproven as a full-build figure — the vendor's own second listing and independent cross-vendor pricing converge on ~$200-230. Two open GitHub issues on the official `lerobot` repo, one closed "not planned," document real calibration failures the brief's vendor/press-sourced description missed. Buildability itself is not in question; the cost figure and the build-smoothness undertone both needed correction.

LeKiwi: the strongest result in this round. An independent, non-affiliated builder account (Foxglove/Aditya Kamath) reported an out-of-the-box working build with accurate odometry, reinforcing rather than merely surviving the brief's buildability claim. The $660 headline cost is unresolved, not disproven — the upstream Hugging Face-linked reference BOM totals $482-499 excluding 3D-printing cost, a real gap with no reconciling explanation surfaced. Treat $660 as an unreconciled upper bound; $482-499 is the harder number if one figure is needed downstream. Whether the two aggregator sources citing $660 are genuinely independent of each other could not be determined.

Sawppy: no counter-evidence targeted its specific claims (sub-$500 parts cost, Hackaday.io build-log community, JPL-derived architecture) directly. The one relevant independent evidence — Hackaday.io reports of M3 heat-set-insert tolerance problems and real builds commonly exceeding $500 once accessories are added — is genuine friction but folds into the general tone correction below rather than disproving anything specific. Core claims stand unchallenged.

Petoi Bittle: mixed, and the most consequential correction in the set. Direct inspection of the actual firmware (`InstinctBittle.h`) and an independent community tool (`ger01d/kinematic-model-opencat`) show gait execution is playback of precomputed joint-angle tables, not live per-step inverse kinematics — the brief's Ch.6 chapter-mapping claim is false as worded and should be revised toward a Ch.9 (trajectory-playback) framing instead. Separately, "remains an actively sold, maintained product" is half right: the Bittle lineage is alive and arguably stronger than reported (an actively developed successor, Bittle X, exists), but the specific hardware tied to the cited 2020 Kickstarter numbers (NyBoard/ATmega328P) is now discontinued, per the project's own current README. The brief conflated "the brand is alive" with "the exact funded product is still current" — only the first is true.

**Ch.8 dynamics-gap risk note.** Strengthened, not just surviving. The brief flagged this itself as an editorial judgment call with no source behind it. The counter-evidence round actively searched for a contradiction and instead found supporting primary evidence: Feetech servos expose torque-sensing capability in principle, but no documented tutorial path for any of the four candidates uses it, and firmware inspection confirms no runtime dynamics computation anywhere in the set. This moved from unsourced judgment to evidence-backed finding.

**Chapter 7 (closed chains) gap.** No candidate's sourced material confirms a closed-chain leg or mechanism. Bittle's legs remain the closest candidate but this was never resolved either way — it stays an open gap in coverage, not a claim that was tested and failed.

**Blanket hobbyist-feasibility framing.** Buildability itself holds across all three physically-inspected candidates (SO-ARM100, Sawppy, Bittle) — nothing in the counter-evidence round rises to "not actually buildable." But the tone consistently needed correction: independent, non-vendor sources (LeRobot GitHub issues, Hackaday.io build logs, The Gadgeteer and Tom's Hardware reviews, one of which explicitly judges Bittle "probably not worth the investment" for a non-coding-focused buyer) document real friction the brief's largely vendor/press-sourced description didn't surface. Not a reversal — a tempering.

**Vibe/lifestyle fit (research step 6).** Explicitly an unsourced judgment call from the start — the gathering stage found no meaningful external sources for interest-adjacency claims, and the counter-evidence round correctly left this section untouched. It was never a factual claim to verify, so there's nothing to uphold or overturn here; it remains exactly what the brief said it was: the critique/evaluation stages' own qualitative read, not sourced evidence.

## Confidence

High confidence in the textbook structure and the overall shape of the recommendation set (four real, buildable candidates, two specific number corrections, one chapter-mapping correction). This rests on primary-source evidence throughout — direct PDF extraction, direct firmware inspection, vendor's own contradictory pricing, official GitHub issue trackers — rather than secondhand claims.

Lower confidence in three specific numbers/claims that stayed unresolved: SO-ARM100's "thousands of builders" (traces to one Hackster.io mention, no independent count), LeKiwi's exact all-in cost (somewhere between the $482-499 reference BOM and the $660 headline, depending on unverified extras), and whether the two LeKiwi cost-aggregator sources are truly independent of each other or share a common upstream origin.

What would overturn a finding: a documented per-step IK computation in a shipped Bittle firmware build (not a design-time tool) would reverse the on-device-IK finding. A reconciling breakdown showing what the extra ~$160-180 in LeKiwi's $660 figure actually covers would resolve that gap in the brief's favor. Evidence that robotsthatexist.com and growbotics.ai independently priced LeKiwi rather than citing a shared source would strengthen the $660 figure; evidence they share an origin would weaken it further.

## Open questions

Carried forward from the brief, unresolved by this research and not resolvable by more sourcing — these are downstream framing/preference decisions:

Should the final recommendation present a single project or an explicit sequence (SO-ARM100 to LeKiwi, or SO-ARM100 plus Sawppy) to reach fuller chapter coverage, since no single candidate spans all 13 chapters?

Given the shared Ch.8 weakness across all four candidates, is a hobbyist-feasible modification worth proposing (e.g., torque-sensing servos, a supplementary simulation-only dynamics exercise), or should Ch.8 simply be framed as a "read but not hands-on-built" chapter?

Is Chapter 7 (closed chains) worth deliberately targeting with a fifth candidate, or is leaving it unexercised acceptable within the plan's 2-4-candidate scope?

Which candidate's vibe framing (AI/teleoperation-adjacent arm, sci-fi rover, anime/cyberware-adjacent robotic companion) best matches the user's actual stated interests — this was never a sourceable question and stays a judgment call for the user.

Should LeKiwi be presented as a standalone fourth option or as an extension phase of the SO-ARM100 build? The sourced material supports either framing.

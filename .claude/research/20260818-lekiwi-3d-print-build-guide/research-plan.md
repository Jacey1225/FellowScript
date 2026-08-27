# Research Plan: LeKiwi From-Scratch Build Walkthrough (3D-Printed Parts, Chapter-Mapped)

## Topic / Claim

Produce a from-scratch build walkthrough for the LeKiwi robot (SO-ARM101-family robotic arm mounted on a holonomic 3-wheel "Kiwi drive" mobile base) for a builder who will 3D-print all body/frame parts themselves rather than buying a pre-made frame kit. The walkthrough must be organized into build phases, and each phase must be explicitly tied to the specific chapter of *Modern Robotics: Mechanics, Planning, and Control* (Lynch & Park) whose concepts that phase puts into practice, and why.

This is a distinct, standalone research task with its own directory and its own full 8-step pipeline run. It builds on, and should cite forward from, prior research at `/Users/jaceysimpson/Vscode/FellowScript/.claude/research/20260818-modern-robotics-textbook-projects/` (specifically `brief.md`, `critique.md`, and `conclusion.md`), which already established LeKiwi as the strongest of four hobbyist candidates, confirmed the textbook's 13-chapter structure directly from the user's own PDF, and produced a first-pass chapter mapping for LeKiwi. That prior research is background material to build on, not something to re-derive from scratch.

## Scope

**In bounds:**
- What must be 3D-printed for LeKiwi: which parts/subassemblies (arm links, base/chassis, wheel mounts, any brackets/mounts), where the STL/print files are sourced from (official LeRobot/HuggingFace repo, SO-ARM101 upstream repo, any community remix used specifically for LeKiwi's base), printer requirements if documented (bed size, material/filament type, infill/print-time estimates, tolerances/post-processing notes such as heat-set inserts).
- What must be bought rather than printed: servos (make/model/count), control boards/electronics, motors for the wheeled base, fasteners, bearings, wiring/connectors, and any other non-printed BOM items — building on and citing forward from the prior research's BOM/cost findings ($482-660 range, componentry already identified in `brief.md`/`critique.md`) rather than re-researching cost from zero.
- Step-by-step assembly grouped into discrete build phases (e.g., arm sub-assembly, base sub-assembly, wiring/electronics integration, calibration, software/firmware setup, final integration/test).
- For each phase, an explicit mapping to one (or more) Modern Robotics chapters and a stated reason for the mapping (e.g., "assembling the arm's revolute joints — Chapter 3, rigid-body motions"; "programming the wheeled base's kinematics — Chapter 13, wheeled mobile robots"), building on and refining the chapter mapping already sketched for LeKiwi in the prior research's brief (Ch.2-3, 4, 5, 6, 9, 11, 12, 13) rather than starting the mapping over.
- Software/firmware setup as its own mapped phase(s): calibration procedure, and the LeRobot/HuggingFace software stack referenced in the prior research (installation, configuration, teleoperation/control setup) — explicitly in scope, not to be waved off as "not physical assembly."
- Known friction points/build risks specific to a from-scratch 3D-printed build (e.g., print tolerances, calibration failures already documented in the prior research's critique/conclusion for the SO-ARM family, base-specific assembly issues) should be surfaced where sourced material supports it.

**Out of bounds:**
- Re-litigating whether LeKiwi is the "best" candidate among the four surveyed previously (SO-ARM100 solo, Sawppy, Bittle) — that comparative judgment was already made in the prior research and is not being revisited here.
- Re-deriving the textbook's chapter structure or general prerequisite ordering from the PDF — treat the prior research's confirmed 13-chapter structure and prerequisite notes as settled background, citable directly.
- Full independent re-verification of the LeKiwi cost figures ($482-499 reference BOM vs. $660 headline) — the prior research left this as an unreconciled range; this task may cite that range but does not need to re-resolve it unless new print-cost-specific evidence changes the picture (e.g., filament cost estimates for printed parts, which the prior research did not price out since it assumed a pre-made frame purchase in its cost baseline).
- Non-LeKiwi builds. This task is LeKiwi-specific.
- General 3D-printer buying advice or printer setup/calibration unrelated to LeKiwi's specific parts (assume the builder already owns a working 3D printer; only surface LeKiwi-specific print requirements such as bed size minimums, material recommendations, and tolerances).

## Constraints

- **Recency**: LeKiwi and the LeRobot software stack are actively developed; prefer current documentation/repo state over older cached descriptions, and flag anything print-file or BOM related that may have changed since the prior research round (dated 2026-08-18).
- **Source types required**: Primary sources for print files and assembly steps — the official Hugging Face LeRobot LeKiwi documentation, the SO-ARM101/LeKiwi GitHub repositories (for STL/print files and BOM), vendor build guides (e.g., Seeed Studio's LeRobot LeKiwi wiki, already identified in prior research), and independent builder accounts (e.g., the Foxglove/Aditya Kamath build already surfaced in prior research, or new independent builder logs) for real-world print/assembly friction points. Vendor/press-only sourcing should be treated with the same skepticism the prior critique applied — corroborate print/assembly claims with at least one non-vendor source where possible.
- **Depth expected**: Enough for a builder to actually follow — concrete phase-by-phase steps, named parts, named files/repos, not a high-level overview. Chapter-mapping reasoning for each phase should be substantive (a sentence or two of "why this phase exercises this chapter's concepts"), not just a label.
- **Must build on, not duplicate, prior research**: Cite forward from `20260818-modern-robotics-textbook-projects/brief.md`, `critique.md`, and `conclusion.md` for already-established facts (textbook structure, LeKiwi buildability confirmation, known BOM/cost range, known calibration friction points). Only gather new sourced material for what that prior research did not cover: the print-specific angle (STL files, printer requirements, print-vs-buy split) and the full phase-by-phase assembly/software walkthrough structure.

## Research steps

1. Confirm where LeKiwi's official 3D-printable part files live (repo/path), what parts they cover (arm links vs. base/chassis vs. both), and any printer requirements documented alongside them (bed size, material, print time, infill, tolerances, post-processing).
2. Establish the full print-vs-buy split: enumerate printed parts vs. purchased components (servos, control board(s), base drive motors/wheels, fasteners, electronics, cabling), citing forward from the prior research's BOM findings where already covered and filling gaps specific to the printed-frame path.
3. Identify or construct a phased assembly sequence (e.g., arm sub-assembly, base sub-assembly, electronics/wiring integration, calibration, software/firmware setup, final integration and test) from official documentation and independent builder accounts.
4. For each phase, determine which Modern Robotics chapter(s) it exercises and why, building on and refining the mapping already sketched in the prior research's brief (Ch.2-3 configuration/pose, Ch.4 forward kinematics, Ch.5 velocity kinematics/Jacobian, Ch.6 inverse kinematics, Ch.9 trajectory generation, Ch.11 robot control, Ch.12 grasping/manipulation, Ch.13 wheeled mobile robots).
5. Cover the software/firmware setup phase(s) in the same depth as physical assembly: calibration procedure specifics, and LeRobot/HuggingFace software stack installation/configuration/teleoperation setup, mapped to its relevant chapter(s) (e.g., Ch.11 control, Ch.13 wheeled kinematics for odometry/drive control).
6. Surface known friction points or risks specific to a from-scratch, 3D-printed LeKiwi build (print tolerance issues, calibration failures, base-specific assembly quirks) where independent/non-vendor sources support them, distinguishing what's newly found here from what the prior research already documented for the SO-ARM family generally.

## User-provided sources

(None provided verbatim in the request. The request references, by description, the prior completed research task at `.claude/research/20260818-modern-robotics-textbook-projects/` in the FellowScript project — specifically its `brief.md`, `critique.md`, and `conclusion.md` — as background/starting material to build on and cite forward from, not to re-derive. The request also references the user's own copy of the Modern Robotics textbook at `/Users/jaceysimpson/Downloads/MR-v2.pdf`, already confirmed as a 13-chapter, four-appendix "updated first edition" (Dec 2019) printing by the prior research.)

## Success criteria

Sourcing stage has produced enough to work with when it has, for LeKiwi specifically:
- A confirmed, cited location for the official 3D-printable part files, with any documented printer requirements (bed size, material, print time, tolerances).
- A clear, cited print-vs-buy component split covering both the arm and the wheeled base.
- A phase-by-phase assembly sequence (including software/firmware setup as its own phase(s)) grounded in at least one primary source (official docs/repo) and, where available, at least one independent builder account.
- Every phase carries an explicit, substantive chapter mapping back to Modern Robotics, consistent with and building on the mapping already sketched in the prior research rather than contradicting it without reason.
- Prior research's already-established facts (textbook structure, LeKiwi buildability, BOM/cost range, known friction points) are cited forward, not re-sourced from scratch.

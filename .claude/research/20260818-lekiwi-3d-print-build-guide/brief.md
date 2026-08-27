# Research Brief: LeKiwi From-Scratch Build Walkthrough (3D-Printed Parts, Chapter-Mapped)

## Summary

This brief covers a from-scratch, 3D-printed LeKiwi build, organized around the six research steps in `research-plan.md`. It builds on and cites forward from the prior research at `.claude/research/20260818-modern-robotics-textbook-projects/` (`brief.md`, `critique.md`, `conclusion.md`) rather than re-deriving settled facts.

### 1. Official 3D-printable part files, location, and printer requirements

LeKiwi's base/chassis print files and printer requirements live in the official `SIGRobotics-UIUC/LeKiwi` GitHub repo, in `3DPrinting.md` [github.com/SIGRobotics-UIUC/LeKiwi/blob/main/3DPrinting.md]. That file specifies: PLA filament, 15% infill, 0.2mm layer height, 150mm/s print speed, tested on a Bambu Lab P1S with auto-arrange/auto-support, ~34 hours total print time across 11+ parts, and supports needed specifically for the servo wheel hub (no other part needs supports). No bed-size minimum or heat-set-insert guidance is given for the base parts specifically. The base part list covers: base plate (printed in 2 layers/pieces), 3x drive motor mounts, 3x servo wheel hubs, servo controller mount, battery mount, Raspberry Pi case (top/bottom), camera mounts, and an optional modified follower-arm-base shim. The independent Seeed Studio wiki corroborates these print settings from its own build, with one minor wording discrepancy: it recommends PLA+ specifically, where the official doc says plain PLA — a small inconsistency, not a substantive conflict [wiki.seeedstudio.com/lerobot_lekiwi/]. It also independently confirms supports are needed only on the wheel hub.

The arm (SO-101) is a separate print job from a separate upstream repo, `TheRobotStudio/SO-ARM100`, under `STL/SO101` [github.com/TheRobotStudio/SO-ARM100/tree/main/STL/SO101]. That repo documents two bed-size variants (Ender-compatible 220x220mm, Prusa/UP-compatible 205x250mm), PLA+ at 0.4mm nozzle/0.2mm layer height (or an alternative 0.6mm nozzle/0.4mm layer height), 15% infill, supports everywhere except shallow slopes and horizontal-axis screw holes, and — notably — no heat-set inserts (screws thread directly into printed plastic). It also recommends printing and test-fitting a calibration gauge part (against a 4x2 Lego block or an actual STS3215 servo) before committing to a full arm print run, to catch printer dimensional-accuracy issues early. The LeKiwi repo's README confirms Fusion 360 CAD source files and an exported URDF are also available alongside the STLs (useful for simulation/verification before printing), and that base plates use a standardized 3.5mm-hole/20mm-spacing mounting pattern across parts [github.com/SIGRobotics-UIUC/LeKiwi/blob/main/README.md].

### 2. Print-vs-buy split and BOM

The default (Feetech-servo) LeKiwi build's itemized BOM lives at `BOM.md` in the official repo [github.com/SIGRobotics-UIUC/LeKiwi/blob/main/BOM.md]. It totals $482 (12V complete variant), $499 (5V complete variant), or $184 (wired-base-only variant), explicitly excluding 3D-printing filament/time cost. This confirms and extends the prior research's $482-499 reference figure by supplying the itemization and the print-cost exclusion caveat, which the prior round did not have. Printed items (chassis, motor mounts, wheel hubs, Pi case, camera mounts, battery mount) are effectively free beyond filament/machine time; purchased items include the servos, Raspberry Pi, cameras, battery, base controller board, and fasteners, costed line by line.

A distinct Dynamixel-servo variant exists at `DynamixelLeKiwi/BOM.md`, totaling $770.47 — notably higher than both the $482-499 Feetech figure and the prior research's $660 aggregator headline figure [github.com/SIGRobotics-UIUC/LeKiwi/blob/main/DynamixelLeKiwi/BOM.md]. Its BOM: 3x DYNAMIXEL XL430-W250-T wheel motors, U2D2 controller hardware, and Koch v1.1 leader/follower teleoperation arms priced separately ($199 leader / $232 follower). This is new evidence suggesting the $660 headline may reflect a different or mixed configuration rather than being directly reconcilable with the $482-499 Feetech figure — it is not a resolution of that gap, consistent with the plan treating full reconciliation as out of bounds.

Independent third-party corroboration of the print-vs-buy split and cost comes from orobot.io, which independently lists roughly 12-15 printed parts (chassis, mounts, hubs, camera holders, compute enclosure) against the same purchased-component set (motors, wheels, controller, Pi, battery, cameras, fasteners), and gives its own cost estimate of $450-550 — a third data point sitting between the $482-499 and $660 figures, again not resolving the gap [orobot.io/o/program/BROKER-2/lekiwi-mobile-base].

### 3. Phased assembly sequence

The official repo's `Assembly.md` gives a concrete, fastener-level 5-phase sequence, estimated at ~2 hours total, with an explicit prerequisite that a pre-built SO-100/SO-101 arm exists before LeKiwi-specific assembly begins [github.com/SIGRobotics-UIUC/LeKiwi/blob/main/Assembly.md]:

1. **Wheel modules** — mount each drive motor to its motor mount, attach the servo horn to the wheel hub, fit the omniwheel to the hub.
2. **Bottom plate / electronics** — install the base controller board and battery/power wiring onto the bottom plate; wiring path differs by power variant (12V vs 5V vs wired-only).
3. **Top plate / Pi / arm mount** — mount the Raspberry Pi in its case and the pre-built SO-101 arm onto the top plate.
4. **Final assembly / cable routing** — join top and bottom plates, route cabling between the base electronics, Pi, and arm.
5. **Camera mounting** — attach workspace and wrist cameras.

The independent Seeed Studio wiki corroborates this sequence at a coarser phase level (motor install → electronics → Pi/arm mount) under its own phase lettering, and adds one critical, non-obvious callout absent from the official doc: wheel drive-motor IDs 7/8/9 must be assigned to specific physical positions (8=rear, 7=left-front, 9=right-front), and mis-assignment is a documented pitfall [wiki.seeedstudio.com/lerobot_lekiwi/]. This is treated as a build-risk item (see Risks) rather than folded silently into the phase description, since it is independent-source-only detail not present in the primary repo doc.

### 4-5. Software/firmware setup phase (in the same depth as physical assembly)

The official Hugging Face LeRobot documentation for LeKiwi is the primary source for this phase [huggingface.co/docs/lerobot/lekiwi, rendered from github.com/huggingface/lerobot/blob/main/docs/source/lekiwi.mdx], authored independently of the SIGRobotics-UIUC hardware repo though part of the same ecosystem:

- **Install**: `pip install -e ".[lekiwi]"`.
- **Port detection**: `lerobot-find-port` to identify the serial ports for the base and arm.
- **Motor setup**: `lerobot-setup-motors` to assign/configure servo IDs.
- **Calibration** (two-step): first the follower base+arm together, then the leader teleop arm separately, using `lerobot-calibrate`. Procedure: move to mid-range, then cycle each joint through its full range of motion — explicitly framed by the docs as enabling policy transfer across physically distinct robot units (i.e., calibration normalizes joint-space differences between individual builds).
- **Host/client teleoperation architecture**: the Raspberry Pi runs a `lekiwi_host` process; a separate laptop/workstation runs the client that connects to it.
- **Keyboard teleoperation**: three named speed modes (fast/medium/slow) with explicit linear (m/s) and rotational (deg/s) values for the holonomic base.
- **Data collection / training**: guidance to record at least 50 episodes (10 per location) for imitation-learning policy training.

Independent corroboration and additional software-side friction points come from the Seeed Studio wiki, which documents several gotchas not spelled out as explicitly in the HF docs: a Linux USB serial-port permissions fix is typically required; `lerobot-find-port` requires physically disconnecting the USB cable during the detection step to work correctly; IP configuration between host and client should be verified by ping before attempting teleoperation; macOS requires granting Input Monitoring permission for keyboard teleop to register; and SSH is not enabled by default on fresh Raspberry Pi OS images and must be turned on manually [wiki.seeedstudio.com/lerobot_lekiwi/].

### 6. Known friction points and build risks

- **Print-specific friction is thinly documented.** No independent, non-vendor builder account documenting physical print/assembly friction (tolerance issues, warping, part breakage, heat-set-insert problems — note: this design uses no heat-set inserts at all) was found in this round. The GitHub issue tracker for the LeKiwi repo has no open or closed issues about print tolerances, part fit, or assembly problems as of this round. The one independent builder account located (Foxglove/Aditya Kamath) reports the base "arrived pre-integrated" and was "a breeze" to integrate, with zero physical build/print friction reported — friction there was entirely software-side (a buggy third-party ROS 2 LiDAR driver package, unrelated to LeKiwi's own build process) [foxglove.dev/blog/upgrading-the-lekiwi-into-a-lidar-equipped-explorer]. This is informative (an experienced builder found the physical build smooth) but does not itself surface print-specific risk — treated as a genuine sourcing gap, not evidence of a smooth build for less-experienced builders.
- **Motor-ID assignment pitfall** (base-specific, from the independent Seeed Studio source): wheel drive-motor IDs 7/8/9 must map to specific physical positions; getting this wrong is a documented mis-assembly risk not called out in the primary repo doc.
- **Unconfirmed community-remix lead**: two community remix files (a Printables "OmniWheel to Feetech STS3215 Servo Adapter" and a Thingiverse "Easy OmniWheel to STS3215 adapter hub(s)") surfaced in search but could not be fetched (HTTP 403; browser-automation tooling unavailable this round). Their existence may hint that some builders needed an alternative wheel-hub-to-servo design, but the reason (fit issue vs. servo-brand variance vs. preference) is unconfirmed — flagged as a lead, not a claim.
- **Cost range remains unreconciled**, and is now more complex, not less: alongside the prior research's $482-499 (Feetech reference) vs. $660 (aggregator headline) figures, this round adds a $770.47 Dynamixel-variant BOM and an independent $450-550 estimate. Per the research plan this reconciliation is explicitly out of bounds unless print-cost evidence resolves it, and none of the new figures does — filament/print cost alone is unlikely to close a $160-180 gap, and no source prices filament cost out specifically.
- **Prior research's already-established friction points carry forward directly**: Ch.8 dynamics is a structural gap across the whole SO-ARM/LeKiwi family (position-controlled hobby servos, no runtime dynamics computation), and general SO-ARM-family calibration friction is documented via open GitHub issues on the `lerobot` repo — both cited from `20260818-modern-robotics-textbook-projects/critique.md` rather than re-sourced here.

## Chapter mapping (Modern Robotics: Mechanics, Planning, and Control)

Building on and refining the mapping already sketched in the prior research's brief, each assembly/software phase maps to Modern Robotics chapters as follows:

- **Wheel modules (Phase 1) + drive-control software (keyboard teleop speed modes)** — **Ch. 13, Wheeled Mobile Robots.** Assembling and driving a 3-wheel holonomic ("Kiwi drive") base directly exercises the chapter's treatment of omnidirectional/holonomic wheeled kinematics: the physical act of mounting three independently-driven omniwheels at fixed angular offsets is the mechanical instantiation of the wheel-velocity-to-body-velocity kinematic model the chapter derives, and the three named teleop speed modes (linear m/s, rotational deg/s) are a direct, hands-on encounter with that model's outputs.
- **Arm sub-assembly (SO-101 print + build, prerequisite to Phase 3)** — **Ch. 2-3, Configuration Space / Rigid-Body Motions**, continuing the prior mapping. Each revolute joint assembled is a configuration-space degree of freedom; fitting links together is a physical exercise in the rigid-body transformations (rotation/translation composition) the chapters formalize.
- **Bottom plate/electronics + top plate/Pi/arm mount (Phases 2-3)** — **Ch. 4, Forward Kinematics**, continuing the prior mapping: fixing the arm's base frame to the mobile platform and wiring joints to their controllers is the physical setup that a forward-kinematics chain (base frame → end-effector frame) is later computed over.
- **Calibration (two-step: base+arm, then leader arm)** — **Ch. 11, Robot Control**, and secondarily **Ch. 5, Velocity Kinematics/Jacobian**: calibration establishes the joint-space zero/reference points and range-of-motion limits that any controller (position or velocity-based) depends on; the explicit framing (enabling policy transfer across physically different units) is a direct, applied instance of why consistent joint-space reference frames matter for the kinematic and control models in Ch. 4-5 and Ch. 11.
- **Software/firmware install, port/motor setup, host/client teleoperation architecture** — **Ch. 11, Robot Control**: this is the practical control-loop plumbing (command → actuator, sensor/state → host) that the chapter's control-architecture concepts describe abstractly.
- **Final integration/test + data collection for imitation learning** — **Ch. 9, Trajectory Generation** (recorded episodes are concrete trajectories in configuration space) and **Ch. 12, Grasping and Manipulation** where the arm's end-effector interacts with objects during data collection, continuing the prior mapping.
- **Structural gap, carried forward from prior research**: **Ch. 8, Dynamics** has no clean mapped phase — the build uses position-controlled hobby servos with no runtime dynamics computation, so no phase of this from-scratch build meaningfully exercises Ch. 8. This is a known, already-documented gap for the whole SO-ARM/LeKiwi family, not new to the printed-frame path.

## Citations

All claims above are traceable to `sources.json` entries by URL:
- Prior research (background, cited forward): `.claude/research/20260818-modern-robotics-textbook-projects/{brief,critique,conclusion}.md`
- `github.com/SIGRobotics-UIUC/LeKiwi/blob/main/3DPrinting.md`
- `github.com/SIGRobotics-UIUC/LeKiwi/blob/main/Assembly.md`
- `github.com/SIGRobotics-UIUC/LeKiwi/blob/main/BOM.md`
- `github.com/SIGRobotics-UIUC/LeKiwi/blob/main/DynamixelLeKiwi/BOM.md`
- `github.com/SIGRobotics-UIUC/LeKiwi/blob/main/README.md`
- `github.com/huggingface/lerobot/blob/main/docs/source/lekiwi.mdx` (rendered at `huggingface.co/docs/lerobot/lekiwi`)
- `wiki.seeedstudio.com/lerobot_lekiwi/`
- `foxglove.dev/blog/upgrading-the-lekiwi-into-a-lidar-equipped-explorer`
- `github.com/TheRobotStudio/SO-ARM100` (STL/SO101 directory)
- `orobot.io/o/program/BROKER-2/lekiwi-mobile-base`

## Risks

- **Sparse print-specific failure data.** The strongest gap in this sourcing round: no independent account of physical print/assembly friction (warping, tolerance mismatch, part breakage) exists for LeKiwi specifically. All positive signal (smooth build) comes from a single experienced builder (Foxglove) who already had SO-100 print/servo experience; this may understate friction for a first-time printer/builder. The critiquing stage should probe whether this absence reflects genuine build simplicity or simply thin independent documentation.
- **Two vendor/official sources (SIGRobotics-UIUC repo, Seeed Studio wiki) dominate the phase-by-phase and print-settings claims**, though they are independently authored and do show minor discrepancies (PLA vs PLA+) rather than being a single mirrored source — treated as adequate but not maximal corroboration.
- **Cost figures are now four-way inconsistent** ($482-499 Feetech reference, $660 aggregator headline, $770.47 Dynamixel variant, $450-550 independent estimate), and per the research plan this is explicitly not to be fully resolved here. The critiquing stage should treat any single cost figure cited in downstream output with appropriate hedging.
- **Two community-remix files relevant to the wheel-hub-to-servo interface could not be accessed** (HTTP 403, no working browser-automation tool this round) — their relevance to a from-scratch print build is plausible but unconfirmed.
- **WebSearch budget was exhausted before a planned targeted search for Reddit/forum/video build logs could run**, per `source-gathering.json`. This is the most likely place additional print-specific friction data would have surfaced; its absence is a search-coverage gap, not evidence of an absence of friction.
- **Motor-ID assignment pitfall (7/8/9 → rear/left-front/right-front) is independent-source-only** — the official Assembly.md does not flag it, raising a small risk that it reflects a Seeed-specific build variant note rather than a universal requirement, though nothing in the primary source contradicts it.

## Open questions

- Does any print-specific failure data exist outside this round's search reach (Reddit, YouTube build logs, forum threads) that would change the "smooth build" impression currently resting on a single experienced-builder account?
- What is the actual composition of the $660 aggregator headline figure — is it closer to the Dynamixel variant ($770.47), a mixed/regional-pricing Feetech build, or something else entirely? (Explicitly out of scope to resolve in sourcing per the plan, but worth flagging for critique to assess how much this ambiguity should be hedged in any downstream cost-facing claim.)
- Do the two inaccessible community-remix files (Printables/Thingiverse OmniWheel-to-STS3215 adapters) indicate a genuine fit or tolerance issue with the official wheel-hub design, or are they simply alternative preferences? This should be re-attempted with working browser-automation tooling if the critiquing stage judges it material.
- Is the PLA vs. PLA+ discrepancy between the official 3DPrinting.md and the Seeed Studio wiki meaningful (e.g., does PLA+ matter for the wheel-hub part specifically, which bears mechanical load under the servo), or purely incidental wording?
- Should the Ch. 8 dynamics gap (no phase of this build meaningfully exercises dynamics) be treated as a genuine limitation of the chapter-mapping exercise, or does some phase (e.g., battery/power sizing, motor torque selection during BOM/part selection) deserve a thinner, caveated Ch. 8 mapping that this brief has not attempted? Critique should weigh in.

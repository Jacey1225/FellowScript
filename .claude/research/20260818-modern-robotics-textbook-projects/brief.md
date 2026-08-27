# Research Brief: Modern Robotics Textbook — Chapter-Mapped Project Suggestions

## Summary

### 1. Confirmed textbook structure

The user's actual PDF (`/Users/jaceysimpson/Downloads/MR-v2.pdf`) was read directly with `pdftotext` (front matter, pages 1-9; preface, pages 14-18) rather than assumed from the public syllabus [PDF]. It is the "updated first edition" preprint of *Modern Robotics: Mechanics, Planning, and Control* by Lynch & Park, dated December 2019 (Cambridge University Press, original 2017 edition), 644 pages [PDF].

Confirmed 13-chapter structure, in book order [PDF]:

1. Preview
2. Configuration Space
3. Rigid-Body Motions
4. Forward Kinematics
5. Velocity Kinematics and Statics
6. Inverse Kinematics
7. Kinematics of Closed Chains
8. Dynamics of Open Chains
9. Trajectory Generation
10. Motion Planning
11. Robot Control
12. Grasping and Manipulation
13. Wheeled Mobile Robots

Plus four appendices (Useful Formulas; Other Representations of Rotations; Denavit-Hartenberg Parameters; Optimization and Lagrange Multipliers), a bibliography, and an index [PDF].

The authors' own stated prerequisite structure: Chapters 2-6 are the "minimum essentials" meant to be covered in sequence; Chapter 8 (dynamics) is a prerequisite for the standard treatment of Chapter 9 (trajectory generation) and Chapter 11 (robot control), though the authors note trajectory generation/control can be taught with velocity-only inputs if dynamics is skipped. Named university course paths cited in the preface combine subsets differently by focus: kinematics-only (2-7, 13), planning-focused (2-3, 10, 13), manipulation-focused (2-6, 8, 12), control-focused (2-6, 8, 9, 11) [PDF]. This gives real prerequisite grounding for sequencing project phases, rather than assuming naive chapter-number order.

No fallback to the public syllabus was needed — the PDF's own table of contents was successfully extracted directly.

### 2. Candidate hobbyist projects and chapter mapping

Four candidates were identified, each with 3-4 independent corroborating sources establishing real-world buildability (not purely theoretical designs).

**A. SO-ARM100/101 desktop robot arm** — 6-DOF, 3D-printed, servo-driven serial manipulator; official open-source design from TheRobotStudio in collaboration with Hugging Face [github.com/TheRobotStudio/SO-ARM100]. Commercially kitted (~$115 single arm, ~$230 dual-arm teleop) with concrete specs (~300mm reach, 200g payload) [seeedstudio.com/SO-ARM100], actively maintained tutorials/software integration with the Hugging Face LeRobot stack [wiki.seeedstudio.com/lerobot_so100m_new], independent maker-press coverage confirming "thousands of builders" and an actively-iterated successor (SO-101) [hackster.io], and independent confirmation as an actually-built (not just proposed) robot [robotsthatexist.com/robots/so-100].
- Build-phase chapter mapping: Ch.2-3 (describing arm/joint configuration and pose) → Ch.4 (forward kinematics, computing end-effector pose from joint angles) → Ch.5 (velocity kinematics/Jacobian, relevant to teleoperation) → Ch.6 (inverse kinematics, solving joint angles for target end-effector poses/pick-and-place) → Ch.9 (trajectory generation, smooth motion between poses) → Ch.11 (robot control, servo position-control loop) → Ch.12 (grasping and manipulation, gripper/pick-and-place, contact).
- Gap: minimal genuine exercise of Ch.8 (dynamics of open chains) since it uses position-controlled hobby servos rather than torque/force-controlled actuation — see Risks.

**B. LeKiwi mobile manipulator** — SO-ARM101 arm mounted on a low-cost holonomic (3-wheel Kiwi-drive) mobile base; official Hugging Face LeRobot documentation [huggingface.co/docs/lerobot/lekiwi], independently documented bill of materials/assembly [robotics.growbotics.ai/projects/hardware/lekiwi], confirmed as an actually-built platform at ~$660 [robotsthatexist.com/robots/lekiwi], and actively maintained vendor tutorials [wiki.seeedstudio.com/lerobot_lekiwi].
- Build-phase chapter mapping: everything in candidate A, plus Ch.13 (wheeled mobile robots — holonomic drive kinematics, odometry) and the mobile-manipulation material within Ch.12, plus Ch.10 (motion planning, navigating with an attached manipulator). Functions as a natural "capstone" extension of the arm build that adds the wheeled-robot chapter.

**C. Sawppy rover** — 6-wheel rocker-bogie Mars-rover replica (Curiosity/Perseverance-inspired), open-source, under $500 in parts [github.com/Roger-random/Sawppy_Rover]; independently replicated by multiple hobbyists with an active build-log community on Hackaday.io [hackaday.io/project/158208-sawppy-the-rover]; derived from NASA JPL's own open-source rover project, giving the underlying rocker-bogie architecture institutional engineering credibility [open-source-rover.readthedocs.io].
- Build-phase chapter mapping: Ch.3 (rigid-body motion, chassis geometry) → Ch.13 (wheeled mobile robots — the chapter's core subject matter: rocker-bogie/nonholonomic kinematics, odometry) → Ch.10 (motion planning, rover path planning over terrain) → Ch.11 (robot control, motor/steering control).
- Gap: no arm, so it does not exercise Ch.4-7 (forward/inverse/closed-chain kinematics) or Ch.12 (grasping/manipulation), and dynamics (Ch.8) relevance is limited to simple wheeled-locomotion dynamics rather than multi-link manipulator dynamics.

**D. Petoi Bittle** — 9-DOF (2 joints/leg × 4 legs + 1 neck) open-source quadruped robot pet, running the OpenCat Arduino/Raspberry Pi framework [github.com/PetoiCamp/OpenCat]; raised $567,218 from 2,052 backers in its original Kickstarter [kickstarter.com/projects/petoi/bittle]; remains an actively sold, maintained product years later [petoi.com/products/petoi-bittle-robot-dog]; independently covered by tech press confirming price point and hobbyist framing [newatlas.com].
- Build-phase chapter mapping: Ch.2-3 (body/leg configuration) → Ch.4 (forward kinematics of each 2-DOF leg) → Ch.6 (inverse kinematics — OpenCat's gait generation genuinely requires per-leg IK to hit foot-placement targets, per the framework's own documentation) → Ch.9 (trajectory generation — gait/foot-path generation) → Ch.11 (robot control — servo motion control plus IMU-based balance feedback).
- Gap: no manipulator, so Ch.5 (full Jacobian-based velocity kinematics, vs. OpenCat's simpler geometric IK), Ch.7 (closed chains — unclear from sourced material whether any leg uses a four-bar/closed-chain linkage vs. simple open 2-DOF legs), and Ch.12 (grasping/manipulation) are not exercised; Ch.13 (wheeled mobile robots) does not apply to a legged platform; dynamics (Ch.8) relevance is limited for the same position-controlled-servo reason as the other candidates.

### 3. Vibe/lifestyle fit — explicitly a judgment call, not a sourced claim

The gathering agent found no meaningful external sources for "vibe" adjacency to video games/AI/cyberware/anime as a category (only generic/weak results like TikTok clips or generic tutorial roundups) [source-gathering.json gaps]. This assessment is therefore the brief/critique stage's own qualitative read of each project's real characteristics, not a claim traceable to a specific source, and should be treated as such downstream:
- SO-ARM100/LeKiwi: Hugging Face-branded, AI/robot-learning ecosystem (teleoperation, imitation learning) gives strong "AI/techy" adjacency; a desk-mounted arm has plausible everyday utility (pick-and-place assistant, desk organizer) rather than being a static display piece.
- Sawppy: strong sci-fi/space adjacency (near, not identical, to a video-game-prop aesthetic) but weakest on "everyday routine utility" — a Mars-rover replica has no obvious daily household function beyond novelty/demo driving.
- Bittle: closest to "robotic companion/familiar" framing (anime/cyberware-adjacent "pet" concept) and has some routine-utility angle (patrol/monitoring, interactive companion) but is the most literally pet-shaped, which risks reading as a toy rather than a techy build.

## Citations

- `[PDF]` = `/Users/jaceysimpson/Downloads/MR-v2.pdf`, read directly via `pdftotext` (sources.json entry 1)
- `[github.com/TheRobotStudio/SO-ARM100]` = sources.json entry 2
- `[seeedstudio.com/SO-ARM100]` = sources.json entry 3
- `[wiki.seeedstudio.com/lerobot_so100m_new]` = sources.json entry 4
- `[hackster.io]` = sources.json entry 5
- `[robotsthatexist.com/robots/so-100]` = sources.json entry 6
- `[huggingface.co/docs/lerobot/lekiwi]` = sources.json entry 7
- `[robotics.growbotics.ai/projects/hardware/lekiwi]` = sources.json entry 8
- `[robotsthatexist.com/robots/lekiwi]` = sources.json entry 9
- `[wiki.seeedstudio.com/lerobot_lekiwi]` = sources.json entry 10
- `[github.com/Roger-random/Sawppy_Rover]` = sources.json entry 11
- `[hackaday.io/project/158208-sawppy-the-rover]` = sources.json entry 12
- `[open-source-rover.readthedocs.io]` = sources.json entry 13
- `[kickstarter.com/projects/petoi/bittle]` = sources.json entry 14
- `[github.com/PetoiCamp/OpenCat]` = sources.json entry 15
- `[petoi.com/products/petoi-bittle-robot-dog]` = sources.json entry 16
- `[newatlas.com]` = sources.json entry 17
- `[source-gathering.json gaps]` = `.claude/research/20260818-modern-robotics-textbook-projects/source-gathering.json`, `gaps` field

## Risks

- **Single-source structure confirmation.** The chapter-list claims all trace to one source — the PDF itself (`corroboration_count: 1`). This is expected and appropriate (it is the primary source of record per the research plan, and no external corroboration is meaningful for "what this specific PDF's TOC says"), but flagging it: nothing here has been cross-checked against a second independent reading of this exact PDF file.
- **Dynamics chapter (Ch.8) is weakly exercised by every candidate.** All four projects use position-controlled hobby servos rather than torque/force-controlled actuators, so none of them genuinely requires working through the book's Lagrangian/Newton-Euler dynamics formalism in the way building a torque-controlled arm would. This is a structural gap across the entire candidate set, not a flaw in any single project — the eventual project-to-chapter mapping should not overstate how deeply any candidate exercises Ch.8.
- **Chapter 7 (Kinematics of Closed Chains) is unmapped by any candidate.** None of the four projects' sourced technical descriptions clearly involves a closed-chain/parallel mechanism. Bittle's legs are the closest candidate but the sourced OpenCat documentation doesn't confirm a four-bar or other closed-chain leg linkage — this is marked as uncertain, not confirmed either way.
- **No single project covers the full 13-chapter list.** Full coverage requires combining projects (e.g., arm-family candidates A/B for Ch.4-7/12, plus a wheeled or legged candidate for Ch.13) — a single-project "complete chapter tour" is not supported by the sourced material.
- **Kickstarter figures for Bittle are dated (2020 campaign).** Backer/funding numbers reflect the original launch; current-day popularity is only indirectly corroborated by the vendor's still-active product page and independent press, not a recent sales/community figure.
- **Vibe/lifestyle-fit assessment is unsourced by design.** As noted above, this is a qualitative judgment made from each project's real technical/commercial characteristics, not a claim backed by a specific source — the gathering agent confirmed no meaningful sources exist for this category and flagged it as appropriately left to downstream judgment.

## Open questions

- Should the final suggestion be a single project, or an explicit two-project sequence (e.g., SO-ARM100 → LeKiwi, or SO-ARM100 + Sawppy) in order to achieve fuller chapter coverage, given that no single candidate spans all 13 chapters?
- Given the shared weakness on Ch.8 (dynamics) across all four candidates, is there a hobbyist-feasible project modification (e.g., adding torque-sensing servos, or a supplementary simulation-only dynamics exercise) worth proposing, or should the recommendation simply acknowledge Ch.8 as a "read but not hands-on-built" chapter?
- Is Chapter 7 (closed chains) worth deliberately targeting with a fifth candidate (e.g., a parallel-linkage/Stewart-platform-style mechanism), or is leaving it unexercised acceptable given the plan's "2-4 candidates, not exhaustive" scope?
- Which of the four candidates' "vibe" framing (AI/teleoperation-adjacent arm, sci-fi rover, anime/cyberware-adjacent robotic pet) best matches the user's actual stated interest adjacencies — this is a judgment call for the critique/evaluation stages to weigh, not something further sourcing can resolve.
- Should LeKiwi be framed as a standalone fourth option or strictly as an "extension phase" of the SO-ARM100 build — the sourced material supports it either way, and the recommendation format may depend on how the user prefers the project options to be presented.

# Research Plan: Modern Robotics Textbook — Chapter-Mapped Project Suggestions

## Topic / Claim

Two linked deliverables:

1. **Confirm the actual chapter/topic structure** of the specific PDF at
   `/Users/jaceysimpson/Downloads/MR-v2.pdf` — the user's copy of *Modern
   Robotics: Mechanics, Planning, and Control* by Kevin M. Lynch and Frank C.
   Park (~644 pages). This must be read directly from the PDF's own table of
   contents / chapter headers, not assumed purely from the publicly known MIT
   Press syllabus, since editions/versions ("v2") can differ in chapter
   numbering, appendices, or included sections.
2. **Identify a handful of hobbyist/maker-achievable robotics build projects**
   that can be organized as a chapter-by-chapter learning path through that
   confirmed structure (first chapter's concepts built/exercised first,
   through to the last), where each major phase of the build corresponds to a
   specific chapter's material.

This is a **suggestion-stage** deliverable only. A full build walkthrough
(bill of materials, wiring, step-by-step assembly/code) is an explicit later
step the user will request after reviewing these suggestions — do not produce
a full build guide in this pipeline run.

## Scope

**In bounds:**
- Extracting/confirming the real chapter list, section structure, and topic
  progression from the actual PDF (front matter TOC, chapter titles, major
  section headers within each chapter).
- Noting where topics build on each other (e.g., configuration space and
  rigid-body motion typically precede forward kinematics, which precedes
  velocity kinematics/Jacobians, which precedes dynamics, trajectory
  generation, motion planning, and control) so the project sequencing can
  reflect real prerequisite structure rather than an assumed one.
- Researching 2-4 candidate hobbyist/individual-buildable robot projects
  (e.g., robot arm, mobile/wheeled robot, legged or hybrid platform, etc.)
  that plausibly touch most/all of the textbook's major chapter topics over
  the course of a build (kinematics, dynamics, trajectory generation, motion
  planning, control, possibly grasping/manipulation, wheeled mobile robots,
  visual/sensor feedback if covered).
- For each candidate project: what chapters it would exercise, roughly in
  what order, feasibility for a single hobbyist builder (cost, tools,
  fabrication complexity, electronics/programming complexity), and existing
  real-world precedent (open-source designs, kits, tutorials, communities)
  that show it's actually been built by individuals before — not a purely
  theoretical proposal.
- Aesthetic/personality fit: the eventual suggested project(s) should have
  genuine everyday "lifestyle" utility or routine functional use (not a
  static shelf display), and should carry a build-focused, techy vibe that is
  adjacent to — without being literally costumed as — video games, AI,
  cyberware/cybertech, or anime (e.g. a functional desk companion robot, a
  wearable/exosuit-adjacent assistive rig, a small autonomous "familiar"
  platform, a smart camera/turret-style utility bot, etc. — concept
  examples only, not a commitment to any one of these).

**Out of bounds:**
- Full parts lists, CAD files, wiring diagrams, or step-by-step build
  instructions — that's the later walkthrough phase.
- Projects requiring industrial fabrication, institutional lab access, or
  budgets beyond an individual hobbyist (no six-figure humanoid platforms).
- Projects that are literally branded/costumed as a specific IP (no "build a
  Pikachu," no licensed-character skins) — adjacency/vibe only.
- Deep dives into robotics research literature beyond what's needed to
  confirm textbook structure and validate project feasibility/precedent.

## Constraints

- **Primary source of record for structure:** the actual PDF at
  `/Users/jaceysimpson/Downloads/MR-v2.pdf`. If PDF text/TOC extraction tools
  are unavailable in the environment, the source-gathering agent should try
  multiple extraction paths (e.g. installing/using a PDF text extraction
  library, OCR fallback, or reading specific page ranges via available
  tooling) before falling back to the publicly documented syllabus — and if
  it must fall back, that must be flagged explicitly in the brief as an
  assumption, not presented as confirmed.
  time period: no date constraint — the textbook is a stable, well-known
  reference; project/community sources can be any age but prefer sources that
  are still reasonably current (designs/kits/forums that appear maintained or
  at least not defunct) over very old dead links.
- **Source types:** the textbook PDF itself (primary), plus a mix of
  maker/hobbyist project write-ups, open-source robotics project repos,
  kit/product pages, and community build logs/forums as evidence of
  real-world buildability. Academic papers acceptable as supporting evidence
  of technique but should not be the sole source for feasibility claims.
- **Depth expected:** enough to confidently map 2-4 project options against
  the confirmed chapter list with a clear rationale per project — not an
  exhaustive survey of every robot project ever built.

## Research steps

1. Extract the actual table of contents and chapter list from
   `/Users/jaceysimpson/Downloads/MR-v2.pdf`, including chapter numbers,
   titles, and (if readily visible) major subsection headings per chapter.
2. Note the logical/prerequisite ordering across those confirmed chapters
   (what depends on what) so later project-to-chapter mapping respects real
   sequencing, not just chapter number order for its own sake.
3. Identify the technical topics each chapter actually covers (e.g. rigid
   body motion & configuration space, forward kinematics, velocity
   kinematics & Jacobians, inverse kinematics, dynamics of open chains,
   trajectory generation, motion planning, robot control, grasping and
   manipulation, wheeled mobile robots, kinematics of closed chains — confirm
   which of these the actual PDF covers and in what order, don't assume).
4. Survey hobbyist/maker-level robotics projects (arms, mobile robots,
   legged/hybrid platforms, robotic pets/companions, etc.) that individuals
   have actually built, with attention to which ones naturally require
   working through kinematics → dynamics → planning → control-type
   progressions.
5. For each strong candidate (aim for 2-4), map which confirmed textbook
   chapters it would exercise and in what build-phase order, and assess
   hobbyist feasibility (cost ballpark, tools/fabrication needed, existing
   open-source precedent or kits).
6. Assess "vibe"/lifestyle fit for each candidate against the user's stated
   interest adjacencies (video games, AI, cyberware/cybertech, anime,
   coding) and its everyday routine utility (not just a display piece) —
   without proposing anything literally themed as a specific IP or single
   category.

## User-provided sources

- `/Users/jaceysimpson/Downloads/MR-v2.pdf` — the user's own copy of
  *Modern Robotics: Mechanics, Planning, and Control* by Kevin M. Lynch and
  Frank C. Park (~644 pages), referred to by the user as "MR-v2.pdf." This is
  the authoritative source for the textbook's structure and must be read
  directly, not assumed from memory of the public syllabus alone.

## Success criteria

The sourcing stage has produced enough to work with when it has:

- A confirmed (not assumed) chapter-by-chapter breakdown of the actual PDF,
  with enough topic detail per chapter to map projects against it.
- At least 2-4 well-reasoned candidate hobbyist robotics projects, each with
  real-world buildability evidence (not purely speculative), a plausible
  chapter-ordered build-phase mapping across the confirmed chapter list, and
  a stated rationale for its fit with the user's interest adjacencies and
  everyday-use requirement.
- Clear flagging of any point where the PDF's structure could not be
  directly confirmed and a public-syllabus assumption had to be used instead.

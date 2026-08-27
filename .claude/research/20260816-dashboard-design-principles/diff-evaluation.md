# Diff Evaluation: Dashboard UI/UX Design Principles

This evaluation walks `brief.md`'s eight sections in order, weighing each
section's claims against `critique.md`'s per-claim verdicts (which already
placed `counter-claims.json` against `brief.md`/`sources.json`). No new
evidence is introduced here — this is a synthesis of material already on
record in the prior three files.

## Section-by-section verdicts

### 1. Information architecture

No counter-evidence claim targeted this section (F/Z-pattern scanning,
progressive disclosure, Gestalt proximity, empty-state guidance, curated
content). **Stronger side: original, by default** — these claims were never
put under adversarial pressure by the counter-evidence stage, so they stand
as sourced (NN/g eye-tracking research, IxDF, Pencil & Paper) but should be
read as *unchallenged*, not *independently re-confirmed*. **Disproven:**
none. **False:** none. **Unresolved:** none — simply out of scope for this
critique round.

### 2. Visual design fundamentals

Target: **B** (Material Design's 15.8:1 dark-theme contrast recommendation).
**Stronger side: both, on different questions — not a real conflict.** The
brief's claim is descriptive (what Material's spec says) and nothing in the
counter-evidence disputes that fact; Stephanie Walter's halation research
(corroborated by three convergent accessibility publishers) addresses a
different, normative question the brief never explicitly asserted
(whether maximum contrast is unambiguously good for every user). **Disproven:**
none. **False:** none. **Unresolved:** none — this is a resolved caveat-add,
not an open question. The brief should carry forward Material's 15.8:1 figure
as-is, plus a new caveat about offering a contrast/theme choice for users
with astigmatism or similar conditions.

### 3. Data visualization principles

Targets: **A** (pie vs. bar/line/scatter) and **F**, first occurrence
(truncated/non-zero Y-axes as anti-pattern).

- **A** — **Stronger side: counter.** A 2025 peer-reviewed journal article
  (Hill, multi-metric methodology including pupillometry) plus two
  independently converging findings (Kosara & Skau's mechanism analysis,
  Simkin & Hastie) outrank the brief's practitioner-synthesis source on this
  specific empirical question. **Disproven as stated:** the blanket
  "consistently outperform... pie charts" framing for proportion-estimation
  tasks. **Not simply false:** the underlying preattentive-processing science
  (length/2D position as faster/more accurate channels in general) is not
  disputed, and no counter-evidence rehabilitates 3D charts, gauges, or
  multi-slice pies — only the narrow pie-vs-bar-for-proportion-estimation
  claim gives way. Needs narrowing to: bar/line/scatter win for magnitude
  comparison across many categories; pie and bar perform comparably for
  simple part-to-whole judgments with few slices.
- **F** — **Stronger side: counter.** Two independent, well-established
  data-viz authorities (Cole Nussbaumer Knaflic/Stephen Few, and Alberto
  Cairo via secondary coverage) converge on a chart-type-dependent rule.
  **Disproven as stated:** the chart-type-agnostic framing of the anti-pattern.
  **Not simply false:** the rule holds fully for bar charts; it's the
  extension to all chart types, especially line-chart trend widgets, that
  doesn't survive. Practically significant for dashboards given their heavy
  use of sparklines/trend widgets.
- **Unresolved:** none in this section.

### 4. Interaction design and micro-interactions

Target: **D** (skeleton screens preferred over spinners).
**Stronger side: counter.** This is the clearest reversal in the whole
evaluation: Viget's controlled, methodologically transparent study (n=136,
three conditions) found skeleton screens performed *worst* on every metric
measured (perceived speed, subjective wait rating, task completion time),
directly contradicting freeCodeCamp's uncited "preferred" framing.
**Disproven as stated:** the blanket "preferred over spinners... for
content-heavy interfaces" claim. **Not simply false:** the counter-finding
itself is a single, non-peer-reviewed study that its own authors describe as
preliminary — the same single-source limitation the brief already flags
elsewhere — so the correct confidence level is "does not survive as an
unqualified claim," not "proven to be the opposite." **Unresolved:** whether
the reversal holds generally or depends on interface familiarity/wait-time
length is itself an open question the evidence doesn't settle either way.

### 5. Accessibility for data-dense interfaces

No counter-evidence claim targeted this section (WCAG contrast thresholds,
data-table screen-reader markup, ARIA grid pattern, interactive-chart
accessibility). **Stronger side: original, by default**, unchallenged rather
than independently re-confirmed. **Disproven:** none. **False:** none.
**Unresolved:** none — out of scope for this round.

### 6. Generic/templated vs. distinctive dashboard design

Target: **E** (content-form fit drives distinctiveness).
**Stronger side: both — complementary, not competing.** NN/g's "Fresh vs.
Familiar" research (same reliability tier as several of the brief's own core
sources) argues familiarity should dominate over freshness for
high-frequency, functional interfaces — but this operates on a different
axis (interaction-pattern conventions) than the brief's claim (content-driven
visual/hierarchy decisions). A dashboard can be visually distinctive through
content-driven choices while still preserving conventional filter placement,
navigation, and chart interactions. **Disproven:** none. **False:** none.
**Unresolved:** none — this is a resolved caveat-add. The brief's core claim
should carry forward with an added caveat: distinctiveness efforts should
stop short of disrupting the interaction layer for frequent/expert users.

### 7. What "modern" (2023-2026) means in dashboard design

Targets: **C1** (15-30% FPS drop from backdrop-filter/glassmorphism) and
**C2** (bento grids at high information density).

- **C1** — **Stronger side: neither — genuinely unresolved.** Even the
  highest-authority technical sources available (web.dev, MDN) confirm a
  real performance cost only qualitatively, with no percentage figures at
  all. Other sources citing similar magnitude numbers are themselves
  uncited, SEO-flavored blogs — repetition of an unverified figure, not
  independent confirmation. This confirms rather than resolves the brief's
  own flagged risk. **Disproven:** none. **False:** none. **Unresolved:**
  the specific 15-30% figure — present it as illustrative, not established,
  while treating the qualitative "real performance cost" claim as solid.
- **C2** — **Stronger side: neither — genuinely unresolved.** The only
  source found on the dense-dashboard-specific question (baltech.in) is the
  same low reliability tier already flagged as thin for the original claim,
  not an improvement on it. **Disproven:** none. **False:** none.
  **Unresolved:** whether bento grids hold up at high information density
  specifically (as opposed to overview/summary pages) remains open exactly
  as the brief's own Open Questions anticipated.

### 8. Common failure modes / anti-patterns

Target: **F**, second occurrence (Y-axis truncation flagged again as a
dashboard anti-pattern). Same verdict as in Section 3: **stronger side:
counter**, **disproven as stated** (chart-type-agnostic framing), narrowed
to bar charts specifically, not a blanket rule for line-chart trend widgets.
The section's other claims (metric overload, vanity metrics, missing
context, wrong chart-type selection, the ~5-9-element working-memory cap,
Nielsen's 10 heuristics) were not targeted by counter-evidence and stand
unchallenged; note the brief's own Open Questions already flagged the
5-9-element figure's primary-research lineage as unverified, and that gap
remains open (no counter-evidence stage activity resolved or contested it).

## Overall picture

Of the seven claims/clusters the counter-evidence stage targeted:

- **Counter side stronger / original disproven as stated (needs narrowing),
  none proven simply false:** A (pie vs. bar/line/scatter for proportion
  estimation), D (skeleton screens vs. spinners), F (Y-axis truncation as a
  blanket, chart-type-agnostic rule). In each case a higher- or
  equal-reliability, more directly on-point source (a 2025 peer-reviewed
  study for A; a controlled n=136 usability study for D; two independent
  established data-viz authorities for F) displaces an unqualified framing
  in the brief — but in none of the three cases does the underlying
  mechanism/science get discredited outright, and in D's case the
  counter-evidence itself is flagged as preliminary. These three sections
  need their brief language walked back from "consistently"/"preferred
  over"/blanket-anti-pattern framings to narrower, conditioned statements.
- **Original and counter side compatible, caveat added, no real
  conflict:** B (Material Design contrast — factual claim about the spec
  stands; new caveat about accessibility trade-offs added) and E
  (content-form fit — core claim stands; new caveat about interaction-pattern
  familiarity for frequent users added).
- **Genuinely unresolved, neither side has adequate evidence:** C1 (specific
  15-30% FPS figure) and C2 (bento grids at high density specifically) —
  both were already flagged as risks/open questions in the original brief,
  and the counter-evidence search confirmed rather than closed those gaps.
- **Untested / out of scope for this critique round:** Sections 1
  (information architecture) and 5 (accessibility fundamentals) received no
  counter-evidence claims at all and should be read as unchallenged rather
  than independently re-verified.

No claim across either side was found to rest on a source that doesn't
actually support it, and the counter-evidence stage engaged substantively
with every claim it targeted — consistent with `critique.md`'s own
conclusion that no bounce to `research-brief` or `counter-evidence` was
warranted. This evaluation reaches the same conclusion for the
evaluating-diffs gate: the critique is usable as-is, and no bounce back to
`critique` is needed.

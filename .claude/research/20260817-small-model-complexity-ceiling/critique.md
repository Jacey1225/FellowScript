# Critique: Closing the Small-Model Complexity Ceiling

Side-by-side critique of `brief.md`'s four target claims against `counter-claims.json`'s
counter-evidence. For each, the question asked is not "does the brief survive" by default, but
whether either side's evidence actually holds up when actively attacked.

## Per-claim verdicts

### 1. SCoRe: 7B student (52.3 avg) exceeds 72B teacher (51.1 avg) on 8 combined benchmarks (arXiv 2509.14257)

- **Original position**: Single-source, unreplicated, but concrete and quantified. The brief
  already self-flagged this as "promising but unreplicated," not established fact.
- **Counter position**: No direct replication or SCoRe-specific critique exists after a genuine
  search (citation graph, contamination/overfitting literature). The only related finding —
  "When Agents Look the Same" (arXiv 2604.21255, ACL 2026, independent authors) — argues
  distillation generally produces behavioral homogenization, such that a student "matching or
  exceeding" a teacher can reflect surface mimicry of teacher-preferred patterns rather than
  independently verified capability gain.
- **Does the counter actually contradict, or just add nuance?** Nuance, not contradiction, and
  weaker nuance than it first appears. The homogenization paper's mechanism is about *diversity
  loss* in reasoning style across distilled models, not a demonstrated way that automatically
  scored, execution/correctness-style agentic benchmarks (GAIA, HLE, xBench, WebWalker) can be
  inflated by mimicry alone — those benchmarks generally grade task completion, not
  judge-scored "style," so the proposed inflation mechanism doesn't obviously transfer to
  SCoRe's specific scoring method. The counter-evidence agent's own honest framing — "does not
  test SCoRe's own benchmarks, does not test the same models, never mentions SCoRe by name" — is
  the load-bearing admission here.
- **Verdict**: Neither side is strengthened or weakened much. The original claim survives at
  exactly the hedge level the brief already assigned it (promising, single-source, unreplicated).
  The counter fails to establish a specific mechanism for why *these* benchmarks would be
  susceptible to the homogenization critique, so it should not be read as materially undermining
  SCoRe's numbers — but it is a legitimate general reason for caution across the whole
  distillation-cluster claim family, appropriately logged as a soft discount rather than a
  refutation.

### 2. ACM: sub-9B models "lose coherence after only a few turns" for context-compression training (arXiv 2607.23809)

- **Original position**: Incidental but concrete evidence of a possible scale floor for this
  specific architectural technique (context-management training).
- **Counter position**: Mixed. ATOD (0.6B, fetched in full) succeeds at >80% on multi-turn
  ALFWorld/WebShop with no reported coherence collapse — an order of magnitude below ACM's 9B
  cutoff. But LHC v0.2 (a non-peer-reviewed blog, found while searching for the *strongest* form
  of counter-evidence) instead reinforces ACM's claim at nearby 8B scale, finding 8B-class models
  underperform a deterministic baseline on state-recall after context gaps.
- **Does the counter actually contradict, or just add nuance?** Nuance. ACM's claim is narrowly
  about coherence sufficient to produce *trajectories informative enough to learn a compression
  policy from* — plausibly requiring much longer horizons than ALFWorld/WebShop episodes, which
  are bounded and don't require the token-volume buildup that makes compression necessary in the
  first place. ATOD demonstrates general multi-turn task success at 0.6B, not coherence over the
  specific long-horizon, compression-relevant trajectory lengths ACM is about. Domain mismatch is
  real and was already flagged by the counter-evidence agent itself, which is the correct
  self-skepticism.
- **Verdict**: ACM's narrow, scoped claim survives — the counter-evidence doesn't test the same
  task structure, and one of its two legs (LHC v0.2) actually corroborates rather than refutes it
  at a nearby scale. What does NOT survive is any broader generalization from ACM's finding to
  "sub-9B models can't sustain multi-turn coherence generally" — ATOD is a real, direct refutation
  of that stronger, unscoped version of the claim. The brief itself never made that stronger
  claim (it scoped the finding to "this specific architectural technique"), so the brief's own
  hedging is validated by this exercise, not undermined by it.

### 3. HORIZON: "model scaling alone is unlikely to resolve the dominant failure mechanisms" of long-horizon collapse, imported to small models by inference (arXiv html/2604.11978v1)

- **Original position**: Argued only on frontier models (GPT-5-class, Claude-4), extended to
  small models purely by the brief's own inferential allowance — the brief was explicit that this
  transfer was unproven.
- **Counter position**: Two small-model-inclusive, peer-reviewed/arXiv sources. "The Illusion of
  Diminishing Returns" (ICLR 2026) tests Qwen3/Gemma3 from 4B up through frontier scale and finds
  a clear, non-diminishing scaling trend in how many sequential turns a model can execute
  correctly — even when single-step accuracy is already comparable across sizes. AgentFloor
  (16 open-weight models, 0.27B–32B) finds small-model long-horizon failure signatures are
  capacity-flavored (step-budget exhaustion, tool hallucination under token pressure) and
  qualitatively distinct from frontier failure modes, and that no tested intervention —
  including the paper's own "obvious candidate for a universal fix" — generalized across scales.
- **Does the counter actually contradict, or just add nuance?** This is a genuine contradiction,
  not mere nuance, on the specific point the brief flagged as unproven: whether HORIZON's
  frontier-derived conclusion transfers to small models. "Illusion of Diminishing Returns"
  directly measures long-horizon execution capacity across the small-to-frontier range and finds
  scale itself does measurably and continuously extend it — this is the opposite of "scaling
  alone is unlikely to resolve," at least for the execution-capacity axis of long-horizon failure.
  One caveat in the counter's favor of nuance rather than total contradiction: HORIZON's named
  failure modes are planning errors, catastrophic constraint-forgetting, and history-error
  accumulation — arguably a different axis than raw turn-execution capacity — so "scaling helps
  execution capacity" and "scaling doesn't fix planning/memory failure modes" could both be true
  simultaneously. AgentFloor's finding that failure composition shifts with scale actually extends
  HORIZON's own core insight (failure composition, not just rate, is what matters) rather than
  refuting it — but AgentFloor's finding that no intervention generalized across scales does cut
  against the practical implication of HORIZON's recommendation (method-level fixes), at least as
  a *universal* fix.
- **Verdict**: This is the clearest case where the original claim, as extended by inference to
  small models, does not survive scrutiny intact. The counter-evidence is the strongest and most
  directly on-point of the four (confidence 0.6, appropriately the highest of the four
  counter-claims) — small models are not just an unproven inferential extension of HORIZON's
  argument, there is now direct evidence that scale matters more than "scaling alone is unlikely
  to resolve" suggests, at least for execution capacity specifically. The narrower point HORIZON
  makes (failure composition shifts, not just success rate) is corroborated and even strengthened
  by AgentFloor's scale-based version of the same finding.

### 4. AgenticQwen/ATOD/CacheRL cluster: three-source corroboration of the distillation-narrows-the-gap claim

- **Original position**: AgenticQwen's "closes the gap" claim, corroborated directionally by ATOD
  and CacheRL — but two of the three legs were only search-summary-level at brief-writing time,
  an "echo chamber" risk the brief itself flagged.
- **Counter position**: This round upgraded ATOD to fully-fetched-and-verified — it confirms and
  quantifies the claim (0.6B/1.7B/4B students surpass teacher by 2.16 points average across
  ALFWorld/Search-QA/WebShop). CacheRL remains unverifiable after two independent fetch attempts.
  AgenticQwen's own headline number remains entirely self-reported — no third-party leaderboard
  evaluation was found.
- **Does the counter actually contradict, or just add nuance?** Neither, really — this is a
  corroboration-strength audit, not a contest between opposing claims. Net effect is mixed but
  slightly positive for the original: one leg got strictly stronger (ATOD), one leg stayed exactly
  as weak as before (CacheRL, still unverifiable), and one leg's weakness (AgenticQwen,
  self-reported) was already known and is unchanged. The "echo chamber" risk the brief flagged is,
  in the counter-evidence agent's own words, "only partially resolved, not closed."
- **Verdict**: The cluster's directional claim (targeted multi-turn distillation training can
  narrow the small-vs-large gap) is somewhat better evidenced than the brief could confirm at
  writing time, because ATOD is now a genuinely independent, fully-verified, quantified data
  point rather than a search-summary echo. But AgenticQwen's specific "closes the gap" framing
  should still be discounted as self-reported and externally unverified, and CacheRL should still
  be treated as unconfirmed.

## Claims that hold

- **ACM's scale-floor claim, as narrowly scoped** (sub-9B models may be too incoherent to acquire
  context-compression-training-relevant trajectories) — survives; the best counter-evidence found
  doesn't test the same task structure, and a second source corroborates it at a nearby scale.
- **SCoRe's headline result, at the brief's own hedge level** (promising, single-source,
  unreplicated) — survives unchanged; the counter-evidence's general distillation-homogenization
  critique doesn't establish a specific mechanism applicable to SCoRe's own scoring method.
- **ATOD's contribution to the distillation cluster** — now fully verified and quantified (2.16
  points average gain over teacher at 0.6B–4B), stronger evidence than the brief could claim at
  writing time.
- **HORIZON's core methodological insight** — that long-horizon failure is a shift in failure
  *composition*, not just success rate — is corroborated and extended (not refuted) by
  AgentFloor's finding that failure composition also shifts by *scale*, in a capacity-flavored way
  for small models specifically.

## Claims that don't hold

- **HORIZON's "scaling alone is unlikely to resolve" conclusion, as applied to small models by
  inference** — this specific inferential extension does not survive. "The Illusion of Diminishing
  Returns" (ICLR 2026, small-model-inclusive) directly shows scale continuously and measurably
  extends long-horizon execution capacity even when single-step accuracy is held comparable across
  sizes — the opposite of what "scaling alone is unlikely to resolve" implies for at least the
  execution-capacity axis of long-horizon failure. The brief's own hedge that this transfer was
  "an inference under the plan's domain-transfer allowance, not direct small-model evidence" turns
  out to have been well warranted — the direct small-model evidence, now that it exists, points
  against the inference.
- **Any unscoped reading of ACM's claim as "sub-9B models generally can't sustain multi-turn
  coherence"** — this broader version (which the brief did not actually assert, but which a
  careless reading might infer) is directly falsified by ATOD's 0.6B results on ALFWorld/WebShop.
- **AgenticQwen's "closes the gap with much larger models" framing, taken as an established,
  externally verified fact** — it remains an entirely self-reported claim with no third-party
  leaderboard corroboration found after a genuine search; it should be read as a lab's own
  benchmark claim, not confirmed capability.

## Confidence adjustments

- **SCoRe (brief: "strongest ceiling-raising claim... should not be taken at face value")**: no
  change. Confidence stays low-moderate; the counter-evidence neither strengthens nor
  meaningfully weakens it, so the brief's existing caution is correct as written.
- **ACM scale-floor finding (brief: incidental, small, secondary)**: confidence in the *narrowly
  scoped* version increases slightly — it survived a genuine, good-faith attempt at falsification,
  and gained a second, nearby-scale corroborating (if lower-quality) source. Confidence in any
  broader generalization beyond the brief's own scoping should be treated as low, per ATOD's
  direct counter-evidence.
- **HORIZON's small-model inference (brief: explicitly flagged as unproven inference)**:
  confidence in the transfer to small models decreases materially. Where the brief treated this as
  an open, untested inference, it should now be treated as a specific point of *known tension*
  with direct small-model evidence (Illusion of Diminishing Returns), not merely unproven.
  HORIZON's failure-composition insight itself, however, gains confidence via AgentFloor's
  scale-based corroboration.
- **AgenticQwen/ATOD/CacheRL cluster (brief: "should be read as a promising but unreplicated
  result")**: confidence in the cluster overall ticks up modestly (ATOD's upgrade to
  fully-verified status), but confidence in AgenticQwen's specific headline framing stays flat —
  still self-reported, still externally unverified. CacheRL should continue to be treated as the
  weakest, least-verified leg of the three.

## Unresolved

- **SCoRe replication**: genuinely inconclusive on both sides. No source directly confirms or
  refutes SCoRe's own numbers; the general distillation-homogenization critique is suggestive but
  not targeted. This remains the single highest-value replication target, exactly as the brief's
  Open Question 3 already flagged — the critique stage does not close this gap, only confirms it
  is real and still open.
- **Whether HORIZON's planning/memory-specific failure modes (as opposed to raw execution
  capacity) are also scale-resolvable**: the counter-evidence targets the execution-capacity axis
  specifically; whether scale similarly helps with catastrophic constraint-forgetting or
  history-error accumulation — HORIZON's other named failure modes — is not addressed by either
  side's sources and remains open.
- **CacheRL's actual claims**: could not be verified by either the sourcing or critiquing stage
  despite three total fetch attempts across both stages (one original, two this round). Whatever
  CacheRL actually shows remains unknown; it should be treated as effectively unverified evidence
  going forward, not corroboration either way.

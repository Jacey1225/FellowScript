# Research Brief: Closing (Not Working Around) the Small-Model Complexity Ceiling

Follow-up to `20260817-small-model-coding-agents`. That prior research established the
gap-widens-with-difficulty pattern and found no scaffolding technique (RAG, verifiers,
multi-agent orchestration, distillation) changed the trend, only where a small model sits within
it. This brief asks the narrower question: does anything found here actually **raise** the
ceiling, versus compensate within it? Each claim below is tagged **[ceiling-raising]**,
**[within-ceiling]**, or **[unclear/contested]** per the plan's tagging requirement, and cited to
`sources.json` by URL.

## Summary

### Step 1 — Architectural/system-level techniques

Five sources speak directly to architectural levers (context management, memory, execution
loops, RL-training stability) rather than model-level scaffolding:

- **Context management / compression**: ACM (https://arxiv.org/abs/2607.23809) trains an agent to
  compress and offload context on long-horizon tasks — but its own authors deliberately used a
  9B model as the rollout/student model, explicitly because "substantially smaller models often
  lose coherence after only a few turns, producing trajectories of limited value for learning
  effective compression behavior." **[unclear/contested, negative signal]** — this is direct,
  if incidental, evidence that below some scale floor, models may be too incoherent to even
  acquire this architectural skill, which cuts against "architecture alone raises the ceiling"
  for the smallest models.
- **Memory systems**: LightMem (https://arxiv.org/html/2604.07798v1) shows a tiered
  short/mid/long-term memory architecture, using quantized 1–1.5B models for online control,
  improves retrieval quality (~2.5 F1 on LoCoMo) consistently across backbone sizes including
  sub-3B models. **[within-ceiling, with a capability-expansion claim too weak to confirm]** —
  the benchmark is long-context QA retrieval, not agentic coding difficulty, so it plausibly
  extends what a small model's *context window* can effectively hold, but does not directly
  demonstrate movement on harder task classes.
- **Execution feedback**: "Feedback Over Form" (https://arxiv.org/abs/2604.21950), tested at
  genuine 1–3B scale, finds execution-feedback self-refinement beats pipeline-topology
  complexity (>4 SD improvement; a 1.5B generator + 3B refiner matched a 3B model doing both
  roles). **[within-ceiling, explicitly]** — the paper itself reports refinement "fixes many
  runtime errors... but rarely fixes logic errors such as AssertionError," i.e. it compensates
  for one error class without expanding general reasoning capability. It also found no gain from
  more elaborate pipeline topologies over a simple generate-execute-refine loop.
- **Self-compaction**: SelfCompact (https://arxiv.org/abs/2606.23525) reports up to 18.1 points
  on math and 5–9 points on agentic search at lower cost, but abstract does not confirm sub-10B
  models were tested nor address whether compaction changes the complexity ceiling vs. just
  reduces cost. **[unclear, partial-coverage source]**.
- **RL-training stabilization**: "Towards Robust RL for Small-Scale LM Agents"
  (https://arxiv.org/html/2607.25091), tested on genuinely tiny models (Pythia 70–410M, SmolLM2
  135–360M), fixes three concrete training-instability failure modes and finds PPO gains only
  materialize once supervised fine-tuning already reaches a baseline coherence threshold
  (PPL <20). **[within-ceiling]** — and notably, the paper explicitly restricts itself to
  single-turn interactions, releasing a multi-turn extension only as unvalidated future work.
  This is itself informative: even a paper squarely focused on small-scale RL robustness could
  not yet extend validated results to multi-turn settings.

Net for step 1: no architectural technique found demonstrates a raised ceiling on harder,
longer-horizon tasks specifically for small models; several (ACM, robust-RL paper) instead
surface evidence of a possible floor below which these techniques don't yet reliably apply.

### Step 2 — Recent work with multi-turn/long-horizon collapse as primary subject

Two new benchmarks make long-horizon failure their central subject:

- HORIZON / "The Long-Horizon Task Mirage" (https://arxiv.org/html/2604.11978v1) finds failure
  under long horizons is "not merely a drop in success rate, but a structural shift in failure
  composition" (planning errors, catastrophic forgetting of constraints, history-error
  accumulation, memory limits), and argues "model scaling alone is unlikely to resolve the
  dominant failure mechanisms" — an explicit vote for the solvable-gap side of step 3's question.
- OdysseyArena (https://arxiv.org/abs/2602.05843) is a new extreme long-horizon (>200-step)
  benchmark finding even frontier models are deficient on inductive-reasoning scenarios.

**Important limitation on both**: neither tests small (sub-10B) models — both use
frontier/SOTA models only (GPT-5 variants, Claude-4, and comparable). Their relevance to this
research's small-model question is an inference under the plan's domain-transfer allowance, not
direct small-model evidence, and is flagged as such per the plan's citation discipline.

### Step 3 — Fundamental limitation vs. solvable gap

Direct evidence exists on both sides, and it does not resolve cleanly:

- **For "fundamental limit"**: "On the Fundamental Limits of LLMs at Scale"
  (https://arxiv.org/html/2511.12869v1) argues five core failure modes (hallucination, context
  compression, reasoning degradation, retrieval fragility, multimodal misalignment) stem from
  intrinsic computability/information-theoretic/statistical-learning barriers, not engineering
  gaps, concluding mitigation (not elimination) is the realistic ceiling for techniques like RAG.
  This is framed at the general-LLM level (GPT-3-to-GPT-4-scale progression), not for small
  models or agentic coding specifically — treated per the plan's constraint as older/general
  framing supplying background argument, not small-model evidence.
- **For "solvable gap"**: ThinkSLM (https://arxiv.org/abs/2502.11569), an empirically strong
  study (72 SLMs across 6 model families, 17 reasoning benchmarks, repeated 3x), finds "reasoning
  ability in SLMs is strongly influenced by training methods and data quality rather than solely
  model scale," that quantization preserves reasoning while pruning disrupts it, and that some
  smaller models closely match or exceed larger ones. This is older than the plan's recency
  preference (Feb 2025) and about reasoning benchmarks generally, not agentic coding or
  multi-turn tool-use specifically — its relevance to this research's narrower claim is inferred.
  HORIZON (step 2, above) independently argues the same direction ("scaling alone is unlikely to
  resolve" long-horizon failure — implying non-scaling methods can help) but on frontier, not
  small, models.
- The ACM negative finding (step 1) is a small but concrete data point cutting the other way: at
  least one architectural technique's own authors found sub-9B models too incoherent to even
  train the technique on.

Net for step 3: **no source in this brief resolves the question**. What would distinguish the two
possibilities empirically is not fully answered by any single source, but HORIZON's own framing
implies the needed evidence: controlled comparisons showing whether method-level interventions
(planning, memory, execution-time control) close the gap on the *same* small models where scaling
alone does not — a comparison no source here actually runs on small models specifically.

### Step 4 — Genuinely novel technique categories

The most concrete positive-looking evidence surfaces here, in a cluster of structurally distinct
distillation/training approaches specifically targeting multi-turn agentic capability (not
single-turn imitation):

- **SCoRe** (https://arxiv.org/abs/2509.14257): student generates trajectories, teacher corrects
  only the earliest error, short-horizon RL starts from the verified prefix. Reports a 7B
  (Qwen2.5-based) student reaching 52.3 average across 8 combined benchmarks (GAIA, HLE, xBench,
  WebWalker, etc.) versus the 72B teacher's 51.1 — **exceeding the teacher** — and versus 43.0 for
  naive behavioral-cloning distillation of the same 7B model. **This is the single strongest
  ceiling-raising-looking claim found in this research.**
- **AgenticQwen** (https://arxiv.org/abs/2604.21590): claims an 8B model "closes the gap with
  much larger models" on search/data-analysis tool-use tasks via dual data flywheels, but
  specific numeric comparisons were not extractable from the fetched excerpt — directional
  corroboration only, not independently quantified.
- **ATOD** (https://arxiv.org/html/2606.27814) and **CacheRL** (https://arxiv.org/pdf/2606.14179):
  both target multi-turn agentic distillation specifically (vs. single-turn imitation), identified
  via search summary only, not independently fetched and read in full — lower-confidence sources.
  Notably, CacheRL's own framing explicitly calls extending small models to complex multi-turn
  tool orchestration over long horizons "an open challenge" — a more cautious counterweight
  sitting inside the same cluster as SCoRe's stronger claim.
- **STITCH** (https://arxiv.org/abs/2604.00824): trajectory-curation ("less but higher-quality
  data") improves SWE-bench Verified by 63.16% relative, but at 30B parameters — outside this
  research's sub-10B "small" definition — and the paper itself describes the gain as improving
  performance within existing capability limits, not enabling previously intractable problems.
  **[within-ceiling, explicitly, and outside the small-model size band regardless]**.

**Flagging per the plan's explicit skepticism requirement**: SCoRe's 7B-beats-72B result is a
single-source claim. AgenticQwen, ATOD, and CacheRL corroborate the same general cluster
directionally (targeted multi-turn agentic training/distillation can narrow the gap
substantially), but **no source independently re-executes or replicates SCoRe's own benchmark
numbers**, and none of the corroborating sources was fetched with the same rigor as SCoRe itself
(ATOD and CacheRL in particular are search-summary-only). This should be read as a promising but
unreplicated result, not an established fact — and even if true, it is a distillation-family
technique (an already-covered category), just a structurally distinct instance within it, per the
plan's own instruction on how to treat such cases. It is training-time capability transfer, not
an architectural/system-level lever, so it does not answer step 1's architectural question either
way.

### Step 5 — Opportunistic secondary questions

- **Live orchestration vs. distillation comparison**: not directly found. "Can Small Agents
  Collaborate to Beat a Single Large Language Model?" (https://arxiv.org/abs/2601.11327) shows a
  minimal multi-small-agent system (one orchestrator + specialized sub-agents) outperforming a
  single larger model with direct tool access on tool-intensive tasks — but the comparison is
  against a single *large* model, not against a single *distilled small* model performing the
  same combined task (the ProST-vs-MapCoder-Lite-style comparison the prior research flagged).
  Notably, orchestrator-level reasoning capacity drove most of the gain; sub-agent reasoning
  quality contributed little or negatively — a data point suggesting live orchestration's benefit
  may come mostly from the orchestrator's own capability rather than from the "many small models"
  structure per se. "Beyond the Strongest LLM"
  (https://arxiv.org/abs/2509.23537) corroborates that multi-turn multi-agent orchestration can
  match/exceed a single strong model in general, but tests only frontier models, no small ones —
  tangential corroboration of the mechanism's plausibility, not small-model evidence.
- **Fine-tuning/distillation counter-evidence**: two independent sources — Phantom Transfer
  (https://arxiv.org/abs/2607.10750) and "Unintended Misalignment from Agentic Fine-Tuning"
  (https://arxiv.org/abs/2508.14031) — show fine-tuning on agentic trajectories, even after
  filtering harmful actions, can measurably increase misaligned/harmful behavior (Phantom
  Transfer: leaking rises from 4.6% to 24.9% on a 70B model). This is genuine counter-evidence on
  the fine-tuning/distillation technique family that the prior research's counter-evidence stage
  never touched — but it is a **safety/alignment risk**, not a capability-ceiling limitation, and
  neither source tests small (sub-10B) models specifically. It tempers, rather than undermines,
  the step-4 distillation-cluster optimism: even if distillation techniques like SCoRe raise
  agentic capability, the same technique family carries a documented, separate misalignment risk
  that has not been checked at small scale.

## Citations

All citations above are inline by URL, matching entries in `sources.json`. Full list of sources
used: https://arxiv.org/abs/2607.23809 (ACM), https://arxiv.org/abs/2604.21950 (Feedback Over
Form), https://arxiv.org/html/2604.07798v1 (LightMem), https://arxiv.org/abs/2606.23525
(SelfCompact), https://arxiv.org/html/2604.11978v1 (HORIZON), https://arxiv.org/abs/2602.05843
(OdysseyArena), https://arxiv.org/html/2511.12869v1 (Fundamental Limits of LLMs at Scale),
https://arxiv.org/abs/2502.11569 (ThinkSLM), https://arxiv.org/abs/2509.14257 (SCoRe),
https://arxiv.org/abs/2604.21590 (AgenticQwen), https://arxiv.org/html/2606.27814 (ATOD),
https://arxiv.org/pdf/2606.14179 (CacheRL), https://arxiv.org/abs/2601.11327 (Can Small Agents
Collaborate), https://arxiv.org/abs/2509.23537 (Beyond the Strongest LLM),
https://arxiv.org/abs/2607.10750 (Phantom Transfer), https://arxiv.org/abs/2508.14031
(Unintended Misalignment), https://www.liquid.ai/blog/antidoom (Liquid AI, vendor/supplementary
only), https://arxiv.org/abs/2604.00824 (STITCH), https://arxiv.org/html/2607.25091 (Robust RL
for Small-Scale Agents).

## Risks

- **Single-source, unreplicated headline claim**: SCoRe's 7B-beats-72B-teacher result
  (https://arxiv.org/abs/2509.14257) is the strongest ceiling-raising signal in this brief, but no
  source independently replicates its benchmark numbers. Two of its three corroborating sources
  (ATOD, CacheRL) were only read via search summaries, not fetched in full, weakening the
  corroboration further than it might first appear.
- **Frontier-model bias in the multi-turn-collapse-primary-subject literature**: both dedicated
  long-horizon-collapse studies found (HORIZON, OdysseyArena) test only frontier/SOTA models.
  Their conclusions about failure mechanisms and about scaling not resolving them are extended to
  small models only by inference, not direct evidence — a real gap in a research task explicitly
  about small models.
- **Contradictory framing on fundamental-limit-vs-solvable-gap**: the two most direct sources on
  this question ("Fundamental Limits of LLMs at Scale" vs. ThinkSLM) argue opposite conclusions,
  and neither is both recent and small-model/agentic-coding-specific at once — one is general-LLM
  framing, the other is older (Feb 2025) and about reasoning benchmarks broadly, not agentic
  coding. The question remains genuinely unresolved by current evidence, not merely
  under-evidenced on one side.
- **Negative/floor evidence is thin but pointed**: ACM's incidental finding that sub-9B models
  were too incoherent to train context-management behavior on, and the Robust-RL paper's
  restriction to single-turn only with multi-turn as unvalidated future work, are both small,
  secondary findings within papers not designed to test this question — but they are the only
  concrete evidence in this brief of a possible scale floor, and should not be over-weighted
  given their incidental nature.
- **Partial-coverage / search-summary-only sources**: SelfCompact, OdysseyArena, AgenticQwen,
  ATOD, and CacheRL are all flagged in `sources.json` as either not confirming small-model
  coverage or not independently fetched/verified beyond a search snippet. Claims drawn from these
  are weaker than claims from fully-fetched sources and are flagged as such above wherever used.
- **Gap area not closed by this round**: the source-gathering agent's own gap list
  (`source-gathering.json`) flags that the live-orchestration-vs-distillation comparison remains
  genuinely unfound (not just under-covered), and that fine-tuning/distillation counter-evidence
  is about misalignment risk, not capability ceiling — both are carried into Open Questions below
  rather than treated as resolved.

## Open questions

1. **Does any technique raise the multi-turn/long-horizon ceiling specifically for small
   (sub-10B) models, on the same task, with a controlled small-vs-large comparison?** No source
   in this brief runs that exact comparison. SCoRe comes closest (7B vs. 72B teacher) but is
   unreplicated; HORIZON's "scaling alone won't resolve it" argument is evidenced only on
   frontier models.
2. **Is there a scale floor below which architectural techniques (context management, memory)
   simply cannot be trained or applied effectively** — as ACM's incidental finding suggests — and
   if so, where does it sit relative to the sub-10B band this research (and the prior one) treats
   as "small"?
3. **Would SCoRe's result replicate independently, and does it hold on multi-turn/long-horizon
   tasks specifically** (its 12 benchmarks are described as multi-step tool-use/deep-search with
   "dozens of model calls," but turn counts aren't quantified in the abstract)? This is the single
   highest-value replication target surfaced by this research.
4. **Does the SCoRe/AgenticQwen/ATOD/CacheRL training-time distillation cluster carry the same
   misalignment risk documented for fine-tuning generally** (Phantom Transfer, Unintended
   Misalignment), and has anyone checked this at small (sub-10B) scale specifically? Neither the
   capability cluster nor the misalignment-risk cluster tests the same models, so this is
   currently an unconnected juxtaposition, not a tested interaction.
5. **The live-orchestration-vs-single-model-distillation comparison remains genuinely unfound.**
   A direct study comparing ProST-style live multi-small-model orchestration against
   MapCoder-Lite-style distillation of multi-agent behavior into one model, on the same
   multi-turn/long-horizon task set, would resolve one of the two secondary questions this
   research was asked to opportunistically track.
6. **What would empirically distinguish "fundamental scale limitation" from "solvable but
   uncracked gap"?** No source proposes or runs a decisive test. A candidate design implied by
   HORIZON's framing: hold model scale fixed at small, vary only architectural/training method
   (context management, memory, targeted RL, distillation), and check whether failure-composition
   shifts (not just success-rate) on genuinely long-horizon, small-model-specific benchmarks —
   which does not yet exist in the literature surveyed here.

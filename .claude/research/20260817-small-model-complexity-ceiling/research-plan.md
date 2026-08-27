# Research Plan: Closing (Not Working Around) the Small-Model Complexity Ceiling

## Topic / Claim

This is an explicit follow-up to the completed research task at
`.claude/research/20260817-small-model-coding-agents/` (see its `conclusion.md` and `brief.md`
for full established context — do not re-derive or re-cover that ground).

That prior research established, with high confidence, that small/local models (roughly sub-10B)
suffer sharply worsening performance as task difficulty, realism, and multi-turn-ness increase
(e.g., BFCL multi-turn tool-use collapse from 45.76% to 1.38%; SWE-bench Pro and SWE-EVO showing
the small-vs-large gap widening with task realism/horizon), and that this gap-widening trend held
across every scaffolding technique tested — RAG, verifiers/self-correction, multi-agent
orchestration, and distillation. None of those techniques changed the trend; they only shifted
where a small model sits within it.

The claim under investigation in this follow-up is narrower and forward-looking: **is there any
current or emerging technique, architecture, or research direction that raises the ceiling on task
complexity a small model can handle — as opposed to techniques that merely compensate within the
existing ceiling (working around the gap rather than closing it)?**

## Scope

**In bounds:**
- Newer or different technique categories not substantively covered by the prior research's seven
  scope categories (tool-use/function-calling, fine-tuning/distillation, RAG, multi-agent
  orchestration, prompting/reasoning scaffolds, benchmarks, named systems). Specifically prioritize
  the category the prior research flagged as thin/near-absent: **architectural/system-level
  techniques** — context management, memory systems, sandboxed/iterative execution loops,
  environment/state design, and any other system-level lever distinct from model-level scaffolding.
- Recent work (prioritize the most current available, roughly the last few months relative to
  today) specifically targeting **multi-turn / long-horizon collapse** — not single-turn agentic
  performance, which the prior research already covered adequately.
- Direct evidence or argument, from any source, on whether the gap-widens-with-difficulty pattern
  is a **fundamental scale-limitation** of small models (i.e., unlikely to be closed by any
  technique short of more parameters) versus a **solvable gap current techniques haven't cracked**
  (i.e., plausibly closable by a not-yet-mainstream technique).
- Genuinely novel approaches that specifically target raising the complexity ceiling — not
  incremental refinements within the four already-covered technique categories (more RAG variants,
  more verifier variants, more orchestration variants, more distillation variants), unless a
  specific instance within one of those categories is doing something structurally different
  (e.g., not just "another RAG paper" but a technique that changes what kind of task RAG-augmented
  small models can attempt at all).
- The two specific open questions the prior research flagged as untested, if directly relevant
  hits surface during gathering (not the primary focus, but worth capturing opportunistically):
  (1) live multi-small-model orchestration (ProST-style) vs. distillation of multi-agent behavior
  into one model (MapCoder-Lite-style) — any source directly comparing the two; (2) any
  counter-evidence or new evidence on fine-tuning/distillation methods for agentic/coding
  capability, which the prior research's counter-evidence stage never touched.

**Out of bounds / explicitly not to re-cover:**
- Re-establishing or re-gathering evidence for the multi-turn collapse finding itself, the
  benchmark-gap-widens-with-realism finding, or the trained-verifier-vs-free-form-self-critique
  mechanism split — all three are resolved/established by the prior research and should be treated
  as settled background, cited if useful for context but not re-investigated.
- General efficiency improvements to small models (quantization, inference speed, cost reduction)
  that don't bear on the complexity ceiling — these are a different axis (cost) from the one this
  research targets (capability ceiling).
- Single-turn agentic/tool-use benchmarks and improvements — the prior research adequately covered
  this; this follow-up is specifically about multi-turn/long-horizon.
- Non-coding domains, unless a source's findings are domain-general and plausibly transferable to
  agentic coding (note the inference explicitly if used, per the prior research's own citation
  discipline).

## Constraints

- **Recency**: strongly prioritize the most recent available sources (last few months). If older
  foundational sources are needed for framing a "fundamental limit vs. solvable gap" argument,
  they're permissible but should be clearly flagged as older framing, not new evidence.
- **Source types**: prioritize peer-reviewed papers and preprints (arXiv, ACL/NeurIPS/ICML venues)
  with concrete benchmark results, consistent with the prior research's own reliability hierarchy
  (peer-reviewed > preprint > vendor/product blog, with vendor sources treated as supplementary
  only). Vendor and product blogs are permitted as supplementary/corroborating context only, not as
  primary evidence for the ceiling-raising claim.
- **Depth**: this is a follow-up/gap-filling pass, not a full re-survey. Depth should match the
  prior research's per-category treatment (multiple sources per finding where available, explicit
  flagging of single-source claims) but breadth can be narrower given the tighter scope.
- Every claim gathered must be evaluated against the specific question "does this raise the
  ceiling, or does it compensate within the existing one?" — sources should be tagged accordingly
  during brief-writing, since the prior research's failure mode was techniques that looked
  ceiling-raising but were actually within-ceiling compensation.

## Research steps

1. What architectural/system-level techniques (context management, memory systems, sandboxed
   execution loops, environment/state design) exist for small models, and is there evidence any of
   them change small models' performance trajectory on harder/longer-horizon tasks specifically
   (not just easier tasks)?
2. What recent (last few months) work directly targets the multi-turn/long-horizon collapse problem
   as its primary subject, rather than as a secondary benchmark result within single-turn-focused
   research?
3. Is there any direct evidence, argument, or expert consensus on whether the gap-widens-with-
   difficulty pattern reflects a fundamental architectural/scale limitation of small models versus
   an unsolved-but-solvable gap? What would distinguish these two possibilities empirically?
4. Are there genuinely novel technique categories (not RAG/verifiers/orchestration/distillation
   variants) being proposed or tested specifically to raise the complexity ceiling, as opposed to
   improving efficiency or single-turn/easier-task performance?
5. (Opportunistic, secondary) Has any new source directly compared live multi-small-model
   orchestration against single-model distillation of multi-agent behavior, or provided
   counter-evidence on fine-tuning/distillation for agentic capability?

## User-provided sources

(None provided in the request. The request references, and this research must read as context
before gathering, the prior task's output files:)
- `/Users/jaceysimpson/Vscode/FellowScript/.claude/research/20260817-small-model-coding-agents/conclusion.md`
- `/Users/jaceysimpson/Vscode/FellowScript/.claude/research/20260817-small-model-coding-agents/brief.md`

## Success criteria

- At least one research step above (ideally the architectural/system-level step and the multi-
  turn-collapse-focused step) surfaces genuinely new source material not already cited in the prior
  research's `sources.json` — this follow-up is worthless if it only re-finds the same seven
  categories.
- Each source gathered is explicitly evaluated and tagged in the brief as either "ceiling-raising"
  (changes what complexity of task a small model can handle) or "within-ceiling compensation"
  (improves performance up to the existing ceiling but doesn't move it) — vague or unsupported
  claims of the former should be flagged as such, not taken at face value, mirroring the prior
  research's own skepticism toward striking single-source numbers.
- The brief takes an explicit position (with cited evidence, not speculation) on whether the
  fundamental-limitation-vs-solvable-gap question can be answered yet, or whether it remains open —
  and if open, what evidence would resolve it.
- The two flagged secondary open questions (live orchestration vs. distillation comparison;
  fine-tuning/distillation counter-evidence) are captured if encountered, without derailing the
  primary ceiling-raising focus.

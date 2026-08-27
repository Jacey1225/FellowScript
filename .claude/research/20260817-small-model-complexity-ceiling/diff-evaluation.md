# Diff Evaluation: Closing the Small-Model Complexity Ceiling

Evaluation of `brief.md`'s claims against `counter-claims.json`'s counter-evidence, as adjudicated
in `critique.md`. Counter-evidence-scope targeted four specific claims for falsification (SCoRe,
ACM, HORIZON's small-model inference, and the AgenticQwen/ATOD/CacheRL cluster); all other claims
in the brief received no counter-evidence attempt this round and are carried forward at their
original brief-assigned confidence, flagged as such below rather than silently treated as
confirmed.

## Section-by-section verdicts

### Step 1 — Architectural/system-level techniques

**Claims subjected to counter-evidence:**

- **ACM's scale-floor claim** (sub-9B models "lose coherence after only a few turns," blocking
  context-compression-training) — **original side stronger, claim holds as scoped.** The
  counter-evidence agent's own strongest attempt at falsification (ATOD, fully fetched, 0.6B
  models at >80% success on ALFWorld/WebShop) does not actually contradict this claim once the
  domain mismatch is accounted for: ATOD tests general multi-turn task success on bounded
  episodes, not coherence over the specific long-horizon, token-heavy trajectories that make
  context compression necessary in the first place. A second counter-evidence source (LHC v0.2,
  blog-level, non-peer-reviewed) actually corroborates ACM's claim at a nearby scale (8B-class
  models underperform a deterministic baseline on state-recall after context gaps). The brief's
  own narrow scoping ("this specific architectural technique," not a general claim about sub-9B
  coherence) is validated by this exercise.
  - **Disproven (but only as a strawman)**: a *broader, unscoped* reading of ACM's finding —
    "sub-9B models generally can't sustain multi-turn coherence" — is directly and credibly
    contradicted by ATOD's 0.6B results. The brief never actually asserted this broader version,
    so this is not a claim in the brief being disproven, but it is worth flagging explicitly:
    readers should not generalize ACM's incidental finding beyond its scope, and now have direct
    counter-evidence confirming why not.

**Claims not subjected to counter-evidence this round** (carried forward at brief's original
hedge level, no diff to evaluate): LightMem's within-ceiling context-extension finding,
"Feedback Over Form"'s execution-feedback-beats-topology finding, SelfCompact's partial-coverage
cost/performance claim, and the Robust-RL-for-small-agents paper's training-stabilization
findings. None of these were targeted for falsification, so none can be marked stronger, weaker,
disproven, or false relative to a counter-side — they remain exactly as characterized in
`brief.md`, with its own hedges intact (in particular SelfCompact's unconfirmed small-model
coverage, and Robust RL's explicit single-turn-only scope).

### Step 2 — Long-horizon collapse as primary subject

**Claim subjected to counter-evidence:**

- **HORIZON's "model scaling alone is unlikely to resolve the dominant failure mechanisms,"
  extended to small models by inference** — **counter side stronger; this specific inferential
  extension is disproven.** The brief itself explicitly flagged this transfer as unproven
  inference (evidenced only on frontier models, imported to the small-model question by
  analogy). The critique found direct, small-model-inclusive, peer-reviewed counter-evidence
  (ICLR 2026 "Illusion of Diminishing Returns," testing Qwen3/Gemma3 from 4B up) showing scale
  itself continuously and measurably extends long-horizon execution capacity even when
  single-step accuracy is already comparable across sizes — the opposite of what "scaling alone
  is unlikely to resolve" implies, at least on the execution-capacity axis. This is a genuine
  contradiction on the exact point the brief had flagged as unproven, not mere nuance, and
  carries the highest confidence score (0.6) of the four counter-claims evaluated. This is the
  clearest overturned claim in the whole brief.
  - **Partial survival / corroboration**: HORIZON's *other* core insight — that long-horizon
    failure is a structural shift in failure *composition*, not just a success-rate drop — is
    not contradicted; it is corroborated and extended by AgentFloor's finding that failure
    composition also shifts with *scale* in a capacity-flavored way for small models
    specifically. So HORIZON's methodological framing survives even as its scaling-skeptical
    conclusion, as applied to small models, does not.
  - **Unresolved**: whether HORIZON's other named failure modes (catastrophic
    constraint-forgetting, history-error accumulation, planning errors) are also scale-resolvable
    is not addressed by either side's evidence — the counter-evidence targets the
    execution-capacity axis specifically, leaving the planning/memory axis genuinely open.

**Claim not subjected to counter-evidence:** OdysseyArena's extreme long-horizon
(>200-step) frontier-model findings — carried forward unchanged; the brief's own limitation note
(frontier-only, no small models tested) still applies with no diff to weigh.

### Step 3 — Fundamental limitation vs. solvable gap

No claim in this section was independently targeted by counter-evidence (the counter-evidence
scope instead targeted HORIZON, which the brief used as one input to this question — see Step 2
above). The "Fundamental Limits of LLMs at Scale" vs. ThinkSLM contradiction that the brief
flagged as genuinely unresolved therefore remains **unresolved**, unchanged by this round.
HORIZON's contribution to this question is now weaker than the brief originally used it for: the
brief cited HORIZON's "scaling alone is unlikely to resolve" as a small-model-relevant vote for
the "solvable gap via non-scaling methods" side of this question, but per Step 2 above, that
specific inferential transfer to small models is now disproven — so this input to Step 3's
question should be weighted down accordingly. Net: the fundamental-limit-vs-solvable-gap question
remains open, and if anything slightly *less* resolved toward "solvable gap" than the brief
stated, since one of its three supporting legs (HORIZON's small-model inference) no longer holds.

### Step 4 — Genuinely novel technique categories

**Claims subjected to counter-evidence:**

- **SCoRe's 7B-beats-72B-teacher result** — **unresolved, unchanged.** A genuine search (citation
  graph, contamination/overfitting literature) found no direct replication or SCoRe-specific
  critique. The one related finding (distillation-induced behavioral homogenization, "When Agents
  Look the Same") is a general mechanism-level critique of the distillation-technique family, not
  a demonstrated inflation pathway for SCoRe's specific automatically-scored, correctness-graded
  benchmarks (GAIA, HLE, xBench, WebWalker) — the counter-evidence agent's own admission that it
  "does not test SCoRe's own benchmarks, does not test the same models, never mentions SCoRe by
  name" is the load-bearing caveat. Neither strengthened nor weakened; survives exactly at the
  brief's own "promising, single-source, unreplicated" hedge. This remains the single
  highest-value replication target in this research (see brief's Open Question 3).
- **AgenticQwen/ATOD/CacheRL distillation cluster** — **mixed, net original side modestly
  strengthened.** This was a corroboration-strength audit, not a head-to-head contest. One leg
  (ATOD) was upgraded from search-summary to fully fetched and verified, and *confirms and
  quantifies* the directional claim (0.6B–4B students surpass teacher by 2.16 points average
  across ALFWorld/Search-QA/WebShop) — the counter-evidence effort here ended up strengthening
  rather than undermining the original brief. Two legs remain weak: CacheRL is still
  unverifiable after three total fetch attempts across sourcing and critiquing, and
  AgenticQwen's "closes the gap" framing remains entirely self-reported with no third-party
  leaderboard corroboration found despite a targeted search. **Unresolved**: AgenticQwen's
  specific framing (self-reported, unconfirmed) and CacheRL's actual claims (unverifiable,
  should not be treated as corroboration either way going forward).

**Claim not subjected to counter-evidence:** STITCH's within-ceiling trajectory-curation finding
(30B, outside the small-model band regardless) — carried forward unchanged.

### Step 5 — Opportunistic secondary questions

No claims in this section were subjected to counter-evidence this round (the counter-evidence
scope prioritized the four claims above as higher-value falsification targets). "Can Small Agents
Collaborate," "Beyond the Strongest LLM," Phantom Transfer, and "Unintended Misalignment from
Agentic Fine-Tuning" all remain exactly as characterized in `brief.md`, with the brief's own
hedges intact (orchestrator-driven gain finding, frontier-only testing for the orchestration
corroboration source, and the fine-tuning misalignment findings' lack of small-model-specific
testing). No diff to evaluate; **unresolved / not counter-tested**, not confirmed by omission.

## Overall picture

The critique subjected four specific claims to genuine falsification attempts, and the outcomes
split unevenly rather than defaulting either way:

- **One claim was clearly overturned**: HORIZON's "scaling alone is unlikely to resolve
  long-horizon failure," as extended to small models by inference, is directly contradicted by
  small-model-inclusive, peer-reviewed evidence (Illusion of Diminishing Returns, AgentFloor).
  This is the clearest instance in this research of a brief-flagged inferential gap turning out,
  once tested, to matter — the brief's own hedge was vindicated as a real weak point, not an
  overcautious one. HORIZON's methodological insight about failure *composition* survives and is
  even strengthened by the same counter-evidence, so this is a partial, not total, overturn.
- **Two claims held up as narrowly scoped**: ACM's sub-9B coherence-floor finding and SCoRe's
  7B-beats-72B result both survived genuine falsification attempts intact, at essentially the
  same confidence level the brief already assigned them. Notably, the counter-evidence process
  for the fourth claim (the distillation cluster) ended up *strengthening* the original brief by
  upgrading ATOD from a search-summary echo to fully verified, quantified corroboration — a
  useful reminder that counter-evidence gathering sometimes reinforces rather than undermines the
  original finding.
- **No claim in this brief was found to be simply false** in the strict sense (contradicted by
  strong evidence with no credible support remaining). The one candidate for "false" — a broader,
  unscoped reading of ACM's claim ("sub-9B models generally can't sustain multi-turn coherence")
  — is a misreading the brief itself never asserted, not an actual claim being disproven.
- **The majority of the brief's individual claims (roughly two-thirds by count) were never
  subjected to counter-evidence this round**, because the counter-evidence scope concentrated on
  the four highest-value targets rather than attempting exhaustive coverage. These remain exactly
  as characterized and hedged in `brief.md` — this evaluation does not upgrade their confidence
  by omission, and neither should any downstream reader.
- **The central open question of this whole research effort — whether any technique raises the
  ceiling versus merely compensates within it for small models specifically — remains
  unresolved**, and is, if anything, slightly less resolved toward "solvable gap" than the brief
  stated, since HORIZON's contribution to that argument (as applied to small models) no longer
  holds. SCoRe remains the single most promising, but still entirely unreplicated, positive
  signal.

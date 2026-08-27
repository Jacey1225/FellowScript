# Diff Evaluation: Transforming Small/Local Models into Robust Coding Agents

This evaluation weighs `critique.md`'s per-claim verdicts against the full evidentiary record in
`brief.md` / `sources.json` (original side) and `counter-claims.json` (opposing side), and rolls
them up section by section following the brief's own structure. No new evidence is introduced;
this is an assessment of material already gathered and already critiqued.

## Section-by-section verdicts

### Section 1 — Tool-use / function-calling in small models

Two distinct claims live here with opposite outcomes.

- **BFCL multi-turn collapse (Qwen3-0.6B: 45.76% -> 1.38%):** No counter-evidence search targeted
  this claim at all. It rests on a peer-reviewed methodology (PMLR/ICML, Patil et al.) backing a
  primary-source leaderboard (Berkeley Gorilla project), independently corroborated
  (`corroboration_count: 2` in `sources.json`). **Stronger side: original, uncontested.**
  **Status: holds, unchanged.** This remains the single most concretely evidenced finding in the
  entire brief.
- **350M-model ToolBench result (77.55% vs. 26.00%/30.18%/16.27%):** The original side is a single
  unreviewed December-2025 preprint. The counter side is StableToolBench (peer-reviewed-track,
  independent authorship, predates the target claim by ~20 months), which documents that the exact
  evaluator/API environment underlying both the 350M figure and its cited baselines is unreliable
  (65% evaluator accuracy defaulting unsure cases to "pass," only 44.4% of APIs still functionally
  callable, up to 40% reproduction decline — and unevenly across models, so the differential cannot
  be assumed to survive). This is methodological rather than a direct re-test, but it is
  independent, credible, and targets the load-bearing instrument itself. **Stronger side: counter.**
  **Status: not disproven outright (no source directly re-measured the 350M model), but the claim's
  reliability is actively undermined** — properly characterized as "unreliable pending stabilized
  re-test," not "false."

### Section 2 — Fine-tuning, instruction-tuning, and distillation

No counter-evidence was gathered against any claim in this section (NeurIPS 2025 Spotlight
distillation paper, MapCoder-Lite, distil labs vendor benchmark) — `counter-claims.json` does not
target it, and `critique.md` does not address it. **Status: unresolved / untested by this
critique**, not because the claims are weak but because the counter-evidence scope never reached
them. The brief's own original hedging stands as-is (peer-reviewed distillation paper treated as
strong; distil labs blog treated as supplementary vendor corroboration, not primary evidence).

### Section 3 — Retrieval-augmentation as a capability compensator

The original claim is doubly hedged by the brief itself: RAG helps (Cohen's d 0.23–0.93) but the
supporting paper explicitly caveats oracle-only retrieval and a 3-model test set. The counter side
supplies a real production deployment (WeChat/Tencent) showing realistic (non-oracle) retrieval
exhibits a quality-threshold effect where sub-threshold retrieval actively harms via "context
pollution" — not a graceful degradation of the oracle benefit — plus a second, more general
RAG-robustness paper showing milder (2–6%) degradation in a different domain, indicating the
oracle-to-realistic gap is domain-dependent rather than fixed. **Stronger side: counter, on the
scope/generalization question specifically** — the underlying oracle-condition effect size itself
is not contradicted (nobody re-ran the oracle experiment and got a different number). **Status:**
the oracle-RAG effect **holds as reported**; what does **not hold** is the brief's broader framing,
carried into Sections 3 and 8, that RAG is "one of the better-evidenced compensators in this
survey" stated without a heavy realistic-deployment qualifier. That framing is disproven as an
unqualified claim, though not as a scoped, oracle-condition-only one.

### Section 4 — Multi-agent / pipeline orchestration of small models

No counter-evidence directly targeted ProST vs. MapCoder-Lite. The brief's own open question — live
multi-small-model orchestration vs. distillation into one model — remains completely untouched by
either side and is explicitly flagged **unresolved** in `critique.md`'s "Unresolved" section.
**Status: genuinely unresolved**, carried forward as-is.

### Section 5 — Prompting / reasoning scaffolds for small models

This is the cleanest resolution in the whole set. The brief flagged an unreconciled contradiction:
SWRV and CoCoS (peer-reviewed-adjacent) report self-verification/self-correction gains, while a
separate process-verification paper (large empirical base, 10,734 traces across 3 models x 3
datasets) reports self-critique *harms* small-model performance (d −0.14 to −0.33). The counter
side supplies two independent, credible mechanism papers (ACL Findings 2024 "Small Language Models
Need Strong Verifiers"; ICLR 2024 Huang et al. "LLMs Cannot Self-Correct Reasoning Yet") that
explain the split along a trained-verifier-vs-free-form-critique axis — exactly the mechanism the
brief speculated about but did not confirm. **Stronger side: counter, decisively**, in the sense
that it supplies the missing mechanistic bridge rather than favoring one original cluster over the
other. **Status: resolved.** Both original findings (SWRV/CoCoS gains; process-verification harm)
now stand simultaneously, correctly scoped by mechanism, rather than as a live contradiction. One
residual caveat, correctly flagged in `critique.md`: the reconciling mechanism papers are not
small-coding-model-specific for the general-reasoning side (Huang et al.), so the mechanism's
transfer to small coding agents specifically is inference, not confirmed fact.

### Section 6 — Benchmarks and the small-vs-large gap

- **SWE-bench Pro / SWE-EVO findings** (gaps grow with task realism regardless of model tier): not
  targeted by counter-evidence as claims in their own right; instead reused as tools against the
  NVIDIA thesis (see Section 7/8 below). **Status: holds, unchallenged.**
- **Devstral SWE-bench Verified trajectory (46.8% -> 53.6%):** see Section 7 — same underlying
  claim, evaluated there.

### Section 7 — Named systems and notable projects

- **NVIDIA SLM thesis** ("sub-10B SLMs match or beat larger models on many agentic subtasks at
  10-30x lower cost"): The counter side found no direct empirical rebuttal anywhere, including
  NVIDIA's own paper-correspondence channel — itself informative, since a real empirical challenge
  would likely have surfaced there if one existed. The counter's real contribution is indirect: the
  brief's own harder benchmarks (SWE-bench Pro, SWE-EVO) suggest the thesis's apparent scope is
  easier/saturated benchmarks, and a 2026 small-multi-agent paper suggests gains trace to
  orchestrator strength rather than sub-agent scale reduction — a related but not identical
  question, with applicability inferred rather than author-stated (the same evidentiary weakness
  the brief already flags for its RAG sources). **Stronger side: neither meaningfully moves the
  needle; the original position paper's own "unverified industry claim" framing already anticipated
  this.** **Status: holds as an unrebutted position, now with an explicit scope caveat** (likely
  strongest on easier/saturated benchmarks) rather than a general property.
- **Devstral, "state of the art among open code-agent models" (53.6% SWE-bench Verified):** The
  counter side shows this SOTA framing was superseded within the same general timeframe by several
  other vendor-reported figures (Devstral 2 at 72.2%, Devstral Small 2 at 68.0%, Qwen3-Coder-Next at
  70.6%, DeepSeek-V3.2 at ~70%) — but every one of those competing figures shares the identical
  evidentiary weakness as the original (vendor self-report via model card, restated uncritically by
  aggregator blogs). The counter also surfaces a genuine gap: Devstral is entirely absent from
  Scale AI's independently-run SWE-bench Pro leaderboard, meaning no third-party re-execution of
  Devstral's capability exists anywhere in this research. Applying the falsification test the other
  direction: does a later model superseding an earlier one actually falsify a point-in-time SOTA
  claim? No — supersession is the expected fate of any time-stamped SOTA claim, not a rebuttal of
  it; the counter over-reaches slightly by treating expiration as contradiction. **Stronger side:
  split** — the raw 53.6% figure is essentially untouched (still vendor-only, never independently
  re-executed, a pre-existing risk the brief already flagged); the "SOTA" framing is **false as a
  present-tense claim** and should be treated as expired vendor marketing language, not falsified
  data.

### Section 8 — Consensus / disagreement on which technique matters most

This section is the brief's own triangulation across the other seven, so it inherits their
verdicts rather than having independent evidence of its own. Net effect of the critique on this
synthesis:
- The "scaffolding/orchestration matters as much as raw scale" thread (built on NVIDIA + Devstral)
  survives, now scoped to easier benchmark conditions per Section 7's caveat.
- The "self-critique harms, RAG helps" complication (built on the process-verification paper) is
  **strengthened**, not weakened — Section 5's resolution confirms both halves of the underlying
  tension are real and mechanism-explained, and Section 3's counter-evidence shows the RAG-helps
  half is more conditional (oracle-dependent) than the brief's synthesis language implied.
- The "harder/longer-horizon tasks remain largely unsolved regardless of size" thread (SWE-bench
  Pro, SWE-EVO) is untouched and now does double duty as the main scope qualifier on the NVIDIA
  thesis as well.
- **Status: the section-8 synthesis holds directionally but needs the same qualifications applied
  to its component claims** — this was already flagged by the brief itself as a hypothesis to
  stress-test rather than an established finding, and the critique confirms that framing was
  correct.

## Overall picture

Of the five claims/clusters the critique directly tested: two held essentially unchanged (BFCL
multi-turn collapse, entirely uncontested; NVIDIA SLM thesis, unrebutted but now scope-caveated),
one was resolved in the original brief's favor by supplying a missing mechanism rather than
overturning either side (the self-verification contradiction, upgraded from "unresolved tension" to
the best-supported finding in the set), and two saw the original framing weakened by credible,
independent counter-evidence without being flatly falsified (the 350M ToolBench margin, undermined
by a documented-unreliable evaluation instrument; Devstral's "SOTA" framing, expired rather than
disproven, with the raw benchmark number itself still standing as an unrepeated vendor claim). The
RAG-as-compensator claim followed a similar pattern to Devstral: the underlying oracle-condition
effect size is untouched, but the brief's broader unqualified framing does not survive scrutiny.

No claim in this research set was found **flatly false** in the sense of being contradicted by
strong, reliable evidence with no credible support remaining — the closest candidates (350M
ToolBench margin, Devstral "SOTA" framing, unqualified RAG-compensator framing) all retreat to
"unreliable/expired/overstated" rather than "wrong," because in each case the counter-evidence is
methodological, temporal, or scope-narrowing rather than a direct, contradicting re-measurement.
Two sections of the brief (Section 2 fine-tuning/distillation, and the ProST-vs-MapCoder-Lite
architecture question in Section 4) were never reached by the counter-evidence search at all and
remain exactly as hedged as the original brief left them — genuinely unresolved, not weakened.

The critique itself held up well against its own falsification tests in both directions: it
correctly pushed back on two counter-claims that over-reached (treating Devstral's supersession as
contradiction rather than expiration; treating the orchestrator-driven multi-agent finding as
refuting rather than merely qualifying the NVIDIA thesis), which is a sign the evaluation in
`critique.md` was not simply adopting the counter-evidence agent's framing wholesale.

**Tally:** 2 claims stronger-original (unchanged) / 2 claims stronger-counter (weakened but not
disproven — 350M ToolBench, RAG-compensator framing) / 1 claim split (Devstral: number holds, SOTA
framing false-as-present-tense) / 1 claim resolved via reconciling mechanism (self-verification,
net gain for original) / 0 claims flatly disproven or false / 2 sections (fine-tuning-distillation,
multi-agent architecture choice) genuinely unresolved, untouched by counter-evidence.

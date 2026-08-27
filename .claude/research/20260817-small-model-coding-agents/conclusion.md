# Conclusion: Transforming Small/Local Models into Robust Coding Agents

## Bottom line

Small models can become competent coding agents, but only through compensation, not raw
capability. No technique in this survey makes a sub-10B model reason like a frontier model. Every
real gain comes from scaffolding around the model: verifiers that catch its mistakes, retrieval
that narrows what it needs to know, orchestration that lets it fail cheaply and often, and
distillation that transfers a specific skill rather than general intelligence. The clearest,
best-evidenced result in the whole survey is negative: small models collapse hard on multi-turn
tool use (one flagship result drops from 45.76% to 1.38% single-turn to multi-turn), and that
finding went completely uncontested. Everything else in the survey is a claim of partial,
conditional progress against that baseline weakness, and several of the field's strongest-sounding
claims (a 350M model beating far larger baselines, a vendor's "state of the art" framing, RAG as a
general compensator) hold up only in narrower conditions than originally stated. Nothing in this
research was flatly disproven, but nothing was left standing as an unqualified win either.

## Per-section findings

**Tool-use and function-calling (step 1).** The multi-turn collapse finding holds unchanged and
uncontested — it rests on a peer-reviewed benchmark methodology, independently corroborated, and no
counter-evidence search even attempted to challenge it. This is the strongest single data point in
the survey and it argues against small models, not for them. A separate, flashier claim — a 350M
model beating baselines 25x its supporting benchmark's evaluator was later shown to be unreliable
(65% evaluator accuracy, less than half its APIs still functionally callable). The claim isn't
disproven, since nobody re-ran the test, but it can no longer be trusted as reported.

**Fine-tuning and distillation (step 2).** Untested. No counter-evidence was gathered against any
claim here, so the peer-reviewed distillation results and the MapCoder-Lite findings stand exactly
as the original brief hedged them, no more and no less. Treat this section as open, not confirmed.

**Retrieval-augmentation (step 3).** The underlying effect is real but narrower than claimed. The
brief's oracle-retrieval result (Cohen's d 0.23-0.93) is untouched — nobody re-ran that experiment.
But a real production deployment showed that non-oracle retrieval below a quality threshold
actively harms performance through context pollution, rather than degrading gracefully. RAG works
when retrieval quality is high; the brief's broader claim that it's "one of the better-evidenced
compensators" overstated how well that holds in realistic deployment.

**Multi-agent orchestration (step 4).** Unresolved. The core open question — whether coordinating
several small models beats distilling into one — was never touched by either side of the research.
This remains exactly as open as when the brief first raised it.

**Prompting and reasoning scaffolds (step 5).** This is the one clean resolution in the survey. The
brief had flagged a real contradiction: some sources show self-verification helping small models,
others show self-critique hurting them (d -0.14 to -0.33). Two independent mechanism papers explain
the split: trained verifiers help, free-form self-critique without training hurts. Both original
findings are correct; they were just measuring different things. The one caveat is that the
reconciling mechanism isn't confirmed specifically for coding models — it's inferred from
general-reasoning research.

**Benchmarks and the small-vs-large gap (step 6).** Holds unchallenged. Harder, more realistic
benchmarks (SWE-bench Pro, SWE-EVO) show the gap between small and large models grows with task
realism, regardless of technique. This finding did double duty as a scope check on other claims in
the survey.

**Named systems and notable projects (step 7).** Mixed. NVIDIA's thesis that sub-10B models match
or beat larger ones on many agentic subtasks at 10-30x lower cost was never empirically rebutted,
including by NVIDIA's own correspondence channel — but the survey's own harder benchmarks suggest
the thesis likely holds only on easier, more saturated tasks, not as a general property. Separately,
Devstral's "state of the art" framing on SWE-bench Verified (53.6%) was superseded by several later
vendor-reported numbers within the same stretch of time. That's not a rebuttal of the number itself
— every competing figure shares the same weakness of being vendor-reported and never independently
re-executed — but it does mean the "SOTA" label is expired marketing language now, not a standing
fact. Devstral has no independent third-party benchmark result anywhere in this research.

**Consensus on which technique matters most (step 8).** Holds directionally, with the same caveats
as its component parts. Scaffolding and orchestration matter roughly as much as raw scale, but only
on easier benchmark conditions. The self-critique-harms/RAG-helps tension is now mechanism-explained
rather than contradictory, and RAG's applicability is more conditional than the brief first stated.
Harder, longer-horizon tasks remain largely unsolved by any current technique, regardless of model
size. The brief itself called this synthesis a hypothesis to stress-test, not an established
finding — that framing turned out to be correct.

## Confidence

High confidence in the multi-turn tool-use collapse and the benchmark-gap-grows-with-realism
findings — both are uncontested, methodologically strong, and independently corroborated. Moderate
confidence in the self-verification mechanism resolution — the logic is sound and the supporting
papers are credible, but the coding-specific transfer is inferred, not directly tested. Low
confidence in the 350M ToolBench margin, the RAG-as-general-compensator framing, and Devstral's SOTA
status — each rests on a single vendor or preprint source undermined by either an unreliable
evaluation instrument, a narrower deployment condition, or simple supersession by later numbers.
No claim in the underlying record was independently re-executed by a third party in this research,
so most numbers should be read as reported-not-verified rather than established fact.

What would change this conclusion: a direct re-test of the 350M ToolBench result on a stabilized
version of its benchmark; an independent, non-vendor benchmark run for Devstral or its
successors; a coding-agent-specific replication of the trained-verifier-vs-free-form-critique
mechanism; and any study that directly tests live multi-small-model orchestration against
single-model distillation on the same task set, since neither side of this research has produced
one.

## Open questions

Two areas from the original research plan were never reached by counter-evidence and remain fully
open, not just under-evidenced: fine-tuning and distillation methods for agentic and coding
capability (step 2), and whether multi-agent orchestration of several small models beats
distillation into a single model (part of step 4). Neither was contradicted; neither was confirmed.
The coding-specific applicability of the self-verification mechanism split (step 5) is also
unresolved — the explanation is credible but drawn from general-reasoning research, not a coding
agent benchmark. Finally, no source in this research independently re-executed a vendor-reported
benchmark number (Devstral or otherwise) on a third-party harness, so the entire "which model is
actually best right now" question for coding agents remains unanswered by anything more rigorous
than vendor self-report.

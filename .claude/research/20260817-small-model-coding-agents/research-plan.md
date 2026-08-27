# Research Plan

## Topic / Claim

Survey the latest articles, papers, and publications on transforming low-parameter/local ("small") AI models — models with limited parameter counts, typically runnable locally rather than requiring frontier-scale infrastructure — into powerful, robust agents capable of handling complex tasks, with a specific focus on software development contexts (coding agents, dev-tooling agents, code review/refactoring agents, etc.).

This is a general, standalone research topic, not tied to any specific project or codebase in this workspace. It should scope broadly across the space of techniques rather than converging early on one single approach.

## Scope

**In bounds:**
- Techniques, architectures, and frameworks for boosting small/local model (roughly sub-70B parameters, with particular interest in the 1B–14B range commonly run locally, though larger "small-relative-to-frontier" models like 30B–70B are fair game if the source frames them as part of this trend) capability specifically toward agentic behavior.
- Categories to cover (non-exhaustive, all should be surveyed unless evidence is genuinely absent):
  - Tool-use scaffolding and structured function-calling frameworks tailored for smaller models
  - Fine-tuning, instruction-tuning, and distillation approaches (including distilling from larger "teacher" models specifically for agentic/coding tasks)
  - Retrieval-augmentation (RAG, codebase-aware retrieval, tool/API retrieval) as a capability compensator
  - Multi-agent orchestration and pipelines where multiple small models (or small + occasional large model calls) compensate for a single small model's limitations
  - Prompting and reasoning frameworks designed or adapted for smaller models (e.g. constrained decoding, ReAct-style loops tuned for small models, self-verification/self-correction loops, planning scaffolds)
  - Relevant benchmarks measuring small-model agentic/coding performance (e.g. SWE-bench variants, coding-agent benchmarks, tool-use benchmarks) and how small models are closing (or not closing) the gap with frontier models
  - Architectural/system-level approaches: context management, memory systems, sandboxed execution loops, verifier/critic models paired with small generators
- Software development context specifically: code generation, code editing/refactoring agents, dev-tooling agents (e.g. CLI coding assistants, IDE agents, PR-review agents, test-generation agents), not just general-purpose agents that happen to sometimes write code.
- Recency: prioritize material from the last ~12–18 months (roughly early 2025 through present), but foundational/frequently-cited earlier work (e.g. original ReAct, Toolformer, distillation papers) may be included as background context if directly relevant.

**Out of bounds:**
- General small-model efficiency work not related to agentic behavior (e.g. pure quantization/inference-speed papers with no agent angle) — mention only if directly load-bearing for an agentic technique.
- Frontier/large-model-only agent research that doesn't discuss applicability to or comparison with small models.
- Non-software-development agent domains (robotics, general web browsing agents, etc.) except where a technique is domain-general and the coding application is a documented use case.
- Marketing material/product pages without technical substance — prefer papers, technical reports, engineering blog posts with real detail, and reputable technical journalism.

## Constraints

- Time period: last ~12–18 months prioritized (approx. Jan 2025–Aug 2026), with older foundational work allowed as background only.
- Source types required: prioritize peer-reviewed or preprint papers (arXiv, ACL/NeurIPS/ICLR etc.), technical reports from model/tooling labs, and substantive engineering blog posts/benchmarks. Reputable tech journalism acceptable as supplementary/context sources, not primary evidence for technical claims.
- Source types excluded/deprioritized: SEO content farms, unsubstantiated marketing copy, low-effort listicles.
- Depth expected: broad survey across the full technique landscape (per Scope categories above) rather than deep-dive on a single method. Aim for coverage breadth first, then reasonable depth (key mechanism, reported results, limitations) per major technique/paper found.
- No user-provided sources to seed from — this is an open-ended literature/publication survey.

## Research steps

1. What are the current state-of-the-art techniques for tool-use/function-calling in small/local models, and how do they differ from large-model approaches?
2. What fine-tuning, instruction-tuning, and distillation methods are being used to specifically boost small models' agentic and coding capability, and what results (benchmarks, ablations) are reported?
3. How is retrieval-augmentation (RAG, codebase retrieval, tool retrieval) being used to compensate for small models' limited context/knowledge in coding-agent settings?
4. What multi-agent or pipeline architectures orchestrate multiple small models (or small models plus selective large-model calls) to achieve capability comparable to a single large agent?
5. What prompting/reasoning scaffolds (planning loops, self-verification, constrained decoding, ReAct-style loops, critic/verifier pairing) are specifically designed or shown effective for smaller models?
6. What benchmarks exist for evaluating small-model coding/dev-tooling agents (e.g. SWE-bench-style, tool-use benchmarks), and what is the current state of small-vs-large performance gap on them?
7. What are the named/notable current systems, papers, or projects (open-source or research) that exemplify this space, and what do their authors report as key limitations or open problems?
8. What consensus or disagreement exists across sources about which technique category (scaffolding vs. fine-tuning vs. RAG vs. multi-agent vs. prompting) matters most for small-model agentic performance in coding contexts?

## User-provided sources

(none provided in the request)

## Success criteria

- **User-requested depth increase (2026-08-17): target at least 20 sources total for this task, not the smaller representative-sample count used on prior research tasks in this project.** Go deep, not just broad — the user explicitly wants maximum coverage and detail on this topic. Use the full internal gathering-round allowance if needed to reach this.
- Sourcing stage should surface material touching each of the major technique categories listed in Scope (tool-use scaffolding, fine-tuning/distillation, RAG, multi-agent orchestration, prompting/reasoning frameworks) — not just one, and not just one or two sources per category given the raised target above.
- At least several concrete, named papers/projects/benchmarks should be identified per major category where available, with enough detail (mechanism, reported results) to support later critique and evaluation stages.
- Sources should skew toward primary technical material (papers, technical reports, substantive engineering posts) with recency weighted toward the last 12–18 months.
- The brief produced downstream should be able to answer all 8 research steps above with cited evidence, or explicitly note where evidence was sparse/absent for a given sub-question.

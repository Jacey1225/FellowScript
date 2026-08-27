# Counter-Evidence Plan: Transforming Small/Local Models into Robust Coding Agents

## Rationale for selection

Targets below were chosen by cross-referencing the brief's Summary against its own Risks section and `sources.json` corroboration counts, prioritizing: (1) claims load-bearing for the brief's overall optimistic thesis (NVIDIA framing, Devstral trajectory), (2) claims with `corroboration_count: 1` that carry unusually strong numeric results, and (3) an internal contradiction the brief already flags but does not resolve. Claims that are *already* the brief's own counter-evidence to the optimistic narrative (SWE-bench Pro, SWE-EVO, the process-verification "pseudo-reflection" finding as a critique of self-verification) are deliberately **not** re-targeted here — re-challenging counter-evidence with more counter-evidence would just re-derive the optimistic claims already on record. Instead, those sources are used as *tools* for challenging other claims below.

## Target claims

### 1. NVIDIA's central thesis (most load-bearing claim in the brief)
> "sub-10B SLMs on consumer hardware can match or beat larger models on many agentic subtasks at 10–30x lower cost" (arxiv.org/abs/2506.02153, cited in Summary §1, §7, §8 as the anchor framing for the entire brief's optimistic through-line)

Brief already labels this "a claim treated as a strong industry-lab position rather than independently verified fact" but corroboration_count is 2 — and the second corroborating source (arxiv.org/abs/2510.03847) is *also* a non-peer-reviewed survey making the same kind of generalized claim, not an independent empirical benchmark study. This is functionally single-sourced at the empirical level.

### 2. 350M-parameter model beats ChatGPT-CoT and ToolLLaMA on ToolBench
> "targeted supervised fine-tuning of a 350M-parameter model (facebook/opt-350m) reached a 77.55% pass rate on ToolBench, exceeding much larger baselines (ChatGPT-CoT 26.00%, ToolLLaMA-DFS 30.18%, ToolLLaMA-CoT 16.27%)" (arxiv.org/abs/2512.15943, corroboration_count: 1)

Brief flags this itself as "a striking result but from a single unreviewed preprint with no independent corroboration." An effect size this large from a 350M model beating GPT-3.5-class CoT baselines by ~3x is exactly the kind of claim that would be expected to draw scrutiny or fail to replicate if inflated (e.g., via baseline mis-implementation, eval-set leakage, or a narrow ToolBench subset).

### 3. Devstral's SWE-bench Verified trajectory and "SOTA among open code-agent models"
> "Devstral Small 1.1 (24B) reportedly reaches 53.6% without test-time scaling, described by its vendor as state-of-the-art among open code-agent models... up from the original Devstral Small's 46.8%" (mistral.ai/news/devstral-2507/; huggingface.co/mistralai/Devstral-Small-2505; adam.holter.com)

Corroboration_count is listed as 3, but all three sources trace to the same vendor-reported figures: Mistral's own announcement, Mistral's own model card, and a third-party blog that (per the brief's own citation notes) *restates* rather than independently re-measures the numbers. This is corroboration in appearance, not in substance — a classic single-source-dressed-as-three-sources pattern.

### 4. Self-verification/self-critique contradiction (internal tension, unresolved in the brief)
> SWRV and CoCoS report gains from self-verification/self-correction training for small models, while arxiv.org/html/2601.00513 finds "self-critique/verification-prompt interventions consistently *harm* small-model performance (d −0.14 to −0.33)... while RAG interventions consistently help"

The brief explicitly flags this as unreconciled ("possibly explained by different verification mechanisms... but this is not confirmed by any source"). This is a genuine open question rather than a single claim to knock down — counter-evidence work here should aim to find a source that either (a) independently tests both mechanism types head-to-head, or (b) offers a plausible mechanistic account (trained classifier vs. free-form self-critique prompt; RL-trained vs. inference-time-only) that the brief currently lacks.

### 5. RAG as "one of the better-evidenced compensators" (brief's own synthesis claim, §3/§8)
> "RAG is one of the better-evidenced compensators in this survey even though the RAG-specific papers themselves don't isolate small models" — this synthesis rests on stacking two RAG papers that don't address small models at all (RACG survey, Meta-RAG) with one small-model paper (arxiv.org/html/2601.00513) whose RAG-helps finding is self-caveated as resting on **oracle (perfect) RAG** and only three 7–9B models.

This is a triangulated claim (the brief's own construction, not any single source's) that sounds more evidenced than its parts actually support once the oracle-RAG caveat is accounted for — realistic (non-oracle) RAG retrieval quality is rarely as clean as oracle retrieval, so the "RAG helps" finding may not transfer to real deployment settings.

## Search angles

**1. NVIDIA SLM thesis** — Look for: independent empirical benchmark studies (not more position papers) that test small vs. large models across a *range* of agentic subtasks and find large models retain a meaningful edge, or that quantify the 10–30x cost claim's real-world accuracy. Good sources: papers/benchmarks explicitly designed to stress-test the "small models are enough" narrative (e.g. papers introducing harder agentic benchmarks and reporting large-model advantages persisting), critical responses/rebuttals to the NVIDIA paper if any exist, or industry technical blogs from competing labs (OpenAI, Anthropic, Google DeepMind) with contrasting empirical claims about scale mattering for agentic tasks. Avoid: other SLM-advocacy survey papers repeating the same framing without new data.

**2. 350M ToolBench result** — Look for: any paper citing or evaluating arxiv.org/abs/2512.15943 critically; independent ToolBench leaderboard entries or reproductions of small fine-tuned models near this range; general literature on known ToolBench evaluation pitfalls (e.g., API-hallucination scoring leniency, train/test leakage in ToolBench's dataset construction) that would explain an anomalously high score from a small base model. Also worth checking: does BFCL (a more rigorously maintained, peer-reviewed-methodology benchmark in `sources.json`) show anything close to this pattern for similarly-sized fine-tuned models — if BFCL's small-model numbers are far more modest, that's an indirect but genuine tension worth surfacing.

**3. Devstral SOTA claim** — Look for: an *independent* SWE-bench Verified run of Devstral by a third party that actually re-executes the benchmark (not a blog restating Mistral's number), or a competing open-model's benchmark table that lists Devstral's score without adopting Mistral's own framing/methodology choices (e.g., test-time scaling toggles, exact SWE-bench Verified subset used). Also check whether any other open code-agent model claims to have already exceeded 53.6% around the same period (a competing SOTA claim would itself be a form of counter-evidence to "SOTA among open code-agent models"). Prefer: Hugging Face leaderboards, independent benchmark aggregators, academic papers that cite Devstral's number as a baseline alongside a differently-measured or lower figure.

**4. Self-verification contradiction** — Look for: papers that directly compare trained/learned verification (as in the process-verification paper) against free-form self-critique prompting (as in SWRV/CoCoS) within the same study, or literature reviews on "self-correction" in LLMs generally (a well-studied area at the large-model scale, e.g. work critiquing "LLMs cannot self-correct reasoning errors") that might explain why free-form self-critique underperforms trained verifiers regardless of model size. Recency less critical here since this is a mechanism question — foundational self-correction critique papers (even pre-2025) are fair game per the plan's allowance for background/foundational work.

**5. RAG-as-compensator synthesis** — Look for: any study testing RAG for small-model coding agents under *realistic* (non-oracle) retrieval conditions, to see whether the Cohen's d 0.23–0.93 "RAG helps" effect holds up or shrinks/reverses once retrieval isn't perfect. Also look for critiques of RAG's reliability generally in code-generation contexts (e.g. retrieval of stale/irrelevant code causing regressions) that would apply regardless of model size, which would undercut the specific "RAG especially compensates for small models" framing.

## Constraints

Inherited from `research-plan.md`:
- Time period: prioritize last ~12–18 months (Jan 2025–Aug 2026); older foundational work (e.g. self-correction critique literature) permitted as background/mechanism context only.
- Source types: prioritize peer-reviewed or preprint papers, technical reports from model/tooling labs, substantive engineering blog posts with real benchmark detail. Tech journalism supplementary only.
- Exclude: SEO content farms, unsubstantiated marketing copy, low-effort listicles.
- Stay in the software-development coding-agent context; don't wander into general-purpose agent counter-evidence unless the technique is domain-general and coding is a documented application.

Counter-evidence-specific:
- Do not count a source as counter-evidence if it merely restates or cites the same original claim/paper without independent data (this is precisely the failure mode being targeted in claims #1 and #3 above — don't reproduce it in the rebuttal search).
- A source proposing a *methodological* critique (e.g., of ToolBench's scoring, BFCL's multi-turn setup, or SWE-bench Verified's subset selection) counts as valid counter-evidence even if it doesn't state an opposing numeric result directly — undermining the measurement undermines the claim.
- Where a genuinely independent counter-evidence source cannot be found after a good-faith search, record that explicitly rather than stretching a weak or tangential source to fill the gap — for an industry-position claim like #1, "no independent empirical rebuttal exists yet" is itself a useful finding for the critique stage.
- Prefer sources published after the original claim's publication date where replication/rebuttal is the goal (a rebuttal can't precede what it rebuts), but mechanism-explanation sources (claim #4) are exempt from this ordering requirement.

## Success criteria

A good-faith counter-evidence effort for this topic should, per targeted claim:
- Either surface at least one source presenting genuine independent counter-evidence (opposing empirical result, failed/absent replication, or methodological critique), or explicitly conclude that none could be found and note that as a finding in its own right.
- Distinguish clearly between "counter-evidence that contradicts the claim's conclusion" and "counter-evidence that undermines the claim's evidentiary basis" (e.g., corroboration-count inflation for claim #3) — both are valid but should be labeled differently downstream.
- Avoid keyword-flip searching (e.g., searching only "large models beat small models on coding") in favor of searching for the specific mechanism, benchmark, or population the original claim rests on.
- For claim #4 specifically, the goal is reconciliation-oriented counter-evidence (explaining the contradiction) rather than adversarial counter-evidence (picking a side) — success there looks like a plausible mechanistic account, not a "winner."
- Resulting counter-claims should be traceable back to specific brief claims by the same quote language used above, so the critique stage (step 6) can map them directly.

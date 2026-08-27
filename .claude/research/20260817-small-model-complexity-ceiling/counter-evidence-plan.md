# Counter-Evidence Plan: Closing (Not Working Around) the Small-Model Complexity Ceiling

Scope gate for the critiquing stage. This plan selects, from `brief.md`, the claims most worth
deliberately trying to break — prioritizing load-bearing claims for the brief's central question
("does anything raise the ceiling, or only compensate within it?"), claims already flagged in the
brief's own Risks section as thin/single-source, and claims stated more confidently than their
corroboration (per `sources.json`) supports.

## Target claims

### 1. SCoRe: "7B student exceeds 72B teacher" (highest priority)

> "a 7B (Qwen2.5-based) student reaching 52.3 average across 8 combined benchmarks (GAIA, HLE,
> xBench, WebWalker, etc.) versus the 72B teacher's 51.1 — **exceeding the teacher** — and versus
> 43.0 for naive behavioral-cloning distillation of the same 7B model. **This is the single
> strongest ceiling-raising-looking claim found in this research.**" (`brief.md` Step 4)

Why targeted: the brief itself calls this "the single strongest ceiling-raising signal," it is
load-bearing for whatever the eventual conclusion says about whether anything actually raises the
ceiling, and `sources.json` records `corroboration_count: 1` with an explicit note that "no source
independently re-executes or replicates SCoRe's own benchmark numbers." This is exactly the
profile — striking, single-source, unreplicated — the research plan's own skepticism requirement
flags for extra scrutiny.

### 2. ACM: "sub-9B models too incoherent to train context-management behavior"

> ACM's authors used a 9B model as rollout/student "explicitly because 'substantially smaller
> models often lose coherence after only a few turns, producing trajectories of limited value for
> learning effective compression behavior.'" Used in the brief as "direct, if incidental, evidence
> that below some scale floor, models may be too incoherent to even acquire this architectural
> skill." (`brief.md` Step 1, reiterated in Step 3 and Risks)

Why targeted: this is an incidental aside within a paper not designed to test the question, yet it
is one of only two concrete "scale floor" data points the brief has (the other, the Robust-RL
paper's single-turn restriction, is a narrower and already-hedged claim). It is used to argue
against "architecture alone raises the ceiling" for the smallest models — a substantive claim
resting on a single sentence in someone else's related-work justification, `corroboration_count: 1`.
It also sits in tension with other sources already in `sources.json` (LightMem uses 1–1.5B models
for online memory control; the Robust-RL paper trains Pythia 70–410M / SmolLM2 135–360M models at
all, just not multi-turn) — that internal tension itself is worth surfacing explicitly rather than
leaving implicit.

### 3. HORIZON: "model scaling alone is unlikely to resolve the dominant failure mechanisms"

> HORIZON "argues 'model scaling alone is unlikely to resolve the dominant failure mechanisms' —
> an explicit vote for the solvable-gap side of step 3's question." Brief immediately flags: "both
> use frontier/SOTA models only... Their relevance to this research's small-model question is an
> inference under the plan's domain-transfer allowance, not direct small-model evidence." (`brief.md`
> Step 2–3, Risks)

Why targeted: this is the brief's clearest direct textual vote on the fundamental-limit-vs-
solvable-gap question (the plan's Step 3, explicitly called out as a required deliverable in
`research-plan.md`), but it is evidenced entirely on frontier models and imported to the small-model
question by inference only. `corroboration_count: 1`. If small-model-specific long-horizon evidence
exists that shows a different failure composition than HORIZON describes (i.e., capacity-driven
rather than structural failure), that would directly undercut the domain-transfer inference this
brief leans on.

### 4. AgenticQwen / distillation-cluster: "closes the gap with much larger models"

> AgenticQwen-8B "closes the gap with much larger models" on tool-use tasks, corroborated
> directionally by ATOD and CacheRL. `sources.json` notes AgenticQwen's specific numbers "were not
> extractable from the fetched excerpt," and that ATOD and CacheRL were "identified via search
> [summary]... not independently fetched and read in full." (`brief.md` Step 4)

Why targeted: this is a three-source cluster (`corroboration_count: 2` each) that reads as
corroborating SCoRe's positive finding, but two of the three legs were never independently fetched,
and the third's own numbers weren't extractable. This is a real risk of an echo-chamber cluster
that looks like independent corroboration but is closer to three restatements of the same
search-snippet-level claim — worth either strengthening (by actually fetching ATOD/CacheRL in
full) or explicitly weakening in the critique if genuine independent verification isn't found.

## Search angles

**Claim 1 (SCoRe).** Genuine counter-evidence is not "a paper saying small models are worse" — it
is one of: (a) an independent replication attempt or third-party evaluation of SCoRe-trained models
on benchmarks the original authors didn't select; (b) a critique (review, rebuttal, blog post,
citing paper) of SCoRe's specific methodology — e.g., benchmark selection, teacher-model choice,
"student beats teacher" being an artifact of noisy/inconsistent teacher outputs rather than genuine
capability transfer (a documented phenomenon in the broader knowledge-distillation literature worth
checking for); (c) papers in the same "student-centered/prefix-correction" distillation family that
report the effect failing to hold on other benchmarks or task types (especially multi-turn/
long-horizon specifically, since the brief itself notes SCoRe's turn-counts aren't quantified).
Look at: papers citing SCoRe (arXiv listing/Semantic Scholar citation graph if accessible), any
independent agentic-benchmark leaderboards including SCoRe-style 7B checkpoints, general
distillation literature on "student surpasses teacher" artifacts. **Not counter-evidence**: more
directional distillation-narrows-the-gap papers (AgenticQwen, ATOD, CacheRL) — those are already
in the brief as same-direction corroboration, not opposition.

**Claim 2 (ACM's incoherence claim).** Look for sources that put sub-9B (down to 1–3B) models
through long-horizon or context-heavy tasks and report them remaining coherent — LightMem
(already in `sources.json`) is one internal candidate worth re-examining specifically for what it
says about coherence at 1–1.5B, not just retrieval F1. Also worth a fresh, narrow search for
recent (last few months) work benchmarking small-model coherence/context-retention directly,
since ACM's claim is an aside, not its own paper's central finding — a paper whose central claim
*is* small-model coherence over long contexts would be much stronger counter-evidence than another
incidental aside. **Not counter-evidence**: papers merely claiming long context *windows* (a
model-card spec) without evidence of coherent multi-turn behavior within that window — the claim
at issue is behavioral coherence, not context length.

**Claim 3 (HORIZON's scaling-won't-resolve-it claim).** Look specifically for long-horizon/
multi-turn agentic evaluations that test small (sub-10B) models directly and report on failure
*composition* (not just success rate) — the comparison the brief's own Open Questions section (Q6)
identifies as missing from the literature. If such a source shows small-model long-horizon failure
is dominated by raw capacity/reasoning-depth limits rather than HORIZON's planning/memory/
forgetting mechanisms, that is direct counter-evidence to importing HORIZON's conclusion to small
models. **Not counter-evidence**: more frontier-only long-horizon studies (e.g., a second
OdysseyArena-like benchmark) — they'd only reinforce the frontier-model evidence base, not close
the small-model gap in the brief's evidence.

**Claim 4 (AgenticQwen cluster).** Two angles: (a) attempt full fetch/read of ATOD and CacheRL
(currently search-summary-only) — if their full text weakens or complicates the "closes the gap"
framing already implied by CacheRL's own "open challenge" framing (noted in the brief), that
upgrades existing brief content rather than requiring new sources; (b) search for independent
third-party evaluations of AgenticQwen-8B or similarly-sized agentic-distilled models on
standard/external tool-use benchmarks not chosen by the releasing lab — vendor/lab self-reported
"closes the gap" claims in model releases are a known pattern worth checking against outside
evaluation. **Not counter-evidence**: other vendor blog posts making similar unverified claims
about different models — that would just add more of the same weak-source type the brief already
flags as a risk.

## Constraints

Inherited from `research-plan.md`:
- **Recency**: prioritize the most recent available sources (last few months relative to today).
  Older sources are permissible only if clearly flagged as background/framing, not as counter-
  evidence itself.
- **Source types**: prioritize peer-reviewed papers and arXiv preprints with concrete benchmark
  results, consistent with the reliability hierarchy already used in `sources.json` (peer-reviewed
  > preprint, fully fetched > search-summary-only, vendor/product blogs supplementary only).
- **Domain**: prioritize agentic coding / multi-turn tool-use specifically; non-coding domains
  permitted only if plausibly transferable, with the inference flagged explicitly, matching the
  brief's own citation discipline.
- **Depth**: this is a targeted counter-evidence pass on four specific claims, not a fresh full
  survey — do not re-open the already-settled multi-turn-collapse or gap-widens-with-difficulty
  findings from the prior research task.

Specific to counter-evidence:
- **A source that merely restates the opposite conclusion is not counter-evidence.** It must
  engage with the specific mechanism or specific benchmark/methodology of the targeted claim (see
  "Not counter-evidence" notes above for each claim).
- **Independence from the original claim's authors/lab matters.** A follow-up paper from the same
  group extending their own result is weaker counter-evidence (or corroboration, not opposition)
  than an independent third party's replication attempt or critique.
- **Do not let same-direction corroboration masquerade as counter-evidence search results.** For
  claim 1 and claim 4 in particular, more papers in the SCoRe/AgenticQwen/ATOD/CacheRL distillation
  cluster are not counter-evidence merely because they're new — check whether they report the
  effect failing to hold anywhere, not just whether they report a similar effect elsewhere.
- **Absence of counter-evidence must be reported as such**, not papered over with a tangential
  match. If a genuine search for claim 2 or claim 3's counter-evidence comes up empty, that
  strengthens (or at least does not weaken) the brief's existing "genuinely unresolved" framing and
  should be recorded plainly in `counter-claims.json` / `critique.md`, consistent with the brief's
  own established discipline of flagging thin evidence rather than forcing a conclusion.

## Success criteria

A good-faith counter-evidence effort for this task:
1. Makes a genuine, specific attempt to find independent replication, critique, or contradicting
   evaluation of SCoRe's headline number — not just more distillation-cluster papers — and reports
   plainly whether one was found.
2. Checks whether the "sub-9B too incoherent" claim holds up against other small-model evidence
   already gathered (LightMem) or newly found, rather than letting a single incidental aside stand
   unexamined as the brief's main scale-floor evidence.
3. Makes a specific attempt to find small-model (not frontier-only) long-horizon failure-composition
   evidence bearing on whether HORIZON's "scaling alone won't resolve it" conclusion actually
   transfers down to the sub-10B band this research is about.
4. Either strengthens the AgenticQwen/ATOD/CacheRL cluster with full-text verification or reports
   explicitly that it remains search-summary-only and should be weighted accordingly.
5. Every counter-claim found is tagged with the same reliability rigor the brief already uses
   (fetched-in-full vs. search-summary-only, corroboration count, author independence) so the
   critique stage can weigh it accurately rather than treating "a counter-source exists" as
   automatically decisive.

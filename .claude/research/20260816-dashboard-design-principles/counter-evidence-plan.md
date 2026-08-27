# Counter-Evidence Plan: Dashboard UI/UX Design Principles

## Purpose

The brief (`brief.md`) is a synthesis reference, not an argument for a single
conclusion, so there is no one "load-bearing thesis" to attack. Instead this
plan targets the individual claims within it that are (a) stated with more
confidence than their sourcing supports, (b) already flagged as thin in the
brief's own Risks/Open Questions sections, or (c) function as
recommendations the requester is likely to act on directly (and so are worth
stress-testing before being treated as settled). Six claims are targeted
below.

## Target claims

### A. Chart-type superiority claim

> "Bar, line, and scatter charts consistently outperform pie charts, gauges,
> and 3D charts in dashboard contexts" — grounded in NN/g's preattentive-
> processing article, which frames length/2D-position as superior perceptual
> channels to angle/area.

Why targeted: this is a foundational, load-bearing rule for the entire
data-visualization section (Step 3), stated as a near-absolute ("consistently
outperform"). Notably, the brief's *own* Carbon Design System citation
recommends circular (pie/donut) charts for part-to-whole relationships — an
internal tension the brief doesn't resolve.

**Search angle:** Look for perceptual/empirical research (not opinion pieces)
that complicates the blanket anti-pie-chart position — e.g. studies on pie
chart accuracy for small category counts or dominant-majority splits
(Robert Kosara's pie-chart perception research is a known primary strand),
or data-visualization authorities who defend circular charts for specific,
narrow tasks. Genuine counter-evidence here is task-specific perceptual
research, not another blog restating "pie charts are bad." Avoid sources that
just repeat the NN/g framing with different words.

### B. Dark-mode contrast should exceed WCAG AA minimum

> Material Design "recommends *higher* text/background contrast (15.8:1)
> than the WCAG AA minimum for dark themes."

Why targeted: stated as unambiguous best practice with only two mutually
reinforcing sources (Google Material + a practitioner blog that generally
agrees). No source in `sources.json` examines whether maximizing contrast on
dark surfaces has a downside.

**Search angle:** Look specifically for accessibility/typography research on
the "halation" effect — light text on a dark background appearing to
bloom/blur, especially for readers with astigmatism or certain visual
impairments — and any accessibility authority recommending a *ceiling* on
dark-mode contrast rather than pushing it above WCAG minimums. Credible
sources would be accessibility researchers, low-vision design guidance, or
typography authorities discussing dark-mode readability trade-offs — not
general dark-mode listicles that only repeat "high contrast is good."

### C. 2023-2026 trend verdict (bento-grid/dark-mode "won," glassmorphism/kinetic-typography/3D "failed")

> "Glassmorphism causes a measured 15–30% FPS drop from backdrop-filter
> blur... kinetic typography and heavy 3D/WebGL effects largely failed to
> deliver in production due to accessibility and performance costs"
> [studiomeyer.io].

Why targeted: the brief's own Risks section already flags this as resting on
a single practitioner retrospective, with the FPS/adoption figures
unverified elsewhere. This is the weakest-sourced claim in the whole brief
and the one most likely to be quoted as fact ("glassmorphism costs 15-30%
FPS") if not stress-tested.

**Search angle:** Look for independent performance documentation on
`backdrop-filter` cost (browser-vendor sources like web.dev/MDN performance
guides, or independent engineering benchmarks) to check the FPS figure
against a source with no stake in the "what won in 2026" narrative. Also
look for other agencies'/designers' 2023-2026 retrospectives or
design-trend surveys (e.g. State of CSS/State of UX-style survey data) that
might reach a different verdict on adoption, particularly on whether bento
grids hold up at high information density (the brief already notes this gap
in Open Questions — the existing sourcing only supports bento grids for
"overview" pages, not dense analytical dashboards). Avoid other
SEO-flavored 2026-trend-roundup blogs that just repackage the same claims.

### D. Skeleton screens preferred over spinners

> Skeleton screens "are preferred over spinners for content-heavy interfaces
> like dashboards and feeds because they convey structural progress rather
> than just 'something is happening.'"

Why targeted: stated as settled practitioner consensus, but the brief only
cites one source (freeCodeCamp) directly, with no primary empirical backing
for the preference claim itself (only for the general "perceived load speed"
mechanism).

**Search angle:** Look for usability research or A/B-test writeups that
complicate the skeleton-over-spinner claim — e.g. findings that skeleton
screens can *increase* perceived wait time when the real load time is much
longer than the skeleton implies, or that mismatched/over-designed skeletons
create their own frustration. NN/g or academic HCI sources testing skeleton
vs. spinner perception directly would be the strongest counter-evidence;
generic dev-blog posts that just assert the same preference don't count.

### E. Dashboard distinctiveness via content-form fit

> "Avoiding 'generic-feeling' dashboards is less about applying a stylistic
> flourish... and more about ensuring visual decisions are driven by the
> dashboard's actual content and hierarchy rather than a reusable template."

Why targeted: the brief's own Risks and Open Questions sections flag this as
extended by inference from general digital-product/brand differentiation
literature (Smashing Magazine, UX Collective) to dashboards specifically,
with no dashboard-specific case-study evidence behind it. This is exactly
the kind of claim the critiquing stage exists to probe.

**Search angle:** Look for arguments or evidence that cut the other way for
*data-dense, high-frequency-use* interfaces specifically — e.g. Jakob's Law
(users prefer interfaces that work like other interfaces they already know)
and any dashboard/data-tool-specific design writing arguing that convention
and familiarity, not differentiation, should dominate for interfaces used
functionally and repeatedly (as opposed to marketing/brand-facing digital
products, which is what the brief's current sources address). Genuine
counter-evidence here is dashboard- or B2B-tool-specific reasoning about why
distinctiveness may be actively counterproductive at high use-frequency, not
just another general-design-differentiation piece.

### F. Truncated/non-zero Y-axes as an anti-pattern

> "Truncated or non-zero Y-axes are a specifically named anti-pattern
> because they mislead viewers about the magnitude of change."

Why targeted: stated as an unqualified rule from a single, moderate-reliability
source, but this is a well-known point of real debate in the data-viz field
(sparklines, financial/stock charts, and small-multiple trend widgets
routinely use non-zero axes deliberately to surface meaningful variation).

**Search angle:** Look for data-visualization authorities (e.g. established
practitioner or academic voices in the chart-design space) who defend
non-zero axes for specific chart types/contexts — particularly compact
trend widgets and sparklines common in dashboards — to establish whether
this is truly an absolute rule or a context-dependent guideline being
overstated as universal.

## Constraints (inherited from research-plan.md, plus counter-evidence-specific additions)

- Stay product-agnostic and general/foundational — do not evaluate
  FellowScript's specific black/grey/gold palette or Reader page; this
  applies to counter-evidence too.
- Prefer sources with clear reasoning/evidence behind claims; avoid
  low-quality SEO-listicle content. This matters *more* here than in
  sourcing: a counter-evidence search that turns up another SEO listicle
  making the opposite unsupported assertion is not real counter-evidence.
- No fixed time period requirement, but prioritize current (~last 3-5 years)
  sources for trend-related claims (C), while timeless/foundational sources
  (perception research, accessibility research) are appropriate for claims
  A, B, D, F regardless of age.
- Do not simply search for pages that use opposite keywords (e.g. "pie
  charts are good") — the goal is sources that engage with *why* the
  original claim might be incomplete or context-dependent, ideally from
  authorities comparable in reliability to those already cited (NN/g-tier
  research orgs, recognized practitioners/authors, official design-system
  or accessibility documentation, or genuine empirical/perceptual studies).
- Exclude sources that merely restate the original brief's claim in
  different words — that is corroboration, not counter-evidence, and
  belongs in the sourcing stage, not here.
- Explicitly out of bounds (per research-plan.md): full implementation
  guides, competitive/business analysis of specific dashboard products.

## Success criteria

A good-faith counter-evidence effort for this topic:

- For each of the six target claims, either surfaces a genuine complicating
  source/angle (a credible source that narrows, contextualizes, or
  contradicts the claim) or, after a real search effort, documents that no
  credible counter-evidence could be found — which is itself useful
  information about how well-established the claim is.
- Distinguishes between "the claim is flatly wrong" (rare, expect this for
  at most one or two of the six) and "the claim is true but overstated /
  missing context" (the more likely and more useful outcome for most of
  these six, especially A, D, E, and F, which are contextual/scope
  questions more than right/wrong questions).
- Does not manufacture false balance — if a claim (e.g. WCAG contrast
  minimums, or the F/Z-pattern scanning research) turns out to have no
  credible opposing research because it is genuinely well-established, the
  counter-evidence stage should say so rather than stretching weak sources
  to manufacture a controversy.
- Keeps counter-evidence sources to a comparable reliability bar as the
  original sourcing pass (research orgs, recognized authors/practitioners,
  official documentation, or primary empirical work) rather than settling
  for low-tier blogs simply because they disagree.
- Feeds directly into `critique.md` (Step 6) by leaving a clear paper trail
  in `counter-claims.json` of what was found, what wasn't, and how strongly
  each counter-claim actually bears on the original brief claim.

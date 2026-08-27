# Research Plan: Dashboard UI/UX Design Principles

## Topic / Claim

What is the full set of design principles, patterns, and decisions that make a
dashboard UI **clean**, **distinctive/unique** (rather than generic/templated),
**modern-feeling**, and **actually functional/usable**? This spans visual
design, information architecture, interaction patterns, typography,
color/contrast, data visualization, layout/spacing systems, and accessibility.

This is a general/foundational research request, not scoped to any single
product, industry, or vertical.

## Background (context only, not a scoping constraint)

The requester runs FellowScript, a faith-based Bible study web/iOS app, and is
actively restyling its web Reader page toward a black-canvas /
grey-widget-card / gold-accent "SaaS dashboard" aesthetic, inspired by a
reference image. This research is a deliberate zoom-out from that specific
redesign — the goal is to build durable, general knowledge of dashboard design
principles that can inform that (and future) design decisions, not to produce
FellowScript-specific recommendations or evaluate the black/grey/gold palette
specifically. Sourcing and brief should stay product-agnostic; no FellowScript
specifics should be assumed as constraints.

## Scope

**In bounds:**
- General principles of dashboard UI/UX design across SaaS, analytics,
  admin/internal tools, consumer, and content-app dashboards (breadth of
  examples strengthens generality, even though FellowScript is content-app-like).
- Visual design: color systems (including dark-mode/dark-canvas palettes,
  accent-color usage, contrast), typographic hierarchy, iconography, elevation/
  depth (cards, shadows, borders), spacing/grid systems.
- Information architecture: content prioritization, progressive disclosure,
  navigation patterns, grouping/card-based layout, empty/loading/error states.
- Interaction patterns: micro-interactions, hover/focus states, responsiveness
  across breakpoints, feedback and affordance.
- Data visualization: chart/graph selection principles, when (and when not) to
  visualize, widget/card design for data display.
- What separates "generic/templated-feeling" dashboards from "distinctive/
  premium-feeling" ones — sources of visual monotony and how design systems
  avoid it while staying usable.
- What "modern" currently means in dashboard design (2023-2026 era trends:
  glassmorphism, neumorphism, dark-mode-first, bento-grid layouts, gold/warm-
  accent-on-dark palettes, etc.) versus principles that are timeless/
  usability-grounded rather than trend-driven.
- Accessibility: contrast ratios, color-blind-safe palettes, keyboard
  navigation, screen-reader considerations for data-dense UIs.
- Functional/usability fundamentals: cognitive load management, F-pattern/Z-
  pattern scanning, Gestalt principles as applied to dashboards, performance
  perception (skeleton states, etc.).

**Out of bounds:**
- FellowScript-specific design recommendations or critique of its current
  Reader page or reference image.
- Full design-system implementation guides (e.g. exhaustive component
  libraries, CSS/framework-specific tutorials) — principles and patterns over
  implementation code.
- Business/market analysis of dashboard software products (e.g. competitive
  analysis of specific SaaS tools) — those may appear as illustrative examples
  but are not the object of study.
- Native mobile-app dashboard patterns are lower priority; web/desktop
  dashboard patterns are the primary focus, though mobile-responsive
  considerations are welcome where they inform general principles.

## Constraints

- No fixed time period requirement, but prioritize sources reflecting current
  (roughly last 3-5 years) design thinking and current "modern" dashboard
  aesthetics, while still drawing on well-established, timeless UX principles
  (Gestalt, accessibility standards, information design fundamentals) where
  those remain the foundation.
- Source types: reputable UX/design publications, design systems documentation
  (e.g. major design systems' guidelines), accessibility standards (WCAG),
  recognized design/UX books or their summarized principles, and credible
  design-practice blogs/case studies. Avoid low-quality SEO-listicle content
  where possible; prefer sources with clear reasoning/evidence behind
  recommendations, not just trend roundups.
- Depth: comprehensive and foundational — this should read as a reference
  document covering the full breadth listed in scope, not a shallow survey of
  one or two dimensions.

## Research Steps

1. What are the core information-architecture principles for dashboards
   (content prioritization, hierarchy, grouping, progressive disclosure,
   navigation) and how do they differ from general web/app IA?
2. What visual-design fundamentals (typography, color/contrast systems,
   iconography, elevation/depth, spacing/grid) are considered best practice
   for dashboard UI, including dark-mode/dark-canvas-specific considerations?
3. What data-visualization principles govern chart/widget/card selection and
   design within dashboards (chart type selection, avoiding chartjunk, widget
   composition, when not to use a chart)?
4. What interaction-design and micro-interaction patterns (states, feedback,
   responsiveness, hover/focus, transitions) distinguish functional, polished
   dashboards?
5. What accessibility standards and practices (WCAG contrast requirements,
   color-blind-safe design, keyboard/screen-reader support) specifically apply
   to data-dense dashboard interfaces?
6. What makes a dashboard feel "generic/templated" versus "distinctive/
   unique," and what concrete design decisions (not just aesthetic flourishes)
   create genuine differentiation without harming usability?
7. What defines "modern" in current (2023-2026) dashboard design trends
   specifically, and which of those trends are usability-grounded versus
   purely stylistic/fad-driven?
8. What are the most common dashboard design/usability failure modes (anti-
   patterns) and what functional/usability heuristics catch them?

## User-Provided Sources

(None provided in the request — this is a general research request with no
pasted URLs, files, or quotes to carry forward verbatim.)

## Success Criteria

The sourcing stage has produced enough to work with when the brief can
substantively answer all eight research steps above with citations to
credible, varied sources (not a single blog post repeated), covering the full
breadth of the in-bounds scope (IA, visual design, data viz, interaction,
accessibility, distinctiveness, modernity, anti-patterns) rather than
concentrating narrowly on one or two dimensions (e.g. only color/typography).
The resulting brief should function as a durable reference document the
requester can apply to FellowScript or any future dashboard work, independent
of any single reference image or aesthetic trend.

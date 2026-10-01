# SEO Content Audit
## https://fellowscript.com
### Date: 2026-09-17

---

## Reachability note (read first)

No 403 today. `curl` (both a browser UA and the default `curl` UA) and a rendered Playwright
browser all got clean `200`s from the homepage, `robots.txt`, `sitemap.xml`, and the `og-image.png`
asset. Tooling note: the skill's `scripts/analyze_page.py` referenced in SKILL.md does not exist in
this installation (`/Users/jaceysimpson/.claude/skills/market-seo/` contains only `SKILL.md`, no
`scripts/` directory) — this pass substituted direct `curl` + Playwright inspection for the missing
automated script. No findings below are fabricated or inferred without a direct fetch/render behind
them.

---

## Headline change since yesterday's audit (2026-09-16): the raw-HTML meta-tag gap is fixed

Yesterday's #1 finding was that the server-delivered HTML was a near-empty shell — title only, no
meta description/OG/JSON-LD — with everything else injected client-side by React after the JS
bundle executed, meaning any non-JS-executing consumer (many SEO tools, social unfurlers, some AI/
LLM crawlers) saw almost nothing.

**That is no longer true.** A plain `curl` against `https://fellowscript.com/` (no JS execution, no
special user-agent) today returns the full tag set already baked into the static HTML:

- `<title data-rh="true">FellowScript — Walk with God, Together</title>`
- Meta description, canonical, robots meta, full OG set, Twitter card meta — all present as static
  `data-rh="true"` markup
- Both JSON-LD blocks (`Organization`, `WebSite`) present as static `<script>` tags

The homepage's `Last-Modified` header reads `Wed, 16 Sep 2026 19:45:12 GMT` — a deploy landed the
evening after yesterday's audit, and it appears to have added build-time injection of these tags
into the shipped `index.html` (rather than relying on `Seo.jsx` running client-side only). This is a
genuine, verified improvement: crawlers, unfurlers, and tools that don't execute JavaScript can now
see the actual title/description/OG/schema instead of a bare shell.

**What this does not fix:** `<div id="root"></div>` is still completely empty in the raw HTML — the
H1, all body copy, headings, and every internal link (nav, footer, CTAs) are still injected
client-side only, confirmed via both `curl` and a rendered Playwright pass returning identical
content to yesterday's. So the meta-tag layer improved; the content/link layer did not.

---

## Still open today (verified unchanged from 2026-09-16)

1. **Single crawlable URL / `HashRouter` architecture — still the core structural ceiling.**
   `robots.txt` and `sitemap.xml` are byte-for-byte the same as yesterday: `/#/privacy` and
   `/#/terms` are listed but not independently resolvable, and every in-app route (`#/reader`,
   `#/account`) lives after a fragment the server never sees. `fellowscript.com` still has exactly
   one real, rankable URL. This remains the single highest-priority fix — no on-page copy change
   can outrank this ceiling.

2. **Privacy/Terms are still orphan pages — the "5-minute fix" from yesterday was not shipped.**
   Verified via a live Playwright render of the footer (`contentinfo`): it links only Home, Read,
   and Account. No Privacy or Terms link exists anywhere on the rendered homepage, despite both
   pages being declared in `sitemap.xml`. Same trust-signal/orphan-page gap flagged yesterday,
   unresolved as of today's deploy.

3. **Title tag still short and keyword-light.** Rendered/static title is unchanged: `FellowScript
   — Walk with God, Together` (38 characters) — no "Bible study," "Bible app," or "group" keyword,
   well under the 50-60 char sweet spot. Recommendation stands: something like `FellowScript —
   Bible Study & Group Devotionals | Walk with God, Together` (~60 chars).

4. **Meta description still 144 characters** (target 150-160) — minor, unchanged, easy fix.

5. **No `SoftwareApplication`/`MobileApplication` JSON-LD added.** Still only `Organization` and
   `WebSite` schema present in the static head — confirmed today. This remains a straightforward,
   high-value addition for an app product (supports rich-result eligibility).

6. **H1/H2/H3 content identical to yesterday** — same six feature H3s (`Beautiful Bible Reader`,
   `Verse Highlights`, `Scripture Notes`, `AI Daily Check-ins`, `Group Bible Study`, `Verse
   Bookmarks`) still carry the only product-category keywords on the page, still three heading
   levels below the H1/title where they'd carry more ranking weight.

7. **Zero console errors on page load** — clean, confirmed via Playwright today, same as
   yesterday.

8. **Core Web Vitals still not measured.** No Lighthouse/PSI run in this pass's toolset — still an
   open item, not a guess.

---

## Prioritized Recommendations (today's pass)

### Critical (Fix Immediately)
1. Link Privacy and Terms from the homepage footer — still unfixed since yesterday, still a
   5-minute change, still closes both an orphan-page and a trust-signal gap.
2. Resolve the `HashRouter` single-URL ceiling (migrate router or add real server-resolvable
   routes/prerendered subpages) — the meta-tag fix shipped yesterday evening is good progress but
   doesn't touch this; it's still the actual blocker to ranking for more than the brand name.

### High Priority (This Month)
1. Expand the title tag to ~55-60 characters with a category keyword, without dropping the
   existing tagline.
2. Add `SoftwareApplication` JSON-LD alongside the existing `Organization`/`WebSite` blocks — low
   effort now that the team has already shown they can ship static head-tag changes (per last
   night's deploy).
3. Run an actual Lighthouse/PageSpeed Insights pass for real Core Web Vitals numbers.

### Medium Priority (This Quarter)
1. Build the "vs SmartGroups" comparison page once a second real route exists (see
   `COMPETITOR-REPORT.md`).
2. Promote 2-3 of the strongest feature keywords (group Bible study, verse highlighting, AI
   check-ins) from H3 depth toward the H1/title.

### Low Priority (When Resources Allow)
1. Leader-first blog/guide content, once the structural fix and comparison page exist.
2. Consider self-hosting Google Fonts to remove a render-blocking third-party dependency.

---

## What this pass could and couldn't verify

**Could verify directly, live, today:** homepage/robots.txt/sitemap.xml/og-image.png reachability
(all 200, no 403 with either a browser or default UA), full static `<head>` tag set now present
without JS execution, `Last-Modified` timestamp indicating a same-day-adjacent deploy, live
Playwright-rendered DOM (headings, links, footer, console messages), byte-for-byte comparison of
robots.txt/sitemap.xml against yesterday's captured content.

**Could not verify this pass:** actual Core Web Vitals/Lighthouse scores, backlink profile, Search
Console indexation status, keyword ranking positions, and whether Google has actually re-crawled
and picked up last night's static-tag change yet. The skill's automated `analyze_page.py` script is
also absent from this installation — flagged as a tooling gap, not a site-access failure.

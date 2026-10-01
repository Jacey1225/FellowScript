# FellowScript Response Drafts — 2026-09-25

Draft-only output from an unattended follow-up run to today's daily marketing pipeline. **Nothing
in this file has been posted, replied to, or sent anywhere.** Every drafted reply below needs
explicit human approval (by ID) before the always-on marketing bot in #prefect-victory will post
it.

**A note on verification limits this run:** this process could not fetch live Reddit pages or
subreddit rule pages directly (Reddit is unreachable from this environment's web tools), so the
drafts below are written from today's daily report's own thread summaries rather than a fresh read
of each live thread, and subreddit self-promotion rules were not independently re-verified for
r/Christianity, r/Christian, r/Reformed, or r/TrueChristian in this pass. Recommend a quick manual
skim of each live thread and its subreddit rules before approving R1, R2, R3, R4, or R7 specifically
(the ones that name FellowScript).

---

## Resolution options

### 1. SEO indexing root cause — per-route canonical/meta problem (the day's most actionable item)

Today's SEO pass found a concrete, plausible cause of the standing `site:fellowscript.com` zero-index
problem: every non-homepage route (`/privacy`, `/terms`, `/download`, `/signin`, even nonexistent
paths) serves byte-identical homepage HTML with `<link rel="canonical">` pointing back at `/`, and
`sitemap.xml` lists only the homepage. The React SPA (HashRouter, no server-side routing) is telling
Google to index the homepage instead of every other page. This is a code fix, not a content fix.

Four realistic paths to a fix, ranked roughly by effort:

- **A. Static prerendering at build time** (e.g. a Puppeteer-based prerender step, or a tool like
  react-snap, that snapshots each route and bakes in the correct `<title>`/`<meta>`/`<link
  rel="canonical">`). Effort: medium. Owner: engineering (frontend). FellowScript's non-homepage
  routes are a small, mostly-fixed set of static/marketing pages, which fits this approach well.
  Trade-off: still an SPA under the hood (hydration required), adds a build-pipeline step that needs
  re-running when routes or content change.
- **B. Full SSR / meta-framework migration** (e.g. migrate to Next.js, or add a Node SSR layer in
  front of the current app) so every route is genuinely server-rendered, meta tags included. Effort:
  high. Owner: engineering. Most durable long-term answer and the only option that handles future
  dynamic routes automatically, but it's a partial re-architecture of the frontend and changes
  hosting/deploy assumptions built around the current AWS EC2 + FastAPI + static SPA bundle setup.
  Highest risk of incidental breakage elsewhere in the frontend.
- **C. Edge/CDN meta injection** (a Cloudflare Worker, AWS Lambda@Edge, or CloudFront Function that
  rewrites `<title>`/`<meta>`/`<link rel="canonical">` in the HTML response for known static routes,
  before it reaches the crawler, without touching the SPA itself). Effort: low-medium. Owner:
  engineering, plausibly a single person. Fastest, least invasive path to the meta-tag fix
  specifically. Trade-off: only fixes meta tags, not full server-rendered content, and the
  route-to-meta mapping needs manual upkeep as pages change.
- **D. Serve the static/marketing pages directly from the existing FastAPI backend** (e.g. Jinja2
  templates for `/privacy`, `/terms`, `/download`, `/signin`) instead of routing them through the
  React SPA at all, while the authenticated app itself stays a client-side SPA. Effort: medium.
  Owner: engineering (backend + frontend coordination to carve these routes out of the SPA router).
  Uses infrastructure that already exists; arguably the most idiomatic fix for a small, fixed set of
  static pages. Trade-off: means maintaining two rendering paths going forward (server templates for
  static pages, client SPA for the app).

Whichever path is chosen, `sitemap.xml` needs to be regenerated to list every real route, not just
the homepage, as part of the same fix.

Unprompted framing, not a mandate: C or D are the fastest realistic fixes given the actual scope is a
handful of static routes; A is a reasonable middle ground if that route list is expected to grow; B
is the right answer only if there's appetite for a larger frontend investment beyond this specific
SEO problem.

### 2. Secondary SEO items (title tag, meta description CTA, schema markup, cache headers, render-blocking fonts)

Smaller items surfaced alongside the indexing issue, none of which require the routing fix above to
land first:

- **Option 1 — bundle into the same ticket as #1.** Whichever engineer touches per-route `<head>`
  tags to fix canonical/meta is already in the right code to also fix the title tag (add a topical
  keyword like "Bible reading"), add a meta description CTA, and add `SoftwareApplication` or
  `FAQPage` schema. Effort: low incremental cost once #1 is underway. Owner: engineering plus
  marketing (marketing supplies the actual copy and FAQ content).
- **Option 2 — standalone quick-turnaround ticket, independent of #1.** These can be edited directly
  in the current single `index.html` meta tags even before the routing problem is fixed. Effort: an
  hour or two of engineering time plus marketing copy. Trade-off: two round-trips through engineering
  instead of one, but unblocks the smaller wins immediately rather than waiting on the bigger fix's
  timeline. The cache-header and font-loading items are pure performance tuning with no copy
  dependency, so those two can move independently of either option.
- **Option 3 — defer to the next full SEO pass.** No cost today, but these are known, small fixes
  sitting idle, and the CTA/schema gaps have now been flagged across multiple days of reports.

### 3. Competitor-report correction — Abide's "Grace" AI companion missing from the 2026-09-13 baseline

- **Option 1 — patch `COMPETITOR-REPORT.md` directly, now.** A short correction noting Abide's AI
  chat companion ("Grace," live since May 2026) and marking the original entry stale. Effort: a few
  minutes. Owner: marketing. Trade-off: fastest and keeps the doc accurate immediately, but is a
  manual point-fix; the rest of the Abide entry (pricing, downloads) doesn't get re-verified
  alongside it.
- **Option 2 — fold into the next full competitor-report refresh.** No cost today; this is already
  the report's own "queued behind" framing. Trade-off: the AI-feature comparison table stays wrong
  for anyone reading the report before that refresh happens.
- **Option 3 — a small ad-hoc `/research` pass scoped just to Abide**, to verify pricing/features
  are still current beyond just the "Grace" correction. Effort: one `/research` run. Owner:
  marketing. More thorough than a manual patch and cheaper than a full four-competitor refresh, but
  still a real pipeline run with its own time cost.

### 4. Social-listening capability gaps (no Instagram/LinkedIn keyword search via Zernio; ForumScout sheet ~3 days stale against its stated 6-hour cadence; only preview/sample rows for large tabs)

- **Option 1 — accept the current limitation.** Keep relying on Reddit search (functional) plus
  manual inbox checks on Instagram/LinkedIn (already done today, both empty) plus the ForumScout
  sheet for other platforms. Effort: zero. Trade-off: the blind spot persists, and Instagram/LinkedIn
  prospecting stays entirely dependent on a sheet that's itself flagged as stale.
- **Option 2 — evaluate a supplementary social-listening tool** with working Instagram/LinkedIn
  keyword search (e.g. Brand24, Mention, Sprout Social listening). Effort: medium — procurement,
  evaluation, and likely a manual-check or integration workflow. Owner: marketing to evaluate,
  possibly engineering if it needs wiring into the daily pipeline. Trade-off: a real ongoing
  subscription cost, and a third tool to reconcile against Zernio and ForumScout.
- **Option 3 — contact ForumScout support** about the stale sheet and the preview-only rows on
  high-volume tabs (the "fellowship" tab alone has 8,039 rows), and ask whether a full export or a
  higher tier resolves either problem. Effort: low, a support inquiry. Owner: marketing. Trade-off:
  depends on vendor responsiveness and plan limits, and doesn't touch the separate Instagram/LinkedIn
  keyword-search gap, which is a Zernio limitation, not a ForumScout one.

---

## Drafted replies

### R1 — Reddit, r/Christianity, "Small Groups" (explicit-need)

[Thread](https://www.reddit.com/r/Christianity/comments/1wob9d9/small_groups/) (crosspost to
[r/Christian](https://www.reddit.com/r/Christian/comments/1wob82l/small_groups/) — engaging on the
r/Christianity thread only, per the report's own guidance).

> I hit this exact wall in a group I used to be part of. We kept saying we'd "get to the study" after catching up, and catching up just never stopped. Took about four months before someone finally said out loud that we hadn't opened a Bible together since Easter.
>
> What fixed it wasn't a stricter rule. It was picking one short passage in advance and having everyone bring one note or question about it before we even sat down, so the study part didn't have to compete with the catching-up part, it just came first because everyone already had something to say.
>
> I ended up building a small app around that habit, FellowScript, which I work on. It's a way for a group to land on the same passage and see each other's notes ahead of the meeting. Not saying that's the fix for your group, but committing to the passage before you show up instead of once you're all in the room is what got ours back on track.

Status: pending approval.

### R2 — Reddit, r/Reformed, "Balancing Teaching and Community" (explicit-need)

[Thread](https://www.reddit.com/r/Reformed/comments/1w9f77b/balancing_teaching_and_community/)

> Co-led a group for about two years at a church big enough that most of us didn't live near each other either, closest person to me was still a 20 minute drive. What killed our community outside the Sunday meeting wasn't distance, it was that nobody had a reason to reach out mid-week besides texting "hey how's it going," which gets old fast and everyone stops doing it by week six.
>
> What held up longer was giving people something small and specific to bring back: one verse, one honest note on how it landed that week, instead of leaving the connection to general vibes. It gave people an actual reason to open a thread mid-week instead of it going quiet.
>
> That's part of why I've been building FellowScript, which I work on. It's a shared thread where the group's notes on the week's passage sit together even when nobody's in the same room. Not a fix for the teaching and community balance question itself, but if the distance piece is what's wearing on you, it might be worth a look.

Status: pending approval.

### R3 — Reddit, r/TrueChristian, "Is it normal to feel pressured to become a discipleship group leader..." (explicit-need)

[Thread](https://www.reddit.com/r/TrueChristian/comments/1wb0v4y/is_it_normal_to_feel_pressured_to_become_a/)

> Got put in almost the same spot: three meetings in, told I was "ready," and I very much was not. Said yes anyway because saying no felt like letting the group down, then spent the next two months winging it and panicking quietly before each meeting.
>
> What helped wasn't more training, since none was coming. It was giving myself a simple prep rhythm: read the passage a few days ahead, jot down three things (one observation, one question I genuinely didn't know the answer to, one place it hit close to home), and share those with the group a day before we met instead of improvising live. That took the pressure off having to "perform" leadership and turned it into just being a few days ahead of everyone else.
>
> I ended up building that rhythm into an app, FellowScript, which I work on. Group members can see each other's notes on the passage ahead of the meeting, so the leader isn't the only one showing up prepared. Not saying you need it, just sharing what got me through that first stretch, since "zero training, thrown in anyway" is a rough way to start.

Status: pending approval.

### R4 — Reddit, r/TrueChristian, "Bible study" (explicit-need)

[Thread](https://www.reddit.com/r/TrueChristian/comments/1wjck51/bible_study/)

> Ran into the same frustration leading a group a while back. Every curriculum we tried was fill-in-the-blank questions clearly written to have one "correct" answer, and it killed actual discussion. People stopped reading the text closely because the workbook was already telling them what to notice.
>
> What worked better: drop the workbook, assign the passage, and have everyone bring one thing they noticed and one question to the meeting. No answer key. Some weeks the conversation was messier, but it was real, people were wrestling with the text instead of hunting for the blank to fill in.
>
> That's basically the premise behind FellowScript, an app I work on. It's a way for a group to read the same passage and leave notes on it that everyone else can see, no curriculum attached. Not saying you need an app for the read-and-discuss format itself, that part just requires ditching the workbook, but if keeping everyone's notes in one place is useful, it's there.

Status: pending approval.

### R5 — Reddit, r/TrueChristian, "Any tips on taking notes when reading the bible?" (explicit-need, no product mention per task guidance)

[Thread](https://www.reddit.com/r/TrueChristian/comments/1wpi8tc/any_tips_on_taking_notes_when_reading_the_bible/)

> A method that's stuck with me: instead of trying to write something for every verse, pick just three things per passage. One observation, what does it actually say. One question, what don't I understand or want to dig into. One application, what does this ask of me today. Keeps you from either writing nothing or writing a page of restated verses.
>
> It also helps to date each entry and note the passage reference at the top before anything else. Sounds obvious, but six months in you'll want to find what you wrote about a specific verse, and "somewhere in March" isn't searchable.
>
> If you're using a physical notebook, leave the facing page blank for follow-up notes when you circle back to the same passage later. Worth doing from day one, since you will circle back, and cramming margin notes in later is worse than just having the space.

Status: pending approval. No FellowScript mention (kept generic per the daily report's own posture note for this thread).

### R6 — Reddit, r/TrueChristian, "Should Christians use AI to study the Bible?" (explicit-need, no product mention, high-heat)

[Thread](https://www.reddit.com/r/TrueChristian/comments/1wolagb/should_christians_use_ai_to_study_the_bible/)
(crosspost to
[r/Christianity](https://www.reddit.com/r/Christianity/comments/1woij65/) — engaging on the
r/TrueChristian thread only).

> I think it depends entirely on what you're using it for. Asking an AI to summarize what a passage "means" so you don't have to sit with it yourself is a real problem, it hands over the part of study that's supposed to be work. But using it as a prompt back into the text, like asking what cross-references you're missing or how someone from a different tradition would read a verse, isn't functionally different from a study Bible's footnotes or a commentary. Those are also someone else's interpretation sitting next to the text.
>
> The line I'd watch for isn't the tool, it's whether you're still opening your Bible afterward. If the AI answer becomes the destination instead of a detour back to the text, that's the failure mode, same as it would be with any commentary you stopped questioning.

Status: pending approval. No FellowScript mention or link (high-heat thread, per task guidance).

### R7 — Reddit, r/Christianity, "Healthcare worker Bible study" (explicit-need)

[Thread](https://www.reddit.com/r/Christianity/comments/1wnj8ox/healthcare_worker_bible_study/) (0
comments as of today's report).

> Had someone in a group I led who was an ER nurse, and "meet same time every week" just flatly didn't work for her. She'd miss two out of three meetings some months and started to feel like she wasn't really part of the group anymore, through no fault of her own.
>
> What worked: everyone read and noted on their own schedule during the week, whenever their shift allowed, then we had a standing thread where people dropped their notes on the passage as they got to it, and only tried to get everyone on a call when schedules actually lined up instead of forcing a fixed weekly slot. She went from feeling like a dropout to genuinely caught up, just async.
>
> I ended up building FellowScript, which I work on, partly with that in mind. It's a shared thread for a group's notes on the passage that doesn't require everyone online at once, plus an occasional call when it works. Not saying it's the only way to do this, but the shift-schedule problem is exactly what pushed me toward building it that way.

Status: pending approval.

### R8 — Twitter/X, @ThomisticDan (networking)

[Post](https://twitter.com/ThomisticDan/status/2101832340368413096)

> Genuinely curious what's driving the online study for you. Is it distance from a church, or more that the online group itself has become the deeper connection? Those feel like different questions with different answers. Hebrews 10:25 gets brought up a lot in these threads, but it's talking about a specific kind of neglect, not really the medium. I don't think it forbids online gathering outright, but I'd want to know if the online study is supplementing a body you're still part of, or if it's become the whole thing for you.

Status: pending approval. Delivery: comment. No FellowScript mention (networking posture — no stated problem the product addresses).

### R9 — Instagram, @godschurchphilly (networking, DM)

[Post](https://instagram.com/p/DdkS2afKult)

> Hey, saw your post about the weekly online Bible study you're running. How long has the group been going? I'm always curious how groups that meet mostly online keep people showing up week to week instead of fading out after a month or two. Is that something you've had to actively work at, or has it stayed pretty steady?

Status: pending approval. Delivery: **DM, not a public comment** (Instagram rule). See the capability-limit note below — approval alone won't get this delivered.

### R10 — Instagram, @edenfellowship25 (networking, DM)

[Post](https://instagram.com/p/DdiswJQDhH_)

> Hey, came across your post about the fellowship group. What's the format usually like, more discussion-based, or is someone teaching each week? I ask because I've found the hardest part of keeping a group going isn't the first few weeks, it's the stretch after the initial excitement wears off. Curious if that's matched your experience or if yours has run differently.

Status: pending approval. Delivery: **DM, not a public comment** (Instagram rule). Same capability-limit note as R9.

### R11 — YouTube, Toronto Church SDARM (networking)

[Video](https://youtube.com/watch?v=qCsiLT-BT8E)

> Been watching a bit of your Saturday study series. How long has this particular group been meeting together? Curious whether it's mostly the same core group each week or if it varies a lot, since I've found that's usually the biggest factor in how deep the discussion can go over time.

Status: pending approval. Delivery: comment.

---

## Capability-limit note (R9, R10)

Per Zernio's own docs, `messages_create_inbox_conversation` cannot cold-start a new conversation on
Instagram — only X, Bluesky, Reddit, WhatsApp, SMS, and Slack support that. Instagram only supports
replying inside a conversation the other person already opened. **Approving R9 or R10 does not mean
they'll be automatically delivered** — both DMs will need to be sent manually.

## Deprioritized, not queued (no drafts, per today's report)

The report separately flagged but did not queue: a Sunday-notes-retention thread whose polished
structure may itself be soft-promo (recommends checking OP history before touching), a
youth-apologetics-prep thread (leader-oriented but for teens rather than adults), and a 161-comment
"why don't Christians know the Bible" mega-thread (too broad/noisy to act on). No drafts were written
for these; they're not part of the approval queue above.

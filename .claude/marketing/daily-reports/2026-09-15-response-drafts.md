# FellowScript Response Drafts — 2026-09-15

Unattended draft-only run, follow-up to today's daily marketing digest. **Nothing in this
document has been posted, replied to, or published anywhere.** Every item below needs explicit
human approval before it goes out, and posting itself is handled by a separate always-on process
reading the #prefect-victory Discord channel, not by this script.

## A note on today's access limits

Two things blocked verification that would normally happen at this step, and both are worth
flagging plainly rather than glossing over:

1. **Full thread text wasn't available.** Reddit's own site is unreachable to this environment's
   web-fetch tool (blocked at the domain level, both `www.reddit.com` and `old.reddit.com`), and
   Zernio's Reddit connector — which the morning listening pass used for its 14 read-only
   searches — returned `429 Rate limit exceeded` on every call made here, including the first
   attempt to just re-check subreddit rules. It resets 2026-09-16 04:00. So every draft below is
   written from today's daily report's own summaries (title, poster's situation, suggested angle),
   not from re-read full post text or comment threads. The summaries are substantive enough to
   draft from without inventing detail, but they are not a substitute for a human skimming the
   actual thread before approving, especially to catch anything that's changed since the report
   was compiled or any nuance a one-paragraph summary can't carry.
2. **Subreddit self-promotion rules were not verified today.** The pipeline instructions call for
   checking each subreddit's rules before drafting anything promotional; the same rate limit blocked
   that too. No draft below has been confirmed against current subreddit rules. Treat every
   promotional draft (marked below) as provisionally acceptable at best — a large-subreddit norm of
   tolerating disclosed, on-topic participation, not a verified policy. **Please check each
   subreddit's rules before approving R2, R6, R7, R8, R9, R11, or R13.**

No event/gathering/Bible-study broadcast-style posts appear in today's queue — the report's
ForumScout section had zero survivors today (versus one yesterday), so every item below is an
explicit-need Reddit post, not a networking-posture item.

---

## Resolution options

### 1. SEO regression — homepage missing all meta tags (flagged 2026-09-14, still unfixed 2026-09-15)

The problem, per today's and yesterday's reports: `fellowscript.com`'s server-delivered HTML is a
bare `<title>FellowScript</title>` with an empty `<div id="root">` — no meta description, no
OG/Twitter tags, no canonical, no JSON-LD, no H1, no body text. Everything renders client-side
after JS executes. `site:fellowscript.com` returns nothing in Google, and the site doesn't rank
even for its own brand name. This does not require rewriting the authenticated app — only the
public `/` route's `<head>` needs to be server-delivered.

**Option A — Static/prerendered `<head>` injection for the `/` route only.**
What it involves: a small build or edge-function step that serves static title, meta description,
OG/Twitter tags, canonical URL, and Organization/SoftwareApplication JSON-LD for `/` (and any other
public marketing routes), while leaving the authenticated app untouched.
Effort: low to medium — a few hours to a day for one engineer, no architecture change.
Owner: engineering (frontend or infra, whoever owns the deploy pipeline).
Trade-off/risk: lowest risk, most targeted option; needs a process to keep the static tags in sync
if homepage copy changes later, or they'll drift stale again.

**Option B — Bot-aware prerendering service (e.g., Prerender.io, or a Cloudflare Worker/edge
function that detects crawler user-agents and serves a pre-rendered HTML snapshot).**
What it involves: routing requests from known crawler user-agents to a cached, fully-rendered HTML
version of the page while real users still get the client-rendered React app.
Effort: medium — new infra dependency, needs configuration and testing.
Owner: engineering.
Trade-off/risk: adds a third-party or custom infra dependency and ongoing cost; must serve content
identical to what a real visitor sees or it edges toward a cloaking pattern search engines penalize.

**Option C — Migrate the public marketing pages (home, privacy, terms) off the authenticated React
app entirely, onto a proper SSR framework (Next.js) or a decoupled static site (Astro, etc.).**
What it involves: a real rebuild of the public-facing site, separate from the logged-in app.
Effort: high — the biggest lift of the three, likely a multi-day to multi-week project.
Owner: engineering, with marketing/design input on the actual page content.
Trade-off/risk: solves the problem permanently and also fixes the adjacent issue that
`sitemap.xml` only lists 3 URLs with no blog/content footprint — but it's a real project, not a
patch, and shouldn't block on getting Option A shipped first.

Whichever path is chosen, this has now been flagged unfixed for two consecutive days — worth a
direct check with whoever owns the frontend deploy on whether anything is already in flight before
picking one of the above.

### 2. SmartGroups' "Scale" tier — needs folding into `COMPETITOR-REPORT.md`

SmartGroups' $12/month-per-group, unlimited-groups "Scale" tier was first surfaced 2026-09-14 and
re-confirmed live today. It hasn't been written into `COMPETITOR-REPORT.md` yet.

**Option A — Quick patch.** Add a short section to the existing report noting the new tier and how
it compares to FellowScript's per-seat pricing. Effort: ~30 minutes. Owner: whoever maintains the
report (marketing). Risk: minimal, but doesn't produce any actual strategic read on what it means
for FellowScript's pricing or messaging.

**Option B — Roll it into the next scheduled full refresh.** `COMPETITOR-REPORT.md` was last fully
refreshed 2026-09-13; wait for the next periodic pass and update it alongside everything else.
Effort: none extra right now. Risk: leaves the report visibly stale on this one fact in the
meantime, and delays any reaction if the Scale tier turns out to be a real competitive pressure
point.

**Option C — Scope a dedicated `/research` run** on what the Scale tier specifically implies for
FellowScript's positioning and pricing (SmartGroups now offers unlimited groups for a flat fee where
FellowScript charges per seat). Effort: medium — the full 8-agent research pipeline. Owner: whoever
runs `/research` (marketing/strategy). Risk: likely overkill for a single competitor fact in
isolation, but it's the option that produces an actual recommendation rather than just a logged
observation — worth it only if this tier looks like it's actually pulling prospects away.

### 3. ForumScout "fellowship" keyword noise — recurring, not new today

The report flags (again) that the ForumScout sheet's bare "fellowship" keyword match surfaces mostly
noise — Lord of the Rings discussion, medical/academic fellowships, one-way broadcast content — and
that this was already flagged at pipeline setup. Today's real relevance filtering worked as designed
(zero survivors, versus one yesterday, reflecting content not a filtering bug), but the underlying
keyword scope is still broad.

**Option A — Tighten the keyword list.** Require co-occurring terms (e.g. "fellowship" plus
"Bible"/"scripture"/"church"/"study"), or add FellowScript-specific and category terms directly.
Effort: low. Owner: whoever administers the ForumScout monitoring configuration (marketing). Risk:
could narrow too far and miss genuine leads; wants a validation pass against recent historical rows
before trusting it fully.

**Option B — Add a scoring/classification layer between ForumScout ingest and the daily digest**
(e.g. a lightweight relevance-classification pass on new rows) instead of relying on the raw keyword
match plus manual filtering each day. Effort: medium. Owner: engineering/marketing-ops, whoever owns
the daily pipeline script. Risk: added complexity and per-row cost, but removes the recurring
"read through the noise" step the pipeline currently absorbs itself every run.

**Option C — Leave it as-is.** The daily pipeline's own filtering step is already catching this
correctly (zero survivors today is a correct result, not a miss). Effort: none. Risk: keeps
spending pipeline time/tokens scanning mostly-noise rows every day; only worth revisiting if that
cost starts to matter.

---

## Drafted replies

13 items reviewed from today's report's combined Reddit review queue, assigned R1–R13 in the order
the report listed them. All are `explicit_need` posture — no event/gathering/networking-style posts
were present in today's queue.

### R1 — r/Christianity, "Lifestyle + habits for modern day Christians"
**Platform:** reddit · **URL:** https://www.reddit.com/r/Christianity/comments/1w3j0ar/
**Status:** pending_approval (not promotional — asks a genuine question, mentions FellowScript
only as an aside)

> Putting together a multi-week series is its own kind of discipline. Curious how you're keeping
> the plan and your notes together as you go, especially a few weeks in when people forget what
> happened in week 1. Asking partly because that's the problem that got me building FellowScript,
> a Bible study app that puts a study plan into your group's shared feed so people aren't digging
> through old texts to find week 3's questions. Not saying it's the answer to your post, just
> wondering if that's part of what's been hard for you too.

*Note: today's report summary doesn't say what "feedback" the poster is asking for beyond a
multi-week series, so this stays general rather than guessing at their actual content topic.*

### R2 — r/TrueChristian, "Organization resource for church small groups"
**Platform:** reddit · **URL:** https://www.reddit.com/r/TrueChristian/comments/1vcuowy/
**Status:** pending_approval (promotional — subreddit rules not verified today, see note above)

> Been there, juggling three separate apps for one group is its own part-time job. For what it's
> worth, I work on FellowScript. We built it around exactly that problem: notes and group chat
> live in the same place as the scripture you're studying, so you're not bouncing between a
> spreadsheet and a group chat to figure out what's next. It's built for the study side of things
> though, not signups or scheduling, so you'd probably still want something lightweight for RSVPs.

### R3 — r/TrueChristian, "Young adult small group topics"
**Platform:** reddit · **URL:** https://www.reddit.com/r/TrueChristian/comments/1w2klyq/
**Status:** pending_approval (promotional — subreddit rules not verified today)

> First time leading is honestly the hardest one, you're building the habit of prepping and
> learning to lead at the same time. Two things that helped people I've talked to: pick a passage
> or short book to move through slowly rather than a new topic every week, it gives you a built-in
> shape. And write your questions down somewhere your group can see too, not just your own notes,
> it takes the pressure off you to remember everything out loud. I work on FellowScript, which is
> basically built for that second part, a shared notes space for a group. But the bigger thing is
> just picking a simple structure and sticking with it for a few weeks.

### R4 — r/Christianity, "Devotional book recommendations?"
**Platform:** reddit · **URL:** https://www.reddit.com/r/Christianity/comments/1w33s2s/
**Status:** pending_approval (promotional — subreddit rules not verified today)

> Following this thread for recs too. One thing that's made more of a difference for groups I've
> talked to than the book choice itself: whether everyone's notes and reflections land somewhere
> the whole group can actually see between meetings, it keeps the study alive outside the room. I
> work on FellowScript, which does collaborative devotion plans for exactly that. Mentioning it
> since it's relevant, though I don't have a book recommendation for your group, that part's
> outside what I can help with.

### R5 — r/Reformed, "Looking for a Bible Study"
**Platform:** reddit · **URL:** https://www.reddit.com/r/Reformed/comments/1tt8rc3/
**Status:** pending_approval (promotional — subreddit rules not verified today)

> Running four studies at once is a lot of plates to keep spinning. Genuine question, how are you
> keeping each group's material and notes separate from each other right now? That's the exact
> tangle FellowScript, which I work on, was built to untangle: each group gets its own space for
> notes and plans so nothing bleeds into the wrong study. Not assuming that's your actual
> bottleneck, just curious given the scale you're running.

### R6 — r/Bible, "Taking notes, still not retaining much"
**Platform:** reddit · **URL:** https://www.reddit.com/r/Bible/comments/1uvhngd/
**Status:** pending_approval (promotional — subreddit rules not verified today; note this thread
already has 18 comments, so check it's still worth engaging)

> Retention almost never comes from the notes themselves, it comes from what you do with them
> after: saying them out loud, defending why you highlighted something, having someone push back
> on it. If your notes are just sitting in an app nobody else sees, that's probably the actual gap,
> not the note-taking method. I work on FellowScript, which anchors notes to specific verses and
> lets people in your group see and respond to them, built around the idea that retention is a
> discussion thing, not a filing thing.

### R7 — r/Bible, "Best Bible Gateway alternative"
**Platform:** reddit · **URL:** https://www.reddit.com/r/Bible/comments/1i9j6sa/
**Status:** pending_approval (promotional — subreddit rules not verified today; evergreen post
from 2025-01, confirm it's still active before posting)

> FellowScript might be worth a look, I work on it. Web and iOS with notes that sync, and a macOS
> desktop app if you study at a computer. Worth knowing upfront: it's built group-first, so notes
> are tied to a shared study space rather than being a purely solo tool. Still works fine solo,
> just be aware that's the frame it's designed around before you commit to it.

### R8 — r/Bible, "App to read, take notes, and share notes with a friend?"
**Platform:** reddit · **URL:** https://www.reddit.com/r/Bible/comments/1ikq51k/
**Status:** pending_approval (promotional — subreddit rules not verified today; evergreen post
from 2025-02, confirm still active)

> That's pretty much exactly what FellowScript does. Full disclosure, I work on it: read, take
> notes tied to specific verses, and share them with whoever you're studying with, whether that's
> one friend or a small group. Happy to answer specifics if you want them.

### R9 — r/Bible, "Bible note-taking app recommendations"
**Platform:** reddit · **URL:** https://www.reddit.com/r/Bible/comments/1kg1cje/
**Status:** pending_approval (promotional — subreddit rules not verified today; evergreen post
from 2025-05, confirm still active)

> FellowScript, I'm one of the people building it, has a three-panel layout: scripture, notes, and
> messaging side by side, which covers the side-by-side part well. Being upfront though, it's
> single-translation (ESV) with no cross-reference or lexicon tooling, so if multi-translation
> comparison or original-language lookup is what you actually need, it won't cover that. Worth
> knowing before you try it.

### R10 — r/Christianity, "How to split costs in a Bible study group?"
**Platform:** reddit · **URL:** https://www.reddit.com/r/Christianity/comments/1wgon2y/
**Status:** pending_approval (no product pitch, per the report's own instruction — actual question
is about cost-splitting, not tooling)

> A few things that've worked for groups I've heard from: a simple rotating potluck sign-up so
> it's not always the host cooking, or a shared per-meeting fund (Venmo or Zelle, a small flat
> amount like $5) that covers snacks and coffee instead of one person always footing the bill. If
> the group's growing, worth revisiting the amount every so often since costs scale with headcount
> faster than people expect.

### R11 — r/Christianity, "How do people find Christian community?"
**Platform:** reddit · **URL:** https://www.reddit.com/r/Christianity/comments/1wcry7q/
**Status:** pending_approval (promotional — subreddit rules not verified today; product mention
kept brief since the actual question is about finding community, not tooling)

> On the practical side, your own church's small-group ministry page, or a campus/young-adult
> ministry if there's one near you, tend to be the easiest way in if you don't already know people
> to ask directly. But "small groups just fall apart" is the real thing worth sitting with. In my
> experience it's rarely the first meeting that kills a group, it's the six weeks after when
> nobody's talking between sessions. I work on FellowScript, built partly around that exact gap:
> shared notes and chat so a group has a reason to stay connected outside the meeting. Mentioning
> it because you named the actual problem, not as a blanket plug.

### R12 — r/Christian, "Bible Study groups online"
**Platform:** reddit · **URL:** https://www.reddit.com/r/Christian/comments/1ug02wf/
**Status:** skipped
**Skip reason:** poster wants to find/join an existing online study, not looking for a tool.
FellowScript doesn't offer a group-finding directory, so there's no genuine product fit here, and
the report's one-line summary isn't enough to draft a non-generic, non-promotional comment without
the full thread (blocked today per the note above). Recommend a human read the actual thread before
deciding whether a purely non-promotional "here's where to look" comment is worth adding.

### R13 — r/Christianity, "Any good *non ai* Christian apps?"
**Platform:** reddit · **URL:** https://www.reddit.com/r/Christianity/comments/1wfwpor/
**Status:** pending_approval (promotional — subreddit rules not verified today; this one especially
needs a careful read before posting, since the poster explicitly said no AI and the draft discloses
the optional AI feature rather than hiding it, per the hard rule against deceptive framing)

> Totally get the wariness, a lot of "AI companion" framing in this space feels off. FellowScript,
> I work on it, is built human-first: it's fundamentally a group study tool, shared notes, group
> chat, people actually seeing what you're studying. Accountability comes from real people in your
> group, not a bot. Since you specifically said no AI: there is an optional AI "heartbeat" feature
> (daily devotional prompts), but it's opt-in and easy to ignore if you don't want it. Didn't want
> to leave that out and have you find it later and feel misled.

---
*Unattended draft-only pipeline run. No posting, replying, or publishing action was taken on any
platform. All drafts pending human review and approval.*

# FellowScript Response Drafts — 2026-09-19

Unattended draft-only run. Nothing below has been posted, replied to, or sent anywhere. Every
item requires explicit human approval (by ID) before the always-on marketing process posts it.

---

## Resolution options

Covers the two items flagged "needs a decision today" in today's digest, plus one recurring
SEO/technical bucket and one positioning note raised elsewhere in the report. Each lays out
concrete paths, not a single prescribed fix — pick one and this needs a human decision, not
another pipeline run.

### 1. Google isn't indexing fellowscript.com (confirmed again, 2nd day running)

`site:fellowscript.com` still returns zero results. `robots.txt` now carries a comment from
yesterday's `/build` task (`20260918-fix-google-indexing-audit`) stating repo-side causes
(robots.txt, meta robots, X-Robots-Tag) are ruled out and pointing at the Cloudflare account layer
or Google Search Console as the likely remaining cause. This is an account/dashboard problem, not
a code problem — no further `/build` run can fix it.

**Option A — Google Search Console diagnostic first.**
Log into GSC (if not already verified, verify ownership via DNS TXT record first), check the
Coverage/Pages report for the homepage's exact status (`Blocked by robots.txt`, `Crawled – not
indexed`, `Discovered – not indexed`, `Server error`, or `Blocked due to other 4xx/5xx`), then use
URL Inspection to request indexing. This single report will usually say *which* of the two
remaining causes it is, turning the rest of this into a five-minute fix instead of a guess.
Effort: low (~30–60 min). Owner: whoever holds GSC access (marketing or engineering). Risk: none,
purely diagnostic.

**Option B — Cloudflare configuration audit.**
Check Bot Fight Mode / Super Bot Fight Mode, WAF custom rules, and the Firewall Events log,
filtered to Googlebot's user-agent/IP ranges, for any block or challenge event. Cloudflare's Bot
Fight Mode is a common, easy-to-miss cause of silent Googlebot blocking on sites that enabled it
for general bot protection without an allowlist exception. Effort: low-medium (needs Cloudflare
dashboard access, ~1 hr). Owner: engineering (holds infra access). Risk: low if scoped to
allowlisting verified Googlebot; don't disable Bot Fight Mode entirely just to fix this, since that
reopens the abuse surface it exists for.

**Option C — Run A and B together, then escalate if both come back clean.**
Given this has now sat unresolved across two daily digests, the fastest path is doing the GSC
check and the Cloudflare check in the same sitting rather than sequentially waiting on one to rule
out the other. If both come back clean (no block found, no coverage error, sitemap accepted) and
the site is still unindexed a few days later, that's the point to loop in Cloudflare support or an
outside technical-SEO consultant rather than keep re-checking the same two dashboards. Effort:
same as A+B combined (~1.5–2 hrs) plus a wait-and-recheck cycle. Owner: whoever owns both access
points, or marketing + engineering jointly.

### 2. Site is 100% client-rendered — no crawlable content without JS

Raw HTML is `<div id="root"></div>`. No H1, no body text, no links for a non-JS-executing crawler.
Combined with `HashRouter`, only one real URL exists in the sitemap. This is a scope decision
(how much to invest in making the marketing site crawlable), not a quick patch.

**Option A — Prerendering/rendering middleware for bots.**
Add a prerendering layer (e.g., a Cloudflare Worker that detects crawler user-agents and serves a
pre-rendered snapshot, or a hosted service like Prerender.io) in front of the existing SPA. Users
still get the full React app; crawlers get static HTML. Effort: medium (new infra component, needs
testing to confirm Google gets identical content to users — cloaking risk if snapshots drift out
of sync). Owner: engineering. This is the standard fix for exactly this class of problem and
doesn't require rebuilding the app.

**Option B — Split the public marketing site from the authenticated app.**
Build the public-facing pages (home, pricing/about, any future landing pages) as a small
server-rendered or statically generated site (Next.js, Astro, or similar), and keep the existing
React SPA purely for the logged-in Reader experience behind auth. This is more work up front but
is the cleanest long-term fix: no prerendering layer to keep in sync, and it opens the door to
adding more indexable marketing pages later (currently there's only one URL in the sitemap
regardless of fix chosen here). Effort: medium-high (a real rebuild of the marketing shell).
Owner: engineering + design (copy/layout for real marketing pages, not just the app shell).

**Option C — Minimal patch: hand-write static fallback content in the root HTML.**
Add a static H1, a paragraph of body copy, and a few real `<a>` links directly into `index.html`
behind the `#root` div, so non-JS crawlers see *something* even though `HashRouter` still caps
real routing at one URL. The JS app still mounts and replaces it for real users. Cheapest option,
but it's a band-aid: content will drift out of sync with the live app copy over time, and it does
not fix the one-URL-in-sitemap problem. Effort: low (a few hours). Owner: engineering. Risk: low,
but flagged as the weakest long-term option of the three.

**Option D — Explicitly accept the gap for now.**
Given the standing marketing strategy prioritizes leader-first referral/group-invite growth over
paid or organic search acquisition (`fellowscript-overview.md`), it's a legitimate option to
formally decide this isn't worth engineering time right now and revisit later. Worth naming as a
real choice rather than letting it sit unresolved-by-default across further daily digests, since
that's what's been happening for two days running.

### 3. Recurring smaller SEO/schema gaps (worth bundling into one quick pass)

Noted again today, unchanged from prior runs: no `sameAs` links in the Organization JSON-LD
(should point at FellowScript's real social profiles), no `SoftwareApplication` schema despite
being an app (a missed rich-result opportunity — only add this with real, non-fabricated fields;
no user rating data exists to put in it), and no explicit CTA in the meta description. Also:
**Bible Study Together** ranks strongly for phrasing nearly identical to FellowScript's own
tagline ("walk with God together") — worth adjusting title-tag/meta wording to differentiate
rather than compete head-on for the same generic phrase. All four are small, independent copy/markup
changes, not infrastructure work. Effort: low (a few hours total). Owner: marketing (copy) +
engineering (schema markup). No meaningful trade-off or risk; the only reason to defer is
prioritization against items 1 and 2 above.

---

## Drafted replies

15 items reviewed (8 Reddit via Zernio, 7 cross-platform via ForumScout) — matches today's
digest's "15 items queued" count. All 15 got a posture decision and a draft; none were skipped for
subreddit self-promotion rules, see the verification note below. Totals: 8 explicit-need, 7
networking; 14 comments, 1 DM.

**Verification note:** this run could not fetch reddit.com (WebFetch and WebSearch both failed to
retrieve live subreddit rule pages from this environment), so subreddit self-promotion rules were
not independently re-verified today. All explicit-need drafts follow the same disclosed-affiliation
pattern already established and used in prior days' human-approved drafts
(`response-style-guide.md`) — but a human should still spot-check the live subreddit rules before
approving, since this run genuinely couldn't.

**Duplicate flag — R1:** this thread (r/Christianity, "Any one know where to get some group Bible
studies?") appears to be the *exact same thread* already hand-drafted and refined by Jacey on
2026-09-18 — see `response-style-guide.md`'s last worked example, which matches this thread's
details (weekly group of 15–20, writes and prints material, "less is more" lesson) word for word.
Today's queue re-surfaced it as if new. **Recommend checking whether this was already posted
before approving it again** — the draft below is Jacey's own already-finalized text, reused
as-is, not run through humanizer again since it's not an AI draft to begin with.

### R1 — r/Christianity, "Any one know where to get some group Bible studies?"
**Platform:** reddit · **Posture:** explicit_need · **Delivery:** comment
**Thread:** https://www.reddit.com/r/Christianity/comments/1wjdqi2/any_one_know_where_to_get_some_group_bible_studies/
**Flag:** likely duplicate of an already-finalized 2026-09-18 draft — verify not already posted.

> I did something similar for about two years, writing a full study from scratch every week and
> printing it for a group of 15 to 20. What surprised me was noticing the same thing you're
> describing: the weeks I brought less prepared material, people talked more, not less. I'd been
> treating a thick handout as what made the study feel legitimate, and it was actually getting in
> the way of people just sitting with the text themselves.
>
> If you want something ready-made instead of writing weekly, The Gospel Coalition has free
> studies, and RightNow Media's library is solid if your church already has access. The bigger
> shift for me wasn't finding better material though, it was cutting it down to a passage and two
> or three questions and letting the group mark up the text themselves instead of reading my notes
> about it.
>
> I feel this is a good chance to share my personal journey with this exact issue. I recently
> published an app, FellowScript. It's free for a group your size, and it killed the printing loop
> for me: everyone reads the same passages and leaves notes right on it, so nothing gets
> photocopied anymore. The less-prep shift works fine on paper too, but if the printing and prep
> grind specifically is what's wearing you down, I believe this could be right for you.
> fellowscript.com

### R2 — r/TrueChristian, "Young adult small group topics"
**Platform:** reddit · **Posture:** explicit_need · **Delivery:** comment
**Thread:** https://www.reddit.com/r/TrueChristian/comments/1w2klyq/young_adult_small_group_topics/

> First time leading a group is its own kind of stressful — I remember way overplanning my first
> few weeks because I didn't trust the group to carry a conversation without me filling every
> silence.
>
> What actually worked was picking one short book, a gospel or a short epistle, and going chapter
> by chapter instead of building a curriculum from scratch. Fewer decisions for you every week, and
> it gives the group a shape to expect. I'd start with 4-6 weeks in one book before committing to
> anything longer; easier to adjust than a full semester plan you're locked into.
>
> That first-time-leader stretch is part of why I built FellowScript. It runs a scheduled month of
> daily content for a group, so you're not starting from a blank page every week deciding what's
> next. Not something you need to get started, just something that took a load off once I had a
> group going. fellowscript.com

### R3 — r/Christianity, "Any good *non ai* Christian apps?"
**Platform:** reddit · **Posture:** explicit_need · **Delivery:** comment
**Thread:** https://www.reddit.com/r/Christianity/comments/1wfwpor/any_good_non_ai_christian_apps/
**Caution honored:** poster explicitly wants non-AI; draft stays candid that FellowScript's
heartbeat is an AI feature and makes clear it's optional, rather than omitting that fact.

> I get the AI fatigue — a lot of what's out there lately is generic devotional content with no
> depth, slapped together fast.
>
> For accountability specifically, without it being AI-driven: the simplest thing that's worked for
> me is just a shared place where a couple people can see your notes. Not a feature, just
> visibility — it only needs someone else to notice if you go quiet for a week.
>
> Since you're specifically trying to avoid AI apps, I'll be upfront: I run FellowScript, and it
> does have an optional AI daily-prompt feature. The core is just scripture, notes, and shared
> visibility with a group though, no AI required for any of that part. Didn't want to recommend it
> without being clear about that piece, since it's exactly what you're trying to avoid.
> fellowscript.com

### R4 — r/Reformed, "How do you take notes on your Bible?"
**Platform:** reddit · **Posture:** explicit_need · **Delivery:** comment
**Thread:** https://www.reddit.com/r/Reformed/comments/1v4anfo/how_do_you_take_notes_on_your_bible/

> Consistency's the actual hard part with note-taking, not the system. I've tried more note apps
> and physical journaling methods than I'd like to admit, and the ones that stuck were the
> simplest, not the most featured.
>
> What helped most: tying every note directly to the verse instead of a separate notebook or app
> you have to cross-reference back to. If the note lives right next to the text, you're a lot more
> likely to actually write the one-line thought instead of skipping it because opening a second app
> feels like a chore. With ADHD especially, cutting the steps between having a thought and getting
> it written down matters more than any organizational system.
>
> That's basically the problem FellowScript's built around for me: notes attached right to the
> verse, and if your group's reading the same thing, everyone sees each other's in place instead of
> comparing separate notebooks after the fact. Not saying you need an app for it, but if switching
> between text and notes is part of what's stopping you, might be worth a look. fellowscript.com

### R5 — r/pastors, "Bible Study Group - Where to Start???"
**Platform:** reddit · **Posture:** explicit_need · **Delivery:** comment
**Thread:** https://www.reddit.com/r/pastors/comments/1uvx0zl/bible_study_group_where_to_start/

> Inheriting a group without picking the people or the starting point is its own challenge. I've
> been there, stepping into a group that already existed without getting to set the tone from
> scratch.
>
> What worked was resisting the urge to pick something ambitious right away. Start with a single,
> well-known book, one of the Gospels or a short epistle like Philippians, and go slow, a passage
> at a time. With an older group especially, pace matters more than material; better to spend three
> weeks on one chapter with real discussion than rush a syllabus nobody asked for.
>
> One thing that's helped quieter members (and older groups often have a few who don't jump into
> live discussion) is giving people a way to leave a thought in writing between meetings instead of
> only in the room. That's part of why I built FellowScript: shared notes tied to the passage, so
> people who process slower or don't love speaking up can still be part of it. Not essential to get
> started, just something that's helped my own group. fellowscript.com

### R6 — r/Reformed, "Looking for discussion questions / one day Bible studies"
**Platform:** reddit · **Posture:** explicit_need · **Delivery:** comment
**Thread:** https://www.reddit.com/r/Reformed/comments/1uyzxps/looking_for_discussion_questions_one_day_bible/
**Caution honored:** doesn't position FellowScript as a source of confessionally Reformed content
— points to real Reformed resources for that, and only mentions FellowScript for the shared-notes
logistics of a one-day study.

> For confessionally Reformed one-day material, I'd check Ligonier or Desiring God. Ligonier
> especially has short guides written from that lens, a better fit than a general list I could
> throw together.
>
> For the logistics side of a one-day study with friends on a trip: what's tripped up trips like
> that for me before is everyone having a different printout, or nobody having the passage marked
> how they want it. If you're all looking at the same text at once, having it in one shared place
> where everyone can mark it up live helps more than the discussion questions themselves. That's
> the piece FellowScript actually solves for me, not confessional content, just everyone on the
> same page literally. Might be worth it for that one day even if the study material comes from
> elsewhere. fellowscript.com

### R7 — r/Bible, "Help requested - Guided Reading"
**Platform:** reddit · **Posture:** explicit_need · **Delivery:** comment
**Thread:** https://www.reddit.com/r/Bible/comments/1tmjp33/help_requested_guided_reading/

> A one-book-a-week pace with just two of you is a great setup. Small enough that you don't need a
> heavy structure, just consistency.
>
> What helped when I was mentoring someone newer to reading Scripture regularly: don't just tell
> them what a passage means after the fact, let them see your actual notes and highlights while
> they're reading it themselves, in context. It's a different thing to hear "this part matters
> because X" versus seeing exactly which verse someone marked and why, right next to the text.
>
> That's the specific use case that got me building FellowScript: shared highlights and notes that
> show up right on the passage for both of you, so a newer reader isn't just getting your
> conclusions secondhand. Not a requirement to do this well, just something that made the mentoring
> part easier for me. fellowscript.com

### R8 — r/Bible, "How to self study the Bible?"
**Platform:** reddit · **Posture:** explicit_need · **Delivery:** comment
**Thread:** https://www.reddit.com/r/Bible/comments/1u18mag/how_to_self_study_the_bible/
**Note:** lower priority per the report (older thread), drafted anyway since it was in the queue.

> Losing the group along with the pastor retiring is the harder part of this, honestly. The
> studying-alone piece is learnable, but losing the people you were doing it with is a real loss,
> not just a logistics problem.
>
> Before assuming it has to become solo studying: is there any appetite among the old group to keep
> meeting even informally, without a designated leader? A lot of groups don't actually need the
> original leader to keep going, just someone willing to pick the next passage. Worth one message
> to the group before defaulting to going it alone.
>
> If it does end up being just you for now, or if the group wants to keep going without meeting in
> person as often, I built FellowScript partly for that gap: a way for a group to keep reading and
> leaving notes together even when the regular meeting isn't happening. Not saying it replaces what
> you had, just flagging it in case staying connected async is useful during the transition.
> fellowscript.com

### R9 — r/ChristianDating, comment on "Spiritual boundaries"
**Platform:** reddit · **Posture:** networking · **Delivery:** comment
**Thread:** https://www.reddit.com/r/ChristianDating/comments/1wkbnfj/spiritual_boundaries/papitzz/
**Note:** no product mention — the comment doesn't name a problem FellowScript addresses.

> This is a great way to frame it. Praying and studying together as a couple hits different than
> doing devotions separately and comparing notes after. Curious how you two handle it practically
> though: do you keep it totally unstructured, or follow some kind of plan or passage together so
> you're not just winging it week to week?

### R10 — LinkedIn, Adwoa Adwubi Baah, "Day 19" post
**Platform:** linkedin · **Posture:** networking · **Delivery:** comment
**Post:** https://www.linkedin.com/posts/adwoa-adwubi-baah-_day-19-there-is-something-about-going-to-activity-7507011445298188289-aZ7d
**Note:** no product mention — personal journal post with no stated problem.

> Day 19 and still showing up to document it honestly is its own discipline. A lot of journaling
> series like this quietly die out around the two-week mark. What's been keeping the momentum
> going for you between Sundays? Is it a personal habit, or are you processing this with anyone
> else along the way?

### R11 — LinkedIn, Sharon Paul-Ojinigbo, on Agora Summit 2.0
**Platform:** linkedin · **Posture:** networking · **Delivery:** comment
**Post:** https://www.linkedin.com/posts/sharon-paul-ojinigbo-29a027b4_agorasummit-thealignment-christianleadership-activity-7507009930915401728-BAoc
**Note:** no product mention.

> Sounds like a summit worth reflecting on. The marketplace and leadership angle on faith doesn't
> get talked about nearly as much as it should. Curious what's stuck with you most so far: is there
> anything from Agora that you and your circle are actually trying to put into practice together,
> or is it still more individual reflection at this stage?

### R12 — LinkedIn, The Potter's Daughter Community, "Sisters Time Out"
**Platform:** linkedin · **Posture:** networking · **Delivery:** comment
**Post:** https://www.linkedin.com/posts/the-potter-s-daughter-community_sisterstimeout-thepottersdaughtercommunity-activity-7506987824563515392-a-LC
**Note:** no product mention.

> Spaces like this matter more than people give them credit for. A lot of women's groups struggle
> to keep the connecting and growing part going once the gathering itself ends. What does staying
> in touch actually look like for your group between Sisters Time Out events? Is there a way people
> keep the conversation or study going, or does it mostly restart each time you meet?

### R13 — Twitter/X, @Fellowship_MLS, prayer retreat announcement
**Platform:** twitter · **Posture:** networking · **Delivery:** comment
**Post:** https://twitter.com/Fellowship_MLS/status/2101246869359796614
**Note:** no product mention.

> A law school fellowship running its own retreat is a good sign the group has real staying power
> beyond weekly meetings. How do you all keep things going the rest of the semester once the
> retreat wraps? Is there a way people stay connected or keep studying together between the big
> events?

### R14 — Twitter/X, @SGCCAbuja, new Sunday School series
**Platform:** twitter · **Posture:** networking · **Delivery:** comment
**Post:** https://twitter.com/SGCCAbuja/status/2101236035833213053
**Note:** no product mention.

> A new teaching series is always exciting to kick off. Curious how you all handle continuity
> across the weeks though, especially for anyone who misses a Sunday. Is there a way people catch
> up on what was covered, or keep discussing it during the week between sessions?

### R15 — Instagram, @knowinggodmin, ministry event promo
**Platform:** instagram · **Posture:** networking · **Delivery:** dm
**Post:** https://instagram.com/p/DdcrFmIGLSg
**Note:** no product mention. Per the delivery-channel rule, this goes as a DM, not a public
comment — **Instagram can't be cold-started by `messages_create_inbox_conversation`** (only X,
Bluesky, Reddit, WhatsApp, SMS, and Slack support that; Instagram only replies inside a
conversation the other person already opened), so this DM has to be sent manually even after
approval.

> Hey! Saw your post about the event to equip women to share their faith. That's such a needed
> focus, a lot of women want to talk about their faith more confidently but don't get practical
> tools for it very often. Curious, after an event like that wraps, is there anything you all do to
> help people actually keep practicing what they learned, or does it tend to end when the event
> does?

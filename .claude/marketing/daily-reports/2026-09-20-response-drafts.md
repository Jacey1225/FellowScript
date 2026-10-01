# FellowScript Response Drafts — 2026-09-20

Unattended follow-up to today's daily marketing digest (`2026-09-20.md`). **Everything below is a
draft. Nothing has been posted, replied to, or sent anywhere.** No Zernio write action was taken —
this run only read from Zernio, the ForumScout sheet, and public web sources to prepare these
drafts for review.

**A note on verification limits this run:** Reddit itself (`reddit.com` and `old.reddit.com`) was
unreachable from this environment for both WebFetch and a live-thread check, so two things
instructed by the task could not be done directly this time:
- Subreddit self-promotion rules could not be fetched live for r/Christianity, r/TrueChristian,
  r/Reformed, or r/Christian (the subreddits where a draft below mentions FellowScript). Drafting
  proceeded on the basis of existing precedent in `response-style-guide.md` — prior hand-finished
  replies with the same disclosed, soft-mention style exist for r/Christianity, r/TrueChristian,
  and r/Christian already — but this is not the same as a fresh rules check. Worth a live glance
  before approving, same as any queued item.
- R1 below could not be checked for whether it already has a live reply (see its note).

---

## Resolution options

### 1. fellowscript.com not indexed by Google (flagged 3 days running: 09-18, 09-19, 09-20)

Root cause, per today's SEO check: the homepage is a pure client-rendered React SPA
(`HashRouter`) — raw HTML is an empty `<div id="root"></div>` with no H1, body copy, or crawlable
links, and `sitemap.xml` lists only one URL. This is a real fix, not a config tweak, so here are
three realistic paths to it, roughly narrowest-to-broadest in scope:

**Option A — Add a build-time prerender step to the current React app.** A tool like
`vite-plugin-ssr`, `react-snap`, or `prerender-spa-plugin` renders each route to static HTML at
build time, so crawlers get real markup without a framework rewrite. Effort: medium, on the order
of a few days including the routing change below. Owner: engineering (frontend). Caveat:
`HashRouter` routes aren't server-resolvable, so this option also requires switching to
`BrowserRouter` first (a small but real change, since it affects every internal link and requires
a server rewrite rule so deep links don't 404 on refresh). Ongoing cost: needs to re-run on every
deploy that changes content.

**Option B — Put a prerendering-as-a-service proxy in front of the app** (e.g. Prerender.io,
self-hosted rendertron) that detects crawler user agents and serves a fully-rendered snapshot,
while real users still get the SPA. Effort: medium, mostly infrastructure/Cloudflare config rather
than app code, so it doesn't require the `HashRouter` → `BrowserRouter` change. Owner:
engineering/DevOps. Trade-off: ongoing service cost and an added infra dependency, plus a cache
that needs to stay fresh; if the service goes down or misconfigures, crawlers silently see nothing
again.

**Option C — Migrate to a meta-framework with built-in SSR** (Next.js, Remix, or Vite's own
SSR/SSG mode). This is the most complete long-term fix: fixes indexing, improves real-user load
performance, and gives every future content page (see the "High" recommendation below) SSR by
default instead of needing the same workaround again. Effort: high, realistically weeks, since it
touches routing, data fetching, and build/deploy. Owner: engineering. Risk: a real rewrite with
rewrite risk and a deploy cutover, not something to run alongside other priorities casually.

**Interim stopgap worth considering regardless of which path above gets picked:** hand-author a
minimal static HTML homepage (real H1, on-brand copy, a couple of internal links) served at `/`,
which the SPA then hydrates over for logged-in use. Low effort (about a day), could ship this week
independent of the bigger decision, but only fixes the homepage specifically and creates a content
drift risk if not kept in sync. Worth doing now if Options A–C won't land within the week, given
this is day three of the flag.

Also queued alongside the indexing fix, lower priority: sharpen the title tag with a category
keyword, and eventually add 2–3 real content pages once SSR/prerendering exists to serve them from.

### 2. SmartGroups' new "Scale" pricing tier ($12/mo per group, unlimited groups)

This corrects `COMPETITOR-REPORT.md`'s current "flat org fee" framing of SmartGroups' upgrade
tier — Scale is a genuine per-group price, closer in spirit to FellowScript's own per-seat model
than previously documented.

**Option A — Update `COMPETITOR-REPORT.md` now with just this correction.** Effort: low, under an
hour; it's a documented, directly-observed pricing-page fact, not something needing further
verification. Owner: marketing. Caveat to note inline: can't confirm whether Scale is brand-new
since the 09-13 baseline or simply wasn't surfaced before — flag that uncertainty in the doc rather
than asserting a launch date.

**Option B — Hold the correction until the next scheduled competitive refresh.** Effort: zero now,
but the standing report used for messaging stays wrong in the meantime, and any messaging drafted
against the "flat org fee" framing this week would be factually incorrect the moment someone
checks the real pricing page.

**Option C — Run a fuller competitive refresh now,** not just this one number, since the report
also flagged unconfirmed-timing sightings of a new "Ask AI" preset-questions feature and Apple
Declared Age Range / child-safety additions. Effort: medium, a few hours, same live-check process
as the 09-13 refresh. Owner: marketing.

Recommended combination: A now (it's cheap and the report is actively wrong until it's fixed), C
at the next natural refresh cadence rather than as an emergency pass.

### 3. Standing gap: no Instagram/LinkedIn keyword or hashtag discovery in Zernio

Today's run again relied entirely on the ForumScout sheet for Instagram/LinkedIn signal, filtering
356 same-day rows down to 4 genuine candidates by hand. This has been a recurring, unchanged
limitation across recent daily runs, not a one-off.

**Option A — Status quo: keep using ForumScout as the substitute.** Effort: zero to set up
(already running), but real ongoing cost is the daily triage burden of filtering hundreds of
irrelevant "fellowship"-keyword rows (political photo-ops, PhD fellowship postings, generic Sunday
posts) down to a handful of real leads.

**Option B — Check whether Zernio itself offers IG/LinkedIn hashtag or keyword discovery on a
higher plan,** since today's tooling only exposed own-account inbox mentions/comments for both
platforms. Effort: low (a docs check or a support question), owner: marketing. Real risk: this may
not exist at any tier — Meta and LinkedIn both restrict third-party discovery access at the
platform level, so a higher Zernio plan might not actually unlock it.

**Option C — Build a custom scraper/monitor outside Zernio** for IG hashtags or LinkedIn keyword
search. Effort: medium-high, owner: engineering. Real risk: likely violates Instagram/LinkedIn
Terms of Service on scraping, carries account-ban risk, and adds an ongoing maintenance burden for
a narrow gain.

**Option D — Tighten the ForumScout filtering itself** (refine the keyword/rule set feeding the
sheet to cut obvious noise categories, e.g. political "fellowship" mentions, PhD postings, before
they reach the daily pipeline). Effort: low-medium, owner: marketing/engineering collaboration.
Doesn't add new discovery, but cuts the daily triage cost significantly.

Recommended starting point: B (cheap to check, might close the gap outright) plus D (worth doing
regardless of B's answer, since ForumScout will remain the IG/LinkedIn source either way).

---

## Drafted replies

### R1 — r/Christianity, "Any one know where to get some group Bible studies?"
**Status: flag before approving — likely duplicate.** This is the *same thread* already given a
full hand-finished reply, recorded in `response-style-guide.md` under its own "R1 — r/Christianity"
entry dated 2026-09-18. That file doesn't explicitly record whether it was ever actually posted
(unlike the R1/R6 entries from 09-17, which do note "drafted, not yet confirmed posted"). Reddit
was unreachable from this environment today, so the live thread could not be checked for an
existing reply from the account. **Check the live thread before approving this — if the 09-18
version already went up, this is a duplicate, not a new opportunity.**

- Platform: reddit — Thread: https://www.reddit.com/r/Christianity/comments/1wjdqi2/any_one_know_where_to_get_some_group_bible_studies/
- Posture: explicit_need — Delivery: comment
- Draft (reusing the existing 2026-09-18 hand-finished text verbatim, not re-run through
  humanizer since it isn't a fresh AI draft):

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

### R2 — r/TrueChristian, "Need help with bible study"
- Platform: reddit — Thread: https://www.reddit.com/r/TrueChristian/comments/1w6t0ub/need_help_with_bible_study/
- Posture: explicit_need — Delivery: comment

> I helped start something almost identical with a few guys at my last job a couple years back.
> First mistake I made: I planned out like six weeks of material before we'd even met once, trying
> to make it feel legitimate. Nobody read any of it. What actually got it moving was way simpler:
> same day every week, one short passage, two or three questions, and honestly more silence than I
> was comfortable with at first so people could actually answer instead of me filling the space.
>
> Work schedules being what they are, the thing that kept people from quietly falling off was
> having somewhere to drop a note or a thought on the days someone had to miss. Not a huge
> feature, just meant nobody showed up the next week completely lost. That's part of why I ended
> up building FellowScript, it does that piece for my own group now. Not saying you need an app to
> start though, the format above is what actually mattered. fellowscript.com if you want to look.

### R3 — r/TrueChristian, "Young adult small group topics"
- Platform: reddit — Thread: https://www.reddit.com/r/TrueChristian/comments/1w2klyq/young_adult_small_group_topics/
- Posture: explicit_need — Delivery: comment

> First time I led a young-adult group I felt exactly this pressure, like I needed a polished
> curriculum before I could even start. I picked a topical series that looked great in the outline
> and it fell flat by week three because it didn't match what the group was actually dealing with.
>
> What worked better the second time: start with a book instead of a topic. A Gospel or a short
> epistle gives you a built-in weekly structure without you having to invent one, and the first two
> or three weeks can just be finding out what people actually want to talk about before you plan
> the rest.
>
> If having something pre-structured would still help you get started, FellowScript runs a daily
> prompt over about a month that you can point at a group, which is the closest thing I've got to
> "predefined curriculum." I'd still build the first few weeks around your group's actual questions
> though, not a script. fellowscript.com

### R4 — r/Christians, "Looking for an Online Bible Study Group That Meets Every Evening"
**No FellowScript mention** — this poster wants an existing group to join, which isn't something
the product does (it's infrastructure for a group that already exists, not a matchmaking service).
Forcing a mention in here would be exactly the "pitching too early" failure the task guidance warns
against, so this is genuine community-pointer advice only.
- Platform: reddit — Thread: https://www.reddit.com/r/Christians/comments/1wbbkc9/looking_for_an_online_bible_study_group_that/
- Posture: explicit_need — Delivery: comment

> This is a tough one to actually solve from the outside, especially wanting it every evening. A
> few things that have worked for people I know in a similar spot: church-hosted online studies
> tend to be more consistent than public ones, even if you're not a member. Most churches will let
> visitors join their weeknight Zoom study if you just email and ask, and a lot of mid-size
> churches run one nightly during specific seasons like Lent or Advent even if not year-round.
> Facebook still has active closed groups for this specific thing (search "online bible study
> nightly" rather than just "bible study") that don't show up well in general search.
>
> Also worth trying: post this same ask in a few church-specific subreddits, since denominational
> ones tend to have more people who actually know of a live group, rather than just the general
> ones. You'll get more specific leads than general encouragement.
>
> I don't have a group to point you to directly, just what's worked for others trying the same
> thing. Hope it helps.

### R5 — r/Bible, "Bible study methods for small groups" — **skipped**
- Platform: reddit — Thread: https://www.reddit.com/r/Bible/comments/1p4b8ql/bible_study_methods_for_small_groups/
- Skip reason: post is from 2025-11-23, roughly 10 months old as of today. Reddit locks most
  threads to new comments well before that age, so a reply here likely can't post at all. Not
  worth drafting.

### R6 — r/Christian, "Bible Study groups online"
- Platform: reddit — Thread: https://www.reddit.com/r/Christian/comments/1ug02wf/bible_study_groups_online/
- Posture: explicit_need — Delivery: comment
- Note: ~3 months old with zero replies so far — verify it's still visible/relevant before posting.

> I don't know your specific setup, but I've watched a friend run something similar for a group
> that's scattered across three states. The thing that actually kept it alive wasn't finding a
> "better" scheduling tool, it was moving from live-call-only to also having a shared place people
> could drop what they read and noticed on their own time, since getting everyone on a call at once
> eventually always breaks down.
>
> That's basically the exact problem that got me building FellowScript: everyone in the group
> reading the same passage and leaving notes on it async, plus the option to hop on a call together
> when schedules line up instead of it being required. Free for a group your size. Not saying it's
> the only way to do this, just what's actually worked for a group in a similar spot to yours.
> fellowscript.com

### R7 — r/TrueChristian, "Is it normal to feel pressured to become a discipleship group leader..."
**No FellowScript mention** — this is a pastoral/personal thread, not a tooling question. Per the
task guidance, this is encouragement only.
- Platform: reddit — Thread: https://www.reddit.com/r/TrueChristian/comments/1wb0v4y/is_it_normal_to_feel_pressured_to_become_a/
- Posture: explicit_need — Delivery: comment

> Felt this almost exactly before I started leading. The pressure usually isn't really about
> qualification, it's about feeling like leading means having it all figured out first, which
> nobody actually does going in. If you're being asked because people trust you, that's usually a
> better sign than feeling "ready" ever is. Worth talking to whoever's asking about what the actual
> expectations are before saying yes or no, since a lot of that pressure comes from an assumption
> about the role that might not even be accurate. For what it's worth, saying "not yet" is also a
> completely legitimate answer if it's genuinely not the season for it.

### R8 — r/Reformed, "Balancing Teaching and Community"
- Platform: reddit — Thread: https://www.reddit.com/r/Reformed/comments/1w9f77b/balancing_teaching_and_community/
- Posture: explicit_need — Delivery: comment

> Co-led a group for a while where a chunk of us didn't live close either, and the teaching part
> was never actually the hard part. It was that community only really happened during the hour we
> were together, then went quiet again all week.
>
> What helped more than anything scheduling-wise: giving people something small to actually do
> between meetings instead of just "read ahead for next week," a specific question tied to the
> passage, somewhere to actually post an answer, so there was a reason to think about each other
> outside the meeting itself.
>
> That's the specific gap FellowScript ended up filling for my own group: notes on the passage that
> everyone in the group can see between sessions, so the conversation doesn't fully reset every
> time you meet. Not a fix for the drive time, but it closes the gap in between. fellowscript.com
> if that's useful.

### R9 — r/Christian, "starting a youth bible study - tips?"
- Platform: reddit — Thread: https://www.reddit.com/r/Christian/comments/1vbwwhq/starting_a_youth_bible_study_tips/
- Posture: explicit_need — Delivery: comment
- Note: a student/youth-group segment can't afford the paid plan, but the group/social layer is
  free and uncapped regardless of group size, so the mention below is cost-honest.

> Led a youth group study for a semester, and the biggest thing I underestimated going in was how
> much energy it takes just keeping teenagers engaged verbally versus adults. Silence reads as
> "boring" way faster with that age group even if they're actually thinking.
>
> What worked: shorter passages than I wanted to use, and building in something visual or
> interactive every single week rather than just discussion, even something as basic as splitting
> into pairs for two minutes before opening back up to the group. Momentum mattered more than depth
> early on.
>
> If it's useful, the group side of FellowScript (shared notes, highlights, messaging) is free with
> no cap on group size, so cost isn't really a factor for a youth group specifically. Not central
> to your question, just flagging it in case a shared space for whatever they write down would
> help. fellowscript.com

### R10 — r/Christian, "Bible Study Question" — **skipped**
- Platform: reddit — Thread: https://www.reddit.com/r/Christian/comments/1nqbpaz/bible_study_question/
- Skip reason: post is from 2025-09-25, roughly a year old. Very likely Reddit-archived/locked for
  new comments. Not worth drafting.

### R11 — r/Baptist, comment on "online live bible studies" (cost_controller, hybrid study, Punggol)
Networking posture: a real host inviting others to a hybrid study, no stated problem. No
FellowScript mention per the networking rules — genuine discovery question only.
- Platform: reddit — Thread: https://www.reddit.com/r/Baptist/comments/1vav812/online_live_bible_studies/paxf5y3/
- Posture: networking — Delivery: comment

> Hybrid is such an underrated setup honestly. Most groups I've seen pick one or the other and
> lose people who can't do whichever wasn't picked. How are you finding the balance between the two
> in practice? Curious whether the online folks end up feeling like a slightly different tier of
> the group, or if it actually blends pretty evenly week to week.

### R12 — LinkedIn, Amanda Nicole, "You're invited to come study with me"
Networking posture: a lay Bible teacher opening up her own study, no stated problem. No
FellowScript mention.
- Platform: linkedin — Post: https://www.linkedin.com/posts/amanda-nicole-b9b854197_youre-invited-to-come-study-with-me-im-activity-7507248635512885248-iJUM
- Posture: networking — Delivery: comment

> Luke 11 and the Lord's Prayer is such a rich place to sit for a whole study rather than rushing
> through it. That prayer holds up to a lot of slow reading. How are you structuring the sessions,
> more discussion-led or do you also teach through it verse by verse? Always curious how other
> people pace something that dense so it doesn't feel rushed.

### R13 — Instagram, impart.supernatural_church, "Online Bible Study is Back"
Instagram → delivery is a DM, not a public comment, per the delivery-channel rule. Networking
posture, no product mention (post doesn't name a problem).
- Platform: instagram — Post: https://instagram.com/p/DdgQua3k5qX
- Posture: networking — Delivery: dm

> Saw your post about Hebrews 11 starting back up. That's one of my favorite chapters to actually
> study slowly instead of skim. Curious how you all handle it for anyone who can't make the live
> session some weeks: do people catch up on their own after, or does it mostly just get missed?
> Always interested in how other online studies handle that gap.

### R14 — Instagram, gatewaybaptistwhitehouse, "Ladies Tuesday Table"
Instagram → delivery is a DM. Networking posture, no product mention.
- Platform: instagram — Post: https://instagram.com/p/DdfXUugx9Db
- Posture: networking — Delivery: dm

> Saw the Ladies Tuesday Table post. That kind of small, in-person setup with scripture and actual
> conversation over treats is honestly the best format IMO, better than a lot of bigger structured
> studies. How long has this particular group been meeting? Curious if it started as something
> bigger and settled into this size, or if it was always meant to stay small and close like this.

---

## Totals

- 4 resolution proposals (indexing, SmartGroups pricing, IG/LinkedIn tooling gap — 3 items, each
  with multiple options)
- 14 queued items reviewed → **12 drafted, 2 skipped**
- Drafted by posture: **8 explicit-need, 4 networking**
- Drafted by delivery: **10 comments, 2 DMs**
- Skipped: **2**, both for likely Reddit archive/lock (age), not self-promotion rules
- **R1 needs a live-thread check before approval** — likely duplicate of an already-drafted (status
  unconfirmed) 2026-09-18 reply to the same thread.

# FellowScript Response Drafts — 2026-09-21

**Draft-only output. Nothing in this file has been posted, replied to, or otherwise published anywhere.** These are proposals for human review, produced by an unattended scheduled process.

**Access limitation, noted plainly rather than worked around:** this run's environment could not fetch Reddit (any subdomain, including the Wayback Machine as a workaround) or Twitter/X (which returned HTTP 402) at all. Every reply below is drafted from today's daily report's own written characterization of each thread, not from a fresh read of the raw post or its comments. Subreddit self-promotion/advertising rules also could not be checked live today for r/Reformed, r/Christianity, r/TrueChristian, or r/Bible. A human should skim the live thread and each subreddit's current rules before approving, especially R1 and R5 (r/Reformed), which have no prior posting precedent in this repo's response-style-guide.md, unlike r/Christianity, r/TrueChristian, and r/Bible, which do.

---

## Resolution options

For the one item flagged "needs a decision today," plus three recurring SEO items from today's SEO check section that are systemic rather than one-off.

### 1. No SSR/prerendering on the marketing routes (Critical — today's flagged decision)

fellowscript.com serves an empty `<div id="root"></div>` for `/`, `/privacy`, and `/terms`; all content only exists after client-side JS runs. Google can render this on a second crawl pass, but Bing, DuckDuckGo, and most AI-answer-engine crawlers largely can't or won't. This plausibly explains the standing "zero organic search results" issue already logged in this repo (task `20260918`).

**Option A — Build-time static prerendering for just these 3 routes** (e.g. react-snap, or a prerender-mode plugin for the existing build tool).
- What it involves: render the existing React build against `/`, `/privacy`, `/terms` at build time, output static HTML for first paint, hydrate on the client as today. No new server component.
- Effort: low-medium — these three pages are static and don't need per-request personalization.
- Owner: engineering (frontend/build pipeline).
- Trade-off/risk: low risk, but the static snapshot needs regenerating whenever marketing copy changes (should be automatable in existing CI). Doesn't help if the marketing site later needs per-request dynamic content.

**Option B — Migrate the marketing shell to a framework with native SSR/SSG** (e.g. a small Next.js or Astro project serving just the public routes, routed at the edge to the same domain, leaving the authenticated app as the existing SPA).
- What it involves: a second, separate frontend project, a new deploy pipeline, and edge/CDN routing changes so `/`, `/privacy`, `/terms` hit the new project while everything behind login still hits the current app.
- Effort: medium-high — new framework, new deploy path, infra changes.
- Owner: engineering, likely needs sign-off from whoever owns infra/deployment too.
- Trade-off/risk: bigger upfront cost, but a more standard long-term setup — worth it mainly if the blog/FAQ expansion in item 3 below also gets greenlit, since that would need more than 3 static pages anyway.

**Option C — Dynamic rendering (serve a prerendered snapshot only to known bot user agents)** via a hosted service like Prerender.io or a self-run Rendertron.
- What it involves: a middleware/proxy layer detects crawler user agents and serves a prerendered snapshot; real visitors still get the client-rendered SPA unchanged.
- Effort: low — mostly configuration against a hosted service.
- Owner: engineering.
- Trade-off/risk: Google has moved away from recommending this pattern, and UA-based content switching can read as cloaking-adjacent if implemented carelessly. Cheapest and fastest, but the least future-proof — treat as a stopgap only if A and B are blocked on capacity, not a destination.

No implementation was attempted — this process has no write access to the FellowScript codebase for this task.

### 2. Title tag and H1 carry no category keyword (High, SEO check)

Current title: `"FellowScript — Walk with God, Together"` (39 chars) — no "Bible study," "group devotions," or similar category term, on either the title tag or the rendered H1.

- **Option A — Direct copy edit**: add a category keyword while keeping the brand phrase (e.g. something like "FellowScript — Bible Study & Group Devotions, Together"). Low effort, marketing owns the copy call, engineering just deploys the string. Risk: could read slightly less distinctive than the current brand-forward title — worth a quick tone check from marketing before shipping.
- **Option B — Stage it as a test** (swap the title, watch impressions/CTR for a few weeks if Search Console or similar is set up) before fully committing. Slower, avoids locking in a worse-performing title.
- **Option C — Bundle with item 3** so keyword strategy across title, H1, and any new content pages gets decided together instead of piecemeal. Slower to ship, more coherent result.

### 3. Only one indexable content route exists — no blog/FAQ/long-tail surface (High, SEO check)

- **Option A — Lightweight FAQ page** targeting long-tail queries small-group leaders actually search ("how to lead a Bible study," "free Bible study app for small groups"). Medium effort: one routing/build change plus marketing-written content, then occasional updates.
- **Option B — Full blog/content program**, CMS-backed, regularly published. Higher effort and an ongoing content commitment from marketing, but the only option that compounds long-tail SEO equity over time.
- **Option C — A small set of static "who this is for" pages** tied to the ICP work already done in `target-audience-profile.md` (e.g. a page for small-group leaders, one for geographically-scattered groups). Medium effort, marketing + engineering, ties SEO work to positioning that's already researched instead of generic content.

### 4. Minimal JSON-LD schema (Medium, SEO check)

- **Option A — Add `sameAs` (social profile links), a `description` field, and a `SoftwareApplication` schema block** alongside the existing `Organization`/`WebSite` schema. Trivial effort, engineering-owned, low risk, no visible user-facing change. No real alternative path here worth laying out separately — this one's simple enough that it's really just "do it."

---

## Drafted replies

9 items from today's report's social-listening / ForumScout review queue, in the order the report listed them. IDs are assigned in that order for approval by ID (e.g. "approve R1, R3").

### R1 — Reddit, r/Reformed — explicit_need — comment

**Thread:** "How do you actually remember what you hear on Sunday?" (2026-09-17, 30 comments)
https://www.reddit.com/r/Reformed/comments/1wiqvuy/how_do_you_actually_remember_what_you_hear_on/

**Draft:**
> I had this exact problem for years. I'd walk out of church locked in on something, and by Wednesday I couldn't even tell you the passage it came from, let alone what I was supposed to do with it.
>
> What didn't work was just telling myself I'd "sit with it" during the week. That's not a plan, that's a hope, and it never survived a busy Tuesday.
>
> What actually stuck: one sentence about what struck me, and one specific way to live it out that week, written down before I even left the building. Then saying it out loud to one other person before Wednesday. The saying it out loud part mattered more than the writing, honestly. It's what kept me from just filing it away and moving on.
>
> That's actually close to the itch that got me building FellowScript, a place where that one sentence is written against the actual passage and a couple people in your group can see it, so it's not just sitting in a notebook nobody else ever looks at. Not saying you need an app for it, just sharing what finally worked for me. fellowscript.com

**Note:** no prior posting precedent in r/Reformed specifically (response-style-guide.md's precedent is r/Christianity, r/TrueChristian, r/Bible). Double-check r/Reformed's current self-promotion rules before approving — could not verify live today.

---

### R2 — Reddit, r/Christianity — explicit_need — comment

**Thread:** "Any one know where to get some group Bible studies?" (2026-09-18, 4 comments)
https://www.reddit.com/r/Christianity/comments/1wjdqi2/any_one_know_where_to_get_some_group_bible_studies/

**Draft:**
> I did something close to this for almost two years, writing a full lesson from scratch every week for a group of about 20. It's genuinely more sustainable to stop doing that than to find better material.
>
> My mistake was treating a thick handout as what made the study feel legit. It didn't. It usually meant I talked more and people engaged less.
>
> If you want ready-made material: The Gospel Coalition has solid free studies, and RightNow Media's library is good if your church has a subscription already. Either way, I'd pick one book of the Bible and go through it slowly rather than jumping topic to topic. It's a lot less prep than building something new every week, and the group tends to go deeper.
>
> That printing and prep grind is actually what got me building FellowScript. Everyone reads the same passage and leaves notes right on it, so there's nothing to photocopy or rewrite. Not saying you need an app for this, just flagging it in case the prep load specifically is the thing wearing you down. fellowscript.com

---

### R3 — Reddit, r/TrueChristian — explicit_need — comment

**Thread:** "Young adult small group topics" (2026-08-30, 6 comments)
https://www.reddit.com/r/TrueChristian/comments/1w2klyq/young_adult_small_group_topics/

**Draft:**
> My first group was young adults too, and I remember staring at a blank page trying to pick "topics" out of thin air. It never held together for more than two weeks.
>
> What worked way better than a topic list: picking one short book and going through it a few verses at a time. Philippians or James are both good for that age group, short enough to finish, practical enough that people actually bring stuff up during the week, not just at the meeting.
>
> Once I had that, staying consistent week to week was the harder part for me, so I ended up building FellowScript around scheduling that plan out in advance so the group gets the next passage automatically instead of me remembering to send it. Not required to run a group well, just what worked for me once I had the book picked. fellowscript.com

---

### R4 — Reddit, r/TrueChristian — networking — comment

**Thread:** "Is it normal to feel pressured to become a discipleship group leader when you still feel like a new Christian?" (2026-09-08, 17 comments)
https://www.reddit.com/r/TrueChristian/comments/1wb0v4y/is_it_normal_to_feel_pressured_to_become_a/

Per today's report, this needs a pastoral tone, not a product pitch — no stated problem here that FellowScript addresses, so no product mention.

**Draft:**
> Yeah, that's a really normal thing to feel, and honestly it doesn't mean you're not ready. A lot of the leaders I know felt pushed into it before they felt qualified, and that feeling didn't really go away until partway through actually doing it.
>
> Is the pressure more about not feeling spiritually equipped yet, or more just the logistics, time, prep, that kind of thing? Those usually need pretty different answers.

---

### R5 — Reddit, r/Reformed — explicit_need — comment

**Thread:** "Balancing Teaching and Community" (2026-09-07, 5 comments)
https://www.reddit.com/r/Reformed/comments/1w9f77b/balancing_teaching_and_community/

Report flags: author co-leads a group, teaches 25 minutes away, distance killing midweek connection — also weighing leaving their church. Draft stays narrowly focused on the midweek-connection question only; deliberately doesn't touch the church-leaving consideration.

**Draft:**
> I've dealt with a version of this, co-leading with real distance between meetings, and the thing that actually hurt us wasn't the teaching. It was that nothing happened between Sundays. The connection only existed for the hour we were physically together.
>
> What helped was giving the group one small thing to respond to midweek: same passage, one question, everybody writes something before the next meeting, distance or not. It's a low bar, but it's the difference between a group that only exists once a week and one that actually knows what's going on with each other.
>
> That's the specific gap FellowScript ended up being built around for me. Everyone's looking at the same passage and notes between meetings even when nobody's in the same room. Not a fix for everything you're weighing right now, just wanted to flag it in case the midweek gap specifically is part of what's wearing on you. fellowscript.com

**Note:** same r/Reformed verification caveat as R1.

---

### R6 — Reddit, r/Christianity — networking — comment

**Thread:** "Bible Study Map" (2026-09-19, 70 upvotes, 7 comments)
https://www.reddit.com/r/Christianity/comments/1wkz57j/bible_study_map/

An artifact share, not a stated problem — no product mention, just a genuine question about their map.

**Draft:**
> This is a great resource to put together, genuinely useful having it all in one visual. How do you keep it updated as your group actually works through it, and does everyone in the group use it, or is it mostly something you maintain and share out?

---

### R7 — Reddit, r/Bible — explicit_need (weak fit) — comment

**Thread:** "Any tips for studying the Bible on my own?" (2026-09-13, 16 comments)
https://www.reddit.com/r/Bible/comments/1wf9qaq/any_tips_for_studying_the_bible_on_my_own/

Solo studier, weaker product fit per today's report. Following the established pattern from response-style-guide.md's R6 entry (same situation, different thread), the product mention stays but with an explicit "works fine solo too" hedge so it doesn't imply the solo studier needs a group feature to answer their actual question.

**Draft:**
> Studying alone is honestly harder to keep up long-term than it looks going in. Not because the material's hard to find, it's that there's no one checking whether you actually did it.
>
> What helped me most: shrinking the sessions way down. One small passage, sometimes just a few verses, then writing one question and one observation before moving on, instead of reading three chapters and retaining basically none of it. Consistency beat how much I read, every time.
>
> Part of why I built FellowScript was that same problem: notes tied to the actual verse, that you can keep totally private or let a couple people see if you ever want some accountability. Works fine solo too, that's not required. Just flagging it in case the staying consistent part is the piece you're missing, same as it was for me. fellowscript.com

---

### R8 — Twitter/X, @ThomisticDan — explicit_need — comment

**Thread:** "Is it 'forsaking my brethren' if I decide to do an online Bible Study instead of going to Sunday Services?" (2026-09-21)
https://twitter.com/ThomisticDan/status/2101832340368413096

Per today's report: complement in-person church, don't position FellowScript as a replacement.

**Draft:**
> Worth separating two things here: "not forsaking the gathering" (Heb 10:25) is about giving up meeting with other believers altogether, not about the specific format that meeting takes. An online study with real back and forth, people actually showing up and engaging with each other, isn't the thing that verse is warning against. Checking out entirely and not being known by anyone is.
>
> Where it gets risky is if online becomes the whole thing and in-person church stops happening at all. You lose the ordinances, the physical body gathered, pastoral care in person. I'd treat online study as something that runs alongside Sunday gathering, not instead of it.
>
> I work on an app (FellowScript) built around exactly that middle ground: async group study between in-person meetings, not a replacement for them. Figured it was relevant given the question. fellowscript.com

---

### R9 — Twitter/X, @fellowshipswfl — networking — comment

**Thread:** two posts describing their "FC Groups" structured program and promoting their own "Group Finder" (2026-09-21)
https://twitter.com/fellowshipswfl/status/2101990404149125569 and https://twitter.com/fellowshipswfl/status/2101990405864574982

A church small-group ministry org already running structured programs, not a direct-help opportunity — relationship-building only, no product mention (they promote their own tool; pitching FellowScript here would be tone-deaf and off-target).

**Draft:**
> Running the same book across every group each semester is a smart way to keep the whole church roughly in step with each other. How do you handle it when an individual group falls behind the shared pace? Do they just catch up on their own, or does the format flex for that?

---

## Totals

9 drafted replies, all set to `pending_approval` (none skipped): 6 explicit-need (R1, R2, R3, R5, R7, R8), 3 networking (R4, R6, R9). All 9 are public comments — no Instagram items in today's queue, so no DMs.

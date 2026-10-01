# FellowScript Response Drafts — 2026-09-28

Follow-up to today's daily digest (`2026-09-28.md`). Everything below is a draft for human review — nothing has been posted, replied to, or DM'd anywhere. This process has no write access to any social platform.

---

## Resolution options

The report's "Top line" and process notes name five systemic issues. None were flagged under an explicit "Needs a decision today" heading, so all five below are the clearly-systemic items raised elsewhere in the report, treated the same way that section would be treated.

### 1. SEO: HashRouter SPA serves identical HTML on /privacy, /terms, /download (highest priority)

The report calls this the one concrete, actionable SEO finding: Google effectively sees one indexable page. Three realistic paths to a fix:

- **Full migration to BrowserRouter + SSR/prerendering.** Move off hash-based routing entirely so every route resolves server-side (a Next.js-style migration, or bolting on a prerendering layer). *Effort: high.* *Owner: engineering.* Most durable fix, but it's a structural rewrite with real regression risk, and old hash URLs already indexed would need redirect handling.
- **Targeted static prerendering for the handful of marketing/legal pages only.** Generate real static HTML with distinct title/meta/canonical for `/privacy`, `/terms`, `/download` specifically (a small build step or an edge-function rule), leaving the authenticated app's own routing untouched. *Effort: medium.* *Owner: engineering, with marketing reviewing the static copy.* Solves exactly the reported problem cheaply; doesn't help any future page added the same way unless the pattern gets reused deliberately.
- **Accept the SPA's limits and build a real blog/resources section with server-resolvable URLs.** Doubles as a content-marketing play (fresh indexable pages over time) rather than just fixing the three existing orphans. *Effort: medium-high.* *Owner: marketing (content) + engineering (route infra).* Doesn't fix `/privacy`/`/terms`/`/download` directly unless paired with option 2.
- **Do nothing structural for now; ship the report's lower-priority stopgaps** (SoftwareApplication schema, footer links to `/privacy`/`/terms`, a longer title tag). *Effort: low.* *Owner: split.* Doesn't touch the root cause; likely marginal impact only.

### 2. ForumScout scan frozen since 2026-09-22 (flagged two days running)

- **Check the ForumScout account/subscription directly** (billing, API key expiry, paused scan). *Effort: low.* *Owner: marketing (account holder).* Fastest path; just needs a human to look.
- **Add a same-day staleness alert** (compare the sheet's newest timestamp against the expected 6-hour cadence, post to Discord if it falls behind). *Effort: low-medium.* *Owner: engineering or marketing, depending on tooling.* Doesn't fix the root cause, but stops multi-day blind spots.
- **Evaluate a second social-listening vendor** if ForumScout's reliability keeps recurring, especially since it also doesn't cover Instagram/LinkedIn (see #3). *Effort: medium.* *Owner: marketing.* Could solve both problems at once, but premature before the account issue itself is diagnosed, and adds cost/migration work.

### 3. Instagram and LinkedIn have no listening coverage at all (standing gap)

- **Accept the gap** and rely on occasional manual browsing outside the pipeline. *Effort: low (time only).* *Owner: marketing.* No new cost, systematic blind spot stays.
- **Add a listening tool with real IG/LinkedIn public search** (Brandwatch, Mention, Talkwalker, or check whether ForumScout has a higher tier that covers it). *Effort: medium.* *Owner: marketing (budget), light engineering integration.* Real cost — worth confirming the ICP (small-group leaders) is actually reachable there before spending.
- **Weekly manual spot-checks on a known short list of hashtags/accounts**, rather than daily automation. *Effort: low.* *Owner: marketing.* Partial coverage, no new spend.

### 4. `market-seo` skill's documented `analyze_page.py` doesn't exist in this install

- **Fix/restore the script** so future SEO runs don't need the curl/WebFetch workaround. *Effort: low–medium.* *Owner: engineering (skills maintainer).*
- **Leave it and document the manual workaround as the standard procedure.** *Effort: none.* Each future run repeats the slower manual path.

### 5. Reddit rate-limited mid-scan (5 of 22 searches never ran)

- **Add pacing/backoff to the Reddit search step** (space calls out, or split the day's searches across two passes). *Effort: low-medium.* *Owner: engineering (pipeline tuning).*
- **Trim the daily search list to the highest-value queries first**, so the cap is rarely hit. *Effort: low.* *Owner: marketing.* Simpler, but may reduce total candidates found.
- **Leave as-is**, relying on the resume-and-recover behavior that already worked today. *Effort: none.* Keeps losing ~20% of scan days to the limit, but it's proven survivable.

---

## A note on ForumScout's "3 genuine candidates"

The ForumScout section of today's report states "3 genuine candidates remain — see queue below," but the report's own "Queued for human review" tables (Strong fits + Lower priority) contain only Reddit, X/Twitter, and YouTube items — no Instagram or other ForumScout-sourced entries appear anywhere in either table. This looks like a gap in today's report itself (the 3 candidates were identified in prose but never actually written into the queue). Rather than invent what those 3 items might be, this is flagged here for a human to check against the source ForumScout sheet directly. No R-numbered draft exists for them.

---

## Drafted replies

All 13 items from the report's "Strong fits" and "Lower priority / optional" tables are covered below, in the order the report listed them. Every draft was run through the `humanizer` skill. **Caveat:** live subreddit-rule checking wasn't possible this run — `reddit.com` (including `old.reddit.com`) is unreachable from this environment's fetch tool, and web search didn't surface the specific rule text for any of the relevant subreddits. Drafts below follow the same disclosed-affiliation pattern already used successfully on similar general-Christian subreddits per `response-style-guide.md`, but a human should give the actual subreddit sidebar/rules a quick look before posting, especially R1 (r/pastors) and R9/R10 (r/Christian, r/Reformed), which haven't had a prior posted example in the style guide.

### R1 — Reddit r/pastors — explicit need — comment

[Advice needed: transitioning a Sunday-only church](https://www.reddit.com/r/pastors/comments/1vlkmzq/advice_needed_how_do_we_transition_a_12yearold/)

> I went through something similar trying to get relational groups going in a church that was pretty comfortable just showing up Sunday and leaving. What actually got traction wasn't announcing a new "small groups program." That stalled out immediately. It was asking four or five of the most engaged people directly, one at a time, if they'd try meeting every other week, with no pitch to the whole church at all.
>
> The other thing that mattered was giving that first group something to do between Sundays: a passage to sit with, a question to answer, so the group existed outside the meeting itself and not just as a calendar event.
>
> That's actually the piece I ended up building an app around. I work on FellowScript, and it keeps a small group on the same passage and notes between meetings so there's something happening midweek without you having to manage it by hand. Not saying you need an app for that part specifically, but if that's the gap you're hitting, it might be worth a look: fellowscript.com

### R2 — Reddit r/Christians (+ cross-post r/pastors) — explicit need — comment

[Bible Study Group – Where to Start???](https://www.reddit.com/r/Christians/comments/1uvitwh/bible_study_group_where_to_start/) / [r/pastors cross-post](https://www.reddit.com/r/pastors/comments/1uvx0zl/bible_study_group_where_to_start/)

> I got handed a mixed-age group with zero warning a couple years back, and the first few weeks were rough because I was trying to teach it like a class instead of run it like a conversation. What worked was picking one short passage a week, showing up with three or four real questions (not trivia, more like "where have you actually felt this" type questions), and just letting people talk instead of filling every silence myself.
>
> The other thing that helped a lot: having everyone's notes and highlights visible to the rest of the group instead of just in my own head. People engage more when they can see what someone else in the room actually thought about a verse before they show up.
>
> That's part of why I built FellowScript. I work on it, it's free to start for a group your size, and the shared notes and highlights piece is basically that same idea, just not dependent on me remembering to relay it. Not a requirement to run a good group by any means, just flagging it in case the visibility piece is the part you're missing too: fellowscript.com

### R3 — Reddit r/Christian — explicit need — comment

[Bible Study groups online](https://www.reddit.com/r/Christian/comments/1ug02wf/bible_study_groups_online/) — scattered friend group across churches, precise fit for the §5.2 async-groups segment.

> I've got people in my life going through basically this exact problem. Everyone's in a different city on a different schedule, and nobody's ever going to land on one Zoom time that works for more than half the group. What ended up working wasn't trying to schedule around it at all. It was giving up on "meeting" as the unit and making the passage the unit instead: same reading, same week, everyone goes through it on their own clock, then you check in on what people noticed whenever you're both free.
>
> That's actually the exact problem that got me into building FellowScript. I work on it, and it's built around exactly that: a group reads the same passage async and can see each other's notes and highlights on it without needing to be online at the same time. Not the only way to do this, but if the scheduling wall is the actual blocker for you all, might be worth a look: fellowscript.com

### R4 — X/Twitter @ThomisticDan — explicit need — comment (no product mention)

[@ThomisticDan — "forsaking my brethren" if I do online instead of Sunday services?](https://twitter.com/ThomisticDan/status/2101832340368413096)

This is a genuine discernment question, not a tool/recommendation ask — the real need here isn't product-shaped, so per the diagnose-first guidance no FellowScript mention is included.

> Genuinely don't think it has to be one or the other. Hebrews 10:25 is about not giving up gathering altogether, not really a referendum on medium. The actual danger it's warning against is isolating yourself, not picking Tuesday night over Sunday morning. If the online thing is on top of real relationships where people actually know you, not a replacement for ever being known by anyone, I don't think you're forsaking anything. If it's quietly becoming the only place you show up though, that's worth being honest with yourself about. The format's not really the test, the isolation is.

### R5 — YouTube "Things to Put Away" (Eph 4:25-32) — networking — comment (no product mention)

[All Things New w/ Barry E. Fields / Executive Pastor Jerry Gifford](https://youtube.com/watch?v=63-OTJ7iWPo)

Active study group, no stated problem — pure relationship-building comment with a genuine discovery-style question.

> Just watched this. Really appreciated how much time you gave to the "do not let the sun go down on your anger" part instead of rushing past it like a throwaway line. Curious how you all handle it when the passage points at something specific someone in the group is visibly still working through in real time: do you let the conversation sit there, or steer it back to the text?

### R6 — YouTube Divine Service LIVE — networking — comment (no product mention)

[Toronto Church SDARM weekly group Bible study](https://youtube.com/watch?v=qCsiLT-BT8E)

> Been sitting in on a few of these kinds of live group studies lately, and what strikes me about the weekly rhythm is how much it changes the kind of questions people ask compared to a one-off study. You get to actually build on what came up the week before instead of starting cold every time. How do you all keep track of what was said in past weeks so it actually carries forward, or is it more just whoever remembers?

### R7 — Reddit r/Bible — explicit need — comment

[Question for people who bible journal!](https://www.reddit.com/r/Bible/comments/1vsmnre/question_for_people_who_bible_journal_3/)

> I went through a stretch where my journaling started feeling like it was just for me, and honestly it made me journal less because there wasn't really a point to it beyond, well, me. What got me writing consistently again wasn't changing how I journaled. It was having one or two other people actually see what I wrote down sometimes, not to turn it into a whole group thing, just enough that it felt like it mattered past my own notebook.
>
> That's actually part of why I ended up building FellowScript. I work on it, and your highlights and notes can stay private or be visible to a couple people if you want, so it's not all or nothing between a private journal and a full group study. Not saying that's the only fix, just flagging it since the insular feeling is exactly what pushed me toward it: fellowscript.com

### R8 — Reddit r/TrueChristian — explicit need — comment (no product mention)

[Question about small groups](https://www.reddit.com/r/TrueChristian/comments/1wgfzk7/question_about_small_groups/) — seeker wants to join a group; report notes "human reply only," product angle too thin.

> Honestly the fastest way in is usually just asking, awkward as it feels. Most churches have small groups running that never make it onto a website or bulletin. Email or catch the pastor after a service and ask directly if there's a group for your age or stage, they'll almost always know one that has room. If the church itself doesn't have anything, campus ministries (if you're near a college) or a place like Cru or InterVarsity often run open groups that don't require being a student. Showing up once as a guest before committing is completely normal too, most groups expect that.

### R9 — Reddit r/Christian — explicit need — comment (no product mention)

[Starting a youth bible study – tips?](https://www.reddit.com/r/Christian/comments/1vbwwhq/starting_a_youth_bible_study_tips/) — campus/youth segment is deferred per the ICP doc §5.1, so no product mention.

> Biggest thing I'd say for youth specifically: keep the ratio of talking to listening way more toward listening than you think you need to. Teenagers can smell a lecture coming and check out fast. Pick one short passage, ask questions that don't have an obvious "Sunday school answer" (things like "when has this actually been hard to believe for you"), and let uncomfortable silences sit instead of filling them yourself. Food helps more than curriculum does, in my experience. A good study with pizza will outlast a great curriculum with nothing to eat.

### R10 — Reddit r/Reformed — explicit need — comment (no product mention)

[Looking for discussion questions / one-day studies](https://www.reddit.com/r/Reformed/comments/1uyzxps/looking_for_discussion_questions_one_day_bible/) — one-off study, low product fit.

> For one-off studies, Ligonier's got a decent free library of single-session studies with discussion questions already built in, and The Gospel Coalition has some shorter topical ones too if you're looking for something not tied to a whole book. If you want to write your own instead, the simplest structure I've found is one observation question (what does the text say), one interpretation question (what does it mean), and one application question (what do we do about it). Keeps you from either over-preparing or winging it.

### R11 — Reddit r/Christianity — explicit need — comment (no product mention)

[Recent bad experience with a new bible study group](https://www.reddit.com/r/Christianity/comments/1ws2lak/recent_bad_experience_with_a_new_bible_study/) — pastoral support situation; report says "skip unless replying purely as a person," so this is a pure supportive human reply with no marketing content at all.

> Sorry you went through that. A bad first experience with a group can make you gun-shy about trying again, which is a real loss because a genuinely good group is worth having. For what it's worth, one bad group usually says more about that specific group's culture (who's running it, how open people actually are) than it does about groups in general or about you. If you're up for trying again at some point, it might help to sit in as a guest once or twice before committing, so you can get a read on the group before you're emotionally invested in it.

### R12 — Reddit r/youthministry — explicit need — comment

[How do you study the Bible together outside of youth group](https://www.reddit.com/r/youthministry/comments/1q6pm7u/how_do_you_study_the_bible_together_outside_of/) — verbatim match for the shared-notes value prop, but the thread is roughly 9 months old and likely too stale for the poster to see. Drafted anyway per the instruction to cover every queued item; flagging low odds of reaching anyone.

> When I've tried to get something going outside of a scheduled meeting, the thing that actually worked wasn't a new meeting time. It was picking one passage a week that everyone reads on their own and then just checking in on it whenever people happened to be around, not scheduling a whole second gathering.
>
> That's basically the exact thing I ended up building FellowScript around. I work on it, and a group stays on the same passage during the week and can see each other's notes without needing to coordinate a time. Thread's a bit old so not sure this'll reach you, but leaving it here in case it's still useful: fellowscript.com

### R13 — Reddit r/TrueChristian — explicit need — comment (no product mention)

[Genuine question: why aren't Christians more familiar with the Bible?](https://www.reddit.com/r/TrueChristian/comments/1wmr4tb/genuine_question_why_arent_christians_more/) — high-traffic (161 comments), tangential thread; genuine engagement only, no product angle.

> I think a big piece of it is that a lot of people were taught Bible stories as kids and never re-engaged with the text as adults with adult questions, so the familiarity stalls out at a Sunday-school level and never gets refreshed. It's also just genuinely long and non-linear compared to almost anything else people read, so without some structure (a plan, a group, a teacher) most people don't know where to start past Genesis and the Gospels.

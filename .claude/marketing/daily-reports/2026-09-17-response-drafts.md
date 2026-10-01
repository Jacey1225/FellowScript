# FellowScript Marketing — Response Drafts for 2026-09-17

Unattended draft-only run, generated as a follow-up to today's daily marketing digest
(`2026-09-17.md`). Nothing in this document has been posted, replied to, or otherwise published
anywhere. Every item below is a proposal for a human to review, edit, and explicitly approve —
posting happens only after that approval, and is carried out by the separate always-on marketing
bot that reads the `#prefect-victory` channel, not by this process.

**A note on verification limits (read before approving any Reddit item):** this run could not
reach Reddit directly — both `www.reddit.com` and `old.reddit.com` are blocked for this process's
web-fetch tool, and web search did not surface the specific current rules text for the five
subreddits involved (r/TrueChristian, r/Reformed, r/Christianity, r/Bible, r/pastors). Per the
task's own instruction to verify self-promotion rules "where fetchable," none of these could
actually be checked live today. None were skipped on the assumption they prohibit self-promotion,
since there was no positive evidence of that either — but **a human should sanity-check the
specific subreddit's current rules before approving any reply below that names FellowScript**,
rather than trusting this run's judgment on that point. Similarly, R1's note about the poster's
handle looking startup-suffixed could not be checked (profile pages are behind the same fetch
block) — verify that manually too before approving R1.

---

## Resolution options

For the three systemic items flagged in today's report's "Needs a decision today" section.

### 1. Privacy/Terms footer links still missing

Flagged multiple days running as a five-minute fix; still not shipped as of today's SEO audit,
even though the team demonstrably shipped a different, harder static-HTML fix (the meta-tag
build-time injection) the evening before. This isn't a technical blocker, it's a
prioritization/backlog gap.

- **Ship it directly.** Add `<Link to="/privacy">` and `<Link to="/terms">` to the existing footer
  component. Effort: minutes. Owner: frontend/whoever has quick write access. Risk: none.
- **Bundle it as a fast-follow on the pipeline that just proved itself.** The same person or
  pipeline that shipped the meta-tag injection on 9/16 evening already has working deploy
  machinery for static-head changes; ask them to add the two footer links in the next push rather
  than treating it as a separate ticket. Effort: minutes. Owner: same engineer.
- **If it keeps slipping because nobody owns small trust/SEO nits, give it a home.** A pinned
  issue or standing checklist item so this doesn't require rediscovery via the marketing report
  every day. Effort: minutes to set up. Owner: marketing/eng coordination.

### 2. Single crawlable URL / `HashRouter` structural ceiling

The real blocker to ranking for anything beyond the brand name — `robots.txt`/`sitemap.xml` list
`/#/privacy` and `/#/terms` but neither is independently server-resolvable. This has an
obvious "right" long-term fix, but three realistic paths exist depending on appetite for risk and
timeline:

- **Full migration to `BrowserRouter` + SSR/SSG** (e.g., move to Next.js, or add a proper
  server-side render/prerender layer to the existing React app). Gives every route
  (`/reader`, `/account`, `/privacy`, `/terms`, and any future route) a real, independently
  crawlable URL — the complete fix, and what unlocks future SEO work like a comparison page.
  Effort: high, likely multi-week, closer to a framework migration than a patch. Owner:
  engineering, probably as its own project rather than a quick PR. Risk: real — touches routing
  behavior for an app with an existing signed-in user base; needs careful QA around auth/session
  flows currently tied to the SPA.
- **Add a prerendering layer on top of the current SPA** (e.g., `react-snap`, Prerender.io, or a
  custom build-time static-HTML snapshot per route) that serves fully-rendered HTML to
  crawlers/bots while real users still get the live, hydrated app. This extends the same
  build-time-injection approach the team just proved out for meta tags on 9/16 to a handful of
  actual routes instead of just the `<head>`. Effort: medium, days rather than weeks, reuses
  existing pipeline knowledge. Owner: engineering, likely the same person who shipped the
  meta-tag fix. Risk: low — doesn't change routing behavior for real users, only what's served to
  non-JS clients.
- **Minimal version: leave the router untouched, add a few genuinely static pages outside the
  SPA** for the highest-value routes only (a plain static `/privacy.html`, `/terms.html`, and
  eventually a comparison page), then point `sitemap.xml`/`robots.txt` at those instead of the
  hash fragments. Effort: low, a day or two. Owner: engineering, or even marketing/design working
  from a template. Risk: creates a small ongoing maintenance seam (two systems to keep in sync),
  but unblocks the two orphan pages immediately without waiting on a bigger routing project.

Unblocking the orphan pages fastest favors the third option; the second is the best medium-term
fix given the team's already-proven build-time-injection approach; the first is the actually
correct long-term fix but is a real project, not a quick win.

### 3. SmartGroups' trust & safety build-out (competitive signal)

SmartGroups — already flagged as FellowScript's closest feature comparable — shipped automated
CSAM/adult-content scanning, human-review quarantine, and a structured moderation audit trail
(~Aug 27 2026), positioning it toward church/institutional buyers.

- **No action beyond the next competitor-report refresh.** Purely informational for now. Effort:
  none. Owner: marketing (already planned). Risk: if a pastor or denominational buyer asks about
  content-safety posture before FellowScript has an answer ready, SmartGroups increasingly has one
  and FellowScript doesn't.
- **Marketing-only response: a short internal one-pager on FellowScript's actual current
  moderation posture** (whatever genuinely exists today, even if informal), so outreach
  conversations with leaders/pastors can answer a safety question honestly without over-claiming.
  Effort: low, a few hours, needs a fact-check pass from whoever actually knows current practices.
  Owner: marketing, with engineering/trust input. Risk: doing this honestly might surface that
  current safeguards are thinner than assumed — worth knowing regardless of whether the one-pager
  ships.
- **Product/engineering response: evaluate real content-safety tooling** (e.g., scanning uploaded
  image attachments, since S3+GIF attachment support already exists) given the product allows
  free-form notes, DMs, and images inside groups that could include minors. Effort: medium-high,
  real engineering plus a security/compliance review — this is exactly the kind of change the
  `security-compliance` skill exists to gate. Owner: engineering + security review, likely its own
  `/build` task. Risk: real scope creep if not bounded, but stops being optional if FellowScript
  ever markets toward youth groups or church-affiliated institutional buyers.
- **Middle path: no new build now, but make sure the existing security/compliance review already
  required for infrastructure/data-handling changes explicitly covers this gap** next time
  anything touching groups, DMs, or attachments changes, so it isn't discovered reactively.
  Effort: none now. Owner: whoever maintains that review's scope/documentation.

The honest one-pager is the lowest-risk immediate step. The product/engineering response is worth
prioritizing only if FellowScript's positioning shifts toward church/institutional buyers —
`target-audience-profile.md` currently argues the opposite (leader-first, non-denominational small
groups, explicitly not diocese/institutional-scale), so treat this as "watch, don't chase yet"
unless that changes.

---

## Drafted replies

14 items from today's report's review queue — 8 from Zernio/Reddit, 6 from ForumScout. Each gets
a short ID (R1–R14) in the same order the report listed them, so approval can reference IDs (e.g.
"approve R1, R3").

### R1 — reddit — explicit_need

**Thread:** r/TrueChristian — "How do you actually remember what you hear on Sunday?"
https://www.reddit.com/r/TrueChristian/comments/1wiqwvv/how_do_you_actually_remember_what_you_hear_on/

**Caution (unverified, check before approving):** today's report flagged the poster's handle
(`cirlorm_io`) as having a startup-style suffix, worth checking in case it's competitor-seeded.
Reddit profile pages were not reachable from this run to check.

**Draft:**
> For me it was never really about which tool: notebook vs. app vs. whatever. It was building the habit of going back to my notes mid-week instead of taking them and letting them sit. I write 2-3 lines during the sermon, then Tuesday or Wednesday I reread them and try to connect them to whatever I'm reading on my own. That's the part that actually made things stick.
>
> The other thing that helped more than I expected: linking notes to the actual verse instead of just a page in a notebook, so when I come back to that passage later the note is right there. I work on FellowScript, which does this and lets a group see each other's notes on the same verses. It turned my private note-taking into something my group actually talks about during the week, not just Sunday. The group-visibility part is what took it from a discipline I kept meaning to do to something that actually happens.

### R2 — reddit — explicit_need

**Thread:** r/Reformed — "Balancing Teaching and Community"
https://www.reddit.com/r/Reformed/comments/1w9f77b/balancing_teaching_and_community/

**Draft:**
> This is the tension every small group leader I know eventually runs into: teaching and closeness end up fighting each other for the same 90 minutes. What's helped the groups I've seen handle it well is moving some of the "life together" part to the days between meetings instead of cramming it into group night. A shared thread where people drop what they're actually chewing on from the week, not just prayer requests but actual verses and notes, does more for closeness than an extra 20 minutes of chit-chat at the start of group.
>
> I work on FellowScript, which is built for that gap: notes tied to specific verses that the whole group can see, so people are engaging with scripture together on a Tuesday, not just Sunday. It wouldn't replace your teaching time, just gives the community side somewhere to live during the week.

### R3 — reddit — explicit_need (no product angle)

**Thread:** r/Christianity — "How to split costs in a Bible study group?"
https://www.reddit.com/r/Christianity/comments/1wgon2y/how_to_split_costs_in_a_bible_study_group/

No FellowScript mention — cost-splitting isn't something the product addresses, so this is a
genuinely helpful reply only.

**Draft:**
> We ran into this with our group once it grew past a dozen people. What worked for us: one person (usually the host) fronts the actual consumables (coffee, snacks) and everyone venmos a flat $5-10 whenever they come, no tracking who owes what for which week. If you're doing a shared meal or study materials specifically, a simple sign-up sheet where people bring or pay for one thing on rotation avoids the awkward "settle up" conversation entirely. Whatever you land on, the earlier you name it out loud as a group instead of letting the host quietly absorb it, the less resentment builds up later.

### R4 — reddit — explicit_need

**Thread:** r/pastors — "Bible Study Group - Where to Start???"
https://www.reddit.com/r/pastors/comments/1uvx0zl/bible_study_group_where_to_start/

**Flag:** thread is from 2026-07-14, about two months old — check it's still live and the poster
hasn't already found an answer before approving.

**Draft:**
> Starting from scratch, I'd pick one thing over trying to do it all at once: either a single book of the Bible (a gospel or one of Paul's shorter letters works well for a first group) or a short topical study with a workbook already built, rather than writing your own curriculum in year one. Keep the first few weeks light on teaching and heavy on just getting people talking. How the group functions matters more early on than how deep the material is.
>
> For keeping people engaged between meetings (I work on FellowScript, so full disclosure), the biggest lift for a brand-new group is usually just having somewhere people can drop a note or a verse that stuck with them during the week. It doesn't have to be an app, but something has to exist there or the group only exists on meeting night.

### R5 — reddit — explicit_need (no product angle)

**Thread:** r/Reformed — "Looking for a Bible Study"
https://www.reddit.com/r/Reformed/comments/1tt8rc3/looking_for_a_bible_study/

**Flag:** thread is from 2026-05-31, about 3.5 months old — the most stale item in today's queue.
Verify it's still live before approving. No FellowScript mention — this is a curriculum question,
not a tooling one.

**Draft:**
> For curriculum specifically, a few that hold up well across different maturity levels in a group: Jen Wilkin's studies (especially if you want something more inductive/text-driven than workbook-driven), or The Gospel Coalition's women's studies if you want something free and solid theologically. If you're running four studies at once, the biggest practical win isn't the material, it's making sure each group has its own designated discussion leader rather than you trying to be present for all four — burnout is the real risk at that scale, not curriculum quality.

### R6 — reddit — explicit_need (weak fit, no product angle)

**Thread:** r/Bible — "Any tips for studying the Bible on my own?"
https://www.reddit.com/r/Bible/comments/1wf9qaq/any_tips_for_studying_the_bible_on_my_own/

Solo studier, no stated interest in a group or tool — no FellowScript mention, per the
diagnose-before-you-pitch guidance (forcing a group product into a solo-study answer would be the
same "pitching too early" failure the task guidance warns against).

**Draft:**
> The thing that changed my own solo study the most wasn't a method: it was picking a single small chunk (like one chapter, sometimes just a few verses) and actually writing down one question and one observation before moving on, instead of reading a few chapters and moving on with nothing captured. Consistency beats coverage by a lot. A few verses a day with a note beats three chapters skimmed.
>
> If you ever find yourself wanting a second set of eyes on what you're seeing in the text, even a couple friends doing the same passage on their own time and comparing notes once a week can make solo study feel less like reading into a void. Not necessary, just something that's helped people I know stick with it longer.

### R7 — reddit — explicit_need

**Thread:** r/Christianity — "College Bible study" (Louisville)
https://www.reddit.com/r/Christianity/comments/1wfmg6m/college_bible_study/

**Draft:**
> Starting a college group, the two things that make or break the first semester: pick a low-commitment first study (something short, 6-8 weeks max) so people can commit without it feeling like a huge ask, and get someone other than you to help host or lead discussion early so it doesn't become "your" group that only exists when you show up.
>
> For keeping everyone on the same page during the week (disclosure: I work on FellowScript), it's free for a group your size. The part that's actually useful for a college group specifically is that everyone can see each other's notes on the same verses, which tends to spark more conversation in the group chat than just a reminder text about when you're meeting next.

### R8 — reddit — explicit_need (weak fit, disclosed but low-key)

**Thread:** r/Bible — "Which Bible app can set up custom reading plans?"
https://www.reddit.com/r/Bible/comments/1wigiy6/which_bible_app_can_set_up_custom_reading_plans/

FellowScript's devotion plans are group-shared, not a personal custom-plan builder — the draft
says so directly rather than overclaiming a feature match that isn't real.

**Draft:**
> For actually custom, build-your-own reading plans, YouVersion (Bible App) is still the most flexible for that specifically: you can build a plan from scratch, not just pick from their library. If you want plans built around specific dates or a group of people finishing together (like a New Testament in 90 days with friends), that's a different feature set worth checking depending on the app.
>
> Not a perfect fit for what you're asking, but flagging in case it's useful: FellowScript (I work on it) does group devotion plans rather than personal custom reading plans. Good if the actual goal is reading with people, not so much if you specifically want a solo custom plan builder.

### R9 — reddit — explicit_need

**Thread:** r/Christianity — "Fellowship"
https://www.reddit.com/r/Christianity/comments/1wipg4r/fellowship/

The clearest direct ask in today's queue — "Love to get connected."

**Draft:**
> The most reliable way I've seen this actually happen (versus just browsing church websites) is asking your own church directly if they have a small groups or connect ministry. Most do but don't advertise it well, so you sometimes have to ask a staff member by name rather than looking for a sign-up on the website. If you're between churches or don't have one yet, a lot of denominational sites (PCA, Acts29, EFCA, etc.) have church finders that let you filter by size, which tends to correlate with how active the small group culture is.
>
> Once you're in a group, honestly the harder part is staying connected between meetings rather than finding the group in the first place. That's the part I've seen trip people up more. (I work on FellowScript, which is built around exactly that gap, if it's useful once you're in a group and not just looking for one.)

### R10 — reddit — networking

**Thread:** r/Christianity, comment by hendrixski
https://www.reddit.com/r/Christianity/comments/1wfek8t/i_hate_that_god_created_me/pac9tes/

Personal story about finding community after Covid-era loneliness. No product mention — a curious
question in the spirit of the post, not a pitch.

**Draft:**
> This really resonates. The isolation from that stretch was rough for a lot of people, and it's interesting how many folks I've talked to trace their way back through exactly this: a specific group of people rather than church in the abstract. Curious what made the friendships stick for you after. Was it a regular group/Bible study structure, or more organic than that? I've noticed the people who stay connected long-term usually have some kind of recurring touchpoint, even a small one, versus just seeing each other on Sundays.

### R11 — twitter — networking

**Thread:** @GPC_WaiyakiWay — "Church Away Day"
https://twitter.com/GPC_WaiyakiWay/status/2100520586506076202

**Draft:**
> An away day is such an underrated format. Something about getting people out of the building changes the conversations that happen. What's the food and activities lineup looking like? Always curious how churches balance structured programming vs. just leaving room for people to actually talk.

### R12 — twitter — networking

**Thread:** @ucf_kampala — "Church, but make it brunch"
https://twitter.com/ucf_kampala/status/2100524923609399384

**Draft:**
> Love this framing. Brunch does something a regular service slot doesn't: people linger instead of rushing off. How'd this format come about? Was it a response to people not sticking around after the usual service, or something you started fresh?

### R13 — linkedin — networking

**Thread:** Deborah's Tribe — "2nd GEM Experience in Kenya"
https://www.linkedin.com/posts/deborah-s-tribe-025502427_deborahstribe-gemexperience-kenya-activity-7506293108624564224-WxZR

**Draft:**
> This looks like such a meaningful gathering. Curious how the GEM Experience has evolved between the 1st and 2nd one. Did you change the format based on what you learned the first time around, or keep the core the same and just build on it?

### R14 — twitter/linkedin — networking

**Thread:** LEMP Online Bible Study (cross-posted)
https://twitter.com/LEMPMentorship/status/2100538852502876601 and
https://www.linkedin.com/posts/livingeffectivelymentorshipprogram_lemp-activity-7506301621426122752-Zfj_

Same draft usable on either platform since it's the same cross-posted announcement.

**Draft:**
> A weekly interdenominational study that's actually sustained is genuinely hard to pull off. Curious what's kept people coming back week over week. Is it the topic rotation, the group itself, or something about the online format specifically that's made it stick where a lot of online studies fizzle?

---

*Draft-only output. No posting, replying, or engagement occurred anywhere during this run. Reply
"approve R1, R3" (or similar) in this channel to move specific drafts forward, or describe an edit
and a revised draft can be produced.*

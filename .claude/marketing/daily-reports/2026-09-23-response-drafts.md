# FellowScript Response Drafts — 2026-09-23

Scheduled/unattended follow-up to today's daily marketing digest. **Everything below is a draft
for human review. Nothing has been posted, replied to, DM'd, or otherwise published anywhere.**
Approval and actual posting happen separately, via the always-on marketing bot reading
#prefect-victory.

**Reach limitation this run:** every attempt to fetch a live Reddit thread or subreddit
rules page (`reddit.com`, `old.reddit.com`) failed — this environment cannot reach the
`reddit.com` domain at all today. All 11 Reddit drafts below are grounded only in today's
`2026-09-23.md` report's own social-listening summaries, not the raw threads. That matches
the known caveat in `response-style-guide.md` ("thread content there is sometimes just the
pipeline's summary... verify against the live thread when possible") — today it genuinely
wasn't possible. **Verify each Reddit thread live before approving**, especially subreddit
self-promotion rules, which could not be checked for any of the 11 (r/Reformed in particular
is new territory for this queue and has no prior successful post on file, unlike
r/Christianity, r/TrueChristian, and r/Bible).

Instagram and YouTube pages fetched successfully and are reflected in the drafts below.

---

## Part 1 — Resolution options

### 1. Google indexing still zero, despite the 403 clearing

The reachability blocker (403) that was present as of 09-13 and possibly 09-22 is gone —
`fellowscript.com` returns a clean 200 today. `site:fellowscript.com` still returns nothing.
Task `20260918-fix-google-indexing-audit` remains open and unresolved.

- **A. Verify the Google Search Console property and read the Page Indexing report.**
  Effort: low. Owner: marketing (GSC account holder) with engineering on standby if DNS/CF
  changes are needed. Confirm the property is still verified, read the specific exclusion
  reason(s) GSC gives per URL (e.g. "Discovered — not indexed," "Crawled — not indexed," or an
  outright manual action / security issue), and explicitly request indexing via the URL
  Inspection tool. This is the cheapest, most direct diagnostic and should happen first,
  regardless of what else gets done — none of today's automated checks can see GSC at all.
- **B. Audit Cloudflare's Bot Fight Mode / WAF rules specifically for Googlebot.** Effort: low.
  Owner: engineering (Cloudflare access). A normal-UA fetch returning 200 does not prove
  Googlebot gets the same treatment — Cloudflare can serve a JS challenge only to
  unrecognized or automated user agents/IP ranges. Check the firewall event log filtered to
  Googlebot's declared UA and IP ranges, and Cloudflare's own verified-bot allowlist settings.
  Trade-off: loosening Bot Fight Mode broadly has a real security cost; the safer version of
  this fix is explicitly allowlisting verified Googlebot rather than turning protections down
  in general.
- **C. Rule out a manual action, and rule out name-collision confusion.** Effort: very low.
  Owner: marketing (GSC "Manual actions" / "Security issues" panels). Also worth noting, not
  fixing: an unrelated, long-running Christian writers' magazine already uses the "FellowScript"
  name and currently outranks the app in search — not something to act on, just useful context
  for why a `site:` search alone can look confusing.
- **D. If A–C come back clean, treat it as a freshness/patience problem and re-check in 1-2
  weeks.** Effort: none but time. Owner: nobody, just a calendar reminder. Should be the
  fallback after the real diagnostics, not the first move — assuming "it'll just resolve
  itself" without checking GSC/Cloudflare first risks leaving a real blocker in place
  indefinitely.

Recommended order: A, then B, then C as a quick side-check, D only as a backstop.

### 2. Thin sitemap / no content depth (SPA + HashRouter architecture)

The sitemap lists exactly one URL by design, since the app is a client-rendered SPA with no
server-rendered routes for Google to index even once the indexing blocker clears. This is the
"obvious right fix, but still worth laying out real paths" case:

- **A. Add prerendering for the handful of marketing-relevant routes** (homepage, `/download`,
  `/signin`, any future landing pages) via a prerender service or a build-time static-HTML
  export. Effort: medium. Owner: engineering. Standard SPA-SEO fix: crawlers get real static
  HTML without executing JS, while the authenticated app itself stays exactly as it is.
  Trade-off: adds a build step and a new dependency (self-hosted renderer or a third-party
  service), but is the lowest-effort path to real content depth.
- **B. Stand up a small server-rendered or statically-generated marketing shell** (e.g. a thin
  Next.js/Astro site) in front of the SPA, which stays purely for the authenticated app.
  Effort: high. Owner: engineering. More durable and gives full per-route control over meta
  tags and JSON-LD, and is the only path that scales to real content marketing (a blog,
  multiple landing pages) later. Trade-off: a second build system to maintain long-term.
- **C. Hand-write a few plain static HTML pages** (homepage, `/download`, `/signin`, maybe
  `/about`) served outside the SPA's own routing, linking into the live app. Effort:
  low-to-medium. Owner: engineering or marketing if simple enough. Cheapest path to more
  sitemap depth, but creates a second copy of homepage content to keep in sync with the real
  app (the same kind of drift that already caused the stale three-tier-pricing problem flagged
  in `fellowscript-overview.md`), and doesn't scale to future content marketing.

Recommended order: A now, revisit B only if a real content-marketing push (blog, SEO landing
pages) gets prioritized. C isn't recommended given the existing drift problem it would likely
repeat.

### 3. Missing structured data (JSON-LD has only `Organization` + `WebSite`)

- **A. Add a `SoftwareApplication` or `MobileApplication` JSON-LD block** to the homepage
  alongside what's already there. Effort: very low (a few hours). Owner: engineering, or
  marketing if the homepage template is directly editable. Low-risk, and can be built and
  merged in parallel with item 2's fix — it only starts paying off once indexing itself is
  actually fixed.
- **B. Add `Review`/`AggregateRating` schema once real ratings exist** (App Store, Google Play).
  Not actionable today — no public rating/review data is documented anywhere in the repo to
  cite. This is a "watch for later" item, not a current option.

This is small enough to fold into the same PR as item 2 rather than track as a separate piece
of work.

### 4. SmartGroups "Scale" tier — new launch or missed in the original baseline?

- **A. Just update `COMPETITOR-REPORT.md`** to reflect the Scale tier ($12/group/mo, unlimited
  groups) as of today, without trying to pin down exactly when it launched. Effort: trivial.
  Owner: marketing. Keeps the record accurate going forward and accepts the "new vs. missed"
  question as genuinely unresolved.
- **B. Check SmartGroups' own pricing-page history** (e.g. via the Wayback Machine) to determine
  whether Scale existed as of the 2026-09-13 baseline. Effort: low, one research pass. Owner:
  marketing. Only worth doing if the distinction changes what anyone does next — "a competitor
  just launched a cheaper tier" is a more urgent signal than "we missed a line item" — otherwise
  it's cheap due diligence with no real payoff.

Recommended order: A now; B only if someone actually wants to act on the timing question.

---

## Part 2 — Drafted replies

15 items queued today (11 Reddit, 4 ForumScout). All 15 got a full draft — none were skipped
for self-promotion rules, since Reddit's rules pages weren't reachable this run to confirm a
prohibition either way (see the reach-limitation note above). Every draft below has been run
through the humanizer pass.

### R1 — r/Christianity, "Any one know where to get some group Bible studies?"
**Platform:** reddit · **Delivery:** comment · **Posture:** explicit_need
https://www.reddit.com/r/Christianity/comments/1wjdqi2/any_one_know_where_to_get_some_group_bible_studies/

> **Possible duplicate — check before approving.** This exact thread (URL `1wjdqi2`) already has
> a hand-finished draft on file in `response-style-guide.md`, dated 2026-09-18, that reads as
> Jacey's own final edit of the beat-4 product mention. It isn't marked there as confirmed
> posted, but it may already be live. Reusing that approved text verbatim below rather than
> re-drafting from scratch. Verify whether this was already posted before approving R1 today —
> if so, skip it to avoid a duplicate reply.

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

### R2 — r/Christianity, "healthcare worker bible study"
**Platform:** reddit · **Delivery:** comment · **Posture:** explicit_need
https://www.reddit.com/r/Christianity/comments/1wnj8ox/healthcare_worker_bible_study/

> I've led a group made mostly of nurses and techs, and rotating shifts wrecked our attendance
> before anything else did. We kept trying to save the group by finding a "better" weekly time,
> and there just isn't one when half the group works nights every third week.
>
> What helped was giving up on everyone being in the same room at the same time. We picked one
> passage a week, everyone read and left a note or question whenever their shift allowed, and
> whoever was free that week hopped on a call or kept the conversation going in a group chat.
> Nobody had to catch up on being "behind" because there wasn't really a start time to miss. CMDA
> (Christian Medical & Dental Associations) also runs faith-focused groups for healthcare workers
> specifically, worth a look given the PA schedule.
>
> That's close to the exact problem that got me building FellowScript: notes and highlights the
> group can leave and read on their own time instead of needing everyone live at once. Not saying
> you need an app for it, but if the scheduling piece is what's blocking you, might be worth a
> look: fellowscript.com

### R3 — r/TrueChristian, "need help with Bible study"
**Platform:** reddit · **Delivery:** comment · **Posture:** explicit_need
https://www.reddit.com/r/TrueChristian/comments/1w6t0ub/need_help_with_bible_study/

> First group I ever led was with a couple coworkers, and I made the same mistake most
> first-timers make: I over-built it. Multi-week outline, extra reading, the whole thing. It fell
> apart by week three because I'd planned the content and never planned for what happens when
> people forget it's Tuesday.
>
> What keeps a workplace study alive isn't the material, it's the rhythm. Pick one short book or a
> handful of passages, keep it to 20-30 minutes, and protect the day and time like it's a meeting
> with your boss. Simple beats ambitious for the first few months. You can always go deeper once
> it's a habit instead of a plan.
>
> One thing that's helped my own group is having a month of prompts already scheduled so nobody
> has to remember to bring something new each week, that's part of why I built FellowScript. Not
> necessary to get started, just flagging it in case the "staying consistent" piece is the part
> you're worried about.

### R4 — r/TrueChristian, "young adult small group topics"
**Platform:** reddit · **Delivery:** comment · **Posture:** explicit_need
https://www.reddit.com/r/TrueChristian/comments/1w2klyq/young_adult_small_group_topics/

> Never led one either before my first time, and I spent way too long hunting for the "perfect"
> curriculum before I just started. Honestly overthought it.
>
> For a young adult group specifically, short books work best to start: James, Philippians, or 1
> Peter are all short enough to not feel like a commitment and practical enough that people
> connect them to actual life fast. Keep questions simple: what does this say, what does it mean,
> what do I do with it this week. You don't need a workbook, just the passage and two or three
> questions you wrote in five minutes beforehand.
>
> If it helps, I ended up building FellowScript partly around this exact "what do I bring this
> week" problem. It can schedule a month of prompts into the group ahead of time so you're not
> starting from scratch every Sunday. Not something you need to get going, just mentioning it
> since the predefined-curriculum question is basically the same thing I ran into.

### R5 — r/Christianity, "devotional book recommendations"
**Platform:** reddit · **Delivery:** comment · **Posture:** explicit_need
https://www.reddit.com/r/Christianity/comments/1w33s2s/devotional_book_recommendations/

> **Likely duplicate — check before approving.** This thread's theme (existing group finishing a
> study plan, wants what's next) matches the worked example labeled "R3" in
> `response-style-guide.md` (dated 2026-09-16, explicitly noted there as "final, as posted") so
> closely that this may be the same underlying thread resurfacing. Could not confirm either way
> since Reddit wasn't reachable this run. If it's already live, skip this one rather than
> double-post. Reusing that same approved text below since it's the best-available draft either
> way.

> I led a group through a full year-long plan once, and looking back, the mistake wasn't the
> length itself — it was assuming a long plan would keep everyone engaged the whole way through.
> Motivation drops hard around month four or five, and by the time you're picking what's next,
> half the group's already checked out. What worked better after that: shorter, focused stretches
> instead, one epistle at a time, 6-8 weeks, then regroup and decide together. Gives you a natural
> finish line instead of one long slog.
>
> The other thing that mattered more than the book pick itself was everyone actually landing on
> the same passage, same day, not whoever-gets-to-it-whenever. That's actually the specific thing
> that got me into building FellowScript in the first place; it just quietly keeps everyone's
> reading in sync day to day so nobody has to chase the group down. Not saying you need an app for
> this — just sharing what actually fixed it for my group when the plan itself wasn't the real
> problem. If that interests you at all, I think it's worth checking out.
> fellowscript.com

### R6 — r/Reformed, "balancing teaching and community"
**Platform:** reddit · **Delivery:** comment · **Posture:** explicit_need
https://www.reddit.com/r/Reformed/comments/1w9f77b/balancing_teaching_and_community/

> **Flag: r/Reformed self-promotion rules unverified.** Unlike r/Christianity, r/TrueChristian,
> and r/Bible (all of which have a successful disclosed-affiliation post on file in
> `response-style-guide.md`), r/Reformed is new territory for this queue and its rules page
> wasn't reachable this run. Double-check the sidebar/rules before approving — the product
> mention below is already kept light per the report's own posture note.

> I co-lead a group that's spread out enough that half of us are driving 20+ minutes just to get
> there, plus everyone's got their own teaching or serving commitments on other nights. The thing
> that actually hurt us wasn't the meeting itself, it was the week in between. By the time we met
> again, everyone had drifted back into their own stuff and we'd spend the first 15 minutes just
> catching back up instead of going anywhere new.
>
> What helped was giving the group something small to do between meetings that didn't require
> everyone syncing calendars again: a passage to sit with and one thing to bring back, even just
> dropped in a group text. Doesn't need to be formal, just enough that the week between meetings
> isn't dead space.
>
> Some of us started doing that through shared notes in FellowScript instead of a group text,
> mostly because it's tied to the actual passage instead of getting buried in a chat. That's part
> of what pushed me to build it in the first place. Not a fix for the distance itself, just a way
> to stay in each other's lives between the drives.

### R7 — r/Christianity, "lifestyle habits for modern day Christians"
**Platform:** reddit · **Delivery:** comment · **Posture:** explicit_need (no product mention)
https://www.reddit.com/r/Christianity/comments/1w3j0ar/lifestyle_habits_for_modern_day_christians/

> No FellowScript mention here. The poster is workshopping a discussion question ahead of their
> own group meeting, not describing a tooling problem — forcing a product aside into pure content
> engagement would be the same "pitching too early" failure flagged elsewhere in the task
> guidance (see the no-mention discipleship example in `response-style-guide.md`).

> This is a good one to sit with as a group rather than just answer solo. A few that have
> generated real discussion for groups I've led: fasting from something specific (not just food,
> phone and scrolling counts too) for a set stretch, not skipping the "boring" spiritual
> disciplines like solitude and silence, and treating Sabbath or rest as a discipline rather than
> just "a day off." The ones that land best in discussion aren't the ones with an obvious right
> answer. They're the ones where people in the room actually disagree a little on how far to take
> it, and that disagreement is usually where the good conversation happens.

### R8 — r/Christianity, "Bible study map"
**Platform:** reddit · **Delivery:** comment · **Posture:** networking (no product mention)
https://www.reddit.com/r/Christianity/comments/1wkz57j/bible_study_map/

> High-visibility thread (score 73), a leader sharing a prep artifact with no stated problem —
> pure relationship-building per the networking posture, genuine compliment plus a real question.

> This is great, genuinely, the way you've laid out the connections makes it way easier to see how
> the books relate than just a list ever would. How are you actually using this with your group?
> Is everyone working off a printed copy during the session, or is it more of a reference you
> point back to as you go through different books?

### R9 — r/TrueChristian, "Bible study" (workbook frustration)
**Platform:** reddit · **Delivery:** comment · **Posture:** explicit_need
https://www.reddit.com/r/TrueChristian/comments/1wjck51/bible_study/

> *(Revised by Jacey, 2026-09-23 — replaces the original drafted reply above)*
>
> I have heard of workbook-style studies and looked into it at some point because I thought that
> structure supported depth, but it ended up feeling like it would do the opposite for our group.
>
> I'd just drop the workbook entirely and read the passage together at the start of each meet,
> then actually talking about two or three open questions somebody wrote fresh that week instead
> of pre-printed ones. Slower to prep, but way better discussion. It's like people would react to
> the actual text instead of to someone else's summary of it.

### R10 — r/Christianity, "how do people find Christian community"
**Platform:** reddit · **Delivery:** comment · **Posture:** explicit_need
https://www.reddit.com/r/Christianity/comments/1wcry7q/how_do_people_find_christian_community/

> *(Revised by Jacey, 2026-09-23 — replaces the original drafted reply above)*
>
> A new environment with not much to get plugged in through is so much harder than people who've
> never had this situation give credit for. I relate a ton with the desire to find a Christian
> community I could be a part of and grow with, but it almost felt like I had to force myself to
> just go out and meet as many strangers as possible
>
> My method was just find a church, meet one or two people there and just stick close to them. It
> makes it so much easier to feel welcomed in a church because more often than not, they're going
> to bring you along to meet so many more people you wouldn't have otherwise. Also a way to text
> each other outside of church is nice too, and can eventually lead to more consistent spiritual
> conversations. A real group can come later, once you've got at least one person you know you can
> come to at church. From there, it became pretty easy to become part of a small group within that
> church, or a little harder, but super dope is starting your own if they don't have one for you.
>
> When that starts going, something like FellowScript can help can support you. It's an app I've
> been using to keep all of us connected in God's word, check in with each other, and just help
> each other grow. Not a replacement for finding people, just something that helps once you have
> one, its pretty nice here fellowscript.com

### R11 — r/TrueChristian, "Bible reading/study" methods
**Platform:** reddit · **Delivery:** comment · **Posture:** explicit_need
https://www.reddit.com/r/TrueChristian/comments/1wbq413/bible_readingstudy/

> The thing that actually changed my study wasn't a method so much as writing one thing down every
> time I read: one observation, one question I don't have an answer to yet. Doesn't need to be
> deep, "why does this word show up again three chapters later" counts. Then when you hit
> something that connects to an earlier passage, go back and actually look at it side by side
> instead of trusting your memory of what it said.
>
> That habit of tying notes to the actual verse instead of a separate notebook is part of what got
> me building FellowScript: notes that stay linked to the passage so cross-referencing is just a
> click instead of flipping back through old notebooks. Works fine with a physical notebook too if
> that's more your thing, just sharing what made the habit stick for me.

### R12 — Instagram, @cody.kinsmen
**Platform:** instagram · **Delivery:** dm · **Posture:** networking (no product mention)
https://instagram.com/p/DdkqaZeysu9

> Men's small-group post quoting 1 Peter 2:21 (ESV), run by a men's fellowship org in Park County,
> Wyoming (also currently promoting a Sept 28 comedy fundraiser). Pure relationship-building, one
> real discovery question about group consistency.

> Hey, saw your post with 1 Peter 2:21 for the men's group. Good verse to build a session around,
> it doesn't let you stay theoretical for long. How's the group been running lately? Is it the
> same core guys most weeks, or does it shift around with everyone's schedules out there?

### R13 — Instagram, @neuma.youngadults
**Platform:** instagram · **Delivery:** dm · **Posture:** networking (no product mention)
https://instagram.com/p/DdkqNVyHzTf

> Neuma Church's Young Adults Retreat announcement, Camp Marysville, ages 18-32, 2 days out from
> the post. Discovery question aimed at what happens after the retreat energy fades.

> Hey, saw the YA retreat post, looks like a great lineup for the weekend at Camp Marysville.
> Curious how you all handle the after: is there anything that keeps the momentum going once
> everyone's back into normal weeks, or does it tend to fade until the next retreat?

### R14 — YouTube, St Louis Young Adults Bible Study Fellowship
**Platform:** youtube · **Delivery:** comment · **Posture:** networking (no product mention)
https://youtube.com/watch?v=-ksVC5by14c

> Active young-adult group's own channel, "Romans Lesson 1 — Humanity's Need for the Gospel."
> Visibility/subscribe-worthy per the report, not a pitch target.

> Really appreciate you putting these online, going through Romans verse by verse with a group is
> no small commitment. Are you all planning to work straight through the whole letter, or pausing
> longer on certain sections depending on how discussion goes?

### R15 — Instagram, @csulb_biblekoin
**Platform:** instagram · **Delivery:** dm · **Posture:** networking (no product mention)
https://instagram.com/p/DdkktotpkEv

> Cal State Long Beach campus ministry, "why we trust the Bible" event with food and fellowship
> after. Campus segment is structurally pricing-blocked per `target-audience-profile.md` §5.1
> (deferred, not disproven) — light engagement only, no FellowScript mention regardless of
> anything surfaced in conversation.

> Hey, saw the post about the "why we trust the Bible" event, that's a good one to open up for a
> campus group, it's usually the actual sticking point for people even if they don't say it out
> loud. Food and fellowship after is a good call too, sometimes the real conversation happens
> after. Hope it goes well!

---

## Summary

- **15 items drafted, 0 skipped.** No subreddit was confirmed to prohibit self-promotion (none
  could be checked live today), so nothing was skipped on that basis — but see the flags on R1,
  R5, and R6 above before approving those three specifically.
- **Posture:** 10 explicit-need, 5 networking (2 of the 10 explicit-need items, R6 and R7, carry
  no product mention or only a very light one by design — see their notes).
- **Delivery:** 12 comments, 3 DMs (all 3 DMs are the Instagram items: R12, R13, R15).
- **Two possible duplicates (R1, R5)** and **one unverified-subreddit flag (R6)** — see each
  entry's note. Recommend resolving those three before a blanket "approve all."

# FellowScript Response Drafts — 2026-09-27

Scheduled/unattended run, drafting only. **Nothing in this file has been posted, replied to, or sent anywhere.** Every item below needs explicit human approval (by ID, in #prefect-victory) before the always-on marketing process will post it.

---

## Resolution options

Covering the report's "Needs a decision today" items plus one recurring housekeeping item flagged elsewhere in the report.

### A. SEO indexing failure — `site:fellowscript.com` returns zero Google results (4th straight day)

This is an engineering/ops problem, not a content problem — the site returns clean 200s to direct fetch, so the issue sits in either Cloudflare's edge config or Google's own indexing/verification state, not the app itself.

1. **Check Cloudflare bot-fight-mode / WAF settings directly in the dashboard.** The site's own `robots.txt` already carries a note from the prior internal audit (`20260918-fix-google-indexing-audit`) pointing here. Low effort (minutes, once someone with dashboard access looks), owned by engineering. Risk: low, it's a read of existing config, not a change until the cause is confirmed. This is the most likely single root cause given everything else about the site fetches cleanly from outside.
2. **Check Google Search Console directly for coverage/verification errors.** If the property was never verified, or verification lapsed, Google has no reason to crawl it regardless of what Cloudflare allows. Low effort, owned by engineering or whoever holds the Search Console account, but requires someone to actually have login access — if nobody currently does, add "recover/re-establish Search Console access" as a precursor step.
3. **Manually request indexing via Search Console once 1 or 2 identify and fix the blocker.** Trivial effort once the account is accessible, but doesn't help until the actual block (Cloudflare or verification) is found — this is a follow-up action, not a fix on its own.
4. **Do nothing further and let it re-resolve on its own.** Not recommended — this has now been flagged unresolved for 4 consecutive daily reports with zero shipped fix, and each day without organic search visibility is a day the branded search "FellowScript Bible reading app" keeps surfacing a GitHub mirror instead of the real site.

**Recommendation:** 1 and 2 in parallel — they're both quick dashboard checks, not code changes, and one of them almost certainly explains the zero-results state. This has enough day-count behind it now to treat as a real priority rather than a re-confirmed line item tomorrow.

### B. ForumScout monitoring appears stopped, not just stale

The Google Sheet's `modifiedTime` hasn't moved since 2026-09-22T03:07:31Z — 5 straight days with zero new rows, well past the Starter tier's advertised 6-hour scan cadence.

1. **Check the ForumScout account/subscription status directly** (billing, API key validity, service status page if one exists). Low effort, owned by whoever holds the ForumScout account. This is the first thing to rule out — a lapsed subscription or expired credential would explain a clean stop like this far better than "increased staleness."
2. **Contact ForumScout support** if the account looks healthy from the outside but rows still aren't landing. Low-to-moderate effort (support response time is out of our control), same owner.
3. **Extend seen-tracking to YouTube/Twitter/Bluesky** — a separate, smaller finding from today's run: those platforms have no seen-list file to check against (only Reddit/LinkedIn/Instagram do), so even when ForumScout resumes, candidates from those platforms can't be reliably deduplicated against prior days' reports. Moderate effort (a marketing/ops scripting task, not urgent), worth bundling into whatever fix restores the ForumScout feed rather than doing as a separate pass.

**Recommendation:** 1 first — it's the fastest way to tell whether this is an account problem (fixable in minutes) or a ForumScout-side outage (needs 2). Treat 3 as a follow-on once the feed is confirmed flowing again, not a blocker to it.

### C. Seen-tracker gap — a queued Reddit thread wasn't recorded, then resurfaced as "new"

A thread queued in the 2026-09-22 report (`r/TrueChristian` "Young adult small group topics") was never appended to `seen-reddit-links.md` that day, so it appeared again today as if unseen. Today's run added it retroactively.

1. **Spot-check 2026-09-23 through 2026-09-26's queued items against `seen-reddit-links.md`** to confirm this was a one-off miss rather than a recurring gap. Low effort (a few minutes of file diffing), could be done by marketing or by whoever next touches the daily pipeline script.
2. **Add a check step to the pipeline itself** that verifies every queued Reddit URL from a given day's report actually made it into the seen-list before the run completes, rather than relying on it happening as a side effect. Moderate effort (a small script change), owned by engineering/whoever maintains the daily pipeline automation. Worth doing only if 1 turns up more than this single instance — otherwise it's process overhead for a problem that's shown up once.

**Recommendation:** Do 1 now since it's cheap; only invest in 2 if 1 finds a pattern rather than an isolated miss.

### D. `COMPETITOR-REPORT.md` baseline is stale on SmartGroups pricing (recurring housekeeping)

The 3-tier SmartGroups structure (Starter free / Growth $59/mo / Scale $12/group/mo) has now been independently surfaced twice — first on 2026-09-22, again today — because the baseline file was never updated after the first confirmation, so today's agent treated it as a fresh finding.

1. **Update `COMPETITOR-REPORT.md` directly with the confirmed 3-tier structure now**, so it stops getting "rediscovered." Low effort (a documentation edit, not a code change), owned by marketing or whoever maintains that file. No real risk or tradeoff here — this is pure housekeeping.
2. **Leave it as-is and let it keep resurfacing.** Not recommended — it costs a small amount of review attention every time it's re-flagged, for no benefit.

**Recommendation:** Just do 1 — this is the one item in this section with an unambiguous right answer and near-zero cost.

---

## Drafted replies

9 items reviewed from the report's queued-for-human-review Reddit list (all platform: Reddit — no ForumScout survivors today, no Instagram items, so no DMs this round). All read the report's own summarized thread context; none were independently re-fetched live beyond that.

**Coverage note:** subreddit rule pages for r/Christianity, r/TrueChristian, r/Baptist, r/Christians, and r/Bible could not be fetched live this run (Reddit blocks this session's fetch tool, and web search didn't surface each subreddit's specific self-promotion policy). No explicit prohibition was found for any of them, and the response-style-guide's own worked examples show disclosed self-promotion has already run successfully in r/Christianity, r/TrueChristian, and r/Christians. r/Baptist and r/Bible are being used for the first time here — flagging that as slightly less-verified than the other three, not as a reason to skip.

### R1 — r/Christianity, ["Mindfulness Study"](https://www.reddit.com/r/Christianity/comments/1wr6hz7/mindfulness_study/)

**Posture:** explicit_need · **Delivery:** comment · **Status:** pending_approval

> I led a short study through the Fruit of the Spirit a while back, half improvised, using it as a stand-in for a "Christian mindfulness" study. I made the mistake of dropping a full reading list on the group up front and telling everyone to work through it before we met. It fell apart fast because everyone finished different chunks at different times, so the discussion never actually matched what people had read that week.
>
> What worked better after that was slowing way down: one short passage a week, same passage for everyone. Gal 5:22-23, then Phil 4:4-9, then Matt 6:25-34, then Ps 46. Nobody's catching up, nobody's ahead, and the discussion actually lines up with what was read.
>
> That's actually part of what got me building FellowScript, a way to keep everyone's notes on that week's passage visible to the rest of the group instead of scattered across whatever app each person happens to use. Not saying you need an app for a 4-passage study, but if it grows past that, might be worth a look. fellowscript.com

### R2 — r/TrueChristian, ["Young adult small group topics"](https://www.reddit.com/r/TrueChristian/comments/1w2klyq/young_adult_small_group_topics/)

**Posture:** explicit_need · **Delivery:** comment · **Status:** pending_approval

> First group I ever led, I'd never actually been part of one myself before that. I just got asked and said yes.
>
> I way overprepared the first week, wrote pages of notes trying to cover the whole book in one sitting, and it came out sounding like a lecture. Nobody said a word the whole time.
>
> What actually worked once I recovered was picking one short book, covering one chapter a week, and showing up with 3 questions I wrote myself instead of pulling them from a workbook. Keeps the prep manageable and leaves room for people to actually talk instead of just listening.
>
> That whole first-time scramble is part of what got me building FellowScript. I share my prep notes with the group ahead of the meeting now, so people show up having at least seen the questions instead of hearing them cold. Not necessary for week one, but if you keep leading, it's worth a look. fellowscript.com

### R3 — r/Baptist, ["Grow Together in Christ — Beginning a Home Fellowship in Toronto"](https://www.reddit.com/r/Baptist/comments/1w74kgi/grow_together_in_christ_beginning_a_home/)

**Posture:** networking · **Delivery:** comment · **Status:** pending_approval

> Starting something built around all three of those at once, prayer, the Word, and actually carrying each other's burdens, is a bigger lift than picking one lane, in my experience. How are you thinking about keeping the Word part going in between when you actually meet, once the new-group energy wears off a bit?

No product mention — this is a pure announcement post with no stated problem, so per the networking-posture rule the goal here is a genuine question, not a pitch.

### R4 — r/Christians, ["Skipping your church's bible study for another group's study?"](https://www.reddit.com/r/Christians/comments/1w6ze8e/skipping_your_churchs_bible_study_for_another/)

**Posture:** explicit_need · **Delivery:** comment · **Status:** pending_approval

> I did something similar a few years back. I left the group my church had put me in for one a friend was running, purely because the second one actually went somewhere every week. Felt a little guilty about it for a while, like I was picking convenience over commitment.
>
> Looking back, the point of a bible study is what happens in the room, not whose name is on the calendar invite. If the other group is where you're actually engaging, that's not a lesser commitment, just an honest one.

No product mention — this thread is about group loyalty/venue, not a tool gap, so nothing here naturally supports a FellowScript aside without forcing it.

### R5 — r/Bible, ["Reading/studying the Bible?"](https://www.reddit.com/r/Bible/comments/1w18koz/readingstudying_the_bible/)

**Posture:** explicit_need · **Delivery:** comment · **Status:** pending_approval

> I've done the two-person version of this before: no group, just one other person and a shared chapter each week.
>
> We started out reading together out loud in the same sitting every time, which sounds nice but turned into a scheduling nightmare the second our weeks stopped lining up. What worked better was each of us reading the same chapter on our own time, jotting down one or two observations, then comparing before we actually talked it through. Kept us in sync without needing the same free evening every week.
>
> That's actually part of why I built FellowScript, notes tied to the verse that either of you can see, so the comparing part doesn't need its own separate text thread. Works the same for two people as it does for a full group. fellowscript.com

### R6 — r/Christianity, ["College Bible study"](https://www.reddit.com/r/Christianity/comments/1wfmg6m/college_bible_study/) (Louisville)

**Posture:** explicit_need · **Delivery:** comment · **Status:** pending_approval

> I ran a study years ago where half the group was commuting in from a different campus, so we were never actually all in the same room at once. I kept handing out printed sheets at the meetings themselves, so anyone who missed a week just fell out of the loop completely, with no way to catch back up.
>
> The actual fix wasn't the study format, it was having one shared place for the passage and everyone's notes that didn't depend on being physically there. A missed week became a gap instead of a dead end.
>
> FellowScript's actually free for a group your size, and that's the exact problem it solves for me now: everyone's on the same passage and can see each other's notes whether they made it that week or not. fellowscript.com

### R7 — r/Christianity, ["Again I tell you..." (Matt 18:19-20)](https://www.reddit.com/r/Christianity/comments/1wgx1t8/again_i_tell_you_if_two_of_you_on_earth_agree/)

**Posture:** networking · **Delivery:** comment · **Status:** pending_approval

> Starting one this small is honestly the harder version to keep going long term, in my experience, there's no built-in group pressure to show up the way there is with a bigger one. What's the plan for keeping it going if one of the two or three of you has to miss a few weeks in a row?

No product mention — this is a prayer group, not a study group, and there's no stated problem for FellowScript to address.

### R8 — r/Christians, ["When does helpful AI become dependence..."](https://www.reddit.com/r/Christians/comments/1vzkwlw/when_does_helpful_ai_become_dependence_and_what/)

**Posture:** explicit_need · **Delivery:** comment · **Status:** pending_approval

> I've caught myself using AI to summarize a passage instead of actually sitting with it, and the difference shows up right after: I remember basically nothing from the summarized version a day later.
>
> Where it's actually helped me is the opposite use, asking it about something confusing in the text instead of letting it read the text for me. Feels like the line is less about the tool itself and more about whether it's replacing your own attention or just pointing you back to it.

No product mention — candid personal take only, per the report's own posture note for this thread (solo KJV user, thought-leadership territory, not a buyer).

---

All 8 threads from the report's queue (both Tier 1 and Tier 2) got a draft; none were skipped for subreddit self-promotion rules today (see coverage note above).

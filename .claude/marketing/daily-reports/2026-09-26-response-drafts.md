# FellowScript Marketing — Response Drafts, 2026-09-26

**Drafts only. Nothing in this document has been posted, replied to, or sent anywhere.** Every item below needs explicit human approval (by ID) before the always-on marketing bot posts it.

---

## Resolution options

For each systemic issue flagged in today's report, here are the realistic paths to actually fixing it — not just one recommendation.

### 1. SEO / Google indexing failure (third day running, no fix shipped)

`site:fellowscript.com` returns zero results and the site doesn't rank for its own name. Two root causes are on the table and aren't mutually exclusive:
- Every non-homepage route serves byte-identical homepage HTML with a canonical pointing back at `/`, and `sitemap.xml` only lists the homepage — a SPA/HashRouter defect with no server-side routing per page.
- A Cloudflare-layer setting (bot-fight-mode/WAF) or a Google Search Console verification/coverage gap.

**Option A — Prerendering / static snapshot generation (addresses the routing cause).** Add a build step (e.g. `react-snap`, `vite-plugin-ssg`, or a small custom Puppeteer-based prerender script) that generates real static HTML per route at build/deploy time, each with its own title, meta, and canonical tag, then serves those instead of the SPA shell to crawlers.
- Effort: medium (1-3 days). Owner: engineering.
- Trade-off: doesn't fix true SSR for dynamic content, but is the fastest path to correct per-page HTML for the routes that matter (marketing pages, not authenticated app views).

**Option B — Move to a framework with built-in SSR/SSG (Next.js, Remix, Astro islands over the existing React components).** Rebuild the public-facing routes (home, pricing, any blog/content pages) on a framework that renders real HTML server-side by default.
- Effort: high (1-3 weeks) — a real migration, not a patch.
- Owner: engineering, likely needs frontend + design input on any layout changes.
- Trade-off: the "right" long-term fix and pays off if content pages are added later, but is a disproportionate response if the only goal is unblocking indexing this quarter.

**Option C — Minimal per-route static shim just for crawlers.** Detect crawler user-agents (Googlebot etc.) at the edge (Cloudflare Worker) and serve a lightweight static HTML snapshot with correct meta/canonical for that route, while real users still get the SPA.
- Effort: low-medium (a few days).
- Owner: engineering (backend/infra-leaning).
- Trade-off: cheapest fix, but cloaking-adjacent if not done carefully — the served HTML must match what a user would eventually see, or it risks a Google Search Console manual action. Needs a security/compliance sanity check before shipping (see `security-compliance` skill).

**Separately, regardless of which option above is chosen — verify the Cloudflare/GSC angle in parallel**, since it may be additive:
- Check Cloudflare bot-fight-mode / WAF rules aren't blocking Googlebot's user-agent or IP ranges.
- Re-verify Google Search Console ownership and check the Coverage report for "Discovered — not indexed" or "Crawled — not indexed" statuses, which point at different root causes than a hard block.
- Effort: low (a few hours). Owner: whoever has GSC/Cloudflare dashboard access — could be marketing or engineering.

**Recommendation:** Option A (prerendering) plus the Cloudflare/GSC check in parallel is the pragmatic near-term fix; Option B is worth scheduling as a separate initiative if FellowScript ever wants real content/SEO pages, not as this week's fix.

### 2. Reddit dedup check misses slugless URLs (false negatives let already-seen threads back into the queue)

The dedup check against `seen-reddit-links.md` does an exact-string match, which misses a duplicate when the stored entry has no slug and the newly-found one does (or vice versa) — confirmed today with `r/Christianity`'s "Should Christians use AI to study the Bible?" thread.

**Option A — Normalize URLs before comparing.** Strip the slug and any query string, keep only `/r/<sub>/comments/<id>/`, and compare on that normalized form.
- Effort: low (an hour or two) — a regex/string-processing change wherever the dedup check runs.
- Owner: whoever maintains the daily pipeline's marketing scripts (engineering or Jacey directly, depending on how it's structured).

**Option B — Switch the dedup key to post ID outright.** Store just the Reddit post ID (the alphanumeric segment after `/comments/`) in `seen-reddit-links.md` instead of full URLs, and compare on that.
- Effort: low, but requires a one-time migration of the existing `seen-reddit-links.md` file to extract IDs from stored URLs.
- Owner: same as above.
- Trade-off: slightly less human-readable file (bare IDs instead of clickable links) unless you keep both the ID and the URL as two columns.

**Recommendation:** Option B is more robust long-term (immune to any future URL-format quirks), but Option A is a same-day fix if the daily pipeline needs to keep running. Either is small enough to do without a dedicated `/build` ticket.

### 3. ForumScout sheet — stale data and incomplete tab coverage

The sheet's newest row is 4 days old against a stated 6-hour scan cadence, and the CSV export path only pulls the sheet's first/default tab, so the other 9 topic tabs can only be previewed at ~4 rows each.

**Option A — Switch from CSV export to the Google Sheets API (per-tab range reads).** Use `gspread` or the raw Sheets API with a service account to read each named tab's full range directly, instead of relying on the CSV export endpoint (which only ever serves the default tab).
- Effort: low-medium (a day) — needs a service account with read access to the shared sheet, then a small script change to iterate over tab names.
- Owner: whoever maintains the daily pipeline (engineering), with marketing confirming which tabs matter.
- This directly fixes the "9 tabs only previewed at ~4 rows" gap; it does not fix staleness.

**Option B — Escalate the staleness to whoever owns the ForumScout scan itself.** The 6-hour cadence isn't being met (4-day-old newest row), which is a problem with the scan job, not the pipeline reading it. Ask the ForumScout account owner (or whoever set up that integration) to check the scan is actually still running on schedule.
- Effort: low (a conversation/check), but not in FellowScript's own codebase — it's a third-party tool's scan job or account status.
- Owner: marketing (whoever manages the ForumScout subscription/integration).

**Recommendation:** Do both — Option A is a same-week engineering fix that immediately restores full visibility into all 10 tabs; Option B is a quick check that costs nothing and rules out (or confirms) a bigger problem with the data source itself.

### 4. Zernio has no post/keyword discovery for Instagram, LinkedIn, or a connected X account

Every Instagram/LinkedIn/X candidate this run came from the ForumScout sheet, not Zernio — Zernio only offers Reddit search plus each platform's own inbox (mentions/comments), which were both checked and empty.

**Option A — Connect an X/Twitter account in Zernio for this session/pipeline.** This unblocks Zernio's existing X search tool (already built, just unusable without a connected account).
- Effort: very low (account connection/OAuth flow) — a few minutes in the Zernio dashboard.
- Owner: whoever manages Zernio's connected accounts (marketing).
- Does not help Instagram/LinkedIn discovery, which is a Zernio product-capability gap, not a configuration gap.

**Option B — Request/wait for Zernio to ship Instagram/LinkedIn keyword discovery.** File it as feedback to Zernio (or check their roadmap/changelog) rather than building a workaround.
- Effort: none on FellowScript's side; timeline entirely dependent on Zernio's own roadmap.
- Owner: marketing (relationship with the vendor).

**Option C — Build a lightweight custom scraper/monitor for Instagram and LinkedIn keyword mentions**, running alongside Zernio and ForumScout rather than replacing either.
- Effort: medium-high (several days) — both platforms actively resist scraping and this risks ToS/account-suspension issues; would need careful, conservative rate-limiting and likely official API access (Instagram Graph API requires a business account and app review; LinkedIn's API is even more restricted for this use case).
- Owner: engineering, with a security/compliance review before shipping given the ToS exposure (see `security-compliance` skill).
- Trade-off: highest effort and highest risk of the three; only worth it if Instagram/LinkedIn organic discovery is a priority channel, not just a nice-to-have.

**Recommendation:** Do Option A immediately (it's free and unblocks X search today). Treat Option B as the default path for Instagram/LinkedIn. Only consider Option C if Instagram/LinkedIn discovery proves to matter enough to justify the ToS risk and engineering cost — the current reliance on the ForumScout sheet for those two platforms is a reasonable stopgap in the meantime.

---

## Drafted replies

18 items reviewed from today's report's social-listening queue. Every drafted reply below has been run through the `humanizer` skill. **Subreddit self-promotion rules could not be independently verified this run** — `WebFetch` is blocked from reaching `reddit.com` in this environment, and web search turned up no subreddit-specific rule text for r/OpenChristian, r/Bible, r/Christianity, or r/Christians. Drafts below follow the same disclosure pattern (`I built FellowScript`, one soft link, explicit hedge) that has been used successfully in this queue before (see `response-style-guide.md`), but a human should do a quick manual check of each subreddit's rules before approving R1–R5 and R8, the six items that mention the product.

### R1 — r/OpenChristian — "How do you start a community Bible study group?"
[Thread](https://www.reddit.com/r/OpenChristian/comments/1wp7jbu/how_do_you_start_a_community_bible_study_group/) · explicit_need · comment

> I did something similar a couple years back. My church's group only met during the day, so a few of us split off and started our own thing in the evenings instead.
>
> The mistake I made early on was over-planning it before the first meeting: picking a whole curriculum, assigning readings weeks out. Almost nobody stuck with that. It felt like homework before we'd even built any trust as a group.
>
> What actually got it off the ground was simpler: one shared passage a week, and everyone brings one line or verse that stood out to them. That's it for the first month or so. Once people are used to showing up and talking, you can go deeper.
>
> I ended up building an app called FellowScript partly because of that same group, just a place for everyone to leave notes on the passage between meetings so nobody's starting from zero each week. Not needed to get going, just something that helped us later. Good luck with it either way.

### R2 — r/Bible — "Any tips for studying the Bible on my own?"
[Thread](https://www.reddit.com/r/Bible/comments/1wf9qaq/any_tips_for_studying_the_bible_on_my_own/) · explicit_need · comment

> Studying solo was harder for me to stick with than I expected. Not the material, the follow-through.
>
> The thing that actually helped: picking a much smaller unit than I wanted to admit was enough, a handful of verses, not a chapter, and writing down one observation and one question before I let myself move on. Longer sessions always fell apart faster than short consistent ones did for me.
>
> I still keep most of that in a paper notebook, for what it's worth. Pen and paper's fine for solo study, nothing about it needs to be digital. The one place I noticed a difference was when a couple people started seeing what I wrote down instead of just me. That's actually part of why I built FellowScript, notes tied to the verse that you can keep private or open up to a couple people. Not something solo study needs, just flagging it in case the same thing helps you.

### R3 — r/Christianity — "Help me learn to study the bible"
[Thread](https://www.reddit.com/r/Christianity/comments/1w2721k/help_me_learn_to_study_the_bible/) · explicit_need · comment

> I've done this the other direction too, studying specifically to lead a group afterward, and the biggest shift for me was changing how I took notes, not how much I read.
>
> Early on I just wrote down what I thought a passage meant. That's fine for yourself, but it's useless when you're trying to teach: you can't remember why you thought that six weeks later. What worked better was writing, for every passage, the observation (what it says), then separately the application (what to do with it), and keeping them attached to the actual verse instead of a separate notebook page.
>
> That structure is actually most of why I built FellowScript, notes linked directly to the verse so when it's time to teach, you can pull up exactly what you thought and why instead of flipping through pages trying to remember. Not saying you need an app for it, the observation/application split works on paper too. Just sharing what actually made the "teach later" part easier for me.

### R4 — r/Christians — "Looking for an Online Bible Study Group That Meets Every Evening"
[Thread](https://www.reddit.com/r/Christians/comments/1wbbkc9/looking_for_an_online_bible_study_group_that/) · explicit_need · comment

> Eleven is a lot of groups to strike out with. That's rough.
>
> If nothing's landing, it might honestly be easier to start one instead of keep searching. It doesn't need to be big: post in a couple of the same places you were reaching out to groups, pick one evening, and go with whoever shows up first. Searching for a perfect existing group has a ceiling that starting a small one yourself doesn't.
>
> The other piece, since evening timing is clearly the hard constraint for you: an async layer helps a lot when people can't all be free the same night every week. Everyone reads the same passage and leaves notes on their own time, then an occasional call instead of a hard weekly slot. That's actually the exact problem that got me building FellowScript. Not a pitch to go start using an app before you've even got people, just worth keeping in mind once you do get a few together.

*Note: likely the same author as R8 below (both r/Christians, similar ask). Consider engaging only whichever thread is livelier if both would otherwise get a reply.*

### R5 — r/Bible — "Best Bible highlighting options"
[Thread](https://www.reddit.com/r/Bible/comments/1wdl3b4/best_bible_highlighting_options/) · explicit_need · comment

> I went through the exact post-it spiral. Every book bulging, half of them fell out eventually and I had no idea what they were even marking anymore.
>
> Honest answer on the physical side: get a proper wide-margin edition if you're staying paper, and switch from post-its to actually writing in the margin or underlining. Post-its are great short-term but they don't survive a book getting picked up and put down a hundred times.
>
> The other option, since you're clearly hitting a physical ceiling: highlighting digitally with the note attached to the verse instead of a separate sticky note. That's actually one of the reasons I built FellowScript, same colored-highlight idea, but the note it's attached to can't fall out or get lost. Not saying paper's wrong, just flagging the digital option since it sounds like you've already outgrown the post-its.

### R6 — r/Bible — "Every morning... I've read Luke, then I journal it"
[Thread](https://www.reddit.com/r/Bible/comments/1wqol8x/every_morning_for_the_last_29_days_ive_read_the/) · networking (no stated problem, no product mention) · comment

> 29 days in a row is no small thing. That's exactly the stretch where most people I know, myself included, usually fall off.
>
> Curious what's kept it going for you this long. Is it the same time each morning, or more that you've built the "read then journal" pairing into how you approach it? I've found the actual reading rarely falls off, it's whatever comes right after the reading that's fragile.

### R7 — r/Christians — "A takeaway from a year of studying the church at Ephesus"
[Thread](https://www.reddit.com/r/Christians/comments/1wh1ho7/a_takeaway_from_a_year_of_studying_the_church_at/) · networking (no stated problem, no product mention) · comment

> A full year on one church is a different kind of study than most people do. Most of us bounce around a lot more than that.
>
> What changed the most for you between the start of that year and now? Is there a takeaway you'd have completely missed if you'd only spent a few weeks on it instead? And how'd you keep it from going stale over that many months?

### R8 — r/Christians — "Why doesn't any church meet anymore for daily Bible study and fellowship?"
[Thread](https://www.reddit.com/r/Christians/comments/1vw5k8f/why_doesnt_any_church_meet_anymore_for_daily/) · explicit_need · comment

> This one's been on my mind too. Best guess from groups I've been part of: weekly became the default because it's the easiest thing to schedule around work, not because anyone decided daily wasn't valuable. Once weekly's the norm, daily just looks unrealistic to suggest.
>
> The groups I've seen actually pull off something closer to daily didn't do it by adding more meetings. They kept one weekly meeting and filled the gaps async: everyone reading the same passage on their own each day and leaving a note or two, so there's still a daily thread even without a daily meeting.
>
> That's actually the specific gap that got me building FellowScript: same passage, same day, notes shared between the people in your group, so the "daily" part isn't riding on everyone's calendars lining up. Not saying you need an app for this, just sharing what's worked for groups I've seen manage it.

*Note: likely the same author as R4 above. See note on R4.*

### R9 — X — @Bornagain19880 (planning a Twitter Spaces Bible study)
[Profile](https://twitter.com/Bornagain19880) · networking · comment

> A Bible study over Spaces is a format I haven't seen many people try. How are you planning to keep it structured with that many people able to just drop in and out? Are you doing one passage per session, or more open discussion?

### R10 — Instagram — @inwoodbiblestudy (weekly Bible study invite)
[Profile](https://instagram.com/inwoodbiblestudy) · networking · **DM**

> Saw your post about the weekly study. How long has the group been meeting? Curious what's kept people coming back week to week, that's usually the hardest part to get right.

### R11 — Instagram — @staycmae (hosting her own women's Bible study group)
[Profile](https://instagram.com/staycmae) · networking · **DM**

> Saw your post about the women's group you're running. How'd you end up being the one to start it? And now that it's going, what's been the hardest part of keeping it consistent as more people join?

### R12 — X — @LilBuff9 (part of Bible Study Fellowship)
[Profile](https://twitter.com/LilBuff9) · networking · comment

> BSF's one of the more structured formats out there: lecture, discussion questions, homework between sessions. How's that structure worked for you compared to a looser group study? Curious if the homework part is what actually keeps people showing up prepared.

### R13 — Instagram — @firstpresgainesville (inviting young professionals into a small group)
[Profile](https://instagram.com/firstpresgainesville) · networking · **DM**

> Saw your post inviting young professionals into a small group. Is this a new group forming or an existing one opening up? Curious what's been the biggest hurdle in getting that age group specifically to actually show up consistently.

### R14 — Reddit — COGOPRetired on r/Actscelerate (small-group time getting squeezed in larger churches)
[Comment](https://www.reddit.com/r/Actscelerate/comments/1wixw7p/loran_livingston_affirms_the_gifts_of_the_holy/pak4rdu/) · networking · comment

> This tracks with what I've seen too. The bigger a church gets, the more the actual relational stuff quietly gets pushed to the edges of the calendar. Has it been better for you in smaller churches specifically, or is it more about whether a given church protects small-group time on purpose regardless of size?

### R15 — LinkedIn — Churches of Christ in Queensland ("Havachat" outreach story)
[Post](https://www.linkedin.com/company/churches-of-christ-in-queensland) · networking · comment

> Really like the Havachat model. A member starting something like that from the ground up instead of it coming down from leadership usually means it actually sticks. How did it start out, informally between a couple people first, or did it launch as an actual program from day one?

### R16 — LinkedIn — @Ronnie Greene (personal reflection on a fellowship-group insight)
[Post](https://www.linkedin.com/in/ronnie-greene) · networking · comment

> That's a good one to sit with. Was that something that came up in discussion with the group, or more something you noticed on your own afterward? Curious how much of it changed how you approach the group going forward.

### R17 — Instagram — @blw_trailblazers (weekly Bible study invite, small account)
[Profile](https://instagram.com/blw_trailblazers) · networking · **DM**

> Saw your post about the weekly study. Is this a group that's been running a while or fairly new? What's been the biggest thing that's helped people actually keep coming back?

### R18 — Reddit — neutrallpinkk on r/Christianmarriage ("are you involved in a church fellowship/small group?")
[Comment](https://www.reddit.com/r/Christianmarriage/comments/1wdv5sg/no_time_for_me/p9ylwzr/) · networking · comment

> Jumping in on this since it's the actual crux of it, I think. A fellowship or small group changes this a lot, in my experience. Are you currently in one, or has it been hard to find one that fits your schedule specifically?

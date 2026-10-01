# FellowScript Response Drafts — 2026-09-18

**Drafts only. Nothing below has been posted, replied to, or published anywhere.** This is an
unattended follow-up to today's daily marketing digest (`2026-09-18.md`). A human approves specific
items by ID in the #prefect-victory Discord channel; only then does the always-on marketing process
actually post them.

## Verification limitations (read before approving)

This run could not reach either `reddit.com` or `instagram.com` from this environment (WebFetch
failed on every attempt), so none of today's queued threads or posts could be re-fetched live, and
none of the six relevant subreddits' self-promotion rules could be checked directly. Every item below
rests on the daily report's own descriptions, not a fresh read of the live thread. Before approving
any item, a human should confirm: the thread/post is still up, Reddit threads are still open to
comments, and (for Reddit) the subreddit doesn't have a self-promotion rule that would get the reply
removed. None of today's items were skipped for a self-promotion reason, because none could be
confirmed either way this run — that's a gap, not a clean bill of health.

---

## Part 1 — Resolution options

Two items are pulled from today's "Needs a decision today" section (the queue of 17 review items,
#3 in that section, is not a resolution-options case — it's exactly what Part 2 below handles). A
third groups three smaller, lower-urgency SEO items the report also flagged today.

### Issue A — fellowscript.com isn't indexed by Google at all

`site:fellowscript.com` and a branded tagline search both return zero results from the domain. Cause
is unconfirmed (crawled-but-excluded vs. never-crawled), but the gap itself is verified via three live
searches and is new as of today.

| Option | What it involves | Effort | Owner | Trade-off / risk |
|---|---|---|---|---|
| A1. Verify the domain in Google Search Console, read the Coverage / Page Indexing report | Claim the property (DNS TXT record or meta tag), then check whether pages are "discovered, not indexed," "crawled, not indexed," or excluded and why | Low (~1-2 hrs) | Whoever holds DNS/hosting access (engineering or Jacey directly) | None — purely diagnostic, and it's the only way to actually know which of A2-A4 is worth doing |
| A2. Request indexing manually via URL Inspection once verified | One click per URL in Search Console | Trivial (minutes) | Marketing | Only treats the symptom — if a noindex tag or crawl block exists, the request will keep failing until that's fixed |
| A3. Audit for an accidental `noindex` meta tag, `X-Robots-Tag` header, or overly broad `robots.txt` disallow | View-source / header check on the live homepage and a couple of other routes | Low (~30 min) | Engineering | Low risk, and a surprisingly common single cause of a "zero results" domain — worth doing regardless of A1's outcome |
| A4. Build a few real inbound links (partner sites, prior research write-ups, social profiles) so Google has a discovery path independent of the sitemap | Add fellowscript.com links from any existing public-facing FellowScript presence | Medium, ongoing | Marketing | Slower, doesn't guarantee crawl priority, but compounds over time and helps regardless of the root cause |
| A5. Treat it as downstream of Issue B | If the site is structurally a single indexable URL with a history of inconsistent server-rendered tags (see the 09-17 meta-tag fix), Google may simply not prioritize crawling it | Depends on Issue B | Engineering | No separate cost, but means indexation may not improve until Issue B is addressed |

**Suggested sequencing:** A1 and A3 first (cheap, diagnostic, no dependencies), then decide on Issue B's investment level based on what Search Console actually shows.

### Issue B — Sitemap ships two dead entries, and the site is structurally one indexable URL

`sitemap.xml` lists `/#/privacy` and `/#/terms`, but the site uses `HashRouter`, so everything after
the `#` is a fragment, not a crawlable URL. This has been flagged as a structural issue since at least
09-13 and sharpens each day it's unaddressed.

| Option | What it involves | Effort | Owner | Trade-off / risk |
|---|---|---|---|---|
| B1. Patch the sitemap now, regardless of the path chosen below | Remove `/#/privacy` and `/#/terms` from `sitemap.xml`, or point them at real static pages if any exist | Trivial (~15 min) | Engineering | Stops shipping a broken sitemap; does nothing for the underlying single-URL problem |
| B2. Switch `HashRouter` to `BrowserRouter` with a server-side catch-all route | Frontend router change plus a server/deploy config change (e.g. `try_files` or a wildcard route) so a direct hit on `/pricing` or `/privacy` resolves instead of 404ing | Medium (1-3 days, plus regression testing for any bookmarked `#`-style links already in the wild) | Engineering (frontend + a bit of infra) | Makes URLs real and crawlable, but content is still client-rendered — Google generally executes JS but on a delay and with more risk than pre-rendered HTML, so this alone may not fully resolve Issue A |
| B3a. Full SSR/framework migration for the public site (e.g. Next.js) | Rebuild the public marketing shell (not the authenticated app) with server-side rendering | High (weeks) | Engineering | Most durable, best long-term SEO and performance outcome, but a real rewrite, not a config change |
| B3b. Lightweight static pre-render for the marketing routes only | Hand-build static HTML for home, pricing, privacy, and terms, with real content and meta tags baked in, that link into the existing SPA for sign-up/log-in; the content from the 09-17 meta-tag fix could seed the copy | Medium (a few days, mostly content/design work) | Engineering + marketing/design for copy | Fastest path to fully-correct SEO (real URLs, content in the initial HTML) without a framework rewrite; creates a second place (static pages vs. SPA components) that copy changes need to stay in sync with |
| B4. Sitemap patch only, lean on non-organic channels | Do B1 and otherwise accept the site won't rank | Low technical cost, ongoing content/outreach cost | Marketing | Cheapest technically, but concedes organic search indefinitely — worth weighing against how much the marketing plan is actually counting on organic traffic (the standing recommendation in `fellowscript-overview.md` is leader-first referral growth, not paid or organic-heavy acquisition, so this may be an acceptable trade) |

**Suggested sequencing:** B1 immediately regardless of anything else. If organic search is worth
investing in at all, B3b is the pragmatic middle path — it directly fixes both flagged problems (dead
sitemap URLs and zero indexable content) without committing to B3a's rewrite. Defer B2-alone or B3a
unless SEO becomes a bigger strategic priority than the referral-growth plan already on record.

### Issue C — Supplementary SEO items (lower urgency, same report)

Three smaller items the SEO check also flagged today, none individually urgent but each cheap to fix:

| Item | Option | Effort | Owner | Note |
|---|---|---|---|---|
| Title tag (38 chars) and H1 carry no target keyword | Copy pass to work a phrase like "group Bible study" into the title/H1 without losing the brand-voice tone | Low (~1 hr copy + a deploy) | Marketing (copy) + engineering (deploy) | Small, safe win |
| No `SoftwareApplication`/`Product` schema on the pricing page | Add JSON-LD structured data with the current two-tier pricing | Low-medium (a few hours) | Engineering | Standard addition, low risk |
| Homepage loads 11 separate Google Fonts families via one render-blocking stylesheet | Audit which font families are actually used, consolidate to 2-3, add `font-display: swap` and preconnect/preload for the ones kept | Medium (half a day: audit, change, visual QA) | Engineering + design sign-off | The warm parchment-and-gold identity (Playfair Display / Lora / IM Fell English) is a named differentiator — don't cut a font that's actually in use, just stop loading families that aren't |

---

## Part 2 — Drafted replies

13 items total: 9 explicit-need, 4 networking, 1 skipped (folded into the explicit-need count above
before the skip). Every non-skipped draft below was rewritten against the `humanizer` skill's
checklist (no em dashes, no staged "not saying X, just Y" hedging repeated verbatim, no templated
closers) before finalizing.

### R1 — reddit — explicit need
**Thread:** r/Christianity — "Any one know where to get some group Bible studies?" (2026-09-18, 3
comments) — https://www.reddit.com/r/Christianity/comments/1wjdqi2/any_one_know_where_to_get_some_group_bible_studies/

> I did something similar for about two years, writing a full study from scratch every week and printing it for a group of 15 to 20. What surprised me was noticing the same thing you're describing: the weeks I brought less prepared material, people talked more, not less. I'd been treating a thick handout as what made the study feel legitimate, and it was actually getting in the way of people just sitting with the text themselves.
>
> If you want something ready-made instead of writing weekly, The Gospel Coalition has free studies, and RightNow Media's library is solid if your church already has access. The bigger shift for me wasn't finding better material though, it was cutting it down to a passage and two or three questions and letting the group mark up the text themselves instead of reading my notes about it.
>
> That's actually part of what got me into building FellowScript. It's free for a group your size, and it killed the printing loop for me: everyone reads the same passage and leaves notes right on it, so nothing gets photocopied anymore. The less-prep shift works fine on paper too, but if the printing and prep grind specifically is what's wearing you down, it might be worth a look. fellowscript.com

### R2 — reddit — SKIPPED
**Thread:** r/Reformed — "How do you actually remember what you hear on Sunday?" (2026-09-17, 27
comments) — https://www.reddit.com/r/Reformed/comments/1wiqvuy/how_do_you_actually_remember_what_you_hear_on/

Skipped. Same handle style and near-identical title to a thread already answered yesterday on
r/TrueChristian (that reply — R1 in `response-style-guide.md` — is already drafted, status
unconfirmed-posted). The report flags this as very likely the same person cross-posting, possibly as
market research for a competing product. Posting a second, near-identical pitch to the same person
across two subreddits risks looking spammy regardless of intent, and this run had no way to check the
poster's post history (Reddit unreachable). Needs a human to check `cirlorm_io`'s history before
deciding whether to engage here at all.

### R3 — reddit — explicit need
**Thread:** r/TrueChristian — "Young adult small group topics" (2026-08-30, 6 comments, 19 days old) — https://www.reddit.com/r/TrueChristian/comments/1w2klyq/young_adult_small_group_topics/

> My first small group was young adults too, and I'd never led one before either. I spent weeks planning a long systematic theology series because it felt like the serious choice, and it fell apart by week three. The material assumed a foundation the group didn't have yet, since we'd never actually sat in a room together before that.
>
> For a first group, something short and conversational works better: a single Gospel, or a short letter like Philippians or James, six to eight weeks, with simple observation and application questions instead of a teaching-heavy format. The real skill you're building those first couple months is getting a room of people comfortable talking, not covering material.
>
> What helped me hold onto momentum between our first few meetings was having somewhere the group could drop a note or a verse that stuck with them during the week, instead of everything resetting to zero every time we met. Even something as simple as a shared group chat or a shared doc works fine for that — the tool isn't really the point, it's giving people a place to leave a thought between meetings so the momentum doesn't rely entirely on the next session going well.

Rewritten at Jacey's request (2026-09-19) to drop all product promotion — no FellowScript mention,
no link. Beats 1 and 2 are unchanged; beat 3 is rewritten to stand alone as a complete answer
instead of setting up the product mention it originally led into.

### R4 — reddit — explicit need
**Thread:** r/Reformed — "How do you take notes on your Bible?" (2026-07-23, 26 comments) — https://www.reddit.com/r/Reformed/comments/1v4anfo/how_do_you_take_notes_on_your_bible/

> I've got a similar attention issue, and full outline-style methods like BSF's homiletics approach never stuck for me either. There are too many fields to fill in for every verse. I tried forcing myself into a rigid multi-part method for a while because it looked thorough, and mostly I just stopped taking notes because it felt like homework.
>
> Cutting it down to one question and one observation per passage made the difference. You're not writing a commentary, you're trying to remember what stood out. For ADHD specifically, tying the note directly to the verse instead of a separate notebook page matters more than it seems, since flipping back to find the right page later is its own tax on attention.
>
> That's actually the exact thing that got me building FellowScript. Notes stay attached to the verse itself instead of a separate page, and sharing them with the men's group is one tap instead of retyping anything into a group thread. The less-is-more part works on paper too, but the verse-attached part might be where things are actually falling apart for you. fellowscript.com

### R5 — reddit — explicit need
**Thread:** r/Reformed — "Bible Study Training Resources" (2026-07-09, 5 comments) — https://www.reddit.com/r/Reformed/comments/1urxvuv/bible_study_training_resources/

> I've co-led before too, splitting slides and discussion questions between two people. We leaned hard on slides for a long stretch, and engagement was flattest exactly on the weeks we projected the most content. People were watching, not talking.
>
> For training resources specifically, Simeon Trust runs solid workshops (in person and online), and The Gospel Coalition has decent leader-training material if you want something structured. But the bigger lever for us wasn't the training itself, it was cutting slide time and having everyone open to the same passage and mark it up together for the first ten minutes before any teaching happened.
>
> That shift toward everyone marking the same text is actually what pulled me into building FellowScript. It just gives a group a shared place to keep doing that outside the meeting too. It's not a training resource, but it might be worth trying alongside whatever training you land on. fellowscript.com

### R6 — reddit — explicit need
**Thread:** r/Bible — "Taking notes, still not retaining much. Tips?" (2026-07-14, 18 comments) — https://www.reddit.com/r/Bible/comments/1uvhngd/taking_notes_still_not_retaining_much_tips/

> I take notes in an app too, and had this exact problem for a long time. Things felt captured in the moment, then a month later they were basically gone. I was tagging by topic, which felt organized, but I'd forget which tag I used and the note would disappear into the pile anyway.
>
> Tying every note to the actual verse reference instead of a theme tag changed that for me, along with forcing myself to write one line connecting it to something happening in my life right then. That's what makes it retrievable later. When I land back on that verse, which happens naturally if you're reading through a book more than once, the note resurfaces with it.
>
> That verse-first structure is part of why I built FellowScript. Notes live attached to the verse, so tagging isn't really necessary, you just land back on the passage. It works fine solo, no group required for that part, but the attach-to-the-verse idea is worth trying even without switching apps. fellowscript.com

### R7 — reddit — explicit need
**Thread:** r/Christian — "Bible Study groups online" (2026-06-26, 0 comments, dead thread) — https://www.reddit.com/r/Christian/comments/1ug02wf/bible_study_groups_online/

> I've got family and friends spread across different churches and time zones too, and we tried a weekly Zoom for a while. The call kept falling apart, not because the content was bad, but because syncing five people's calendars for a live call every week was the actual bottleneck. Eventually it just stopped happening.
>
> The fix for us wasn't a better call platform. It was decoupling doing the study from being on a call at the same time. Everyone reads and marks the passage on their own time during the week, and the live piece, even just a group thread instead of a call, becomes the recap instead of the whole thing.
>
> That's most of why I built FellowScript. Group notes and highlights update as people go, so the study doesn't wait on everyone's calendar syncing, and you can still hop on a call in-app if you want the live piece for the recap. It's not the only way to solve this, but if the scheduling part specifically is what's killing it for your group, it might be worth a look. fellowscript.com

Note: this thread has zero comments and is nearly three months old — low odds of visibility even if
approved, but included per the queue instructions since it was listed and matches the target-audience
profile's "scattered groups" segment almost exactly.

### R8 — reddit — explicit need (carried over from 2026-09-16/17, still unaddressed)
**Thread:** r/pastors — "Bible Study Group - Where to Start???" (2026-07-14, 10 comments, stale) — https://www.reddit.com/r/pastors/comments/1uvx0zl/bible_study_group_where_to_start/

> My first time leading, I had zero group experience either, and I overthought the what-do-we-study question for weeks before we ever met. I picked a long systematic theology series because it felt serious, and it was the wrong call for a group that had never sat in a circle together before. Nobody talked, because the material assumed a foundation we didn't have as a group yet.
>
> For a first group, something short and conversational works better: a single Gospel, or a short letter like Philippians or James, six to eight weeks, with simple observation and application questions rather than a teaching-heavy format. The skill you're actually building the first few months is getting a room comfortable talking, not covering material.
>
> What helped me hold onto momentum between our first few meetings, since as a brand-new leader I had nothing else built up yet, was having somewhere the group could drop a note or a verse that stuck during the week instead of everything resetting to zero each time we met. That's part of why I built FellowScript. It's free for a group your size, and it's not required to start (paper works fine too), but it might help with the momentum piece. fellowscript.com

Note: today's report only names this as "carried over, unchanged" without re-detailing it; this draft
uses the fuller detail from 2026-09-17's own digest (brand-new leader, no group experience). Written
fresh for today per the four-beat/humanizer process rather than reusing yesterday's auto-draft, since
the response-style-guide's hand-finished voice is the target shape going forward, not the pipeline's
older default phrasing.

### R9 — reddit — explicit need (carried over from 2026-09-16/17, still unaddressed)
**Thread:** r/Christianity — "College Bible study" (Louisville campus group, 2026-09-13) — https://www.reddit.com/r/Christianity/comments/1wfmg6m/college_bible_study/

> I helped start a campus group in college too, from nothing: no name recognition, no built-in group of people. We spent the first month trying to recruit broadly with flyers and a table in the student union before we had anything worth inviting people to, and it was mostly wasted effort. What actually worked was starting with three or four people we already knew and growing from there by invite.
>
> For a first semester, keep it small and low-commitment: a short study, a Gospel or a short letter, six to eight weeks, meeting somewhere consistent like a dorm common room instead of reserving a new room every week. Don't try to be the campus ministry right away. Just be one group that meets reliably.
>
> Staying connected between meetings mattered more than I expected for keeping a brand-new group from fading after the first few weeks. That's part of what got me into building FellowScript. It's free for a group your size, with notes on the passage that everyone can see. It's not a requirement to get started, but it's part of what helped ours hold together past the first month. fellowscript.com

Same note as R8: written fresh today rather than reused from yesterday's draft.

### R10 — instagram — networking
**Post:** @talmida.life — "Not everyone can attend a Bible study at the same time every week" (2026-09-17) — https://instagram.com/p/DdZPUwGAJo6

> This is such a smart structure for how differently everyone's weeks actually go. I'm curious about the handoff specifically. Once someone finishes on their own schedule and jumps into the weekly conversation, how do you keep it from feeling like they're a step behind people who finished earlier? Do you resurface anything from earlier in the week, or does the conversation just meet everyone where they are?

No FellowScript mention. This account has already built and shipped its own solution to the exact
pain point (async study + private community); pitching a competing product into that would be tone
deaf, not a discovery question. Per the task's own networking-posture guidance, only mention
FellowScript when the post names a problem the product genuinely still addresses for that person —
this one doesn't.

### R11 — instagram — networking
**Post:** @choosejesus24 — "Foundations for a Beautiful Life - ONLINE BIBLE STUDY" (2026-09-17) — https://instagram.com/p/DdZWN1qjwYu

> Weekly and consistent is its own accomplishment. A lot of online studies fade after a few months. What's kept people coming back Thursday after Thursday? Is it the topic lineup, or something about the format itself, live versus replay, YouTube versus Facebook, that's made it stick for your group specifically?

### R12 — instagram — networking
**Post:** @ifeoluwaakande_ — "Day 11/21… how using a Bible study journal has changed my study" (2026-09-17) — https://instagram.com/p/DdZVAV9jcc1

> Day 11 and still going is real consistency. I'm curious what the actual turning point was: a specific method someone showed you, or more that you kept experimenting until something clicked? Also curious what you wish someone had told you on day one that you only figured out by day eleven.

### R13 — instagram — networking (flagged: ambiguous posture)
**Post:** @simonlawton — small-group/book-club study content promo (2026-09-18) — https://instagram.com/p/DdbEE-2CDem

> This is a solid breakdown for group leaders, especially the connect-groups and cell-groups framing. Are you working with any specific denominational networks on this, or is it more general small-group leaders across networks? I've noticed a gap in tooling specifically for cell and connect-group structures versus traditional small groups.

Flagged plainly rather than guessed: this account reads as a curriculum/content business promoting
itself to small groups, not an individual sharing a personal group or event. It doesn't cleanly fit
either the explicit-need or the event/gathering networking posture the task describes — there's no
stated problem and no personal story to respond to. The draft above treats it as a partnership-scouting
opener (a plausible "are we the same kind of thing, could we work together" comment) rather than a
"help a stranger" reply, per the report's own note that this item is different in kind from the other
three Instagram candidates. A human should confirm that reading before approving.

---
*Unattended daily marketing pipeline run. Full subagent transcripts available in the originating
session if deeper detail is needed.*

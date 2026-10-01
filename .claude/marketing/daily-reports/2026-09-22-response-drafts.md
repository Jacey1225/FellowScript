# FellowScript Response Drafts — 2026-09-22

Scheduled/unattended run. **Nothing in this file has been posted, replied to, or sent anywhere.**
Everything below is a draft for human review. Posting only happens after explicit approval in
#prefect-victory, carried out by the always-on marketing process, not this script.

**Live verification note:** Reddit (`reddit.com`, `old.reddit.com`), X/Twitter, and Facebook were
all unreachable from this environment (network policy blocks fetches to all three, confirmed via
both `WebFetch` and direct `curl`). I could not independently re-verify subreddit self-promotion
rules or thread/account freshness today. Drafts below follow the report's own summaries and lean
on established precedent from `response-style-guide.md`, where disclosed FellowScript mentions
have already been drafted (and in some cases hand-approved) on r/Christianity and r/TrueChristian
without issue. Where a specific freshness concern exists (R5), it's flagged rather than resolved.

---

## Part 1 — Resolution options

### 1. SEO — architectural indexing ceiling (critical, connects to open 2026-09-18 audit finding)

**The problem, restated:** fellowscript.com is a client-side HashRouter SPA. `sitemap.xml` lists
exactly one URL (`/`). Hash fragments (`/#/reader`, etc.) are not distinct, server-resolvable URLs
to a crawler, so there is no realistic path to ranking on anything but the brand name as the site
is currently built. This sits on top of an already-open, separate finding from the 2026-09-18
indexing audit: `site:fellowscript.com` returns zero Google results, traced to something outside
the repo's static SEO files (likely Cloudflare/WAF config or Search Console verification) —
unresolved. Fixing the architecture below does not by itself fix that root block; both need
engineering attention, ideally together.

**Do regardless of which path is chosen (near-zero effort, do today-ish):** `/privacy` and `/terms`
both return 200 but carry a `canonical` tag pointing back to `/`, making them byte-identical to the
homepage as far as search engines are concerned, and neither is linked from the footer. Remove the
incorrect canonical tag and add footer links. Trivial fix, no architecture decision required,
engineering-owned, effectively zero risk.

**Path A — Static marketing shell, leave the app alone.** Keep the React app (HashRouter, auth,
reader, everything behind login) exactly as it is. Build a small set of plain static or
lightweight-framework pages (home, pricing, privacy, terms, maybe a blog) served at real paths
(`fellowscript.com/`, `/pricing`, `/privacy`, `/terms`) instead of hash routes.
- *Effort:* Low–medium. A few static pages, no changes to the authenticated app's routing.
- *Owner:* Frontend engineering, with marketing supplying copy.
- *Trade-off/risk:* Two sources of truth for marketing copy (static pages vs. in-app content) that
  can drift out of sync if not maintained together. Does not help indexing of anything behind
  login, but that content shouldn't be public/indexed anyway, so that's not really a loss.
- *Why it's the pragmatic default:* Smallest blast radius, fixes the orphaned-page issue as a side
  effect, and doesn't touch the working authenticated app at all.

**Path B — Migrate off HashRouter to BrowserRouter + add prerendering.** Switch the app's router,
add server-side rewrite rules (all paths fall back to `index.html`), and put a prerendering layer
in front (a hosted service like Prerender.io, or a self-hosted Puppeteer-based prerender
middleware) so crawlers get fully rendered HTML per route.
- *Effort:* Medium–high. Routing migration, server/infra config changes, new prerender
  infrastructure to stand up and maintain.
- *Owner:* Engineering (frontend + backend/infra).
- *Trade-off/risk:* Broader blast radius than Path A — touches the live app's routing, which
  carries real regression risk on existing bookmarked `/#/...` links unless redirects are added.
  Also worth asking why HashRouter was chosen originally (often: simpler static hosting, no server
  rewrite rules needed) before undoing that decision.

**Path C — Full SSR/SSG framework migration** (e.g., move the frontend to Next.js or similar,
server-rendering public routes while keeping the authenticated app's current SPA behavior via
client components).
- *Effort:* High. Closest to a frontend rewrite; likely a multi-week engineering project.
- *Owner:* Engineering, sustained effort.
- *Trade-off/risk:* Highest risk and cost of the three, but the most durable fix — solves
  per-route SEO/meta consistency automatically and best positions the site for future public
  content (a blog, landing pages per ICP segment per `target-audience-profile.md`) if that's ever
  wanted. Overkill if the only goal right now is "get indexed."

**Recommendation shape, not a decision:** Path A resolves the concrete, named problems
(one-URL sitemap, orphaned `/privacy`/`/terms`) at the lowest cost and risk. Path B or C only make
sense if there's an actual plan to publish more indexable content later (blog, landing pages) —
worth asking that question before picking a path. Whichever is chosen, flag it to whoever owns the
still-open 2026-09-18 zero-Google-results item, since architecture and that root block are
separate blockers and both need to clear before organic search meaningfully works.

### 2. Competitor doc correction — SmartGroups pricing (trivial, not urgent)

`COMPETITOR-REPORT.md` and `fellowscript-overview.md` describe SmartGroups as a flat "$59/mo+ for
2+ groups." Live pricing is actually a 3-tier ladder: Starter (free, 1 group, unlimited members),
Growth ($59/mo, up to 6 groups), and a new Scale tier ($12/group/mo, unlimited groups). Not a price
change, just more granular than documented.
- *Effort:* Trivial — a documentation edit in two files.
- *Owner:* Marketing (whoever next touches either doc).
- *Trade-off/risk:* None. No urgency; fix opportunistically next time either file is opened.

### 3. `market-seo` skill install gap (systemic, will recur every future SEO check)

The skill's documented `scripts/analyze_page.py` doesn't exist in this install — only `SKILL.md`,
no `scripts/` directory. Today's agent worked around it with direct `curl` fetches and manual HTML
parsing, so today's findings are grounded in real content rather than fabricated, but every future
`market-seo` run will hit the same gap and need the same workaround unless it's fixed.
- *Effort:* Low — either add the missing script or update `SKILL.md` to match what the skill
  actually does today.
- *Owner:* Whoever maintains the marketing pipeline's skill installs (engineering or marketing
  tooling, depending on how that's organized here).
- *Trade-off/risk:* None found; purely a documentation/install consistency fix.

---

## Part 2 — Drafted replies

11 items from today's queue (5 Reddit via Zernio, 6 from the ForumScout sheet). IDs assigned in
report order.

---

### R1 — Reddit, r/Christianity — "Any one know where to get some group Bible studies?"
**Posture:** explicit_need · **Delivery:** comment
https://www.reddit.com/r/Christianity/comments/1wjdqi2/any_one_know_where_to_get_some_group_bible_studies/

> I did something pretty similar for a couple of years, writing a fresh study every week for a
> group of about 15-20 and printing it out each time. What I noticed, the same thing you're
> describing, is that the weeks I showed up with less prepared material were actually the weeks
> people talked more. I'd assumed a thick handout was what made a study feel serious. It turned
> out to mostly just be in the way.
>
> If you want something ready-made instead of writing weekly, The Gospel Coalition has free
> studies, and RightNow Media's library is solid if your church already has access to it. Cutting
> everything down to one passage and two or three questions, and letting people mark up the text
> themselves instead of reading my notes about it, mattered more than the material itself.
>
> Full disclosure since some subs care about this: I ended up building an app around that shift,
> FellowScript. It's free for a group your size, and it basically killed the printing loop for me
> since everyone reads the same passage and leaves notes right on it. Not saying you need it, just
> figured I'd mention it in case the prep-and-print grind is the part wearing you down too.
> fellowscript.com

**Flag:** `response-style-guide.md` already contains a hand-finished draft for this *exact* thread
(dated 2026-09-19, credited to Jacey's own rewrite). It's unclear whether that version was ever
actually posted, or whether this is why the thread resurfaced in today's Zernio scan. **Possible
duplicate — check before approving** to avoid a second reply landing on the same thread.

---

### R2 — Reddit, r/TrueChristian — "Young adult small group topics"
**Posture:** explicit_need · **Delivery:** comment
https://www.reddit.com/r/TrueChristian/comments/1w2klyq/young_adult_small_group_topics/

> The first time I got asked to lead a group I said yes before I had any plan at all, then spent
> way too long trying to build the "perfect" twelve-week series so I'd look like I knew what I was
> doing. I burned out on the planning before the first meeting even happened, and most of that
> work never got used.
>
> What worked better the second time was starting with just four weeks on one theme, something
> practically relevant like identity in Christ or what prayer actually looks like day to day, not
> a whole semester upfront. Keep the format simple: read the passage together, three questions,
> close in prayer. If it's working after four weeks, extend it. If it's not, you haven't lost a
> semester.
>
> One small thing that's helped my own group stay consistent between meetings: I built an app
> called FellowScript where notes get shared with the group instead of staying in someone's
> private notebook, so people actually remember what was said last week. Not something you need to
> start, just useful once the group's running. fellowscript.com

---

### R3 — Reddit, r/TrueChristian — "Bible study"
**Posture:** explicit_need (no product mention) · **Delivery:** comment
https://www.reddit.com/r/TrueChristian/comments/1wjck51/bible_study/

> Fill-in-the-blank workbooks can turn a study into busywork instead of an actual conversation, so
> what you're feeling makes sense. A lot of churches default to that format because it's easy to
> run, not because it's the best way to engage with the text.
>
> If there's any room to say something, it might be worth telling whoever leads it that you'd get
> more out of a read-and-discuss format, even just for a few weeks as a trial. Some leaders
> genuinely don't know people want that until someone says so.

**Note:** She's venting, not asking for a tool. Diagnosed as a pure validation case — no
FellowScript mention, matching the report's own posture note.

---

### R4 — Reddit, r/TrueChristian — "Is it normal to feel pressured to become a discipleship group leader when you still feel like a new Christian?"
**Posture:** explicit_need · **Delivery:** comment · **Status: SKIPPED**
https://www.reddit.com/r/TrueChristian/comments/1wb0v4y/is_it_normal_to_feel_pressured_to_become_a/

**Skip reason:** This appears to be the same thread as the "Discipleship leadership-readiness
thread, 2026-09-22 (no product mention)" example already recorded in `response-style-guide.md` as
a reply Jacey hand-wrote directly from a post shared outside the automated queue — same date, same
core scenario (a new believer pushed into leading before being personally discipled). Rather than
draft a second, possibly redundant or inconsistent reply onto a thread that may already have a
posted response, this item is skipped. **Please verify directly** whether that hand-written reply
was already posted to this thread; if not, it may just need approving as-is rather than a fresh
draft from this pipeline.

---

### R5 — Reddit, r/pastors — "Bible Study Group - Where to Start???"
**Posture:** explicit_need · **Delivery:** comment
https://www.reddit.com/r/pastors/comments/1uvx0zl/bible_study_group_where_to_start/

> The first group I led that was mostly older, longtime believers, I used the same fast-paced
> format that worked with a younger group I'd led before: lots of questions, quick turnaround. It
> fell flat. People wanted room to actually reflect and tell their own stories, and the pace I
> brought in just cut that off.
>
> Slowing down mattered more than anything I changed about the material itself. Fewer questions,
> more silence, letting it be discussion-led instead of me driving it the whole time. A consistent
> day and time each week ended up mattering more to this group than any particular curriculum.
>
> Small aside since I'm not sure how relevant it is to your group specifically: I work on an app
> called FellowScript that keeps everyone's notes in one shared place, which has helped a couple of
> people in my own group who don't reliably write things down between meetings. Worth a look if
> that's ever a pain point for yours. fellowscript.com

**Flag:** Thread is from 2026-07-14 — over two months old. The report itself says to confirm it's
still active before engaging; I couldn't verify this (Reddit unreachable from this environment
today). Check freshness before posting.

---

### R6 — Reddit (via ForumScout), r/TrueChristian — comment on "I think I made a creep of myself at church"
**Posture:** explicit_need · **Delivery:** comment
https://www.reddit.com/r/TrueChristian/comments/1wm13oa/i_think_i_made_a_creep_of_myself_at_church/pb7uo8l/

> I hit the same wall when I was single. Every small group at my church skewed married or a lot
> older, and there wasn't really a lane for someone in their twenties who wasn't paired off yet.
>
> I spent almost a year waiting for a group like that to show up on its own before I realized
> nobody was going to build it for me. Ask a staff member or pastor for a room and a time slot,
> then invite three or four people directly instead of putting up a general announcement. Personal
> invites work a lot better than an open call for this age group, and a small group is easier to
> actually start than a big one.
>
> Once you've got even three or four people, it costs nothing to keep growing it. I built
> FellowScript, an app for exactly that kind of group study, and the group side of it is free with
> no cap. Not required to start one, just mentioning it in case it's useful once you're off the
> ground. fellowscript.com

---

### R7 — Twitter/X, @ThomisticDan
**Posture:** explicit_need (no product mention) · **Delivery:** comment
https://twitter.com/ThomisticDan/status/2101832340368413096

> Forsaking the brethren in Hebrews 10:25 is about neglecting fellowship altogether, not about
> which medium it happens through. An online study where you actually know the people, show up on
> a rhythm, and are known back fulfills that a lot more than sitting in a pew next to strangers
> every week. The risk with online study isn't the platform, it's passivity, watching without any
> real relationship attached to it. If yours has that, you're not forsaking anything.

**Note:** A genuine theological legitimacy question, not a product-shaped need. Diagnosed as a
no-mention case; the answer stands alone.

---

### R8 — Instagram, @inwoodbiblestudy
**Posture:** networking · **Delivery:** DM
https://instagram.com/p/DdjzoJKnF8M

> Saw your post about the open Bible study, love that you're explicitly inviting people to bring
> their doubts and questions instead of expecting everyone to already have it figured out. That's
> a harder thing to actually sustain than it sounds.
>
> Curious how you've kept that spirit alive as the group's grown. Does it get harder to keep it
> feeling open to someone brand new once there's a group of regulars with history together, or has
> it stayed pretty natural?

No FellowScript mention — pure relationship-building per the networking posture; the post names no
problem the product addresses.

---

### R9 — Instagram, @csulb_biblekoin
**Posture:** networking · **Delivery:** DM
https://instagram.com/p/DdkktotpkEv

> Saw your post about the CSULB Bible study, food and fellowship after is a great combo for
> getting people to actually stick around and talk instead of leaving right after.
>
> What's worked for you all in keeping people coming back week over week as the semester goes on?
> Campus groups are always fighting the calendar, midterms, breaks, everyone's schedule falling
> apart by week eight. Curious if you've found anything that keeps momentum through that stretch.

No FellowScript mention — campus segment is pricing-blocked per `target-audience-profile.md` §5.1,
so this is relationship/awareness only, not a conversion target.

---

### R10 — Instagram, @godschurchphilly
**Posture:** networking · **Delivery:** DM
https://instagram.com/p/DdkS2afKult

> Saw your post about the weekly online study, always interesting to see how different groups make
> that work over Zoom instead of in person.
>
> How do you all handle notes or follow-up between sessions? That's usually the part that gets
> lost with online groups specifically, everyone's just staring at a screen during the session and
> then nothing carries over to the next week. Curious if you've found a rhythm that works for
> keeping people engaged between calls.

No FellowScript mention — a genuine discovery question that could surface a latent pain point
(notes/follow-up), left open rather than steered toward a pitch.

---

### R11 — Facebook, UK Methodists group
**Posture:** networking · **Delivery:** comment
https://www.facebook.com/groups/2211562545/posts/10163330640277546/

> The tech and faith angle here is genuinely interesting, especially running the same conversation
> across four different states and comparing notes. Most AI-and-church discussions I've seen stay
> pretty surface-level (is it good or bad), so doing it as an actual ongoing discussion group is a
> different approach.
>
> What's been the most surprising disagreement to come out of it so far? Curious whether people
> are mostly landing in the same place or genuinely split.

No FellowScript mention — pure curiosity engagement per the networking posture.

---

## Summary

- **11 items** reviewed → **10 drafted**, **1 skipped** (likely duplicate, R4).
- **By posture:** 7 explicit_need (R1, R2, R3, R4, R5, R6, R7), 4 networking (R8, R9, R10, R11).
  Of the 7 explicit_need items, 2 (R3, R7) diagnosed to no product mention at all.
- **By delivery:** 8 comment (R1, R2, R3, R4, R5, R6, R7, R11), 3 DM (R8, R9, R10).
- **Resolution proposals:** 3 (SEO indexing architecture, SmartGroups pricing doc correction,
  `market-seo` skill install gap).

# FellowScript Response Drafts — 2026-09-16

Unattended draft-only run. Nothing below has been posted, replied to, or published anywhere.
Every item is a proposal for a human to review, edit, or approve in the #prefect-victory Discord
channel. Posting (if any) is handled separately, after explicit approval, by the always-on
marketing bot — not by this process.

**Verification gap, noted plainly:** this run could not reach reddit.com through its available
web-fetch/search tools (every attempt to check subreddit-specific self-promotion rules for
r/Christianity, r/TrueChristian, r/Reformed, and r/Wilmington failed at the network level). No item
below was skipped for a confirmed rule violation, because none could be confirmed either way — but
none of the Reddit self-promotion rules were independently verified this pass either. Treat the
promotional drafts (R2, R3, R4, R5, R7) as unverified against subreddit rules and sanity-check
before approving.

---

## Resolution options

### 1. SEO structural defect (HashRouter / client-rendered SPA, SEO Health 42/100, flagged 3 days running)

Per `SEO-AUDIT.md`, fellowscript.com is a single-page app on a `HashRouter`: the server delivers a
near-empty HTML shell, and every in-app route (including `/privacy` and `/terms`) lives behind a
`#` fragment that isn't independently indexable. Practical effect: the domain has exactly one real,
rankable URL, and nothing else can be built (comparison pages, leader-first content, a second
keyword) until this is addressed.

**Option A — Quick win only, defer the structural fix.**
Link `/privacy` and `/terms` from the homepage footer (they already exist, already in the sitemap,
just orphaned) and widen the title tag to include a category keyword. Effort: under an hour,
frontend/marketing copy change, no architecture risk. Trade-off: doesn't touch the core problem —
still one indexable URL, so this buys a small trust/on-page bump but not real SEO growth. Owner:
frontend engineering for the footer link, marketing for the title copy.

**Option B — Add prerendering/SSR just for the marketing shell, keep the SPA for the app.**
Use a build-time prerendering tool (e.g., a static-generation step, or a prerendering
service/middleware that serves fully-rendered HTML to crawlers) for the homepage and any future
marketing routes, while the authenticated app (Reader, account, etc.) stays a client-rendered SPA
behind login. Effort: medium — a few days of engineering to wire up prerendering and verify it
doesn't fight the existing `HashRouter`. Risk: added build complexity, and prerendered snapshots
can drift from the live page if not kept in the deploy pipeline. Owner: engineering (frontend).
This is the path that requires deciding whether to *also* migrate off `HashRouter` to real paths
(`/privacy` instead of `/#/privacy`), which the audit flags as the deeper architectural blocker —
prerendering without also fixing routing still leaves sub-pages unindexable as distinct URLs.

**Option C — Full framework migration to a stack with native SSR (e.g., Next.js-style
server-rendering) for the marketing surface.**
Most thorough fix: real distinct URLs, real server-rendered HTML per route, no reliance on
JS-execution timing for crawlers. Effort: high — this is close to a rewrite of the marketing-facing
routes, and needs care not to disturb the authenticated Reader experience or the Tauri desktop
wrapper (which points at the live web app, so a routing change has to stay compatible with
whatever it expects). Risk: regression risk across a shipped product with a desktop client
depending on the current URL scheme; also the highest-effort option relative to the others. Owner:
engineering, likely needs a dedicated planning pass before starting.

**Option D — Split the marketing site from the app entirely.**
Stand up a small, separate, fully static/server-rendered marketing site (its own lightweight
build) for `/`, `/privacy`, `/terms`, and future content (the "vs SmartGroups" comparison page,
leader-first guides) on the same domain, while the actual product app continues to live at its own
route or subdomain. Effort: medium — new build/deploy pipeline, but low risk to the existing app
since nothing about the authenticated SPA changes. This is the common industry pattern (marketing
site decoupled from app) and gives full control for future content work without touching the
`HashRouter` question at all. Trade-off: two codebases/deploys to keep in sync (e.g., feature
messaging, pricing) instead of one. Owner: engineering to set up the split, marketing to own
content on the new surface going forward.

**Recommendation for whoever decides:** Option A should happen regardless of which larger path is
chosen — it's free and immediate. Between B, C, and D, the audit's own prioritization (fix the
structural ceiling before any content work) points toward whichever of B/C/D the frontend owner
judges lowest-risk against the existing Tauri desktop dependency; that's an engineering call this
digest can't make from the marketing side. Flagging it to the frontend deploy owner (per the daily
report's own "worth confirming... whether a fix is in flight" note) is the immediate next step
either way.

### 2. SmartGroups tier/feature changes (re-confirmed 3rd day; new "AI-Powered Feature" banner unconfirmed)

SmartGroups' Growth ($59/mo, up to 6 groups) and Scale ($12/mo per group) tiers are now verified
live for a third consecutive day. New and unconfirmed: a homepage "New AI-Powered Feature" banner
that may be a genuinely new capability or just repackaged marketing copy for the AI lesson
generator already documented in `COMPETITOR-REPORT.md`.

**Option A — Wait for the next scheduled full competitor-report refresh.**
Fold this into the normal refresh cadence. Effort: none extra. Risk: if the banner turns out to be
a real new capability that changes the competitive picture (e.g., something that closes the gap
`fellowscript-overview.md` currently credits FellowScript with), the report stays stale on that
point until the next scheduled pass. Owner: marketing (passive, no action needed now).

**Option B — Targeted one-off addendum now.**
Spend one short pass specifically on the SmartGroups banner: click through, see what it actually
claims to do, and check whether it's live functionality or a copy refresh. Append a short dated
note to `COMPETITOR-REPORT.md` without a full re-verification of the other three competitors.
Effort: low, roughly the scope of a single research task. Owner: marketing. This is the
proportionate option given only one data point (a banner) changed, not the whole competitive
picture.

**Option C — Trigger a full ad-hoc competitor-report refresh ahead of schedule.**
Re-verify all four comparables (Hallow, YouVersion, Abide, SmartGroups) now, since SmartGroups has
shown two changes inside a few days (tier restructuring, now the banner). Effort: medium-high, the
full scope of a `COMPETITOR-REPORT.md` refresh. Risk: refresh churn if the banner turns out to be
copy-only and nothing else moved. Owner: marketing.

**Recommendation for whoever decides:** Option B is the proportionate move — it resolves the one
open unknown without paying for a full refresh that three of four data points don't currently
justify.

---

## Drafted replies

### R1 — r/Christianity: "How to split costs in a Bible study group?"
- **Platform:** Reddit
- **Thread:** https://www.reddit.com/r/Christianity/comments/1wgon2y/
- **Posture:** explicit_need (no FellowScript mention — the product doesn't address cost-splitting;
  the report calls this relationship-building with a clearly qualified leader, not a pitch)

> We ran into this too once our group passed a dozen people. What worked best for us was dropping
> the per-head math entirely: we set up a simple recurring group fund (just a shared Venmo or
> Zelle) that people toss into on whatever schedule works for them, no exact split enforced, and
> whoever's hosting or buying snacks that week draws from it. It never felt like a bill that way.
> If you want more structure, rotating which family hosts, and therefore covers that week's cost,
> spreads it out pretty evenly without anyone doing math. With 26 people counting kids, I'd also
> just ask the group directly what feels fair to them. That conversation usually matters more than
> whatever system you land on.

### R2 — r/TrueChristian: "Young adult small group topics"
- **Platform:** Reddit
- **Thread:** https://www.reddit.com/r/TrueChristian/comments/1w2klyq/
- **Posture:** explicit_need

> For a first group, I'd keep it simple and not try to cover everything at once. A short book study
> works better than a topics list for young adults because it gives you a natural throughline.
> Philippians or James are both short, practical, and easy to turn into discussion (identity, joy
> under pressure, faith and action, stuff twenty-somethings are actually wrestling with). Pick 5-6
> weeks, one passage at a time, and leave room for tangents.
>
> One thing that's helped groups I've seen: having a way to drop a short prompt or question into
> everyone's feed between meetings so the study doesn't go quiet for two weeks. I work on
> FellowScript, which has a free feature that does exactly that, it schedules prompts to the group
> automatically. Mentioning it because it solves that specific "keep momentum between meetings"
> problem, not as a pitch for the whole app.

### R3 — r/Christianity: "Devotional book recommendations?"
- **Platform:** Reddit
- **Thread:** https://www.reddit.com/r/Christianity/comments/1w33s2s/
- **Posture:** explicit_need

> After a year-long plan, I'd go shorter next round: something like a study through one epistle
> (Philippians or 1 Peter) or a themed 6-8 week study rather than jumping into another year-long
> commitment right away. Gives the group a win and keeps energy up.
>
> Also, if part of what made the last plan work was having something the whole group followed
> together, FellowScript (which I work on) has a shared devotion-plan feature that keeps everyone
> on the same day and passage automatically. Mentioning it because it's free and matches what you
> described wanting, not because I think you need an app to do this.

### R4 — r/Christianity: "Lifestyle + habits for modern day Christians"
- **Platform:** Reddit
- **Thread:** https://www.reddit.com/r/Christianity/comments/1w3j0ar/
- **Posture:** explicit_need

> Drafting questions weeks out is a great habit. Most leaders I know are scrambling the night
> before. Curious how you're currently getting those questions to the rest of the group once
> you've written them? That's usually where the prep habit breaks down for people: the questions
> are ready but they live in a personal doc nobody else sees until the meeting.
>
> I work on FellowScript, and the reason I ask is our notes feature lets you share what you've
> prepped straight to the group ahead of time instead of it sitting in your own notebook. Only
> bringing it up because it sounds like you've already built the hard habit of prepping ahead and
> might just be missing the easy part of getting it to people.

### R5 — r/Reformed: "Balancing Teaching and Community"
- **Platform:** Reddit
- **Thread:** https://www.reddit.com/r/Reformed/comments/1w9f77b/
- **Posture:** explicit_need

> This is one of the harder parts of leading, honestly: teaching well on Sunday (or whenever you
> meet) is one skill, but keeping the relational thread alive across a week when everyone's
> scattered is a completely different job, and most curricula don't help you with the second one
> at all.
>
> A few things I've seen work without adding a lot of overhead: a standing prayer-request thread
> that isn't tied to the meeting, and giving people a low-effort way to share something from their
> own reading mid-week instead of saving it all for group time. I work on FellowScript and we built
> shared notes and group threads partly for this exact gap. Not a fix for the relational distance,
> but a way to keep the thread from going fully silent between Sundays.

### R6 — r/TrueChristian: "Grow Together in Christ — Beginning a Home Fellowship in Toronto"
- **Platform:** Reddit
- **Thread:** https://www.reddit.com/r/TrueChristian/comments/1w74nhl/
- **Posture:** networking (group-formation announcement, no stated problem, no FellowScript
  mention)

> Starting something like this from scratch takes real courage. The first few gatherings are the
> hardest because there's no established rhythm yet. What does a typical evening look like for you
> right now, worship, prayer, study-wise? And how are you thinking about keeping momentum going
> once the new-fellowship excitement wears off in a month or two? That's usually where these things
> either take root or quietly fade. Praying it takes root.

### R7 — r/Christianity: "Any good *non ai* Christian apps?"
- **Platform:** Reddit
- **Thread:** https://www.reddit.com/r/Christianity/comments/1wfwpor/
- **Posture:** explicit_need — **higher risk, flag for careful human review**

> Worth being upfront since you specifically said non-AI: I work on FellowScript, and it does have
> one optional AI feature, a daily check-in prompt you can turn off entirely (nothing else in the
> app touches AI). The core of it is a shared Bible reader with highlighting, notes, and group
> study that doesn't require the AI piece at all. Saying this plainly because burying it would be
> exactly the kind of thing you're trying to avoid. If the AI feature being present at all, even
> off by default, is a dealbreaker, totally fair, and I'd skip it. Just didn't want to recommend it
> without saying so upfront.

*Note: include only if the human reviewer is comfortable with the upfront AI disclosure landing in
a thread from someone who explicitly said they distrust AI-made apps.*

### R8 — r/Wilmington: "Free Meeting Space?"
- **Platform:** Reddit
- **Thread:** https://www.reddit.com/r/Wilmington/comments/1wen9s5/
- **Posture:** explicit_need (no FellowScript mention — product doesn't offer meeting space)

> A few things that have worked for groups I know looking for free space: public library branches
> almost always have meeting rooms you can book for free (just need a library card usually), and a
> lot of churches will let outside groups use a room on a weeknight even if you're not a member
> there. Worth just calling a few and asking directly, most say yes more often than you'd think.
> Some community centers and even bank branches have small free meeting rooms too, if the
> library's booked up.

### R9 — Instagram: @crcmanchester, "Home Cell Wednesdays are back"
- **Platform:** Instagram
- **Source:** ForumScout, 2026-09-16 (no direct URL captured by the sheet)
- **Posture:** networking

> Love seeing home groups get this kind of consistent energy. Wednesdays becoming a fixture like
> that says a lot about the community you've built. What's kept people coming back week after
> week? Curious what's made the biggest difference as the group's grown.

### R10 — LinkedIn: Canonmills Church, one-year Book Club + Craft Group milestone
- **Platform:** LinkedIn
- **Source:** ForumScout, 2026-09-16 (no direct URL captured by the sheet)
- **Posture:** networking

> A full year of Book Club + Craft Group running consistently is genuinely a big deal. Most
> small-group efforts fizzle well before the one-year mark. What's been the hardest part of
> keeping it going as it's grown, and what's surprised you most about what people actually needed
> from it?

### R11 — LinkedIn: Sarah Atunbi, "Releaders Book Club — 14 Days Reading Challenge"
- **Platform:** LinkedIn
- **Source:** ForumScout, 2026-09-16 (no direct URL captured by the sheet)
- **Posture:** networking

> 14 days of structured reading as a group challenge is a great format. The shared deadline does a
> lot of the motivational work a solo reading plan can't. How are you finding the balance between
> people going at their own pace and keeping everyone roughly together? That's usually the tension
> point in challenges like this.

### R12 — LinkedIn: Jason Monastra, Lifeway Research State of Discipleship data
- **Platform:** LinkedIn
- **Source:** ForumScout, 2026-09-14 (no direct URL captured by the sheet)
- **Posture:** networking (peer/thought-leader engagement — no FellowScript mention, the post
  shares data rather than naming a problem the product addresses)

> That gap between 5+ times a month and occasional attendance tracks with what I've seen
> anecdotally too. It's less about the content of any given study and more about whether people
> have built it into a rhythm. Do you think that's mostly a habit/consistency effect, or is there
> something qualitatively different about what people get out of a group once they're that
> regular?

### R13 — LinkedIn: DeDe Reilly, Director of Family Ministries
- **Platform:** LinkedIn
- **Source:** ForumScout, 2026-09-08 (no direct URL captured by the sheet)
- **Posture:** networking (channel/referral contact per the ICP's "pastor/staff as blesser, not
  buyer" framing — no FellowScript mention)

> Fall is such a good on-ramp moment for this. People are already resetting routines, so the ask
> lands easier than mid-year. What's worked best for you in getting someone who's never been part
> of a group to actually show up to the first meeting? That first step seems to be where most
> people get stuck.

---

*Unattended daily marketing pipeline follow-up. All 13 review-queue items from
`2026-09-16.md` were drafted; none were skipped. Every drafted reply above was run through the
`humanizer` skill before finalizing.*

# FellowScript — Social Media Response Style Guide

**Started 2026-09-16.** A living reference for how Jacey's own social-media replies (Reddit
threads, forum comments, etc. surfaced by the daily marketing pipeline's response-draft queue)
are actually written, as opposed to how the pipeline's own auto-drafts sound by default. Append
to this file — don't replace it — as more responses get worked through by hand; the goal is for
this pattern to sharpen with real examples over time, not to freeze on day one.

**What this is not:** not a claim that this is the only voice that works, and not a substitute for
reading the actual thread before posting (see `daily-reports/*-response-drafts.md` for the
pipeline's own captured context, and note that thread content there is sometimes just the
pipeline's summary, not the raw post — verify against the live thread when possible).

---

## The core structure

Every worked example so far follows the same four-beat shape:

1. **Personal credibility, stated as experience, not as a bio.** Open with a concrete detail
   from Jacey's own history with the topic (led a group, ran a plan, hit a specific wall) —
   never a generic "as someone who cares about X."
2. **The mistake or lesson, named plainly.** State what didn't work and why, in one or two
   sentences. This is the part that makes the reply worth reading instead of skimmable ad copy —
   it costs the writer something to admit, which is what makes it read as real.
3. **The actual advice**, grounded and specific enough to stand alone with zero mention of
   FellowScript. If the FellowScript paragraph were deleted, this section still has to be a
   complete, useful answer to what the person asked.
4. **The product mention, as a personal aside, not a feature listing.** See the "Do / Don't" list
   below — this is the part most likely to drift back into sounding like marketing copy on a
   redraft, so it gets the most scrutiny.

Close soft: no hard CTA beyond a plain link, and an explicit "not saying you need this" or
equivalent hedge before it.

## Do / Don't for the product-mention beat

| Do | Don't |
|---|---|
| Frame it as something that happened to you ("that's the specific thing that got me into building X") | List it like a spec sheet ("X has a free feature that does Y") |
| Name the *one* mechanism that solves the *specific* problem just described | Mention multiple features or the app broadly |
| Disclose affiliation plainly ("which I work on" / "I built") — required by most subreddit self-promo rules, not optional | Bury or omit the affiliation |
| Ground the mentioned feature in something that actually exists in the codebase | Invent or exaggerate a capability |
| Use personal, true claims about your own experience ("it's become a staple in my own group") | Use unverifiable traction/usage claims (see `target-audience-profile.md` — there is no usage telemetry; never imply otherwise) |
| Keep the aside to 1-2 sentences | Let the product paragraph outgrow the advice paragraph |

## Worked examples

### R2 — r/TrueChristian-adjacent small-group thread, 2026-09-16

> I've been active in small groups for a few years now — part of several different communities
> built around this — and recently took the step of leading my own.
>
> My biggest mistake early on was thinking a group could really deepen someone's walk with Christ
> meeting just once a week. If you're looking for a curriculum to build around, I'd push hard on
> making it daily instead. The apostles didn't grow close meeting weekly — they lived life
> together, every day.
>
> That said, getting people to actually show up every day is a hard ask on its own. So I built an
> app around exactly that — scheduled daily devotion sessions for the group, and a nudge if things
> go quiet so nobody just fades out. It's become a staple in my own group, and sharing it with
> others hitting the same wall feels like something worth doing.
>
> No pressure either way — if it sounds useful, there's more on my site: fellowscript.com

### R3 — r/Christianity, "Devotional book recommendations?", 2026-09-16 (final, as posted)

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
> problem. If that interests you at all, I think it's worth checking out 🙂
> fellowscript.com

Note on R3's evolution: the first pass named the feature directly ("it has a free shared
devotion-plan feature that keeps everyone on the same day and passage automatically") and read as
a pitch. The fix was deleting the feature-listing language entirely and replacing it with the
personal-aside framing in the "Do" column above — same underlying fact, same disclosure, much
less promotional.

### R1 — r/TrueChristian, "How do you actually remember what you hear on Sunday?", 2026-09-17

> I've run into the same issue in the past, and probably even worse. I could go weeks doing my
> devotions daily, reflecting on passages deeply, and within an hour or two afterwards, would
> forget all about what I read that morning. I believed that this was part of me not being able
> to apply whatever it was I was learning about through scripture, to my daily life in some
> smaller way.
>
> In response to this, I decided to include in my daily devotions, a concrete goal that I would
> have to reach by the end of the day, that way my mind was constantly focused on applying what I
> learned in my devotions for that day.
>
> Having a concrete goal each day was the shift, but sticking with it on my own was still hit or
> miss. Some days the goal just didn't happen and I'd forget by evening anyway, same as before.
> What actually made it stick was doing this inside a group, where the daily prompt and the goal
> were shared instead of just something I had to remember on my own.
>
> That's actually what got me building my app called FellowScript. It runs a daily devotion
> prompt for the group, so the part where you actually apply what you read isn't just on you to
> keep track of by yourself. Not saying you need an app for that part specifically, but if the
> accountability piece is what's been missing for you too, it might be worth a look:
> fellowscript.com

Note on R1's shape: beats 1 and 2 (credibility, the mistake) were Jacey's own first draft,
written before beat 3 (the goal-setting fix) and beat 4 (the group-accountability pivot) were
added to extend the same thought rather than pitch a break in it — the product mention names one
mechanism (shared daily prompt) tied directly to the one problem just described (goal-setting
alone didn't stick), not a feature list. Status as of this entry: drafted, not yet confirmed
posted.

### R6 — r/Bible, "Any tips for studying the Bible on my own?", 2026-09-17

> Studying alone is honestly harder to stick with long-term than I thought at least, not just
> because its hard to plan the material, it's that the accountability part is non-existent.
>
> What helped me most was committing to very small sessions at a time: one small passage,
> sometimes just a few verses, and writing down one question and one observation before moving
> on, instead of reading a few chapters and walking away forgetting everything. Consistency always
> beats longevity for me.
>
> Even with that habit, there were stretches where life got busy and I'd quietly let it slide for
> a week or two, because nobody else was seeing it. What actually got me back on track more than
> once was having a couple people see what I was writing down, not to turn it into a group study,
> just enough that skipping a week felt like something instead of nothing.
>
> That's part of why I ended up building FellowScript, notes tied to the actual verse that you can
> leave private or let a couple people see if you want. Works fine solo too, that part's not
> required. Just flagging it in case the accountability piece is the thing you're missing, same as
> it was for me. fellowscript.com

Note on R6's shape: a new case for the product-mention beat, a poster with no stated interest in
a group at all. This morning's automated draft for this thread left FellowScript out entirely,
per the diagnose-before-you-pitch guidance, since forcing a group product into a solo-study
answer risks the same "pitching too early" failure the task guidance warns against elsewhere.
Jacey asked for a version that mentions it anyway, so the beat 4 language here adds an explicit
"works fine solo too, that part's not required" line that the earlier examples didn't need,
keeping the mention honest (it doesn't imply a solo studier needs the group feature to answer
their actual question) rather than skipping the tension. Status as of this entry: drafted, not
yet confirmed posted.

### R1 — r/Christianity, "Any one know where to get some group Bible studies?", 2026-09-18

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

Note on this R1's shape: beats 1-3 (credibility, the mistake, the standalone advice) are the
pipeline's original 2026-09-18 auto-draft, unchanged. Beat 4 is Jacey's own hand-rewrite of the
product mention — "I recently published an app, FellowScript" stated directly rather than "that's
actually part of what got me into building X," and "I believe this could be right for you" in
place of a hedged "might be worth a look." This is a more direct close than the explicit
"not saying you need this" hedge the Do/Don't table above calls for; keeping it here as-is per
Jacey's own wording rather than smoothing it back toward the established hedge, since this file's
job is to capture how the responses are actually written, not to enforce the pattern against a
real edit.

### Discipleship leadership-readiness thread, 2026-09-22 (no product mention)

> I don't have a great answer imo, but what stood out to me was being jumped to serve after just
> two meetings, then pushed toward leading your own group after three months, especially with no
> personal check-ins on your own walk with God in between. Discipleship is supposed to be a
> genuine relationship where someone is actually paying attention to you: your doubts, your prayer
> life, what you're wrestling with. Thats family. What you're describing sounds more like being
> handed a role because the group needed support and you were willing. Those are two very
> different things.
>
> So, my opinion, no, not in any healthy model of discipleship is this considered normal. Most
> frameworks assume years, not months, and assume the person doing the sending actually knows the
> person being sent, their character, their maturity, their blind spots. A leader who doesn't ask
> how you're doing spiritually isn't really in a position to judge whether you're ready to lead
> spiritually.

Note on this one's shape: no beat 4 at all — this is a pure `networking`/no-mention case, sourced
from a post Jacey shared directly (not the automated ForumScout queue, so no R-number/manifest
entry). The poster is asking a specific personal-discernment question with no stated product-shaped
pain point, and forcing a FellowScript aside in here would be the same "pitching too early" failure
R6's note warns against — this example exists specifically to show that beats 1-4 are a shape to
reach for, not a checklist every reply has to complete.

## Changelog

- **2026-09-16:** File created from R2 and R3, the first two hand-finished responses out of the
  2026-09-16 response-draft queue (`daily-reports/2026-09-16-response-drafts.md`).
- **2026-09-17:** Added R1, the first hand-finished response out of the 2026-09-17 response-draft
  queue (`daily-reports/2026-09-17-response-drafts.md`).
- **2026-09-18:** Added R6, also out of the 2026-09-17 response-draft queue, the first example
  covering a solo-studier thread where the product mention had to stay explicitly optional.
- **2026-09-19:** Added a second R1, out of the 2026-09-18 response-draft queue — Jacey's own
  hand-rewrite of that queue's R1 product-mention beat, more direct than the established hedge.
- **2026-09-22:** Added the discipleship leadership-readiness thread example — a pure no-mention
  case, and the first entry sourced from a post Jacey shared directly rather than the automated
  pipeline queue.

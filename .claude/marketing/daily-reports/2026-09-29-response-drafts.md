# FellowScript Response Drafts, 2026-09-29

DRAFTS ONLY. Nothing has been posted or replied to anywhere. Approval happens in #prefect-victory; the always-on bot posts.

## Resolution options

### 1. Site is effectively one indexable URL (HashRouter SPA); branded searches don't surface fellowscript.com (3rd day)
Likely cause is weak authority plus a single URL, not a proven indexing failure. Step zero for every option: run URL Inspection in Search Console on the homepage and confirm indexed status.

| Option | What it involves | Effort | Owner | Trade-off / risk |
|---|---|---|---|---|
| A. Prerender key routes | Switch HashRouter to BrowserRouter with path routes; prerender static HTML at build time (e.g. vite-plugin-prerender or similar) for /, /features, /group-bible-study, /faq. Update sitemap. | Medium (days) | Engineering | Must keep the authenticated app working under path routes and fix server fallback rules; existing hash links break unless redirected. |
| B. Separate static marketing site | Keep the app as-is; put a small static site (Astro or plain HTML) on fellowscript.com, app on /app or a subdomain. | Medium | Engineering + marketing | Cleanest SEO and fastest to iterate on content; splits deploys, and needs care with auth cookies and desktop wrapper URLs. |
| C. Full SSR migration | Move the web app to Next.js or Remix SSR. | High (weeks) | Engineering | Overkill for a marketing-visibility problem; large regression surface. |
| D. Off-site authority first | Directory listings, GitHub README link, App Store page backlink, guest posts; no code change. | Low | Marketing | Cheap and parallelizable, but does not fix the one-URL structure by itself. |

Recommendation: D immediately, then A or B (B if the app's routing is hard to change).

### 2. Title/meta/structured data gaps
| Option | What it involves | Effort | Owner | Trade-off |
|---|---|---|---|---|
| A. Edit static index.html | New title ("FellowScript: Bible Reading & Group Study App"), meta description with CTA, SoftwareApplication JSON-LD. | Low (under an hour) | Engineering | Works even on the SPA since these live in the served HTML; only one page benefits. |
| B. Per-route head management | react-helmet or similar, combined with prerendering (option 1A). | Low-Medium | Engineering | Only pays off once routes exist. |
| C. Do nothing until routes exist | Defer. | None | n/a | Loses easy wins in the meantime. |

Also trim internal comments from robots.txt (low effort, engineering).

### 3. ForumScout sheet frozen since 2026-09-22 (3rd day flagged)
| Option | What it involves | Effort | Owner | Trade-off |
|---|---|---|---|---|
| A. Check the ForumScout account | Log in, look for a paused campaign, expired billing, or a broken export/sync to the sheet. | Low | Marketing | Fastest; most likely cause. |
| B. Contact ForumScout support | Ask about the sync failure. | Low | Marketing | Slow turnaround. |
| C. Drop reliance on the sheet | Use Zernio Reddit search and manual scans as the primary queue. | Low | Marketing | Already partly happening; loses ForumScout's event/gathering discovery. |
| D. Add a staleness alert | Have the daily pipeline flag when the sheet's newest row is older than N days as an alert, not a repeated line. | Low-Medium | Engineering | Prevents silent decay; does not fix the source. |

### 4. Instagram/LinkedIn listening has no search tool
| Option | What it involves | Effort | Owner | Trade-off |
|---|---|---|---|---|
| A. Accept and note it | Keep reporting as a tool limitation. | None | n/a | Zero coverage on those channels. |
| B. Manual weekly hashtag scan | Human checks a few hashtags/accounts and adds candidates. | Low-Medium | Marketing | Time cost; manual DMs only (see note on DMs). |
| C. Third-party listening tool | Evaluate a paid social-listening product. | Medium + cost | Marketing | Cost is hard to justify without any measured audience data. |

## Drafted replies

10 drafts: 6 explicit-need (R1-R5, R8), 4 networking (R6, R7, R9, R10); all 10 as public comments, no DMs. Subreddit rules could NOT be verified this run (Reddit fetch was blocked), so nothing was skipped for self-promotion rules.

### R1: r/Christianity: 21M looking for a Bible study buddy
- Platform: reddit | Posture: explicit_need | Delivery: comment
- Link: https://www.reddit.com/r/Christianity/comments/1wt2v2r/21m_looking_for_a_bible_study_buddy_or_a_few/
- Notes: Thread text not fetched (Reddit blocked); drafted from the report's summary. Subreddit rules unverified. Verify against live thread.

> Good on you for putting this out there. Small remote groups usually survive the first couple of weeks and then fade around week three or four, because the call ends up being the only thing holding them together. It helps if everyone reads the same chapter beforehand and writes down a question or two, so the call starts with something already on the table. Keeping it to three or four people and picking one book, a gospel or a short epistle, gives you a natural finish line too. Full disclosure, I work on FellowScript, a free Bible app where a group can leave notes on the same passage before you meet. You don't need it for any of this, a shared doc does the same job. Hope you find your people.

### R2: r/Christianity: Where to get group Bible studies?
- Platform: reddit | Posture: explicit_need | Delivery: comment
- Link: https://www.reddit.com/r/Christianity/comments/1wjdqi2/any_one_know_where_to_get_some_group_bible_studies/
- Notes: DUPLICATE RISK: the 2026-09-18 queue already had a draft for this same thread (style guide shows a hand-finished version). Check whether it was already posted before approving. Rules unverified.

> Writing your own material for 20 people every week is a lot, so running dry makes sense. If you want something ready-made, The Gospel Coalition has free studies, and RightNow Media is solid if your church has access. Cutting the handout down to a passage and two or three questions, and letting people mark up the text themselves, often gets more discussion than a thick packet does. I work on FellowScript, a free app where the group reads the same passage and leaves notes right on it, so nothing gets printed. Worth a look only if the prep and printing is what's wearing you down.

### R3: r/Christianity: Suggestions for home group
- Platform: reddit | Posture: explicit_need | Delivery: comment
- Link: https://www.reddit.com/r/Christianity/comments/1vyifqn/suggestions_for_a_great_bible_studyhome_group/
- Notes: Thread is a month old (2026-08-26); may be stale. Drafted from summary only. Rules unverified.

> Congrats on taking this on. Two things tend to help new leaders. A consistent rhythm: same night, same length, same opening question, so people know what they're walking into. And a way for quieter people to contribute before the meeting, like a question they answer in writing ahead of time, since the loudest voice usually fills the room otherwise. I work on FellowScript, which lets a group leave notes on a passage before meeting, though a group chat with a weekly question does the same job.

### R4: r/Christianity: Splitting costs in a Bible study group
- Platform: reddit | Posture: explicit_need | Delivery: comment
- Link: https://www.reddit.com/r/Christianity/comments/1wgon2y/how_to_split_costs_in_a_bible_study_group/
- Notes: No FellowScript mention, per the report's angle. Relationship/watch target only.

> For a group that size I'd keep it simple. The hosts cover the main dish or drinks, and everyone else signs up for one item, so nobody is doing math. If people want to chip in, a small jar by the door works better than requesting payments, and it stays quietly optional. Splitting costs evenly with a spreadsheet tends to make it feel like a transaction.

### R5: r/Christianity: How do people find Christian community?
- Platform: reddit | Posture: explicit_need | Delivery: comment
- Link: https://www.reddit.com/r/Christianity/comments/1wcry7q/how_do_people_find_christian_community/
- Notes: Thread from 09-10; may be stale. Rules unverified.

> Shift work makes a fixed weekly group really hard, so I get why they keep falling apart. What tends to work better is a group that doesn't need everyone in the same room at the same time: same passage for the week, everyone drops a note or question whenever they can, and one live call now and then. I work on FellowScript, which is built around that async setup, though a group chat and a shared passage would get you most of the way. What does your schedule look like? That changes what would work.

### R6: r/Christianity: Bible Study Map
- Platform: reddit | Posture: networking | Delivery: comment
- Link: https://www.reddit.com/r/Christianity/comments/1wkz57j/bible_study_map/
- Notes: No product mention. The post content wasn't visible to this run; confirm "this looks really useful" fits what they actually shared before approving.

> This looks really useful. How are you using it when you prep for your group? I'm curious whether it changes what you bring to the discussion, or mostly helps you get your own head around the passage first.

### R7: r/TrueChristian: Using AI to chat with biblical figures?
- Platform: reddit | Posture: networking | Delivery: comment
- Link: https://www.reddit.com/r/TrueChristian/comments/1wsse24/using_ai_to_chat_with_biblical_figures/
- Notes: Position comment, no link or product name, so no affiliation disclosure is included. If the human wants to reference FellowScript's AI agent, add explicit disclosure. Rules unverified.

> I'm wary of the roleplay version. Putting invented words in the mouth of Paul or David gets you a confident voice that isn't in the text. Where I could see AI being useful is the opposite direction, something that asks you a question and sends you back to the passage rather than answering for the person. Curious whether anyone here has found a way of using it that actually pushed them into scripture more.

### R8: r/Christianity: Bible Study group. What's the point
- Platform: reddit | Posture: explicit_need | Delivery: comment
- Link: https://www.reddit.com/r/Christianity/comments/1w7as0a/bible_study_group_whats_the_point/
- Notes: Empathy only, no pitch (66-book ESV non-fit). Thread from 09-04; may be stale.

> That's a fair question, and a lot of groups don't answer it well. Groups tend to be worth it when they're small enough that everyone talks and the point is the people more than the material. If yours isn't that, it's reasonable to feel like you're just sitting through it. Being Catholic may also mean the format isn't built around how you already read, and that's no failing on your part.

### R9: r/Bible: Read the Bible cover to cover in 5 days
- Platform: reddit | Posture: networking | Delivery: comment
- Link: https://www.reddit.com/r/Bible/comments/1wofb67/i_read_the_bible_cover_to_cover_in_5_days/
- Notes: Low priority: 131 comments so this will be buried; not ICP. Optional, fine to skip.

> Five days is a serious pace. What did you notice reading it that fast that you'd have missed going slower? And did anything stick with you afterward, or was it more of a sweep than a deep read?

### R10: r/Christianity: Dreaming about building a Bible app
- Platform: reddit | Posture: networking | Delivery: comment
- Link: https://www.reddit.com/r/Christianity/comments/1w1d5o9/i_keep_dreaming_about_building_a_bible_app_should/
- Notes: Founder-to-founder, relationship value only; affiliation disclosed without naming the product. Thread from 08-29; may be stale.

> The fact that you keep dreaming about it is worth taking seriously. I work on a Bible app myself, and one thing I'd suggest is talking to people who lead small groups before you write anything, since what they struggle with may not be what you assume. Which part of Bible study would you want the app to fix?


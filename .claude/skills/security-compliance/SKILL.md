---
name: security-compliance
description: Ensures backend infrastructure stays secure and the app stays compliant with the legal/contractual obligations that come with running a public, paid, cross-platform service (payments, cross-border user data, app store rules). Invoke before shipping any change that touches infrastructure, payments, authentication, third-party data sharing, or newly-collected user data.
---

# FellowScript Security & Compliance Standard

FellowScript is a live, public, paid service: real users, real card payments (Stripe +
Apple StoreKit), real personal data, on a single EC2 box, with an iOS app under
Apple's Developer Program Agreement. This skill covers the two things
`write-tests`'s security checklist doesn't: **infrastructure-level hardening** and
**the legal agreements that come from being public and taking money**. Use it
alongside `backend-architecture` (how code is shaped) and `write-tests` (per-change
checklist) — this one is about the server itself and the obligations around it.

---

## When to invoke

- Any change to EC2/nginx/systemd config, Postgres roles, security groups, or how
  secrets are stored or deployed.
- Adding a new third-party integration that receives user data (a new API, SDK, or
  webhook — the pattern OpenRouter/Stripe/Apple/Google/AWS Chime already set).
- Adding a new field or table that collects personal data, payment data, or anything
  from a minor.
- Before any App Store Connect submission or update (export compliance, privacy
  labels).
- Anytime a security incident happens (leaked secret, unauthorized access) — see
  Incident Response below.

Skip it for pure UI/copy changes with no new data collection or infra touch.

---

## Part 1 — Infrastructure security

### Secrets
- `.env` is gitignored and untracked (fixed after the July 2026 live-key incident —
  see git history / `git-filter-repo` rewrite). Never re-add it, never `git add -f`
  around the ignore.
- No secret is ever logged, put in an error response body, or committed in a
  migration/test fixture. Test files use dummy values (`hash_pass: "x"`, dummy AWS
  keys) — keep it that way.
- Any secret that touches a public GitHub push protection alert or is suspected
  exposed gets **rotated immediately**, not just removed from the file — removal
  without rotation leaves the old value valid forever if it was ever cloned/cached.
- Env vars are the acceptable baseline for this project's scale; if this ever
  grows past one operator, move to a real secret manager (AWS Secrets Manager /
  SSM Parameter Store) instead of hand-rotating `.env` over SSH.

### Database
- The app connects as the `fellowscript` role, never `postgres` — confirm every
  new table/DB is created with `OWNER fellowscript` explicitly (a past bug: tables
  created via `sudo -u postgres psql` were left owned by `postgres` and broke app
  permissions).
- Postgres must not be reachable from outside the EC2 security group — port 5432
  should only accept connections from localhost, never `0.0.0.0/0`. Check the AWS
  security group any time infra changes, not just the `pg_hba.conf`.
- All queries stay parameterized (`%s`, never f-string/`.format()`) — enforced by
  `backend-architecture`/`write-tests`, restated here because it's the single
  biggest infra-adjacent risk (SQL injection against a public endpoint).
- Backups (`fellowscript_backup` DB) live on the same unencrypted-at-rest EBS
  volume as the primary DB today. That's an accepted gap for current scale — if
  the backup ever needs to leave this box (S3, off-site), it must be encrypted in
  transit and at rest before it does.

### Network & transport
- HTTPS only, everywhere — no endpoint should be reachable over plain HTTP except
  the port 80 → 443 redirect.
- Session cookies stay `httponly=True, secure=True` (already the pattern in
  `main.py`) — never relax either flag to "make testing easier."
- **CORS is currently `allow_origins=["*"]`** in `main.py`. Flag this on any auth
  or cookie-related change: a wildcard origin alongside credentialed requests is a
  standing gap, not an approved pattern — narrow it to the real frontend
  origins (`https://fellowscript.com`, etc.) the next time this file is touched.
- No rate limiting exists yet on `/login`, `/signup`, or password-reset endpoints.
  Any change to auth routes should at minimum note this gap in the report; adding
  basic throttling (e.g. `slowapi`) is the fix, tracked as a known gap until done.

### Process hygiene
- Production runs under the `fellowscript.service` systemd unit. Always
  `sudo systemctl restart fellowscript` — never manually `pkill` + `nohup`, which
  races systemd's own auto-restart and produces confusing double-start logs.
- Before declaring an infra change done, confirm the service is actually the one
  serving traffic (`systemctl status fellowscript`, then hit a live endpoint) —
  don't infer health from the deploy command's exit code alone.

### Dependency hygiene
- Periodically check for known-vulnerable dependencies: `pip list --outdated` /
  a vulnerability scan on `api/requirements.txt`, `npm audit` on `frontend/`. Not
  automated yet — treat as a manual pass whenever touching a dependency file.

---

## Part 2 — Compliance & agreements for a public, paid service

This is about the legal/contractual side of being live and taking money, not code.
Ground every claim here in what the app *actually* does — check `docs/architecture/data.md`
and the current Privacy Policy before asserting anything to a user or to Apple.

### Payments — PCI DSS
- FellowScript never touches raw card data: Stripe Checkout is a full-redirect
  hosted page, and Apple StoreKit handles its own payment sheet entirely. This
  combination qualifies for **SAQ A**, the lightest PCI DSS self-assessment tier —
  but only as long as two things stay true:
  1. No card-collection UI is ever embedded/iframed on our own domain.
  2. No script we control runs *on* the Stripe Checkout page itself.
  If either changes (e.g. a custom Stripe Elements card field gets added later),
  PCI scope jumps to a much heavier SAQ tier (script inventory + tamper-detection
  requirements under PCI DSS 6.4.3/11.6.1) — flag this loudly before ever adding
  embedded card fields.
- Only opaque references are stored (`stripe_customer_id`, `card_brand`,
  `card_last4`, `apple_original_transaction_id`) — never a raw PAN/CVC. This is
  already the pattern in `backend-architecture`; restated here because it's also
  the thing that keeps PCI scope at SAQ A.

### Cross-border user data — GDPR / CCPA
- GDPR can apply the moment **a single EU user** signs up — it does not depend on
  revenue or company size, only on whether EU residents' data is processed. Since
  FellowScript has no signup gate on location, assume it applies.
- Practical baseline already largely met: a lawful basis (contract — you signed up
  for the service), a Privacy Policy describing what's collected and why, and a
  working account-deletion path that actually removes data (including the backup
  DB, per the July 2026 fix) — that covers the core "right to erasure" and
  "right to access" asks.
- We don't need our own bespoke Data Processing Agreements with Stripe/Apple/
  Google/AWS/OpenRouter — accepting each platform's standard business terms
  already constitutes that agreement on their side. What we owe **our own users**
  is disclosure that these sub-processors exist and what each receives — keep
  that list (Part 5 of the Privacy Policy) in sync with reality every time a new
  third-party integration is added.
- CCPA only triggers at $25M+ annual revenue or 50,000+ California residents'
  data — not a current concern, but re-check this threshold if the user base or
  revenue ever grows materially.
- If a breach ever occurs and EU user data was affected, GDPR's clock is **72
  hours** to notify the relevant supervisory authority — know this before it's
  needed, not during an incident.

### Minors — COPPA
- No age gate exists today. If FellowScript ever markets to or knowingly onboards
  users under 13, COPPA's parental-consent and data-minimization rules apply and
  the current signup flow does not satisfy them. Flag this explicitly rather than
  silently assuming a faith/Bible-study app is adult-only.

### Apple platform obligations
- **Export compliance**: the app only uses HTTPS/TLS (OS-provided encryption),
  which is exempt from export documentation. `ITSAppUsesNonExemptEncryption` should
  be `NO`/`false` in `Info.plist` — revisit only if the app ever adds its own
  proprietary encryption (not TLS) to anything.
- **App Privacy label**: must be re-verified any time a new data field, table, or
  third party is added — Apple treats a stale privacy label as a Guideline 5.1
  violation, not a formality. See the existing data-tracking audit and App Store
  Connect mapping produced earlier for the current baseline.
- **In-App Purchase (3.1.1 / 3.1.3(b))**: since FellowScript sells the same
  subscription via both Stripe (web) and StoreKit (iOS), any change to what a web
  subscription unlocks in the iOS app must keep the two equivalent and keep the
  iOS app free of any web-checkout links/buttons — that's the boundary that keeps
  this compliant as a "multiplatform service" rather than IAP circumvention.

### Incident response (already exercised once — keep this playbook)
1. Take a full backup (`git bundle` / DB dump) before any destructive fix.
2. Rotate the exposed credential immediately — assume it's compromised the moment
   it was ever pushed, cached, or logged, regardless of whether it's since been
   deleted from the file.
3. Scrub history if a secret was committed (`git-filter-repo`), then force-push,
   then confirm no other branch (e.g. `gh-pages`) needs the same treatment before
   touching it.
4. Re-verify the service after any credential rotation — a password change
   doesn't help if the running process still holds the old connection/env.

---

## Checklist — run before calling any infra/compliance-adjacent change done

- [ ] No secret committed, logged, or returned in a response body
- [ ] New tables/DBs owned by `fellowscript`, not `postgres`
- [ ] No new port exposed to `0.0.0.0/0` in the security group
- [ ] Payment flow still fully redirects/hosted — no embedded card fields added
- [ ] Privacy Policy still matches reality if a new field/table/third party was added
- [ ] App Store privacy label / export compliance re-checked if the iOS app changed
- [ ] Service restarted via `systemctl`, health-checked against live traffic, not
      assumed from a deploy script's exit code

---

## Execution order within a task

1. Identify whether the change is infra (Part 1), compliance-facing (Part 2), or
   both.
2. Make the change.
3. Walk the relevant checklist(s) above before reporting done.
4. If a gap is found that's out of scope to fix right now (e.g. CORS wildcard,
   missing rate limiting), say so explicitly in the report rather than silently
   letting it slide — these are tracked gaps, not invisible ones.

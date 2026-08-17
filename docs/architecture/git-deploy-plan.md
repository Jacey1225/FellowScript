# Git-Based Deploy Plan (Replacing rsync)

**Status: planning only.** Nothing in this document has been built, provisioned, or
deployed — no SSH deploy key or PAT has been generated, no directory on the live
server has been touched, no `.git` checkout exists anywhere on the EC2 host, and no
command from the sequences below has been run against production. This is the
reference to work from when that build actually happens, following the same
planning-first pattern as [Docker Containerization Plan](docker-plan.md).

Companion reading: [Docker Containerization Plan](docker-plan.md) (Phase 1 of that
plan — containerizing the backend — is already built and live; this document is the
next step, replacing the manual `rsync` deploy of that container's source with a
git checkout), [System Overview](overview.md) (current deployment topology).

---

## Baseline: what's actually running today

| Component | Reality |
|---|---|
| Backend deploy | Containerized per `docker-plan.md` Phase 1, already deployed live. Deploy is entirely manual: local build → `rsync` individual changed files into `~/fellowscript-docker/` → `docker compose build` → `docker compose up -d`. **No git checkout exists on the server** — the directory is a flat tree of rsync'd files, not a clone. |
| Legacy backend deploy path | `~/fellowscript/` — the original pre-Docker, systemd-managed deploy location. Still present and still holds a live `.env` and the current APNs key, because `docker-plan.md`'s own Phase 1 rollback plan keeps `fellowscript.service` installed and stopped through a burn-in window rather than retiring it immediately. |
| Frontend deploy | Static Vite/React build, `rsync`'d to `/var/www/html`, served by `nginx`. Unaffected by anything in this document — see Decision 5 below. |
| Repo | Private: `https://github.com/Jacey1225/FellowScript.git` (confirmed via local `git remote -v`). |
| Live untracked secrets in `~/fellowscript-docker/` | `.env` (`OPENROUTER_API_KEY`, `DB_PASSWORD`, `STRIPE_*`, `SES_*`, `APPLE_*`, `CLIENT_ID`, `SUPPORT_EMAIL` — full list in `docker-plan.md`'s Baseline table) and `AuthKey_22G3F2KMHS.p8`, the APNs key rotated earlier tonight. Neither file is, or has ever been, tracked by this repo's current `.gitignore`-covered set. |
| Unresolved incident | `AuthKey_4SRZ3YTAAN.p8` (the prior APNs key) was found tracked in this repo's git history, rotated tonight, and untracked going forward (`.gitignore` now has `*.p8`/`*.pem`). **The actual history scrub of the old commit(s) that tracked it has not happened yet.** This matters directly to Decision 3 below. |

---

## Decision 1 — Auth mechanism: SSH deploy key, not a PAT

**Decision: provision a repo-scoped, read-only SSH deploy key for the server, not a fine-grained personal access token.**

| | Deploy key (chosen) | Fine-grained PAT |
|---|---|---|
| Scope | Bound to exactly one repository (`FellowScript`) at the GitHub-platform level — cannot reach any other repo even if the owning account gains access to more later | Scoped to selected repos at creation time, but tied to a user account; scope can silently drift if the account's own permissions change |
| Read-only enforcement | A first-class GitHub setting on the key itself (write access is opt-in, off by default) — enforced server-side by GitHub, not dependent on the credential holder configuring permissions correctly | Requires deliberately setting the "Contents" permission to Read-only and not over-granting others; a misconfigured PAT can carry far more capability than a deploy needs |
| Expiration / rotation burden | No mandatory expiration — set once, works until revoked | GitHub fine-grained PATs require an expiration date (max 1 year); this server-side credential would need a recurring manual rotation cadence to avoid a surprise deploy outage when it lapses |
| Storage shape | A standard SSH keypair — private half lives in a file with `600` permissions, referenced via `~/.ssh/config`, used through the existing `git`+SSH plumbing already on the host | An opaque token string, typically stored as an env var or in a credentials file — one more secret shape to manage alongside the `.env`/`*.p8` conventions Decision 3 of `docker-plan.md` already established |
| Precedent in this project | Matches the operational pattern already used for server access itself (`fellowscript-ec2-key.pem`, a dedicated SSH keypair, gitignored) | No existing precedent in this project |

**Reasoning:** a deploy key is purpose-built for exactly this scenario — one server, one repo, read-only, non-interactive `git pull`. It carries the least privilege of the two options by construction (repo-scoped, read-only, no user-account link), and it avoids introducing a rotation deadline into a production deploy path for no corresponding security benefit — a PAT's mandatory expiration protects against a token walking off with a departing employee's broader account access, which isn't the threat model here (this is a single-purpose machine credential, not a human's token).

**Provisioning (described, not executed):** generate the keypair locally (`ssh-keygen -t ed25519 -f fellowscript-deploy -N ""`, no passphrase since it must be used non-interactively by an unattended `git pull`), add the **public** half as a GitHub deploy key on the `FellowScript` repo with write access left unchecked, and `scp` the **private** half to the server into a location outside any git working tree — e.g. `~/.ssh/fellowscript-deploy`, mode `600`, owned by the deploy user. Reference it via a dedicated `~/.ssh/config` `Host` alias (e.g. `Host github-fellowscript` → `HostName github.com`, `User git`, `IdentityFile ~/.ssh/fellowscript-deploy`) so the checkout's `origin` remote uses `git@github-fellowscript:Jacey1225/FellowScript.git` rather than embedding the key path in the remote URL. The private key is never echoed to shell history, never written into `.env`, and never enters the repo's own working tree — same storage discipline `docker-plan.md` Decision 3 applies to the APNs key and AWS credential files (secret material supplied outside the build/checkout context, never `COPY`'d or `git add`'d).

---

## Decision 2 — Checkout topology: fresh clone, not in-place conversion

**Decision: clone the repo into a new directory (`~/fellowscript-git/`), do not `git init` inside the existing `~/fellowscript-docker/`.**

**Why not convert `~/fellowscript-docker/` in place:** that directory already contains the live `.env` and `AuthKey_22G3F2KMHS.p8` on disk *before* any `.gitignore` would be in effect for it. Running `git init` there and then adding files is a real window for a mistake — an early `git add .` (before anyone double-checks the ignore rules are actually being honored in that specific directory) could stage and commit a live secret, which is exactly the class of incident this project just spent tonight rotating a key and remediating a `.gitignore` for. There is no operational reason to accept that risk when a fresh clone avoids it entirely.

**Why a fresh clone avoids it:** `git clone` populates the new directory (`~/fellowscript-git/`) starting from the repo's own tracked commit history — which already includes the current `.gitignore` with `*.p8`/`*.pem`/`.env` entries. The secrets never exist in that directory until they are deliberately copied in afterward as plain files, at which point `git status` will already show them as untracked (ignored), because the ignore rule was in effect before the files ever arrived.

**Sequence (described, not executed):**
1. `git clone git@github-fellowscript:Jacey1225/FellowScript.git ~/fellowscript-git`
2. `cp ~/fellowscript-docker/.env ~/fellowscript-git/.env` and the equivalent copy for `AuthKey_22G3F2KMHS.p8` (plain `cp`/local copy, not `git add`, not `git mv`).
3. Confirm `git -C ~/fellowscript-git status` reports a clean tree (the copied secrets should not appear as untracked-and-stageable-by-accident targets that anyone later runs a bare `git add .` against — they should show as ignored, not merely untracked, which is the actual guarantee `.gitignore` provides here).
4. Point `docker compose` at `~/fellowscript-git/` as its working directory and validate the container starts correctly against the new checkout before removing anything.
5. Once validated, retire `~/fellowscript-docker/` (rename rather than delete, e.g. `~/fellowscript-docker.bak/`, kept through a burn-in window) — mirroring the same "don't delete the old thing immediately" caution `docker-plan.md`'s own Phase 1 rollback plan uses for `fellowscript.service`.

**What this decision explicitly does not touch:** `~/fellowscript/`, the legacy pre-Docker systemd deploy path. It is already slated for retirement once `docker-plan.md`'s Phase 1 burn-in window completes, and it is not part of the active deploy path this plan is optimizing — converting it to a git checkout now would be work spent on a directory this project already intends to delete. If `fellowscript.service` is ever un-retired as a longer-term rollback path, that would be a reason to revisit this, not a default.

---

## Decision 3 — `.gitignore` behavior under `git clone`/`git pull`, and the history-scrub blocker

**Explicit statement, not an assumption:** `git clone` and `git pull` only ever fetch content that is part of some commit reachable in the repository's history. `.gitignore` does not participate in that direction at all — it has no effect on what a clone or pull *brings down*. What it prevents is a *future local commit* from accidentally picking up a matching file via a bare `git add .` What actually keeps a file out of a clone is simpler and stricter: **it was never committed in the first place.** For the current `.env` and `AuthKey_22G3F2KMHS.p8`, that holds — neither has ever been tracked by this repo — so a `git clone` today would never fetch them, full stop, regardless of `.gitignore` content.

**Where this breaks down — the actual blocker:** `AuthKey_4SRZ3YTAAN.p8` (the prior, now-rotated APNs key) *was* tracked in a past commit before tonight's remediation untracked it going forward. `.gitignore` only stops it from being re-added in a *future* commit — it does nothing to remove it from commits that already exist. A default `git clone` fetches the full reachable history by default, which means **the exposed old key would be pulled down onto the production server, inside `.git`'s object store, the moment a clone is run** — even though the file itself wouldn't appear in the working tree today. That is a direct regression of the secrets-hygiene work done tonight: it moves a known-leaked credential from "exposed on GitHub" to "exposed on GitHub *and* sitting in a `.git` directory on the box being hardened."

**Decision: the pending git-history scrub of `AuthKey_4SRZ3YTAAN.p8` is a hard blocker to executing this plan.** This plan's checkout topology (Decision 2) depends on a `git clone`, and a clone performed before the scrub would re-introduce exactly the exposure this project is in the middle of remediating. This plan does not perform that scrub (per its own out-of-bounds scope) — it must be completed, as its own separate approved task (e.g. `git filter-repo` or BFG Repo-Cleaner against the offending commit(s), followed by a force-push and a fresh clone-and-verify locally), **before** any step of this plan's clone/checkout sequence is executed on the server. A shallow clone (`--depth=1` from a point after the file's removal) would technically avoid pulling the old history, but is a workaround around the underlying problem, not a fix, and is not recommended as a substitute for the scrub.

---

## Decision 4 — Backend pull+rebuild command sequence

**Sequence (described, not executed), replacing tonight's manual `rsync` + two-step `docker compose build`/`up -d`:**

```
cd ~/fellowscript-git
git pull origin main
docker compose up -d --build
```

(Confirm `main` is the deploy branch in use at execution time — this plan assumes it based on this being the repo's default branch, not confirmed against a server-side deploy convention that doesn't exist yet.)

**Relationship to `~/deploy_backups/<timestamp>/`:** that mechanism exists today to protect against the file-by-file `rsync` process silently missing or corrupting files — a real, documented failure mode in `docker-plan.md`'s Baseline table. A git checkout removes most of that specific risk for *code*: every prior state is already a retrievable commit, so rollback becomes `git -C ~/fellowscript-git reset --hard <previous-sha> && docker compose up -d --build` rather than restoring a directory snapshot. Recommend keeping the `~/deploy_backups/<timestamp>/` mechanism running through the same burn-in window this plan uses elsewhere (Decision 2), as a cheap secondary safety net covering anything outside git's reach (build artifacts, the live `.env`/`*.p8` files themselves, container state) — but expect it to matter progressively less for *code* rollback specifically, since `git log`/`git reset` is faster and less error-prone than reconstructing from a snapshot directory.

---

## Decision 5 — Frontend: explicitly out of scope for this plan

**Decision: this plan covers the backend only. The frontend's `rsync`-to-`/var/www/html` static-build deploy is not converted here.** This matches `docker-plan.md`'s own explicit frontend-out-of-scope precedent, and the reasoning holds again here: the frontend deploy artifact is a *build output* (`npm run build` → `dist/`), not source that gets run in place. A `git pull` on the server would still leave the server needing a Node/npm toolchain and a build step before anything could be served — a materially different operational shape than "pull and restart a container," and not a drop-in replacement for `rsync`ing a pre-built `dist/`. If the frontend is later brought into a git-based flow, it would look like `git pull && npm ci && npm run build` with `nginx` pointed at the resulting `dist/` in place of `/var/www/html`, but that is an explicit future decision for its own plan, not bundled into this one.

---

## Relationship to Phase 4 CI/CD (`docker-plan.md`)

This plan is a **stepping stone toward Phase 4, not a competing approach**, but the two differ in mechanism and it's worth stating precisely what carries forward:

- **Reused by Phase 4:** the deploy key (Decision 1) and the server-side checkout it authenticates (Decision 2) don't go away once CI/CD ships — `docker-compose.yml` and any deploy-time config still need to live somewhere on the server, and pulling that via the same git checkout is cleaner than re-introducing an `rsync` step just for config files. The auth mechanism and checkout topology decided here are the foundation Phase 4 builds on, not throwaway scaffolding.
- **Superseded by Phase 4:** the `--build` half of Decision 4's command sequence. This plan has the server build its own image from source (`git pull && docker compose up -d --build`); Phase 4 has GitHub Actions build the image and push a SHA-tagged image to a registry, and the server's job becomes `docker pull <sha-tag> && docker compose up -d` — no local build, no build-toolchain drift between deploys. Once Phase 4 ships, the server-side `git pull` in this plan's sequence stops being "pull source to rebuild" and becomes "pull the compose/config files that reference the already-built image."
- **No contradiction:** this plan does not lock in an approach Phase 4 would need to undo. It only replaces the file-transport mechanism (rsync → git) for a workflow that Phase 4 later replaces the *build* mechanism for (server-side build → CI-built image). The two are sequential improvements to the same pipeline, not alternatives.

---

## Prerequisites checklist before this plan is safe to execute

1. **Hard blocker:** `AuthKey_4SRZ3YTAAN.p8` git-history scrub completed and force-pushed (Decision 3) — not performed by this plan, must land first as its own task.
2. Deploy key generated and added to GitHub as a read-only, repo-scoped key (Decision 1) — not performed by this plan.
3. `~/fellowscript-git/` cloned, live secrets copied in and confirmed ignored, `docker compose` cut over and validated, `~/fellowscript-docker/` retired only after burn-in (Decision 2).
4. `~/fellowscript/` (legacy systemd path) left untouched, governed entirely by `docker-plan.md`'s own existing rollback/burn-in plan, not this document.

Nothing above is executed as part of this document — this is the order to execute in once the plan is approved and the history-scrub blocker (item 1) is independently resolved.

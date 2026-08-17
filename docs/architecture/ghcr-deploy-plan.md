# GHCR Server-Side Deploy Plan (Phase 4, server half)

**Status: planning only.** Nothing in this document has been built, provisioned,
or deployed — `docker-compose.yml` has not been edited, no GHCR PAT has been
generated, no `docker login` has been run on the EC2 host, and no command from
the sequences below has been run against production. This is the reference to
work from when that build actually happens, following the same planning-first
pattern as [Docker Containerization Plan](docker-plan.md) and
[Git-Based Deploy Plan](git-deploy-plan.md).

Companion reading: [Docker Containerization Plan](docker-plan.md) (this
document is the missing detail section for that plan's Phase 4 deploy-step
bullet — see "Fit into Phase 4" below), [Git-Based Deploy Plan](git-deploy-plan.md)
(a related but distinct credential/mechanism — see Decision 4 for why the two
are not to be conflated), [System Overview](overview.md).

---

## Baseline: what's actually running today

| Component | Reality |
|---|---|
| Build/tag/push | `.github/workflows/build-push.yml` (committed `93896c4e`, already built and live) pushes `ghcr.io/jacey1225/fellowscript-api:latest` and `:<git-sha>` on every push to `main`, authenticated via the workflow's own `GITHUB_TOKEN` — no PAT provisioned for that half of the pipeline. **Out of scope to revisit here.** |
| GHCR network shape | Confirmed: GHCR pulls are entirely outbound/server-initiated. No inbound connection, no port to open. The server needs only outbound HTTPS (already present), the `docker` CLI (already installed), and — only if the package stays private — GHCR credentials. |
| `docker-compose.yml` today | Hardcodes `image: fellowscript-api:latest` alongside `build: { context: ., dockerfile: Dockerfile }`. `docker compose up -d` on this file builds locally by default (or reuses a locally-cached `fellowscript-api:latest` image) rather than pulling a pre-built tag from GHCR — this is the specific behavior this plan has to change for "pull, don't build" to be real in practice, not just aspirational. |
| Image contents | Per the Dockerfile's runtime stage, `COPY api/ .` copies the full FastAPI application source into the image (Python is not compiled) — this matters directly for the GHCR visibility decision below: pulling this image is equivalent to reading the source tree, not just running a binary. |
| Rollback model already shown to the user | `docker pull <previous-sha-tag> && docker compose up -d` — restated, not re-derived, below in Decision 5. |
| Related, distinct plan | [Git-Based Deploy Plan](git-deploy-plan.md) already planned an SSH deploy key for a *different* purpose — pulling **source** via `git pull` for the pre-Phase-4 build-on-server flow. This plan is about pulling a **built image** from GHCR. Different registry, different auth surface. See Decision 4. |

---

## Decision 1 — `docker-compose.yml`: parameterize the image tag, keep `build:`

**Decision: do not remove or reorder the `build:` block in `docker-compose.yml`. Add an `IMAGE_TAG` env-var override to the `image:` field, and make the deploy sequence itself explicit about pulling and skipping the build — the file's *default* behavior (a bare `docker compose up -d` with no env override) stays local-build for developers, but the *deploy* sequence never exercises that path.**

| | Edit `docker-compose.yml` to drop `build:` | Parameterize `image:`, keep `build:` (chosen) |
|---|---|---|
| Local developer workflow | Breaks — a developer without GHCR pull access (or who wants to iterate on an uncommitted local change) can no longer `docker compose up --build` | Unaffected — default `image: fellowscript-api:latest` and the existing `build:` block both still work exactly as today |
| Phase 1/2 burn-in precedent | Diverges from it — `docker-plan.md` Phase 1/2 relied on building directly on the host before CI/CD existed; removing `build:` entirely erases that capability even as a fallback | Preserved as a fallback, without being the deploy-time default |
| Risk of "forgot the flag" deploy mistake | Lower by construction (nothing to forget) | Mitigated by making the deploy sequence (Decision 5) explicit and scripted, not by operator memory each time |
| Blast radius of this edit | A committed-file behavior change that also affects anyone building locally | A single new env var with a safe default (`fellowscript-api:latest`, i.e. unchanged behavior when unset) |

**Reasoning:** the open question here was whether to make "pull, don't build" foolproof by editing the file, or to keep the file flexible and make the *deploy sequence* foolproof instead. Removing `build:` is more foolproof for the one deploy path but actively regresses local development and the Phase 1/2 on-host-build capability `docker-plan.md` already relied on — there's no concrete driver requiring that capability to go away, and this project's own precedent (Decision 1 of `docker-plan.md`, Decision 2 of `git-deploy-plan.md`) favors the option that doesn't remove an existing, still-used capability when a narrower fix is available. The narrower fix here is real: an env-var-driven image tag plus an explicit, scripted deploy sequence (Decision 5) makes "pull, don't build" the actual behavior of every deploy run, without touching what a developer's bare `docker compose up` does.

**The one small edit this implies, described (not made) here:**

```yaml
services:
  api:
    build:
      context: .
      dockerfile: Dockerfile
    image: ${IMAGE_TAG:-fellowscript-api:latest}   # was a bare literal
    container_name: fellowscript-api
    ...
```

With `IMAGE_TAG` unset (developer default), behavior is byte-for-byte identical to today. With `IMAGE_TAG=ghcr.io/jacey1225/fellowscript-api:<sha>` exported before `docker compose up -d` (Decision 5's deploy sequence), compose starts the already-pulled GHCR image and never invokes `build:` — `docker compose up -d` only builds when the named image isn't already present locally or `--build` is passed explicitly, neither of which the deploy sequence does.

---

## Decision 2 — New-image-detection trigger: manual for this phase, extend `build-push.yml` later

**Decision: this phase stays manual — an operator SSHes in and runs the pull/restart sequence (Decision 5) by hand once a new push to `main` has built and pushed. No cron poller and no webhook receiver are introduced now.**

**Future automation path, named explicitly (not left open-ended): extend the existing `.github/workflows/build-push.yml` with a final `deploy` job that SSHes into the EC2 host at the end of the same workflow run, immediately after `build-and-push` succeeds — not a new, separate polling or webhook mechanism running on the server.**

**Reasoning:**

- **GitHub Actions already knows the exact moment a new image is ready** — it just finished building and pushing it. A deploy job appended to the same workflow run has that information for free. A cron poller on the server would have to rediscover it (poll GHCR's API, diff tags, guess an interval), and a webhook receiver would mean standing up and maintaining a new inbound HTTP listener on the server — a new attack surface for a server that, per the Baseline table, currently has no inbound GHCR-related surface at all. Extending the workflow that already has the answer is simpler than building or maintaining either alternative.
- **Full automation's real cost is a new, more powerful credential, not engineering effort.** An Actions-triggered SSH deploy step requires an SSH key stored as a GitHub Actions secret with permission to run arbitrary `docker` commands on production — materially more powerful than anything provisioned so far in this project's Docker/CI work tonight (the `build-push.yml` job only ever used the built-in, repo-scoped `GITHUB_TOKEN`; nothing in tonight's session provisioned a credential capable of reaching production directly from CI).
- **This project had a direct, same-session lesson in credential leakage tonight** (the `AuthKey_*.p8` history exposure documented in `git-deploy-plan.md`'s Baseline and Decision 3). Given that, staying manual until the team is comfortable with the pull+restart mechanism itself — and only then automating, as a deliberate, separately-scoped follow-up task, not bundled into this one — is the recommended sequencing. This mirrors the same staged, conservative approach `docker-plan.md`'s Phase 1 and `git-deploy-plan.md` both already use elsewhere in this project (burn-in windows, keeping a rollback path installed, not retiring the previous mechanism immediately).
- **Manual for this phase introduces zero new credentials.** Decision 5's pull/restart sequence runs over the operator's existing SSH access to the host — the same access already used for every other manual deploy step today. Nothing new is provisioned to reach this phase's acceptance bar.

**What "manual" concretely means for this phase:** an operator (or, if desired later without changing the trigger model, a simple script an operator runs by hand — not a cron job) runs Decision 5's command sequence over SSH after confirming a new push to `main` has finished in the Actions tab or via a Slack/GitHub notification. No polling loop, no listener process, and no new inbound surface on the server.

**Explicit non-decision:** this document does not build the future `deploy` job into `build-push.yml` — that workflow is out of scope for this plan (already built and live, not to be revisited here). This section only names the direction so it doesn't have to be re-derived later, matching `docker-plan.md`'s own Phase 4 bullet, which named CI/CD as a future direction without building it at the time.

---

## Decision 3 — Pull+run sequence

**Sequence (described, not executed):**

```
ssh <deploy-user>@<ec2-host>
cd ~/fellowscript-docker   # or ~/fellowscript-git, once git-deploy-plan.md ships
export IMAGE_TAG=ghcr.io/jacey1225/fellowscript-api:<git-sha>
docker pull "$IMAGE_TAG"
docker compose up -d
```

- `<git-sha>` is the commit SHA `build-push.yml` tagged the image with — read off the Actions run that just completed, or `git rev-parse HEAD` on the operator's own up-to-date local checkout of `main` if the two are known to match.
- `docker compose up -d` here relies on Decision 1's `IMAGE_TAG`-parameterized `image:` field: with `IMAGE_TAG` exported and the image already pulled, compose starts the pulled image directly, no build invoked.
- `docker pull` before `up -d` (rather than relying on compose to pull) is deliberate: it makes the "did the pull actually succeed" step visible and separately checkable (non-zero exit, clear error) before touching the running container, rather than folding pull-failure handling into `up -d`'s own output.
- This sequence supersedes the current `rsync` + local-build deploy path for the backend image specifically — it does not change the frontend's `rsync`-to-`/var/www/html` deploy (`git-deploy-plan.md` Decision 5's frontend-out-of-scope precedent holds here too), and does not change how `.env`/the APNs key/AWS credential mounts are supplied (`docker-plan.md` Decision 3's volumes/env_file wiring in `docker-compose.yml` is untouched by this plan).

---

## Decision 4 — GHCR auth is a distinct credential surface from the SSH deploy key

**Explicit statement, not an assumption:** `git-deploy-plan.md`'s SSH deploy key authenticates `git@github.com` for a `git pull` of **source code**. The mechanism this document covers authenticates `ghcr.io` for a `docker pull` of a **pre-built image**. These are two different registries (`github.com` vs `ghcr.io`), two different protocols (SSH vs HTTPS/Docker registry auth), and — if the private-package branch below is chosen — two different credential shapes (an SSH keypair vs a PAT). They must not be merged into a single credential or a single provisioning step, even though both are colloquially "a deploy key for GitHub."

If both plans are eventually executed, the server ends up holding two independent, narrowly-scoped credentials, each usable for exactly one thing: the SSH deploy key can `git pull` source and nothing else (per `git-deploy-plan.md` Decision 1's read-only, repo-scoped design); a GHCR PAT, if provisioned, can `docker pull`/`docker login` against this one package and nothing else (scope discussed in Decision 5 below). Neither credential's compromise extends to the other's capability.

---

## Decision 5 — GHCR auth: finalized by security gate

**Security gate finalization of backend's recommendation (closed for this pass):**

**Keep the GHCR package private. Provision a fine-grained personal access token (not a classic PAT), scoped to only the `FellowScript` repository with the "Packages: Read-only" permission, for the server.**

The reasoning:

- **This is not a compiled-binary image.** Per the Baseline table, the Dockerfile's runtime stage does `COPY api/ .` — the full FastAPI application source ships inside every image layer, unobfuscated. Setting the GHCR package public would make `docker pull ghcr.io/jacey1225/fellowscript-api:<any-tag>` followed by `docker save`/inspecting the image filesystem equivalent to handing out the entire backend source tree to anyone with the package's URL — a materially different exposure than the "no new credential needed" framing that applies to genuinely compiled artifacts. The underlying GitHub repository is already private (`git-deploy-plan.md` Baseline); a public GHCR package would quietly undo that. **Confirmed: private.**
- **Fine-grained PAT, not classic — this is a correction to backend's draft, not just a confirmation.** Backend's draft described a PAT scoped to `read:packages` as able to "reach... nothing else" but that claim is only true for a fine-grained token. A **classic** PAT with the `read:packages` scope is not scoped to a single package — GitHub grants it read access to every package the authenticating account can see (all of that user's public and private packages), which would make the credential materially broader than "this one package and nothing else," undercutting the least-privilege bar `docker-plan.md` Decision 3 and `git-deploy-plan.md` Decision 1 both hold this project to. A **fine-grained** PAT can be scoped at creation to a single named repository (`FellowScript`) with the repository-level "Packages" permission set to read-only — that is the only token shape for which Decision 4's "can `docker pull`/`docker login` against this one package and nothing else" claim is actually accurate. **Finalized: fine-grained PAT, repository-scoped to `FellowScript`, Packages permission set to Read-only, no other repository or account-wide permission granted.**
- **Storage: confirmed as described.** `docker login ghcr.io -u <github-username> --password-stdin` once on the host, writing the token into Docker's own credential store (`~/.docker/config.json` for the deploy user), rather than exporting it as a shell-history-visible env var each deploy — this follows the same "never in shell history, never echoed" discipline `docker-plan.md` Decision 3 and `git-deploy-plan.md`'s Decision 1 provisioning note both already apply to other secrets in this project. `docker pull`/`docker compose up -d` afterward use the stored credential transparently, with no token appearing in the pull/run sequence in Decision 3 above. **Flagged explicitly, not silently accepted:** absent a credential-helper plugin (e.g. `docker-credential-pass`, `docker-credential-secretservice`), `docker login`'s default backend stores the token base64-encoded, not encrypted, inside `config.json` — confidentiality rests entirely on the file's `0600` permission and the deploy user account, the same posture this project already accepts for `~/.ssh/fellowscript-deploy` (mode `600`, no passphrase). That's consistent with this project's existing risk acceptance for machine credentials at its current scale, not a new gap — but it should be a known property, not an assumed one, matching this project's practice of stating accepted gaps explicitly (see the CORS-wildcard and no-rate-limiting gaps already tracked in this project's security conventions) rather than leaving them implicit.
- **Rotation cadence: finalized.** Fine-grained PATs carry a mandatory expiration (GitHub's maximum is 1 year) — set it to the maximum (1 year) at creation, and add a tracked reminder (calendar entry or equivalent operator process, not new tooling) ~2 weeks before expiry to rotate before it lapses, avoiding the "surprise deploy outage" `git-deploy-plan.md` Decision 1 flagged as the cost of a PAT's mandatory expiration. This does not contradict `git-deploy-plan.md` Decision 1's choice of a non-expiring SSH key for the source-pull credential: that decision's premise was that the SSH deploy key was already at the narrowest available scope (repo-scoped, read-only, no narrower option existed), so an expiration deadline would have added rotation burden with no corresponding least-privilege gain. Here, the situation is different — choosing the fine-grained token *is* what delivers the single-package scoping in the first place (a classic token cannot achieve that scope at any expiration setting), so the mandatory expiration that comes bundled with it is the acceptable cost of getting real least-privilege, not an independent cost paid for nothing.

**Status: closed for this pass.** Architecture routed the package-visibility call and the PAT scope/storage/rotation details to the security gate (checkpoint: this step) — this section is that finalized call, not a placeholder for a later pass. Provisioning itself (generating the token, running `docker login` on the host) is still not performed by this document, per this plan's planning-only scope.

---

## Decision 6 — Rollback

**Restated, not re-derived** (already shown to the user in this session's pipeline diagram, and already the rollback shape named in `docker-plan.md`'s Phase 4 sketch):

```
export IMAGE_TAG=ghcr.io/jacey1225/fellowscript-api:<previous-git-sha>
docker pull "$IMAGE_TAG"
docker compose up -d
```

Because every pushed image is tagged with its git SHA (`build-push.yml`), rollback is just Decision 3's own sequence pointed at the previous known-good SHA — no `~/deploy_backups/<timestamp>/` snapshot reconstruction needed for the backend image specifically, matching the payoff `docker-plan.md`'s Phase 4 sketch already promised ("nothing to manually reconstruct... since every deployed state is a tagged, retrievable image").

---

## Fit into Phase 4

`docker-plan.md`'s Phase 4 section sketches the target shape in three bullets: a workflow that builds/tags/pushes (built, live, out of scope here), "a deploy step that SSHes into the EC2 host... and runs `docker pull <sha-tag> && docker compose up -d`" (this document's Decisions 1, 3, and the compose edit resolve exactly what that bullet left implicit), and a rollback bullet (Decision 6, restated above). This document does not compete with or replace that sketch — it is the detail section for the deploy-step and rollback bullets, plus the trigger-mechanism call (Decision 2) and credential surface (Decisions 4–5) that sketch didn't address at all.

---

## Migration path

Nothing below is executed as part of this document.

**Phase 4a — this document's manual trigger (recommended starting point).**
1. Confirm the security gate's finalized call on Decision 5 (package visibility, PAT if applicable).
2. Apply Decision 1's `docker-compose.yml` edit (`image: ${IMAGE_TAG:-fellowscript-api:latest}`).
3. If the private-package branch is chosen, run `docker login ghcr.io` once on the host per Decision 5's storage note.
4. Operators run Decision 3's sequence manually after each `build-push.yml` run they want deployed, until the team is comfortable with the mechanism.

**Phase 4b — deferred, named but not built here.** Extend `build-push.yml` with a final `deploy` job (Decision 2) that runs Decision 3's sequence over SSH automatically at the end of a successful build-and-push run. Requires provisioning the SSH-as-a-GitHub-Actions-secret credential Decision 2 flags as the actual cost of automating — a deliberate, separately-scoped follow-up task, not bundled into this plan.

---

## Prerequisites checklist before this plan is safe to execute

1. Security gate finalizes Decision 5 (package visibility; PAT scope/storage/rotation if private) — not performed by this document.
2. `docker-compose.yml`'s `image:` field parameterized per Decision 1 — not performed by this document.
3. If private: `docker login ghcr.io` run once on the deploy host per Decision 5 — not performed by this document.
4. Confirm which directory the deploy sequence runs from (`~/fellowscript-docker/` today, or `~/fellowscript-git/` once `git-deploy-plan.md` ships) at execution time — this document does not depend on which, since Decision 3's sequence only needs `docker-compose.yml` to be present in the working directory, but the exact path should be confirmed against whichever of those two plans has landed by then.

Nothing above is executed as part of this document — this is the order to execute in once the security gate's Decision 5 review lands.

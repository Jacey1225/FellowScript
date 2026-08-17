# Docker Containerization Plan

**Status: planning only.** Nothing in this document has been built or deployed —
no `Dockerfile`, `docker-compose.yml`, `.dockerignore`, or CI config exists yet, and
no change has been made to the live EC2 instance, `nginx`, or either systemd unit.
This is the reference to work from when that build actually happens, so decisions
that were made once (Postgres in-container vs. on-host, secrets handling, rollback)
don't need to be re-derived under deploy pressure later.

Companion reading: [System Overview](overview.md) (current deployment topology),
[Backend](backend.md) (`api/` layer structure this Dockerfile has to build).

---

## Baseline: what's actually running today

Confirmed directly against the live server and this repo, not assumed:

| Component | Reality |
|---|---|
| Host | Single AWS EC2 instance, Ubuntu, `t3.medium` (2 vCPU / 3.7GB RAM — recently resized up from a `t3.micro`-class instance that was swapping under normal load) |
| DNS/edge | `fellowscript.com`, behind Cloudflare, `44.216.136.112` |
| Backend | FastAPI app in `api/`, run via `venv`-installed `uvicorn`, managed by the `fellowscript.service` systemd unit — **not containerized today** |
| Database | PostgreSQL running directly on the host (not RDS), managed by its own `postgresql.service` systemd unit. Two databases on the same server: `fellowscript` (primary) and `fellowscript_backup` (nightly per-user copy — see `backend/backup/manager.py`) |
| DB connection | `api/db.py`'s `_connect()` and `DBManager.__init__` hardcode `host="localhost", port=5432, dbname="fellowscript", user="fellowscript"`, with `password=os.getenv("DB_PASSWORD")`. **`host` is not env-configurable today** — this matters directly for the containerization approach below |
| Frontend | Static React/Vite build, `rsync`'d to `/var/www/html`, served by `nginx`. **Out of scope for this plan** — stays a static build + rsync deploy |
| Reverse proxy | `nginx` proxies `/api/` to `localhost:8000`; also serves the static frontend from `/var/www/html` |
| Deploy process | Entirely manual: local build → `scp`/`rsync` individual changed files into `~/fellowscript/` (no git checkout on the server) → timestamped backup to `~/deploy_backups/<timestamp>/` → `sudo systemctl restart fellowscript`. No CI/CD. This has already twice missed files across rounds during a recent frontend restyle — a direct driver for wanting this plan |
| Recent incident | An unbounded-growth bug in the CloudWatch log-monitoring subsystem (`backend/monitoring/`) caused a cascading OOM crash on the old, smaller instance; fixed and redeployed the same session this plan was written in. Real precedent for why per-container memory limits are designed for below, not hypothetical |
| Disk/resource headroom | Healthy as of this writing: 19GB disk / 12GB free, 3.7GB RAM. Was a real blocker before the resize; no longer constrains this plan, though the design below stays resource-conscious since this is one small box, not a cluster |
| Secrets today | Plaintext `.env` in `~/fellowscript/` (`OPENROUTER_API_KEY`, `DB_PASSWORD`, `STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY`, `STRIPE_RESTRICTED_KEY`, `STRIPE_SIGNING_SECRET`, `SES_ACCESS_KEY_ID`, `SES_SECRET_ACCESS_KEY`, `SES_REGION`, `SES_SENDER_EMAIL`, `APPLE_BUNDLE_ID`, `APPLE_CLIENT_ID`, `APPLE_KEY_ID`, `APPLE_KEY_PATH`, `APPLE_TEAM_ID`, `CLIENT_ID`, `SUPPORT_EMAIL`), a file-based APNs key (`AuthKey_*.p8`, referenced by `APPLE_KEY_PATH`), and a separately-scoped `AmazonChimeSDK` IAM user (confirmed zero EC2 permissions — see Secrets section below) |

---

## Decision 1 — Postgres stays on the host (not containerized)

**Decision: keep Postgres running directly on the host under `postgresql.service`. Do not containerize it in this plan's scope.**

Reasoning, specific to this deployment (not a generic "don't containerize your database" take):

- **This is one box.** Containerizing Postgres only pays off when it buys portability across hosts, easier horizontal scaling, or environment parity across a fleet — none apply to a single `t3.medium` EC2 instance serving one production app.
- **It already works.** `postgresql.service` is a mature, well-understood systemd-managed process with an existing nightly backup path (`backend/backup/manager.py` copying into `fellowscript_backup` on the same server). Containerizing it introduces new failure modes — volume misconfiguration, an errant `docker system prune` or `docker volume rm` wiping the data directory, container restart-policy interactions with a stateful process — for zero benefit at this scale.
- **The connection code is hardcoded to `localhost`.** `db.py`'s `_connect()` and `DBManager.__init__` both hardcode `host="localhost"`. If the backend runs in a container with Docker's default bridge networking, `localhost` inside that container refers to the container itself, not the host — the app would fail to reach Postgres. Keeping Postgres on the host and running the backend container with **`--network=host`** (Linux-only, but this is Ubuntu on EC2, so it's available) means `localhost:5432` inside the container still resolves to the real host Postgres, and **zero application code has to change** to make containerization work. This is the single biggest reason Decision 1 and the Dockerfile strategy below are the low-risk path.
- **Revisit condition, not a permanent ban:** if FellowScript ever moves to multi-host, a managed database (RDS) or a proper compose-network topology becomes worth it — a `DB_HOST` env var would need to be introduced into `db.py` at that point (a small, contained code change, intentionally not made in this pass). Until then, this stays on host.

| | Postgres on host (chosen) | Postgres in a container |
|---|---|---|
| Change required to `db.py` | None (`localhost` keeps working via `--network=host`) | Requires adding a `DB_HOST` env var, replacing the hardcoded value |
| Data-loss blast radius from a Docker mistake | None — Postgres is untouched by any `docker` command | Real — volume/network misconfig or a stray `docker volume rm` can destroy prod data |
| Matches existing backup tooling | Yes, unchanged | Would need to be re-pointed at a container path/volume |
| Benefit at this scale (single box) | N/A needed | Marginal — no multi-host portability to gain |

---

## Decision 2 — Dockerfile strategy for `api/`

**Base image:** `python:3.14-slim` — **confirmed against the live server**: `python3 --version` on the EC2 venv reports **3.14.6**, matching this repo's own `.venv`. Pin the base image to `python:3.14-slim` (or `python:3.14.6-slim` if reproducibility down to the patch version is preferred over automatic minor-patch updates).

**Confirmed: no `build-essential`/build-toolchain layer is needed.** `psycopg2-binary` (and the rest of `requirements.txt`) installs cleanly via `pip install --no-cache-dir -r requirements.txt` on `python:3.14-slim` with no build toolchain — verified directly rather than assumed from the manylinux-wheel default. This simplifies the build:

**Two-stage build** (kept even without a compile step, since it still separates a smaller runtime image from anything only needed at install time — e.g. `pip`'s own cache, any `-dev`/test-only entries in `requirements.txt` — not because wheels need compiling):
1. **Builder stage** — `pip install --no-cache-dir -r requirements.txt` into a target directory, no `build-essential` or other compiler toolchain required.
2. **Runtime stage** — copy only the installed site-packages and `api/` source from the builder into a fresh `python:3.14-slim`, run as a **non-root user** (create a dedicated `app` user; don't run `uvicorn` as `root` in the container), `EXPOSE 8000`, `CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]`.

**`requirements.txt` gap check — already mostly closed.** `requirements.txt` was recently annotated to explicitly declare every package that was previously only present on the EC2 venv by hand (confirmed via a `pip freeze` parity check documented inline): `psycopg2-binary`, `python-dotenv`, `apscheduler`, `stripe`, `cryptography`, `h2` (needed for `httpx`'s HTTP/2 APNs client), `mcp`, and `tzdata` are all now pinned in the file. A Docker build `FROM requirements.txt` alone should now produce a working image for everything **except one remaining gap**:

- **`backend/monitoring/cloudwatch_mcp_client.py` shells out to `uvx awslabs.cloudwatch-mcp-server@latest` as a subprocess** (`CLOUDWATCH_MCP_COMMAND` env var, defaulting to that command). Installing the `mcp` Python package via `pip` does **not** install `uv`/`uvx` itself, and does not pre-fetch that MCP server package. Two options for the image, to decide before building:
  - Install `uv` in the runtime image (`pip install uv` or the official `uv` install script) so `uvx` is available and can fetch-on-first-run — simplest, but means the container needs outbound network access to PyPI at startup and on every `uvx` cold-start.
  - Pre-install/pin `awslabs.cloudwatch-mcp-server` into the image at build time and point `CLOUDWATCH_MCP_COMMAND` at the fixed binary path instead of `uvx ...@latest` — more reproducible (no `@latest` drift, no runtime fetch), and is the direction this plan recommends when the Dockerfile actually gets written.
- `.dockerignore` should exclude `.venv/`, `data/`, `.git/`, `frontend/`, `FellowScript/` (the iOS app), and the `.env`/`.pem`/`.p8` files living at the repo root — none of that belongs in the image or its build context.

---

## Decision 3 — Secrets and credential handling

Three distinct categories of secret material exist today, and the plan for each must **not regress the existing least-privilege posture** — in particular the fact that the Chime SDK IAM user is already scoped to zero EC2 permissions, which is worth preserving deliberately rather than by accident.

| Category | Current source | Container plan |
|---|---|---|
| `.env` key/value secrets (`OPENROUTER_API_KEY`, `DB_PASSWORD`, `STRIPE_*`, `SES_*`, `APPLE_BUNDLE_ID`/`APPLE_CLIENT_ID`/`APPLE_KEY_ID`/`APPLE_TEAM_ID`, `CLIENT_ID`, `SUPPORT_EMAIL`) | Plaintext `.env` in `~/fellowscript/`, loaded via `python-dotenv` at import time | Pass via `docker run --env-file` (or compose's `env_file:`) pointing at a `.env` that lives **outside** the build context / image — never `COPY .env` into the image, so secrets never land in an image layer or a pushed-registry blob. `docker history` on any built image should be checked to confirm no secret ever appears in a layer. |
| File-based secret: APNs key (`AuthKey_*.p8`, referenced by `APPLE_KEY_PATH`) | Sits on the host filesystem, path passed via env var | **Bind-mount read-only** into the container (`-v /home/ubuntu/fellowscript/AuthKey_XXXX.p8:/secrets/AuthKey_XXXX.p8:ro`) with `APPLE_KEY_PATH` in the env file pointed at the in-container path — same principle as `.env`: never baked into the image. |
| AWS credential material — Chime SDK IAM **user** (access-key pair) | **Confirmed from `api/routes/messaging.py` and `api/routes/devotion.py`**: `boto3.client("chime-sdk-meetings", region_name="us-east-1")` is constructed with no explicit credentials argument — it relies entirely on boto3's default credential resolution chain. **Confirmed against the live server: file-based (`~/.aws/credentials`), not environment variables.** | Bind-mount `~/.aws/credentials` (and `~/.aws/config`) **read-only** into the container, same pattern as the APNs key — do **not** convert it into env vars, which would duplicate the same credential into a second storage form for no benefit. Keep it a separate mount from the APNs key and `.env`, not merged — don't fold Chime's credentials into the same `.env` as `SES_ACCESS_KEY_ID`/`SES_SECRET_ACCESS_KEY` either (those are already deliberately a separate, narrower credential set per `backend/email/ses_client.py`'s own comment — keep that separation in the container too). |
| AWS credential material — `FellowScriptCloudWatchRole` (EC2 **instance IAM role**, confirmed via IMDSv2 in this repo's own prior pipeline work — `.claude/pipeline/20260811-cloudwatch-error-remediation/intake-spec.md` — not an access-key pair at all) | **Security-review correction to this plan's original secrets table**, which had speculated the CloudWatch watchdog's `boto3.client("sts", ...)` call (`api/backend/monitoring/cloudwatch_mcp_client.py::_resolve_account_id`) "likely" shares the same generic credential pair as the Chime SDK user. It does not — this repo's own history confirms `FellowScriptCloudWatchRole` is a **separate EC2 instance role**, resolved automatically by boto3's default chain via the EC2 Instance Metadata Service (IMDSv2), not via any env var, `.env` entry, or credentials file. Nothing in `cloudwatch_mcp_client.py` or `db.py` pulls explicit key material for it — that's the point of an instance role. | **Do not wire this into `.env` or any bind mount at all — doing so would be a least-privilege regression**, converting a short-lived, automatically-rotated, host-scoped credential into a static, copyable secret that could then leak via a `.env` file or image layer. The correct container plan is to do nothing extra: with Decision 4's `--network=host`, the container reaches the EC2 metadata endpoint (`169.254.169.254`) exactly as the host process does today, so `boto3`'s default chain keeps resolving `FellowScriptCloudWatchRole` automatically inside the container with zero secrets wiring — the same "no code/config change needed" property Decision 1 relies on for `localhost:5432`. **Revisit condition:** if backend networking ever moves off `--network=host` to a bridge network in a later phase, confirm IMDSv2 reachability explicitly first — Docker's default bridge network does not always route to the metadata endpoint without extra configuration, and losing that route would silently break the CloudWatch watchdog's account-id resolution rather than fail loudly. |

General rule carried through all three secret categories above and the instance-role row: **nothing secret is ever `COPY`'d into a Dockerfile layer, and nothing secret goes into shell history** — all secret material is supplied at `docker run`/compose time via `--env-file` or read-only bind mounts, both of which are gitignored and never enter the build context. The one exception, by design, is the instance role: it is never "supplied" at all, because doing so would be the regression, not the fix.

---

## Decision 4 — Compose topology (target state, not yet built)

Given Decision 1 (Postgres stays on host) and the `--network=host` requirement it implies, the minimal, lowest-risk phase-1 topology is:

```
nginx (host, systemd, unchanged)  ──▶  fellowscript-api (Docker container, --network=host, :8000)
                                                │
                                                ▼
                                   PostgreSQL (host, postgresql.service, :5432, unchanged)
```

- **`nginx` stays on the host, unchanged.** It already proxies `/api/` to `localhost:8000`; with the backend container on host networking, that config needs zero edits. Containerizing `nginx` too is a later, optional phase (see Migration Path) — not recommended now, since it adds a container for no behavior change while the frontend deploy story (`rsync` to `/var/www/html`) is explicitly out of scope for this plan.
- **Backend runs as a single service** in `docker-compose.yml` (even for one container, compose is worth it over a bare `docker run` for declarative resource limits, restart policy, and env-file wiring — see Decision 5).
- **Networking:** `network_mode: host` on the backend service. No published ports needed (host networking exposes `:8000` directly, same as today's `uvicorn` process).
- **Volumes:** none needed for Postgres (it's not containerized). The backend container itself should be effectively stateless — no named volume required for `api/` beyond the image itself. If Postgres is ever later containerized (see Decision 1's revisit condition), use a **named volume**, not a bind-mount, for its data directory: named volumes avoid host-container UID/GID permission mismatches with the `postgres` image's internal user, are managed and inspectable via `docker volume`, and are just as easy to back up (`docker run --rm -v <volume>:/data -v $(pwd):/backup alpine tar czf /backup/pg-backup.tgz /data`) — but this is deferred, not part of the current recommendation.

---

## Decision 5 — Resource limits

Directly informed by the CloudWatch-watchdog OOM incident: an unbounded-growth bug in one subsystem was able to consume enough memory to crash the entire host, taking down `nginx`, Postgres, and the app together, because nothing constrained that one process's footprint. A container boundary with an explicit memory cap turns "one subsystem's bug crashes the whole box" into "one container gets OOM-killed and restarted" — a real, not hypothetical, benefit on this hardware.

On a 2 vCPU / 3.7GB RAM host that also runs `nginx`, `postgresql.service`, and OS overhead outside the container:

- **Memory:** cap the backend container around **1.5GB** (`mem_limit: 1500m` in compose / `--memory=1500m`), with **swap disabled for the container** (`memswap_limit` equal to `mem_limit`, i.e. no container swap) — so a runaway process gets OOM-killed and restarted by the container's restart policy instead of dragging the whole host into the same swapping death-spiral the pre-resize instance experienced.
- **CPU:** cap around **1.5 vCPUs** (`cpus: "1.5"`), leaving headroom for `nginx` + Postgres + the OS on the remaining half core, rather than letting one busy request queue starve the database process.
- **Restart policy:** `restart: unless-stopped`, so a container that gets OOM-killed comes back automatically without a manual SSH session, matching the reliability the systemd unit already provides today.
- These are starting numbers to validate under real load once phase 1 actually ships — not a substitute for continuing to fix the root-cause bugs the watchdog surfaces (per `backend/monitoring/`'s own read-only, non-remediating design).

---

## Migration path (phased, live production app)

This app has real users today; nothing below is executed as part of this plan — it is the order to execute in when the actual build happens.

**Phase 0 — this document.** Planning only. No code, config, or infra changed. *(Complete as of this pass.)*

**Phase 1 — containerize the backend only.**
1. Write the Dockerfile per Decision 2 and confirm `docker build` succeeds locally against a copy of `requirements.txt`.
2. Confirm the `uvx`/CloudWatch-MCP-server decision (Decision 2) before finalizing the image.
3. On the EC2 host, `docker build` (or pull a pre-built image once CI/CD exists in Phase 4) and `docker run` the container **alongside** the still-running `fellowscript.service`, on a scratch port first (e.g. `:8001`) to smoke-test independently before touching `nginx` or the live `:8000` path.
4. Cut over: `sudo systemctl stop fellowscript`, start the container with `--network=host` bound to `:8000` (or via `docker compose up -d` once Decision 4's compose file exists).
5. **Rollback plan:** do **not** disable or remove the `fellowscript.service` systemd unit — leave it installed and stopped for a defined burn-in window (recommend at least 1–2 weeks of stable production traffic). Reverting is a single `docker stop fellowscript-api && sudo systemctl start fellowscript` — seconds, not a redeploy. Because Postgres never leaves the host (Decision 1), **the database is never part of this rollback** — there is no data migration to reverse, which is the main risk-reduction payoff of Decision 1. Keep the existing `~/deploy_backups/<timestamp>/` manual snapshot mechanism running through this phase too, as a cheap secondary safety net, and don't retire it until the container has been stable through the burn-in window.

**Phase 2 — formalize with compose.** Once Phase 1 is stable, move from a bare `docker run` to the `docker-compose.yml` from Decision 4, adding the resource limits and restart policy from Decision 5 declaratively. Low-risk, since it's re-expressing an already-working container, not changing behavior.

**Phase 3 — optional, deferred.** Re-evaluate containerizing `nginx` and/or Postgres only if a concrete driver appears (e.g. moving beyond a single instance, wanting environment parity with a staging box, or outgrowing the current backup approach). Not recommended now — Decision 1's reasoning holds as long as this stays a single-instance deployment.

**Phase 4 — CI/CD follow-on** (recommended direction, not built now, per the user's stated interest in removing manual SSH deploy steps):
- A GitHub Actions workflow that, on merge to the deploy branch: builds the Dockerfile from Decision 2, tags the image with the git SHA (not just `latest` — SHA tags are what make instant rollback-to-a-previous-image possible), and pushes it to a registry (GHCR is the natural default — no separate account needed beyond the existing GitHub org).
- A deploy step that SSHes into the EC2 host (still necessary for a single-instance deployment — this isn't being replaced, just made reliable) and runs `docker pull <sha-tag> && docker compose up -d`, replacing the current file-by-file `rsync` (the exact mechanism that has already twice missed files across two rounds) with an atomic, fully-versioned image swap.
- Rollback under CI/CD becomes `docker pull <previous-sha-tag> && docker compose up -d` — nothing to manually reconstruct from `~/deploy_backups/<timestamp>/` snapshots, since every deployed state is a tagged, retrievable image.
- Out of scope for this plan to build; listed here only as the recommended next step once Phases 1–3 are stable.

---

## Open items — all confirmed against the live server

All three items originally flagged here have been confirmed directly against the production host and folded into Decisions 2–3 above; nothing static-analysis-only remains blocking Phase 1:

- **Python version:** 3.14.6, confirmed via `python3 --version` on the EC2 venv. Matches this repo's `.venv` — Decision 2's base image choice stands as written.
- **Chime SDK credential storage:** file-based (`~/.aws/credentials`), not environment variables. Decision 3's secrets table reflects the single confirmed mechanism (read-only bind-mount).
- **`psycopg2-binary` build toolchain requirement:** confirmed **not needed** — installs cleanly with no `build-essential`/compiler layer. Decision 2 updated accordingly.

# FellowScript backend — Phase 1 of docs/architecture/docker-plan.md.
#
# Two-stage build per Decision 2: no build-essential/compiler toolchain is
# needed (psycopg2-binary and the rest of requirements.txt install clean on
# python:3.14-slim — confirmed against the live server, not assumed), but the
# split is kept anyway so the runtime image doesn't carry pip's own cache or
# anything install-time-only.
#
# Build context is the repo root (docker-compose.yml's `context: .`), so this
# Dockerfile can COPY both requirements.txt (root) and api/ (subdir) — see
# .dockerignore for what's excluded from that context.

# ---- builder ----------------------------------------------------------
FROM python:3.14.6-slim AS builder

WORKDIR /build

COPY requirements.txt .
# --prefix installs into an isolated tree the runtime stage copies wholesale,
# instead of polluting /usr/local directly in this stage.
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- runtime -----------------------------------------------------------
FROM python:3.14.6-slim

# Non-root runtime user — Decision 2. No shell/home needed beyond the
# defaults; this user only ever runs uvicorn.
RUN groupadd --system app && useradd --system --gid app --no-create-home app

COPY --from=builder /install /usr/local

# api/main.py and its sibling modules use imports relative to api/ itself
# (e.g. `from routes.notes import notes_router`), so the runtime app root
# has to be api/, not the repo root, for `main:app` to resolve.
WORKDIR /app/api
COPY api/ .

# Decision 2's resolved uvx/cloudwatch-mcp-server pinning: the package is
# pip-installed above (pinned in requirements.txt) rather than fetched at
# runtime via `uvx awslabs.cloudwatch-mcp-server@latest`. No CLOUDWATCH_MCP_
# COMMAND override is set here — cloudwatch_mcp_client.py's own default now
# already resolves to this pinned package's console-script entry point
# (`awslabs.cloudwatch-mcp-server`), so it's correct in this image with zero
# extra env wiring; still overridable via env_file/compose if a future
# deploy target ever needs something else.

# Ownership for the app's own source is enough — no writable data directory
# is needed at runtime (the app is stateless; the only on-disk data/ access
# in this codebase is scripts/migrate_json_to_postgres.py's migrate_data()/
# main_notes_only(), one-off manual migration entry points not invoked by
# the running app, and data/ is excluded from the build context entirely —
# see .dockerignore).
RUN chown -R app:app /app/api
USER app

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]

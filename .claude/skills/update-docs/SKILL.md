---
name: update-docs
description: After every new feature is added, update the MkDocs documentation in docs/ to reflect the change, then deploy to GitHub Pages via `mkdocs gh-deploy`. Triggered automatically after any meaningful code change that adds or modifies user-visible behaviour.
---

# FellowScript Documentation Standard

After writing or changing any feature, update the relevant docs pages so the documentation stays in sync with the code. Then build and push to GitHub Pages. Do not skip this step — stale docs are worse than no docs.

---

## When to update docs

Update docs after **every** change that involves:
- A new backend route or endpoint (add to `docs/api/overview.md`)
- A change to the backend architecture (layers, new manager, new table) → `docs/architecture/backend.md` or `docs/architecture/data.md`
- A new frontend page or major component → `docs/design/` (pick the matching page or create one)
- A new subscription/billing behaviour → whichever architecture or API page covers it
- A new database table or column visible to the API consumer → `docs/architecture/data.md`

Skip docs updates only for:
- Pure cosmetic changes (CSS, colors, copy tweaks)
- Internal refactors with no visible behaviour change
- Test-only additions
- Comment-only edits

---

## Doc file map

| What changed | Doc file to edit |
|---|---|
| New REST endpoint or request/response shape | `docs/api/overview.md` |
| New backend manager, layer, or module | `docs/architecture/backend.md` |
| New Postgres table or column | `docs/architecture/data.md` |
| Frontend routing or new page | `docs/architecture/frontend.md` |
| New user-facing feature (reader, notes, community) | matching file in `docs/design/` |
| System-level architectural change | `docs/architecture/overview.md` |

If the change does not fit any existing file, create a new `.md` file in the closest matching subfolder and add it to the `nav:` section of `mkdocs.yml`.

---

## How to write the docs

Keep every doc entry short — one paragraph max per item. Follow the pattern already in each file:

**For a new API endpoint** (`docs/api/overview.md`):
```markdown
### `POST /subscription/apple`
Validates an Apple App Store receipt and activates the matching subscription plan for the user.

**Body:**
```json
{ "user_id": "uuid", "receipt": "base64string" }
```

**Response:** `201` with `{ "subscription_id": "uuid" }` on success, `402` if validation fails.
```

**For a new architecture component** (`docs/architecture/backend.md`):
```markdown
### `backend/subscription/subscriptions.py`
`SubscriptionsManager(DBManager)` manages plan creation, lookup, and expiry.
Key methods: `create_free_plan`, `get_subscription`, `reconcile_expired_subscriptions`.
```

**For a design/feature change** (`docs/design/*.md`):
```markdown
## Note Date Labels
Each note card now shows the creation date in the bottom-right corner ("Today", "Yesterday", or "Jul 16").
Notes are always sorted by creation date, newest first.
```

Do **not** copy-paste code blocks longer than ~10 lines into docs. Summarise intent and shape, not implementation.

---

## Updating mkdocs.yml nav

If you create a new `.md` file, add it to the `nav:` section of `mkdocs.yml` in the correct position:

```yaml
nav:
  - API:
    - Overview: api/overview.md
    - Subscriptions: api/subscriptions.md   # ← new entry
```

Keep nav entries alphabetical within their section.

---

## Deploying to GitHub Pages

After updating the docs, run:

```bash
cd /Users/jaceysimpson/Vscode/FellowScript
.venv/bin/mkdocs gh-deploy --force
```

This builds the static site and force-pushes it to the `gh-pages` branch of `https://github.com/Jacey1225/FellowScript.git`. It does **not** touch the `main` branch.

If the command fails:
- `git remote not set` → run `git remote add origin https://github.com/Jacey1225/FellowScript.git` from the repo root
- `mkdocs not found` → use the full path `.venv/bin/mkdocs`
- Theme error (`material` not found) → run `.venv/bin/pip install mkdocs-material` first

After a successful deploy, confirm by reporting the URL: `https://jacey1225.github.io/FellowScript/`

---

## Execution order within a task

1. Write the feature code.
2. Identify which doc file(s) the change touches (use the table above).
3. Edit the relevant `docs/**/*.md` files — add or update sections as needed.
4. If a new `.md` file was created, add it to `mkdocs.yml` nav.
5. Run `.venv/bin/mkdocs gh-deploy --force` from the project root.
6. Report: which doc sections were updated and confirm deploy succeeded.

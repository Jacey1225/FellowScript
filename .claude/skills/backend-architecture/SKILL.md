---
name: backend-architecture
description: FellowScript FastAPI backend conventions. Use whenever adding, editing, or reviewing backend code under api/ (schemas, backend/interactions, routes, db.py). Guides new features to match the existing three-layer structure so code stays consistent and simple.
---

# FellowScript Backend Architecture

The backend (`api/`) is a FastAPI + Postgres app with a strict **three-layer** flow.
Data moves in one direction:

```
routes/ (HTTP)  ──►  backend/interactions/ (logic + DB)  ──►  Postgres
   ▲                        │
   └── schemas/ (Pydantic contracts) shared by both ──┘
```

When building a feature, add code to **all three layers**, then register the router
in `main.py` and the table(s) in `db.py`. Follow the patterns below exactly —
prefer copying an existing sibling over inventing a new style.

---

## Layer 1 — `schemas/` (Pydantic data contracts)

One file per domain (`users.py`, `message.py`, `devotion.py`, `agent.py`,
`notifications.py`, `filter.py`). Each holds `pydantic.BaseModel` classes that
define request/response shapes and internal records.

Conventions:
- Import: `from pydantic import BaseModel, Field`.
- IDs: `Field(default_factory=lambda: str(uuid.uuid4()))`.
- Collections: `Field(default_factory=list)` / `default_factory=dict` — **never**
  a bare mutable default.
- Timestamps as strings: `Field(default_factory=lambda: str(datetime.now()))`.
- Optional inbound fields: `str | None = None` (see `UpdateUser`).
- A domain often has a **record model** plus a **request model** that wraps it
  (e.g. `DevotionPlan` + `DevotionRequest`, or `SignUp`/`Login`/`UpdateUser` for users).

Example (`schemas/devotion.py`):
```python
class DevotionPlan(BaseModel):
    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    title: str = ""
    participants: list[str] = Field(default_factory=list)

class DevotionRequest(BaseModel):   # what the route receives
    devotion_id: str
    user_id: str
    devotion: DevotionPlan
```

---

## Layer 2 — `backend/interactions/` (business logic + DB access)

All logic and every query live here in a **`*Manager` class that subclasses
`DBManager`** (from `db.py`). Routes never touch SQL directly.

Two constructor styles — pick based on whether the operations are scoped to one user:

**A. User-scoped** (`GroupsManager`, `FriendsManager`, `AgentManager`) — loads the
acting user in `__init__`:
```python
class FriendsManager(DBManager):
    def __init__(self, user_id: str) -> None:
        super().__init__()
        self.user_id = user_id
        result = self.lookup("users", {"_id": user_id})
        if result:
            uid, data = list(result.items())[0]
            self.user = User(user_id=uid, **data)
        else:
            self.user = User()
```

**B. Context-free** (`DevotionManager`) — no-arg, methods take IDs as params:
```python
class DevotionManager(DBManager):
    def read_devotion(self, devotion_id: str) -> DevotionPlan | None:
        ...
```

### Using the inherited `DBManager` helpers

`DBManager` gives every manager these methods. **They auto-commit and auto-rollback**
— do not add your own commit after them.

| Method | Use for | Returns |
|--------|---------|---------|
| `self.insertion(table, values: dict, conflict="DO NOTHING")` | inserts / upserts | None |
| `self.lookup(table, conditions: dict = {})` | simple reads | `{id: {other_cols}}` |
| `self.delete(table, conditions: dict)` | deletes | None |
| `self.update(table, values: dict, conditions: dict)` | updates | None |

`lookup` returns a dict **keyed by the table's first column** (usually `_id`), each
value being the remaining columns. For a single expected row, unwrap with:
```python
result = self.lookup("groups", {"_id": group_id})
if not result:
    return {"error": "Group not found"}
_, data = list(result.items())[0]
```

Upsert via the `conflict` arg:
```python
self.insertion(
    "highlights",
    {"user_id": user_id, "key": key, "color": color},
    conflict="(user_id, key) DO UPDATE SET color = EXCLUDED.color",
)
```

### When to drop to raw SQL (`self.cur.execute` + `self.conn.commit()`)

Use the cursor directly — and remember to `self.conn.commit()` for writes — when the
helpers can't express it:
- **JOINs** (e.g. friends/requests joining `users`).
- **Composite-PK tables with no `_id`** (`highlights`, `bookmarks`,
  `message_recipients`) — `lookup` keys on the first column and would collapse rows,
  so read with the cursor.
- **Array ops**: `array_append` / `array_remove` / `= ANY(...)` (devotion participants).
- **Ordering / aggregation** (`ORDER BY`, counts).

```python
self.cur.execute(
    "SELECT u._id, u.username FROM users u "
    "JOIN friend_requests fr ON u._id = fr.from_user_id "
    "WHERE fr.to_user_id = %s",
    (self.user_id,),
)
return [{"user_id": r[0], "username": r[1]} for r in self.cur.fetchall()]
```

Always use `%s` parameters — never f-string user data into SQL.

### Error signalling
Managers return `{"error": "message"}` on expected failures (not found, forbidden).
The route translates that into an `HTTPException`. Reserve raising exceptions inside
the manager for truly exceptional cases.

---

## Layer 3 — `routes/` (thin HTTP surface)

One file per domain, each defining an `APIRouter(prefix="/...")`. Handlers are
**thin**: build the manager, call one method, map errors, close the connection.

```python
from fastapi import APIRouter, HTTPException
from backend.interactions.groups import GroupsManager
from schemas.message import Group

group_router = APIRouter(prefix="/groups")

@group_router.post("/{user_id}", status_code=201)
async def create_group(user_id: str, group: Group) -> dict:
    manager = GroupsManager(user_id)
    manager.create_group(group.users, group)
    return {"group_id": group.group_id}
```

Route conventions:
- **`async def`** handlers with a return type annotation (`-> dict`, `-> None`,
  `-> list[dict]`).
- **`try/finally: db.close()`** whenever you hold a manager for multiple ops or the
  handler can raise mid-way (see `routes/notes.py`, `routes/devotion.py`). Short
  single-call handlers that always close may inline it, but prefer `finally`.
- **Map `{"error": ...}` → `HTTPException`**:
  ```python
  result = manager.read_friend(friend_id)
  if "error" in result:
      raise HTTPException(status_code=404, detail=result["error"])
  return result
  ```
- **Status codes**: `201` for create, `204` for delete/void updates, default `200`.
- **Route ordering matters**: register literal segments *before* wildcard captures.
  `GET /{user_id}/requests` must come before `GET /{user_id}/{friend_id}`, and
  websocket/`ws` routes before `/{user_id}`. FastAPI resolves in definition order.
- Docstrings follow the Google style seen in `routes/community.py`
  (Args / Returns / Raises).

### Wiring a new router
Add both lines to `main.py`:
```python
from routes.subscription import subscription_router   # near the other route imports
...
app.include_router(subscription_router)               # near the other include_router calls
```

---

## `db.py` — schema + the `DBManager` engine

- **Schema** lives in `create_tables(cur)`, grouped by FK dependency **Level 0 → 1 → 2**.
  A new table goes *after* everything it references. Style:
  - `_id UUID PRIMARY KEY` (or `DEFAULT gen_random_uuid()` for server-generated IDs).
  - FKs: `REFERENCES users(_id) ON DELETE CASCADE` (or `SET NULL` when the child
    should survive), matching the parent's delete semantics.
  - `TIMESTAMPTZ DEFAULT NOW()`, `TEXT[]` arrays, `JSONB` for blobs.
  - Composite PKs for join tables: `PRIMARY KEY (user_id, key)`.
- **Additive migrations**: after the `CREATE TABLE`, add idempotent
  `cur.execute("ALTER TABLE t ADD COLUMN IF NOT EXISTS col TYPE")` (pattern used for
  `apple_sub`, `google_sub`, `last_fired`). Keep `db.py` and the live DB in sync —
  run the same DDL on the server (see the deploy memory / `DBManager`).
- The **`DBManager`** class connects to `fellowscript` on localhost:5432 with
  `DB_PASSWORD` from env. Every manager `super().__init__()`s into it.

---

## Checklist for a new backend feature

1. **schema** — add record + request models in the right `schemas/*.py`.
2. **table** — add `CREATE TABLE IF NOT EXISTS` to `create_tables` in `db.py` at the
   correct dependency level; run the DDL on the live DB too.
3. **manager** — add a `*Manager(DBManager)` in `backend/interactions/` (or a method
   on an existing one); use helper methods first, raw cursor only when needed; return
   `{"error": ...}` on expected failures.
4. **router** — add an `APIRouter(prefix=...)` in `routes/`; thin handlers,
   `try/finally: db.close()`, map errors to `HTTPException`, correct status codes,
   literal-before-wildcard ordering.
5. **wire** — import + `include_router` in `main.py`.
6. Match existing docstring style and keep SQL parameterized (`%s`).

---

## In-progress: the subscription feature (as of this writing)

Scaffolding exists but is unimplemented — a good first application of this skill:
- `schemas/users.py` → `Subscriptions` model (already defined; note `User` also has
  `subscription_id`).
- `backend/subscription/subscriptions.py` → only imports so far; add a
  `SubscriptionsManager(DBManager)` here (this is a sibling package to
  `interactions/`, so the manager pattern is identical).
- `routes/subscription.py` → empty; add `subscription_router` and wire it in `main.py`.
- `db.py` → no `subscriptions` table yet; add one at Level 1 (FK →
  `users(_id) ON DELETE CASCADE`).

Store only opaque processor references (`stripe_customer_id`, `default_payment_method_id`,
`apple_original_transaction_id`) + safe display fields (`card_brand`, `card_last4`) —
never raw card numbers or CVV.

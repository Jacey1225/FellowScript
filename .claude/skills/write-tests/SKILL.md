---
name: write-tests
description: After every new feature or fix, write and run integration/unit tests that prove correctness, guard security boundaries, and catch the class of bug that was just fixed or added. Invoked automatically after any backend, frontend, or iOS code change.
---

# FellowScript Testing Standard

After writing or changing any code, immediately write tests that prove it works, prove the error paths fail correctly, and probe the security boundary. Run them before declaring the task done.

---

## When to write tests

Write tests after **every** change that involves:
- A new or modified backend route, manager method, or DB query
- A new or modified frontend component with business logic (API calls, state transitions, conditional rendering)
- A new or modified iOS service method
- A bug fix — always write a test that would have caught the bug

Skip tests only for:
- Pure cosmetic changes (CSS, colors, copy, layout tweaks)
- Renaming/moving files with no logic change
- Comment-only edits

---

## Backend tests (`api/test_<feature>.py`)

Use FastAPI's `TestClient` against a **real Postgres test DB** — never mock the database. Mocked DB tests have historically passed while real DB migrations failed. The pattern from existing tests in this project:

```python
import uuid
from fastapi import FastAPI
from fastapi.testclient import TestClient
from db import DBManager
from routes.<domain> import <domain>_router

app = FastAPI()
app.include_router(<domain>_router)
client = TestClient(app)

def make_test_user():
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": f"test_{uid[:8]}",
                               "email": f"test_{uid[:8]}@example.com", "hash_pass": "x"})
    finally:
        db.close()
    return uid

def cleanup(uid):
    db = DBManager()
    try:
        db.delete("users", {"_id": uid})   # cascades to most child tables
    finally:
        db.close()
```

### Mandatory test cases for every backend feature

For each new route or manager method, cover **all four** of these:

1. **Happy path** — correct input returns the right status code and shape
   ```python
   r = client.post("/notes/user123", json={"title": "T", "text": "B"})
   assert r.status_code == 201
   assert "id" in r.json()
   ```

2. **Error path** — missing/invalid input returns 4xx, not 500
   ```python
   r = client.get("/subscriptions/user/nonexistent-id")
   assert r.status_code == 404
   ```

3. **Security boundary** — user A cannot read or mutate user B's data
   ```python
   uid_a, uid_b = make_test_user(), make_test_user()
   # Create note as A, try to delete as B
   note_id = client.post(f"/notes/{uid_a}", json={...}).json()["id"]
   r = client.delete(f"/notes/{uid_b}?note_id={note_id}")
   assert r.status_code in (403, 404)   # must not be 204
   ```

4. **Cascade / cleanup integrity** — deleting a parent does not orphan children or raise FK errors
   ```python
   uid = make_test_user()
   client.post(f"/notes/{uid}", json={"title": "T", "text": "B"})
   r = client.delete(f"/user/{uid}")
   assert r.status_code == 204
   # Confirm no orphaned rows remain
   db = DBManager(); db.cur.execute("SELECT 1 FROM notes WHERE user_id=%s",(uid,)); assert not db.cur.fetchone(); db.close()
   ```

### Additional tests by category

**Subscription / limits**
- Free user hitting a cap returns 403 with `{"detail": {"resource": ..., "used": ..., "limit": ...}}`
- Subscribed user is never blocked
- Lapsed subscription (period_end in past beyond grace) reads as unsubscribed

**Auth**
- Signup with duplicate username → 409
- Login with wrong password → 401
- Login with unknown username → 401/404

**Input validation**
- Empty strings, None values, oversized payloads → 422 or graceful 400, never 500
- UUID fields that are not valid UUIDs → 422

### Style rules
- Test file: `api/test_<feature>.py`
- Each scenario is a function or labeled block — never silent; always `print` or `assert` what you're checking
- Always clean up test data in a `finally` block
- Run with: `cd api && ../.venv/bin/python test_<feature>.py`
- Print `✅` on full pass, `❌ FAIL` with context on any failure

---

## Frontend tests (`frontend/src/**/*.test.jsx`)

Use **Vitest** + **React Testing Library**. Mock the fetch/API layer at the boundary.

```bash
cd frontend && npm test -- --run src/components/MyComponent.test.jsx
```

### What to test in React

Only test components that have **real logic** — conditional rendering, state transitions, API calls, derived values.

```jsx
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { vi } from 'vitest'
import MyComponent from './MyComponent'

global.fetch = vi.fn()

test('shows error when API returns 500', async () => {
  fetch.mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) })
  render(<MyComponent userId="u1" />)
  await waitFor(() => expect(screen.getByRole('alert')).toBeInTheDocument())
})
```

**Always test:**
- Loading state renders while fetch is in-flight
- Success state renders correct data from a mocked 200 response
- Error state renders an error message on 4xx/5xx
- Any conditional that depends on user role, plan type, or auth state

**Skip tests for:**
- Pure presentational components (no logic, no fetch, no state)
- Inline-styled wrappers

---

## iOS tests (`FellowScript/FellowScriptTests/`)

Use **XCTest**. Test only manager/service logic — not UI layout.

```swift
import XCTest
@testable import FellowScript

final class NetworkServiceTests: XCTestCase {

    func testDeleteUserCallsCorrectEndpoint() async throws {
        let mock = MockNetworkService()
        try await mock.deleteUser(userId: "abc-123")
        XCTAssertEqual(mock.lastMethod, "DELETE")
        XCTAssertTrue(mock.lastPath.contains("abc-123"))
    }
}
```

**Always test for new iOS service methods:**
- Correct HTTP method and path are used
- Model parsing does not crash on a minimal valid JSON response
- Error propagation: a 4xx from the server throws (not silently swallows)

---

## Security checklist — run mentally after every change

Before calling any backend feature done, confirm:

- [ ] All SQL uses `%s` parameters — no f-strings or `.format()` with user data
- [ ] No user-supplied string is used in an OS command or file path
- [ ] Auth-gated routes: tested that another user's id returns 403/404
- [ ] Sensitive fields (`hash_pass`, payment tokens) are never included in response JSON
- [ ] New FK columns include `ON DELETE CASCADE` or `ON DELETE SET NULL` — never bare `REFERENCES` (which defaults to RESTRICT and silently breaks `delete_user`)
- [ ] Free-plan users cannot reach paid-only resources by manipulating request fields
- [ ] No secrets, API keys, or passwords committed to files

---

## Pre-deployment smoke test (mandatory before declaring a backend change done)

Per-router `TestClient(app)` instances (as in the pattern above) only prove that
router's handlers work in isolation — they do NOT prove the real app boots. A
change can pass every per-route test and still crash the live server on deploy
via a failure that only shows up when `main.app` itself loads: a bad import, a
missing dependency, a route-ordering conflict across routers, or a startup-time
error in the `lifespan` (scheduler, DB connection, etc.). All of these have
actually happened in this project. Before calling any backend change done:

1. **Boot the real app, not a stub.** Import `main.app` (or run
   `uvicorn main:app`) with the same env vars production uses and confirm it
   starts without exceptions — including the `lifespan` startup (scheduler
   jobs, DB connect). A per-router `FastAPI()` + `include_router(...)` test
   app does not catch cross-router registration issues or lifespan failures.
2. **Hit every modified endpoint at least once against the fully-booted app**
   — not just the ones with dedicated unit tests. A quick loop over modified
   routes checking for a non-500 with plausible input catches silent breakage
   in routes that "should" be unaffected by a change but share a dependency,
   import, or middleware with what changed.
3. **WebSocket routes need explicit tests too** — they use a different
   request/response lifecycle than HTTP routes (no per-request exception
   handler, auth typically read from `websocket.cookies` instead of a
   dependency), so an HTTP-only test pass does not exercise them.
   `TestClient.websocket_connect(url, cookies=...)` covers this without a
   live server.
4. **Auth/permission changes specifically**: for every route whose access
   control changed, test both an authorized caller (still works) and an
   unauthorized one (now correctly rejected) against the live dependency
   chain — not just the manager method in isolation, since the bug is
   typically in the wiring (a missing `Depends(...)`, a parameter name
   mismatch), not the auth logic itself.
5. Only after 1–4 pass should the change be deployed. If a live staging/local
   environment isn't available, say so explicitly in the report rather than
   presenting per-route unit tests as proof the server won't break.

---

## Test coverage targets

| Layer | Minimum coverage |
|-------|-----------------|
| New backend route | happy path + 1 error path + security boundary |
| New manager method | happy path + not-found case |
| Bug fix | a test that fails *before* the fix, passes *after* |
| New React component with logic | loading + success + error states |
| New iOS service method | correct path + error propagation |

---

## Execution order within a task

1. Write the feature code.
2. Write the test(s) covering the cases above.
3. Run the tests (`python test_<feature>.py` or `npm test -- --run`).
4. If any test fails, fix the code (or the test if the assertion was wrong) and re-run.
5. Delete throwaway test scripts that were only used for one-shot debugging. Keep tests that assert ongoing correctness in a named file (e.g. `api/test_subscriptions.py`).
6. Report: which tests were written, which passed, and what edge case each covers.

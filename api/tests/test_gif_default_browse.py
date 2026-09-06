"""Tests for the GIF picker's default/trending browse mode (task
20260905-gif-picker-default-browse, testing step 4 -- the final gate).

Covers, per this task's workflow step 4 charter:
  1. `browse_gifs()` (Giphy branch): integer `offset` pagination normalized
     into an opaque `next_page_token` (stringified offset) + `has_more`,
     round-tripped correctly across multiple pages, converging to
     `has_more=False`/`next_page_token=None` once `offset + len(page) ==
     total_count`; a malformed/negative caller-supplied token degrades to
     offset 0 rather than erroring; `GIF_SEARCH_RESULT_LIMIT` is the page
     size sent to the provider.
  2. `browse_gifs()` (Tenor branch): opaque cursor (`pos`/`next`) passed
     straight through unparsed; `has_more` requires BOTH a truthy `next`
     token AND a non-empty results page (a provider quirk where `next` is
     present but the page is empty must still degrade to "no more", not
     offer a "load more" that fetches nothing); no `pos` param sent for the
     first page.
  3. Both providers: an empty result set degrades to an empty, non-paginated
     response; a provider-side failure raises `GifSearchError`; an
     unconfigured provider raises `GifConfigError` -- same distinction
     `search_gifs` already makes.
  4. `GET /message/gif-search` route: a blank/absent `q` triggers
     `browse_gifs` (not `search_gifs`) and the response envelope carries
     `next_page_token`/`has_more`; `page_token` round-trips to `browse_gifs`
     unmodified; a non-empty `q` still calls `search_gifs`, ignores
     `page_token`, and returns exactly `{"results": [...]}` -- no new keys
     leak into the pre-existing search contract; browse mode is auth-gated
     (401 unauthenticated) exactly like search; `GifConfigError`/
     `GifSearchError` map to 503/502 for browse exactly like they already do
     for search; browse and search share the SAME 30/minute per-IP limiter
     (budget exhausted -> 429).
  5. Regression: runs the existing test_messaging_attachments.py file (which
     covers search_gifs's route/shaping contract) as a subprocess and
     confirms it still passes unmodified -- this task is additive to
     gif_search.py, not a breaking change to search_gifs.

Run with: cd api && ../.venv/bin/python tests/test_gif_default_browse.py
"""
import _pathfix  # noqa: F401,E402

import asyncio
import os
import subprocess
import sys
import uuid
from contextlib import contextmanager

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from dotenv import load_dotenv  # noqa: E402
load_dotenv()  # real .env values (if present) win over the placeholders below


def _ensure_config_present():
    """Same rationale as test_messaging_attachments.py's helper of the same
    shape: let a real, already-provisioned config win; fall back to a
    synthetic placeholder only where genuinely absent, so `main.app` (whose
    lifespan validates both attachment and GIF config unconditionally) boots
    in any environment. GIF search/browse is never exercised against the
    real provider in this file -- every provider call goes through a fake
    `httpx.AsyncClient` (unit-level tests) or a swapped-in fake
    `browse_gifs`/`search_gifs` (route-level tests)."""
    os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
    os.environ.setdefault("S3_REGION", "us-east-1")
    os.environ.setdefault("GIF_PROVIDER", "giphy")
    os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")


_ensure_config_present()

from fastapi.testclient import TestClient  # noqa: E402
from db import DBManager  # noqa: E402
import main as main_module  # noqa: E402
import routes.messaging as messaging_module  # noqa: E402
import backend.interactions.gif_search as gif_search  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


# ── Fixtures / helpers (mirrors test_messaging_attachments.py) ─────────────

def cookie_header(token: str | None):
    return {"cookie": f"session={token}"} if token else {}


_signup_counter = 0


def signup(client, prefix: str):
    global _signup_counter
    _signup_counter += 1
    fake_ip = f"203.0.113.{_signup_counter % 250 + 1}"
    username = f"{prefix}_{uuid.uuid4().hex[:8]}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com",
        "plain_pass": "TestPass123!", "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def cleanup_users(*user_ids):
    db = DBManager()
    try:
        for uid in user_ids:
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


# ── Fake httpx.AsyncClient (mirrors test_sso_terms_gate.py's technique) ────

class _FakeResponse:
    def __init__(self, json_data=None):
        self._json = json_data or {}

    def raise_for_status(self):
        pass

    def json(self):
        return self._json


class _FakeAsyncClient:
    """Queues canned responses/exceptions, consumed in call order; records
    every (url, params) call so tests can assert on what was actually sent
    to the provider."""

    def __init__(self, responses):
        self._responses = list(responses)
        self.calls = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def get(self, url, params=None):
        self.calls.append((url, params or {}))
        if not self._responses:
            raise AssertionError("no more fake provider responses queued")
        resp = self._responses.pop(0)
        if isinstance(resp, Exception):
            raise resp
        return resp


@contextmanager
def _fake_httpx(responses):
    fake_client = _FakeAsyncClient(responses)
    orig = gif_search.httpx.AsyncClient
    gif_search.httpx.AsyncClient = lambda *a, **kw: fake_client
    try:
        yield fake_client
    finally:
        gif_search.httpx.AsyncClient = orig


@contextmanager
def _configured_provider(provider: str, api_key: str = "test-key", limit: int | None = None):
    saved_provider = gif_search.GIF_PROVIDER
    saved_key = gif_search._GIF_PROVIDER_API_KEY
    saved_limit = gif_search.GIF_SEARCH_RESULT_LIMIT
    gif_search.GIF_PROVIDER = provider
    gif_search._GIF_PROVIDER_API_KEY = api_key
    if limit is not None:
        gif_search.GIF_SEARCH_RESULT_LIMIT = limit
    try:
        yield
    finally:
        gif_search.GIF_PROVIDER = saved_provider
        gif_search._GIF_PROVIDER_API_KEY = saved_key
        gif_search.GIF_SEARCH_RESULT_LIMIT = saved_limit


def _giphy_item(gid: str) -> dict:
    return {
        "id": gid,
        "images": {
            "original": {"url": f"https://media.giphy.com/{gid}/giphy.gif", "width": "480", "height": "270"},
            "fixed_width_small": {"url": f"https://media.giphy.com/{gid}/small.gif"},
        },
    }


def _tenor_item(gid: str) -> dict:
    return {
        "id": gid,
        "media_formats": {
            "gif": {"url": f"https://media.tenor.com/{gid}/full.gif", "dims": [320, 240]},
            "tinygif": {"url": f"https://media.tenor.com/{gid}/tiny.gif"},
        },
    }


# ── 1. browse_gifs (Giphy): offset pagination normalization ────────────────

def test_browse_gifs_giphy_normalizes_offset_pagination():
    print("\n=== 1. browse_gifs (Giphy): integer offset normalized into opaque "
          "next_page_token/has_more, round-trips correctly across pages ===")
    with _configured_provider("giphy", limit=2):
        page1_raw = [_giphy_item("a1"), _giphy_item("a2")]
        with _fake_httpx([_FakeResponse({"data": page1_raw, "pagination": {"total_count": 5}})]) as fake:
            page1 = asyncio.run(gif_search.browse_gifs(None))
        check("first page requests offset=0 (no token supplied)", fake.calls[0][1].get("offset") == 0, str(fake.calls))
        check("first page requests limit == GIF_SEARCH_RESULT_LIMIT",
              fake.calls[0][1].get("limit") == 2, str(fake.calls))
        check("first page item shape matches search's _shape_giphy exactly",
              page1["results"] == gif_search._shape_giphy(page1_raw), str(page1))
        check("first page has_more True (2 of 5 seen so far)", page1["has_more"] is True, str(page1))
        check("first page next_page_token is the next offset, stringified",
              page1["next_page_token"] == "2", str(page1))

        page2_raw = [_giphy_item("a3"), _giphy_item("a4")]
        with _fake_httpx([_FakeResponse({"data": page2_raw, "pagination": {"total_count": 5}})]) as fake2:
            page2 = asyncio.run(gif_search.browse_gifs(page1["next_page_token"]))
        check("second page requests offset == the round-tripped token (2)",
              fake2.calls[0][1].get("offset") == 2, str(fake2.calls))
        check("second page has_more True (4 of 5 seen)", page2["has_more"] is True, str(page2))
        check("second page next_page_token advances to 4", page2["next_page_token"] == "4", str(page2))

        page3_raw = [_giphy_item("a5")]
        with _fake_httpx([_FakeResponse({"data": page3_raw, "pagination": {"total_count": 5}})]):
            page3 = asyncio.run(gif_search.browse_gifs(page2["next_page_token"]))
        check("last page has_more False once offset+len(page) reaches total_count",
              page3["has_more"] is False, str(page3))
        check("last page next_page_token is None (nothing further to fetch)",
              page3["next_page_token"] is None, str(page3))

        for bad_token in ("not-a-number", "-5", ""):
            with _fake_httpx([_FakeResponse({"data": page1_raw, "pagination": {"total_count": 5}})]) as fake_bad:
                asyncio.run(gif_search.browse_gifs(bad_token))
            check(f"malformed/invalid caller-supplied page_token {bad_token!r} degrades to offset 0, "
                  "never errors (a bad token means 'start over', not a 500)",
                  fake_bad.calls[0][1].get("offset") == 0, str(fake_bad.calls))


# ── 2. browse_gifs (Tenor): cursor pagination normalization ────────────────

def test_browse_gifs_tenor_normalizes_cursor_pagination():
    print("\n=== 2. browse_gifs (Tenor): opaque cursor passed straight through "
          "unparsed; has_more requires a truthy cursor AND a non-empty page ===")
    with _configured_provider("tenor", limit=2):
        page1_raw = [_tenor_item("t1"), _tenor_item("t2")]
        with _fake_httpx([_FakeResponse({"results": page1_raw, "next": "cursor-abc"})]) as fake:
            page1 = asyncio.run(gif_search.browse_gifs(None))
        check("first page sends no 'pos' param at all", "pos" not in fake.calls[0][1], str(fake.calls))
        check("first page sends limit == GIF_SEARCH_RESULT_LIMIT", fake.calls[0][1].get("limit") == 2, str(fake.calls))
        check("first page item shape matches search's _shape_tenor exactly",
              page1["results"] == gif_search._shape_tenor(page1_raw), str(page1))
        check("first page has_more True, next_page_token passed straight through from provider's 'next'",
              page1["has_more"] is True and page1["next_page_token"] == "cursor-abc", str(page1))

        page2_raw = [_tenor_item("t3")]
        with _fake_httpx([_FakeResponse({"results": page2_raw, "next": ""})]) as fake2:
            page2 = asyncio.run(gif_search.browse_gifs(page1["next_page_token"]))
        check("second page round-trips the opaque cursor back as 'pos', unparsed",
              fake2.calls[0][1].get("pos") == "cursor-abc", str(fake2.calls))
        check("provider omitting 'next' (last page) -> has_more False, next_page_token None",
              page2["has_more"] is False and page2["next_page_token"] is None, str(page2))

        with _fake_httpx([_FakeResponse({"results": [], "next": "still-has-a-token"})]):
            page3 = asyncio.run(gif_search.browse_gifs("cursor-abc"))
        check("a provider 'next' cursor paired with a zero-result page still degrades to "
              "has_more=False (never offers a 'load more' that would fetch nothing)",
              page3["has_more"] is False and page3["next_page_token"] is None, str(page3))


# ── 3. Cross-provider: empty response, provider failure, unconfigured ──────

def test_browse_gifs_empty_provider_response():
    print("\n=== 3. browse_gifs: an empty provider result set degrades to an empty, "
          "non-paginated response for both providers ===")
    with _configured_provider("giphy", limit=2):
        with _fake_httpx([_FakeResponse({"data": [], "pagination": {"total_count": 0}})]):
            page = asyncio.run(gif_search.browse_gifs(None))
        check("giphy empty page -> empty results", page["results"] == [], str(page))
        check("giphy empty page -> has_more False", page["has_more"] is False, str(page))
        check("giphy empty page -> next_page_token None", page["next_page_token"] is None, str(page))

    with _configured_provider("tenor", limit=2):
        with _fake_httpx([_FakeResponse({"results": [], "next": None})]):
            page = asyncio.run(gif_search.browse_gifs(None))
        check("tenor empty page -> empty results", page["results"] == [], str(page))
        check("tenor empty page -> has_more False", page["has_more"] is False, str(page))
        check("tenor empty page -> next_page_token None", page["next_page_token"] is None, str(page))


def test_browse_gifs_provider_failure_raises_GifSearchError():
    print("\n=== 3-cont. browse_gifs: a provider-side failure raises GifSearchError "
          "(never a raw exception, never a silently-empty page) ===")
    with _configured_provider("giphy", limit=2):
        with _fake_httpx([RuntimeError("connection reset")]):
            try:
                asyncio.run(gif_search.browse_gifs(None))
                check("a provider network failure raises GifSearchError", False, "did not raise")
            except gif_search.GifSearchError:
                check("a provider network failure raises GifSearchError", True)
            except Exception as e:  # noqa: BLE001 -- exactly what must NOT happen
                check("a provider network failure raises GifSearchError", False,
                      f"raised {type(e).__name__} instead: {e}")


def test_browse_gifs_config_error_when_unconfigured():
    print("\n=== 3-cont. browse_gifs: unconfigured GIF search raises GifConfigError, "
          "mirroring search_gifs's existing precedent ===")
    saved_provider = gif_search.GIF_PROVIDER
    saved_key = gif_search._GIF_PROVIDER_API_KEY
    try:
        gif_search.GIF_PROVIDER = "giphy"
        gif_search._GIF_PROVIDER_API_KEY = ""
        try:
            asyncio.run(gif_search.browse_gifs(None))
            check("browse_gifs propagates GifConfigError when unconfigured "
                  "(not silently degraded to an empty page)", False, "did not raise")
        except gif_search.GifConfigError:
            check("browse_gifs propagates GifConfigError when unconfigured "
                  "(not silently degraded to an empty page)", True)
    finally:
        gif_search.GIF_PROVIDER = saved_provider
        gif_search._GIF_PROVIDER_API_KEY = saved_key


# ── 4. Route: GET /message/gif-search ───────────────────────────────────────

RATE_LIMIT_BUDGET = 30
_budget_used = [0]


def _hit_gif_search(client, token=None, **params):
    r = client.get("/message/gif-search", params=params, headers=cookie_header(token))
    _budget_used[0] += 1
    return r


def test_route_requires_auth_for_browse(client):
    print("\n=== 4. Route: browse mode (blank/absent q) is auth-gated exactly like "
          "search -- 401 unauthenticated ===")
    # Not counted against `_budget_used`: get_current_user's Depends() raises
    # before the rate-limited endpoint function body ever runs, so slowapi's
    # `@limiter.limit` decorator (which wraps that function) never fires and
    # this request doesn't consume any of the shared 30/minute budget --
    # confirmed empirically (see this task's testing-gate notes) rather than
    # assumed, since it's easy to get backwards.
    r = client.get("/message/gif-search")
    check("no session cookie -> 401 even for the default-browse (blank q) path",
          r.status_code == 401, f"{r.status_code} {r.text}")


def test_route_blank_q_triggers_browse(client, token):
    print("\n=== 4-cont. Route: blank/absent q triggers browse_gifs (not search_gifs); "
          "response envelope carries next_page_token/has_more ===")
    orig_browse = messaging_module.browse_gifs
    try:
        calls = []

        async def fake_browse(page_token=None):
            calls.append(page_token)
            return {
                "results": [{"id": "b1", "url": "https://example.com/b1.gif",
                             "preview_url": "https://example.com/b1-small.gif", "width": 100, "height": 80}],
                "next_page_token": "next-1", "has_more": True,
            }
        messaging_module.browse_gifs = fake_browse

        r = _hit_gif_search(client, token=token)
        check("absent q -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
        check("absent q calls browse_gifs with page_token=None", calls == [None], str(calls))
        check("browse response envelope carries results/next_page_token/has_more",
              r.json() == {
                  "results": [{"id": "b1", "url": "https://example.com/b1.gif",
                               "preview_url": "https://example.com/b1-small.gif", "width": 100, "height": 80}],
                  "next_page_token": "next-1", "has_more": True,
              }, r.text)

        r2 = _hit_gif_search(client, token=token, q="")
        check("explicit empty q='' also triggers browse (not a search for the empty string)",
              r2.status_code == 200 and calls[-1] is None, str((r2.status_code, calls)))
    finally:
        messaging_module.browse_gifs = orig_browse


def test_route_passes_page_token_through(client, token):
    print("\n=== 4-cont. Route: page_token query param round-trips to browse_gifs unmodified ===")
    orig_browse = messaging_module.browse_gifs
    try:
        seen = []

        async def fake_browse(page_token=None):
            seen.append(page_token)
            return {"results": [], "next_page_token": None, "has_more": False}
        messaging_module.browse_gifs = fake_browse

        r = _hit_gif_search(client, token=token, page_token="opaque-cursor-xyz")
        check("page_token query param round-trips to browse_gifs unmodified",
              seen == ["opaque-cursor-xyz"], str(seen))
        check("200 on a valid page_token request", r.status_code == 200, f"{r.status_code} {r.text}")
    finally:
        messaging_module.browse_gifs = orig_browse


def test_route_nonempty_q_ignores_browse_and_page_token(client, token):
    print("\n=== 4-cont. Route: a non-empty q calls search_gifs (never browse_gifs), ignores "
          "page_token, and returns exactly {'results': [...]} -- the pre-existing search "
          "contract gains no new keys ===")
    orig_search = messaging_module.search_gifs
    orig_browse = messaging_module.browse_gifs
    try:
        browse_calls = []

        async def fake_browse(page_token=None):
            browse_calls.append(page_token)
            return {"results": [], "next_page_token": None, "has_more": False}

        async def fake_search(query):
            return [{"id": "s1", "url": "https://example.com/s1.gif",
                     "preview_url": "https://example.com/s1-small.gif", "width": 50, "height": 50}]
        messaging_module.browse_gifs = fake_browse
        messaging_module.search_gifs = fake_search

        r = _hit_gif_search(client, token=token, q="cat", page_token="should-be-ignored")
        check("non-empty q -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
        check("non-empty q never calls browse_gifs", browse_calls == [], str(browse_calls))
        check("search response shape is exactly {'results': [...]} -- no next_page_token/"
              "has_more leaking into the pre-existing search contract",
              set(r.json().keys()) == {"results"}, str(r.json()))
    finally:
        messaging_module.search_gifs = orig_search
        messaging_module.browse_gifs = orig_browse


def test_route_error_mapping_for_browse(client, token):
    print("\n=== 4-cont. Route: browse_gifs errors map exactly like search_gifs's already do "
          "-- 503 config, 502 provider ===")
    orig_browse = messaging_module.browse_gifs
    try:
        async def fake_config_error(page_token=None):
            raise gif_search.GifConfigError("GIF search is not configured: missing GIF_PROVIDER_API_KEY")
        messaging_module.browse_gifs = fake_config_error
        r = _hit_gif_search(client, token=token)
        check("unconfigured browse -> 503 (not 500, not a raw config error leaked to client)",
              r.status_code == 503, f"{r.status_code} {r.text}")
        check("503 body never echoes the raw config-error text", "GIF_PROVIDER_API_KEY" not in r.text, r.text)

        async def fake_provider_error(page_token=None):
            raise gif_search.GifSearchError("GIF provider request failed: 500 Internal Server Error")
        messaging_module.browse_gifs = fake_provider_error
        r = _hit_gif_search(client, token=token)
        check("provider failure during browse -> 502, distinct from the 503 config case",
              r.status_code == 502, f"{r.status_code} {r.text}")
    finally:
        messaging_module.browse_gifs = orig_browse


def test_route_rate_limit_shared_budget(client, token):
    print("\n=== 4-cont. Route: default-browse shares the SAME 30/minute per-IP limiter as "
          "search (no new/looser trust boundary) -- budget exhausted -> 429 ===")
    remaining = RATE_LIMIT_BUDGET - _budget_used[0]
    check("sanity: some rate-limit budget remains for this test to exhaust "
          "(if this is <= 0, an earlier test already consumed the whole window)",
          remaining > 0, str(remaining))
    orig_browse = messaging_module.browse_gifs
    try:
        async def fake_browse(page_token=None):
            return {"results": [], "next_page_token": None, "has_more": False}
        messaging_module.browse_gifs = fake_browse

        codes = [_hit_gif_search(client, token=token).status_code for _ in range(remaining + 1)]
        check(f"exactly the {remaining} remaining requests in the window succeed (200)",
              codes[:remaining].count(200) == remaining, str(codes))
        check("the request beyond the shared 30/minute budget is rate-limited (429)",
              codes[remaining] == 429, str(codes))
    finally:
        messaging_module.browse_gifs = orig_browse


# ── 5. Regression: existing search_gifs test file still passes ─────────────

def test_existing_gif_search_tests_still_pass():
    print("\n=== 5. Regression: test_messaging_attachments.py (search_gifs's route/shaping "
          "contract) still passes unmodified, run as its own subprocess/process ===")
    result = subprocess.run(
        [sys.executable, "tests/test_messaging_attachments.py"],
        cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        capture_output=True, text=True, timeout=120,
    )
    check("test_messaging_attachments.py (search_gifs's existing contract) still exits 0",
          result.returncode == 0,
          f"exit={result.returncode}\nSTDOUT tail:\n{result.stdout[-3000:]}\nSTDERR tail:\n{result.stderr[-2000:]}")


def main():
    test_browse_gifs_giphy_normalizes_offset_pagination()
    test_browse_gifs_tenor_normalizes_cursor_pagination()
    test_browse_gifs_empty_provider_response()
    test_browse_gifs_provider_failure_raises_GifSearchError()
    test_browse_gifs_config_error_when_unconfigured()

    with TestClient(main_module.app) as client:
        test_route_requires_auth_for_browse(client)
        uid, token = signup(client, "gifbrowse")
        try:
            test_route_blank_q_triggers_browse(client, token)
            test_route_passes_page_token_through(client, token)
            test_route_nonempty_q_ignores_browse_and_page_token(client, token)
            test_route_error_mapping_for_browse(client, token)
            test_route_rate_limit_shared_budget(client, token)
        finally:
            cleanup_users(uid)

    test_existing_gif_search_tests_still_pass()

    print(f"\n{'='*60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        sys.exit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()

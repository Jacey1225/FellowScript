"""Tests for the 2026-10-01 price-cut tooling (task 20261001-subscription-price-cut):
api/scripts/stripe_price_migration.py, api/scripts/apple_price_and_promos.py, and
the drift check between the server price table and the web / iOS mirrors.

No network: Stripe uses a fake injectable module, ASC uses httpx.MockTransport.

Run:  cd api && ../.venv/bin/python -m pytest tests/test_price_cut_scripts.py -q
"""

import _pathfix  # noqa: F401

import http.client
import json
import os
import re
import sys

import httpx
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import apple_price_and_promos as ap  # noqa: E402
import stripe_price_migration as sm  # noqa: E402
from schemas.subscription import GROUP_PRICE_CENTS  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
NEW = {1: 499, 2: 810, 3: 1215, 4: 1620, 5: 2025, 6: 2430, 7: 2835, 8: 3240}


# ---------------------------------------------------------------- Stripe script

def mk_sub(sid, n, amount, status="active", **over):
    sub = {"id": sid, "status": status, "metadata": {"member_count": str(n)},
           "items": {"data": [{"id": f"si_{sid}", "price": {
               "currency": "usd", "unit_amount": amount, "product": "prod_x",
               "recurring": {"interval": "month", "interval_count": 1}}}]}}
    sub.update(over)
    return sub


class FakeStripe:
    def __init__(self, subs, fail_on=None):
        self.subs, self.calls, self.fail_on = subs, [], fail_on
        outer = self

        class Subscription:
            @staticmethod
            def list(**kw):
                outer.list_kw = kw
                return list(outer.subs)

            @staticmethod
            def modify(sid, **kw):
                if sid == outer.fail_on:
                    raise RuntimeError("boom secret-ish")
                outer.calls.append((sid, kw))
                for s in outer.subs:  # reflect the change so re-runs are no-ops
                    if s["id"] == sid:
                        s["items"]["data"][0]["price"]["unit_amount"] = kw["items"][0]["price_data"]["unit_amount"]
        self.Subscription = Subscription


def test_tables_pinned():
    assert GROUP_PRICE_CENTS == NEW
    assert sm.OLD_PRICE_CENTS == {1: 1000, 2: 1799, 3: 2699, 4: 3599, 5: 4499, 6: 5399, 7: 6299, 8: 7199}


def test_classify():
    assert sm.classify(1799, 2) == sm.MIGRATE
    assert sm.classify(810, 2) == sm.NOOP
    assert sm.classify(1234, 2) == sm.SKIP


def test_stripe_dry_run_makes_no_writes():
    fs = FakeStripe([mk_sub("s1", 2, 1799)])
    logs = []
    counts = sm.run(fs, apply=False, log=logs.append)
    assert fs.calls == []
    assert counts["migrate"] == 1 and counts["migrated"] == 0
    assert logs[0].startswith("WOULD")


def test_stripe_apply_proration_none_and_idempotent():
    subs = [mk_sub(f"s{n}", n, sm.OLD_PRICE_CENTS[n]) for n in range(1, 9)]
    fs = FakeStripe(subs)
    c1 = sm.run(fs, apply=True, log=lambda *_: None)
    assert c1["migrated"] == 8 and c1["error"] == 0
    for sid, kw in fs.calls:
        n = int(sid[1:])
        assert kw["proration_behavior"] == "none"
        pd = kw["items"][0]["price_data"]
        assert pd["unit_amount"] == NEW[n] and pd["currency"] == "usd"
        assert pd["recurring"] == {"interval": "month"} and pd["product"] == "prod_x"
        assert kw["items"][0]["id"] == f"si_{sid}"
        assert kw["idempotency_key"] == f"price-cut-20261001:{sid}:{NEW[n]}"
    fs.calls.clear()
    c2 = sm.run(fs, apply=True, log=lambda *_: None)
    assert fs.calls == [] and c2["migrated"] == 0 and c2["noop"] == 8


def test_stripe_skips_unknown_shapes_and_continues_after_error():
    bad_items = mk_sub("multi", 2, 1799)
    bad_items["items"]["data"].append(dict(bad_items["items"]["data"][0]))
    eur = mk_sub("eur", 2, 1799)
    eur["items"]["data"][0]["price"]["currency"] = "eur"
    yearly = mk_sub("yr", 2, 1799)
    yearly["items"]["data"][0]["price"]["recurring"]["interval"] = "year"
    custom = mk_sub("custom", 2, 1500)
    nometa = mk_sub("nometa", 2, 1799, metadata={})
    canceled = mk_sub("gone", 2, 1799, status="canceled")
    failing, good = mk_sub("fail", 3, 2699), mk_sub("ok", 3, 2699)
    fs = FakeStripe([bad_items, eur, yearly, custom, nometa, canceled, failing, good], fail_on="fail")
    logs = []
    c = sm.run(fs, apply=True, log=logs.append)
    assert [sid for sid, _ in fs.calls] == ["ok"]
    assert c["skip"] == 6 and c["error"] == 1 and c["migrated"] == 1
    assert not any("secret-ish" in l for l in logs)  # exception text is not logged
    assert not any("gone" in l for l in logs)


def test_stripe_main_guards(monkeypatch):
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_live_abc")
    with pytest.raises(SystemExit) as e:
        sm.main(["--apply"])
    assert "--confirm-live" in str(e.value)
    monkeypatch.setenv("STRIPE_SECRET_KEY", "garbage")
    with pytest.raises(SystemExit):
        sm.main([])


def test_stripe_main_dry_run_default_and_no_key_echo(monkeypatch, capsys):
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_SUPERSECRET")
    fs = FakeStripe([mk_sub("s1", 2, 1799)])
    import types
    monkeypatch.setitem(sys.modules, "stripe", types.SimpleNamespace(Subscription=fs.Subscription, api_key=None))
    assert sm.main([]) == 0
    out = capsys.readouterr().out
    assert "DRY-RUN" in out and "SUPERSECRET" not in out and fs.calls == []


def test_db_sql_matches_table():
    sql = sm.db_backfill_sql()
    for n, c in NEW.items():
        assert f"WHEN {n} THEN {c}" in sql
    assert "price_cents <>" in sql  # idempotent


# ----------------------------------------------------------------- Apple script

def test_rounding_and_targets():
    assert ap.round5_half_up(1799 * 0.45) == 810
    assert ap.target_sub_cents(1, 999) == 499
    # Table from the code (old values) reproduces the new table exactly.
    for n in range(2, 9):
        assert ap.target_sub_cents(n, sm.OLD_PRICE_CENTS[n]) == NEW[n]


def test_snap_nearest_tie_lower():
    pts = [("a", 400), ("b", 500), ("c", 600)]
    assert ap.snap(520, pts) == ("b", 500)
    assert ap.snap(450, pts) == ("a", 400)  # tie -> lower
    with pytest.raises(ValueError):
        ap.snap(1, [])


def test_offer_codes():
    assert ap.offer_code(1) == "invite_reward_50_v2"
    assert [ap.offer_code(n) for n in (2, 8)] == ["invite_reward_50_v2_2", "invite_reward_50_v2_8"]
    assert ap._LEGACY_RE.match("invite_reward_50") and ap._LEGACY_RE.match("invite_reward_50_8")
    assert not ap._LEGACY_RE.match("invite_reward_50_v2")


def test_client_blocks_writes_without_apply():
    calls = []
    c = ap.AscClient(httpx.Client(transport=httpx.MockTransport(lambda r: calls.append(r) or httpx.Response(200, json={}))), "t")
    for fn in (lambda: c.post("/v1/x", {}), lambda: c.delete("/v1/x")):
        with pytest.raises(PermissionError):
            fn()
    assert calls == []


def test_client_retries_get_but_not_post(monkeypatch):
    monkeypatch.setattr(ap, "_sleep", lambda *_: None)
    n = {"get": 0, "post": 0}

    def handler(req):
        if req.method == "GET":
            n["get"] += 1
            if n["get"] == 1:
                raise http.client.IncompleteRead(b"")
            if n["get"] == 2:
                return httpx.Response(500, json={})
            return httpx.Response(200, json={"data": [1]})
        n["post"] += 1
        return httpx.Response(500, json={"errors": [{"title": "Nope"}]})

    c = ap.AscClient(httpx.Client(transport=httpx.MockTransport(handler)), "tok-SECRET", allow_writes=True)
    assert c.get_all("/v1/x")[0] == [1] and n["get"] == 3
    with pytest.raises(RuntimeError) as e:
        c.post("/v1/y", {})
    assert n["post"] == 1 and "SECRET" not in str(e.value) and "Nope" in str(e.value)


# A tiny fake ASC covering the endpoints the planner uses.
TERRS = ["USA", "GBR", "FRA"]


def fake_asc(sub_ids_prices, existing_offers=None, drop_eq=None, writes=None):
    """sub_ids_prices: {sub_id: {territory: price point id currently set}}"""
    existing_offers = existing_offers or {}
    writes = writes if writes is not None else []
    sid_to_cents = {}

    def handler(req):
        path, m = req.url.path, req.method
        if m != "GET":
            writes.append((m, path, json.loads(req.content) if req.content else None))
            return httpx.Response(201, json={})
        mm = re.match(r"/v1/subscriptions/(\d+)/pricePoints", path)
        if mm:
            return httpx.Response(200, json={"data": [
                {"id": f"{mm.group(1)}-pp{c}", "attributes": {"customerPrice": f"{c / 100:.2f}"}}
                for c in (200, 250, 400, 405, 500, 810, 1215, 1620, 2025, 2430, 2835, 3240, 4000, 8100)]})
        mm = re.match(r"/v1/subscriptions/(\d+)/prices", path)
        if mm:
            cur = sub_ids_prices[mm.group(1)]
            return httpx.Response(200, json={"data": [
                {"id": f"pr{t}", "attributes": {"startDate": None}, "relationships": {
                    "territory": {"data": {"id": t}},
                    "subscriptionPricePoint": {"data": {"id": pp}}}} for t, pp in cur.items()]})
        mm = re.match(r"/v1/subscriptionPricePoints/(.+)/equalizations", path)
        if mm:
            base = mm.group(1)
            return httpx.Response(200, json={"data": [
                {"id": f"{base}-{t}", "attributes": {"customerPrice": "1.00"},
                 "relationships": {"territory": {"data": {"id": t}}}}
                for t in TERRS if t != "USA" and t != drop_eq]})
        mm = re.match(r"/v1/subscriptions/(\d+)/promotionalOffers", path)
        if mm:
            return httpx.Response(200, json={"data": existing_offers.get(mm.group(1), [])})
        mm = re.match(r"/v1/subscriptionPromotionalOffers/(.+)/prices", path)
        if mm:
            return httpx.Response(200, json={"data": [
                {"relationships": {"territory": {"data": {"id": t}},
                                   "subscriptionPricePoint": {"data": {"id": pp}}}}
                for t, pp in existing_offers.get("prices:" + mm.group(1), {}).items()]})
        return httpx.Response(404, json={})
    return httpx.Client(transport=httpx.MockTransport(handler)), writes


def state(old_cents_pp=None):
    return {sid: {t: f"{sid}-old" for t in TERRS} for sid in ap.SUBSCRIPTION_IDS.values()}


CURRENT = {p: sm.OLD_PRICE_CENTS[i] for i, p in enumerate(ap.PRODUCT_ORDER, start=1)}


def args(**kw):
    ns = dict(apply=False, preserve_existing=False, allow_missing_territories=False,
              tier_prices=CURRENT, version=2, price_source="current", delete_old=False,
              start_date="2026-10-03")
    ns.update(kw)
    import argparse
    return argparse.Namespace(**ns)


def test_plan_prices_covers_every_territory():
    http_c, _ = fake_asc(state())
    rows = ap.plan_prices(ap.AscClient(http_c, "t"), CURRENT)
    assert len(rows) == 8
    for r in rows:
        assert sorted(r["territories"]) == sorted(TERRS)  # USA + equalized GBR, FRA
        assert r["missing"] == [] and sorted(r["todo"]) == sorted(TERRS)
    assert rows[0]["snapped"] == 500 and rows[0]["target"] == 499  # tier1 pinned, snapped to 5.00 point
    assert [r["target"] for r in rows] == [NEW[i] for i in range(1, 9)]


def test_set_prices_dry_run_no_writes_and_apply_posts_per_territory(monkeypatch):
    monkeypatch.setattr(ap, "_sleep", lambda *_: None)
    http_c, writes = fake_asc(state())
    logs = []
    assert ap.cmd_set_prices(ap.AscClient(http_c, "t"), args(), logs.append) == 0
    assert writes == [] and any(l.startswith("WOULD") for l in logs)

    http_c, writes = fake_asc(state())
    assert ap.cmd_set_prices(ap.AscClient(http_c, "t", allow_writes=True), args(apply=True), lambda *_: None) == 0
    assert len(writes) == 8 * len(TERRS)
    for m, path, body in writes:
        assert m == "POST" and path == "/v1/subscriptionPrices"
        assert body["data"]["attributes"] == {"startDate": "2026-10-03", "preserveCurrentPrice": False}
    terrs = {w[2]["data"]["relationships"]["territory"]["data"]["id"] for w in writes}
    assert terrs == set(TERRS)


def test_set_prices_idempotent_when_already_on_target(monkeypatch):
    monkeypatch.setattr(ap, "_sleep", lambda *_: None)
    http_c, _ = fake_asc(state())
    rows = ap.plan_prices(ap.AscClient(http_c, "t"), CURRENT)
    st = {ap.SUBSCRIPTION_IDS[r["product"]]: dict(r["territories"]) for r in rows}
    http_c, writes = fake_asc(st)
    logs = []
    assert ap.cmd_set_prices(ap.AscClient(http_c, "t", allow_writes=True), args(apply=True), logs.append) == 0
    assert writes == [] and sum(l.startswith("NOOP") for l in logs) == 8


def test_set_prices_preserve_flag(monkeypatch):
    monkeypatch.setattr(ap, "_sleep", lambda *_: None)
    http_c, writes = fake_asc(state())
    ap.cmd_set_prices(ap.AscClient(http_c, "t", allow_writes=True), args(apply=True, preserve_existing=True), lambda *_: None)
    assert all(w[2]["data"]["attributes"]["preserveCurrentPrice"] is True for w in writes)


def test_missing_equalization_aborts_apply(monkeypatch):
    monkeypatch.setattr(ap, "_sleep", lambda *_: None)
    http_c, writes = fake_asc(state(), drop_eq="FRA")
    logs = []
    rc = ap.cmd_set_prices(ap.AscClient(http_c, "t", allow_writes=True), args(apply=True), logs.append)
    assert rc == 2 and writes == [] and any("MISSING-EQUALIZATION" in l for l in logs)
    # dry-run only flags, does not abort
    http_c, _ = fake_asc(state(), drop_eq="FRA")
    assert ap.cmd_set_prices(ap.AscClient(http_c, "t"), args(), lambda *_: None) == 0
    # explicit override proceeds
    http_c, writes = fake_asc(state(), drop_eq="FRA")
    rc = ap.cmd_set_prices(ap.AscClient(http_c, "t", allow_writes=True),
                           args(apply=True, allow_missing_territories=True), lambda *_: None)
    assert rc == 0 and len(writes) == 8 * 2


NEWPRICES = {p: NEW[i] for i, p in enumerate(ap.PRODUCT_ORDER, start=1)}


def test_promos_dry_run_then_apply_payload_and_env_json():
    http_c, writes = fake_asc(state())
    logs = []
    assert ap.cmd_promos(ap.AscClient(http_c, "t"), args(tier_prices=NEWPRICES), logs.append) == 0
    assert writes == [] and sum(l.startswith("WOULD") for l in logs) == 8
    env = json.loads(logs[-1].split("APPLE_PROMO_OFFERS=", 1)[1])
    assert env["com.fellowscript.access.one"] == "invite_reward_50_v2"
    assert env["com.fellowscript.access.eight"] == "invite_reward_50_v2_8"
    assert len(env) == 8

    http_c, writes = fake_asc(state())
    assert ap.cmd_promos(ap.AscClient(http_c, "t", allow_writes=True),
                         args(apply=True, tier_prices=NEWPRICES), lambda *_: None) == 0
    assert len(writes) == 8 and all(m == "POST" for m, *_ in writes)
    body = writes[0][2]
    a = body["data"]["attributes"]
    assert a["offerMode"] == "PAY_UP_FRONT" and a["duration"] == "ONE_MONTH" and a["numberOfPeriods"] == 1
    assert len(body["included"]) == len(TERRS) == len(body["data"]["relationships"]["prices"]["data"])
    ids = [i["id"] for i in body["included"]]
    assert len(set(ids)) == len(ids)


def test_promo_price_is_half_of_new_tier_snapped():
    http_c, _ = fake_asc(state())
    rows = ap.plan_promos(ap.AscClient(http_c, "t"), NEWPRICES, 2)
    # fake grid has 2.00, 2.50, 4.00, 4.05, 5.00, 8.10, ...; 4.99/2=2.495 -> 2.50
    assert rows[0]["promo_cents"] == 250
    assert rows[1]["promo_cents"] == 405


def test_promos_idempotent_and_conflict():
    http_c, _ = fake_asc(state())
    rows = ap.plan_promos(ap.AscClient(http_c, "t"), NEWPRICES, 2)
    sid1 = ap.SUBSCRIPTION_IDS["com.fellowscript.access.one"]
    ok_offers = {sid1: [{"id": "off1", "attributes": {"offerCode": "invite_reward_50_v2"}}],
                 "prices:off1": dict(rows[0]["territories"])}
    http_c, writes = fake_asc(state(), existing_offers=ok_offers)
    rows2 = ap.plan_promos(ap.AscClient(http_c, "t"), NEWPRICES, 2)
    assert rows2[0]["state"] == "ok" and rows2[1]["state"] == "create"
    bad = dict(ok_offers, **{"prices:off1": {"USA": "wrong"}})
    http_c, writes = fake_asc(state(), existing_offers=bad)
    logs = []
    rc = ap.cmd_promos(ap.AscClient(http_c, "t", allow_writes=True), args(apply=True, tier_prices=NEWPRICES), logs.append)
    assert rc == 2 and any(l.startswith("CONFLICT") for l in logs)


def test_delete_old_refused_in_same_run_as_creation_and_works_later():
    legacy = {ap.SUBSCRIPTION_IDS[p]: [{"id": f"leg{i}", "attributes": {"offerCode": ap.offer_code(i + 1, 1).replace("_v1", "")}}]
              for i, p in enumerate(ap.PRODUCT_ORDER)}
    http_c, writes = fake_asc(state(), existing_offers=legacy)
    logs = []
    ap.cmd_promos(ap.AscClient(http_c, "t", allow_writes=True),
                  args(apply=True, delete_old=True, tier_prices=NEWPRICES), logs.append)
    assert not [w for w in writes if w[0] == "DELETE"]
    assert any(l.startswith("ABORT-DELETE") for l in logs)
    assert len([w for w in writes if w[0] == "POST"]) == 8

    # Later run: all v2 offers already exist and match -> legacy deleted.
    http_c, _ = fake_asc(state())
    rows = ap.plan_promos(ap.AscClient(http_c, "t"), NEWPRICES, 2)
    offers = {}
    for i, r in enumerate(rows):
        sid = ap.SUBSCRIPTION_IDS[r["product"]]
        offers[sid] = [{"id": f"leg{i}", "attributes": {"offerCode": "invite_reward_50" if i == 0 else f"invite_reward_50_{i + 1}"}},
                       {"id": f"new{i}", "attributes": {"offerCode": r["offer_code"]}}]
        offers[f"prices:new{i}"] = dict(r["territories"])
    http_c, writes = fake_asc(state(), existing_offers=offers)
    ap.cmd_promos(ap.AscClient(http_c, "t", allow_writes=True),
                  args(apply=True, delete_old=True, tier_prices=NEWPRICES), lambda *_: None)
    assert sorted(p for m, p, _ in writes if m == "DELETE") == sorted(
        f"/v1/subscriptionPromotionalOffers/leg{i}" for i in range(8))
    assert not [w for w in writes if w[0] == "POST"]


def test_main_requires_credentials(monkeypatch):
    monkeypatch.delenv("ASC_KEY_ID", raising=False)
    monkeypatch.delenv("ASC_ISSUER_ID", raising=False)
    with pytest.raises(SystemExit):
        ap.main(["plan-prices"])


def test_tier_prices_override_requires_all_products():
    with pytest.raises(SystemExit):
        ap.tier_current_prices(None, {"com.fellowscript.access.one": 1})


# ------------------------------------------------------------------ drift check

def _parse_js_table(text):
    m = re.search(r"GROUP_PRICE_CENTS\s*=\s*\{([^}]*)\}", text)
    return {int(k): int(v) for k, v in re.findall(r"(\d+)\s*:\s*(\d+)", m.group(1))}


def test_web_mirror_matches_server_table():
    with open(os.path.join(ROOT, "frontend/src/components/SubscriptionCard.jsx")) as f:
        assert _parse_js_table(f.read()) == GROUP_PRICE_CENTS


def test_ios_mirror_matches_server_table():
    with open(os.path.join(ROOT, "FellowScript/FellowScript/Account/AccountView+Subscription.swift")) as f:
        text = f.read()
    m = re.search(r"fallbackPriceCents[^=]*=\s*\[(.*?)\]", text, re.S)
    table = {int(k): int(v) for k, v in re.findall(r"(\d+)\s*:\s*(\d+)", m.group(1))}
    assert table == GROUP_PRICE_CENTS


def test_storekit_display_prices_match_server_table():
    with open(os.path.join(ROOT, "FellowScript/FellowScript/FellowScript.storekit")) as f:
        sk = json.load(f)
    words = ["one", "two", "three", "four", "five", "six", "seven", "eight"]
    found = {}

    def walk(o):
        if isinstance(o, dict):
            if o.get("productID", "").startswith("com.fellowscript.access.") and "displayPrice" in o:
                found[o["productID"].rsplit(".", 1)[1]] = round(float(o["displayPrice"]) * 100)
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(sk)
    assert {w: found.get(w) for w in words} == {w: GROUP_PRICE_CENTS[i] for i, w in enumerate(words, start=1)}


def test_set_prices_apply_requires_start_date_and_old_prices(monkeypatch):
    monkeypatch.setattr(ap, "_sleep", lambda *_: None)
    for kw in (dict(apply=True, start_date=None), dict(apply=True, tier_prices=None)):
        http_c, writes = fake_asc(state())
        logs = []
        rc = ap.cmd_set_prices(ap.AscClient(http_c, "t", allow_writes=True), args(**kw), logs.append)
        assert rc == 2 and writes == [] and any(l.startswith("ABORT") for l in logs)


if __name__ == "__main__":
    # CI runs every tests/test_*.py as a plain script; delegate to pytest (installed by the workflow).
    sys.exit(pytest.main([__file__, "-q"]))

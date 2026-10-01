"""App Store Connect price + promotional-offer tooling for the 2026-10-01 price
cut (task 20261001-subscription-price-cut).

NEVER run by build gates. The orchestrator/operator runs it by hand, dry-run
first. Run from the ``api/`` directory. Read-only commands:

    python scripts/apple_price_and_promos.py plan-prices
    python scripts/apple_price_and_promos.py promos                      # dry run
    python scripts/apple_price_and_promos.py promos --price-source planned

Write commands need an explicit ``--apply`` (the HTTP client itself refuses
any non-GET without it):

    python scripts/apple_price_and_promos.py set-prices --apply [--preserve-existing]
    python scripts/apple_price_and_promos.py promos --apply              # create v2 offers only
    python scripts/apple_price_and_promos.py promos --apply --delete-old  # AFTER server env updated

Auth (never printed): ASC_KEY_ID, ASC_ISSUER_ID, and the .p8 at ASC_KEY_PATH
(default ``~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8``).

Pricing rules
-------------
* Apple's prices legitimately differ from Stripe's (e.g. tier 4 is 36.99 on
  Apple vs 35.99 in the code/Stripe table). Targets are therefore computed from
  the ACTUAL current Apple USD price read via the API (or an explicit
  ``--tier-prices-json`` table), never from the server table:
  tier 1 = 4.99 (pinned), tiers 2-8 = round-half-up-to-5-cents(0.45 x current).
* A target is snapped to the NEAREST price point the subscription offers in
  USA; an exact tie goes to the LOWER point.
* Promo offers = pay-up-front, 1 month, at 50% of the (new) tier price, snapped
  the same way. Apple promo prices cannot be edited, so new VERSIONED offer
  codes are created (``invite_reward_50_v2``, ``invite_reward_50_v2_2`` ..
  ``_8``) and the legacy ones (``invite_reward_50``, ``invite_reward_50_2`` ..)
  are deleted only on a separate, later ``--delete-old`` run (after the server's
  APPLE_PROMO_OFFERS env has switched to the new codes, otherwise live signing
  of the old codes would break). Re-runs are no-ops.
* ALL territories: the subscriptions are priced in ~175 territories. For each
  tier the USA target price point is chosen as above, then ASC's equalizations
  of that point (GET /v1/subscriptionPricePoints/{id}/equalizations) give Apple's
  equivalent price point in every other territory. Prices (and promo-offer
  prices) are created for every territory the product is CURRENTLY priced in.
  A priced territory with no equalization is flagged; ``--apply`` refuses to
  run while any is flagged unless ``--allow-missing-territories``.
* ``set-prices`` posts one subscriptionPrices per territory with startDate null
  (immediate). ``preserveCurrentPrice`` false (default) moves existing
  subscribers to the new price; ``--preserve-existing`` keeps them on the old
  one. Re-runs skip territories already on the target price point.
"""

import argparse
import http.client
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

import httpx

BASE = "https://api.appstoreconnect.apple.com"
TERRITORY = "USA"
READ_RETRIES = 4
WRITE_PAUSE_S = 0.2  # polite pacing between territory writes
_sleep = time.sleep  # patched in tests

SUBSCRIPTION_IDS: dict[str, str] = {
    "com.fellowscript.access.one": "6795828952",
    "com.fellowscript.access.two": "6795808766",
    "com.fellowscript.access.three": "6795809564",
    "com.fellowscript.access.four": "6795810135",
    "com.fellowscript.access.five": "6795813799",
    "com.fellowscript.access.six": "6795814277",
    "com.fellowscript.access.seven": "6795814602",
    "com.fellowscript.access.eight": "6795815077",
}
PRODUCT_ORDER = list(SUBSCRIPTION_IDS)  # one..eight == member counts 1..8
TIER1_NEW_CENTS = 499
GROUP_RATIO = 0.45
OFFER_VERSION = 2
_LEGACY_RE = re.compile(r"^invite_reward_50(_[2-8])?$")


# ---- pure pricing logic -----------------------------------------------------

def round5_half_up(cents: float) -> int:
    """Round to the nearest 5 cents, halves up."""
    return int(cents / 5 + 0.5) * 5


def target_sub_cents(member_count: int, current_cents: int) -> int:
    """New Apple subscription price target before snapping."""
    if member_count == 1:
        return TIER1_NEW_CENTS
    return round5_half_up(current_cents * GROUP_RATIO)


def snap(target_cents: float, points: list[tuple[str, int]]) -> tuple[str, int]:
    """Nearest price point (id, cents); tie -> lower price."""
    if not points:
        raise ValueError("no price points to snap to")
    return min(points, key=lambda p: (abs(p[1] - target_cents), p[1]))


def offer_code(member_count: int, version: int = OFFER_VERSION) -> str:
    base = f"invite_reward_50_v{version}"
    return base if member_count == 1 else f"{base}_{member_count}"


def to_cents(customer_price: str) -> int:
    return int(round(float(customer_price) * 100))


# ---- ASC client ---------------------------------------------------------------

class AscClient:
    """Minimal ASC client. Writes are refused unless ``allow_writes``."""

    def __init__(self, http: httpx.Client, token: str, allow_writes: bool = False):
        self.http, self.token, self.allow_writes = http, token, allow_writes

    def _req(self, method: str, url: str, **kw):
        if method != "GET" and not self.allow_writes:
            raise PermissionError("write blocked: run with --apply")
        attempts = READ_RETRIES if method == "GET" else 1
        for attempt in range(1, attempts + 1):
            try:
                r = self.http.request(method, url,
                                      headers={"Authorization": f"Bearer {self.token}"}, **kw)
            except (http.client.IncompleteRead, httpx.TransportError) as exc:
                # ASC sometimes truncates large pages; GETs are safe to retry.
                if attempt == attempts:
                    raise RuntimeError(f"ASC {method} {url.split('?')[0]} transport error: "
                                       f"{type(exc).__name__}") from None
                _sleep(attempt)
                continue
            if (r.status_code == 429 or (method == "GET" and r.status_code >= 500)) and attempt < attempts:
                _sleep(attempt * 2)
                continue
            break
        if r.status_code >= 400:
            # status + ASC error titles only; never the request headers/token.
            titles = []
            try:
                titles = [e.get("title", "") for e in r.json().get("errors", [])]
            except Exception:
                pass
            raise RuntimeError(f"ASC {method} {url.split('?')[0]} -> {r.status_code} {titles}")
        return r.json() if r.content else {}

    def get_all(self, path: str, params: dict | None = None):
        """GET following links.next; returns (data, included)."""
        data, included = [], []
        url, p = (path if path.startswith("http") else BASE + path), params
        while url:
            body = self._req("GET", url, params=p)
            data += body.get("data", [])
            included += body.get("included", [])
            url, p = (body.get("links") or {}).get("next"), None
        return data, included

    def post(self, path: str, payload: dict):
        return self._req("POST", BASE + path, json=payload)

    def delete(self, path: str):
        return self._req("DELETE", BASE + path)


def make_token(key_id: str, issuer: str, key_path: str) -> str:
    import jwt
    with open(key_path, "rb") as fh:
        key = fh.read()
    now = int(time.time())
    return jwt.encode({"iss": issuer, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})


# ---- ASC reads ----------------------------------------------------------------

def price_points(c: AscClient, sub_id: str) -> list[tuple[str, int]]:
    data, _ = c.get_all(f"/v1/subscriptions/{sub_id}/pricePoints",
                        {"filter[territory]": TERRITORY, "limit": 8000})
    return [(d["id"], to_cents(d["attributes"]["customerPrice"])) for d in data
            if d["attributes"].get("customerPrice") is not None]


def current_price_cents(c: AscClient, sub_id: str) -> int:
    """Latest-starting USA price entry (includes a scheduled future one)."""
    data, included = c.get_all(f"/v1/subscriptions/{sub_id}/prices",
                               {"filter[territory]": TERRITORY, "include": "subscriptionPricePoint",
                                "limit": 200})
    cents_by_pp = {i["id"]: to_cents(i["attributes"]["customerPrice"]) for i in included
                   if i.get("type") == "subscriptionPricePoints"}
    best = None
    for d in data:
        pp = ((d.get("relationships") or {}).get("subscriptionPricePoint") or {}).get("data") or {}
        if pp.get("id") not in cents_by_pp:
            continue
        key = (d["attributes"].get("startDate") or "0000-00-00")
        if best is None or key > best[0]:
            best = (key, cents_by_pp[pp["id"]])
    if best is None:
        raise RuntimeError(f"no USA price found for subscription {sub_id}")
    return best[1]


def list_offers(c: AscClient, sub_id: str) -> list[dict]:
    data, _ = c.get_all(f"/v1/subscriptions/{sub_id}/promotionalOffers", {"limit": 200})
    return data


def offer_price_points(c: AscClient, offer_id: str) -> dict[str, str]:
    """{territory: price point id} for an existing promotional offer."""
    data, _ = c.get_all(f"/v1/subscriptionPromotionalOffers/{offer_id}/prices",
                        {"include": "subscriptionPricePoint,territory", "limit": 200})
    out = {}
    for d in data:
        rel = d.get("relationships") or {}
        terr = ((rel.get("territory") or {}).get("data") or {}).get("id")
        pp = ((rel.get("subscriptionPricePoint") or {}).get("data") or {}).get("id")
        if terr and pp:
            out[terr] = pp
    return out


def equalizations(c: AscClient, price_point_id: str) -> dict[str, tuple[str, int]]:
    """{territory: (price point id, cents)} equivalent to ``price_point_id`` (excludes its own)."""
    data, _ = c.get_all(f"/v1/subscriptionPricePoints/{price_point_id}/equalizations",
                        {"include": "territory", "limit": 200})
    out = {}
    for d in data:
        terr = (((d.get("relationships") or {}).get("territory") or {}).get("data") or {}).get("id")
        cp = d["attributes"].get("customerPrice")
        if terr and cp is not None:
            out[terr] = (d["id"], to_cents(cp))
    return out


def priced_territories(c: AscClient, sub_id: str) -> dict[str, str]:
    """{territory: current price point id}; latest-starting entry per territory
    (includes a scheduled future one)."""
    data, _ = c.get_all(f"/v1/subscriptions/{sub_id}/prices",
                        {"include": "subscriptionPricePoint,territory", "limit": 200})
    best: dict[str, tuple[str, str]] = {}
    for d in data:
        rel = d.get("relationships") or {}
        terr = ((rel.get("territory") or {}).get("data") or {}).get("id")
        pp = ((rel.get("subscriptionPricePoint") or {}).get("data") or {}).get("id")
        if not terr or not pp:
            continue
        key = d["attributes"].get("startDate") or "0000-00-00"
        if terr not in best or key > best[terr][0]:
            best[terr] = (key, pp)
    return {t: v[1] for t, v in best.items()}


def territory_plan(c: AscClient, sub_id: str, usa_pp: str) -> tuple[dict[str, str], list[str], list[str]]:
    """(territory -> target price point id, missing equalization, extra equalizations not priced).

    Covers every territory the subscription is currently priced in."""
    priced = priced_territories(c, sub_id)
    eq = equalizations(c, usa_pp)
    targets = {TERRITORY: usa_pp}
    missing = []
    for terr in sorted(priced):
        if terr == TERRITORY:
            continue
        if terr in eq:
            targets[terr] = eq[terr][0]
        else:
            missing.append(terr)
    extra = sorted(set(eq) - set(priced))
    return targets, missing, extra


# ---- planning -----------------------------------------------------------------

def tier_current_prices(c: AscClient, override: dict | None) -> dict[str, int]:
    if override is not None:
        missing = set(PRODUCT_ORDER) - set(override)
        if missing:
            raise SystemExit(f"--tier-prices-json missing products: {sorted(missing)}")
        return {p: int(override[p]) for p in PRODUCT_ORDER}
    return {p: current_price_cents(c, SUBSCRIPTION_IDS[p]) for p in PRODUCT_ORDER}


def plan_prices(c: AscClient, current: dict[str, int]) -> list[dict]:
    rows = []
    for n, pid in enumerate(PRODUCT_ORDER, start=1):
        pts = price_points(c, SUBSCRIPTION_IDS[pid])
        target = target_sub_cents(n, current[pid])
        pp_id, got = snap(target, pts)
        targets, missing, extra = territory_plan(c, SUBSCRIPTION_IDS[pid], pp_id)
        have = priced_territories(c, SUBSCRIPTION_IDS[pid])
        rows.append({"product": pid, "members": n, "current": current[pid], "target": target,
                     "price_point": pp_id, "snapped": got, "territories": targets,
                     "missing": missing, "extra": extra,
                     "todo": {t: pp for t, pp in targets.items() if have.get(t) != pp}})
    return rows


def plan_promos(c: AscClient, sub_prices: dict[str, int], version: int) -> list[dict]:
    """One row per product: the desired v-offer, its state, and legacy offers."""
    rows = []
    for n, pid in enumerate(PRODUCT_ORDER, start=1):
        sid = SUBSCRIPTION_IDS[pid]
        pts = price_points(c, sid)
        pp_id, cents = snap(sub_prices[pid] / 2, pts)
        code = offer_code(n, version)
        targets, missing, extra = territory_plan(c, sid, pp_id)
        offers = list_offers(c, sid)
        existing = next((o for o in offers if o["attributes"].get("offerCode") == code), None)
        state = "create"
        if existing is not None:
            have = offer_price_points(c, existing["id"])
            state = "ok" if have == targets else "conflict"
        legacy = [o["id"] for o in offers if _LEGACY_RE.match(o["attributes"].get("offerCode") or "")]
        rows.append({"product": pid, "members": n, "sub_price": sub_prices[pid], "offer_code": code,
                     "price_point": pp_id, "promo_cents": cents, "state": state,
                     "territories": targets, "missing": missing, "extra": extra,
                     "existing_id": existing["id"] if existing else None, "legacy_ids": legacy})
    return rows


def create_offer_payload(sub_id: str, row: dict) -> dict:
    """One offer carrying a PAY_UP_FRONT price entry for every territory in row['territories']."""
    terrs = sorted(row["territories"])
    ids = {t: f"${{p{i}}}" for i, t in enumerate(terrs, start=1)}
    return {
        "data": {
            "type": "subscriptionPromotionalOffers",
            "attributes": {"name": f"Invite reward 50% v{OFFER_VERSION} ({row['members']})",
                           "offerCode": row["offer_code"], "duration": "ONE_MONTH",
                           "numberOfPeriods": 1, "offerMode": "PAY_UP_FRONT"},
            "relationships": {
                "subscription": {"data": {"type": "subscriptions", "id": sub_id}},
                "prices": {"data": [{"type": "subscriptionPromotionalOfferPrices", "id": ids[t]}
                                    for t in terrs]},
            },
        },
        "included": [{
            "type": "subscriptionPromotionalOfferPrices", "id": ids[t],
            "relationships": {
                "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints",
                                                    "id": row["territories"][t]}},
                "territory": {"data": {"type": "territories", "id": t}},
            },
        } for t in terrs],
    }


def set_price_payload(sub_id: str, price_point_id: str, preserve: bool, territory: str = TERRITORY,
                      start_date: str | None = None) -> dict:
    """startDate null = effective immediately, which Apple rejects (409 "Initial price cannot be
    created again") once a subscription is approved; then a future date is required (ASC enforces
    a minimum lead time of about two days). preserveCurrentPrice=True keeps existing subscribers
    on their old price; False moves them to the new one."""
    return {"data": {
        "type": "subscriptionPrices",
        "attributes": {"startDate": start_date, "preserveCurrentPrice": preserve},
        "relationships": {
            "subscription": {"data": {"type": "subscriptions", "id": sub_id}},
            "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints", "id": price_point_id}},
            "territory": {"data": {"type": "territories", "id": territory}},
        }}}


def offers_env_json(rows: list[dict]) -> str:
    return json.dumps({r["product"]: r["offer_code"] for r in rows}, separators=(",", ":"))


def _usd(c: int) -> str:
    return f"{c / 100:.2f}"


# ---- commands -----------------------------------------------------------------

def _flag_missing(rows, log) -> bool:
    bad = False
    for r in rows:
        if r["missing"]:
            bad = True
            log(f"MISSING-EQUALIZATION {r['product']}: priced in {r['missing']} but Apple gave "
                f"no equivalent price point there")
    return bad


def cmd_plan_prices(c, args, log=print) -> int:
    rows = plan_prices(c, tier_current_prices(c, args.tier_prices))
    log(f"{'product':<32} {'now':>6} {'target':>7} {'USA pt':>7} {'terr':>5} {'to-set':>6} {'missing':>7}")
    for r in rows:
        log(f"{r['product']:<32} {_usd(r['current']):>6} {_usd(r['target']):>7} {_usd(r['snapped']):>7} "
            f"{len(r['territories']):>5} {len(r['todo']):>6} {len(r['missing']):>7}")
    _flag_missing(rows, log)
    return 0


def cmd_set_prices(c, args, log=print) -> int:
    rows = plan_prices(c, tier_current_prices(c, args.tier_prices))
    log(f"preserve_existing={args.preserve_existing} (False = existing subscribers move to the new price)")
    log(f"{'product':<32} {'now':>6} {'USA new':>8} {'terr':>5} {'to-set':>6} {'missing':>7}")
    for r in rows:
        log(f"{r['product']:<32} {_usd(r['current']):>6} {_usd(r['snapped']):>8} "
            f"{len(r['territories']):>5} {len(r['todo']):>6} {len(r['missing']):>7}")
    bad = _flag_missing(rows, log)
    if bad and args.apply and not args.allow_missing_territories:
        log("ABORT: territories lack equalizations; fix or pass --allow-missing-territories")
        return 2
    if args.apply and not args.start_date:
        log("ABORT: --start-date YYYY-MM-DD is required with --apply (Apple rejects immediate price "
            "changes on approved subscriptions)")
        return 2
    if args.apply and args.tier_prices is None:
        log("ABORT: pass --tier-prices-json with the OLD prices with --apply; targets are derived from "
            "the current price, and ASC reports a scheduled future price as current, so a re-run "
            "would otherwise compound the cut")
        return 2
    log(f"start_date={args.start_date}")
    for r in rows:
        sid = SUBSCRIPTION_IDS[r["product"]]
        if not r["todo"]:
            log(f"NOOP   {r['product']}: all {len(r['territories'])} territories already on target")
            continue
        if not args.apply:
            log(f"WOULD  {r['product']}: create {len(r['todo'])} prices (USA {_usd(r['current'])} -> "
                f"{_usd(r['snapped'])})")
            continue
        for terr, pp in sorted(r["todo"].items()):
            c.post("/v1/subscriptionPrices",
                   set_price_payload(sid, pp, args.preserve_existing, terr, args.start_date))
            _sleep(WRITE_PAUSE_S)
        log(f"SET    {r['product']}: {len(r['todo'])} territory prices")
    return 0


def cmd_promos(c, args, log=print) -> int:
    current = tier_current_prices(c, args.tier_prices)
    if args.price_source == "planned":
        current = {r["product"]: r["snapped"] for r in plan_prices(c, current)}
    rows = plan_promos(c, current, args.version)
    log(f"{'product':<32} {'sub':>6} {'promo USA':>9} {'terr':>5} {'missing':>7} state")
    for r in rows:
        log(f"{r['product']:<32} {_usd(r['sub_price']):>6} {_usd(r['promo_cents']):>9} "
            f"{len(r['territories']):>5} {len(r['missing']):>7} {r['state']}")
    bad = False
    miss = _flag_missing(rows, log)
    if miss and args.apply and not args.allow_missing_territories:
        log("ABORT: territories lack equalizations; fix or pass --allow-missing-territories")
        return 2
    for r in rows:
        line = (f"{r['product']}: sub {_usd(r['sub_price'])} promo {_usd(r['promo_cents'])} "
                f"code {r['offer_code']} [{r['state']}] territories={len(r['territories'])}")
        if r["state"] == "conflict":
            bad = True
            log(f"CONFLICT {line} (code exists with different prices/territories; bump --version)")
        elif r["state"] == "ok":
            log(f"OK       {line}")
        elif args.apply:
            c.post("/v1/subscriptionPromotionalOffers", create_offer_payload(SUBSCRIPTION_IDS[r["product"]], r))
            log(f"CREATED  {line}")
        else:
            log(f"WOULD    {line}")
    if bad:
        return 2
    if args.delete_old:
        if args.apply and any(r["state"] == "create" for r in rows):
            # Guard: deleting legacy offers in the same run that creates the new
            # ones would break live signing before the server env switches.
            log("ABORT-DELETE: new offers were just created; switch APPLE_PROMO_OFFERS on the "
                "server first, then re-run with --apply --delete-old")
        elif not args.apply:
            log("(dry run) legacy offers that --apply --delete-old would delete: "
                f"{sum(len(r['legacy_ids']) for r in rows)}")
        else:
            for r in rows:
                for oid in r["legacy_ids"]:
                    c.delete(f"/v1/subscriptionPromotionalOffers/{oid}")
                    log(f"DELETED  legacy offer {oid} ({r['product']})")
    log("APPLE_PROMO_OFFERS=" + offers_env_json(rows))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("plan-prices", "set-prices", "promos"):
        sp = sub.add_parser(name)
        sp.add_argument("--tier-prices-json", dest="tier_prices_path",
                        help="JSON {productId: current/new USD cents}; overrides reading ASC")
        if name != "plan-prices":
            sp.add_argument("--apply", action="store_true", help="perform writes (default: dry run)")
            sp.add_argument("--allow-missing-territories", action="store_true",
                            help="with --apply: proceed even if a priced territory has no equalization")
        if name == "set-prices":
            sp.add_argument("--start-date", dest="start_date", default=None,
                            help="YYYY-MM-DD effective date (required with --apply)")
            sp.add_argument("--preserve-existing", action="store_true",
                            help="existing subscribers keep their old price (default: move them to the new price)")
        if name == "promos":
            sp.add_argument("--version", type=int, default=OFFER_VERSION)
            sp.add_argument("--price-source", choices=("current", "planned"), default="current",
                            help="'planned' = use the prices set-prices WOULD set (for pre-change dry runs)")
            sp.add_argument("--delete-old", action="store_true",
                            help="with --apply: delete legacy offers (only after the server env switched)")
    args = ap.parse_args(argv)
    args.apply = getattr(args, "apply", False)
    args.allow_missing_territories = getattr(args, "allow_missing_territories", False)
    args.tier_prices = None
    if args.tier_prices_path:
        with open(args.tier_prices_path) as fh:
            args.tier_prices = json.load(fh)
    key_id = os.getenv("ASC_KEY_ID", "").strip()
    issuer = os.getenv("ASC_ISSUER_ID", "").strip()
    if not key_id or not issuer:
        raise SystemExit("ASC_KEY_ID and ASC_ISSUER_ID must be set.")
    key_path = os.getenv("ASC_KEY_PATH") or os.path.expanduser(
        f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")
    token = make_token(key_id, issuer, key_path)
    print(f"cmd={args.cmd} mode={'APPLY' if args.apply else 'DRY-RUN/READ-ONLY'} "
          f"at {datetime.now(timezone.utc).isoformat(timespec='seconds')}")
    with httpx.Client(timeout=60) as http:
        c = AscClient(http, token, allow_writes=args.apply)
        fn = {"plan-prices": cmd_plan_prices, "set-prices": cmd_set_prices, "promos": cmd_promos}[args.cmd]
        return fn(c, args)


if __name__ == "__main__":
    sys.exit(main())

# Subscription price cut runbook (2026-10-01)

Task `20261001-subscription-price-cut`. Gates changed code, docs and scripts only. Nothing here has been run against live Apple, Stripe or production. An operator runs the steps below by hand, dry-run first.

## Tables

Server (Stripe, `GROUP_PRICE_CENTS` in `api/schemas/subscription.py`). Rule: tier 1 pinned at 499. Tiers 2-8 are the old price x 0.45, rounded half-up to 5 cents.

| Members | Old (cents) | New (cents) | New USD |
|---|---|---|---|
| 1 | 1000 | 499 | 4.99 |
| 2 | 1799 | 810 | 8.10 |
| 3 | 2699 | 1215 | 12.15 |
| 4 | 3599 | 1620 | 16.20 |
| 5 | 4499 | 2025 | 20.25 |
| 6 | 5399 | 2430 | 24.30 |
| 7 | 6299 | 2835 | 28.35 |
| 8 | 7199 | 3240 | 32.40 |

Apple (USD, USA is the anchor; all 175 priced territories follow via ASC equalizations). Apple prices differ from Stripe at some tiers. A read-only check on 2026-10-01 found tier 4 at 36.99 on Apple (35.99 in code/Stripe). Targets come from Apple's ACTUAL current price: tier 1 = 4.99, tiers 2-8 = round-half-up-5c(0.45 x current), then snapped to the nearest price point Apple offers (tie goes to the lower point). Example: tier 4 = 0.45 x 36.99 = 16.65 before snapping, not 16.20. Run `plan-prices` to get the exact snapped table and price point ids; do not copy numbers from this page.

Apple promo offers are pay-up-front, 1 month, at 50% of the (new) Apple tier price, snapped the same way. Codes: `invite_reward_50_v2` (1 member), `invite_reward_50_v2_2` .. `invite_reward_50_v2_8`.

## Prerequisites

* ASC env for the Apple script (values never printed): `ASC_KEY_ID` (JZCLMWLW83), `ASC_ISSUER_ID`, optional `ASC_KEY_PATH` (default `~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8`).
* Stripe: `STRIPE_SECRET_KEY` in `api/.env` (live key needs `--confirm-live` with `--apply`).
* Run everything from `api/` with the repo venv. Every command is read-only unless `--apply` is present.

## Order

1. Deploy the new code image first (server table 4.99..32.40, frontend, iOS build as per the other steps). Server env is unchanged at this point.
2. Apple subscription prices.
   * `python scripts/apple_price_and_promos.py plan-prices` and check the table.
   * `python scripts/apple_price_and_promos.py set-prices` (dry run), then `... set-prices --apply`. Default moves existing subscribers to the new price (approved). Add `--preserve-existing` to keep them on the old price instead. Every territory the product is currently priced in (175 on 2026-10-01) gets a price: the script picks the USA target point, then uses `GET /v1/subscriptionPricePoints/{id}/equalizations` to find Apple's equivalent point per territory and posts one `subscriptionPrices` (startDate null = immediate, `preserveCurrentPrice` per the flag) per territory, about 1,400 writes in total, paced and safe to re-run (territories already on target are skipped). The dry run prints a per-tier table (USA target, territory count, to-set count, missing count). Any `MISSING-EQUALIZATION` line means a priced territory has no equivalent point; `--apply` aborts until resolved (or pass `--allow-missing-territories` to accept leaving those at the old price).
3. Apple promo offers (after step 2 so the 50% is taken from the new prices).
   * Optional rehearsal before step 2: `promos --price-source planned`.
   * `promos` (dry run). Exit code 2 means a code already exists at a different price: rerun with `--version 3` (offer codes become `invite_reward_50_v3...`).
   * `promos --apply` creates the missing versioned offers, each priced in every territory (one offer carries all 175 offer prices; Apple promo prices are equalized from the USA promo point). An existing code whose territory prices differ is a CONFLICT. Re-runs are no-ops. It prints `APPLE_PROMO_OFFERS=<json>`.
4. Switch `APPLE_PROMO_OFFERS` to that JSON in all three places in the same step: local `.env`, server `~/fellowscript-docker/.env` (and legacy `~/fellowscript/.env` if used; manual), and the CI env block in `.github/workflows/build-push.yml` (already set to the v2 codes). Restart the server so `validate_owner_rewards_config()` re-reads it.
5. Only after step 4 is live: `promos --apply --delete-old` removes the legacy `invite_reward_50[_N]` offers. Deleting earlier would break live signing of the old codes.
6. Stripe subscribers.
   * `python scripts/stripe_price_migration.py` (dry run). Review the `WOULD` and `SKIP` lines.
   * `python scripts/stripe_price_migration.py --apply` (add `--confirm-live` for the live key).
   * It swaps each subscription whose item equals the OLD table price to the NEW amount with `proration_behavior=none`: no credit or charge now, the new amount bills from the next renewal. Coupons are untouched (percent based, they auto-adjust). Subscriptions at the new price are no-ops, so a re-run is safe. Anything matching neither table, with several items, or not usd/monthly is skipped and logged.
7. DB column. Stripe events do not update `subscriptions.price_cents`. Print the idempotent SQL with `python scripts/stripe_price_migration.py --print-db-sql` and run it with psql on the server.

## Verify

* Re-run the dry runs: Stripe shows only `NOOP`/`SKIP`; promos shows only `OK`.
* A test checkout shows the new amount.
* `GET` price check in App Store Connect matches `plan-prices` output.

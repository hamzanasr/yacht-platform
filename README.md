# Yacht Charter Marketplace — core code

Companion code for the PRD & Architecture doc. Everything here runs on Node 22+ and PostgreSQL 15+ with no npm dependencies.

| Path | What it is |
| --- | --- |
| `db/schema.sql` | Full DDL: 28 tables, 3 views, exclusion constraint against double booking, ledger invariants, RLS |
| `db/test_schema.sql` | 10 integration checks (overlap + buffer, expired holds, ledger split, manifest gate, frozen pricing, append-only ledger, RLS) |
| `src/pricing/pricing-engine.ts` | Pure pricing & deposit engine (integer halalas, basis points) |
| `src/pricing/pricing-engine.test.ts` | 12 tests incl. the brief's example and a 5,000-case invariant sweep |
| `src/booking/slot-hold.service.ts` | Redis `SET NX EX 600` + Postgres `fn_hold_slot` holds, confirmation, sweeper, availability |
| `src/booking/availability.test.ts` | 6 tests for FIXED/OPEN slots, buffers, lead time, overnight shifts |
| `src/payments/moyasar-webhook.ts` | Webhook + callback + reconciliation sharing one idempotent `confirmPayment` |
| `api/openapi.yaml` | OpenAPI 3.1: 35 operations for web, mobile, owner, partner and admin |
| `docs/index.html` | Interactive spec guide (Arabic / English): every screen step by step, ready-made tools, price calculator, booking statuses. Open it in a browser. |

## Run

```bash
# unit tests (Node 22+)
node --experimental-strip-types --test src/pricing/pricing-engine.test.ts src/booking/availability.test.ts

# schema + integration checks (throwaway database)
createdb yacht_test
psql -d yacht_test -v ON_ERROR_STOP=1 -f db/schema.sql
psql -d yacht_test -v ON_ERROR_STOP=1 -f db/test_schema.sql   # prints ALL SCHEMA CHECKS PASSED
```

## Wiring into Next.js

- `app/api/v1/webhooks/moyasar/route.ts` → `export const POST = (req: Request) => handleMoyasarWebhook(req, deps())`
- Implement `RedisPort` with `@upstash/redis` (`set(key, val, { nx: true, ex: 600 })`, `eval`).
- Implement `Database` with `pg` or `@neondatabase/serverless` (`tx` = BEGIN/COMMIT on one client).
- Cron: `sweepExpired()` every minute, `reconcilePendingPayments()` every 5 minutes, outbox worker every 15 s.

## Conventions

- Money: integer halalas (1 SAR = 100). Rates: basis points (1500 = 15%).
- Deposit = trip commission − affiliate discount + online add-ons. Captain balance = trip − commission + dock add-ons (never changed by affiliates).
- Business timezone Asia/Riyadh (+03:00, no DST). Weekend = Friday + Saturday. Holidays come from `seasonal_calendars`.

/**
 * Moyasar payment confirmation — webhook + redirect callback share one code path.
 *
 * Next.js App Router:   app/api/v1/webhooks/moyasar/route.ts
 *   export const POST = (req: Request) => handleMoyasarWebhook(req, deps());
 *
 * Moyasar webhook object (docs.moyasar.com → Webhook Reference):
 *   { id, type: 'payment_paid' | 'payment_faild' | 'payment_refunded' | ..., created_at,
 *     secret_token, account_name, live, data: <payment> }
 * Non-2xx responses are retried 5 times over ~3h, then dropped — so we ALSO run a
 * reconciliation cron (reconcilePendingPayments) that fetches stale payments.
 *
 * Trust model: the webhook body is only a hint. We authenticate it with the shared
 * secret_token, then re-fetch the payment from Moyasar's API with our secret key and
 * act on THAT response (amount, currency, status, metadata).
 */
import { timingSafeEqual } from 'node:crypto';
import type { Database, SqlClient } from '../booking/slot-hold.service.ts';
import { SlotHoldService } from '../booking/slot-hold.service.ts';

// ───────────────────────────── Types ─────────────────────────────

export interface MoyasarPayment {
  id: string;
  status: 'initiated' | 'paid' | 'failed' | 'authorized' | 'captured' | 'refunded' | 'voided' | 'verified';
  amount: number;          // halalas
  currency: string;        // 'SAR'
  refunded?: number;
  source?: { type?: string; company?: string; number?: string; message?: string };
  metadata?: Record<string, string>;
}

export interface MoyasarWebhook {
  id: string;
  type: string;
  created_at: string;
  secret_token: string;
  live: boolean;
  data: MoyasarPayment;
}

export interface MoyasarClient {
  fetchPayment(id: string): Promise<MoyasarPayment>;
  refund(id: string, amountHalalas: number): Promise<void>;
}

export interface Notifier {
  /** Writes to notification_outbox inside the same transaction (outbox pattern). */
  enqueue(c: SqlClient, n: { channel: 'WHATSAPP' | 'SMS'; template: string; recipient: string; bookingId: string; vars: Record<string, unknown>; dedupeKey: string }): Promise<void>;
}

export interface Deps {
  db: Database;
  holds: SlotHoldService;
  moyasar: MoyasarClient;
  notifier: Notifier;
  webhookSecret: string;
  expectLive: boolean;
  manifestLinkFor(bookingId: string): string; // signed, expiring URL (e.g. 72h after trip)
  log: { info(msg: string, ctx?: object): void; error(msg: string, ctx?: object): void };
}

// ─────────────────────────── Moyasar REST ───────────────────────────

export function moyasarRestClient(secretKey: string, base = 'https://api.moyasar.com/v1'): MoyasarClient {
  const auth = 'Basic ' + Buffer.from(`${secretKey}:`).toString('base64');
  return {
    async fetchPayment(id) {
      const r = await fetch(`${base}/payments/${encodeURIComponent(id)}`, { headers: { Authorization: auth } });
      if (!r.ok) throw new Error(`Moyasar fetch ${id} → HTTP ${r.status}`);
      return (await r.json()) as MoyasarPayment;
    },
    async refund(id, amount) {
      const r = await fetch(`${base}/payments/${encodeURIComponent(id)}/refund`, {
        method: 'POST',
        headers: { Authorization: auth, 'Content-Type': 'application/json' },
        body: JSON.stringify({ amount }),
      });
      if (!r.ok) throw new Error(`Moyasar refund ${id} → HTTP ${r.status}`);
    },
  };
}

// ───────────────────────────── Webhook ─────────────────────────────

function safeEqual(a: string, b: string): boolean {
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

export async function handleMoyasarWebhook(req: Request, deps: Deps): Promise<Response> {
  let evt: MoyasarWebhook;
  try { evt = (await req.json()) as MoyasarWebhook; } catch { return new Response('bad json', { status: 400 }); }

  if (typeof evt.secret_token !== 'string' || !safeEqual(evt.secret_token, deps.webhookSecret)) {
    deps.log.error('moyasar webhook: bad secret', { id: evt?.id });
    return new Response('forbidden', { status: 401 });
  }
  if (evt.live !== deps.expectLive) return new Response('wrong mode', { status: 200 }); // ack, ignore

  // Idempotency: first writer wins; replays are acknowledged without work.
  const ins = await deps.db.query<{ id: number }>(
    `INSERT INTO webhook_events (provider, event_id, event_type, payload)
     VALUES ('MOYASAR', $1, $2, $3) ON CONFLICT (provider, event_id) DO NOTHING RETURNING id`,
    [evt.id, evt.type, { ...evt, secret_token: undefined }],
  );
  if (ins.rowCount === 0) {
    const prior = await deps.db.query<{ processed_at: Date | null }>(
      `SELECT processed_at FROM webhook_events WHERE provider = 'MOYASAR' AND event_id = $1`, [evt.id]);
    if (prior.rows[0]?.processed_at) return new Response('duplicate', { status: 200 });
  }

  try {
    if (evt.type === 'payment_paid' || evt.type === 'payment_faild' || evt.type === 'payment_failed') {
      await confirmPayment(evt.data.id, deps);
    }
    await deps.db.query(`UPDATE webhook_events SET processed_at = now(), error = NULL WHERE provider = 'MOYASAR' AND event_id = $1`, [evt.id]);
    return new Response('ok', { status: 200 });
  } catch (e) {
    await deps.db.query(`UPDATE webhook_events SET error = $2 WHERE provider = 'MOYASAR' AND event_id = $1`, [evt.id, String(e)]);
    deps.log.error('moyasar webhook failed', { id: evt.id, err: String(e) });
    return new Response('retry', { status: 500 }); // Moyasar retries; processing is idempotent
  }
}

// ─────────────────────── Confirmation (shared) ───────────────────────

interface BookingRow {
  id: string; booking_number: string; booking_status: string; payment_status: string;
  amount_due_online_halalas: string; reservation_id: string; boat_id: string; client_id: string;
  trip_start: Date; trip_end: Date; hold_token: string; affiliate_id: string | null;
  partner_earning_halalas: string; owner_id: string; online_owner_payable: string;
}

export type ConfirmOutcome = 'PAID' | 'ALREADY_PAID' | 'FAILED' | 'REFUNDED_SLOT_LOST' | 'IGNORED';

/**
 * Idempotent. Safe to call from the webhook, the redirect callback (?id=...) and
 * the reconciliation cron, in any order and any number of times.
 */
export async function confirmPayment(paymentId: string, deps: Deps): Promise<ConfirmOutcome> {
  const p = await deps.moyasar.fetchPayment(paymentId); // source of truth
  const bookingId = p.metadata?.booking_id;
  if (!bookingId) { deps.log.error('payment without booking_id metadata', { paymentId }); return 'IGNORED'; }

  let refundNeeded = 0;
  const outcome = await deps.db.tx(async (c): Promise<ConfirmOutcome> => {
    const { rows } = await c.query<BookingRow>(
      `SELECT b.id, b.booking_number, b.booking_status, b.payment_status, b.amount_due_online_halalas,
              b.reservation_id, b.boat_id, b.client_id, b.trip_start, b.trip_end, r.hold_token,
              b.affiliate_id, b.partner_earning_halalas, b.owner_id,
              COALESCE((SELECT SUM(unit_price_halalas * quantity) FROM booking_addons
                         WHERE booking_id = b.id AND collection = 'ONLINE_DEPOSIT' AND fulfilled_by = 'OWNER'), 0) AS online_owner_payable
         FROM bookings b JOIN boat_reservations r ON r.id = b.reservation_id
        WHERE b.id = $1
        FOR UPDATE OF b`,
      [bookingId],
    );
    const b = rows[0];
    if (!b) return 'IGNORED';

    // Upsert the payment row from the authoritative response
    await c.query(
      `INSERT INTO payments (booking_id, provider_payment_id, amount_halalas, currency, status, method, card_last4, failure_reason, raw_response, paid_at)
       VALUES ($1, $2, $3, $4, $5::payment_status, $6, $7, $8, $9, CASE WHEN $5 = 'PAID' THEN now() END)
       ON CONFLICT (provider_payment_id) DO UPDATE
         SET status = EXCLUDED.status, raw_response = EXCLUDED.raw_response,
             failure_reason = EXCLUDED.failure_reason, paid_at = COALESCE(payments.paid_at, EXCLUDED.paid_at)`,
      [b.id, p.id, p.amount, p.currency, p.status === 'paid' ? 'PAID' : p.status === 'failed' ? 'FAILED' : 'INITIATED',
       p.source?.company ?? p.source?.type ?? null, p.source?.number?.slice(-4) ?? null, p.source?.message ?? null, p],
    );

    if (b.payment_status === 'PAID') return 'ALREADY_PAID';
    if (p.status === 'failed') {
      await c.query(`UPDATE bookings SET payment_status = 'FAILED' WHERE id = $1 AND payment_status = 'INITIATED'`, [b.id]);
      return 'FAILED'; // hold stays until expiry so the client can retry with another card
    }
    if (p.status !== 'paid') return 'IGNORED';

    // Amount / currency must match the frozen quote exactly
    if (p.currency !== 'SAR' || p.amount !== Number(b.amount_due_online_halalas)) {
      throw new Error(`amount mismatch on ${b.booking_number}: paid ${p.amount} ${p.currency}, expected ${b.amount_due_online_halalas} SAR`);
    }

    const slot = await deps.holds.confirmInTx(c, {
      reservationId: b.reservation_id, holdToken: b.hold_token, boatId: b.boat_id,
      start: new Date(b.trip_start), end: new Date(b.trip_end), userId: b.client_id,
    });

    if (slot.outcome === 'SLOT_LOST') {
      await c.query(`UPDATE bookings SET payment_status = 'PAID', booking_status = 'EXPIRED', cancel_reason = 'LATE_PAYMENT_SLOT_TAKEN' WHERE id = $1`, [b.id]);
      await c.query(
        `INSERT INTO refunds (payment_id, amount_halalas, reason)
         SELECT id, amount_halalas, 'LATE_PAYMENT_SLOT_TAKEN' FROM payments WHERE provider_payment_id = $1`, [p.id]);
      refundNeeded = p.amount;
      return 'REFUNDED_SLOT_LOST';
    }

    await c.query(
      `UPDATE bookings SET payment_status = 'PAID', booking_status = 'PENDING_MANIFEST',
              reservation_id = $2, version = version + 1
        WHERE id = $1`,
      [b.id, slot.reservationId],
    );

    if (b.affiliate_id && Number(b.partner_earning_halalas) > 0) {
      await c.query(
        `INSERT INTO affiliate_transactions (affiliate_id, booking_id, txn_type, status, amount_halalas)
         VALUES ($1, $2, 'EARNING', 'PENDING', $3) ON CONFLICT DO NOTHING`,
        [b.affiliate_id, b.id, b.partner_earning_halalas]);
    }
    if (Number(b.online_owner_payable) > 0) {
      await c.query(
        `INSERT INTO owner_payables (owner_id, booking_id, amount_halalas) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`,
        [b.owner_id, b.id, b.online_owner_payable]);
    }

    await enqueueConfirmationMessages(c, b.id, deps);
    return 'PAID';
  });

  if (refundNeeded > 0) {
    // Outside the transaction: an external call must never hold row locks.
    await deps.moyasar.refund(paymentId, refundNeeded);
    await deps.db.query(`UPDATE refunds SET status = 'SUCCEEDED' WHERE payment_id = (SELECT id FROM payments WHERE provider_payment_id = $1)`, [paymentId]);
    await deps.db.query(`UPDATE payments SET status = 'REFUNDED' WHERE provider_payment_id = $1`, [paymentId]);
  }
  deps.log.info('payment confirmed', { paymentId, outcome });
  return outcome;
}

async function enqueueConfirmationMessages(c: SqlClient, bookingId: string, deps: Deps): Promise<void> {
  const { rows } = await c.query<{
    booking_number: string; client_name: string; client_phone: string; client_locale: string;
    captain_phone: string; trip_start: Date; guests: number; route_ar: string; route_en: string;
    marina_ar: string; marina_en: string; lat: string; lng: string; balance: string; boat_ar: string; boat_en: string;
    emergency_phone: string | null;
  }>(
    `SELECT b.booking_number, u.full_name AS client_name, u.phone_e164 AS client_phone, u.preferred_locale AS client_locale,
            COALESCE(cp.whatsapp_e164, o.whatsapp_e164) AS captain_phone, b.trip_start, b.guests,
            d.route_name_ar AS route_ar, d.route_name_en AS route_en, m.name_ar AS marina_ar, m.name_en AS marina_en,
            m.latitude AS lat, m.longitude AS lng, b.balance_due_to_captain AS balance, bt.name_ar AS boat_ar, bt.name_en AS boat_en,
            m.emergency_phone
       FROM bookings b
       JOIN users u ON u.id = b.client_id
       JOIN boats bt ON bt.id = b.boat_id
       JOIN owners o ON o.id = b.owner_id
       LEFT JOIN captains cp ON cp.id = bt.default_captain_id
       JOIN destinations_pricing d ON d.id = b.destination_id
       JOIN marinas m ON m.id = b.marina_id
      WHERE b.id = $1`, [bookingId]);
  const r = rows[0];
  const when = new Date(r.trip_start).toLocaleString('ar-SA-u-nu-latn', { timeZone: 'Asia/Riyadh', dateStyle: 'full', timeStyle: 'short' });
  const balanceSar = (Number(r.balance) / 100).toFixed(2);

  await deps.notifier.enqueue(c, {
    channel: 'WHATSAPP', template: 'captain_new_booking_v1', recipient: r.captain_phone, bookingId,
    dedupeKey: `${bookingId}:captain_new_booking`,
    vars: { booking_number: r.booking_number, guest_name: r.client_name, guest_phone: r.client_phone, departure: when,
            passengers: r.guests, destination: r.route_ar, balance_to_collect_sar: balanceSar,
            manifest_link: deps.manifestLinkFor(bookingId) },
  });
  await deps.notifier.enqueue(c, {
    channel: 'WHATSAPP', template: r.client_locale === 'en' ? 'client_payment_received_en_v1' : 'client_payment_received_ar_v1',
    recipient: r.client_phone, bookingId, dedupeKey: `${bookingId}:client_payment_received`,
    vars: { booking_number: r.booking_number, boat: r.client_locale === 'en' ? r.boat_en : r.boat_ar, departure: when,
            balance_at_dock_sar: balanceSar, manifest_cta: `/bookings/${bookingId}/manifest`,
            maps_pin: `https://www.google.com/maps/search/?api=1&query=${r.lat},${r.lng}`,
            emergency_phone: r.emergency_phone ?? '' },
  });
  // The voucher (client_voucher_v1) is sent by the manifest endpoint once every passenger is entered.
}

/** Cron every 5 min: catch payments whose webhooks never arrived. */
export async function reconcilePendingPayments(deps: Deps): Promise<number> {
  const { rows } = await deps.db.query<{ provider_payment_id: string }>(
    `SELECT p.provider_payment_id FROM payments p JOIN bookings b ON b.id = p.booking_id
      WHERE b.payment_status IN ('INITIATED','FAILED') AND p.provider_payment_id IS NOT NULL
        AND p.created_at BETWEEN now() - interval '24 hours' AND now() - interval '3 minutes'`);
  for (const r of rows) await confirmPayment(r.provider_payment_id, deps).catch((e) => deps.log.error('reconcile', { id: r.provider_payment_id, e: String(e) }));
  return rows.length;
}

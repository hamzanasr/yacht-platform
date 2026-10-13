/**
 * Slot availability + checkout holds.
 *
 * Two layers, each doing what it is good at:
 *   1. Redis (Upstash)  — `SET hold:{boat}:{start}:{end} <token> NX EX 600`
 *      Fast rejection of a hot slot and a session-scoped hold token. Not trusted
 *      for correctness: keys can be lost on failover, and OPEN-mode ranges can
 *      overlap without sharing a key.
 *   2. Postgres         — fn_hold_slot() inserts a HOLD row; the EXCLUDE constraint
 *      on (boat_id, blocked_range) makes overlapping active reservations impossible,
 *      buffer included. This is the guarantee.
 *
 * Dependencies are injected as small interfaces so this file has no vendor imports.
 */

// ───────────────────────────── Ports ─────────────────────────────

export interface RedisPort {
  /** SET key value NX EX seconds → 'OK' | null */
  setNxEx(key: string, value: string, seconds: number): Promise<'OK' | null>;
  /** EVAL script with keys/args (Upstash supports EVAL). */
  eval(script: string, keys: string[], args: string[]): Promise<unknown>;
}

export interface SqlResult<R> { rows: R[]; rowCount: number }
export interface SqlClient { query<R = Record<string, unknown>>(sql: string, params?: unknown[]): Promise<SqlResult<R>> }
export interface Database { tx<T>(fn: (c: SqlClient) => Promise<T>): Promise<T>; query: SqlClient['query'] }

export interface Clock { now(): Date }
export interface Ids { uuid(): string }

// ──────────────────────────── Domain ────────────────────────────

export const HOLD_SECONDS = 600; // 10-minute checkout window
export const RIYADH_OFFSET = '+03:00'; // Asia/Riyadh has no DST

export type HoldErrorCode = 'SLOT_HELD' | 'SLOT_UNAVAILABLE' | 'INVALID_RANGE' | 'BOAT_NOT_BOOKABLE' | 'HOLD_NOT_FOUND';

export class HoldError extends Error {
  code: HoldErrorCode;
  constructor(code: HoldErrorCode, message: string) { super(message); this.code = code; this.name = 'HoldError'; }
}

export interface HoldRequest {
  boatId: string;
  start: Date;
  end: Date;
  userId: string;
}

export interface Hold {
  reservationId: string;
  holdToken: string;
  expiresAt: Date;
}

const holdKey = (boatId: string, start: Date, end: Date) =>
  `hold:${boatId}:${start.toISOString()}:${end.toISOString()}`;

/** Delete only if the value still matches our token (never release someone else's hold). */
const COMPARE_AND_DELETE = `
if redis.call('GET', KEYS[1]) == ARGV[1] then
  return redis.call('DEL', KEYS[1])
end
return 0`;

const PG_EXCLUSION_VIOLATION = '23P01';
const PG_NO_DATA_FOUND = 'P0002';

function pgCode(e: unknown): string | undefined {
  return typeof e === 'object' && e !== null && 'code' in e ? String((e as { code: unknown }).code) : undefined;
}

// ─────────────────────────── Service ───────────────────────────

export class SlotHoldService {
  private redis: RedisPort;
  private db: Database;
  private clock: Clock;
  private ids: Ids;

  constructor(deps: { redis: RedisPort; db: Database; clock: Clock; ids: Ids }) {
    this.redis = deps.redis;
    this.db = deps.db;
    this.clock = deps.clock;
    this.ids = deps.ids;
  }

  /**
   * Hold a slot for checkout.
   *   1. Redis NX lock — rejects a concurrent click on the same slot in ~1 ms.
   *   2. Postgres fn_hold_slot — authoritative; raises 23P01 on any overlap (incl. buffer).
   *   3. On DB rejection, release our Redis key so the slot isn't shadow-blocked.
   */
  async hold(req: HoldRequest): Promise<Hold> {
    if (!(req.end > req.start)) throw new HoldError('INVALID_RANGE', 'end must be after start');
    if (req.start.getTime() < this.clock.now().getTime()) throw new HoldError('INVALID_RANGE', 'start is in the past');

    const token = this.ids.uuid();
    const key = holdKey(req.boatId, req.start, req.end);

    const locked = await this.redis.setNxEx(key, token, HOLD_SECONDS);
    if (locked !== 'OK') throw new HoldError('SLOT_HELD', 'Another customer is checking out this slot');

    try {
      const row = await this.db.tx(async (c) => {
        const ins = await c.query<{ id: string }>(
          `SELECT fn_hold_slot($1, $2, $3, $4, $5, $6) AS id`,
          [req.boatId, req.start, req.end, token, HOLD_SECONDS, req.userId],
        );
        const got = await c.query<{ id: string; hold_expires_at: Date }>(
          `SELECT id, hold_expires_at FROM boat_reservations WHERE id = $1`,
          [ins.rows[0].id],
        );
        return got.rows[0];
      });
      return { reservationId: row.id, holdToken: token, expiresAt: new Date(row.hold_expires_at) };
    } catch (e) {
      await this.redis.eval(COMPARE_AND_DELETE, [key], [token]).catch(() => undefined);
      if (pgCode(e) === PG_EXCLUSION_VIOLATION) throw new HoldError('SLOT_UNAVAILABLE', 'Slot is no longer available');
      if (pgCode(e) === PG_NO_DATA_FOUND) throw new HoldError('BOAT_NOT_BOOKABLE', 'Boat is not bookable');
      throw e;
    }
  }

  /** Client abandoned checkout or changed slot. Idempotent. */
  async release(hold: Hold & { boatId: string; start: Date; end: Date }): Promise<void> {
    await this.db.query(
      `UPDATE boat_reservations SET status = 'RELEASED', released_at = now()
        WHERE id = $1 AND hold_token = $2 AND status = 'HOLD'`,
      [hold.reservationId, hold.holdToken],
    );
    await this.redis.eval(COMPARE_AND_DELETE, [holdKey(hold.boatId, hold.start, hold.end)], [hold.holdToken]);
  }

  /**
   * Called inside the payment-confirmation transaction.
   * Returns 'CONFIRMED' if the reservation is now BOOKED, or 'SLOT_LOST' when the
   * hold expired AND another booking took the time (caller must refund).
   *
   * A hold past its expiry that nobody reclaimed is still ours: it is converted.
   */
  async confirmInTx(
    c: SqlClient,
    args: { reservationId: string; holdToken: string; boatId: string; start: Date; end: Date; userId: string },
  ): Promise<{ outcome: 'CONFIRMED'; reservationId: string } | { outcome: 'SLOT_LOST' }> {
    const upd = await c.query<{ id: string }>(
      `UPDATE boat_reservations
          SET status = 'BOOKED', hold_expires_at = NULL
        WHERE id = $1 AND hold_token = $2 AND status IN ('HOLD','BOOKED')
        RETURNING id`,
      [args.reservationId, args.holdToken],
    );
    if (upd.rowCount === 1) return { outcome: 'CONFIRMED', reservationId: args.reservationId };

    // Our hold was released (reclaimed by someone). Try to take the time again.
    await c.query('SAVEPOINT rehold');
    try {
      const re = await c.query<{ id: string }>(
        `SELECT fn_hold_slot($1, $2, $3, $4, $5, $6) AS id`,
        [args.boatId, args.start, args.end, args.holdToken, HOLD_SECONDS, args.userId],
      );
      const id = re.rows[0].id;
      await c.query(`UPDATE boat_reservations SET status = 'BOOKED', hold_expires_at = NULL WHERE id = $1`, [id]);
      await c.query('RELEASE SAVEPOINT rehold');
      return { outcome: 'CONFIRMED', reservationId: id };
    } catch (e) {
      await c.query('ROLLBACK TO SAVEPOINT rehold');
      if (pgCode(e) === PG_EXCLUSION_VIOLATION) return { outcome: 'SLOT_LOST' };
      throw e;
    }
  }

  /** Cron every minute: release expired holds and expire their PENDING_PAYMENT bookings. */
  async sweepExpired(): Promise<number> {
    return this.db.tx(async (c) => {
      const released = await c.query<{ id: string }>(
        `UPDATE boat_reservations SET status = 'RELEASED', released_at = now()
          WHERE status = 'HOLD' AND hold_expires_at < now() - interval '2 minutes' -- grace for in-flight 3-D Secure
          RETURNING id`,
      );
      if (released.rowCount > 0) {
        await c.query(
          `UPDATE bookings SET booking_status = 'EXPIRED'
            WHERE reservation_id = ANY($1::uuid[]) AND booking_status = 'PENDING_PAYMENT'`,
          [released.rows.map((r) => r.id)],
        );
      }
      return released.rowCount;
    });
  }
}

// ─────────────────────── Availability (pure) ───────────────────────

export interface ShiftRule {
  scheduleId: string;
  slotMode: 'FIXED' | 'OPEN';
  nameEn: string;
  nameAr: string;
  weekdayMask: number;     // bit 0 = Sunday
  startTime: string;       // 'HH:MM'
  endTime: string;         // 'HH:MM' (≤ start → ends next day)
  slotStepMinutes: number; // OPEN mode
  validFrom: string;       // YYYY-MM-DD
  validTo?: string;
}

export interface BusyRange { start: Date; end: Date } // blocked_range of HOLD/BOOKED rows

export interface CandidateSlot {
  scheduleId: string;
  label: { ar: string; en: string };
  start: Date;
  end: Date;
}

export function riyadh(date: string, hhmm: string): Date {
  return new Date(`${date}T${hhmm}:00${RIYADH_OFFSET}`);
}

function addMinutes(d: Date, m: number): Date { return new Date(d.getTime() + m * 60_000); }

/** Weekday (0 = Sun) of a calendar date. */
function dow(date: string): number {
  const [y, m, d] = date.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

/**
 * Bookable slots for one boat on one calendar date.
 *   FIXED: each active shift is one slot.
 *   OPEN : start times every `slotStepMinutes` inside the window, for the requested duration.
 * A candidate is offered only if [start, end + buffer) clears every busy blocked_range
 * and every existing blocked_range clears the candidate (same rule as the DB constraint).
 */
export function computeAvailability(args: {
  date: string;
  rules: ShiftRule[];
  busy: BusyRange[];
  bufferMinutes: number;
  durationMinutes: number; // OPEN mode
  now: Date;
  leadMinutes: number;
}): CandidateSlot[] {
  const { date, rules, busy, bufferMinutes, durationMinutes, now, leadMinutes } = args;
  const earliest = addMinutes(now, leadMinutes);
  const out: CandidateSlot[] = [];
  const weekday = dow(date);

  const free = (s: Date, e: Date) => {
    const blockedEnd = addMinutes(e, bufferMinutes);
    return busy.every((b) => blockedEnd <= b.start || s >= b.end);
  };

  for (const r of rules) {
    if (!(r.weekdayMask & (1 << weekday))) continue;
    if (date < r.validFrom || (r.validTo && date > r.validTo)) continue;

    const winStart = riyadh(date, r.startTime);
    let winEnd = riyadh(date, r.endTime);
    if (winEnd <= winStart) winEnd = addMinutes(winEnd, 24 * 60); // overnight

    if (r.slotMode === 'FIXED') {
      if (winStart >= earliest && free(winStart, winEnd)) {
        out.push({ scheduleId: r.scheduleId, label: { ar: r.nameAr, en: r.nameEn }, start: winStart, end: winEnd });
      }
      continue;
    }

    for (let s = winStart; addMinutes(s, durationMinutes) <= winEnd; s = addMinutes(s, r.slotStepMinutes)) {
      const e = addMinutes(s, durationMinutes);
      if (s >= earliest && free(s, e)) {
        out.push({ scheduleId: r.scheduleId, label: { ar: r.nameAr, en: r.nameEn }, start: s, end: e });
      }
    }
  }
  return out.sort((a, b) => a.start.getTime() - b.start.getTime());
}

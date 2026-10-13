/**
 * Pricing & Deposit Engine — yacht charter marketplace (KSA)
 *
 * All money is integer HALALAS (1 SAR = 100 halalas). All rates are integer
 * BASIS POINTS (1% = 100 bps). No floating-point money anywhere.
 *
 * Model (corrected from the original brief — see PRD §3):
 *   tripSubtotal        = dayRate + max(0, guests − baseCapacity) × extraPersonFee
 *   grossCommission     = round(tripSubtotal × commissionBps)        ← the platform's take
 *   clientDiscount      = round(tripSubtotal × affiliate.clientDiscountBps), paid out of grossCommission
 *   netCommission       = grossCommission − clientDiscount
 *   partnerEarning      = round(netCommission × affiliate.partnerCommissionBps)
 *   platformNetRevenue  = netCommission − partnerEarning
 *   depositOnline       = netCommission + onlineAddons                ← charged via Moyasar
 *   balanceAtDock       = tripSubtotal − grossCommission + dockAddons ← captain collects; NEVER changed by affiliates
 *
 * Add-ons are pass-through (no commission) by design. Online add-ons are charged
 * once, at full price. If an online add-on is fulfilled by the OWNER, its amount
 * is reported as `ownerPayableFromOnlineAddons` for periodic settlement.
 *
 * Pure & deterministic: no I/O, no clock. The caller loads rows and passes them in.
 */

// ───────────────────────────── Types ─────────────────────────────

export type DayType = 'WEEKDAY' | 'WEEKEND' | 'HOLIDAY';
export type AddonCollection = 'ONLINE_DEPOSIT' | 'AT_DOCK';
export type AddonFulfiller = 'PLATFORM' | 'OWNER';

/** YYYY-MM-DD, interpreted as a calendar date in Asia/Riyadh (UTC+3, no DST). */
export type IsoDate = string;

export interface DestinationPricing {
  destinationId: string;
  weekdayPriceHalalas: number;
  weekendPriceHalalas: number;
  holidayPriceHalalas: number;
  baseCapacity: number;
  extraPersonFeeHalalas: number;
}

export interface BoatLimits {
  boatId: string;
  maxCapacity: number;
}

export interface AddonLine {
  addonId: string;
  name: string;
  unitPriceHalalas: number;
  quantity: number;
  collection: AddonCollection;
  fulfilledBy: AddonFulfiller;
  /** Optional per-booking cap set by admin (e.g. one drone package). */
  maxQuantity?: number;
}

export interface AffiliateTerms {
  affiliateId: string;
  /** % of the trip subtotal given to the client, paid from the platform commission. */
  clientDiscountBps: number;
  /** % of the platform's commission AFTER the client discount, earned by the partner. */
  partnerCommissionBps: number;
}

export interface PlatformPolicy {
  /**
   * Minimum share of grossCommission the platform must keep after discount and
   * partner earnings (e.g. 3000 = keeps ≥ 30% of its commission). Discounts and
   * partner earnings are clamped — never the captain's balance.
   */
  minPlatformMarginBps: number;
  /** Payment-gateway floor for a charge (halalas). Verify against Moyasar's current minimum. */
  minOnlineChargeHalalas: number;
}

export interface CalendarOverride {
  date: IsoDate;
  dayType: DayType;
  label?: string;
}

export interface QuoteInput {
  tripDate: IsoDate;
  guests: number;
  destination: DestinationPricing;
  boat: BoatLimits;
  /** Effective rate: per-boat override ?? owner default. Snapshot it on the booking. */
  commissionBps: number;
  addons: AddonLine[];
  calendar: ReadonlyMap<IsoDate, CalendarOverride>;
  policy: PlatformPolicy;
  affiliate?: AffiliateTerms;
  /** Credit from an Emergency Reschedule Pass (halalas), applied to the online deposit only. */
  rescheduleCreditHalalas?: number;
}

export interface QuoteBreakdown {
  dayType: DayType;
  dayTypeLabel?: string;
  dayRateHalalas: number;
  extraGuests: number;
  extraGuestFeeHalalas: number;
  tripSubtotalHalalas: number;

  onlineAddonsHalalas: number;
  dockAddonsHalalas: number;
  ownerPayableFromOnlineAddons: number;

  /** List price of everything before any discount. */
  totalListPriceHalalas: number;

  commissionBps: number;
  grossCommissionHalalas: number;
  clientDiscountHalalas: number;
  netCommissionHalalas: number;
  partnerEarningHalalas: number;
  platformNetRevenueHalalas: number;
  affiliateClamped: boolean;

  /** Deposit value of this booking (what a reschedule pass would be worth). */
  depositHalalas: number;
  rescheduleCreditAppliedHalalas: number;
  /** What Moyasar charges now. 0 when a pass fully covers the deposit. */
  amountDueOnlineNowHalalas: number;
  /** Cash/transfer the captain collects at the marina before departure. */
  balanceDueToCaptainHalalas: number;
  /** What the client pays in total (online + dock), after discount. */
  clientTotalHalalas: number;
}

export class PricingError extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
    this.name = 'PricingError';
  }
}

// ─────────────────────────── Helpers ───────────────────────────

const BPS = 10_000;

/** Round-half-up of (amount × bps / 10000) using integers only. */
export function applyBps(amountHalalas: number, bps: number): number {
  assertInt(amountHalalas, 'amount');
  assertInt(bps, 'bps');
  const n = amountHalalas * bps;
  // n is non-negative in every call site; floor((n + 5000) / 10000)
  return Math.floor((n + BPS / 2) / BPS);
}

function assertInt(v: number, name: string): void {
  if (!Number.isSafeInteger(v)) throw new PricingError('INVALID_NUMBER', `${name} must be a safe integer, got ${v}`);
}

function assertNonNeg(v: number, name: string): void {
  assertInt(v, name);
  if (v < 0) throw new PricingError('INVALID_NUMBER', `${name} must be ≥ 0, got ${v}`);
}

function assertBps(v: number, name: string): void {
  assertInt(v, name);
  if (v < 0 || v > BPS) throw new PricingError('INVALID_RATE', `${name} must be within 0..10000 bps, got ${v}`);
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

/** 0 = Sunday … 6 = Saturday, for a pure calendar date (timezone-independent). */
export function dayOfWeek(date: IsoDate): number {
  if (!ISO_DATE.test(date)) throw new PricingError('INVALID_DATE', `Expected YYYY-MM-DD, got ${date}`);
  const [y, m, d] = date.split('-').map(Number);
  const t = Date.UTC(y, m - 1, d);
  const back = new Date(t);
  if (back.getUTCFullYear() !== y || back.getUTCMonth() !== m - 1 || back.getUTCDate() !== d) {
    throw new PricingError('INVALID_DATE', `Not a real date: ${date}`);
  }
  return back.getUTCDay();
}

/**
 * Seasonal detection. Admin overrides win (Eids, National Day 23 Sep, Founding Day
 * 22 Feb, events). Eid dates follow the Hijri calendar and moon sighting, so they
 * are entered by admin, never computed. KSA weekend = Friday + Saturday.
 */
export function resolveDayType(
  date: IsoDate,
  calendar: ReadonlyMap<IsoDate, CalendarOverride>,
): { dayType: DayType; label?: string } {
  const dow = dayOfWeek(date);
  const override = calendar.get(date);
  if (override) return { dayType: override.dayType, label: override.label };
  return { dayType: dow === 5 || dow === 6 ? 'WEEKEND' : 'WEEKDAY' };
}

function priceFor(dest: DestinationPricing, dayType: DayType): number {
  switch (dayType) {
    case 'WEEKDAY': return dest.weekdayPriceHalalas;
    case 'WEEKEND': return dest.weekendPriceHalalas;
    case 'HOLIDAY': return dest.holidayPriceHalalas;
  }
}

// ─────────────────────────── Engine ───────────────────────────

export function quote(input: QuoteInput): QuoteBreakdown {
  const { destination: dest, boat, policy } = input;

  // Validate inputs
  assertNonNeg(dest.weekdayPriceHalalas, 'weekdayPrice');
  assertNonNeg(dest.weekendPriceHalalas, 'weekendPrice');
  assertNonNeg(dest.holidayPriceHalalas, 'holidayPrice');
  assertNonNeg(dest.extraPersonFeeHalalas, 'extraPersonFee');
  assertInt(input.guests, 'guests');
  assertBps(input.commissionBps, 'commissionBps');
  assertBps(policy.minPlatformMarginBps, 'minPlatformMarginBps');
  assertNonNeg(policy.minOnlineChargeHalalas, 'minOnlineCharge');

  if (dest.baseCapacity < 1 || dest.baseCapacity > boat.maxCapacity) {
    throw new PricingError('INVALID_CAPACITY', 'baseCapacity must be between 1 and the boat maxCapacity');
  }
  if (input.guests < 1) throw new PricingError('INVALID_GUESTS', 'At least one guest is required');
  if (input.guests > boat.maxCapacity) {
    throw new PricingError('OVER_CAPACITY', `Boat is certified for ${boat.maxCapacity} passengers; requested ${input.guests}`);
  }

  // 1. Seasonal rate
  const { dayType, label } = resolveDayType(input.tripDate, input.calendar);
  const dayRate = priceFor(dest, dayType);

  // 2. Capacity split
  const extraGuests = Math.max(0, input.guests - dest.baseCapacity);
  const extraGuestFee = extraGuests * dest.extraPersonFeeHalalas;
  const tripSubtotal = dayRate + extraGuestFee;

  // 3. Add-on routing
  let onlineAddons = 0;
  let dockAddons = 0;
  let ownerPayable = 0;
  const seen = new Set<string>();
  for (const a of input.addons) {
    if (seen.has(a.addonId)) throw new PricingError('DUPLICATE_ADDON', `Add-on ${a.addonId} listed twice`);
    seen.add(a.addonId);
    assertNonNeg(a.unitPriceHalalas, `addon ${a.addonId} price`);
    assertInt(a.quantity, `addon ${a.addonId} quantity`);
    if (a.quantity < 1) throw new PricingError('INVALID_ADDON_QTY', `Add-on ${a.addonId} quantity must be ≥ 1`);
    if (a.maxQuantity !== undefined && a.quantity > a.maxQuantity) {
      throw new PricingError('INVALID_ADDON_QTY', `Add-on ${a.addonId} allows at most ${a.maxQuantity}`);
    }
    const line = a.unitPriceHalalas * a.quantity;
    if (a.collection === 'ONLINE_DEPOSIT') {
      onlineAddons += line;
      if (a.fulfilledBy === 'OWNER') ownerPayable += line;
    } else {
      dockAddons += line;
    }
  }

  // 4. Commission (trip only; add-ons are pass-through)
  const grossCommission = applyBps(tripSubtotal, input.commissionBps);
  const balanceAtDock = tripSubtotal - grossCommission + dockAddons;

  // 5. Affiliate — funded exclusively from the platform commission, with a margin floor
  const platformFloor = applyBps(grossCommission, policy.minPlatformMarginBps);
  let clientDiscount = 0;
  let partnerEarning = 0;
  let clamped = false;
  if (input.affiliate) {
    assertBps(input.affiliate.clientDiscountBps, 'clientDiscountBps');
    assertBps(input.affiliate.partnerCommissionBps, 'partnerCommissionBps');
    const room = grossCommission - platformFloor; // what discount + partner may consume
    const wantedDiscount = applyBps(tripSubtotal, input.affiliate.clientDiscountBps);
    clientDiscount = Math.min(wantedDiscount, room);
    const net = grossCommission - clientDiscount;
    const wantedPartner = applyBps(net, input.affiliate.partnerCommissionBps);
    partnerEarning = Math.min(wantedPartner, room - clientDiscount);
    clamped = clientDiscount < wantedDiscount || partnerEarning < wantedPartner;
  }
  const netCommission = grossCommission - clientDiscount;
  const platformNetRevenue = netCommission - partnerEarning;

  // 6. Online deposit and reschedule credit
  const deposit = netCommission + onlineAddons;
  const credit = Math.max(0, input.rescheduleCreditHalalas ?? 0);
  assertInt(credit, 'rescheduleCredit');
  const creditApplied = Math.min(credit, deposit);
  const dueNow = deposit - creditApplied;

  if (dueNow > 0 && dueNow < policy.minOnlineChargeHalalas) {
    throw new PricingError(
      'BELOW_GATEWAY_MINIMUM',
      `Online amount ${dueNow} halalas is below the gateway minimum ${policy.minOnlineChargeHalalas}`,
    );
  }

  const result: QuoteBreakdown = {
    dayType,
    dayTypeLabel: label,
    dayRateHalalas: dayRate,
    extraGuests,
    extraGuestFeeHalalas: extraGuestFee,
    tripSubtotalHalalas: tripSubtotal,
    onlineAddonsHalalas: onlineAddons,
    dockAddonsHalalas: dockAddons,
    ownerPayableFromOnlineAddons: ownerPayable,
    totalListPriceHalalas: tripSubtotal + onlineAddons + dockAddons,
    commissionBps: input.commissionBps,
    grossCommissionHalalas: grossCommission,
    clientDiscountHalalas: clientDiscount,
    netCommissionHalalas: netCommission,
    partnerEarningHalalas: partnerEarning,
    platformNetRevenueHalalas: platformNetRevenue,
    affiliateClamped: clamped,
    depositHalalas: deposit,
    rescheduleCreditAppliedHalalas: creditApplied,
    amountDueOnlineNowHalalas: dueNow,
    balanceDueToCaptainHalalas: balanceAtDock,
    clientTotalHalalas: deposit + balanceAtDock,
  };

  assertInvariants(result);
  return result;
}

/** Ledger invariants. A violation is a bug, never a user error. */
export function assertInvariants(q: QuoteBreakdown): void {
  const checks: Array<[boolean, string]> = [
    [q.clientTotalHalalas === q.totalListPriceHalalas - q.clientDiscountHalalas, 'client total = list − discount'],
    [q.depositHalalas + q.balanceDueToCaptainHalalas === q.clientTotalHalalas, 'deposit + dock balance = client total'],
    [q.balanceDueToCaptainHalalas === q.tripSubtotalHalalas - q.grossCommissionHalalas + q.dockAddonsHalalas, 'captain balance independent of affiliate'],
    [q.platformNetRevenueHalalas + q.partnerEarningHalalas + q.clientDiscountHalalas === q.grossCommissionHalalas, 'commission fully allocated'],
    [q.platformNetRevenueHalalas >= 0 && q.partnerEarningHalalas >= 0 && q.clientDiscountHalalas >= 0, 'no negative allocations'],
    [q.amountDueOnlineNowHalalas >= 0, 'non-negative online charge'],
  ];
  for (const [ok, name] of checks) {
    if (!ok) throw new PricingError('INVARIANT_BROKEN', `Pricing invariant failed: ${name}`);
  }
}

/** Display helper: 45000 → "450.00 SAR". */
export function formatSar(halalas: number): string {
  const sign = halalas < 0 ? '-' : '';
  const abs = Math.abs(halalas);
  return `${sign}${Math.floor(abs / 100).toLocaleString('en-US')}.${String(abs % 100).padStart(2, '0')} SAR`;
}

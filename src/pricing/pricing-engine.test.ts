// Run: node --experimental-strip-types --test src/pricing/pricing-engine.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  quote, resolveDayType, applyBps, PricingError,
  type QuoteInput, type CalendarOverride, type DestinationPricing,
} from './pricing-engine.ts';

const SAR = (n: number) => Math.round(n * 100);

const calendar = new Map<string, CalendarOverride>([
  ['2026-09-23', { date: '2026-09-23', dayType: 'HOLIDAY', label: 'Saudi National Day' }],
  ['2027-02-22', { date: '2027-02-22', dayType: 'HOLIDAY', label: 'Founding Day' }],
]);

const dest: DestinationPricing = {
  destinationId: 'obhur-reef',
  weekdayPriceHalalas: SAR(3000),
  weekendPriceHalalas: SAR(3500),
  holidayPriceHalalas: SAR(4000),
  baseCapacity: 7,
  extraPersonFeeHalalas: SAR(150),
};

const base = (over: Partial<QuoteInput> = {}): QuoteInput => ({
  tripDate: '2026-10-13', // Tuesday
  guests: 6,
  destination: dest,
  boat: { boatId: 'b1', maxCapacity: 10 },
  commissionBps: 1500,
  addons: [],
  calendar,
  policy: { minPlatformMarginBps: 3000, minOnlineChargeHalalas: 100 },
  ...over,
});

test('brief example: 3,000 SAR weekday trip at 15% → 450 online, 2,550 at the dock', () => {
  const q = quote(base());
  assert.equal(q.dayType, 'WEEKDAY');
  assert.equal(q.depositHalalas, SAR(450));
  assert.equal(q.amountDueOnlineNowHalalas, SAR(450));
  assert.equal(q.balanceDueToCaptainHalalas, SAR(2550));
  assert.equal(q.clientTotalHalalas, SAR(3000));
});

test('KSA weekend is Friday and Saturday; holidays come from the admin calendar', () => {
  assert.equal(resolveDayType('2026-10-15', calendar).dayType, 'WEEKDAY'); // Thu
  assert.equal(resolveDayType('2026-10-16', calendar).dayType, 'WEEKEND'); // Fri
  assert.equal(resolveDayType('2026-10-17', calendar).dayType, 'WEEKEND'); // Sat
  assert.equal(resolveDayType('2026-10-18', calendar).dayType, 'WEEKDAY'); // Sun
  const h = resolveDayType('2026-09-23', calendar);
  assert.deepEqual(h, { dayType: 'HOLIDAY', label: 'Saudi National Day' });
});

test('weekend trip with extra guests, an online add-on and a dock add-on at 20%', () => {
  const q = quote(base({
    tripDate: '2026-10-16',
    guests: 9,
    commissionBps: 2000,
    addons: [
      { addonId: 'drone', name: 'Drone video', unitPriceHalalas: SAR(400), quantity: 1, collection: 'ONLINE_DEPOSIT', fulfilledBy: 'PLATFORM' },
      { addonId: 'seabob', name: 'Seabob', unitPriceHalalas: SAR(600), quantity: 1, collection: 'AT_DOCK', fulfilledBy: 'OWNER' },
    ],
  }));
  assert.equal(q.extraGuests, 2);
  assert.equal(q.tripSubtotalHalalas, SAR(3800));        // 3,500 + 2 × 150
  assert.equal(q.grossCommissionHalalas, SAR(760));      // 20% of trip only
  assert.equal(q.depositHalalas, SAR(1160));             // 760 + 400 (once)
  assert.equal(q.balanceDueToCaptainHalalas, SAR(3640)); // 3,800 − 760 + 600
  assert.equal(q.totalListPriceHalalas, SAR(4800));
  assert.equal(q.clientTotalHalalas, SAR(4800));
});

test("the brief's original formula double-charges online add-ons (regression guard)", () => {
  // Brief: deposit = (Total − dockAddons) × rate + onlineAddons
  const total = SAR(4800), dock = SAR(600), online = SAR(400), rate = 0.2;
  const briefDeposit = (total - dock) * rate + online; // 1,240 SAR
  const q = quote(base({
    tripDate: '2026-10-16', guests: 9, commissionBps: 2000,
    addons: [
      { addonId: 'drone', name: 'Drone', unitPriceHalalas: online, quantity: 1, collection: 'ONLINE_DEPOSIT', fulfilledBy: 'PLATFORM' },
      { addonId: 'seabob', name: 'Seabob', unitPriceHalalas: dock, quantity: 1, collection: 'AT_DOCK', fulfilledBy: 'OWNER' },
    ],
  }));
  assert.equal(briefDeposit - q.depositHalalas, SAR(80)); // 20% of the 400 drone charged a second time
});

test('affiliate 5% client discount + 10% partner share is paid from the commission only', () => {
  const q = quote(base({ affiliate: { affiliateId: 'inf-1', clientDiscountBps: 500, partnerCommissionBps: 1000 } }));
  assert.equal(q.clientDiscountHalalas, SAR(150));       // 5% of 3,000
  assert.equal(q.netCommissionHalalas, SAR(300));
  assert.equal(q.partnerEarningHalalas, SAR(30));        // 10% of 300
  assert.equal(q.platformNetRevenueHalalas, SAR(270));
  assert.equal(q.depositHalalas, SAR(300));
  assert.equal(q.balanceDueToCaptainHalalas, SAR(2550)); // unchanged
  assert.equal(q.affiliateClamped, false);
});

test('aggressive affiliate terms are clamped to the platform margin floor, never the captain', () => {
  const q = quote(base({ affiliate: { affiliateId: 'agency-9', clientDiscountBps: 1000, partnerCommissionBps: 5000 } }));
  // gross 450, floor 30% = 135, room 315; discount wants 300 → 300; partner wants 75 → 15
  assert.equal(q.grossCommissionHalalas, SAR(450));
  assert.equal(q.clientDiscountHalalas, SAR(300));
  assert.equal(q.partnerEarningHalalas, SAR(15));
  assert.equal(q.platformNetRevenueHalalas, SAR(135));
  assert.equal(q.balanceDueToCaptainHalalas, SAR(2550));
  assert.equal(q.affiliateClamped, true);
});

test('holiday rebooking with a reschedule pass charges only the difference', () => {
  const original = quote(base());                                   // deposit 450
  const rebook = quote(base({ tripDate: '2026-09-23', rescheduleCreditHalalas: original.depositHalalas }));
  assert.equal(rebook.dayType, 'HOLIDAY');
  assert.equal(rebook.depositHalalas, SAR(600));                    // 15% of 4,000
  assert.equal(rebook.amountDueOnlineNowHalalas, SAR(150));
  assert.equal(rebook.balanceDueToCaptainHalalas, SAR(3400));

  const cheaper = quote(base({ tripDate: '2026-10-14', rescheduleCreditHalalas: SAR(600) }));
  assert.equal(cheaper.amountDueOnlineNowHalalas, 0);              // excess credit is not refunded
  assert.equal(cheaper.rescheduleCreditAppliedHalalas, SAR(450));
});

test('capacity rules', () => {
  assert.throws(() => quote(base({ guests: 11 })), (e: unknown) => e instanceof PricingError && e.code === 'OVER_CAPACITY');
  assert.throws(() => quote(base({ guests: 0 })), (e: unknown) => e instanceof PricingError && e.code === 'INVALID_GUESTS');
  assert.equal(quote(base({ guests: 7 })).extraGuests, 0);
  assert.equal(quote(base({ guests: 10 })).extraGuestFeeHalalas, SAR(450));
});

test('integer rounding is half-up to the halala', () => {
  assert.equal(applyBps(33333, 1500), 5000); // 4,999.95 → 5,000
  assert.equal(applyBps(33330, 1500), 5000); // 4,999.5 → 5,000
  assert.equal(applyBps(33329, 1500), 4999); // 4,999.35 → 4,999
});

test('rejects impossible dates and non-integer money', () => {
  assert.throws(() => quote(base({ tripDate: '2026-02-30' })), (e: unknown) => e instanceof PricingError && e.code === 'INVALID_DATE');
  assert.throws(() => quote(base({ destination: { ...dest, weekdayPriceHalalas: 3000.5 } })), PricingError);
});

test('online add-on fulfilled by the owner is reported as payable to the owner', () => {
  const q = quote(base({
    addons: [{ addonId: 'catering', name: 'Catering', unitPriceHalalas: SAR(250), quantity: 2, collection: 'ONLINE_DEPOSIT', fulfilledBy: 'OWNER' }],
  }));
  assert.equal(q.onlineAddonsHalalas, SAR(500));
  assert.equal(q.ownerPayableFromOnlineAddons, SAR(500));
  assert.equal(q.depositHalalas, SAR(950));
});

test('invariants hold across a randomized sweep', () => {
  let seed = 42;
  const rnd = (n: number) => { seed = (seed * 1103515245 + 12345) % 2 ** 31; return seed % n; };
  for (let i = 0; i < 5000; i++) {
    const q = quote(base({
      guests: 1 + rnd(10),
      commissionBps: 500 + rnd(2500),
      destination: { ...dest, weekdayPriceHalalas: 10000 + rnd(2_000_000) },
      addons: rnd(2) ? [{ addonId: 'x', name: 'x', unitPriceHalalas: rnd(100000), quantity: 1 + rnd(3), collection: rnd(2) ? 'ONLINE_DEPOSIT' : 'AT_DOCK', fulfilledBy: 'PLATFORM' }] : [],
      affiliate: rnd(2) ? { affiliateId: 'a', clientDiscountBps: rnd(2000), partnerCommissionBps: rnd(6000) } : undefined,
      policy: { minPlatformMarginBps: rnd(5000), minOnlineChargeHalalas: 0 },
    }));
    assert.ok(q.platformNetRevenueHalalas >= 0);
  }
});

// Run: node --experimental-strip-types --test src/booking/availability.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { computeAvailability, riyadh, type ShiftRule } from './slot-hold.service.ts';

const fixed: ShiftRule[] = [
  { scheduleId: 'am', slotMode: 'FIXED', nameEn: 'Morning shift', nameAr: 'الفترة الصباحية', weekdayMask: 127, startTime: '06:00', endTime: '12:00', slotStepMinutes: 30, validFrom: '2026-01-01' },
  { scheduleId: 'pm', slotMode: 'FIXED', nameEn: 'Sunset shift', nameAr: 'فترة الغروب', weekdayMask: 127, startTime: '13:00', endTime: '19:00', slotStepMinutes: 30, validFrom: '2026-01-01' },
];
const now = new Date('2026-10-13T12:00:00+03:00');

test('FIXED: both shifts free when nothing is booked', () => {
  const s = computeAvailability({ date: '2026-10-16', rules: fixed, busy: [], bufferMinutes: 45, durationMinutes: 0, now, leadMinutes: 120 });
  assert.deepEqual(s.map((x) => x.scheduleId), ['am', 'pm']);
});

test('FIXED: morning booking + 45-min buffer still leaves the 13:00 shift (60-min gap)', () => {
  const busy = [{ start: riyadh('2026-10-16', '06:00'), end: riyadh('2026-10-16', '12:45') }];
  const s = computeAvailability({ date: '2026-10-16', rules: fixed, busy, bufferMinutes: 45, durationMinutes: 0, now, leadMinutes: 120 });
  assert.deepEqual(s.map((x) => x.scheduleId), ['pm']);
});

test('FIXED: a 90-min buffer would collide with the sunset shift', () => {
  const busy = [{ start: riyadh('2026-10-16', '06:00'), end: riyadh('2026-10-16', '13:30') }];
  const s = computeAvailability({ date: '2026-10-16', rules: fixed, busy, bufferMinutes: 90, durationMinutes: 0, now, leadMinutes: 120 });
  assert.deepEqual(s.map((x) => x.scheduleId), []);
});

test('OPEN: 3-hour trips stepped every 30 min around an existing booking', () => {
  const open: ShiftRule[] = [{ scheduleId: 'open', slotMode: 'OPEN', nameEn: 'Custom', nameAr: 'مخصص', weekdayMask: 127, startTime: '08:00', endTime: '18:00', slotStepMinutes: 30, validFrom: '2026-01-01' }];
  // booked 12:00–14:00, blocked to 14:30 with 30-min buffer
  const busy = [{ start: riyadh('2026-10-16', '12:00'), end: riyadh('2026-10-16', '14:30') }];
  const s = computeAvailability({ date: '2026-10-16', rules: open, busy, bufferMinutes: 30, durationMinutes: 180, now, leadMinutes: 120 });
  const starts = s.map((x) => x.start.toISOString().slice(11, 16));
  // Riyadh = UTC+3: 08:00 → 05:00Z. Last start before the booking must end + buffer ≤ 12:00 → 08:30.
  assert.deepEqual(starts, ['05:00', '05:30', '11:30', '12:00']); // 08:00, 08:30, 14:30, 15:00 local
});

test('lead time hides slots that start too soon; weekday mask filters days', () => {
  const s = computeAvailability({ date: '2026-10-13', rules: fixed, busy: [], bufferMinutes: 45, durationMinutes: 0, now, leadMinutes: 120 });
  assert.deepEqual(s.map((x) => x.scheduleId), []); // now = 12:00, pm at 13:00 is < 2 h away
  const fridayOnly = fixed.map((r) => ({ ...r, weekdayMask: 1 << 5 }));
  assert.equal(computeAvailability({ date: '2026-10-15', rules: fridayOnly, busy: [], bufferMinutes: 45, durationMinutes: 0, now, leadMinutes: 0 }).length, 0);
  assert.equal(computeAvailability({ date: '2026-10-16', rules: fridayOnly, busy: [], bufferMinutes: 45, durationMinutes: 0, now, leadMinutes: 0 }).length, 2);
});

test('overnight shift ends the next day', () => {
  const night: ShiftRule[] = [{ scheduleId: 'night', slotMode: 'FIXED', nameEn: 'Night', nameAr: 'ليلية', weekdayMask: 127, startTime: '20:00', endTime: '02:00', slotStepMinutes: 30, validFrom: '2026-01-01' }];
  const [s] = computeAvailability({ date: '2026-10-16', rules: night, busy: [], bufferMinutes: 45, durationMinutes: 0, now, leadMinutes: 0 });
  assert.equal((s.end.getTime() - s.start.getTime()) / 3.6e6, 6);
});

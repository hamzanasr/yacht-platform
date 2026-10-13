-- Integration checks for schema.sql. Run inside a throwaway database:
--   psql -v ON_ERROR_STOP=1 -f schema.sql && psql -v ON_ERROR_STOP=1 -f test_schema.sql
-- Every block raises on failure; a clean run prints "ALL SCHEMA CHECKS PASSED".
BEGIN;

-- Seed
INSERT INTO regions (id, code, name_ar, name_en) VALUES ('00000000-0000-0000-0000-000000000001','MAKKAH','منطقة مكة','Makkah Region');
INSERT INTO cities (id, region_id, slug, name_ar, name_en, is_live)
  VALUES ('00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','jeddah','جدة','Jeddah', true);
INSERT INTO marinas (id, city_id, slug, name_ar, name_en, latitude, longitude)
  VALUES ('00000000-0000-0000-0000-000000000100','00000000-0000-0000-0000-000000000010','obhur-north','أبحر الشمالية','Obhur North', 21.758000, 39.105000);
INSERT INTO users (id, phone_e164, full_name, roles) VALUES
  ('00000000-0000-0000-0000-00000000a001','+966500000001','Owner One', ARRAY['OWNER']::user_role[]),
  ('00000000-0000-0000-0000-00000000a002','+966500000002','Client One', ARRAY['CLIENT']::user_role[]),
  ('00000000-0000-0000-0000-00000000a003','+966500000003','Client Two', ARRAY['CLIENT']::user_role[]),
  ('00000000-0000-0000-0000-00000000a004','+966500000004','Influencer', ARRAY['AFFILIATE']::user_role[]);
INSERT INTO owners (id, user_id, legal_name, default_commission_bps, whatsapp_e164, is_approved)
  VALUES ('00000000-0000-0000-0000-00000000b001','00000000-0000-0000-0000-00000000a001','Owner One Est.',1500,'+966500000001',true);
INSERT INTO boats (id, owner_id, home_marina_id, slug, name_ar, name_en, boat_type, registration_number, registration_expiry,
                   base_capacity, max_capacity, buffer_minutes)
  VALUES ('00000000-0000-0000-0000-00000000c001','00000000-0000-0000-0000-00000000b001','00000000-0000-0000-0000-000000000100',
          'sea-breeze','نسيم البحر','Sea Breeze','YACHT','JED-123','2027-12-31', 7, 10, 45);
INSERT INTO destinations_pricing (id, boat_id, route_name_ar, route_name_en, duration_minutes,
                                  weekday_price_halalas, weekend_price_halalas, holiday_price_halalas, base_capacity, extra_person_fee_halalas)
  VALUES ('00000000-0000-0000-0000-00000000d001','00000000-0000-0000-0000-00000000c001','شعب أبحر','Obhur Reef',240, 300000, 350000, 400000, 7, 15000);

-- 1. Destination base capacity may not exceed boat max
DO $$ BEGIN
  BEGIN
    INSERT INTO destinations_pricing (boat_id, route_name_ar, route_name_en, duration_minutes,
      weekday_price_halalas, weekend_price_halalas, holiday_price_halalas, base_capacity)
    VALUES ('00000000-0000-0000-0000-00000000c001','x','x',60,1,1,1, 12);
    RAISE EXCEPTION 'FAIL: capacity trigger';
  EXCEPTION WHEN check_violation THEN NULL; END;
END $$;

-- 2. Holds: first wins, overlap rejected, buffer enforced, back-to-back after buffer OK
DO $$
DECLARE r1 uuid; r2 uuid;
BEGIN
  r1 := fn_hold_slot('00000000-0000-0000-0000-00000000c001', '2026-10-16 06:00+03', '2026-10-16 12:00+03', gen_random_uuid(), 600, NULL);

  BEGIN  -- exact overlap
    PERFORM fn_hold_slot('00000000-0000-0000-0000-00000000c001', '2026-10-16 10:00+03', '2026-10-16 14:00+03', gen_random_uuid(), 600, NULL);
    RAISE EXCEPTION 'FAIL: overlap accepted';
  EXCEPTION WHEN exclusion_violation THEN NULL; END;

  BEGIN  -- starts inside the 45-min buffer
    PERFORM fn_hold_slot('00000000-0000-0000-0000-00000000c001', '2026-10-16 12:30+03', '2026-10-16 16:00+03', gen_random_uuid(), 600, NULL);
    RAISE EXCEPTION 'FAIL: buffer not enforced';
  EXCEPTION WHEN exclusion_violation THEN NULL; END;

  BEGIN  -- earlier trip whose own buffer runs into the 06:00 start
    PERFORM fn_hold_slot('00000000-0000-0000-0000-00000000c001', '2026-10-16 03:00+03', '2026-10-16 05:30+03', gen_random_uuid(), 600, NULL);
    RAISE EXCEPTION 'FAIL: leading buffer not enforced';
  EXCEPTION WHEN exclusion_violation THEN NULL; END;

  r2 := fn_hold_slot('00000000-0000-0000-0000-00000000c001', '2026-10-16 12:45+03', '2026-10-16 19:00+03', gen_random_uuid(), 600, NULL);
  IF r2 IS NULL THEN RAISE EXCEPTION 'FAIL: back-to-back after buffer rejected'; END IF;
END $$;

-- 3. An expired hold is reclaimed by the next hold on that slot
DO $$
DECLARE r uuid;
BEGIN
  INSERT INTO boat_reservations (boat_id, kind, status, trip_range, blocked_range, buffer_minutes, hold_token, hold_expires_at)
  VALUES ('00000000-0000-0000-0000-00000000c001','BOOKING','HOLD',
          tstzrange('2026-10-20 06:00+03','2026-10-20 12:00+03'), tstzrange('2026-10-20 06:00+03','2026-10-20 12:45+03'),
          45, gen_random_uuid(), now() - interval '1 minute');
  r := fn_hold_slot('00000000-0000-0000-0000-00000000c001', '2026-10-20 08:00+03', '2026-10-20 11:00+03', gen_random_uuid(), 600, NULL);
  IF (SELECT count(*) FROM boat_reservations WHERE status = 'RELEASED' AND lower(trip_range) = '2026-10-20 06:00+03') <> 1 THEN
    RAISE EXCEPTION 'FAIL: expired hold not released';
  END IF;
END $$;

-- 4. Released reservations stop blocking
DO $$ BEGIN
  UPDATE boat_reservations SET status = 'RELEASED', released_at = now()
   WHERE lower(trip_range) = '2026-10-20 08:00+03';
  PERFORM fn_hold_slot('00000000-0000-0000-0000-00000000c001', '2026-10-20 08:00+03', '2026-10-20 11:00+03', gen_random_uuid(), 600, NULL);
END $$;

-- 5. Booking ledger constraints (values = pricing-engine scenario 3: affiliate 5% / 10%)
INSERT INTO affiliates (id, user_id, partner_type, display_name, referral_code, client_discount_pct_bps, affiliate_commission_pct_bps, status)
  VALUES ('00000000-0000-0000-0000-00000000e001','00000000-0000-0000-0000-00000000a004','INFLUENCER','Sara Trips','SARA5', 500, 1000, 'APPROVED');

INSERT INTO bookings (id, booking_number, client_id, boat_id, owner_id, marina_id, destination_id, reservation_id,
  trip_start, trip_end, guests, day_type, day_rate_halalas, extra_guests, extra_guest_fee_halalas, trip_subtotal_halalas,
  total_amount, commission_bps, gross_commission_halalas, client_discount_halalas, partner_earning_halalas, platform_net_halalas,
  deposit_amount, amount_due_online_halalas, balance_due_to_captain, client_total_halalas, pricing_snapshot, affiliate_id, idempotency_key)
SELECT '00000000-0000-0000-0000-0000000f0001','JED-261016-AAAA','00000000-0000-0000-0000-00000000a002',
  '00000000-0000-0000-0000-00000000c001','00000000-0000-0000-0000-00000000b001','00000000-0000-0000-0000-000000000100',
  '00000000-0000-0000-0000-00000000d001', id, lower(trip_range), upper(trip_range), 6, 'WEEKDAY', 300000, 0, 0, 300000,
  300000, 1500, 45000, 15000, 3000, 27000, 30000, 30000, 255000, 285000, '{}'::jsonb, '00000000-0000-0000-0000-00000000e001', 'idem-1'
FROM boat_reservations WHERE lower(trip_range) = '2026-10-16 06:00+03';

DO $$ BEGIN
  BEGIN  -- captain balance tampered by a "discount": must be rejected
    INSERT INTO bookings (booking_number, client_id, boat_id, owner_id, marina_id, destination_id, reservation_id,
      trip_start, trip_end, guests, day_type, day_rate_halalas, extra_guests, extra_guest_fee_halalas, trip_subtotal_halalas,
      total_amount, commission_bps, gross_commission_halalas, platform_net_halalas,
      deposit_amount, amount_due_online_halalas, balance_due_to_captain, client_total_halalas, pricing_snapshot, idempotency_key)
    SELECT 'JED-BAD', '00000000-0000-0000-0000-00000000a003', '00000000-0000-0000-0000-00000000c001','00000000-0000-0000-0000-00000000b001',
      '00000000-0000-0000-0000-000000000100','00000000-0000-0000-0000-00000000d001', id, lower(trip_range), upper(trip_range), 6,
      'WEEKDAY', 300000, 0, 0, 300000, 300000, 1500, 45000, 45000, 45000, 45000, 240000, 285000, '{}'::jsonb, 'idem-bad'
    FROM boat_reservations WHERE lower(trip_range) = '2026-10-16 12:45+03';
    RAISE EXCEPTION 'FAIL: inconsistent split accepted';
  EXCEPTION WHEN check_violation THEN NULL; END;
END $$;

-- 6. Voucher cannot be issued before the manifest; manifest capped at guest count
DO $$ BEGIN
  BEGIN
    UPDATE bookings SET voucher_issued_at = now() WHERE booking_number = 'JED-261016-AAAA';
    RAISE EXCEPTION 'FAIL: voucher without manifest';
  EXCEPTION WHEN check_violation THEN NULL; END;
END $$;

INSERT INTO booking_passengers (booking_id, seq, full_name, id_type, id_number_ciphertext, id_number_hmac, id_number_last4, is_lead_passenger)
SELECT '00000000-0000-0000-0000-0000000f0001', g, 'Passenger ' || g, 'NATIONAL_ID', '\x00'::bytea, decode(md5(g::text), 'hex'), '000' || g, g = 1
FROM generate_series(1, 6) g;

DO $$ BEGIN
  BEGIN
    INSERT INTO booking_passengers (booking_id, seq, full_name, id_type, id_number_ciphertext, id_number_hmac, id_number_last4)
    VALUES ('00000000-0000-0000-0000-0000000f0001', 7, 'Seventh Guest', 'PASSPORT', '\x00', '\x07', '0007');
    RAISE EXCEPTION 'FAIL: manifest over capacity';
  EXCEPTION WHEN check_violation THEN NULL; END;
END $$;

UPDATE bookings SET payment_status = 'PAID', manifest_submitted_at = now(), voucher_issued_at = now(), booking_status = 'CONFIRMED'
 WHERE booking_number = 'JED-261016-AAAA';

-- 7. Pricing frozen after payment
DO $$ BEGIN
  BEGIN
    UPDATE bookings SET deposit_amount = 1, amount_due_online_halalas = 1, balance_due_to_captain = 284999
     WHERE booking_number = 'JED-261016-AAAA';
    RAISE EXCEPTION 'FAIL: pricing editable after payment';
  EXCEPTION WHEN check_violation THEN NULL; END;
END $$;

-- 8. Affiliate ledger: one earning per booking, append-only, wallet view
INSERT INTO affiliate_transactions (affiliate_id, booking_id, txn_type, status, amount_halalas)
  VALUES ('00000000-0000-0000-0000-00000000e001','00000000-0000-0000-0000-0000000f0001','EARNING','PENDING', 3000);
DO $$ BEGIN
  BEGIN
    INSERT INTO affiliate_transactions (affiliate_id, booking_id, txn_type, status, amount_halalas)
      VALUES ('00000000-0000-0000-0000-00000000e001','00000000-0000-0000-0000-0000000f0001','EARNING','PENDING', 3000);
    RAISE EXCEPTION 'FAIL: duplicate earning';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  BEGIN
    UPDATE affiliate_transactions SET amount_halalas = 999999 WHERE booking_id = '00000000-0000-0000-0000-0000000f0001';
    RAISE EXCEPTION 'FAIL: ledger mutable';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;
END $$;
UPDATE affiliate_transactions SET status = 'AVAILABLE', available_at = now() WHERE booking_id = '00000000-0000-0000-0000-0000000f0001';
DO $$ BEGIN
  IF (SELECT wallet_balance FROM affiliate_wallets WHERE affiliate_id = '00000000-0000-0000-0000-00000000e001') <> 3000 THEN
    RAISE EXCEPTION 'FAIL: wallet view';
  END IF;
END $$;

-- 9. Reschedule pass integrity
INSERT INTO users (id, phone_e164, full_name, roles) VALUES ('00000000-0000-0000-0000-00000000a005','+966500000005','Admin', ARRAY['ADMIN']::user_role[]);
INSERT INTO sailing_suspensions (id, city_id, reason, suspension_window, declared_by)
  VALUES ('00000000-0000-0000-0000-0000000aa001','00000000-0000-0000-0000-000000000010','WEATHER',
          tstzrange('2026-10-16 00:00+03','2026-10-17 00:00+03'),'00000000-0000-0000-0000-00000000a005');
INSERT INTO reschedule_passes (code, original_booking_id, client_id, reason, suspension_id, credit_amount, expiry_date)
  VALUES ('RSP-TEST-0001','00000000-0000-0000-0000-0000000f0001','00000000-0000-0000-0000-00000000a002','SUSPENSION',
          '00000000-0000-0000-0000-0000000aa001', 30000, now() + interval '90 days');
DO $$ BEGIN
  BEGIN
    UPDATE reschedule_passes SET status = 'REDEEMED' WHERE code = 'RSP-TEST-0001';
    RAISE EXCEPTION 'FAIL: redeemed without target booking';
  EXCEPTION WHEN check_violation THEN NULL; END;
END $$;

-- 10. RLS: another owner sees nothing
CREATE ROLE app_user NOLOGIN;
GRANT SELECT ON bookings TO app_user;
SET LOCAL ROLE app_user;
SET LOCAL app.owner_id = '00000000-0000-0000-0000-0000000fffff';
DO $$ BEGIN
  IF (SELECT count(*) FROM bookings) <> 0 THEN RAISE EXCEPTION 'FAIL: RLS leak'; END IF;
END $$;
SET LOCAL app.owner_id = '00000000-0000-0000-0000-00000000b001';
DO $$ BEGIN
  IF (SELECT count(*) FROM bookings) <> 1 THEN RAISE EXCEPTION 'FAIL: RLS hides own booking'; END IF;
END $$;
RESET ROLE;

DO $$ BEGIN RAISE NOTICE 'ALL SCHEMA CHECKS PASSED'; END $$;
ROLLBACK;

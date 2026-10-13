-- =============================================================================
-- Yacht & Boat Charter Marketplace (KSA) — PostgreSQL 15+ schema
-- =============================================================================
-- Conventions
--   * Money: BIGINT halalas (1 SAR = 100). Rates: INTEGER basis points (1% = 100).
--   * Time: TIMESTAMPTZ everywhere; business timezone Asia/Riyadh (UTC+3, no DST).
--   * Bilingual text: *_ar (default) + *_en.
--   * Double-booking is made impossible by the EXCLUDE constraint on
--     boat_reservations.blocked_range — Redis holds are an optimisation on top.
--   * Passenger ID numbers are encrypted by the application (AES-256-GCM, key in
--     KMS); the DB stores ciphertext + HMAC blind index + last 4 digits only.
-- =============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- '=' on uuid inside GiST exclusion
CREATE EXTENSION IF NOT EXISTS citext;      -- case-insensitive emails / codes

-- ───────────────────────────── Enums ─────────────────────────────
CREATE TYPE user_role            AS ENUM ('CLIENT','OWNER','CAPTAIN','AFFILIATE','ADMIN','OPS');
CREATE TYPE id_type              AS ENUM ('NATIONAL_ID','IQAMA','PASSPORT');
CREATE TYPE day_type             AS ENUM ('WEEKDAY','WEEKEND','HOLIDAY');
CREATE TYPE slot_mode            AS ENUM ('FIXED','OPEN');
CREATE TYPE addon_collection     AS ENUM ('ONLINE_DEPOSIT','AT_DOCK');
CREATE TYPE addon_fulfiller      AS ENUM ('PLATFORM','OWNER');
CREATE TYPE reservation_kind     AS ENUM ('BOOKING','MAINTENANCE','OWNER_BLOCK');
CREATE TYPE reservation_status   AS ENUM ('HOLD','BOOKED','RELEASED');
CREATE TYPE booking_status       AS ENUM (
  'PENDING_PAYMENT',        -- hold taken, awaiting Moyasar
  'PENDING_MANIFEST',       -- paid; voucher withheld until manifest is complete
  'CONFIRMED',              -- paid + manifest; voucher issued
  'EMERGENCY_RESCHEDULED',  -- sailing suspended; pass issued
  'CANCELLED_BY_CLIENT',    -- deposit forfeited
  'CANCELLED_BY_OWNER',     -- refund or pass, client's choice
  'NO_SHOW',
  'COMPLETED',
  'EXPIRED'                 -- checkout abandoned
);
CREATE TYPE payment_status       AS ENUM ('INITIATED','PAID','FAILED','REFUNDED','PARTIALLY_REFUNDED','VOIDED','NOT_REQUIRED');
CREATE TYPE partner_type         AS ENUM ('INFLUENCER','TRAVEL_AGENCY','CORPORATE');
CREATE TYPE partner_status       AS ENUM ('PENDING','APPROVED','SUSPENDED');
CREATE TYPE affiliate_txn_type   AS ENUM ('EARNING','REVERSAL','PAYOUT','ADJUSTMENT');
CREATE TYPE affiliate_txn_status AS ENUM ('PENDING','AVAILABLE','PAID','VOID');
CREATE TYPE suspension_reason    AS ENUM ('COAST_GUARD','WEATHER','OTHER_AUTHORITY');
CREATE TYPE pass_reason          AS ENUM ('SUSPENSION','OWNER_CANCELLATION','ADMIN_GOODWILL');
CREATE TYPE pass_status          AS ENUM ('ACTIVE','REDEEMED','EXPIRED','VOID');
CREATE TYPE notify_channel       AS ENUM ('WHATSAPP','SMS','EMAIL','PUSH');
CREATE TYPE notify_status        AS ENUM ('QUEUED','SENT','DELIVERED','FAILED','DEAD');

-- ───────────────────────── Shared trigger ─────────────────────────
CREATE OR REPLACE FUNCTION trg_touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

-- ───────────────────────────── Identity ─────────────────────────────
CREATE TABLE users (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone_e164       text NOT NULL UNIQUE CHECK (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  email            citext UNIQUE,
  full_name        text NOT NULL CHECK (length(btrim(full_name)) > 0),
  roles            user_role[] NOT NULL DEFAULT ARRAY['CLIENT']::user_role[],
  preferred_locale text NOT NULL DEFAULT 'ar' CHECK (preferred_locale IN ('ar','en')),
  phone_verified_at timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz
);
CREATE INDEX users_roles_gin ON users USING gin (roles);
CREATE TRIGGER users_touch BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION trg_touch_updated_at();

-- ───────────────────────────── Geography ─────────────────────────────
CREATE TABLE regions (
  id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code     text NOT NULL UNIQUE,            -- e.g. 'MAKKAH', 'EASTERN'
  name_ar  text NOT NULL,
  name_en  text NOT NULL
);

CREATE TABLE cities (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  region_id  uuid NOT NULL REFERENCES regions(id),
  slug       text NOT NULL UNIQUE,          -- 'jeddah', 'yanbu', 'rabigh', 'dammam'
  name_ar    text NOT NULL,
  name_en    text NOT NULL,
  timezone   text NOT NULL DEFAULT 'Asia/Riyadh',
  is_live    boolean NOT NULL DEFAULT false -- launch switch per city
);

CREATE TABLE marinas (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  city_id          uuid NOT NULL REFERENCES cities(id),
  slug             text NOT NULL UNIQUE,    -- 'obhur-north', 'durrat-al-arus', ...
  name_ar          text NOT NULL,
  name_en          text NOT NULL,
  latitude         numeric(9,6) NOT NULL CHECK (latitude  BETWEEN -90  AND 90),
  longitude        numeric(9,6) NOT NULL CHECK (longitude BETWEEN -180 AND 180),
  google_place_id  text,
  address_ar       text,
  address_en       text,
  dock_info        jsonb NOT NULL DEFAULT '{}'::jsonb, -- gates, parking, berth map
  emergency_phone  text,
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX marinas_city_idx ON marinas (city_id) WHERE is_active;
CREATE TRIGGER marinas_touch BEFORE UPDATE ON marinas FOR EACH ROW EXECUTE FUNCTION trg_touch_updated_at();

-- ───────────────────────────── Supply ─────────────────────────────
CREATE TABLE owners (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                 uuid NOT NULL UNIQUE REFERENCES users(id),
  legal_name              text NOT NULL,
  commercial_reg_no       text UNIQUE,               -- CR / Freelance doc
  vat_number              text,
  default_commission_bps  integer NOT NULL CHECK (default_commission_bps BETWEEN 0 AND 10000),
  iban_ciphertext         bytea,                     -- for owner-fulfilled online add-on settlement
  whatsapp_e164           text NOT NULL CHECK (whatsapp_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  is_approved             boolean NOT NULL DEFAULT false,
  approved_at             timestamptz,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER owners_touch BEFORE UPDATE ON owners FOR EACH ROW EXECUTE FUNCTION trg_touch_updated_at();

CREATE TABLE captains (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id         uuid NOT NULL REFERENCES owners(id),
  user_id          uuid REFERENCES users(id),
  full_name        text NOT NULL,
  whatsapp_e164    text NOT NULL,
  license_number   text,
  license_expiry   date,
  is_active        boolean NOT NULL DEFAULT true
);
CREATE INDEX captains_owner_idx ON captains (owner_id);

CREATE TABLE boats (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id                 uuid NOT NULL REFERENCES owners(id),
  home_marina_id           uuid NOT NULL REFERENCES marinas(id),
  default_captain_id       uuid REFERENCES captains(id),
  slug                     text NOT NULL UNIQUE,
  name_ar                  text NOT NULL,
  name_en                  text NOT NULL,
  boat_type                text NOT NULL,          -- YACHT, SPEEDBOAT, CATAMARAN, FISHING
  length_m                 numeric(5,2) CHECK (length_m > 0),
  year_built               smallint CHECK (year_built BETWEEN 1950 AND 2100),
  registration_number      text NOT NULL UNIQUE,
  registration_expiry      date NOT NULL,
  insurance_expiry         date,
  dock_label               text,                   -- berth / pier number
  base_capacity            smallint NOT NULL CHECK (base_capacity >= 1),
  max_capacity             smallint NOT NULL CHECK (max_capacity >= 1),
  commission_bps_override  integer CHECK (commission_bps_override BETWEEN 0 AND 10000),
  slot_mode                slot_mode NOT NULL DEFAULT 'FIXED',
  buffer_minutes           smallint NOT NULL DEFAULT 45 CHECK (buffer_minutes BETWEEN 0 AND 240),
  min_booking_minutes      smallint NOT NULL DEFAULT 120 CHECK (min_booking_minutes > 0),
  max_booking_minutes      smallint NOT NULL DEFAULT 720,
  booking_lead_minutes     smallint NOT NULL DEFAULT 120,  -- earliest start from now
  amenities                jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_active                boolean NOT NULL DEFAULT true,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT boats_capacity_ck CHECK (base_capacity <= max_capacity),
  CONSTRAINT boats_duration_ck CHECK (min_booking_minutes <= max_booking_minutes)
);
CREATE INDEX boats_marina_idx ON boats (home_marina_id) WHERE is_active;
CREATE INDEX boats_owner_idx  ON boats (owner_id);
CREATE TRIGGER boats_touch BEFORE UPDATE ON boats FOR EACH ROW EXECUTE FUNCTION trg_touch_updated_at();

CREATE TABLE boat_media (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  boat_id    uuid NOT NULL REFERENCES boats(id) ON DELETE CASCADE,
  url        text NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0,
  alt_ar     text,
  alt_en     text
);
CREATE INDEX boat_media_boat_idx ON boat_media (boat_id, sort_order);

-- Effective commission: boat override → owner default
CREATE VIEW boat_effective_commission AS
SELECT b.id AS boat_id, COALESCE(b.commission_bps_override, o.default_commission_bps) AS commission_bps
FROM boats b JOIN owners o ON o.id = b.owner_id;

-- ───────────────────────────── Pricing ─────────────────────────────
CREATE TABLE destinations_pricing (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  boat_id                  uuid NOT NULL REFERENCES boats(id) ON DELETE CASCADE,
  route_name_ar            text NOT NULL,
  route_name_en            text NOT NULL,
  description_ar           text,
  description_en           text,
  duration_minutes         smallint NOT NULL CHECK (duration_minutes > 0), -- default for OPEN mode
  weekday_price_halalas    bigint NOT NULL CHECK (weekday_price_halalas >= 0),
  weekend_price_halalas    bigint NOT NULL CHECK (weekend_price_halalas >= 0),
  holiday_price_halalas    bigint NOT NULL CHECK (holiday_price_halalas >= 0),
  base_capacity            smallint NOT NULL CHECK (base_capacity >= 1),
  extra_person_fee_halalas bigint NOT NULL DEFAULT 0 CHECK (extra_person_fee_halalas >= 0),
  is_active                boolean NOT NULL DEFAULT true,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX destinations_boat_idx ON destinations_pricing (boat_id) WHERE is_active;
CREATE TRIGGER destinations_touch BEFORE UPDATE ON destinations_pricing FOR EACH ROW EXECUTE FUNCTION trg_touch_updated_at();

-- A destination's base capacity can never exceed the boat's certified maximum
CREATE OR REPLACE FUNCTION trg_destination_capacity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_max smallint;
BEGIN
  SELECT max_capacity INTO v_max FROM boats WHERE id = NEW.boat_id;
  IF NEW.base_capacity > v_max THEN
    RAISE EXCEPTION 'destination base_capacity % exceeds boat max_capacity %', NEW.base_capacity, v_max
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER destinations_capacity BEFORE INSERT OR UPDATE ON destinations_pricing
  FOR EACH ROW EXECUTE FUNCTION trg_destination_capacity();

CREATE TABLE boat_addons (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  boat_id                  uuid NOT NULL REFERENCES boats(id) ON DELETE CASCADE,
  item_name_ar             text NOT NULL,
  item_name_en             text NOT NULL,
  price_halalas            bigint NOT NULL CHECK (price_halalas >= 0),
  payment_collection_type  addon_collection NOT NULL,
  fulfilled_by             addon_fulfiller NOT NULL DEFAULT 'OWNER',
  max_quantity             smallint NOT NULL DEFAULT 1 CHECK (max_quantity >= 1),
  is_active                boolean NOT NULL DEFAULT true,
  created_at               timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX boat_addons_boat_idx ON boat_addons (boat_id) WHERE is_active;

-- Holiday / event overrides. city_id NULL = nationwide (Eids, National Day, Founding Day).
CREATE TABLE seasonal_calendars (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  calendar_date  date NOT NULL,
  city_id        uuid REFERENCES cities(id),
  day_type       day_type NOT NULL,
  label_ar       text NOT NULL,
  label_en       text NOT NULL,
  created_by     uuid REFERENCES users(id),
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX seasonal_calendars_uq ON seasonal_calendars (calendar_date, city_id) NULLS NOT DISTINCT;

-- ─────────────────────── Schedules & availability ───────────────────────
-- FIXED mode: recurring shifts. weekday_mask bit 0 = Sunday … bit 6 = Saturday.
CREATE TABLE boat_schedules (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  boat_id          uuid NOT NULL REFERENCES boats(id) ON DELETE CASCADE,
  slot_mode        slot_mode NOT NULL,
  name_ar          text NOT NULL,                 -- 'الفترة الصباحية'
  name_en          text NOT NULL,                 -- 'Morning shift'
  weekday_mask     smallint NOT NULL DEFAULT 127 CHECK (weekday_mask BETWEEN 1 AND 127),
  start_time       time NOT NULL,                 -- FIXED: shift start; OPEN: opening time
  end_time         time NOT NULL,                 -- may be < start_time for overnight
  destination_id   uuid REFERENCES destinations_pricing(id), -- optional shift-specific route
  slot_step_minutes smallint NOT NULL DEFAULT 30 CHECK (slot_step_minutes IN (15,30,60)), -- OPEN only
  valid_from       date NOT NULL DEFAULT current_date,
  valid_to         date,
  is_active        boolean NOT NULL DEFAULT true,
  CONSTRAINT boat_schedules_valid_ck CHECK (valid_to IS NULL OR valid_to >= valid_from),
  CONSTRAINT boat_schedules_len_ck CHECK (start_time <> end_time)
);
CREATE INDEX boat_schedules_boat_idx ON boat_schedules (boat_id) WHERE is_active;

-- THE source of truth for occupancy: bookings, holds, maintenance, owner blocks.
-- blocked_range = trip_range extended by the turnaround buffer.
CREATE TABLE boat_reservations (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  boat_id          uuid NOT NULL REFERENCES boats(id),
  kind             reservation_kind NOT NULL,
  status           reservation_status NOT NULL,
  trip_range       tstzrange NOT NULL,
  blocked_range    tstzrange NOT NULL,
  buffer_minutes   smallint NOT NULL DEFAULT 0,
  hold_token       uuid,                          -- matches the Redis lock value
  hold_expires_at  timestamptz,
  is_maintenance   boolean GENERATED ALWAYS AS (kind = 'MAINTENANCE') STORED,
  note             text,
  created_by       uuid REFERENCES users(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  released_at      timestamptz,
  CONSTRAINT res_range_ck CHECK (NOT isempty(trip_range) AND lower_inc(trip_range) AND NOT upper_inc(trip_range)),
  CONSTRAINT res_blocked_ck CHECK (lower(blocked_range) = lower(trip_range) AND upper(blocked_range) >= upper(trip_range)),
  CONSTRAINT res_hold_ck CHECK (status <> 'HOLD' OR (hold_expires_at IS NOT NULL AND hold_token IS NOT NULL)),
  CONSTRAINT res_release_ck CHECK ((status = 'RELEASED') = (released_at IS NOT NULL)),
  -- No two active reservations of the same boat may overlap, buffer included.
  CONSTRAINT res_no_overlap EXCLUDE USING gist (boat_id WITH =, blocked_range WITH &&)
    WHERE (status IN ('HOLD','BOOKED'))
);
CREATE INDEX res_boat_active_idx ON boat_reservations USING gist (boat_id, blocked_range) WHERE status IN ('HOLD','BOOKED');
CREATE INDEX res_expired_holds_idx ON boat_reservations (hold_expires_at) WHERE status = 'HOLD';

-- Legacy-name view requested in the brief
CREATE VIEW blocked_slots AS
SELECT id, boat_id, kind, lower(trip_range) AS start_time, upper(trip_range) AS end_time,
       buffer_minutes, is_maintenance, note
FROM boat_reservations
WHERE status = 'BOOKED' AND kind IN ('MAINTENANCE','OWNER_BLOCK');

-- Atomic hold: frees overlapping expired holds, then inserts. Raises 23P01
-- (exclusion_violation) when the slot is taken.
CREATE OR REPLACE FUNCTION fn_hold_slot(
  p_boat_id uuid, p_start timestamptz, p_end timestamptz,
  p_hold_token uuid, p_hold_seconds integer, p_user uuid
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_buffer smallint;
  v_blocked tstzrange;
  v_id uuid;
BEGIN
  SELECT buffer_minutes INTO v_buffer FROM boats WHERE id = p_boat_id AND is_active FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'boat % not bookable', p_boat_id USING ERRCODE = 'no_data_found'; END IF;

  v_blocked := tstzrange(p_start, p_end + make_interval(mins => v_buffer), '[)');

  UPDATE boat_reservations
     SET status = 'RELEASED', released_at = now()
   WHERE boat_id = p_boat_id AND status = 'HOLD'
     AND hold_expires_at < now() AND blocked_range && v_blocked;

  INSERT INTO boat_reservations (boat_id, kind, status, trip_range, blocked_range, buffer_minutes,
                                 hold_token, hold_expires_at, created_by)
  VALUES (p_boat_id, 'BOOKING', 'HOLD', tstzrange(p_start, p_end, '[)'), v_blocked, v_buffer,
          p_hold_token, now() + make_interval(secs => p_hold_seconds), p_user)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ───────────────────────────── Affiliates ─────────────────────────────
CREATE TABLE affiliates (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                   uuid NOT NULL UNIQUE REFERENCES users(id),
  partner_type              partner_type NOT NULL,
  display_name              text NOT NULL,
  referral_code             citext NOT NULL UNIQUE CHECK (referral_code ~ '^[A-Za-z0-9_-]{3,32}$'),
  client_discount_pct_bps   integer NOT NULL DEFAULT 0 CHECK (client_discount_pct_bps BETWEEN 0 AND 10000),
  affiliate_commission_pct_bps integer NOT NULL DEFAULT 0 CHECK (affiliate_commission_pct_bps BETWEEN 0 AND 10000),
  attribution_days          smallint NOT NULL DEFAULT 30 CHECK (attribution_days BETWEEN 1 AND 365),
  status                    partner_status NOT NULL DEFAULT 'PENDING',
  approved_by               uuid REFERENCES users(id),
  approved_at               timestamptz,
  iban_ciphertext           bytea,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER affiliates_touch BEFORE UPDATE ON affiliates FOR EACH ROW EXECUTE FUNCTION trg_touch_updated_at();

CREATE TABLE affiliate_clicks (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  affiliate_id  uuid NOT NULL REFERENCES affiliates(id),
  visitor_id    uuid NOT NULL,           -- first-party cookie / device id
  landing_path  text,
  utm           jsonb,
  ip_hash       bytea,                   -- HMAC, never raw IP
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX affiliate_clicks_aff_time_idx ON affiliate_clicks (affiliate_id, created_at DESC);
CREATE INDEX affiliate_clicks_visitor_idx ON affiliate_clicks (visitor_id, created_at DESC);

-- ───────────────────────── Suspensions & passes ─────────────────────────
CREATE TABLE sailing_suspensions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  city_id              uuid REFERENCES cities(id),
  marina_id            uuid REFERENCES marinas(id),
  reason               suspension_reason NOT NULL,
  suspension_window    tstzrange NOT NULL,
  authority_reference  text,                    -- circular / notice number
  evidence_url         text,
  declared_by          uuid NOT NULL REFERENCES users(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT suspension_scope_ck CHECK (city_id IS NOT NULL OR marina_id IS NOT NULL)
);
CREATE INDEX sailing_suspensions_window_idx ON sailing_suspensions USING gist (suspension_window);

-- ───────────────────────────── Bookings ─────────────────────────────
CREATE TABLE bookings (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_number              text NOT NULL UNIQUE,               -- e.g. JED-261016-7K3Q
  client_id                   uuid NOT NULL REFERENCES users(id),
  boat_id                     uuid NOT NULL REFERENCES boats(id),
  owner_id                    uuid NOT NULL REFERENCES owners(id), -- denormalised for RLS / reporting
  marina_id                   uuid NOT NULL REFERENCES marinas(id),
  destination_id              uuid NOT NULL REFERENCES destinations_pricing(id),
  reservation_id              uuid NOT NULL UNIQUE REFERENCES boat_reservations(id),
  trip_start                  timestamptz NOT NULL,
  trip_end                    timestamptz NOT NULL,
  guests                      smallint NOT NULL CHECK (guests >= 1),

  -- Pricing snapshot (immutable once PAID)
  day_type                    day_type NOT NULL,
  day_rate_halalas            bigint NOT NULL CHECK (day_rate_halalas >= 0),
  extra_guests                smallint NOT NULL CHECK (extra_guests >= 0),
  extra_guest_fee_halalas     bigint NOT NULL CHECK (extra_guest_fee_halalas >= 0),
  trip_subtotal_halalas       bigint NOT NULL CHECK (trip_subtotal_halalas >= 0),
  online_addons_halalas       bigint NOT NULL DEFAULT 0 CHECK (online_addons_halalas >= 0),
  dock_addons_halalas         bigint NOT NULL DEFAULT 0 CHECK (dock_addons_halalas >= 0),
  total_amount                bigint NOT NULL CHECK (total_amount >= 0),   -- list price
  commission_bps              integer NOT NULL CHECK (commission_bps BETWEEN 0 AND 10000),
  gross_commission_halalas    bigint NOT NULL CHECK (gross_commission_halalas >= 0),
  client_discount_halalas     bigint NOT NULL DEFAULT 0 CHECK (client_discount_halalas >= 0),
  partner_earning_halalas     bigint NOT NULL DEFAULT 0 CHECK (partner_earning_halalas >= 0),
  platform_net_halalas        bigint NOT NULL CHECK (platform_net_halalas >= 0),
  affiliate_clamped           boolean NOT NULL DEFAULT false,
  deposit_amount              bigint NOT NULL CHECK (deposit_amount >= 0),
  reschedule_credit_halalas   bigint NOT NULL DEFAULT 0 CHECK (reschedule_credit_halalas >= 0),
  amount_due_online_halalas   bigint NOT NULL CHECK (amount_due_online_halalas >= 0),
  balance_due_to_captain      bigint NOT NULL CHECK (balance_due_to_captain >= 0),
  client_total_halalas        bigint NOT NULL CHECK (client_total_halalas >= 0),
  currency                    char(3) NOT NULL DEFAULT 'SAR',
  pricing_snapshot            jsonb NOT NULL,          -- full engine output + inputs, for audit

  affiliate_id                uuid REFERENCES affiliates(id),
  booking_status              booking_status NOT NULL DEFAULT 'PENDING_PAYMENT',
  payment_status              payment_status NOT NULL DEFAULT 'INITIATED',
  idempotency_key             text NOT NULL UNIQUE,
  rescheduled_from_id         uuid REFERENCES bookings(id),
  manifest_submitted_at       timestamptz,
  voucher_issued_at           timestamptz,
  balance_collected_at        timestamptz,             -- captain confirms cash/transfer received
  cancelled_at                timestamptz,
  cancel_reason               text,
  completed_at                timestamptz,
  version                     integer NOT NULL DEFAULT 1,  -- optimistic locking
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT bookings_time_ck     CHECK (trip_end > trip_start),
  CONSTRAINT bookings_total_ck    CHECK (total_amount = trip_subtotal_halalas + online_addons_halalas + dock_addons_halalas),
  CONSTRAINT bookings_client_ck   CHECK (client_total_halalas = total_amount - client_discount_halalas),
  CONSTRAINT bookings_split_ck    CHECK (deposit_amount + balance_due_to_captain = client_total_halalas),
  CONSTRAINT bookings_captain_ck  CHECK (balance_due_to_captain = trip_subtotal_halalas - gross_commission_halalas + dock_addons_halalas),
  CONSTRAINT bookings_alloc_ck    CHECK (platform_net_halalas + partner_earning_halalas + client_discount_halalas = gross_commission_halalas),
  CONSTRAINT bookings_online_ck   CHECK (amount_due_online_halalas = deposit_amount - reschedule_credit_halalas),
  CONSTRAINT bookings_voucher_ck  CHECK (voucher_issued_at IS NULL OR manifest_submitted_at IS NOT NULL),
  CONSTRAINT bookings_confirm_ck  CHECK (booking_status NOT IN ('CONFIRMED','COMPLETED') OR voucher_issued_at IS NOT NULL),
  CONSTRAINT bookings_aff_ck      CHECK (affiliate_id IS NOT NULL OR (client_discount_halalas = 0 AND partner_earning_halalas = 0))
);
CREATE INDEX bookings_client_idx  ON bookings (client_id, trip_start DESC);
CREATE INDEX bookings_owner_idx   ON bookings (owner_id, trip_start DESC);
CREATE INDEX bookings_boat_idx    ON bookings (boat_id, trip_start);
CREATE INDEX bookings_status_idx  ON bookings (booking_status, trip_start);
CREATE INDEX bookings_aff_idx     ON bookings (affiliate_id, created_at DESC) WHERE affiliate_id IS NOT NULL;
CREATE TRIGGER bookings_touch BEFORE UPDATE ON bookings FOR EACH ROW EXECUTE FUNCTION trg_touch_updated_at();

-- Pricing is frozen once money has moved
CREATE OR REPLACE FUNCTION trg_bookings_freeze_pricing() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.payment_status IN ('PAID','NOT_REQUIRED','REFUNDED','PARTIALLY_REFUNDED')
     AND (NEW.deposit_amount, NEW.balance_due_to_captain, NEW.commission_bps, NEW.total_amount)
         IS DISTINCT FROM (OLD.deposit_amount, OLD.balance_due_to_captain, OLD.commission_bps, OLD.total_amount) THEN
    RAISE EXCEPTION 'pricing of booking % is frozen after payment', OLD.booking_number USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER bookings_freeze BEFORE UPDATE ON bookings FOR EACH ROW EXECUTE FUNCTION trg_bookings_freeze_pricing();

CREATE TABLE booking_addons (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id         uuid NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  addon_id           uuid NOT NULL REFERENCES boat_addons(id),
  name_snapshot      text NOT NULL,
  unit_price_halalas bigint NOT NULL CHECK (unit_price_halalas >= 0),
  quantity           smallint NOT NULL CHECK (quantity >= 1),
  collection         addon_collection NOT NULL,
  fulfilled_by       addon_fulfiller NOT NULL,
  UNIQUE (booking_id, addon_id)
);

CREATE TABLE booking_passengers (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id            uuid NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  seq                   smallint NOT NULL CHECK (seq >= 1),
  full_name             text NOT NULL CHECK (length(btrim(full_name)) >= 3),
  id_type               id_type NOT NULL,
  id_number_ciphertext  bytea NOT NULL,          -- AES-256-GCM(iv || tag || ct), app-side
  id_number_hmac        bytea NOT NULL,          -- HMAC-SHA256 blind index for de-dupe/search
  id_number_last4       char(4) NOT NULL,
  nationality_iso2      char(2),
  phone_e164            text,
  is_lead_passenger     boolean NOT NULL DEFAULT false,
  created_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (booking_id, seq),
  UNIQUE (booking_id, id_number_hmac)
);
CREATE UNIQUE INDEX booking_passengers_one_lead ON booking_passengers (booking_id) WHERE is_lead_passenger;

-- Manifest cannot exceed the booked guest count
CREATE OR REPLACE FUNCTION trg_manifest_capacity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_guests smallint; v_count integer;
BEGIN
  SELECT guests INTO v_guests FROM bookings WHERE id = NEW.booking_id FOR UPDATE;
  SELECT count(*) INTO v_count FROM booking_passengers WHERE booking_id = NEW.booking_id;
  IF v_count + 1 > v_guests THEN
    RAISE EXCEPTION 'manifest exceeds booked guests (%)', v_guests USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER booking_passengers_capacity BEFORE INSERT ON booking_passengers
  FOR EACH ROW EXECUTE FUNCTION trg_manifest_capacity();

CREATE TABLE reschedule_passes (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code                 text NOT NULL UNIQUE,                 -- shown to client, e.g. RSP-7K3Q-92XD
  original_booking_id  uuid NOT NULL UNIQUE REFERENCES bookings(id),
  client_id            uuid NOT NULL REFERENCES users(id),
  reason               pass_reason NOT NULL,
  suspension_id        uuid REFERENCES sailing_suspensions(id),
  credit_amount        bigint NOT NULL CHECK (credit_amount > 0),
  restricted_boat_id   uuid REFERENCES boats(id),             -- NULL = any boat
  issued_at            timestamptz NOT NULL DEFAULT now(),
  expiry_date          timestamptz NOT NULL,
  status               pass_status NOT NULL DEFAULT 'ACTIVE',
  is_redeemed          boolean GENERATED ALWAYS AS (status = 'REDEEMED') STORED,
  redeemed_booking_id  uuid UNIQUE REFERENCES bookings(id),
  redeemed_at          timestamptz,
  CONSTRAINT pass_expiry_ck CHECK (expiry_date > issued_at AND expiry_date <= issued_at + interval '366 days'),
  CONSTRAINT pass_redeem_ck CHECK ((status = 'REDEEMED') = (redeemed_booking_id IS NOT NULL AND redeemed_at IS NOT NULL)),
  CONSTRAINT pass_suspension_ck CHECK (reason <> 'SUSPENSION' OR suspension_id IS NOT NULL)
);
CREATE INDEX reschedule_passes_client_idx ON reschedule_passes (client_id) WHERE status = 'ACTIVE';
CREATE INDEX reschedule_passes_expiry_idx ON reschedule_passes (expiry_date) WHERE status = 'ACTIVE';

-- ───────────────────────────── Payments ─────────────────────────────
CREATE TABLE payments (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id            uuid NOT NULL REFERENCES bookings(id),
  provider              text NOT NULL DEFAULT 'MOYASAR',
  provider_payment_id   text UNIQUE,              -- Moyasar payment id
  amount_halalas        bigint NOT NULL CHECK (amount_halalas > 0),
  currency              char(3) NOT NULL DEFAULT 'SAR',
  status                payment_status NOT NULL DEFAULT 'INITIATED',
  method                text,                     -- mada / visa / mastercard / applepay
  card_last4            char(4),
  failure_reason        text,
  raw_response          jsonb,
  created_at            timestamptz NOT NULL DEFAULT now(),
  paid_at               timestamptz,
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX payments_booking_idx ON payments (booking_id);
CREATE UNIQUE INDEX payments_one_paid_per_booking ON payments (booking_id) WHERE status = 'PAID';
CREATE TRIGGER payments_touch BEFORE UPDATE ON payments FOR EACH ROW EXECUTE FUNCTION trg_touch_updated_at();

CREATE TABLE refunds (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id           uuid NOT NULL REFERENCES payments(id),
  amount_halalas       bigint NOT NULL CHECK (amount_halalas > 0),
  reason               text NOT NULL,         -- OWNER_CANCELLATION, LATE_PAYMENT_SLOT_TAKEN, ADMIN
  provider_refund_ref  text,
  status               text NOT NULL DEFAULT 'REQUESTED' CHECK (status IN ('REQUESTED','SUCCEEDED','FAILED')),
  requested_by         uuid REFERENCES users(id),
  created_at           timestamptz NOT NULL DEFAULT now()
);

-- Idempotent inbound webhooks (Moyasar, WhatsApp delivery receipts)
CREATE TABLE webhook_events (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  provider      text NOT NULL,
  event_id      text NOT NULL,
  event_type    text NOT NULL,
  payload       jsonb NOT NULL,
  received_at   timestamptz NOT NULL DEFAULT now(),
  processed_at  timestamptz,
  error         text,
  UNIQUE (provider, event_id)
);

-- ─────────────────────── Affiliate ledger & payouts ───────────────────────
CREATE TABLE affiliate_payouts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  affiliate_id    uuid NOT NULL REFERENCES affiliates(id),
  amount_halalas  bigint NOT NULL CHECK (amount_halalas > 0),
  bank_reference  text,
  status          text NOT NULL DEFAULT 'REQUESTED' CHECK (status IN ('REQUESTED','APPROVED','PAID','REJECTED')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  paid_at         timestamptz
);

-- Append-only ledger. Signed amounts: EARNING > 0, REVERSAL/PAYOUT < 0.
CREATE TABLE affiliate_transactions (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  affiliate_id    uuid NOT NULL REFERENCES affiliates(id),
  booking_id      uuid REFERENCES bookings(id),
  payout_id       uuid REFERENCES affiliate_payouts(id),
  txn_type        affiliate_txn_type NOT NULL,
  status          affiliate_txn_status NOT NULL,
  amount_halalas  bigint NOT NULL CHECK (amount_halalas <> 0),
  available_at    timestamptz,            -- set when the trip is COMPLETED (+ hold period)
  note            text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT aff_txn_sign_ck CHECK (
    (txn_type = 'EARNING'  AND amount_halalas > 0) OR
    (txn_type IN ('REVERSAL','PAYOUT') AND amount_halalas < 0) OR
    (txn_type = 'ADJUSTMENT')),
  CONSTRAINT aff_txn_ref_ck CHECK (
    (txn_type IN ('EARNING','REVERSAL') AND booking_id IS NOT NULL) OR
    (txn_type = 'PAYOUT' AND payout_id IS NOT NULL) OR txn_type = 'ADJUSTMENT')
);
CREATE UNIQUE INDEX aff_txn_one_earning ON affiliate_transactions (booking_id) WHERE txn_type = 'EARNING';
CREATE UNIQUE INDEX aff_txn_one_reversal ON affiliate_transactions (booking_id) WHERE txn_type = 'REVERSAL';
CREATE INDEX aff_txn_aff_idx ON affiliate_transactions (affiliate_id, created_at DESC);

CREATE OR REPLACE FUNCTION trg_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION '% is append-only', TG_TABLE_NAME; END IF;
  -- Only status / available_at may change (PENDING → AVAILABLE → PAID, or VOID)
  IF (NEW.affiliate_id, NEW.booking_id, NEW.txn_type, NEW.amount_halalas)
     IS DISTINCT FROM (OLD.affiliate_id, OLD.booking_id, OLD.txn_type, OLD.amount_halalas) THEN
    RAISE EXCEPTION '% rows are immutable except status', TG_TABLE_NAME;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER affiliate_transactions_append_only BEFORE UPDATE OR DELETE ON affiliate_transactions
  FOR EACH ROW EXECUTE FUNCTION trg_append_only();

-- Wallet balances are derived from the ledger, never stored
CREATE VIEW affiliate_wallets AS
SELECT a.id AS affiliate_id,
       COALESCE(SUM(t.amount_halalas) FILTER (WHERE t.status = 'PENDING'), 0)                     AS pending_halalas,
       COALESCE(SUM(t.amount_halalas) FILTER (WHERE t.status IN ('AVAILABLE','PAID')), 0)         AS wallet_balance,
       COALESCE(SUM(t.amount_halalas) FILTER (WHERE t.txn_type = 'EARNING' AND t.status <> 'VOID'), 0) AS lifetime_earned_halalas
FROM affiliates a
LEFT JOIN affiliate_transactions t ON t.affiliate_id = a.id
GROUP BY a.id;

-- Owner-fulfilled online add-ons → periodic settlement to owner
CREATE TABLE owner_payables (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  owner_id        uuid NOT NULL REFERENCES owners(id),
  booking_id      uuid NOT NULL UNIQUE REFERENCES bookings(id),
  amount_halalas  bigint NOT NULL CHECK (amount_halalas > 0),
  status          text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','AVAILABLE','PAID','VOID')),
  settled_at      timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- ───────────────────────── Notifications (outbox) ─────────────────────────
CREATE TABLE notification_outbox (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  channel              notify_channel NOT NULL,
  template_key         text NOT NULL,          -- 'captain_new_booking_v1'
  locale               text NOT NULL DEFAULT 'ar',
  recipient            text NOT NULL,          -- E.164 or email
  booking_id           uuid REFERENCES bookings(id),
  variables            jsonb NOT NULL,
  dedupe_key           text NOT NULL UNIQUE,   -- e.g. '<booking_id>:captain_new_booking'
  status               notify_status NOT NULL DEFAULT 'QUEUED',
  attempts             smallint NOT NULL DEFAULT 0,
  next_attempt_at      timestamptz NOT NULL DEFAULT now(),
  provider_message_id  text,
  last_error           text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  sent_at              timestamptz
);
CREATE INDEX notification_outbox_due_idx ON notification_outbox (next_attempt_at) WHERE status = 'QUEUED';

-- ───────────────────────────── Audit ─────────────────────────────
CREATE TABLE audit_log (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_id    uuid REFERENCES users(id),
  action      text NOT NULL,                 -- 'booking.cancel', 'manifest.view', 'commission.update'
  entity      text NOT NULL,
  entity_id   text NOT NULL,
  before      jsonb,
  after       jsonb,
  ip_hash     bytea,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_log_entity_idx ON audit_log (entity, entity_id, created_at DESC);

-- ───────────────────────── Row-level security (owner portal) ─────────────────────────
-- The API sets these per request:  SET LOCAL app.user_id = '<uuid>'; SET LOCAL app.owner_id = '<uuid>';
-- The admin / service role connects with BYPASSRLS.
ALTER TABLE bookings           ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_passengers ENABLE ROW LEVEL SECURITY;
ALTER TABLE boat_reservations  ENABLE ROW LEVEL SECURITY;

CREATE POLICY bookings_owner_read ON bookings FOR SELECT
  USING (owner_id = NULLIF(current_setting('app.owner_id', true), '')::uuid
         OR client_id = NULLIF(current_setting('app.user_id', true), '')::uuid);

CREATE POLICY passengers_owner_read ON booking_passengers FOR SELECT
  USING (EXISTS (SELECT 1 FROM bookings b WHERE b.id = booking_id
                 AND (b.owner_id = NULLIF(current_setting('app.owner_id', true), '')::uuid
                      OR b.client_id = NULLIF(current_setting('app.user_id', true), '')::uuid)));

CREATE POLICY reservations_owner_rw ON boat_reservations FOR ALL
  USING (EXISTS (SELECT 1 FROM boats bt WHERE bt.id = boat_id
                 AND bt.owner_id = NULLIF(current_setting('app.owner_id', true), '')::uuid));

COMMIT;

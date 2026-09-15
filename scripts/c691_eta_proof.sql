-- CHANGE #691 — the QA journey for register rows 122 and 126, as SQL.
--
-- Row 122's claim was "deliveries.eta_min is written once by
-- delivery_apply_google and never rebased (delivery_recompute_eta has zero
-- callers)". This script runs a three-stop delivery and proves the opposite:
-- the run starting stamps an eta_at on every open stop, and EACH stop closing
-- moves the remaining stops earlier — the thing the old code could not do,
-- because it read its own output as its own input.
--
-- Row 126's claim was that completion stores proof and shows it to nobody.
-- The last stop is delivered with a photo and a receiver, and the block is then
-- read back through every surface that renders it.
--
-- SAFE TO RUN ON PRODUCTION: everything happens inside one transaction that
-- ROLLS BACK. Nothing survives it. `now()` is frozen for the whole transaction,
-- which is exactly what makes the assertions below exact — every eta_at is a
-- fixed offset from one anchor, so a rebase that did not happen is visible.
--
--   psql "$(cat ~/.medibo/dburl)" -v ON_ERROR_STOP=1 -f scripts/c691_eta_proof.sql

\set ON_ERROR_STOP on
begin;

do $proof$
declare
  v_partner uuid;
  v_run uuid := gen_random_uuid();
  v_o uuid[]; v_d uuid[] := '{}'; v_one uuid;
  v_anchor timestamptz := now();
  v_dwell numeric;
  i int;
  d3a timestamptz; d3b timestamptz; d3c timestamptz;
  v_eta jsonb; v_proof jsonb; v_res jsonb; v_tl jsonb; v_card jsonb; v_invoice jsonb;
  v_leg int[] := array[10, 15, 12];
begin
  -- ── fixtures ──────────────────────────────────────────────────────────────
  -- A REAL rider on REAL orders: z_synthetic_rider_guard refuses to put a
  -- synthetic delivery on a real rider (and vice versa), and there are no
  -- synthetic orders to pair with the test rider. The rollback at the end is
  -- what keeps this safe, not a flag.
  select id into v_partner from delivery_partner_registrations
   where coalesce(is_deleted,false) = false and coalesce(is_synthetic,false) = false
   order by created_at limit 1;
  if v_partner is null then raise exception 'c691: no delivery partner to run with'; end if;

  select array_agg(id) into v_o from (
    select id from orders order by created_at desc limit 3) t;
  if coalesce(array_length(v_o,1),0) < 3 then
    raise exception 'c691: need 3 orders, found %', coalesce(array_length(v_o,1),0);
  end if;

  -- The rider has no live position in this fixture, so leg 1 is the OPTIMISER's
  -- leg_min rather than a straight line from a moving van. That keeps every
  -- number below deterministic; the GPS path is asserted separately at the end.
  delete from delivery_partner_locations where partner_id = v_partner;

  v_dwell := coalesce((select (value #>> '{}')::numeric from app_settings
                        where key='delivery_dwell_minutes'), 4);

  insert into delivery_runs(id, partner_id, run_date, status, total_stops)
  values (v_run, v_partner, (v_anchor at time zone 'Asia/Kolkata')::date, 'planned', 3);

  for i in 1..3 loop
    v_one := gen_random_uuid();
    insert into deliveries(id, order_id, run_id, partner_id, status, accept_status,
                           seq, lat, lng, leg_km, leg_min, qr_token)
    values (v_one, v_o[i], v_run, v_partner, 'assigned', 'accepted',
            i, 21.24 + i*0.01, 81.63 + i*0.01, 3.0, v_leg[i],
            'c691tok' || i::text);
    v_d := v_d || v_one;
  end loop;

  -- Nothing has rebased yet: an inserted stop carries no eta_at.
  if exists (select 1 from deliveries where run_id = v_run and eta_at is not null) then
    raise exception 'c691: eta_at set before the run started';
  end if;
  raise notice 'c691 step 0  — 3 stops staged, no eta_at yet  OK';

  -- ── 1. RUN START rebases (trg_delivery_run_rebase_eta) ───────────────────
  update delivery_runs set status = 'started', started_at = v_anchor where id = v_run;
  update deliveries set status = 'out_for_delivery' where run_id = v_run;

  for i in 1..3 loop
    if (select eta_at from deliveries where id = v_d[i]) is null then
      raise exception 'c691: stop % has no eta_at after the run started', i;
    end if;
  end loop;

  -- stop1 = 10 ; stop2 = 10 + dwell + 15 ; stop3 = 10 + dwell + 15 + dwell + 12
  if (select eta_at from deliveries where id = v_d[1])
       <> v_anchor + make_interval(mins => 10) then
    raise exception 'c691: stop 1 eta is % , expected anchor+10',
      (select eta_at from deliveries where id = v_d[1]);
  end if;
  if (select eta_at from deliveries where id = v_d[3])
       <> v_anchor + make_interval(mins => (10 + v_dwell + 15 + v_dwell + 12)::int) then
    raise exception 'c691: stop 3 eta is %, expected anchor+%',
      (select eta_at from deliveries where id = v_d[3]),
      (10 + v_dwell + 15 + v_dwell + 12);
  end if;
  select eta_at into d3a from deliveries where id = v_d[3];
  raise notice 'c691 step 1  — run start rebased all 3 stops; stop3 eta %  OK', d3a;

  -- ── 2. STOP 1 CLOSES → trg_delivery_rebase_eta moves the rest earlier ────
  update deliveries set status = 'delivered', delivered_at = v_anchor where id = v_d[1];
  select eta_at into d3b from deliveries where id = v_d[3];
  if d3b is null or d3b >= d3a then
    raise exception 'c691: stop 3 did not rebase after stop 1 closed (% -> %)', d3a, d3b;
  end if;
  if d3b <> v_anchor + make_interval(mins => (15 + v_dwell + 12)::int) then
    raise exception 'c691: stop 3 eta after one delivery is %, expected anchor+%',
      d3b, (15 + v_dwell + 12);
  end if;
  raise notice 'c691 step 2  — stop 1 delivered; stop3 eta % -> %  OK', d3a, d3b;

  -- ── 3. STOP 2 CLOSES → it moves again ────────────────────────────────────
  update deliveries set status = 'delivered', delivered_at = v_anchor where id = v_d[2];
  select eta_at into d3c from deliveries where id = v_d[3];
  if d3c is null or d3c >= d3b then
    raise exception 'c691: stop 3 did not rebase after stop 2 closed (% -> %)', d3b, d3c;
  end if;
  if d3c <> v_anchor + make_interval(mins => 12) then
    raise exception 'c691: stop 3 eta after two deliveries is %, expected anchor+12', d3c;
  end if;
  raise notice 'c691 step 3  — stop 2 delivered; stop3 eta % -> %  OK', d3b, d3c;

  -- ── 4. THE WINDOW THE CUSTOMER READS ─────────────────────────────────────
  v_eta := public._delivery_eta_block(v_d[3]);
  if coalesce((v_eta->>'has')::boolean,false) is not true then
    raise exception 'c691: eta block has:false while the stop is live — %', v_eta;
  end if;
  if coalesce(v_eta->>'window_label','') = '' or coalesce(v_eta->>'label','') = '' then
    raise exception 'c691: eta block carries no window sentence — %', v_eta;
  end if;
  if (v_eta->>'stops_ahead')::int <> 0 then
    raise exception 'c691: last open stop should have 0 ahead, got %', v_eta->>'stops_ahead';
  end if;
  raise notice 'c691 step 4  — customer window: "%"  (%)  OK',
    v_eta->>'label', v_eta->>'countdown_label';

  -- ── 5. THE THROTTLE, so a moving rider cannot rewrite the run every second ─
  v_res := public.delivery_recompute_eta(v_run, false);
  if coalesce((v_res->>'throttled')::boolean,false) is not true then
    raise exception 'c691: an unforced rebase inside the window was not throttled — %', v_res;
  end if;
  if not exists (select 1 from pg_trigger
                  where tgname = 'trg_delivery_loc_rebase_eta'
                    and tgrelid = 'public.delivery_partner_locations'::regclass) then
    raise exception 'c691: the rider-location rebase trigger is missing';
  end if;
  raise notice 'c691 step 5  — unforced rebase throttled, location trigger installed  OK';

  -- ── 6. DELIVER THE LAST STOP WITH PROOF (register row 126) ───────────────
  update deliveries
     set status = 'delivered', delivered_at = v_anchor, handover_at = v_anchor,
         proof_method = 'otp', proof_photo_path = 'c691/proof.jpg',
         receiver_name = 'Sunita Verma',
         delivered_lat = 21.2514, delivered_lng = 81.6296
   where id = v_d[3];

  v_proof := public._delivery_proof_block(v_o[3]);
  if coalesce((v_proof->>'has')::boolean,false) is not true then
    raise exception 'c691: proof block still has:false after a delivery — %', v_proof;
  end if;
  if coalesce(v_proof->>'receiver_name','') <> 'Sunita Verma' then
    raise exception 'c691: receiver not carried — %', v_proof->>'receiver_name';
  end if;
  if coalesce(v_proof->>'time_label','') = '' then
    raise exception 'c691: handover time not carried';
  end if;
  if coalesce(v_proof->'photo'->>'has','false') <> 'true'
     or coalesce(v_proof->'photo'->>'bucket','') <> 'delivery-proofs' then
    raise exception 'c691: photo not carried — %', v_proof->'photo';
  end if;
  if coalesce(v_proof->'map'->>'has','false') <> 'true'
     or coalesce(v_proof->'map'->>'url','') = '' then
    raise exception 'c691: map pin not carried — %', v_proof->'map';
  end if;
  -- the METHOD LABEL is copy, never the key title-cased
  if coalesce(v_proof->>'method_label','') = ''
     or v_proof->>'method_label' = 'Otp' then
    raise exception 'c691: method label is not backend copy — %', v_proof->>'method_label';
  end if;
  raise notice 'c691 step 6  — proof: % / % / % / photo=% / pin=%  OK',
    v_proof->>'receiver_name', v_proof->>'time_label', v_proof->>'method_label',
    v_proof->'photo'->>'has', v_proof->'map'->>'has';

  -- ── 7. EVERY SURFACE THAT RENDERS IT ─────────────────────────────────────
  v_tl := public.order_timeline(v_o[3]);
  if coalesce(v_tl->'proof'->>'has','false') <> 'true' then
    raise exception 'c691: order_timeline (customer + admin/partner #75) has no proof';
  end if;

  v_card := public._order_customer_card(v_o[3]);
  if coalesce(v_card->'proof'->>'has','false') <> 'true' then
    raise exception 'c691: the Orders card has no proof';
  end if;
  if not (v_card ? 'eta') then
    raise exception 'c691: the Orders card has no eta block';
  end if;

  v_invoice := public.customer_invoice(v_o[3]);
  if coalesce(v_invoice->'delivery_proof'->>'has','false') <> 'true' then
    raise exception 'c691: the invoice/bill carries no proof — %',
      v_invoice->'delivery_proof';
  end if;

  -- and the delivered stop no longer offers a countdown
  v_eta := public._delivery_eta_block(v_d[3]);
  if coalesce(v_eta->>'state','') <> 'delivered' then
    raise exception 'c691: a delivered stop still reports state %', v_eta->>'state';
  end if;

  raise notice 'c691 step 7  — timeline, Orders card and invoice all carry the proof  OK';
  raise notice 'c691 PASS — ETA rebased on run start and on BOTH stop completions; proof visible on 3 surfaces + the bill.';
end
$proof$;

rollback;

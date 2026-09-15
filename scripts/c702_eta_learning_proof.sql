-- CHANGE #702 — the QA journey the spec asks for, as SQL: replay a week of
-- completed runs, report MAE before vs after, and prove the window narrows as
-- history grows.
--
-- It is not enough to show the model produces numbers. The claim being tested
-- is that the numbers are BETTER, so the fixture builds a world with a known
-- truth in it — a zone that is 70% slower than the optimiser thinks at 6 pm and
-- 10% faster at 6 am, with a rider who dwells 9 minutes rather than the
-- fleet's 4 — and then asks whether the fit recovered those facts and whether
-- the residual error fell.
--
-- SAFE ON PRODUCTION: one transaction, rolled back. The real eta_model is
-- rebuilt from the real (empty) history on the way out, so nothing is left
-- fitted to fixture data.
--
--   psql "$(cat ~/.medibo/dburl)" -v ON_ERROR_STOP=1 -f scripts/c702_eta_learning_proof.sql

\set ON_ERROR_STOP on
begin;

do $proof$
declare
  v_zone smallint := 9701;         -- a zone id no real row uses
  v_partner uuid;
  v_fit jsonb;
  i int; d int; h int;
  v_planned numeric; v_truth numeric; v_actual numeric;
  mae_before numeric; mae_after numeric;
  m_evening numeric; m_morning numeric; dwell numeric;
  band_small numeric; band_big numeric; v_p80 numeric;
begin
  select id into v_partner from delivery_partner_registrations order by created_at limit 1;
  if v_partner is null then raise exception 'c702: no delivery partner in this database'; end if;

  -- COLD START, measured first: no model at all is the state this platform was
  -- in the moment before #702 landed, and it must be #691's exact window.
  delete from public.eta_model;
  band_small := public._eta_band_min(v_zone);
  if round(band_small,1) <> round(
       coalesce((select (value #>> '{}')::numeric / 2 from public.app_settings
                  where key='delivery_eta_window_minutes'), 10), 1) then
    raise exception 'c702: an untrained platform must keep #691''s window, got +/-% min', band_small;
  end if;
  raise notice 'c702 step 0  — cold start band +/-% min = #691''s window  OK', round(band_small,1);

  -- ── a week of completed legs, with a truth the fit is not told ───────────
  -- 18:00 in this zone actually takes 1.70x the planned leg; 06:00 takes 0.90x.
  -- Dwell is 9 minutes, not the fleet's 4. Every "actual" is derived from the
  -- plan by those factors plus a small deterministic wobble, so the medians are
  -- recoverable and the test is not flaky.
  for d in 0..6 loop
    foreach h in array array[6, 18] loop
      for i in 1..6 loop
        v_planned := 8 + i;                                   -- 9..14 planned minutes
        v_truth   := case when h = 18 then 1.70 else 0.90 end;
        -- wobble: -1, 0, +1 minutes, cycling, so the MEDIAN is exactly v_truth
        v_actual  := v_planned * v_truth + ((i % 3) - 1);
        insert into public.delivery_leg_history(
          delivery_id, run_id, partner_id, zone_id, seq, leg_km, planned_min,
          actual_sec, dwell_sec, hour_ist, dow, started_at, ended_at, outcome,
          is_synthetic)
        values (gen_random_uuid(), gen_random_uuid(), v_partner, v_zone, i,
                round((v_planned/3.0)::numeric, 2), v_planned,
                (v_actual * 60)::int, 9 * 60, h::smallint, d::smallint,
                now() - make_interval(days => d, hours => 2),
                now() - make_interval(days => d),
                'delivered', true);
      end loop;
    end loop;
  end loop;

  -- ── MAE of the OLD estimate (multiplier 1.0 — what #691 shipped) ─────────
  select round(avg(abs(h.actual_sec/60.0 - h.planned_min))::numeric, 3)
    into mae_before
    from public.delivery_leg_history h where h.zone_id = v_zone;

  -- ── fit ──────────────────────────────────────────────────────────────────
  v_fit := public.eta_model_fit();
  if coalesce((v_fit->>'ok')::boolean,false) is not true then
    raise exception 'c702: eta_model_fit failed — %', v_fit;
  end if;

  m_evening := public._eta_multiplier(v_zone, 18::smallint);
  m_morning := public._eta_multiplier(v_zone, 6::smallint);
  dwell     := public._eta_dwell_min(v_partner);

  if abs(m_evening - 1.70) > 0.06 then
    raise exception 'c702: the 6 pm multiplier should be ~1.70, fit says %', m_evening;
  end if;
  if abs(m_morning - 0.90) > 0.06 then
    raise exception 'c702: the 6 am multiplier should be ~0.90, fit says %', m_morning;
  end if;
  if abs(dwell - 9) > 0.5 then
    raise exception 'c702: the rider dwell should be ~9 min, fit says %', dwell;
  end if;
  raise notice 'c702 step 1  — recovered 18:00 x%, 06:00 x%, dwell % min  OK',
    round(m_evening,3), round(m_morning,3), round(dwell,2);

  -- ── MAE of the LEARNED estimate ──────────────────────────────────────────
  select round(avg(abs(h.actual_sec/60.0
                       - h.planned_min * public._eta_multiplier(h.zone_id, h.hour_ist)))::numeric, 3)
    into mae_after
    from public.delivery_leg_history h where h.zone_id = v_zone;

  if mae_after >= mae_before then
    raise exception 'c702: learning did not reduce error — before % after %',
      mae_before, mae_after;
  end if;
  raise notice 'c702 step 2  — MAE % min -> % min (% %% better)  OK',
    mae_before, mae_after,
    round((100 * (mae_before - mae_after) / nullif(mae_before,0))::numeric, 1);

  -- ── the WINDOW narrows as history grows ──────────────────────────────────
  -- The honest comparison is the SAME zone before and after the platform had
  -- anything to learn from — not one zone against another, because an unseen
  -- zone inherits the global band and should. band_small was measured above
  -- with eta_model emptied; band_big is the same call after the fit.
  band_big := public._eta_band_min(v_zone);
  if band_big >= band_small then
    raise exception 'c702: the window did not narrow with history (cold +/-% min, learned +/-% min)',
      band_small, band_big;
  end if;
  raise notice 'c702 step 3  — band: cold start +/-% min -> learned +/-% min  OK',
    round(band_small,1), round(band_big,1);

  -- ...and the narrowing is the MODEL's, not just the configured floor.
  select p80_min into v_p80 from public.eta_model where scope='band' and key = v_zone::text;
  if v_p80 is null or v_p80 > 2 then
    raise exception 'c702: the fitted 80th-percentile residual should be ~1 min, got %', v_p80;
  end if;
  raise notice 'c702 step 4  — fitted p80 residual % min (floored to +/-% by config)  OK',
    round(v_p80,2), round(band_big,1);

  raise notice 'c702 PASS — model recovered the truth, MAE % -> %, window narrows with history.',
    mae_before, mae_after;
end
$proof$;

rollback;

-- Leave the real model fitted to the real (post-rollback) history, never to the
-- fixture: the transaction above is gone, so this rebuilds from what survives.
select public.eta_model_fit();

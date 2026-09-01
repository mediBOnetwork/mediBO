-- CHANGE #424 — the consumption inference engine, proven on Om's own example.
--
--   psql "$(cat ~/.medibo/dburl)" -X -A -t -f scripts/c424_proof.sql
--
-- c424_montikop_proof() seeds one synthetic pharmacy with the spec's exact
-- sequence — 10 bought 60 days ago (earliest expiry), 12 bought 30 days ago,
-- 8 delivered today — then asserts what the engine must conclude:
--
--   • velocity ≈ 0.37 units/day, learned from the purchase gaps alone;
--   • the January lot (earliest expiry, so FEFO's first) is fully presumed
--     consumed — 10 sold, 0 left;
--   • February's lot takes the spill and keeps a REAL remainder, with a band
--     around it rather than a fake exact;
--   • today's delivery has sold nothing, because a box cannot sell before it
--     arrives — that is the clock, and it is what makes the presumption honest;
--   • a one-tap correction pins the January lot at 2 and is never re-guessed.
--
-- The fixture deletes everything it created, including on failure.
select jsonb_pretty(public.c424_montikop_proof()) as montikop_proof;

-- The engine on the real network: what it learned, and where each number came
-- from. `pos_actual` rows are SKUs where #411's counter silently took over.
select public.pharmacy_velocity_learn(id) as learned
  from public.pharmacy_profiles
 where id in (select distinct pharmacy_id from public.pharmacy_stock);

select public.pharmacy_infer_lots(id) as inferred
  from public.pharmacy_profiles
 where id in (select distinct pharmacy_id from public.pharmacy_stock);

select method, count(*) as lots, round(avg(confidence), 2) as avg_confidence
  from public.pharmacy_lot_inference
 group by method order by lots desc;

select source, count(*) as skus, round(avg(per_day), 3) as avg_per_day
  from public.pharmacy_sku_velocity
 group by source order by skus desc;

-- The nightly job rides the ONE #305 dispatcher, at its own offset.
select name, ord, mode, enabled, run_at_ist
  from public.cron_task
 where name = 'pharmacy-consumption-infer';

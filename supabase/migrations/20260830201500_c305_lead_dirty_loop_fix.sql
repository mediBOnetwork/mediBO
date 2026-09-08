-- CHANGE #305 — the dirty-flag feedback loop, caught by step 1's instrumentation.
--
-- lead-pipeline ran 95 times in 24 hours at 13.3 s average / 53 s worst, on a
-- platform with no traffic, and lead_pipeline_state.dirty was STILL true the
-- instant a run finished reporting 0 new zones, 0 unclustered and 0 attached.
-- lead_pipeline_tick() clears the flag before it works, so the re-dirtying came
-- from the pipeline's own output: trg_leads_dirty fired FOR EACH ROW on
-- scraped_leads for columns that lead_pipeline_refresh() itself writes
-- (lead_score, distance_km, zone_id, delivery_zone, brand_key, matched_*,
-- lead_class, lead_type, status). Scoring 3,104 leads therefore re-armed the
-- job 3,104 times, forever. That is ~21 minutes of database time a day spent
-- re-deciding nothing.
--
-- Two corrections, both narrow:
--   1. the trigger watches only the pipeline's INPUT columns — the fields a
--      scrape run or an admin edit changes. A derived column changing is the
--      pipeline's own footprint, not new information.
--   2. FOR EACH STATEMENT, matching the two sibling triggers on
--      pharmacy_profiles and supplier_profiles. One bulk update is one event,
--      not one event per row.
-- The pipeline still re-runs on every genuinely new or edited lead.

drop trigger if exists trg_leads_dirty on public.scraped_leads;

create trigger trg_leads_dirty
after insert or delete or update of
  lat, lng, address, short_address, street, area, city, district, state,
  pincode, locality, name, phone, phone10, manual_class, is_target
on public.scraped_leads
for each statement
execute function public.trg_lead_pipeline_dirty();

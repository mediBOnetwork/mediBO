-- CHANGE #747 · step 3 — the words, the door, and the guards.
--
-- Three things that are not the feature but decide whether it is real:
--   1. every string the Catalogue prints exists as a ui_copy ROW, so changing a
--      word is an UPDATE and never a deploy;
--   2. the customer_nav_slot row finally points at a screen — the dead button
--      Om reported was a registry row aimed at page 0 (Home);
--   3. rg rules that fail the guard if a catalogue payload gets fat or slow,
--      which is the spec's own acceptance line (item 7) turned into a tripwire.

-- ── 1. the words ────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('catalogue.title',              to_jsonb('Catalogue'::text)),
  ('catalogue.subtitle',           to_jsonb('Browse the whole product list by class, company or salt.'::text)),
  ('catalogue.tab_browse',         to_jsonb('Browse'::text)),
  ('catalogue.tab_companies',      to_jsonb('Companies'::text)),
  ('catalogue.tab_salts',          to_jsonb('Salts'::text)),
  ('catalogue.tab_schemes',        to_jsonb('Schemes'::text)),
  ('catalogue.tab_cold',           to_jsonb('Cold chain'::text)),
  ('catalogue.tree_l0',            to_jsonb('Therapeutic class'::text)),
  ('catalogue.tree_l1',            to_jsonb('Chemical class'::text)),
  ('catalogue.tree_l2',            to_jsonb('Action class'::text)),
  ('catalogue.tree_home',          to_jsonb('All classes'::text)),
  ('catalogue.tree_products',      to_jsonb('View products'::text)),
  ('catalogue.tree_empty_root',    to_jsonb('The catalogue has no classes in this view.'::text)),
  ('catalogue.tree_empty',         to_jsonb('Nothing below this class in this view — open the products instead.'::text)),
  ('catalogue.companies_title',    to_jsonb('Companies'::text)),
  ('catalogue.companies_word',     to_jsonb('companies'::text)),
  ('catalogue.companies_empty',    to_jsonb('No company matches this view.'::text)),
  ('catalogue.company_search_hint',to_jsonb('Search a company'::text)),
  ('catalogue.company_subtitle',   to_jsonb('Products from this company'::text)),
  ('catalogue.letter_all',         to_jsonb('All'::text)),
  ('catalogue.salts_title',        to_jsonb('Salts'::text)),
  ('catalogue.salts_word',         to_jsonb('salts'::text)),
  ('catalogue.salts_lead',         to_jsonb('Biggest salts first — search to narrow.'::text)),
  ('catalogue.salts_empty',        to_jsonb('No salt matches this search in this view.'::text)),
  ('catalogue.salt_search_hint',   to_jsonb('Search a salt, e.g. Paracetamol'::text)),
  ('catalogue.salt_subtitle',      to_jsonb('Every brand for this salt'::text)),
  ('catalogue.brand_word',         to_jsonb('brand'::text)),
  ('catalogue.brands_word',        to_jsonb('brands'::text)),
  ('catalogue.schemes_empty',      to_jsonb('No product is running a scheme right now.'::text)),
  ('catalogue.cold_empty',         to_jsonb('No cold-chain product in this view.'::text)),
  ('catalogue.scheme_chip',        to_jsonb('Scheme available'::text)),
  ('catalogue.zone_switch',        to_jsonb('Available in my zone'::text)),
  ('catalogue.zone_anon_note',     to_jsonb('Showing the whole catalogue.'::text)),
  ('catalogue.zone_on_note',       to_jsonb('Showing what suppliers in your zone can send.'::text)),
  ('catalogue.zone_off_note',      to_jsonb('Showing the whole catalogue, including items no supplier near you stocks.'::text)),
  ('catalogue.filters_title',      to_jsonb('Filters'::text)),
  ('catalogue.filters_clear',      to_jsonb('Clear all'::text)),
  ('catalogue.filters_apply',      to_jsonb('Show results'::text)),
  ('catalogue.filters_on',         to_jsonb('Filters on'::text)),
  ('catalogue.f_pack_type',        to_jsonb('Pack type'::text)),
  ('catalogue.f_rx',               to_jsonb('Prescription'::text)),
  ('catalogue.f_rx_only',          to_jsonb('Rx only'::text)),
  ('catalogue.f_otc_only',         to_jsonb('OTC only'::text)),
  ('catalogue.f_flags',            to_jsonb('Product'::text)),
  ('catalogue.f_habit',            to_jsonb('Habit forming'::text)),
  ('catalogue.f_cold',             to_jsonb('Cold chain'::text)),
  ('catalogue.f_image',            to_jsonb('Has photo'::text)),
  ('catalogue.f_scheme',           to_jsonb('Has scheme'::text)),
  ('catalogue.sort_title',         to_jsonb('Sort'::text)),
  ('catalogue.sort_name',          to_jsonb('Name A–Z'::text)),
  ('catalogue.sort_newest',        to_jsonb('Newest added'::text)),
  ('catalogue.all_products',       to_jsonb('All products'::text)),
  ('catalogue.showing_word',       to_jsonb('shown'::text)),
  ('catalogue.load_more',          to_jsonb('Load more'::text)),
  ('catalogue.list_end',           to_jsonb('That is the whole list.'::text)),
  ('catalogue.list_empty',         to_jsonb('Nothing here in this view.'::text)),
  ('catalogue.list_empty_filtered',to_jsonb('Nothing matches these filters. Clear one and try again.'::text)),
  ('catalogue.counts_note',        to_jsonb('Counts refresh automatically.'::text)),
  ('catalogue.search_hint',        to_jsonb('Search a salt or a company'::text)),
  ('catalogue.retry',              to_jsonb('Retry'::text)),
  ('catalogue.failed',             to_jsonb('Could not load the catalogue.'::text))
on conflict (key) do nothing;

-- ── 2. the door ─────────────────────────────────────────────────────────────
-- The bug Om reported, in one row. #630 built the bar from customer_nav_slot
-- and gave every slot the page it opens; `catalogue` was given page 0 because
-- there was no catalogue screen to point at, so the second tab has re-opened
-- Home ever since. Page 12 is the CatalogueScreen this command adds — appended
-- rather than slotted in, because pages 3–10 are addressed by NUMBER from the
-- admin nav and 11 is My Shop (#536).
update public.customer_nav_slot
   set page_index = 12, updated_at = now()
 where slot_key = 'catalogue' and page_index <> 12;

insert into public.ui_copy(key, value) values
  ('home_shell.catalogue', to_jsonb('Catalogue'::text))
on conflict (key) do nothing;

-- ── 3. the guards ───────────────────────────────────────────────────────────
-- Payload shape: any change to what the catalogue answers has to be a decision
-- somebody made, not a drift. Pinned as an ANONYMOUS caller, which is the
-- viewer class the whole tree must serve inside anon's 3 s statement budget.
insert into public.rg_payload_targets(name, jwt_sub, sql, enabled, note) values
  ('c747_catalogue_home', null,
   'select public.catalogue_home(true)', true,
   'CHANGE #747 — the Catalogue landing: tabs, counts, filter vocabulary.'),
  ('c747_catalogue_tree_root', null,
   'select public.catalogue_tree(''{}''::text[], true)', true,
   'CHANGE #747 — the browse tree root: 22 therapeutic classes with counts.'),
  ('c747_catalogue_salts_top', null,
   'select public.catalogue_salts(null, 0, 10, true)', true,
   'CHANGE #747 — the salt index''s first page.')
on conflict (name) do update
  set sql = excluded.sql, note = excluded.note, enabled = true;

-- Spec item 7, as a tripwire rather than a promise: a catalogue payload that
-- gets FAT or SLOW fails rg_check, which fails the deploy.
--
-- Both numbers are deliberate. 300 ms is the spec's own line and sits well
-- inside anon's 3 s PostgREST budget — the #678 lesson is that a storefront RPC
-- which drifts past that budget shows the customer a Retry button, and it
-- drifts by growing, one payload at a time. 512 KB is roughly double what these
-- payloads measure today; the failure this catches is a rail of 24 cards
-- quietly becoming 24 raw MEDICINE rows again (get_storefront_feed returns 60+
-- columns per row, which is exactly how storefront_home_v2 reached ~1 MB).
insert into public.rg_behavior_tests(name, body, enabled, note) values
('c747_catalogue_budget', $rg$
do $c747$
declare
  t0 timestamptz; ms int; sz int; bad text := '';
  budget_ms int := 300; budget_kb int := 512;
begin
  t0 := clock_timestamp();
  sz := length(public.catalogue_home(true)::text);
  ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
  if ms > budget_ms then bad := bad || format('catalogue_home %sms; ', ms); end if;
  if sz > budget_kb * 1024 then bad := bad || format('catalogue_home %skb; ', sz/1024); end if;

  t0 := clock_timestamp();
  sz := length(public.catalogue_tree('{}'::text[], true)::text);
  ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
  if ms > budget_ms then bad := bad || format('catalogue_tree %sms; ', ms); end if;
  if sz > budget_kb * 1024 then bad := bad || format('catalogue_tree %skb; ', sz/1024); end if;

  t0 := clock_timestamp();
  sz := length(public.catalogue_companies(null, null, 0, 40, true)::text);
  ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
  if ms > budget_ms then bad := bad || format('catalogue_companies %sms; ', ms); end if;
  if sz > budget_kb * 1024 then bad := bad || format('catalogue_companies %skb; ', sz/1024); end if;

  t0 := clock_timestamp();
  sz := length(public.catalogue_salts(null, 0, 40, true)::text);
  ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
  if ms > budget_ms then bad := bad || format('catalogue_salts %sms; ', ms); end if;
  if sz > budget_kb * 1024 then bad := bad || format('catalogue_salts %skb; ', sz/1024); end if;

  t0 := clock_timestamp();
  sz := length(public.catalogue_list('tree', null, array['ANTI INFECTIVES'],
                                     '{}'::jsonb, 'name', true, null, 24)::text);
  ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
  if ms > budget_ms then bad := bad || format('catalogue_list %sms; ', ms); end if;
  if sz > budget_kb * 1024 then bad := bad || format('catalogue_list %skb; ', sz/1024); end if;

  if bad <> '' then
    raise exception 'RG_FAIL: catalogue budget blown (limit %ms / %kb) — %',
      budget_ms, budget_kb, bad;
  end if;
  raise exception 'RG_ROLLBACK';
end $c747$;
$rg$, true,
'CHANGE #747 — spec item 7. Every catalogue RPC answers inside 300 ms and under '
'512 KB, or the guard is red and nothing deploys.'),

-- The other half of item 7: the counts must come from the CACHE. A future
-- change that reaches for count(*) on "MEDICINE" would pass the timing test on
-- a warm box and fail it at 9 a.m., so the structural fact is asserted too.
('c747_catalogue_counts_cached', $rg$
do $c747$
declare n bigint; zones int;
begin
  select count(*) into n from public.catalogue_facet_count;
  if n < 1000 then
    raise exception 'RG_FAIL: catalogue_facet_count holds only % rows — the count cache is empty, so the catalogue is counting live', n;
  end if;
  select count(distinct zone_id) into zones from public.catalogue_facet_count;
  if zones < 2 then
    raise exception 'RG_FAIL: catalogue counts exist for % zone(s) — the "available in my zone" switch has nothing to read', zones;
  end if;
  if not exists (select 1 from public.catalogue_zone_avail) then
    raise exception 'RG_FAIL: catalogue_zone_avail is empty — the zone switch would silently show an empty catalogue';
  end if;
  if not exists (select 1 from public.cron_task
                  where name = 'catalogue_cache_refresh' and enabled) then
    raise exception 'RG_FAIL: the catalogue_cache_refresh cron task is missing or disabled — the counts would freeze';
  end if;
  raise exception 'RG_ROLLBACK';
end $c747$;
$rg$, true,
'CHANGE #747 — the counts are cached and the refresh is scheduled. Without this '
'the timing guard above can be satisfied by a lucky warm cache.'),

-- And the door itself. This is the bug that started the command: a nav row
-- pointing at a page that is not the screen it names.
('c747_catalogue_nav_reachable', $rg$
do $c747$
declare p int;
begin
  select page_index into p from public.customer_nav_slot where slot_key = 'catalogue';
  if p is null then
    raise exception 'RG_FAIL: the catalogue nav slot is gone';
  end if;
  if p = 0 then
    raise exception 'RG_FAIL: the Catalogue tab points at page 0 (Home) again — that is the dead button #747 fixed';
  end if;
  raise exception 'RG_ROLLBACK';
end $c747$;
$rg$, true,
'CHANGE #747 — the Catalogue bottom-nav slot opens the Catalogue, not Home.')
on conflict (name) do update
  set body = excluded.body, note = excluded.note, enabled = true;

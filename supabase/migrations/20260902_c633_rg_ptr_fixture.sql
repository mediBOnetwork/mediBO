-- CMD #633 (QA round) — storefront_ptr_entitlement seeds its own fixture.
--
-- The guard was red, and not because entitlement broke: its PRECONDITION had
-- drifted out of the catalog. It needed a row that is both priced
-- (medicine_pricing.pricing_ready AND ptr > 0) and buyable, and there is no
-- longer any such row — 54,399 products are buyable and the only 4 priced rows
-- are all buyable = false. So the guard raised
-- "RG_FAIL: no priced+buyable product exists, so PTR entitlement is untested"
-- and blocked every dev_cmd_complete on the box, on a data fact rather than a
-- regression.
--
-- buyable cannot be forced: medicine_set_buyable_trg derives it on every write
-- from the zone supplier arrays, so `update "MEDICINE" set buyable = true`
-- silently writes false. The fixture therefore goes the other way — take a
-- product that is ALREADY buyable and give it a price.
--
-- Nothing is written: the guard runs as one DO block that ends in RG_ROLLBACK,
-- exactly as the existing `update ... set ptr = v_ptr + 7` step already relies
-- on. A real priced+buyable product is still preferred when one exists, so this
-- only changes what happens when the catalog cannot supply the fixture.
--
-- Every assertion is unchanged. The guard is not weakened by this — it is made
-- independent of catalog drift, which is the only reason it went red.
insert into public.rg_behavior_tests (name, body, enabled, note)
values (
  'storefront_ptr_entitlement',
$rg_body$
do $rg$
declare
  v_ids   bigint[];
  v_cards jsonb;
  v_txt   text;
  v_ptr   numeric;
  v_mrp   numeric;
  v_pid   bigint;
  v_seeded boolean := false;
begin
  -- Preferred: a real priced+buyable product, so the guard tests live data.
  select mp.product_id, mp.ptr into v_pid, v_ptr
    from public.medicine_pricing mp
    join "MEDICINE" m on m.id = mp.product_id
   where coalesce(mp.pricing_ready,false) and coalesce(mp.ptr,0) > 0
     and lower(coalesce(m.buyable::text,'')) in ('true','t')
   limit 1;

  -- Fallback: seed one inside this transaction. The window off
  -- idx_medicine_buyable_true keeps it to a few ms; an MRP is required
  -- because _pricing_block returns the mrp_only base without one, which
  -- would make the entitled branch untestable rather than failing.
  if v_pid is null then
    select t.id, nullif(regexp_replace(coalesce(t.mrp::text,''),'[^0-9.]','','g'),'')::numeric
      into v_pid, v_mrp
      from (select m2.id, m2.mrp
              from "MEDICINE" m2
             where lower(coalesce(m2.buyable::text,'')) = any (array['true','t'])
             order by m2.id
             limit 200) t
     where nullif(regexp_replace(coalesce(t.mrp::text,''),'[^0-9.]','','g'),'')::numeric > 0
     order by t.id
     limit 1;
    if v_pid is null then
      raise exception 'RG_FAIL: no buyable product with an MRP exists, so PTR entitlement is untested';
    end if;
    -- A trade rate below MRP, and deliberately not equal to it, so the
    -- "PTR must not appear in an anonymous payload" assertion still bites.
    v_ptr := round(v_mrp * 0.8, 2);
    if v_ptr <= 0 or v_ptr = v_mrp then v_ptr := v_mrp - 1; end if;
    insert into public.medicine_pricing
      (product_id, ptr, gst_pct, pricing_ready, pricing_source, pricing_updated_at)
    values (v_pid, v_ptr, 12, true, 'rg_fixture', now())
    on conflict (product_id) do update
      set ptr = excluded.ptr, gst_pct = excluded.gst_pct, pricing_ready = true,
          pricing_source = 'rg_fixture';
    v_seeded := true;
  end if;
  v_ids := array[v_pid];

  perform set_config('request.jwt.claims', '', true);
  perform set_config('medibo.viewer_approved', '', true);
  if public.viewer_sees_trade_price() then
    raise exception 'RG_FAIL: an anonymous viewer is entitled to trade prices';
  end if;
  v_cards := public._sf_cards(v_ids);
  v_txt   := v_cards::text;

  if jsonb_array_length(coalesce(v_cards,'[]'::jsonb)) = 0 then
    raise exception 'RG_FAIL: the fixture product % renders no storefront card (seeded=%)',
      v_pid, v_seeded;
  end if;
  if v_cards #> '{0,pricing,card_price,has_ptr}' <> 'false'::jsonb then
    raise exception 'RG_FAIL: card_price.has_ptr is not false for an anonymous viewer -> %',
      v_cards #> '{0,pricing,card_price}';
  end if;
  if v_cards #> '{0,pricing,card_price}' ? 'ptr_display' then
    raise exception 'RG_FAIL: card_price carries a ptr_display key for an anonymous viewer';
  end if;
  if exists (select 1 from jsonb_object_keys(v_cards -> 0 -> 'pricing') k
              where k in ('ptr_display','ptr_caption','has_ptr','raw')) then
    raise exception 'RG_FAIL: the pricing block still carries PTR keys for an anonymous viewer';
  end if;
  select nullif(regexp_replace(coalesce(mrp::text,''), '[^0-9.]','','g'),'')::numeric
    into v_mrp from "MEDICINE" where id = v_pid;
  if v_ptr is distinct from v_mrp and position(public.inr_money(v_ptr) in v_txt) > 0 then
    raise exception 'RG_FAIL: the PTR value % appears in an anonymous storefront payload',
      public.inr_money(v_ptr);
  end if;
  if v_cards #> '{0,pricing,display_mode}' <> '"mrp_only"'::jsonb then
    raise exception 'RG_FAIL: an anonymous viewer got a full pricing block';
  end if;

  perform set_config('request.jwt.claims',
    (select json_build_object('sub', u.id, 'email', u.email, 'role','authenticated')::text
       from auth.users u join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
      where coalesce(a.is_super,false) limit 1), true);
  perform set_config('medibo.viewer_approved', '', true);
  if not public.viewer_sees_trade_price() then
    raise exception 'RG_FAIL: a super admin may not see trade prices';
  end if;
  v_cards := public._sf_cards(v_ids);
  if v_cards #> '{0,pricing,card_price,has_ptr}' <> 'true'::jsonb then
    raise exception 'RG_FAIL: a super admin gets no PTR on the card -> %',
      v_cards #> '{0,pricing,card_price}';
  end if;
  if coalesce(v_cards #>> '{0,pricing,card_price,ptr_display}', '') = '' then
    raise exception 'RG_FAIL: card_price.ptr_display is empty for a super admin';
  end if;
  if (v_cards #>> '{0,pricing,card_price,ptr_display}') <> public.inr_money(v_ptr) then
    raise exception 'RG_FAIL: the card shows % but medicine_pricing.ptr is %',
      v_cards #>> '{0,pricing,card_price,ptr_display}', public.inr_money(v_ptr);
  end if;

  update public.medicine_pricing set ptr = v_ptr + 7 where product_id = v_pid;
  v_cards := public._sf_cards(v_ids);
  if (v_cards #>> '{0,pricing,card_price,ptr_display}') <> public.inr_money(v_ptr + 7) then
    raise exception 'RG_FAIL: PTR did not follow medicine_pricing - expected %, got %',
      public.inr_money(v_ptr + 7), v_cards #>> '{0,pricing,card_price,ptr_display}';
  end if;

  if coalesce(v_cards #>> '{0,pack_label}', '') = ''
     and coalesce((select btrim(coalesce(pack_qty, pack_size, pack_type, ''))
                     from "MEDICINE" where id = v_pid), '') <> '' then
    raise exception 'RG_FAIL: the card lost its pack badge';
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$rg_body$,
  true,
  'CHANGE #274 - PTR is entitlement-gated in the RPC, not hidden in Flutter: an anonymous viewer''s storefront payload carries no ptr key and no PTR number anywhere, while a super admin gets card_price.ptr_display, and that value follows medicine_pricing.ptr live (a supplier bill import changes the card with no deploy). CMD #633 - the fixture is seeded inside the guard''s own rolled-back transaction when the catalog has no priced+buyable product, so catalog drift can no longer turn this guard red on a data fact.'
)
on conflict (name) do update
  set body = excluded.body,
      enabled = excluded.enabled,
      note = excluded.note;

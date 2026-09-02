-- CMD #463 — the PTR entitlement guard seeds its own fixture.
--
-- Why: rg_check went red on `storefront_ptr_entitlement` with
--   "RG_FAIL: no priced+buyable product exists, so PTR entitlement is untested".
-- Nothing about entitlement regressed. The guard picked its subject out of live
-- catalogue data — a product that had BOTH a captured trade price and
-- buyable=true — and that intersection drifted to empty: medicine_pricing holds
-- exactly 4 rows (176025/176026/176027/176044) and `buyable_recompute_tick`
-- has since flipped all four to false, because buyable is
-- (a supplier in an ACTIVE zone) AND (a numeric MRP) and their z_*_sup arrays
-- are empty. So the guard stopped testing the thing it exists to test, and went
-- red for a fixture reason rather than a behaviour reason — the worst failure
-- mode a guard has, because it blocks every completion in the fleet while
-- proving nothing.
--
-- Fix: keep every assertion exactly as it was, and stop depending on the data.
-- When no priced+buyable product exists, the guard now SEEDS one inside its own
-- transaction — the same transaction that already ends in RG_ROLLBACK, and that
-- already mutates medicine_pricing to prove the card follows the table live. The
-- seed is rolled back with everything else; medicine_pricing is untouched after
-- a run (verified: still exactly its 4 original rows).
--
-- Nothing is weakened. Anonymous still must not see a PTR key, a ptr_display, a
-- raw block or the number itself anywhere in the payload; a super admin still
-- must get ptr_display, and it must still follow medicine_pricing.ptr live. The
-- one thing that changed is that those assertions now always RUN.
insert into public.rg_behavior_tests (name, body, enabled, note) values (
'storefront_ptr_entitlement',
$rgt$
do $rg$
declare
  v_ids   bigint[];
  v_cards jsonb;
  v_txt   text;
  v_ptr   numeric;
  v_mrp   numeric;
  v_pid   bigint;
begin
  -- A product that HAS a captured trade price, so this can never pass
  -- vacuously by testing a product with no PTR to leak in the first place.
  select mp.product_id, mp.ptr into v_pid, v_ptr
    from public.medicine_pricing mp
    join "MEDICINE" m on m.id = mp.product_id
   where coalesce(mp.pricing_ready,false) and coalesce(mp.ptr,0) > 0
     and lower(coalesce(m.buyable::text,'')) in ('true','t')
   limit 1;

  if v_pid is null then
    -- The live catalogue carries no captured trade price on a buyable product
    -- right now. Seed one INSIDE this rolled-back transaction rather than go
    -- quiet: a drifting fixture must never be able to silence the entitlement
    -- assertions below.
    -- No ORDER BY on purpose: with the partial index on buyable this stops at
    -- the first qualifying row (~70 ms). Ordering it walked the whole low-id
    -- range where buyable has already been swept to false and pushed the guard
    -- past a minute, which times the whole rg_check run out.
    select m.id, nullif(regexp_replace(coalesce(m.mrp,''),'[^0-9.]','','g'),'')::numeric
      into v_pid, v_mrp
      from "MEDICINE" m
     where m.buyable is true
       and regexp_replace(coalesce(m.mrp,''),'[^0-9.]','','g') ~ '^[0-9]+(\.[0-9]+)?$'
       and nullif(regexp_replace(coalesce(m.mrp,''),'[^0-9.]','','g'),'')::numeric > 1
     limit 1;
    if v_pid is null then
      raise exception 'RG_FAIL: the catalogue has no buyable product with an MRP, so PTR entitlement cannot be tested';
    end if;
    -- A trade price that is plainly NOT the MRP, so the "the number must not
    -- appear anywhere in an anonymous payload" assertion below stays meaningful.
    v_ptr := round(v_mrp * 0.72, 2);
    if v_ptr = v_mrp or v_ptr <= 0 then v_ptr := round(v_mrp / 2, 2); end if;
    insert into public.medicine_pricing (product_id, ptr, gst_pct, pricing_ready, pricing_source)
    values (v_pid, v_ptr, 12, true, 'rg_fixture')
    on conflict (product_id) do update
      set ptr = excluded.ptr, pricing_ready = true, pricing_source = excluded.pricing_source;
  end if;
  v_ids := array[v_pid];

  -- ANONYMOUS: no session at all.
  perform set_config('request.jwt.claims', '', true);
  perform set_config('medibo.viewer_approved', '', true);
  if public.viewer_sees_trade_price() then
    raise exception 'RG_FAIL: an anonymous viewer is entitled to trade prices';
  end if;
  v_cards := public._sf_cards(v_ids);
  v_txt   := v_cards::text;

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
  -- The number itself must not appear anywhere in the payload, under any key.
  -- (Skipped in the freak case where the PTR equals the MRP, which is legitimately printed.)
  select nullif(regexp_replace(coalesce(mrp::text,''), '[^0-9.]','','g'),'')::numeric
    into v_mrp from "MEDICINE" where id = v_pid;
  if v_ptr is distinct from v_mrp and position(public.inr_money(v_ptr) in v_txt) > 0 then
    raise exception 'RG_FAIL: the PTR value % appears in an anonymous storefront payload',
      public.inr_money(v_ptr);
  end if;
  if v_cards #> '{0,pricing,display_mode}' <> '"mrp_only"'::jsonb then
    raise exception 'RG_FAIL: an anonymous viewer got a full pricing block';
  end if;

  -- SUPER ADMIN: the same card must carry the PTR.
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

  -- The displayed PTR is the one the table holds RIGHT NOW — never a cache.
  if (v_cards #>> '{0,pricing,card_price,ptr_display}') <> public.inr_money(v_ptr) then
    raise exception 'RG_FAIL: the card shows % but medicine_pricing.ptr is %',
      v_cards #>> '{0,pricing,card_price,ptr_display}', public.inr_money(v_ptr);
  end if;
  update public.medicine_pricing set ptr = v_ptr + 7 where product_id = v_pid;
  v_cards := public._sf_cards(v_ids);
  if (v_cards #>> '{0,pricing,card_price,ptr_display}') <> public.inr_money(v_ptr + 7) then
    raise exception 'RG_FAIL: PTR did not follow medicine_pricing — expected %, got %',
      public.inr_money(v_ptr + 7), v_cards #>> '{0,pricing,card_price,ptr_display}';
  end if;

  -- The card also has to keep its Plazza anatomy fields.
  if coalesce(v_cards #>> '{0,pack_label}', '') = ''
     and coalesce((select btrim(coalesce(pack_qty, pack_size, pack_type, ''))
                     from "MEDICINE" where id = v_pid), '') <> '' then
    raise exception 'RG_FAIL: the card lost its pack badge';
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$rgt$,
true,
'CHANGE #274 — PTR is entitlement-gated in the RPC, not hidden in Flutter: an anonymous viewer''s storefront payload carries no ptr key and no PTR number anywhere, while a super admin gets card_price.ptr_display, and that value follows medicine_pricing.ptr live (a supplier bill import changes the card with no deploy). CMD #463 — the guard now seeds its own priced+buyable fixture inside its rolled-back transaction, so drifting catalogue data can no longer silence these assertions.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

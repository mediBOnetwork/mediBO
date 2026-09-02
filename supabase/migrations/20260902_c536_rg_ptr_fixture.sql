-- CHANGE #536 — the PTR entitlement guard builds its own fixture.
--
-- rg_check() went red on 2026-09-01 21:23 with
--   RG_FAIL: no priced+buyable product exists, so PTR entitlement is untested
-- and stayed red, blocking every completion behind it. Nothing about PTR
-- entitlement had regressed: the guard's PRECONDITION had. It looked for a row
-- that was priced (medicine_pricing.pricing_ready + ptr > 0) AND buyable, and
-- all four priced rows the catalog currently holds carry buyable=false. Whether
-- those four medicines should be on sale is a catalog decision, not a schema
-- one, so flipping buyable on production to make a guard green would be exactly
-- the "bless the regression" move the regression guard exists to prevent.
--
-- The guard already ends in `raise exception 'RG_ROLLBACK'` and already mutates
-- medicine_pricing.ptr inside that rolled-back block to prove the card follows
-- the table. So it can build the rest of its own fixture the same way: pick any
-- priced row and make it buyable FOR THE DURATION OF THE CHECK. Nothing is
-- persisted, and the check stops depending on transient catalog state it never
-- meant to assert.
--
-- Every assertion below is byte-for-byte the one #274 wrote. The only changes:
--   * the fixture query no longer filters on buyable (a priced row is enough),
--   * one `update "MEDICINE" set buyable=true` establishes it, rolled back,
--   * zero priced rows is STILL a hard RG_FAIL — a vacuous guard is no guard.
update public.rg_behavior_tests set body = $body$
do $rg$
declare
  v_ids   bigint[];
  v_cards jsonb;
  v_txt   text;
  v_ptr   numeric;
  v_mrp   numeric;
  v_pid   bigint;
begin
  -- The fixture is BUILT, not found. See the migration header: filtering on
  -- buyable made a PTR-entitlement guard fail for a catalog reason.
  select mp.product_id, mp.ptr into v_pid, v_ptr
    from public.medicine_pricing mp
    join "MEDICINE" m on m.id = mp.product_id
   where coalesce(mp.pricing_ready,false) and coalesce(mp.ptr,0) > 0
   order by (lower(coalesce(m.buyable::text,'')) in ('true','t')) desc, mp.product_id
   limit 1;
  if v_pid is null then
    raise exception 'RG_FAIL: no priced product exists, so PTR entitlement is untested';
  end if;
  -- Rolled back with everything else below.
  update "MEDICINE" set buyable = true where id = v_pid;
  v_ids := array[v_pid];

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
$body$
where name = 'storefront_ptr_entitlement';

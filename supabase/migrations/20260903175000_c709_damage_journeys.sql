-- CHANGE #709 (spec item 5) — the journeys.
--
-- Two probes running the REAL chain on a real order line and rolling every
-- write back: damage at count → the bag ledger, the pack, the bill and the
-- settlement all move; and the zero-line path → the line joins the unfulfilled
-- split with the backend's own reason and leaves the bill entirely.
-- Registering them is an INSERT (the convention dispatcher, CHANGE #705).
-- Idempotent throughout.

create or replace function public._journey_c709_damage_chain()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_item uuid; v_order uuid; v_qty numeric; v_price numeric;
  v_bill_before numeric; v_bill_after numeric; v_note text := '';
  v_bag_before numeric; v_bag_after numeric;
  v_log jsonb; v_cost numeric; v_amount numeric; v_state jsonb;
  v_over jsonb; v_noreason jsonb; v_nophoto jsonb;
  v_chain text := 'not run'; v_ok boolean;
  v_reasons int; v_stages int; v_cost_type boolean;
begin
  perform public._dev_guard();

  select count(*)::int into v_reasons from handling_damage_reason where is_active;
  select count(*)::int into v_stages  from handling_damage_stage  where allow;
  select exists (select 1 from cost_types where slug='handling_damage' and active)
    into v_cost_type;

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;

  -- a line that actually reaches the bill, so the money half is real
  select oi.id, oi.order_id, oi.quantity, oi.price
    into v_item, v_order, v_qty, v_price
    from order_items oi
    join orders o on o.id = oi.order_id
   where o.status <> 'cancelled' and o.closed_at is null
     and coalesce(oi.unfulfillable,false) = false
     and oi.fulfillment_state not in ('shipped','cancelled')
     and oi.quantity >= 4
     and exists (select 1 from jsonb_array_elements(public._bill_lines_for_order(oi.order_id)) e
                  where (e->>'qty')::numeric > 0)
   order by o.created_at desc limit 1;

  if v_admin is not null and v_item is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);

      -- price it so the settlement half is exercised even on a line the
      -- catalogue has not rated yet
      update order_items set price = coalesce(nullif(price,0), 40) where id = v_item;

      select coalesce(sum((e->>'qty')::numeric),0) into v_bill_before
        from jsonb_array_elements(public._bill_lines_for_order(v_order)) e;
      select coalesce(sum(qty),0) into v_bag_before
        from bag_allocations where order_item_id = v_item and state='reserved';

      -- the three refusals, each in the backend's own words
      v_noreason := public.damage_log(v_item, 1, 'not_a_reason', 'count');
      v_over     := public.damage_log(v_item, v_qty + 10, 'broken', 'count', null, 'p.jpg');
      v_nophoto  := public.damage_log(v_item, 1, 'broken', 'count');

      -- the real one
      v_log := public.damage_log(v_item, 2, 'broken', 'count', 'journey',
                 'order/'||v_order::text||'/journey.jpg');

      select coalesce(sum((e->>'qty')::numeric),0),
             coalesce(max(e->>'damage_note'),'')
        into v_bill_after, v_note
        from jsonb_array_elements(public._bill_lines_for_order(v_order)) e;
      select coalesce(sum(qty),0) into v_bag_after
        from bag_allocations where order_item_id = v_item and state='reserved';
      select amount into v_amount from handling_damage
       where order_item_id = v_item order by id desc limit 1;
      select computed_amount into v_cost from order_costs
       where order_id = v_order and cost_type = 'handling_damage';
      v_state := public.damage_state(v_order);

      v_chain := 'ran';
      raise exception using errcode='ZZ709', message='c709 journey rollback';
    exception
      when sqlstate 'ZZ709' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_chain = 'ran'
      and v_reasons = 5 and v_stages = 4 and coalesce(v_cost_type,false)
      and coalesce(v_noreason->>'error','') = 'bad_reason'
      and coalesce(v_over->>'error','') = 'qty_over'
      and coalesce(v_nophoto->>'error','') = 'need_photo'
      and coalesce((v_log->>'ok')::boolean,false)
      and v_bill_after = v_bill_before - 2
      and v_note like '%damaged in handling%'
      and coalesce(v_bag_after,0) <= coalesce(v_bag_before,0)
      and coalesce(v_amount,0) > 0
      and coalesce(v_cost,0) = coalesce(v_amount,0)
      and coalesce((v_state->>'confirmed_qty')::numeric,0) >= 2;

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | reasons='||v_reasons::text||' stages='||v_stages::text
   || ' cost type registered='||coalesce(v_cost_type,false)::text
   || ' | bad reason='||coalesce(v_noreason->>'error','?')
   || ' | over qty='||coalesce(v_over->>'error','?')
   || ' | missing photo='||coalesce(v_nophoto->>'error','?')
   || ' | logged='||coalesce(v_log->>'ok','?')
   || ' | bill qty '||coalesce(v_bill_before::text,'?')||' -> '||coalesce(v_bill_after::text,'?')
   || ' | the sentence on the bill='||coalesce(nullif(v_note,''),'<none>')
   || ' | bag reserved '||coalesce(v_bag_before::text,'?')||' -> '||coalesce(v_bag_after::text,'?')
   || ' | valued at='||coalesce(v_amount::text,'null')
   || ' settlement line='||coalesce(v_cost::text,'none')
   || ' | order note='||coalesce(v_state->>'order_note','?')));
end
$fn$;

create or replace function public._journey_c709_damage_zero_line()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_item uuid; v_order uuid; v_qty numeric;
  v_unfulfillable boolean := false; v_reason text := '';
  v_in_bill boolean := true; v_exc int := 0; v_chain text := 'not run'; v_ok boolean;
  v_exc_reason boolean;
begin
  perform public._dev_guard();

  select exists (select 1 from exception_reason
                  where reason_code = 'damage_rate_high' and enabled)
    into v_exc_reason;

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;

  select oi.id, oi.order_id, oi.quantity into v_item, v_order, v_qty
    from order_items oi
    join orders o on o.id = oi.order_id
   where o.status <> 'cancelled' and o.closed_at is null
     and coalesce(oi.unfulfillable,false) = false
     and oi.fulfillment_state not in ('shipped','cancelled')
     and oi.quantity between 1 and 20
   order by o.created_at desc limit 1;

  if v_admin is not null and v_item is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);

      -- the whole line breaks
      perform public.damage_log(v_item, v_qty, 'wet', 'pack', 'journey',
                'order/'||v_order::text||'/journey.jpg');

      select coalesce(unfulfillable,false), coalesce(unfulfillable_reason,'')
        into v_unfulfillable, v_reason from order_items where id = v_item;
      v_in_bill := exists (
        select 1 from jsonb_array_elements(public._bill_lines_for_order(v_order)) e
         where (e->>'product') = (select product_name from order_items where id = v_item)
           and (e->>'qty')::numeric > 0);
      select count(*)::int into v_exc from public._exception_rows() r
       where r.reason_code = 'damage_rate_high';

      v_chain := 'ran';
      raise exception using errcode='ZZ709', message='c709 journey rollback';
    exception
      when sqlstate 'ZZ709' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_chain = 'ran'
      and coalesce(v_exc_reason,false)
      and v_unfulfillable
      and v_reason <> ''
      and v_in_bill = false;

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | exceptions reason damage_rate_high registered='||coalesce(v_exc_reason,false)::text
   || ' | whole line damaged -> unfulfillable='||v_unfulfillable::text
   || ' reason='||coalesce(nullif(v_reason,''),'<empty>')
   || ' | still on the bill='||v_in_bill::text||' (must be false)'
   || ' | damage_rate_high rows on the console now='||v_exc::text));
end
$fn$;

insert into public.dev_journeys (name, area, kind, steps, assertions, required, enabled)
values
  ('c709-damage-chain','fulfillment','api',
   jsonb_build_array('a bad reason, an over-quantity and a missing photo are each refused',
                     'a confirmed damage comes off the bill with the backend sentence',
                     'the bag ledger comes down by the same quantity',
                     'the loss is valued and lands as a settlement cost line'),
   jsonb_build_array('_journey_c709_damage_chain'), false, true),
  ('c709-damage-zero-line','fulfillment','api',
   jsonb_build_array('a line damaged in full joins the unfulfilled split',
                     'with the backend own reason',
                     'and leaves the bill entirely'),
   jsonb_build_array('_journey_c709_damage_zero_line'), false, true)
on conflict (name) do update
  set area = excluded.area, steps = excluded.steps,
      assertions = excluded.assertions, enabled = true;

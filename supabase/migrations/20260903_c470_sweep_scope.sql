-- CHANGE #470 (follow-up, same command) — two sweeps share one findings table.
--
-- #469's ops_state_sweep() lands its six ORDER-STATUS rules in the same
-- ops_state_finding table this change created for its six FULFILMENT rules.
-- Each sweep must therefore clear only what it owns: a clear step that says
-- "gone from MY live set" would otherwise wipe the other sweep's findings on
-- every tick and the console would flap. #469 already scoped its clear; this
-- scopes ours.
--
-- It also gives #469's rules their route, so an impossible state it finds
-- carries the same one-tap link every other exception carries.

insert into public.exception_route_map (class_key, route, note) values
  ('rule:order_state_unreachable',      'customer_order', 'Order in a status nothing can reach'),
  ('rule:delivered_not_accepted',       'customer_order', 'Delivered without being accepted'),
  ('rule:order_delivered_no_delivery',  'delivery',       'Delivered with no delivered run'),
  ('rule:delivery_delivered_no_dispatch','delivery',      'Delivered without going out'),
  ('rule:delivery_ahead_of_order',      'delivery',       'Delivered under a cancelled order'),
  ('rule:order_closed_unbilled',        'bill_pipeline',  'Closed with no rendered bill')
on conflict (class_key) do update
  set route = excluded.route, note = excluded.note;

create or replace function public.ops_state_machine_sweep(p_limit integer default 200)
returns jsonb
language plpgsql security definer set search_path to 'public' as $function$
declare
  v_lim   int := greatest(least(coalesce(p_limit, 200), 1000), 1);
  v_found int := 0;
  v_clear int := 0;
  -- The rules THIS sweep owns. ops_state_finding is shared with #469's
  -- ops_state_sweep(), so the clear below must never reach past this list.
  v_mine  text[] := array['item_packed_uncollected','item_counted_uncollected',
                          'bagged_uncounted','unfulfillable_packed',
                          'delivered_no_proof','closed_with_live_items'];
begin
  create temp table _c470_live on commit drop as
    select 'item_packed_uncollected'::text as rule_key, oi.id::text as entity_id,
           oi.order_id, oi.zone_id,
           coalesce(nullif(oi.product_name,''), 'Line ' || left(oi.id::text,8)) as label,
           coalesce(nullif(oi.assigned_supplier,''), '—') as detail
      from public.order_items oi
     where coalesce(oi.packed, false)
       and coalesce(oi.collect_locked, false) = false
       and coalesce(oi.status,'') <> 'cancelled'
       and coalesce(oi.unfulfillable, false) = false
    union all
    select 'item_counted_uncollected', oi.id::text, oi.order_id, oi.zone_id,
           coalesce(nullif(oi.product_name,''), 'Line ' || left(oi.id::text,8)),
           coalesce(nullif(oi.assigned_supplier,''), '—')
      from public.order_items oi
     where oi.wh_recount_qty is not null
       and coalesce(oi.collect_locked, false) = false
       and coalesce(oi.status,'') <> 'cancelled'
    union all
    select 'bagged_uncounted', oi.id::text, oi.order_id, oi.zone_id,
           coalesce(nullif(oi.product_name,''), 'Line ' || left(oi.id::text,8)),
           coalesce(nullif(oi.assigned_supplier,''), '—')
      from public.order_items oi
     where oi.wh_recount_qty is null
       and coalesce(oi.status,'') <> 'cancelled'
       and exists (select 1 from public.bag_allocations ba where ba.order_item_id = oi.id)
    union all
    select 'unfulfillable_packed', oi.id::text, oi.order_id, oi.zone_id,
           coalesce(nullif(oi.product_name,''), 'Line ' || left(oi.id::text,8)),
           coalesce(nullif(oi.unfulfillable_reason,''), '—')
      from public.order_items oi
     where coalesce(oi.unfulfillable, false)
       and coalesce(oi.packed, false)
    union all
    select 'delivered_no_proof', d.id::text, d.order_id, d.zone_id,
           coalesce(nullif(o.order_code,''), 'Stop ' || left(d.id::text,8)),
           coalesce(nullif(d.proof_method,''), '—')
      from public.deliveries d
      left join public.orders o on o.id = d.order_id
     where lower(coalesce(d.status,'')) in ('delivered','completed')
       and d.otp_verified_at is null
       and coalesce(d.proof_photo_path,'') = ''
       and coalesce(d.signature_path,'') = ''
    union all
    select 'closed_with_live_items', o.id::text, o.id, o.zone_id,
           coalesce(nullif(o.order_code,''), 'Order ' || left(o.id::text,8)),
           coalesce(nullif(o.pharmacy_name,''), '—')
      from public.orders o
     where o.closed_at is not null
       and exists (select 1 from public.order_items oi
                    where oi.order_id = o.id
                      and coalesce(oi.status,'') <> 'cancelled'
                      and coalesce(oi.unfulfillable, false) = false
                      and coalesce(oi.packed, false) = false);

  with ins as (
    insert into public.ops_state_finding
      (rule_key, entity_kind, entity_id, order_id, zone_id, label, detail)
    select l.rule_key, r.entity_kind, l.entity_id, l.order_id, l.zone_id,
           l.label, l.detail
      from _c470_live l
      join public.ops_state_rule r on r.rule_key = l.rule_key and r.enabled
     order by l.rule_key, l.entity_id
     limit v_lim
    on conflict (rule_key, entity_id) where cleared_at is null
    do update set last_seen_at = now(),
                  runs  = public.ops_state_finding.runs + 1,
                  label = excluded.label,
                  detail = excluded.detail
    returning (xmax = 0) as inserted)
  select count(*) filter (where inserted) into v_found from ins;

  with cl as (
    update public.ops_state_finding f
       set cleared_at = now()
     where f.cleared_at is null
       and f.rule_key = any (v_mine)
       and not exists (select 1 from _c470_live l
                        where l.rule_key = f.rule_key and l.entity_id = f.entity_id)
    returning 1)
  select count(*) into v_clear from cl;

  return jsonb_build_object('ok', true, 'opened', v_found, 'cleared', v_clear,
                            'rules', v_mine,
                            'open_total', (select count(*) from public.ops_state_finding
                                            where cleared_at is null
                                              and rule_key = any (v_mine)));
end $function$;

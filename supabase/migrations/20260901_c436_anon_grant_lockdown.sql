-- CHANGE #436 — the default PUBLIC EXECUTE grant, closed as a CLASS.
--
-- Bug (filed from #401 QA, pre-existing, NOT introduced by it): 10
-- admin_supplier_* RPCs and most pack_* RPCs are callable with the anon key
-- that ships in lib/supabase_config.dart. Same shape as feature_gaps #25,
-- CHANGE #353, CHANGE #395 and audit_write() in #422: every new SECURITY
-- DEFINER function inherits Postgres's default `GRANT EXECUTE TO PUBLIC`, and
-- `anon` is a member of PUBLIC.
--
-- Reproduced live on 2026-09-01 with nothing but the bundled anon key:
--   pack_nav(<order>)                 -> {"total":1,"packed":0,"left":1,...}
--   pack_count_source_audit(<order>)  -> product_id, product_name, order_item_id,
--                                        counted qty for every line of the order
-- Four pack_* RPCs had NO body-level guard at all; the rest returned
-- not_authorized only because their own body asked get_my_role().
--
-- This migration fixes the class, not the ten names:
--   1. body-level guards on the four that had none (defence in depth — a guard
--      in the body survives a future re-GRANT),
--   2. a catalog-driven revoke over EVERY public.admin_* / public.pack_*
--      function (164 of them; all SECURITY DEFINER, so nested calls keep
--      running as the owner and nothing internal breaks),
--   3. rpc_anon_rule / rpc_anon_allow — the rule is DATA, so the next hot
--      surface is one INSERT, not a deploy,
--   4. rg behaviour test `privileged_rpcs_are_not_anon`, which turns rg_check
--      red — and rg_check red blocks every dev_cmd_complete on this box,
--   5. journey bug-436 (_journey_bug436), the permanent linked journey.
-- Idempotent throughout: a resumed worker re-applies it as a no-op.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. BODY-LEVEL GUARDS on the four RPCs that had none.
--    Same idiom as pack_reset_counts / pack_mark_item / pack_list_orders_core:
--    get_my_role() NOT IN ('admin','super_admin') -> refuse. Each refusal keeps
--    the function's OWN return shape, so a caller never type-errors on a denial.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.pack_nav(p_order_id uuid)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select case when public.get_my_role() not in ('admin','super_admin')
              then jsonb_build_object('error','not_authorized')
  else (
  with lines as (
    select oi.id, oi.quantity as ordered,
           coalesce(oi.received_qty,0) as received,
           coalesce(oi.packed_qty,0) as packed_qty,
           oi.pack_counted_qty,
           coalesce(
             nullif((select coalesce(sum(ba.qty),0) from bag_allocations ba
                      where ba.order_item_id = oi.id and ba.state in ('reserved','packed')),0),
             least(
               (select coalesce(sum(bic.qty),0) from bag_item_counts bic
                 where bic.assigned_supplier = oi.assigned_supplier
                   and bic.product_id = oi.product_id and bic.qty > 0),
               coalesce(oi.received_qty,0))
           ) as in_bag_qty
    from order_items oi
    where oi.order_id = p_order_id
      and oi.fulfillment_state not in ('shipped','cancelled') and coalesce(unfulfillable,false) = false
  ),
  calc as (
    select l.*,
           greatest(least(l.in_bag_qty, l.ordered), 0) as packable_qty
    from lines l
  ),
  done as (
    select c.*,
      ( c.packable_qty > 0 and c.packed_qty >= c.packable_qty and c.packed_qty > 0 ) as is_packed,
      ( c.pack_counted_qty is not null and c.packable_qty > 0
        and coalesce(c.pack_counted_qty,0) >= c.packable_qty ) as is_counted
    from calc c
  )
  select jsonb_build_object(
    'total',      count(*)::int,
    'packed',     count(*) filter (where is_packed)::int,
    'left',       count(*) filter (where not is_packed)::int,
    'done',       count(*) filter (where is_packed)::int,
    'done_left',  count(*) filter (where not is_packed)::int,
    'verified',   count(*) filter (where is_packed and is_counted)::int,
    'all_packed', (count(*) filter (where not is_packed) = 0)
  ) from done
  ) end;
$function$;

create or replace function public.pack_item_bags(p_order_item_id uuid)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  SELECT case when public.get_my_role() not in ('admin','super_admin') then '[]'::jsonb
  else coalesce((
    SELECT jsonb_agg(jsonb_build_object('bag_no',bag_no,'qty',qty,'state',state) ORDER BY bag_no)
    FROM bag_allocations WHERE order_item_id=p_order_item_id AND state = 'reserved'
  ),'[]'::jsonb) end;
$function$;

create or replace function public.pack_count_source_audit(p_order_id uuid)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select case when public.get_my_role() not in ('admin','super_admin')
              then jsonb_build_object('status','error','error','not_authorized')
  else (
  with items as (
    select oi.id as order_item_id, oi.product_id, oi.product_name,
           oi.pack_counted_qty, coalesce(oi.packed,false) as packed
    from order_items oi
    where oi.order_id = p_order_id and oi.fulfillment_state not in ('shipped','cancelled')
  ), voice as (
    select pm.product_id, sum(pm.qty) filter (where pm.status <> 'deleted') as voice_total,
           count(*) filter (where pm.status <> 'deleted') as active_mentions
    from pack_clip_mentions pm
    where pm.order_id = p_order_id
      and pm.the_date = ((now() at time zone 'Asia/Kolkata')::date)
    group by pm.product_id
  )
  select jsonb_build_object('status','ok','order_id',p_order_id,
    'items', coalesce(jsonb_agg(jsonb_build_object(
      'order_item_id', i.order_item_id, 'product_id', i.product_id, 'product_name', i.product_name,
      'actual_total', i.pack_counted_qty, 'voice_total', v.voice_total, 'packed', i.packed,
      'source', case when v.active_mentions > 0 and v.voice_total = i.pack_counted_qty then 'voice'
                     when v.active_mentions > 0 then 'mixed'
                     when i.pack_counted_qty is not null then 'manual'
                     else 'uncounted' end,
      'mismatch', (coalesce(v.active_mentions,0) > 0 and v.voice_total is distinct from i.pack_counted_qty)
    ) order by i.product_name),'[]'::jsonb))
  from items i left join voice v on v.product_id = i.product_id
  ) end;
$function$;

create or replace function public.pack_mention_product_totals(p_order_id uuid)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select case when public.get_my_role() not in ('admin','super_admin') then '{}'::jsonb
  else (
  with has_mentions as (
    select exists (select 1 from pack_clip_mentions p where p.order_id = p_order_id) as yes
  ), mentions as (
    -- voice mentions when they exist, otherwise the real packed quantities
    select p.product_id,
           coalesce(sum(p.qty) filter (where p.status in ('counted','readded')),0) as counted_total
    from pack_clip_mentions p, has_mentions h
    where h.yes and p.order_id = p_order_id and p.product_id is not null
    group by p.product_id
    union all
    select oi.product_id, sum(coalesce(oi.packed_qty,0)) as counted_total
    from order_items oi, has_mentions h
    where not h.yes and oi.order_id = p_order_id
      and coalesce(oi.packed_qty,0) > 0
      and oi.fulfillment_state not in ('cancelled')
    group by oi.product_id
  ), ord as (
    select oi.product_id, sum(oi.quantity) as ordered_total
    from order_items oi
    where oi.order_id = p_order_id and oi.fulfillment_state not in ('shipped','cancelled')
    group by oi.product_id
  ), j as (
    select m.product_id,
           m.counted_total,
           coalesce(o.ordered_total,0) as ordered_total,
           case when coalesce(o.ordered_total,0) > 0
                then least(m.counted_total, o.ordered_total) else m.counted_total end as accepted,
           case when coalesce(o.ordered_total,0) > 0
                then greatest(m.counted_total - o.ordered_total, 0) else 0 end as over_qty
    from mentions m left join ord o on o.product_id = m.product_id
  )
  select coalesce(jsonb_object_agg(j.product_id::text, jsonb_build_object(
           'counted_total', j.counted_total,
           'ordered_total', j.ordered_total,
           'accepted_total', j.accepted,
           'over_qty', j.over_qty,
           'is_over', (j.over_qty > 0),
           'is_full', (j.ordered_total > 0 and j.accepted >= j.ordered_total),
           'base_label', j.accepted::text || '/' || j.ordered_total::text,
           'base_colors', case when j.ordered_total > 0 and j.accepted >= j.ordered_total
                               then jsonb_build_object('bg','#E1F5EE','fg','#0F6E56')
                               when j.counted_total = 0 then jsonb_build_object('bg','#F3F4F6','fg','#6B7280')
                               else jsonb_build_object('bg','#FEF3C7','fg','#92400E') end,
           'over_label', case when j.over_qty > 0 then j.over_qty::text else null end,
           'over_colors', case when j.over_qty > 0 then jsonb_build_object('bg','#FBE9E7','fg','#B42318') else null end,
           'label', case when j.over_qty > 0
                         then j.over_qty::text || '+' || j.accepted::text || '/' || j.ordered_total::text
                         else j.accepted::text || '/' || j.ordered_total::text end,
           'colors', case when j.ordered_total > 0 and j.accepted >= j.ordered_total
                          then jsonb_build_object('bg','#E1F5EE','fg','#0F6E56')
                          when j.counted_total = 0 then jsonb_build_object('bg','#F3F4F6','fg','#6B7280')
                          else jsonb_build_object('bg','#FEF3C7','fg','#92400E') end
         )), '{}'::jsonb)
  from j
  ) end;
$function$;

-- pack_get_queue only refused anon because the core it delegates to refuses.
-- Say it in its own body too, so the refusal cannot be lost by an edit to the
-- helper. Behaviourally a no-op for every caller that already passes.
create or replace function public.pack_get_queue(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v jsonb; v_items jsonb; v_total int; v_packed int; v_done int; v_start int; v_groups jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  v := public._pack_get_queue_core(p_order_id);
  if v ? 'error' then return v; end if;

  v_items  := coalesce(v->'items','[]'::jsonb);
  v_total  := jsonb_array_length(v_items);

  select count(*) into v_packed from jsonb_array_elements(v_items) it
   where (it->>'is_packed')::boolean is true;
  select count(*) into v_done from jsonb_array_elements(v_items) it
   where (it->>'is_done')::boolean is true;

  select coalesce(min(ord), -1) into v_start
  from (select (row_number() over ())::int - 1 as ord, it from jsonb_array_elements(v_items) it) z
  where coalesce((z.it->>'is_done')::boolean, false) = false;

  select coalesce(jsonb_agg(g order by g_is_null, g_bag_no), '[]'::jsonb) into v_groups
  from (
    select (it->>'bag_no' is null)              as g_is_null,
           (it->>'bag_no')::int                 as g_bag_no,
           jsonb_build_object(
             'bag_no',       (it->>'bag_no')::int,
             'header_label', coalesce(it->>'bag_label', v->'labels'->>'no_bag'),
             'item_count',   count(*),
             'order_item_ids', jsonb_agg(it->>'order_item_id')
           ) as g
    from jsonb_array_elements(v_items) it
    group by (it->>'bag_no' is null), (it->>'bag_no')::int, it->>'bag_label'
  ) z;

  return v || jsonb_build_object(
    'nav', jsonb_build_object(
      'total',       v_total,
      'packed',      v_packed,             -- actually packed (matches what left the bag)
      'left',        v_total - v_packed,
      'done',        v_done,               -- packed AND pack-counted
      'done_left',   v_total - v_done,
      'bag_count',   jsonb_array_length(coalesce(v->'bag_stats','[]'::jsonb)),
      'start_index', case when v_start < 0 then 0 else v_start end,
      'all_packed',  (v_start < 0)
    ),
    'bag_groups', v_groups
  );
end; $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE RULE IS DATA. A new hot prefix is one INSERT, never a deploy.
--    rpc_anon_allow is the documented escape hatch for a genuinely tokenless
--    caller (the shape of inquiry_rate_capture in #353) — it starts empty
--    because no admin_* / pack_* RPC has one.
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.rpc_anon_rule (
  prefix     text primary key,
  note       text not null,
  created_at timestamptz not null default now()
);
create table if not exists public.rpc_anon_allow (
  fn_name    text primary key,
  reason     text not null,
  created_at timestamptz not null default now()
);

alter table public.rpc_anon_rule  enable row level security;
alter table public.rpc_anon_rule  force  row level security;
alter table public.rpc_anon_allow enable row level security;
alter table public.rpc_anon_allow force  row level security;

revoke all on table public.rpc_anon_rule  from public, anon, authenticated;
revoke all on table public.rpc_anon_allow from public, anon, authenticated;
grant  all on table public.rpc_anon_rule  to service_role;
grant  all on table public.rpc_anon_allow to service_role;

insert into public.rpc_anon_rule(prefix, note) values
  ('admin\_%', 'CHANGE #436 — every admin screen RPC. An anonymous caller has no admin identity to ask about.'),
  ('pack\_%',  'CHANGE #436 — the warehouse packing surface. pack_nav and pack_count_source_audit were returning live order lines to the bundled anon key.')
on conflict (prefix) do update set note = excluded.note;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE REVOKE. Catalog-driven, so it covers the ten names in the report AND
--    the 136 nobody had looked at yet — and re-running it is a no-op.
-- ─────────────────────────────────────────────────────────────────────────────

do $lockdown$
declare f record; v_n int := 0;
begin
  for f in
    select format('public.%I(%s)', p.proname, pg_get_function_identity_arguments(p.oid)) as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind = 'f'
       and exists (select 1 from public.rpc_anon_rule r where p.proname like r.prefix)
       and not exists (select 1 from public.rpc_anon_allow a where a.fn_name = p.proname)
  loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
    v_n := v_n + 1;
  end loop;
  raise notice 'c436: locked down % function(s)', v_n;
  if v_n = 0 then
    raise exception 'c436: the rule matched no function at all — refusing to claim a lockdown that did nothing';
  end if;
end $lockdown$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE PERMANENT GUARD. rg_check() runs this; a red rg_check blocks every
--    dev_cmd_complete on the box, so the class cannot ship again — and it is
--    written as a PATTERN, because a guard written as a list of names only ever
--    catches the bug it was written for (the lesson audit_write left in #422).
-- ─────────────────────────────────────────────────────────────────────────────

insert into public.rg_behavior_tests(name, body, enabled, note) values (
'privileged_rpcs_are_not_anon',
$behaviour$
do $rg$
declare f record; v_checked int := 0;
begin
  -- The rg runner executes this inside a SECURITY DEFINER function where
  -- `set role` is illegal, so the live tokenless call lives in
  -- scripts/anon_grant_audit.sh and this guard asks the catalog — which is
  -- the authoritative answer about a GRANT anyway.
  for f in
    select p.oid,
           p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind = 'f'
       and exists (select 1 from public.rpc_anon_rule r where p.proname like r.prefix)
       and not exists (select 1 from public.rpc_anon_allow a where a.fn_name = p.proname)
  loop
    v_checked := v_checked + 1;
    if has_function_privilege('anon', f.oid, 'execute') then
      raise exception 'RG_FAIL: anon can EXECUTE % — the anon key ships inside the web bundle and the APK, so that is a PUBLIC endpoint on an admin/warehouse surface. Every SECURITY DEFINER function inherits Postgres''s default GRANT TO PUBLIC; add the explicit revoke, or record a tokenless caller in rpc_anon_allow (#436, same shape as #25/#353/#395/#422)', f.sig;
    end if;
    if not has_function_privilege('authenticated', f.oid, 'execute') then
      raise exception 'RG_FAIL: authenticated cannot EXECUTE % — the lockdown revoked PUBLIC without re-granting the signed-in role, which locks the admin screens out of their own RPC (#436)', f.sig;
    end if;
  end loop;

  -- A guard that matches nothing passes vacuously. Say so instead.
  if v_checked = 0 then
    raise exception 'RG_FAIL: rpc_anon_rule matched no function — the anon-grant guard would have passed without checking anything (#436)';
  end if;

  -- The four that had no body guard at all must keep asking who is calling,
  -- so a future re-GRANT still cannot read a live order.
  for f in
    select p.oid, p.proname as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('pack_nav','pack_count_source_audit','pack_item_bags',
                         'pack_mention_product_totals','pack_get_queue')
       and p.prosrc !~ 'get_my_role'
  loop
    raise exception 'RG_FAIL: % lost its body-level role guard — the GRANT is the outer lock, get_my_role() is the inner one and #436 exists because it only had the outer (#436)', f.sig;
  end loop;

  raise exception 'RG_ROLLBACK';
end $rg$;
$behaviour$,
true,
'CHANGE #436 — no public.admin_* / public.pack_* function may hold anon EXECUTE. Pattern-driven from rpc_anon_rule so a new surface is one INSERT; rpc_anon_allow is the escape hatch for a genuinely tokenless caller. Red here turns rg_check red, which blocks every dev_cmd_complete.')
on conflict (name) do update
  set body = excluded.body, enabled = true, note = excluded.note;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. THE LINKED JOURNEY (dev_journeys.bug-436, auto-created by bug_report).
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public._journey_bug436()
returns jsonb language plpgsql security definer set search_path to 'public'
as $fn$
declare v_total int; v_open int; v_unguarded int; v_no_auth int;
        v_a1 boolean; v_a2 boolean; v_a3 boolean; v_a4 boolean; v_a5 boolean; v_ok boolean;
begin
  -- a1: the doors still EXIST. A bool_and over a vanished function is silently
  -- true, which is how a security journey quietly stops asserting anything.
  select count(*) into v_total
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.prokind='f'
     and exists (select 1 from public.rpc_anon_rule r where p.proname like r.prefix);
  v_a1 := v_total >= 140;

  -- a2: not one of them is reachable with the key that ships in the bundle.
  select count(*) into v_open
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.prokind='f'
     and exists (select 1 from public.rpc_anon_rule r where p.proname like r.prefix)
     and not exists (select 1 from public.rpc_anon_allow a where a.fn_name = p.proname)
     and has_function_privilege('anon', p.oid, 'execute');
  v_a2 := v_open = 0;

  -- a3: the three the bug report named by hand — a bulk company re-link, a
  -- forced settlement of a supplier order, and a supplier status change.
  v_a3 := not has_function_privilege('anon','public.admin_supplier_company_bulk_link(jsonb)','execute')
      and not has_function_privilege('anon','public.admin_supplier_order_force_settle(uuid,text)','execute')
      and not has_function_privilege('anon','public.admin_supplier_action(uuid,text)','execute');

  -- a4: the four with NO body guard now guard themselves. pack_count_source_audit
  -- was returning product_id, product_name, order_item_id and counted qty for
  -- every line of any order id, tokenless.
  select count(*) into v_unguarded
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public'
     and p.proname in ('pack_nav','pack_count_source_audit','pack_item_bags',
                       'pack_mention_product_totals','pack_get_queue')
     and p.prosrc !~ 'get_my_role';
  v_a4 := v_unguarded = 0;

  -- a5: the revoke did not lock the admin screens out of their own RPCs.
  select count(*) into v_no_auth
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.prokind='f'
     and exists (select 1 from public.rpc_anon_rule r where p.proname like r.prefix)
     and not has_function_privilege('authenticated', p.oid, 'execute');
  v_a5 := v_no_auth = 0;

  v_ok := v_a1 and v_a2 and v_a3 and v_a4 and v_a5;
  return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'admin_*/pack_* RPCs present='||v_total::text||' (>=140)='||v_a1::text||
      ' | anon EXECUTE holes='||v_open::text||' -> none='||v_a2::text||
      ' | the 3 named admin_supplier_* denied to anon='||v_a3::text||
      ' | body-level guard on all 5 pack RPCs='||v_a4::text||
      ' | authenticated still holds EXECUTE everywhere='||v_a5::text));
end $fn$;

revoke all on function public._journey_bug436() from public, anon, authenticated;
grant execute on function public._journey_bug436() to service_role;

update public.dev_journeys set
  area = 'supplier',
  kind = 'api',
  steps = jsonb_build_array(
    'Enumerate every public.admin_* and public.pack_* function from rpc_anon_rule and assert they still EXIST — a bool_and over a function that has vanished is silently true.',
    'Ask Postgres directly whether anon can EXECUTE any of them (has_function_privilege), because every SECURITY DEFINER function inherits the default GRANT TO PUBLIC and anon is a member of PUBLIC — that is how feature_gaps #25, CHANGE #353, CHANGE #395 and audit_write in #422 all happened.',
    'Assert the three the bug report named by hand are shut: admin_supplier_company_bulk_link (re-links a supplier''s companies), admin_supplier_order_force_settle (force-settles a supplier order), admin_supplier_action (changes supplier status).',
    'Assert the four pack RPCs that had NO body-level guard now ask get_my_role() themselves — the GRANT is the outer lock, the body is the inner one, and #436 exists because these only ever had the outer. pack_count_source_audit returned product_id, product_name, order_item_id and counted quantity for every line of any order id, tokenless.',
    'Assert the revoke did not overshoot: authenticated must still hold EXECUTE on all of them, or the lockdown would have locked the admin and warehouse screens out of their own backend.'
  ),
  assertions = jsonb_build_array(
    'all admin_*/pack_* RPCs still present (>=140)',
    'none EXECUTE-able by anon',
    'admin_supplier_company_bulk_link / _order_force_settle / _action denied to anon',
    'pack_nav, pack_count_source_audit, pack_item_bags, pack_mention_product_totals, pack_get_queue each carry a get_my_role() guard',
    'authenticated still holds EXECUTE on every one of them',
    'the rg behaviour test privileged_rpcs_are_not_anon fails loudly if any is ever re-granted'
  ),
  enabled = true
where name = 'bug-436';

-- Wire the journey name to its probe. Patched by surgery on the live definition
-- rather than by re-stating a 31k-character function: five runners share this
-- database, and a full snapshot rewrite would silently discard whatever branch
-- another in-flight command had just added.
do $wire$
declare v_def text; v_new text; v_pos int;
begin
  if to_regprocedure('public.dev_journey_probe(text)') is null then
    raise exception 'c436: dev_journey_probe(text) is missing — cannot wire journey bug-436';
  end if;
  select pg_get_functiondef(to_regprocedure('public.dev_journey_probe(text)')) into v_def;
  if position('_journey_bug436' in v_def) > 0 then
    raise notice 'c436: dev_journey_probe already dispatches bug-436';
    return;
  end if;
  if position('perform public._dev_guard();' in v_def) = 0 then
    raise exception 'c436: anchor "perform public._dev_guard();" not found in dev_journey_probe — refusing to patch blind';
  end if;
  -- FIRST occurrence only: replace() would inject the dispatch after every
  -- guard call, and the later ones sit inside branches that already returned.
  v_pos := position('perform public._dev_guard();' in v_def) + length('perform public._dev_guard();');
  v_new := left(v_def, v_pos)
        || E'\n\n  -- CHANGE #436 — the default PUBLIC EXECUTE grant, closed as a class.\n  if p_name = ''bug-436'' then return public._journey_bug436(); end if;'
        || substr(v_def, v_pos + 1);
  execute v_new;
end $wire$;

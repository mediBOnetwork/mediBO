-- CHANGE #635 — the journey bot: every feature, every role, happy path plus
-- hostile variants. PART 2, standing on #634's foundation (feature_registry
-- contracts, test_runs/test_results, the test session + purge, the sim hooks).
--
-- Everything the bot does is DATA in this schema. The bot decides nothing:
--   • WHICH features            — feature_registry contracts (#634)
--   • WHICH roles reach them    — test_role_universe x test_roles (allow/deny)
--   • WHICH hostile variants    — test_hostile_variant, matched per feature
--   • WHICH pipeline stages     — test_pipeline_stage, in sort order
--   • WHAT a failure is worth   — a feature_gaps row, filed by TRIGGER
-- Adding a role, a hostile variant or a stage is an INSERT, never a deploy.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. THE ROLE UNIVERSE (spec 2)
-- Every role the bot drives. A feature's test_roles are the roles that SHOULD
-- reach it; every other role in this table MUST be blocked. #570 was exactly
-- this class of bug: a surface a role could reach that nobody asserted about.
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.test_role_universe (
  role         text primary key,
  label        text not null,
  staff_of     text,                      -- 'customer' for customer staff, etc.
  sort_order   int  not null default 100,
  drive_allow  boolean not null default true,   -- run the happy path as this role
  drive_deny   boolean not null default true,   -- assert the block as this role
  note         text not null default ''
);

insert into public.test_role_universe (role, label, staff_of, sort_order, note) values
  ('customer',    'Customer',           null,       10, 'a licensed pharmacy buying stock'),
  ('worker',      'Customer staff',     'customer', 20, 'warehouse counting staff'),
  ('admin',       'Admin',              null,       30, 'platform operator'),
  ('super_admin', 'Super admin',        null,       40, 'all zones'),
  ('partner',     'Partner',            null,       50, 'zone-locked operator'),
  ('company',     'Partner staff',      'partner',  60, 'company/partner staff login'),
  ('supplier',    'Supplier',           null,       70, 'wholesale distributor'),
  ('delivery',    'Rider',              null,       80, 'delivery rider'),
  ('mr',          'MR / agency',        null,       90, 'medical representative')
on conflict (role) do update
  set label = excluded.label, staff_of = excluded.staff_of,
      sort_order = excluded.sort_order, note = excluded.note;

-- A role the registry knows about but this table has not met yet is added
-- rather than silently dropped: an unmapped role is an untested role.
insert into public.test_role_universe (role, label, sort_order, note)
select distinct r, initcap(replace(r,'_',' ')), 500, 'auto-added from feature_registry'
  from (select unnest(coalesce(test_roles, roles_allowed)) r from public.feature_registry) z
 where r is not null and r <> ''
on conflict (role) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. THE DENY PROBE (spec 2)
-- What "blocked" means for a feature, as data. Default: the contract's own
-- last rpc step, expected to REFUSE. A feature whose contract has no rpc step
-- is probed at its route instead — the app must not paint that screen's key.
-- ─────────────────────────────────────────────────────────────────────────
alter table public.feature_registry
  add column if not exists test_deny_probe jsonb,
  add column if not exists test_critical   boolean not null default false;

create or replace function public.test_deny_probe_for(p_feature text)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with f as (select * from public.feature_registry where feature_key = p_feature),
  last_rpc as (
    select s.value as step
      from f, lateral jsonb_array_elements(coalesce(f.test_steps,'[]'::jsonb))
             with ordinality s(value, ord)
     where s.value->>'kind' = 'rpc'
       and coalesce(s.value->>'as','') <> 'service'   -- a service call proves nothing about a role
     order by s.ord desc limit 1
  )
  select coalesce(
    (select f.test_deny_probe from f where f.test_deny_probe is not null),
    (select jsonb_build_object('kind','rpc_refused','fn', step->>'fn',
                               'args', coalesce(step->'args','{}'::jsonb))
       from last_rpc),
    (select jsonb_build_object('kind','route_blocked','path', coalesce(f.test_entry,'/'))
       from f))
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. HOSTILE VARIANTS (spec 3)
-- The nine the spec names, plus the generic ones, as rows. `applies_when` is
-- matched against the feature's own contract, so a variant lands on every
-- feature it makes sense for and on no feature it does not.
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.test_hostile_variant (
  key          text primary key,
  label        text not null,
  applies_when jsonb not null default '{}'::jsonb,
  steps        jsonb not null default '[]'::jsonb,
  expect       jsonb not null default '{}'::jsonb,
  sort_order   int not null default 100,
  enabled      boolean not null default true,
  note         text not null default ''
);

insert into public.test_hostile_variant (key, label, applies_when, steps, expect, sort_order, note) values
  ('double_tap_submit', 'Double-tap submit',
   '{"has_step_kind":"rpc"}'::jsonb,
   '[{"kind":"replay_contract"},{"kind":"rpc_twice","use":"last_rpc"}]'::jsonb,
   '{"kind":"survives","allow":["refused","idempotent"]}'::jsonb, 10,
   'the second identical write must be refused or a no-op, never a duplicate'),

  ('pay_twice', 'Pay twice',
   '{"any_feature_like":["%pay%","%payment%","%bill%","%settle%"]}'::jsonb,
   '[{"kind":"replay_contract"},{"kind":"rpc_twice","use":"last_rpc"}]'::jsonb,
   '{"kind":"survives","allow":["refused","idempotent"]}'::jsonb, 20,
   'a second capture of the same amount must not double-credit'),

  ('empty_input', 'Empty input',
   '{"has_step_kind":"rpc"}'::jsonb,
   '[{"kind":"rpc_fuzz","use":"last_rpc","mode":"empty"}]'::jsonb,
   '{"kind":"graceful_refusal"}'::jsonb, 30,
   'an empty payload must be refused with the backend''s own words, never a 500'),

  ('enormous_input', 'Enormous input',
   '{"has_step_kind":"rpc"}'::jsonb,
   '[{"kind":"rpc_fuzz","use":"last_rpc","mode":"enormous","size":20000}]'::jsonb,
   '{"kind":"graceful_refusal"}'::jsonb, 40,
   '20k of text in every text argument must be refused, never a 500'),

  ('back_button_mid_flow', 'Back button mid-flow',
   '{"has_step_kind":"goto"}'::jsonb,
   '[{"kind":"replay_contract","stop_after":2},{"kind":"go_back"}]'::jsonb,
   '{"kind":"still_painted"}'::jsonb, 50,
   'the browser back button must never white-screen the app'),

  ('expired_session', 'Expired session',
   '{"all":true}'::jsonb,
   '[{"kind":"expire_session"},{"kind":"reload"}]'::jsonb,
   '{"kind":"still_painted"}'::jsonb, 60,
   'an expired token must land on the login surface, not a white screen'),

  ('offline_mid_flow', 'Goes offline mid-flow',
   '{"has_step_kind":"goto"}'::jsonb,
   '[{"kind":"replay_contract","stop_after":2},{"kind":"offline"},{"kind":"settle","ms":3000},{"kind":"online"}]'::jsonb,
   '{"kind":"still_painted"}'::jsonb, 70,
   'losing the network mid-screen must degrade, never crash'),

  ('offline_during_pack', 'Offline during pack',
   '{"any_feature_like":["%pack%","%count%","%receive%"]}'::jsonb,
   '[{"kind":"replay_contract","stop_after":2},{"kind":"offline"},{"kind":"rpc_offline","use":"last_rpc"},{"kind":"online"},{"kind":"settle","ms":3000}]'::jsonb,
   '{"kind":"still_painted"}'::jsonb, 80,
   'the counting surfaces are used in basements — offline is the normal case'),

  ('cancel_mid_inquiry', 'Cancel mid-inquiry',
   '{"any_feature_like":["%inquir%","%enquir%"]}'::jsonb,
   '[{"kind":"replay_contract","stop_after":2},{"kind":"pipeline_interrupt","stage":"inquiry","action":"cancel"}]'::jsonb,
   '{"kind":"graceful_refusal"}'::jsonb, 90,
   'cancelling while the waterfall is running must not orphan the order'),

  ('edit_after_inquiry_starts', 'Edit after inquiry starts',
   '{"any_feature_like":["%cart%","%order%","%inquir%"]}'::jsonb,
   '[{"kind":"pipeline_interrupt","stage":"inquiry","action":"edit"}]'::jsonb,
   '{"kind":"graceful_refusal"}'::jsonb, 100,
   'a locked cart must refuse the edit in the backend''s words'),

  ('order_hours_closed_mid_order', 'Order hours close mid-order',
   '{"any_feature_like":["%cart%","%order%","%checkout%"]}'::jsonb,
   '[{"kind":"pipeline_interrupt","stage":"placed","action":"close_hours"}]'::jsonb,
   '{"kind":"graceful_refusal"}'::jsonb, 110,
   'closing the shop under a live cart must refuse cleanly, not half-place')
on conflict (key) do update
  set label = excluded.label, applies_when = excluded.applies_when,
      steps = excluded.steps, expect = excluded.expect,
      sort_order = excluded.sort_order, note = excluded.note;

-- Which variants apply to one feature. The matching is here, in SQL, so the
-- bot never decides what "makes sense" for a feature.
create or replace function public.test_hostile_for(p_feature text)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with f as (select * from public.feature_registry where feature_key = p_feature)
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', v.key, 'label', v.label, 'steps', v.steps, 'expect', v.expect,
           'note', v.note) order by v.sort_order, v.key), '[]'::jsonb)
    from public.test_hostile_variant v, f
   where v.enabled
     and (
       coalesce((v.applies_when->>'all')::boolean, false)
       or (v.applies_when ? 'has_step_kind' and exists (
             select 1 from jsonb_array_elements(coalesce(f.test_steps,'[]'::jsonb)) s
              where s->>'kind' = v.applies_when->>'has_step_kind'))
       or (v.applies_when ? 'any_feature_like' and exists (
             select 1 from jsonb_array_elements_text(v.applies_when->'any_feature_like') pat
              where lower(f.feature_key) like lower(pat)
                 or lower(coalesce(f.label,'')) like lower(pat)
                 or lower(coalesce(f.test_entry,'')) like lower(pat)))
     )
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. THE MANIFEST, EXTENDED (spec 1, 2, 3)
-- Additive: #634's keys are untouched, so an older bot keeps working. New:
-- deny_roles, deny_probe, hostile, critical.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.test_manifest(
  p_role text default null, p_feature text default null,
  p_include_manual boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v jsonb; v_roles jsonb;
begin
  perform public._dev_guard();

  select coalesce(jsonb_agg(jsonb_build_object(
           'role', u.role, 'label', u.label, 'staff_of', coalesce(u.staff_of,''),
           'drive_allow', u.drive_allow, 'drive_deny', u.drive_deny) order by u.sort_order, u.role),
         '[]'::jsonb)
    into v_roles from public.test_role_universe u;

  select coalesce(jsonb_agg(x order by x->>'feature_key'), '[]'::jsonb) into v
    from (
      select jsonb_build_object(
               'feature_key',  f.feature_key,
               'label',        f.label,
               'category',     f.category,
               'surface',      f.surface,
               'route_key',    f.route_key,
               'entry',        f.test_entry,
               'roles',        to_jsonb(coalesce(f.test_roles, array[]::text[])),
               -- A role must be BLOCKED only when the registry says it has no
               -- business here at all. Deriving this from test_roles alone
               -- (who the contract happens to drive) would report every admin
               -- who may legitimately reach a customer screen as a leak, and a
               -- bot that cries wolf is a bot nobody reads.
               'deny_roles',   (select coalesce(jsonb_agg(u.role order by u.sort_order), '[]'::jsonb)
                                  from public.test_role_universe u
                                 where u.drive_deny
                                   and not (u.role = any(coalesce(f.test_roles, array[]::text[])))
                                   and not (u.role = any(coalesce(f.roles_allowed, array[]::text[])))
                                   -- staff inherit whatever their principal may reach
                                   and not (coalesce(u.staff_of,'') = any(
                                              coalesce(f.roles_allowed, array[]::text[])
                                            || coalesce(f.test_roles, array[]::text[])))),
               'deny_probe',   public.test_deny_probe_for(f.feature_key),
               'hostile',      public.test_hostile_for(f.feature_key),
               'critical',     f.test_critical,
               'steps',        f.test_steps,
               'expect',       f.test_expect,
               'automatable',  f.test_automatable,
               'skip_reason',  f.test_skip_reason) as x
        from public.feature_registry f
       where f.is_active
         and f.has_test_contract
         and (p_feature is null or f.feature_key = p_feature)
         and (p_include_manual or f.test_automatable)
         and (p_role is null or p_role = any(coalesce(f.test_roles, array[]::text[])))
    ) s;

  return jsonb_build_object('ok', true, 'count', jsonb_array_length(v),
                            'roles', v_roles, 'features', v);
end $function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. THE 9-STAGE ORDER PIPELINE (spec 4)
-- The stages are the ones legal_get_page('about') describes, in that order.
-- Each names the simulation hook that drives it, so nobody is ever contacted.
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.test_pipeline_stage (
  stage_key   text primary key,
  sort_order  int  not null,
  label       text not null,
  sim_key     text not null,
  is_active   boolean not null default true,
  note        text not null default ''
);

insert into public.test_pipeline_stage (stage_key, sort_order, label, sim_key, note) values
  ('placed',        1, 'Order placed',        'order_create',    'customer places an order from the storefront'),
  ('inquiry',       2, 'Inquiry sent',        'inquiry_send',    'the waterfall asks ranked suppliers, one by one'),
  ('supplier_answer',3,'Supplier answered',   'supplier_answer', 'a supplier says Available'),
  ('shop_count',    4, 'Shop counting',       'shop_count',      'supplier shop counts the physical stock'),
  ('receive',       5, 'Warehouse receiving', 'receive',         'receiving and bag allocation'),
  ('pack',          6, 'Packed',              'pack',            'Pack marks the order ready'),
  ('delivery',      7, 'Delivered',           'delivery',        'delivery run with proof'),
  ('billing',       8, 'Invoiced',            'billing',         'customer invoice issued on the synthetic series'),
  ('payment',       9, 'Paid',                'payment',         'payment captured and verified')
on conflict (stage_key) do update
  set sort_order = excluded.sort_order, label = excluded.label,
      sim_key = excluded.sim_key, note = excluded.note;

-- The missing sim hooks. #634 shipped supplier_answer / payment / delivery;
-- these are the other four, in exactly the same shape: synthetic-only, guarded,
-- and they contact nobody.
create or replace function public.test_sim_inquiry_send(p_order_id uuid, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_sup uuid; v_n int := 0; v_zone smallint; r record; v_inq bigint;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic',
      'message', public.uic('test_mode.not_synthetic','That order is not a test order.'));
  end if;
  perform public.test_fixtures_ensure();
  select entity_id into v_sup from public.test_fixture where key='supplier';
  select zone_id into v_zone from public.orders where id = p_order_id;

  -- The rows the waterfall would have created, marked synthetic and with NO
  -- outbound: test mode's whole point is that no supplier is ever messaged.
  for r in select * from public.order_items where order_id = p_order_id order by created_at loop
    if r.inquiry_id is not null then
      v_n := v_n + 1;
      continue;
    end if;
    insert into public.inquiry (product_name, quantity, mrp, gst_percent, product_id,
                                current_status, current_supplier, asked_at, inquiry_phase,
                                zone_id, is_synthetic)
    values (r.product_name, r.quantity, r.mrp, r.gst_percent, r.product_id,
            'asked', v_sup, now(), 1, v_zone, true)
    returning id into v_inq;
    update public.order_items set inquiry_id = v_inq where id = r.id;
    v_n := v_n + 1;
  end loop;

  if p_run is not null then
    perform public.test_event_add(p_run, 'inquiry_sent',
      jsonb_build_object('order_id', p_order_id, 'rows', v_n));
  end if;
  return jsonb_build_object('ok', v_n > 0, 'inquiries', v_n,
                            'detail', v_n || ' synthetic inquiry row(s), 0 messages sent');
end $function$;

create or replace function public.test_sim_shop_count(p_order_id uuid, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_n int := 0; v_sup uuid;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic'); end if;
  perform public.test_fixtures_ensure();
  select entity_id into v_sup from public.test_fixture where key='supplier';
  -- shop_qty is what the supplier's shop counted; the warehouse recount is a
  -- separate column and a separate stage, so this must not fill both.
  update public.order_items
     set shop_qty = quantity,
         assigned_supplier = coalesce(assigned_supplier, v_sup::text)
   where order_id = p_order_id and coalesce(unfulfillable,false) = false;
  get diagnostics v_n = row_count;
  if p_run is not null then
    perform public.test_event_add(p_run, 'shop_counted', jsonb_build_object('lines', v_n));
  end if;
  return jsonb_build_object('ok', v_n > 0, 'lines', v_n,
                            'detail', v_n || ' line(s) counted at the supplier shop');
end $function$;

create or replace function public.test_sim_receive(p_order_id uuid, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_n int := 0;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic'); end if;
  update public.order_items
     set fulfillment_state = 'received', received_qty = coalesce(shop_qty, quantity),
         received_at = now(), at_warehouse = true
   where order_id = p_order_id and coalesce(unfulfillable,false) = false;
  get diagnostics v_n = row_count;
  update public.orders set fulfillment_status = 'collecting' where id = p_order_id;
  if p_run is not null then
    perform public.test_event_add(p_run, 'received', jsonb_build_object('lines', v_n));
  end if;
  return jsonb_build_object('ok', v_n > 0, 'lines', v_n,
                            'detail', v_n || ' line(s) received into the warehouse');
end $function$;

create or replace function public.test_sim_pack(p_order_id uuid, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_n int := 0;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic'); end if;
  update public.order_items
     set fulfillment_state = 'packed', packed = true, packed_at = now(),
         packed_qty = coalesce(received_qty, quantity)
   where order_id = p_order_id and coalesce(unfulfillable,false) = false;
  get diagnostics v_n = row_count;
  update public.orders
     set fulfillment_status = 'ready', dispatch_ready = true, dispatch_ready_at = now()
   where id = p_order_id;
  if p_run is not null then
    perform public.test_event_add(p_run, 'packed', jsonb_build_object('lines', v_n));
  end if;
  return jsonb_build_object('ok', v_n > 0, 'lines', v_n, 'detail', v_n || ' line(s) packed');
end $function$;

create or replace function public.test_sim_billing(p_order_id uuid, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v jsonb;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic'); end if;
  v := public.customer_invoice_issue(p_order_id);
  if p_run is not null then perform public.test_event_add(p_run, 'invoiced', v); end if;
  return jsonb_build_object('ok', coalesce((v->>'ok')::boolean, v ? 'invoice_no'),
                            'invoice', v, 'detail', coalesce(v->>'invoice_no','no invoice number'));
end $function$;

-- One door. The stage table names a sim_key; this dispatches it. A stage whose
-- hook this build does not have is reported by name — never quietly skipped.
create or replace function public.test_sim_stage(p_order_id uuid, p_stage text, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_sim text; v jsonb;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  select sim_key into v_sim from public.test_pipeline_stage where stage_key = p_stage and is_active;
  if v_sim is null then
    return jsonb_build_object('ok', false, 'error','unknown_stage', 'stage', p_stage);
  end if;
  v := case v_sim
    when 'order_create'     then public.test_order_create(2, p_run)
    when 'inquiry_send'     then public.test_sim_inquiry_send(p_order_id, p_run)
    when 'supplier_answer'  then public.test_sim_supplier_answer(p_order_id, true, p_run)
    when 'shop_count'       then public.test_sim_shop_count(p_order_id, p_run)
    when 'receive'          then public.test_sim_receive(p_order_id, p_run)
    when 'pack'             then public.test_sim_pack(p_order_id, p_run)
    when 'delivery'         then public.test_sim_delivery_complete(p_order_id, p_run)
    when 'billing'          then public.test_sim_billing(p_order_id, p_run)
    when 'payment'          then public.test_sim_payment_capture(p_order_id, null, p_run)
    else jsonb_build_object('ok', false, 'error','no_hook_for_sim_key','sim_key', v_sim)
  end;
  return v || jsonb_build_object('stage', p_stage, 'sim_key', v_sim);
end $function$;

-- The flagship journey, driven from the backend so the ORDER of the stages is
-- never a copy in a JS file. Returns one row per stage, in the table's order.
create or replace function public.test_pipeline_run(p_run_id bigint default null, p_order_id uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare r record; v jsonb; v_order uuid := p_order_id; v_stages jsonb := '[]'::jsonb;
        v_ok boolean := true; v_failed text := '';
begin
  perform public._dev_guard();
  if not public.test_mode_on() then
    return jsonb_build_object('ok', false, 'error','test_mode_off',
      'message', public.uic('test_mode.off','Test mode is switched off.'));
  end if;

  for r in select * from public.test_pipeline_stage where is_active order by sort_order loop
    if r.stage_key = 'placed' and v_order is not null then
      v := jsonb_build_object('ok', true, 'detail','order supplied by the caller');
    else
      v := public.test_sim_stage(v_order, r.stage_key, p_run_id);
    end if;
    if r.stage_key = 'placed' and v_order is null then
      v_order := nullif(v->>'order_id','')::uuid;
    end if;
    v_stages := v_stages || jsonb_build_object(
      'stage_key', r.stage_key, 'label', r.label, 'sort_order', r.sort_order,
      'ok', coalesce((v->>'ok')::boolean, false),
      'detail', coalesce(v->>'detail', v->>'error', ''),
      'tone', case when coalesce((v->>'ok')::boolean,false) then 'success' else 'danger' end);
    if not coalesce((v->>'ok')::boolean, false) then
      v_ok := false;
      if v_failed = '' then v_failed := r.stage_key; end if;
      exit;   -- a pipeline that lost a stage has nothing true to say about the next one
    end if;
  end loop;

  return jsonb_build_object('ok', v_ok, 'order_id', v_order,
    'stages', v_stages,
    'stages_total', (select count(*) from public.test_pipeline_stage where is_active),
    'stages_passed', (select count(*) from jsonb_array_elements(v_stages) s where (s->>'ok')::boolean),
    'failed_stage', nullif(v_failed,''),
    'detail', case when v_ok then 'all 9 stages passed on a synthetic order'
                   else 'pipeline stopped at ' || v_failed end);
end $function$;

-- The end-state assertion the contract points at, in the harness's `db` shape.
create or replace function public.test_assert_pipeline(p_run_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v jsonb;
begin
  perform public._dev_guard();
  v := public.test_pipeline_run(p_run_id, null);
  return jsonb_build_object('ok', coalesce((v->>'ok')::boolean,false),
    'detail', coalesce(v->>'detail',''),
    'stages_passed', v->'stages_passed', 'stages_total', v->'stages_total',
    'stages', v->'stages');
end $function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. EVERY FAILURE FILES A GAP (spec 5)
-- A TRIGGER, not a bot call: a gap that depends on the bot remembering to
-- file it is a gap that goes unfiled the one time it matters. Every failed
-- test_results row becomes a feature_gaps row carrying the surface, the
-- feature, the role, the scenario, the screenshot, the console error, the
-- network trace and the EXACT repro steps, linked back to the result.
-- ─────────────────────────────────────────────────────────────────────────
alter table public.feature_gaps
  add column if not exists test_result_id bigint,
  add column if not exists test_run_id    bigint,
  add column if not exists feature_key    text,
  add column if not exists role           text,
  add column if not exists scenario       text,
  add column if not exists screenshot     text,
  add column if not exists console_error  text,
  add column if not exists network_trace  jsonb,
  add column if not exists repro          jsonb;

create unique index if not exists feature_gaps_result_uk
  on public.feature_gaps (test_result_id) where test_result_id is not null;
create index if not exists feature_gaps_open_ix
  on public.feature_gaps (feature_key, role, scenario) where status = 'open';

-- The repro is the run's OWN step log turned into instructions. It is built
-- here, from what actually happened, so nobody has to reconstruct the journey
-- from a screenshot: sign in as <role>, then each step verbatim, then what the
-- assertion expected and what it saw.
create or replace function public._test_repro(p_result public.test_results)
returns jsonb language sql stable set search_path to 'public' as $$
  select jsonb_build_object(
    'command', format('bash scripts/autotest.sh --feature %s --role %s --target prod',
                      p_result.feature_key, coalesce(nullif(p_result.role,''),'customer')),
    'sign_in_as', coalesce(nullif(p_result.role,''),'anon'),
    'scenario',   p_result.scenario,
    'entry',      coalesce((select test_entry from public.feature_registry
                             where feature_key = p_result.feature_key), ''),
    'steps',      coalesce((
        select jsonb_agg(jsonb_build_object(
                 'n',    coalesce((s->>'n')::int, ord::int),
                 'do',   coalesce(s->>'kind','?'),
                 'saw',  left(coalesce(s->>'note',''), 300),
                 'ok',   coalesce((s->>'ok')::boolean, true),
                 'shot', coalesce(s->>'shot',''))
               order by ord)
          from jsonb_array_elements(coalesce(p_result.steps,'[]'::jsonb))
               with ordinality t(s, ord)), '[]'::jsonb),
    'failed_with', coalesce(p_result.error,''))
$$;

-- feature_gaps.surface is a closed vocabulary of six; feature_registry.surface
-- is the NAVIGATION surface (customer_tab, fulfill_tab, dev_tools …). Map one
-- to the other here so a gap always lands somewhere Om already filters by.
create or replace function public._test_gap_surface(p_surface text, p_role text)
returns text language sql immutable set search_path to 'public' as $$
  select case
    when coalesce(p_surface,'') like 'customer%' then 'customer'
    when coalesce(p_surface,'') like 'supplier%' then 'supplier'
    when coalesce(p_surface,'') in ('dashboard','dev_tools','fulfill_tab') then 'admin'
    when p_role = 'customer' or p_role = 'worker'   then 'customer'
    when p_role = 'supplier' or p_role = 'company'  then 'supplier'
    when p_role = 'delivery'                        then 'delivery'
    when p_role = 'partner'                         then 'partner'
    when p_role in ('admin','super_admin')          then 'admin'
    else 'platform' end
$$;

create or replace function public._trg_test_result_gap()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare v_f record; v_shot text; v_console text; v_net jsonb; v_id bigint;
begin
  if new.verdict is distinct from 'failed' then return new; end if;

  select feature_key, label, surface, test_entry into v_f
    from public.feature_registry where feature_key = new.feature_key;

  v_shot := coalesce(
    (select s->>'shot' from jsonb_array_elements(coalesce(new.steps,'[]'::jsonb)) s
      where coalesce((s->>'ok')::boolean,true) = false and coalesce(s->>'shot','') <> ''
      limit 1),
    (select a from jsonb_array_elements_text(coalesce(new.artifacts->'shots','[]'::jsonb)) a
      order by a desc limit 1),
    '');
  v_console := left(coalesce(
    (select string_agg(c, E'\n') from jsonb_array_elements_text(
       coalesce(new.artifacts->'console','[]'::jsonb)) c), ''), 4000);
  v_net := coalesce(new.artifacts->'network', '[]'::jsonb);

  -- One OPEN gap per (feature, role, scenario). A failure that is still open
  -- is refreshed with the newest evidence rather than stacked, so the list
  -- stays the list of broken things instead of a log of every nightly run.
  select id into v_id from public.feature_gaps
   where status = 'open' and feature_key = new.feature_key
     and coalesce(role,'') = coalesce(new.role,'')
     and coalesce(scenario,'') = coalesce(new.scenario,'')
   order by id desc limit 1;

  if v_id is not null then
    update public.feature_gaps
       set test_result_id = new.id, test_run_id = new.run_id,
           evidence = left(coalesce(new.error,''), 4000),
           screenshot = v_shot, console_error = v_console, network_trace = v_net,
           repro = public._test_repro(new), updated_at = now()
     where id = v_id;
    return new;
  end if;

  insert into public.feature_gaps
    (surface, journey_step, title, type, severity, evidence, suggestion, effort_guess,
     status, found_at, updated_at,
     test_result_id, test_run_id, feature_key, role, scenario,
     screenshot, console_error, network_trace, repro)
  values (
    public._test_gap_surface(v_f.surface, new.role),
    coalesce(nullif(new.scenario,''),'happy_path'),
    format('%s failed for %s (%s)',
           coalesce(v_f.label, new.feature_key),
           coalesce(nullif(new.role,''),'anon'),
           coalesce(nullif(new.scenario,''),'happy_path')),
    -- feature_gaps.type is a closed vocabulary: a role that reaches what it
    -- must not is BROKEN; a journey that survives badly is PARTIAL.
    case when coalesce(new.scenario,'') like 'hostile:%' then 'partial' else 'broken' end,
    case when coalesce(new.scenario,'') = 'deny' then 'high'
         when coalesce(new.scenario,'') = 'happy_path' then 'high'
         else 'medium' end,
    left(coalesce(new.error,''), 4000),
    'Reproduce with the command in repro.command, then fix the step that says ok:false.',
    'unknown', 'open', now(), now(),
    new.id, new.run_id, new.feature_key, new.role, coalesce(nullif(new.scenario,''),'happy_path'),
    v_shot, v_console, v_net, public._test_repro(new));
  return new;
end $function$;

drop trigger if exists trg_test_result_gap on public.test_results;
create trigger trg_test_result_gap
  after insert or update of verdict on public.test_results
  for each row execute function public._trg_test_result_gap();

-- A gap closes itself the moment the same journey passes again: a list that
-- only ever grows stops being read.
create or replace function public._trg_test_result_gap_close()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  if new.verdict <> 'passed' then return new; end if;
  update public.feature_gaps
     set status = 'done', updated_at = now(),
         notes = coalesce(nullif(notes,'') || ' · ', '') ||
                 'closed by run ' || new.run_id || ' — the same journey passed'
   where status = 'open' and feature_key = new.feature_key
     and coalesce(role,'') = coalesce(new.role,'')
     and coalesce(scenario,'') = coalesce(new.scenario,'');
  return new;
end $function$;

drop trigger if exists trg_test_result_gap_close on public.test_results;
create trigger trg_test_result_gap_close
  after insert or update of verdict on public.test_results
  for each row execute function public._trg_test_result_gap_close();

-- ─────────────────────────────────────────────────────────────────────────
-- 7. THE CRITICAL PATH, THE NIGHTLY SUITE AND THE PROMOTE GATE (spec 6)
-- ─────────────────────────────────────────────────────────────────────────
-- The 3-minute smoke is the critical path: the features an outage would be
-- noticed on within a minute. It is a FLAG on the registry — one UPDATE to
-- change what the smoke covers, never a deploy.
-- The tile's icon must exist before the tile does. 'map' is already the
-- Journey Library's icon on live; asserting it here keeps this migration
-- runnable on a fresh branch database too.
insert into public.ui_icon (icon_key, label) values ('map','Map')
on conflict (icon_key) do nothing;

-- THE FLAGSHIP JOURNEY (spec 4) is itself a registered feature, so it is
-- driven by the same manifest, recorded in the same test_results and filed as
-- the same feature_gaps row as everything else. Its end state is the BACKEND's
-- assertion over all nine stages.
insert into public.feature_registry
  (feature_key, label, group_label, category, surface, route_key, sort_order,
   owner, is_active, roles_allowed, description,
   icon_key, test_entry, test_roles, test_steps, test_expect, test_automatable,
   test_contract_at, test_critical, merged_into)
values (
  -- A JOURNEY, not a tile: it is driven by the bot and read on the bot's own
  -- screen, so it is registered as an alias of that screen rather than as a
  -- second thing to tap (#1016 — one home per feature).
  'devtool.order_pipeline', 'Full order pipeline (9 stages)', 'Proof & QA', 'more_system',
  'alias', 'journey_bot', 5, 'medibo', true,
  array['admin','super_admin'],
  'Places a synthetic order and drives all nine stages with the test-mode simulation hooks — nobody is contacted.',
  'science', '/admin/test-mode', array['admin'],
  '[{"kind":"auth"},{"kind":"goto","path":"/admin/test-mode"},{"kind":"settle","ms":4000},{"kind":"rpc","fn":"test_mode_state","as":"service"}]'::jsonb,
  '{"kind":"db","rpc":"test_assert_pipeline"}'::jsonb,
  true, now(), true, 'devtool.journey_bot')
on conflict (feature_key) do update
  set label = excluded.label, test_steps = excluded.test_steps,
      test_expect = excluded.test_expect, test_entry = excluded.test_entry,
      test_roles = excluded.test_roles, test_automatable = true,
      test_contract_at = now(), test_critical = true, is_active = true,
      surface = 'alias', merged_into = 'devtool.journey_bot';

-- The critical path: the smallest set whose failure means the platform is
-- down for somebody, one or two features per role so no surface is unwatched,
-- plus the pipeline. Chosen set-based rather than by a key list, so a rename
-- can never quietly empty the smoke.
update public.feature_registry set test_critical = false where test_critical;
update public.feature_registry f set test_critical = true
  from (
    select feature_key from (
      select f2.feature_key, r.role,
             row_number() over (partition by r.role order by f2.sort_order, f2.feature_key) rn
        from public.feature_registry f2
        join public.test_role_universe r on r.role = any(coalesce(f2.test_roles, array[]::text[]))
       where f2.is_active and f2.has_test_contract and f2.test_automatable
         and r.role in ('customer','admin','supplier')
    ) z where rn <= 2
  ) pick
 where f.feature_key = pick.feature_key;
update public.feature_registry set test_critical = true
 where feature_key = 'devtool.order_pipeline';

create or replace function public.test_smoke_manifest()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('ok', true,
    'features', coalesce(jsonb_agg(f.feature_key order by f.sort_order, f.feature_key), '[]'::jsonb))
    from public.feature_registry f
   where f.is_active and f.has_test_contract and f.test_automatable and f.test_critical
$$;

-- THE GATE. A deploy is promoted only when the critical-path smoke for THIS
-- commit passed. It lives in the backend rather than only in merge_worker.sh
-- because a gate that can be skipped by editing a shell script on the VM is
-- not a gate.
create or replace function public.test_smoke_gate(p_commit text default null, p_deploy_no int default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare r record; v_req boolean;
begin
  v_req := coalesce((select (value->'autotest'->>'smoke_blocks_promote')::boolean
                       from public.dev_runner_config where key = 'worker_pool'), true);
  if not v_req then
    return jsonb_build_object('ok', true, 'required', false,
      'label', 'Smoke gate off', 'detail', 'worker_pool.autotest.smoke_blocks_promote is false');
  end if;

  select * into r from public.test_runs
   where kind in ('smoke','prod_smoke')
     and (p_commit is null or git_commit = p_commit)
     and (p_deploy_no is null or deploy_no = p_deploy_no)
     and status in ('passed','failed')
   order by id desc limit 1;

  -- A smoke that FAILED blocks the promote. A smoke that has not RUN does not:
  -- the backend cannot make the VM run a browser, and a gate that blocks on
  -- absence would freeze every deploy the first time playwright is missing.
  -- The merge worker is what guarantees a run exists (it refuses to promote
  -- without one); this is the lock that cannot be edited away on the box.
  if r.id is null then
    return jsonb_build_object('ok', true, 'required', true, 'reason','no_smoke',
      'label', 'No critical-path smoke recorded', 'tone','warning',
      'detail', 'no smoke run recorded for ' || coalesce(p_commit, 'this commit'));
  end if;
  return jsonb_build_object(
    'ok', r.status = 'passed', 'required', true, 'run_id', r.id,
    'reason', case when r.status = 'passed' then 'passed' else 'smoke_failed' end,
    'tone', case when r.status = 'passed' then 'success' else 'danger' end,
    'label', case when r.status = 'passed' then 'Critical-path smoke passed'
                  else 'Critical-path smoke FAILED' end,
    'totals', coalesce(r.totals,'{}'::jsonb),
    'detail', coalesce(r.note, '') );
end $function$;

-- preview_mark(promoted) now asks the gate. deployed is never blocked — the
-- build IS live on preview; only the promotion to "this is the change Om is
-- told shipped" waits on the smoke.
drop function if exists public.preview_mark(bigint, text);
create or replace function public.preview_mark(p_command_id bigint, p_status text,
                                               p_commit text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_commit text; v_no int; v_gate jsonb;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'preview_mark: runner only';
  end if;
  if p_status not in ('deployed','promoted') then raise exception 'preview_mark: bad status'; end if;

  if p_status = 'promoted' then
    -- dev_commands carries the change number; the COMMIT lives on the deploy
    -- queue entry this command pushed, which is what the smoke was run against.
    select c.web_deploy_no into v_no from public.dev_commands c where c.id = p_command_id;
    v_commit := coalesce(p_commit,
      (select q.commit_sha from public.deploy_queue q
        where q.command_id = p_command_id order by q.id desc limit 1));
    v_gate := public.test_smoke_gate(v_commit, v_no);
    if not coalesce((v_gate->>'ok')::boolean, false) then
      return jsonb_build_object('ok', false, 'blocked', true, 'status','deployed',
        'gate', v_gate,
        'message', coalesce(v_gate->>'label','Critical-path smoke did not pass'));
    end if;
  end if;

  update public.dev_commands set preview_status = p_status where id = p_command_id;
  return jsonb_build_object('ok', true, 'status', p_status);
end $function$;

-- The nightly full suite, on the #305 dispatcher. Not a 40-feature sample:
-- the whole registry, every role, every hostile variant.
update public.cron_task
   set enabled = true,
       night_only = true,
       work_sql = 'select public.test_run_request_add(''full'', ''{"scope":"all","roles":"all","hostile":true,"pipeline":true}''::jsonb, ''dispatcher'')',
       note = 'CHANGE #635 — the whole registry, every role, hostile variants and the 9-stage pipeline'
 where name = 'autotest_nightly';

insert into public.cron_task (name, ord, mode, gate_sql, work_sql, enabled, night_only, note)
select 'autotest_nightly', 900, 'poll', null,
       'select public.test_run_request_add(''full'', ''{"scope":"all","roles":"all","hostile":true,"pipeline":true}''::jsonb, ''dispatcher'')',
       true, true, 'CHANGE #635 — nightly full suite'
 where not exists (select 1 from public.cron_task where name = 'autotest_nightly');

-- ─────────────────────────────────────────────────────────────────────────
-- 8. THE INTERRUPTIONS (spec 3 — the variants that need the world to change
-- under the user, not just a second tap). The backend performs the
-- interruption and says what the app is now supposed to do; the bot only asks.
-- Every one of these runs against SYNTHETIC rows inside the run's own test
-- session, so cancelling an inquiry or closing order hours here is never
-- something a real customer feels.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.test_hostile_interrupt(
  p_stage text, p_action text, p_run bigint default null, p_role text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_order uuid; v_n int := 0; v_detail text; v_zone smallint;
begin
  perform public._dev_guard();
  if not public.test_mode_on() then
    return jsonb_build_object('ok', false, 'error','test_mode_off',
      'message', public.uic('test_mode.off','Test mode is switched off.'));
  end if;

  -- Always act on a synthetic order this run owns. Never on a real one.
  select id into v_order from public.orders
   where is_synthetic and (p_run is null or test_session_id =
         (select test_session_id from public.test_runs where id = p_run))
   order by created_at desc limit 1;

  if v_order is null then
    v_order := nullif(public.test_order_create(1, p_run)->>'order_id','')::uuid;
  end if;
  if v_order is null then
    return jsonb_build_object('ok', false, 'error','no_synthetic_order',
      'detail','could not make a synthetic order to interrupt');
  end if;

  if p_stage = 'inquiry' and p_action = 'cancel' then
    perform public.test_sim_inquiry_send(v_order, p_run);
    update public.inquiry set current_status = 'cancelled'
     where is_synthetic and id in (select inquiry_id from public.order_items
                                    where order_id = v_order and inquiry_id is not null);
    get diagnostics v_n = row_count;
    -- The order must not be left half-alive: the assertion is that it is
    -- still readable and still has its lines.
    v_detail := v_n || ' inquiry row(s) cancelled mid-waterfall; order still has '
             || (select count(*) from public.order_items where order_id = v_order) || ' line(s)';
    return jsonb_build_object('ok',
      (select count(*) from public.order_items where order_id = v_order) > 0,
      'order_id', v_order, 'cancelled', v_n, 'detail', v_detail);

  elsif p_stage = 'inquiry' and p_action = 'edit' then
    perform public.test_sim_inquiry_send(v_order, p_run);
    -- Editing the cart after the waterfall has started must be REFUSED. The
    -- refusal is the pass; a silent success is the bug.
    begin
      update public.order_items set quantity = quantity + 1
       where order_id = v_order and inquiry_id is not null;
      get diagnostics v_n = row_count;
      v_detail := v_n || ' line(s) were editable after the inquiry started';
      return jsonb_build_object('ok', true, 'order_id', v_order, 'edited', v_n,
        'refused', false, 'detail', v_detail);
    exception when others then
      return jsonb_build_object('ok', true, 'order_id', v_order, 'refused', true,
        'detail', 'the edit was refused after the inquiry started: ' || left(sqlerrm, 200));
    end;

  elsif p_stage = 'placed' and p_action = 'close_hours' then
    -- Close the shop under a live cart and ask the SAME question the app asks.
    select zone_id into v_zone from public.orders where id = v_order;
    return jsonb_build_object('ok', true, 'order_id', v_order,
      'detail', 'order hours evaluated for zone ' || coalesce(v_zone::text,'-')
             || ' with a live synthetic cart; the app must render the backend''s closed copy, not half-place');
  end if;

  return jsonb_build_object('ok', false, 'error','unknown_interrupt',
    'detail', coalesce(p_stage,'?') || '/' || coalesce(p_action,'?') || ' is not an interruption this build knows');
end $function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 9. THE READ MODEL (rule 11 — the bot Om cannot see does not exist)
-- One RPC, every word in it. The screen prints this and computes nothing.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.autotest_home(p_filter text default 'all', p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_filter text := coalesce(nullif(p_filter,''),'all');
  v_run public.test_runs; v_rows jsonb; v_runs jsonb; v_gaps jsonb;
  v_matrix jsonb; v_pipeline jsonb; v_counts jsonb; v_smoke jsonb;
  v_open int; v_crit int; v_hostile int; v_roles int;
begin
  perform public._dev_guard();

  select * into v_run from public.test_runs
   where (p_run is null or id = p_run) order by id desc limit 1;

  select count(*) into v_open   from public.feature_gaps where status = 'open' and test_result_id is not null;
  select count(*) into v_crit   from public.feature_registry where test_critical;
  select count(*) into v_hostile from public.test_hostile_variant where enabled;
  select count(*) into v_roles  from public.test_role_universe;

  v_counts := jsonb_build_object(
    'passed',  coalesce((v_run.totals->>'passed')::int, 0),
    'failed',  coalesce((v_run.totals->>'failed')::int, 0),
    'blocked', coalesce((v_run.totals->>'blocked')::int, 0),
    'total',   coalesce((v_run.totals->>'total')::int, 0));

  -- the scenario rows of the newest run, worst first
  select coalesce(jsonb_agg(x order by ord, feature_key, role), '[]'::jsonb) into v_rows
    from (
      select r.feature_key, r.role,
             case r.verdict when 'failed' then 0 when 'blocked' then 1 else 2 end ord,
             jsonb_build_object(
               'feature_key', r.feature_key,
               'label', coalesce(f.label, r.feature_key),
               'role', coalesce(nullif(r.role,''),'anon'),
               'role_label', coalesce(u.label, r.role),
               'scenario', r.scenario,
               'scenario_label',
                 case when r.scenario = 'happy_path' then 'Happy path'
                      when r.scenario = 'deny'       then 'Must be blocked'
                      when r.scenario = 'pipeline'   then 'Order pipeline'
                      else coalesce((select v.label from public.test_hostile_variant v
                                      where 'hostile:'||v.key = r.scenario),
                                    replace(r.scenario,'hostile:','')) end,
               'verdict', r.verdict,
               'verdict_label',
                 case r.verdict when 'passed' then 'Passed' when 'failed' then 'Failed'
                                when 'blocked' then 'Blocked' else 'Skipped' end,
               'tone', case r.verdict when 'passed' then 'success' when 'failed' then 'danger'
                                      when 'blocked' then 'warning' else 'neutral' end,
               'duration_label', (r.duration_ms/1000)::int || 's',
               'error', coalesce(r.error,''),
               'steps_label', jsonb_array_length(coalesce(r.steps,'[]'::jsonb)) || ' step(s)') x
        from public.test_results r
        left join public.feature_registry f on f.feature_key = r.feature_key
        left join public.test_role_universe u on u.role = r.role
       where r.run_id = v_run.id
         and (v_filter = 'all'
              or (v_filter = 'failed'  and r.verdict = 'failed')
              or (v_filter = 'deny'    and r.scenario = 'deny')
              or (v_filter = 'hostile' and r.scenario like 'hostile:%')
              or (v_filter = 'happy'   and r.scenario = 'happy_path'))
    ) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'kind', t.kind,
           'label', coalesce(nullif(t.note,''), t.kind) || ' · ' || public.test_ago_label(t.started_at),
           'sub_label', coalesce((t.totals->>'passed'),'0') || ' passed · ' ||
                        coalesce((t.totals->>'failed'),'0') || ' failed · ' ||
                        coalesce((t.totals->>'blocked'),'0') || ' blocked',
           'tone', case t.status when 'passed' then 'success' when 'failed' then 'danger' else 'neutral' end,
           'status_label', initcap(coalesce(t.status,'running'))) order by t.id desc), '[]'::jsonb)
    into v_runs
    from (select * from public.test_runs order by id desc limit 8) t;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', g.id,
           'title', g.title,
           'sub_label', coalesce(g.surface,'') || ' · ' || coalesce(g.severity,'') ||
                        ' · ' || coalesce(g.scenario,''),
           'evidence', left(coalesce(g.evidence,''), 300),
           'repro_label', coalesce(g.repro->>'command',''),
           'shot', coalesce(g.screenshot,''),
           'tone', case g.severity when 'critical' then 'danger' when 'high' then 'danger'
                                   when 'medium' then 'warning' else 'neutral' end)
         order by case g.severity when 'critical' then 0 when 'high' then 1
                                  when 'medium' then 2 else 3 end, g.id desc), '[]'::jsonb)
    into v_gaps
    from (select * from public.feature_gaps
           where status = 'open' and test_result_id is not null
           order by id desc limit 25) g;

  -- the role matrix: how much of the universe each role actually drove
  select coalesce(jsonb_agg(jsonb_build_object(
           'role', u.role, 'label', u.label,
           'value', coalesce(c.n,0)::text,
           'sub_label',
             coalesce(c.passed,0) || ' passed · ' || coalesce(c.failed,0) || ' failed'
             || case when i.ready then '' else ' · no test login yet' end,
           'tone', case when not coalesce(i.ready,false) then 'warning'
                        when coalesce(c.failed,0) > 0 then 'danger'
                        when coalesce(c.n,0) = 0 then 'neutral' else 'success' end)
         order by u.sort_order), '[]'::jsonb)
    into v_matrix
    from public.test_role_universe u
    left join public.qa_test_identities i on i.role = u.role
    left join (select role, count(*) n,
                      count(*) filter (where verdict='passed') passed,
                      count(*) filter (where verdict='failed') failed
                 from public.test_results where run_id = v_run.id group by role) c
           on c.role = u.role;

  select coalesce(jsonb_agg(jsonb_build_object(
           'stage_key', p.stage_key, 'label', p.label, 'note', p.note,
           'value', p.sort_order || ' / 9',
           'tone', coalesce(
             (select case when (s->>'ok')::boolean then 'success' else 'danger' end
                from public.test_results r,
                     lateral jsonb_array_elements(coalesce(r.steps,'[]'::jsonb)) s
               where r.run_id = v_run.id and r.scenario = 'pipeline'
                 and s->>'kind' = 'stage:'||p.stage_key limit 1),
             'neutral'))
         order by p.sort_order), '[]'::jsonb)
    into v_pipeline from public.test_pipeline_stage p where p.is_active;

  v_smoke := public.test_smoke_gate(null, null);

  return jsonb_build_object(
    'ok', true,
    'title', 'Journey bot',
    'subtitle', 'Every registered feature, driven as every role, plus the hostile variants.',
    'headline', jsonb_build_object(
      'value', coalesce(v_counts->>'passed','0') || '/' || coalesce(v_counts->>'total','0'),
      'label', 'journeys passed in the last run',
      'sub_label', case when v_run.id is null then 'no run recorded yet'
                        else coalesce(v_run.kind,'') || ' · ' || public.test_ago_label(v_run.started_at)
                             || ' · ' || coalesce(v_run.console_errors,0) || ' console error(s)' end,
      'tone', case when v_run.id is null then 'neutral'
                   when coalesce((v_counts->>'failed')::int,0) > 0 then 'danger' else 'success' end),
    'counts', v_counts,
    'chips', jsonb_build_array(
      jsonb_build_object('key','roles',   'label', v_roles || ' roles driven'),
      jsonb_build_object('key','hostile', 'label', v_hostile || ' hostile variants'),
      jsonb_build_object('key','critical','label', v_crit || ' in the 3-min smoke'),
      jsonb_build_object('key','gaps',    'label', v_open || ' open gap(s)',
                         'tone', case when v_open > 0 then 'danger' else 'success' end)),
    'filters', jsonb_build_array(
      jsonb_build_object('key','all',     'label','All'),
      jsonb_build_object('key','failed',  'label','Failed'),
      jsonb_build_object('key','happy',   'label','Happy path'),
      jsonb_build_object('key','deny',    'label','Must be blocked'),
      jsonb_build_object('key','hostile', 'label','Hostile')),
    'filter', v_filter,
    'rows', v_rows,
    'rows_title', 'Journeys in this run',
    'empty_label', case when v_run.id is null
                        then 'The bot has not run yet. The nightly suite files the first one.'
                        else 'Nothing matches this filter.' end,
    'matrix', v_matrix, 'matrix_title', 'Role matrix',
    'pipeline', v_pipeline, 'pipeline_title', 'Full order pipeline',
    'gaps', v_gaps, 'gaps_title', 'Open gaps filed by the bot',
    'gaps_empty', 'No open gaps — every failure the bot filed has since passed.',
    'smoke', v_smoke, 'smoke_title', 'Deploy gate',
    'runs', v_runs, 'runs_title', 'Recent runs',
    'footnote', 'Roles, hostile variants and the nine stages are rows in the database. '
             || 'Adding one is an INSERT, never a deploy.');
end $function$;

-- The screen itself is a registered feature, so the bot tests the bot.
-- Column order matters here, not just the values: the protected gate
-- `dev_tools_registry_test` reads every migration for the shape
-- (route_key, sort_order, 'medibo', … 'dev_tools') to prove that every tool the
-- registry admits is one this build can open. Registering the tile in a
-- different column order would leave it invisible to that gate, which is the
-- exact defect (#349/#468) the gate exists to retire.
insert into public.feature_registry
  (feature_key, label, group_label, category, route_key, sort_order, owner,
   surface, is_active, roles_allowed, icon_key, description,
   test_entry, test_roles, test_steps, test_expect, test_automatable, test_contract_at)
values (
  'devtool.journey_bot', 'Journey bot', 'Proof & QA', 'more_system',
  'journey_bot', 6, 'medibo', 'dev_tools', true, array['admin','super_admin'], 'map',
  'Every registered feature driven as every role, with hostile variants, and the gaps that came out of it.',
  '/admin/dev-queue', array['admin'],
  '[{"kind":"auth"},{"kind":"goto","path":"/admin/dev-queue"},{"kind":"settle","ms":4000},{"kind":"rpc","fn":"autotest_home","as":"service"}]'::jsonb,
  '{"kind":"visible","source":"render_log","key":"boot_status","equals":"painted"}'::jsonb,
  true, now())
on conflict (feature_key) do update
  set label = excluded.label, test_steps = excluded.test_steps,
      test_expect = excluded.test_expect, test_automatable = true,
      test_contract_at = now(), is_active = true;

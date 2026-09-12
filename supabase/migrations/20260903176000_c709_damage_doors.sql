-- CHANGE #709 (6/6a) — the doors, and the list behind them.
--
-- A worker holding a task needs to say "this broke" about a LINE, and the task
-- only knows the order. damage_lines() is that list, worded and gated by the
-- backend: what is left on each line after everything already logged, and
-- whether this stage may be logged at at all.
--
-- The button on the task row is labelled by fulfil_my_tasks() (one more key on
-- a row it already builds), and the admin report gets a registry tile and a
-- declared route, because a tile with no door is the #821 class.
-- Idempotent throughout.

create or replace function public.damage_lines(p_order_id uuid, p_stage text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_act jsonb := public._c709_actor(p_order_id);
  v_stage text := lower(btrim(coalesce(nullif(p_stage,''),'count')));
  v_rows jsonb; v_allow boolean;
begin
  if not coalesce((v_act->>'has')::boolean,false) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'title', _c('damage.title'), 'message', _c('damage.err_not_authorized'));
  end if;
  select coalesce(allow,false) into v_allow from handling_damage_stage where stage_key = v_stage;

  select coalesce(jsonb_agg(jsonb_build_object(
           'order_item_id', x.id,
           'product_name', x.product_name,
           'supplier', x.supplier,
           'ordered_qty', x.quantity,
           'remaining_qty', x.remaining,
           'damaged_qty', x.damaged,
           'qty_label', _cf('damage.qty_summary', jsonb_build_object(
                          'qty', rtrim(rtrim(to_char(x.remaining,'FM999999990.99'),'0'),'.'),
                          'n', '1')),
           'line_note', case when x.damaged > 0
                             then _cf('damage.line_note', jsonb_build_object(
                                    'qty', rtrim(rtrim(to_char(x.damaged,'FM999999990.99'),'0'),'.'),
                                    'unit', _c('damage.unit_default')))
                             else '' end,
           'can_log', (x.remaining > 0 and coalesce(v_allow,false))
         ) order by x.product_name), '[]'::jsonb)
    into v_rows
    from (
      select oi.id, coalesce(nullif(btrim(oi.product_name),''), _c('damage.none_label')) as product_name,
             coalesce(nullif(btrim(oi.assigned_supplier),''),'') as supplier,
             coalesce(oi.quantity,0) as quantity,
             public.damage_qty_for_item(oi.id) as damaged,
             greatest(coalesce(oi.quantity,0) - public.damage_qty_for_item(oi.id), 0) as remaining
        from order_items oi
       where oi.order_id = p_order_id
         and coalesce(oi.status,'') <> 'cancelled'
         and oi.fulfillment_state not in ('shipped','cancelled')) x;

  return jsonb_build_object(
    'ok', true,
    'title', _c('damage.title'),
    'subtitle', _c('damage.subtitle'),
    'stage_key', v_stage,
    'stage_allowed', coalesce(v_allow,false),
    'message', case when coalesce(v_allow,false) then '' else _c('damage.err_stage') end,
    'empty_note', _c('damage.report_empty'),
    'rows', v_rows,
    'state', public.damage_state(p_order_id));
end
$fn$;

revoke all on function public.damage_lines(uuid,text) from public, anon, authenticated;
grant execute on function public.damage_lines(uuid,text) to authenticated;

-- ── the button on the worker's own task row ──────────────────────────────
do $do$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'fulfil_my_tasks';
  if v_def is not null and v_def not like '%damage_label%' then
    v_new := replace(v_def,
      '             ''order_id'',     t.order_id::text,',
      '             ''order_id'',     t.order_id::text,
             -- CHANGE #709: the damage door, labelled here so the worker''s
             -- screen never writes the word itself.
             ''damage_label'', public._c(''damage.title''),
             ''damage_stage'', t.stage_key,');
    if v_new = v_def then raise exception 'c709: fulfil_my_tasks anchor missing'; end if;
    execute v_new;
  end if;
end $do$;

-- ── the admin/partner report needs a tile AND a declared door (#821) ─────
insert into public.feature_registry
  (feature_key, label, group_label, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface, roles_allowed,
   description)
select 'partner.damage_report', public._c('damage.report_title'), 'Fulfilment',
       'damage_report', 56, 'partner', true, 'none', true, 'orders', 'dashboard',
       array['admin','super_admin'],
       'CHANGE #709 — what was damaged in handling, as a rate per worker, supplier and product, plus the queue waiting to be confirmed.'
where not exists (select 1 from public.feature_registry where route_key = 'damage_report');

insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
select 'damage_report', 'partner.damage_report', 'feature', 'home_shell',
       'CHANGE #709 — the damage report; opened by shellExtraRouteScreen() in '
       'lib/screens/shell/shell_extra_routes.dart.', true
where not exists (select 1 from public.surface_route where route_key = 'damage_report');

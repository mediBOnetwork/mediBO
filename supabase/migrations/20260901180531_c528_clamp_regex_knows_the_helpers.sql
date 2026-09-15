-- CHANGE #528 — the clamp judgement must recognise every helper that IS a
-- partner zone clamp, not only the three named partner_scope_* ones.
-- `_oa_visible(zone)` is one: `my_partner_id() is null or zone = partner_zone_id()`.
-- Scoring it as unguarded made the proof cry wolf on already-safe functions,
-- which is how a real hole gets lost in the noise.
create or replace function public._partner_clamp_re()
returns text language sql immutable set search_path to 'public'
as $fn$ select 'partner_scope_|partner_zone_ok|partner_order_zone_ok|partner_zone_id|my_partner_id|_oa_visible|is_partner|role_for_medibo_only|zone_filter_order_array|admin_active_zone' $fn$;

create or replace function public.partner_rpc_allow_refresh()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
declare v_ok int; v_bad int;
begin
  update public.partner_rpc_allow a
     set clamp_ok = j.ok, clamp_checked_at = now()
    from (
      select p.proname,
             bool_and(
               (not p.prosecdef)
               or (p.prosrc ~ public._partner_clamp_re())
               or exists (select 1 from public.partner_rpc_guard_exempt e where e.proname = p.proname)
               or (pg_get_function_identity_arguments(p.oid) !~ '(order_id|order_ids|supplier_name|supplier_order_id|delivery_id|zone_id|partner_id|claim_id|inquiry_id|product_id|session_key)')
             ) as ok
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
       group by p.proname
    ) j
   where j.proname = a.proname;
  select count(*) filter (where clamp_ok), count(*) filter (where not clamp_ok)
    into v_ok, v_bad from public.partner_rpc_allow;
  return jsonb_build_object('ok', true, 'clamped', v_ok, 'closed_to_partners', v_bad);
end $fn$;
grant execute on function public.partner_rpc_allow_refresh() to authenticated;

select public.partner_rpc_allow_refresh();

-- The standing guard: an rpc a partner can REACH (clamp_ok), that is SECURITY
-- DEFINER, takes a scoped argument and carries no clamp, is a hole. Empty list
-- or the proof is red.
create or replace function public.partner_rpc_guard_proof()
returns jsonb
language sql stable security definer set search_path to 'public'
as $fn$
  with fn as (
    select a.proname, a.clamp_ok, p.prosecdef, p.prosrc,
           pg_get_function_identity_arguments(p.oid) as args
      from public.partner_rpc_allow a
      join pg_proc p on p.proname = a.proname
      join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
  ),
  judged as (
    select f.proname, f.args, f.prosecdef, f.clamp_ok,
           (f.args ~ '(order_id|order_ids|supplier_name|supplier_order_id|delivery_id|zone_id|partner_id|claim_id|inquiry_id|product_id|session_key)') as takes_scoped_arg,
           (f.prosrc ~ public._partner_clamp_re()) as has_clamp,
           exists (select 1 from public.partner_rpc_guard_exempt e where e.proname = f.proname) as exempt
      from fn f
  ),
  bad as (
    select proname, args from judged
     where clamp_ok and prosecdef and takes_scoped_arg and not has_clamp and not exempt
  )
  select jsonb_build_object(
    'ok', not exists (select 1 from bad),
    'checked',             (select count(*) from judged),
    'reachable_by_partner',(select count(*) from judged where clamp_ok),
    'closed_to_partner',   (select count(*) from judged where not clamp_ok),
    'unguarded_reachable', coalesce((select jsonb_agg(jsonb_build_object('proname',proname,'args',args) order by proname) from bad), '[]'::jsonb))
$fn$;
grant execute on function public.partner_rpc_guard_proof() to authenticated;

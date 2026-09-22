-- CMD #2154 — every staff alert popup has ONE button: View.
--
-- View stops the alarm, marks the alert seen for good (every admin device, a
-- reload included — the in-memory seen-set used to forget on refresh and the
-- 10-minute look-back rang the same sign-up again), closes the popup and opens
-- the item's own action screen. WHICH screen is the backend's: every alert row
-- now carries view {label, route, params}, and the label is ui_copy
-- admin_alert.view.
--
-- Idempotent: safe to replay on live.

insert into public.ui_copy(key, value)
values ('admin_alert.view', to_jsonb('View'::text))
on conflict (key) do nothing;

create table if not exists public.admin_alert_seen (
  kind     text        not null,
  item_id  text        not null,
  seen_by  uuid,
  seen_at  timestamptz not null default now(),
  primary key (kind, item_id)
);
alter table public.admin_alert_seen enable row level security;
revoke all on public.admin_alert_seen from anon, authenticated;

-- The one place an alert kind is mapped to the screen that acts on it.
create or replace function public._admin_alert_view(p_kind text, p_id text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'label',  coalesce((select value #>> '{}' from public.ui_copy
                         where key = 'admin_alert.view'), ''),
    'route',  case p_kind
                when 'new_registration'     then 'customers'
                when 'new_supplier'         then 'suppliers'
                when 'mr_registration'      then 'mr'
                when 'company_registration' then 'companies'
                when 'dp_registration'      then 'delivery_partners'
                when 'new_order'            then 'order_timeline'
                else 'home' end,
    'params', jsonb_build_object('id', p_id));
$function$;
revoke all on function public._admin_alert_view(text, text) from public, anon, authenticated;


-- The card the popup draws, worded here: a title from ui_copy and the three
-- lines each kind has always shown. The overlay prints these verbatim.
create or replace function public._admin_alert_card(p_kind text, r jsonb)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'title', coalesce((select value #>> '{}' from public.ui_copy where key =
               case p_kind
                 when 'new_registration'     then 'admin_alert.banner_new_registration'
                 when 'new_supplier'         then 'admin_alert.banner_new_supplier'
                 when 'mr_registration'      then 'admin_alert.banner_new_mr'
                 when 'company_registration' then 'admin_alert.banner_new_company'
                 when 'dp_registration'      then 'admin_alert.banner_new_delivery_partner'
                 else 'admin_alert.banner_new_order' end), ''),
    'name', coalesce(nullif(btrim(case p_kind
                 when 'new_registration'     then r->>'pharmacy_name'
                 when 'new_supplier'         then r->>'supplier_name'
                 when 'company_registration' then r->>'company_name'
                 else r->>'full_name' end), ''), '—'),
    'subtitle', coalesce(nullif(btrim(case p_kind
                 when 'new_registration'     then coalesce(r->>'customer_name', r->>'owner_name')
                 when 'new_supplier'         then r->>'contact_name'
                 when 'mr_registration'      then r->>'company_represented'
                 when 'company_registration' then r->>'contact_person'
                 when 'dp_registration'      then r->>'vehicle_type'
                 else null end), ''), ''),
    'detail', concat_ws('  ·  ',
                 nullif(btrim(coalesce(r->>'whatsapp_no', r->>'phone', '')), ''),
                 nullif(concat_ws(', ', nullif(btrim(coalesce(r->>'city','')), ''),
                                        nullif(btrim(coalesce(r->>'state','')), '')), '')));
$function$;
revoke all on function public._admin_alert_card(text, jsonb) from public, anon, authenticated;

create or replace function public.admin_alert_new_since(p_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'mode', 'public'
AS $function$
declare v_since timestamptz := coalesce(p_since, now() - interval '10 minutes');
        v_lim int := least(greatest(coalesce(p_limit,25),1),50);
        v_rows jsonb;
        -- CHANGE #1765 — the overlay pings the admin who is ON that zone. The
        -- DATE dimension does not apply: p_since IS this surface's time
        -- bound, and clamping a live alert to the picked date would silence
        -- it the moment anyone looked at yesterday (zone_scope_allow, 'date').
        v_zone smallint := public.scope_zone();
begin
  if coalesce(public.get_my_role(),'') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'rows', '[]'::jsonb, 'server_time', now());
  end if;

  -- one union, one order, one limit — the overlay renders in payload order.
  -- CMD #2154: an alert somebody has Viewed never rings again, and every row
  -- carries the View button's own {label, route, params}.
  select coalesce(jsonb_agg(u.x || jsonb_build_object(
                    'view', public._admin_alert_view(u.x->>'kind', u.x->>'id'),
                    'card', public._admin_alert_card(u.x->>'kind', u.x->'row'))
                  order by u.created_at), '[]'::jsonb) into v_rows
  from (
   select q.created_at, q.x from (
    select p.created_at,
           jsonb_build_object('kind','new_registration','id',p.id::text,'row',to_jsonb(p)) as x
      from pharmacy_profiles p
     where p.created_at > v_since and coalesce(p.approved,false) = false
       and coalesce(p.status,'') in ('','pending')
       and not coalesce(p.is_synthetic,false)
       and public.scope_zone_ok(p.zone_id, v_zone)
    union all
    select s.created_at,
           jsonb_build_object('kind','new_supplier','id',s.id::text,'row',to_jsonb(s))
      from supplier_profiles s
     where s.created_at > v_since and coalesce(s.approved,false) = false
       and coalesce(s.status,'') in ('','pending')
       and not coalesce(s.is_synthetic,false)
       and public.scope_zone_ok(s.zone_id, v_zone)
    union all
    -- CHANGE #668: mr_registrations has submitted_at, not created_at.
    -- CHANGE #1765: an MR application carries no zone, so it reaches every
    -- zone rather than none.
    select m.submitted_at,
           jsonb_build_object('kind','mr_registration','id',m.id::text,'row',to_jsonb(m))
      from mr_registrations m
     where m.submitted_at > v_since
    union all
    -- ...and company_profiles is submitted_at too, for the same reason.
    select c.submitted_at,
           jsonb_build_object('kind','company_registration','id',c.id::text,'row',to_jsonb(c))
      from company_profiles c
     where c.submitted_at > v_since
    union all
    select d.created_at,
           jsonb_build_object('kind','dp_registration','id',d.id::text,'row',to_jsonb(d))
      from delivery_partner_registrations d
     where d.created_at > v_since
       and not coalesce(d.is_synthetic,false)
       and public.scope_zone_ok(d.zone_id, v_zone)
    union all
    select o.created_at,
           jsonb_build_object('kind','new_order','id',o.id::text,'row',to_jsonb(o))
      from orders o
     where o.created_at > v_since
       and not coalesce(o.is_synthetic,false)
       and public.scope_zone_ok(o.zone_id, v_zone)
       and coalesce(o.status,'') in ('','pending')
   ) q
   where q.created_at is not null
     and not exists (select 1 from public.admin_alert_seen s
                      where s.kind = q.x->>'kind' and s.item_id = q.x->>'id')
   order by q.created_at desc
   limit v_lim
  ) u;

  return jsonb_build_object(
    'ok', true,
    'rows', v_rows,
    'count', jsonb_array_length(v_rows),
    'since', v_since,
    'server_time', now());
end $function$;

-- View tapped: stamp the alert seen for every admin, hand back where to go.
create or replace function public.admin_alert_view(p_kind text, p_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if coalesce(public.get_my_role(),'') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;
  if coalesce(p_kind,'') = '' or coalesce(p_id,'') = '' then
    return jsonb_build_object('ok', false, 'error', 'missing_alert');
  end if;
  insert into public.admin_alert_seen(kind, item_id, seen_by)
  values (p_kind, p_id, auth.uid())
  on conflict (kind, item_id) do nothing;
  return jsonb_build_object('ok', true, 'view', public._admin_alert_view(p_kind, p_id));
end $function$;
revoke all on function public.admin_alert_view(text, text) from public, anon;
grant execute on function public.admin_alert_view(text, text) to authenticated;

-- The new-order popup is a staff alert popup too: one button, View. The
-- secondary word goes empty (the widget draws no second button for an empty
-- label) and the primary is the same ui_copy word. Patched in place so this
-- replay never overwrites whatever else order_alert_popup has become on live.
do $do$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
   where p.proname = 'order_alert_popup'
     and p.pronamespace = 'public'::regnamespace
   limit 1;
  if v_def is null then return; end if;
  if position($s$'secondary_label', public.oa_label('popup_secondary')$s$ in v_def) = 0 then
    return; -- already patched (or reshaped); nothing to do
  end if;
  v_def := replace(v_def,
    $s$'primary_label',   public.oa_label('popup_primary')$s$,
    $s$'primary_label',   coalesce((select value #>> '{}' from public.ui_copy where key = 'admin_alert.view'), public.oa_label('popup_primary'))$s$);
  v_def := replace(v_def,
    $s$'secondary_label', public.oa_label('popup_secondary')$s$,
    $s$'secondary_label', ''$s$);
  execute v_def;
end $do$;

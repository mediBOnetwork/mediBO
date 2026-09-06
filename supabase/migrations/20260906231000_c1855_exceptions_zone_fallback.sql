-- CHANGE #1855 — Exceptions tab: default p_zone to admin_active_zone()
-- replay-target: production
--
-- exceptions_queue(p_zone,...) only filtered when the CALLER passed a zone.
-- Flutter passes nothing, so the tab read "All zones" while the header picker
-- said Raipur Zone — and the tab badge (fulfill_stage_counts -> exceptions_queue)
-- disagreed with the picker in exactly the same way.
--
-- A null p_zone now means "use the header picker" (admin_active_zone()), not
-- "every zone". A partner stays locked to their own zone; a super admin with no
-- zone selected still resolves to NULL = all zones, because that is what
-- admin_active_zone() itself returns for them.
--
-- admin_count_exceptions (Ops -> Count differences) was reading order_items with
-- no zone predicate at all, so the same screen showed another zone's rows next
-- to a zone-scoped list. It now reads the same picker.

create or replace function public.exceptions_queue(
  p_zone   smallint default null,
  p_reason text     default null,
  p_status text     default 'open',
  p_limit  integer  default 200)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_role    text     := coalesce(public.get_my_role(), 'none');
  v_partner bigint   := public.my_partner_id();
  v_access  text;
  v_zone    smallint;
  v_status  text     := lower(coalesce(nullif(btrim(p_status),''), 'open'));
  v_reason  text     := nullif(btrim(coalesce(p_reason,'')), '');
  v_limit   int      := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_zlabel  text;
  v_out     jsonb;
begin
  if auth.uid() is null or v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'title', public._c('exc.title'),
      'message', public._c('exc.not_authorized'),
      'rows', '[]'::jsonb, 'count', 0);
  end if;

  v_access := case when v_partner is not null
                   then coalesce(public.partner_access('partner.exceptions', v_partner), 'none')
                   else coalesce(public.admin_access('fulfill.exceptions'), 'none') end;

  if v_access = 'none' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'title', public._c('exc.title'),
      'message', public._c('exc.not_authorized'),
      'rows', '[]'::jsonb, 'count', 0);
  end if;

  -- A partner never chooses a zone: it is theirs, always.
  -- CHANGE #1855 — an admin who passes nothing gets the header picker, not
  -- every zone. admin_active_zone() already answers NULL for a super admin
  -- with no zone selected, which is still "all zones".
  v_zone := case when v_partner is not null
                 then (select r.zone_id::smallint from public.region_partners r where r.id = v_partner)
                 when p_zone is not null then p_zone
                 else public.admin_active_zone() end;

  v_zlabel := coalesce((select z.name from public.zones z where z.id = v_zone),
                       public._c('exc.zone_all'));

  if v_reason = 'all' then v_reason := null; end if;

  with base as (
    select r.reason_code || ':' || r.ref_id                             as id,
           r.reason_code, r.ref_id, r.zone_id, r.title, r.subtitle,
           r.since, r.action_ref,
           -- CHANGE #470 — the row's own stage wins; the reason's stage is the
           -- fallback for a source that is not stage-bound.
           coalesce(nullif(r.stage_key,''), nullif(x.stage_key,'')) as stage_key,
           x.severity, x.sla_hours, x.owner_kind, x.action_kind,
           x.action_route, x.sort_rank,
           coalesce(s.status, 'open')                                   as status,
           s.outcome_code,
           round((extract(epoch from (now() - r.since)) / 3600.0)::numeric, 2) as age_hours
      from public._exception_rows() r
      join public.exception_reason x
        on x.reason_code = r.reason_code and x.enabled
      left join public.exception_state s
        on s.reason_code = r.reason_code and s.ref_id = r.ref_id
     where (v_zone is null or r.zone_id = v_zone or r.zone_id is null)
       and case v_status
             when 'closed' then coalesce(s.status,'open') = 'closed'
             when 'all'    then true
             else coalesce(s.status,'open') <> 'closed'
           end
  ),
  scored as (
    select b.*, (b.age_hours * b.severity) as sort_score, ow.blk as owner_blk,
           lk.route as link_route
      from base b
      cross join lateral (
        select coalesce(nullif(b.action_route, ''),
                 (select m.route from public.exception_route_map m
                   where m.class_key = b.action_ref),
                 (select c.action_route from public.ops_board_class c
                   where c.key = b.action_ref), '') as route) lk
      cross join lateral (
        select case
          when b.owner_kind = 'admin' or b.zone_id is null then
            jsonb_build_object('kind','admin','id','','label', public._c('exc.owner.admin'))
          else coalesce((
            select jsonb_build_object('kind','partner','id', rp.id::text,
                     'label', public._cf('exc.owner.partner',
                                jsonb_build_object('name', coalesce(nullif(rp.partner_name,''), ''))))
              from public.region_partners rp
             where rp.zone_id = b.zone_id and coalesce(rp.is_active, true)
             order by rp.id limit 1),
            jsonb_build_object('kind','admin','id','','label', public._c('exc.owner.admin')))
        end as blk) ow
  ),
  tot as (select count(*)::int as n from scored),
  filt as (
    select jsonb_build_array(jsonb_build_object(
             'key', 'all', 'label', public._c('exc.filter.all'),
             'count', (select n from tot), 'selected', (v_reason is null)))
           || coalesce((
             select jsonb_agg(jsonb_build_object(
                      'key',      g.reason_code,
                      'label',    public._c('exc.reason.' || g.reason_code),
                      'count',    g.n,
                      'selected', (v_reason is not null and v_reason = g.reason_code))
                    order by g.rank desc, g.n desc)
               from (select s.reason_code, count(*)::int n, max(s.sort_rank) rank
                       from scored s group by s.reason_code) g), '[]'::jsonb) as j
  ),
  picked as (
    select s.* from scored s
     where (v_reason is null or s.reason_code = v_reason)
     order by s.sort_score desc, s.since asc
     limit v_limit
  ),
  rws as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id',            p.id,
             'reason_code',   p.reason_code,
             'reason_label',  public._c('exc.reason.' || p.reason_code),
             'severity',      p.severity,
             'title',         p.title,
             'subtitle',      p.subtitle,
             'ref_id',        p.ref_id,
             'stage_key',     coalesce(p.stage_key, ''),
             'stage_label',   coalesce((select st.label from public.sla_stage st
                                         where st.stage_key = p.stage_key), ''),
             'stage_chip',    case when coalesce(p.stage_key,'') = ''
                                   then public._c('exc.stage_none')
                                   else public._cf('exc.stage_prefix', jsonb_build_object(
                                          'stage', coalesce((select st.label from public.sla_stage st
                                                              where st.stage_key = p.stage_key),
                                                            p.stage_key))) end,
             'link',          jsonb_build_object(
                                'has',   (p.link_route <> ''),
                                'label', public._c('exc.link_label'),
                                'route', p.link_route),
             'zone_id',       p.zone_id,
             'zone_label',    coalesce((select z.name from public.zones z where z.id = p.zone_id), ''),
             'age_label',     public._cf('exc.age', jsonb_build_object(
                                'age', public.ops_age_label(p.since))),
             'age_hours',     p.age_hours,
             'sort_score',    p.sort_score,
             'over_sla',      (p.age_hours > p.sla_hours),
             'sla_label',     case when p.age_hours > p.sla_hours
                                   then public._cf('exc.sla_over', jsonb_build_object(
                                          'h', floor(p.age_hours - p.sla_hours)::int::text))
                                   else public._c('exc.sla_within') end,
             'tone',          case when p.age_hours <= p.sla_hours then 'info'
                                   when p.severity >= 5 then 'bad'
                                   when p.age_hours > p.sla_hours * 3 then 'bad'
                                   else 'warn' end,
             'owner',         p.owner_blk,
             'owner_label',   public._cf('exc.owner_prefix',
                                jsonb_build_object('owner', p.owner_blk->>'label')),
             'status',        p.status,
             'status_label',  public._c('exc.status.' || p.status),
             'status_tone',   case p.status when 'closed' then 'good'
                                            when 'working' then 'warn'
                                            else 'info' end,
             'next_action',   case
               when p.action_kind = 'rpc' then jsonb_build_object(
                 'has', true, 'kind', 'rpc',
                 'label', public._c('exc.action.' || p.reason_code),
                 'rpc', 'exceptions_action',
                 'args', jsonb_build_object('p_id', p.id),
                 'route', p.action_route)
               when p.action_kind = 'route' then jsonb_build_object(
                 'has', true, 'kind', 'route',
                 'label', public._c('exc.action.' || p.reason_code),
                 'rpc', '', 'args', '{}'::jsonb,
                 'route', p.link_route)
               else jsonb_build_object('has', false, 'kind', 'none',
                 'label', '', 'rpc', '', 'args', '{}'::jsonb, 'route', '')
             end,
             'close_label',   public._c('exc.close'),
             'can_close',     (v_access = 'write' and p.status <> 'closed'),
             'outcome_label', case when p.outcome_code is null then ''
                                   else public._c('exc.outcome.' || p.outcome_code) end)
             order by p.sort_score desc, p.since asc), '[]'::jsonb) as j
      from picked p
  )
  select jsonb_build_object(
    'ok',            true,
    'title',         public._c('exc.title'),
    'subtitle',      public._c('exc.subtitle'),
    'role',          v_role,
    'is_partner',    (v_partner is not null),
    'partner_id',    v_partner,
    'zone_id',       v_zone,
    'zone_label',    v_zlabel,
    'access',        v_access,
    'can_write',     (v_access = 'write'),
    'status_key',    v_status,
    'reason_key',    coalesce(v_reason, 'all'),
    'count',         t.n,
    'count_label',   case when t.n = 0 then public._c('exc.clean')
                          when t.n = 1 then public._c('exc.count_one')
                          else public._cf('exc.count_many',
                                 jsonb_build_object('n', t.n::text)) end,
    'tone',          case when t.n = 0 then 'good' else 'warn' end,
    'empty_label',   case when v_reason is null then public._c('exc.empty')
                          else public._c('exc.empty_filtered') end,
    'filter_label',  public._c('exc.filter_label'),
    'refresh_label', public._c('exc.refresh'),
    'retry_label',   public._c('exc.retry'),
    'filters',       f.j,
    'outcomes',      coalesce((
                       select jsonb_agg(jsonb_build_object(
                                'code', o.outcome_code,
                                'label', public._c('exc.outcome.' || o.outcome_code),
                                'affects', o.affects,
                                'is_success', o.is_success)
                              order by o.sort_rank desc)
                         from public.exception_outcome o where o.enabled), '[]'::jsonb),
    'close',         jsonb_build_object(
                       'title',     public._c('exc.close.title'),
                       'hint',      public._c('exc.close.hint'),
                       'note_hint', public._c('exc.close.note_hint'),
                       'submit',    public._c('exc.close.submit'),
                       'cancel',    public._c('exc.close.cancel'),
                       'pick',      public._c('exc.close.pick')),
    'rows',          r.j)
    into v_out
    from tot t, filt f, rws r;

  return v_out;
end $function$;

revoke all on function public.exceptions_queue(smallint, text, text, integer) from public, anon;
grant execute on function public.exceptions_queue(smallint, text, text, integer) to authenticated, service_role;


create or replace function public.admin_count_exceptions(p_limit integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_rows jsonb;
  v_n    int;
  -- CHANGE #1855 — the same header picker the Exceptions tab now reads.
  -- NULL (super admin with no zone selected) still means every zone.
  v_zone smallint := public.admin_active_zone();
begin
  if not public._c459_admin() then return public._c459_refuse(); end if;

  select count(*)::int into v_n
    from order_items oi
   where oi.count_diff is not null and oi.count_diff <> 0
     and (v_zone is null or oi.zone_id = v_zone);

  select coalesce(jsonb_agg(s.x order by s.sort_key), '[]'::jsonb) into v_rows
  from (
    select to_char(coalesce(oi.received_at, oi.created_at),'YYYYMMDDHH24MISS') as sort_key,
           jsonb_build_object(
      'id',          oi.id,
      'sort_key',    to_char(coalesce(oi.received_at, oi.created_at),'YYYYMMDDHH24MISS'),
      'title',       coalesce(oi.product_name,''),
      'subtitle',    coalesce(nullif(oi.assigned_supplier,''), ''),
      'age_label',   public._c459_counted_label(coalesce(oi.received_at, oi.created_at)),
      'qty_label',   public._cf('ops.count.pair', jsonb_build_object(
                       'shop', oi.shop_qty::text,
                       'wh',   case when oi.wh_recount_qty is null
                                    then public._c('ops.count.no_recount')
                                    else public._cf('ops.count.wh_n', jsonb_build_object('n', oi.wh_recount_qty::text)) end)),
      'state_label', case when oi.count_diff < 0
                          then public._cf('ops.count.short', jsonb_build_object('n', abs(oi.count_diff)::text))
                          else public._cf('ops.count.over',  jsonb_build_object('n', oi.count_diff::text)) end,
      'state_tone',  'danger') as x
    from order_items oi
    where oi.count_diff is not null and oi.count_diff <> 0
      and (v_zone is null or oi.zone_id = v_zone)
    order by coalesce(oi.received_at, oi.created_at) desc
    limit greatest(1, coalesce(p_limit, 100))
  ) s;

  return jsonb_build_object(
    'ok', true, 'key', 'count_exceptions',
    'title', public._c('ops.count.title'), 'subtitle', public._c('ops.count.subtitle'),
    'count', v_n,
    'count_label', case when v_n = 0 then public._c('ops.clean')
                        when v_n = 1 then public._c('ops.count_one')
                        else public._cf('ops.count_many', jsonb_build_object('n', v_n::text)) end,
    'tone', case when v_n = 0 then 'success' else 'danger' end,
    'zone_id', v_zone,
    'zone_label', coalesce((select z.name from public.zones z where z.id = v_zone),
                           public._c('exc.zone_all')),
    'empty_label', public._c('ops.empty'),
    'rows', v_rows);
end $function$;

revoke all on function public.admin_count_exceptions(integer) from public, anon;
grant execute on function public.admin_count_exceptions(integer) to authenticated, service_role;

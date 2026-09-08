-- CHANGE #697 — three copy fixes the live screenshots found. All data.
--
-- 1. The desk printed "NPS trend" twice in a row: once as the hero card's line
--    and again as the heading of the section directly beneath it. The hero
--    gets its own sentence.
-- 2. The public WhatsApp page stacked subtitle + intro, so a pharmacy read
--    "It takes 30 seconds" twice. The intro now says the one thing the
--    in-app subtitle cannot: this link is for THIS order and is single-use.

insert into public.ui_copy (key, value) values
  ('feedback.nps_hero', to_jsonb('Net promoter score'::text))
on conflict (key) do update set value = excluded.value;

update public.ui_copy
   set value = to_jsonb('This link is for this order only, and works once.'::text)
 where key = 'feedback.wa_intro';


-- 3. The payload has to carry the new line, or the screen renders an empty
--    string for it. One key added to order_feedback_screen()'s return.
CREATE OR REPLACE FUNCTION public.order_feedback_screen(p_zone integer DEFAULT NULL::integer, p_weeks integer DEFAULT 8)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role    text   := coalesce(public.get_my_role(),'none');
  v_partner bigint := public.my_partner_id();
  v_zone    int    := p_zone;
  v_locked  boolean := false;
  v_weeks   int    := greatest(least(coalesce(p_weeks, 8), 26), 2);
  v_trend   jsonb; v_dims jsonb; v_worst jsonb; v_zones jsonb;
  v_total   int; v_nps numeric;
begin
  if v_partner is not null then
    select rp.zone_id into v_zone from public.region_partners rp where rp.id = v_partner;
    v_locked := true;
  elsif v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'title', public._c('feedback.screen_title'),
      'message', public._c('feedback.err_not_authorized'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'week_start',  w.week_start::text,
           'label',       to_char(w.week_start, 'DD Mon'),
           'nps',         w.nps,
           'nps_label',   coalesce(w.nps::text, '—'),
           'responses',   w.responses,
           'responses_label', public._order_feedback_responses_label(w.responses),
           'tone',        case when w.nps is null then 'info'
                               when w.nps >= 50 then 'success'
                               when w.nps >= 0  then 'warning'
                               else 'danger' end)
           order by w.week_start), '[]'::jsonb)
    into v_trend
    from public.order_feedback_weekly w
   where w.week_start >= (current_date - (v_weeks * 7))
     and (v_zone is null or w.zone_id = v_zone);

  select count(*)::int,
         round(100.0 * (count(*) filter (where f.nps >= 9)
                        - count(*) filter (where f.nps <= 6))::numeric
               / nullif(count(*),0), 1)
    into v_total, v_nps
    from public.order_feedback f
   where not f.skipped
     and f.created_at >= now() - make_interval(weeks => v_weeks)
     and (v_zone is null or f.zone_id = v_zone);

  select coalesce(jsonb_agg(x.js order by x.sort_order), '[]'::jsonb) into v_dims
    from (
      select d.sort_order,
             jsonb_build_object(
               'key',   d.dim_key,
               'label', public._c(d.copy_key),
               'avg',   a.v,
               'avg_label', coalesce(to_char(a.v, 'FM990.0'), '—'),
               'tone',  case when a.v is null then 'info'
                             when a.v >= 4.0 then 'success'
                             when a.v >= 3.0 then 'warning'
                             else 'danger' end) as js
        from public.order_feedback_dimension d
        left join lateral (
          select round(avg(
                   case d.dim_key
                     when 'ordering'  then f.score_ordering
                     when 'packaging' then f.score_packaging
                     when 'delivery'  then f.score_delivery
                     when 'products'  then f.score_products
                     when 'support'   then f.score_support end)::numeric, 2) as v
            from public.order_feedback f
           where not f.skipped
             and f.created_at >= now() - make_interval(weeks => v_weeks)
             and (v_zone is null or f.zone_id = v_zone)) a on true
       where d.is_active) x;

  select coalesce(jsonb_agg(jsonb_build_object(
           'order_id',    f.order_id::text,
           'order_code',  coalesce(o.order_code,''),
           'customer',    coalesce(pp.pharmacy_name,''),
           'when_label',  public._ist_stamp(f.created_at),
           'nps_label',   'NPS ' || f.nps::text,
           'worst_label', lo.label || ' ' || lo.score::text || '/5',
           'reason',      coalesce(f.reason,''),
           'has_reason',  (nullif(btrim(coalesce(f.reason,'')),'') is not null),
           'ticket',      (f.ticket_id is not null),
           'tone',        'danger',
           'open_label',  public._c('feedback.open_order'),
           'open_link',   '/admin/fulfill/customer_order?order=' || f.order_id::text)
           order by f.created_at desc), '[]'::jsonb)
    into v_worst
    from public.order_feedback f
    join public.orders o on o.id = f.order_id
    left join public.pharmacy_profiles pp on pp.id = f.customer_id
    cross join lateral (
      select v.label, v.score from (values
        (public._c('feedback.dim_ordering'),  f.score_ordering),
        (public._c('feedback.dim_packaging'), f.score_packaging),
        (public._c('feedback.dim_delivery'),  f.score_delivery),
        (public._c('feedback.dim_products'),  f.score_products),
        (public._c('feedback.dim_support'),   f.score_support)
      ) as v(label, score)
      order by v.score nulls last limit 1) lo
   where not f.skipped
     and (v_zone is null or f.zone_id = v_zone)
     and (f.nps <= 6 or least(coalesce(f.score_ordering,5), coalesce(f.score_packaging,5),
                              coalesce(f.score_delivery,5), coalesce(f.score_products,5),
                              coalesce(f.score_support,5)) <= 2)
     and f.created_at >= now() - make_interval(weeks => v_weeks)
   limit 20;

  if not v_locked then
    select jsonb_agg(jsonb_build_object('id', z.id, 'label', z.name,
                                        'selected', coalesce(v_zone = z.id, false))
                     order by z.id)
      into v_zones from public.zones z where z.is_active;
    v_zones := jsonb_build_array(jsonb_build_object(
                 'id', null, 'label', public._c('feedback.zone_all'),
                 'selected', (v_zone is null))) || coalesce(v_zones, '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'ok', true,
    'title',          public._c('feedback.screen_title'),
    'nps_heading',    public._c('feedback.nps_heading'),
    -- CHANGE #697 — the hero card's own line. It used to print
    -- nps_heading, which the section directly beneath it also prints,
    -- so the desk read "NPS trend" twice in a row.
    'nps_hero',       public._c('feedback.nps_hero'),
    'dims_heading',   public._c('feedback.dims_heading'),
    'worst_heading',  public._c('feedback.worst_heading'),
    'empty_title',    public._c('feedback.empty_title'),
    'empty_note',     public._c('feedback.empty_note'),
    'zone_locked',    v_locked,
    'zone_id',        v_zone,
    'zones',          coalesce(v_zones, '[]'::jsonb),
    'weeks',          v_weeks,
    'responses',      coalesce(v_total, 0),
    'responses_label',public._order_feedback_responses_label(coalesce(v_total, 0)),
    'nps',            v_nps,
    'nps_label',      coalesce(v_nps::text, '—'),
    'nps_tone',       case when v_nps is null then 'info'
                           when v_nps >= 50 then 'success'
                           when v_nps >= 0  then 'warning'
                           else 'danger' end,
    'has_rows',       (coalesce(v_total,0) > 0),
    'trend',          v_trend,
    'dimensions',     v_dims,
    'worst',          v_worst);
end $function$;



grant execute on function public.order_feedback_screen(int, int) to authenticated;

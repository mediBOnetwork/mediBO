-- CMD #2160 — Product card v6: every word, tone and size the new card draws.
--
-- The card gains ONE block, `v6`, next to v5's `style`/`pack_chip`/`sub_line`:
--   scheme       — the short "{order_qty}+{free_qty}" from supplier_schemes
--                  (active, in date, a supplier in the viewer's zone), light
--                  yellow. Falls back to the pricing row's own buy+free.
--   unavail_chip — the pack chip's replacement when the product cannot be
--                  added: "Unavailable", light red.
--   notify_pill  — the red Notify me / We'll notify pill colours.
--   image_pct    — the photo's contain box as % of the square plate (92).
-- Idempotent: create or replace + upserts.

insert into public.storefront_ui_label(key, value)
values ('card_chip_unavailable', 'Unavailable')
on conflict (key) do nothing;

insert into public.ui_copy(key, value)
values ('card.scheme_short', to_jsonb('{order_qty}+{free_qty}'::text))
on conflict (key) do nothing;

insert into public.app_settings(key, value)
values ('card.v6', '{"image_pct":92,
  "scheme_bg":"#FEF3C7","scheme_fg":"#92400E",
  "unavail_bg":"#FEE2E2","unavail_fg":"#991B1B",
  "notify_bg":"#DC2626","notify_fg":"#FFFFFF"}'::jsonb)
on conflict (key) do nothing;

-- The short scheme for one product, or has:false. Zone first: a scheme from a
-- supplier outside the viewer's zone is not an offer this viewer can take.
create or replace function public.card_scheme_short(m "MEDICINE", p_pricing jsonb)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with z as (select coalesce(public._viewer_zone_or_null(),
                             (select v.zone_id from public._storefront_viewer() v)) as zone_id),
  s as (
    select ss.order_qty, ss.free_qty
      from public.supplier_schemes ss
      left join public.supplier_profiles sp on sp.id = ss.supplier_id
      cross join z
     where ss.product_id = m.id
       and ss.active
       and coalesce(ss.order_qty, 0) > 0 and coalesce(ss.free_qty, 0) > 0
       and (ss.valid_from is null or ss.valid_from <= (now() at time zone 'Asia/Kolkata')::date)
       and (ss.valid_to   is null or ss.valid_to   >= (now() at time zone 'Asia/Kolkata')::date)
       and (z.zone_id is null or sp.zone_id is null or sp.zone_id = z.zone_id)
     order by ss.free_qty / ss.order_qty desc, ss.order_qty
     limit 1),
  p as (
    select coalesce((regexp_match(coalesce(p_pricing#>>'{scheme_badge,label}', ''),
                                  '^(\d+)\+(\d+)'))[1]::numeric, 0) oq,
           coalesce((regexp_match(coalesce(p_pricing#>>'{scheme_badge,label}', ''),
                                  '^(\d+)\+(\d+)'))[2]::numeric, 0) fq),
  pick as (
    select coalesce((select order_qty from s), nullif(p.oq, 0)) oq,
           coalesce((select free_qty  from s), nullif(p.fq, 0)) fq
      from p),
  st as (select coalesce((select value from public.app_settings where key = 'card.v6'), '{}'::jsonb) v)
  select case when pick.oq is null or pick.fq is null
              then jsonb_build_object('has', false, 'label', '')
              else jsonb_build_object(
                'has', true,
                'label', replace(replace(public.uic('card.scheme_short', '{order_qty}+{free_qty}'),
                                         '{order_qty}', trim_scale(pick.oq)::text),
                                 '{free_qty}', trim_scale(pick.fq)::text),
                'bg', coalesce(st.v->>'scheme_bg', '#FEF3C7'),
                'fg', coalesce(st.v->>'scheme_fg', '#92400E')) end
    from pick, st
$function$;

revoke all on function public.card_scheme_short("MEDICINE", jsonb) from public, anon;
grant execute on function public.card_scheme_short("MEDICINE", jsonb) to authenticated, service_role;

create or replace function public._product_card(m "MEDICINE", p_pricing jsonb, p_avail jsonb, p_qty integer, p_notified boolean)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select x.b || jsonb_build_object(
    'style', x.st,
    'pack_chip', jsonb_build_object('label', x.pc, 'has', x.pc <> ''),
    'sub_line', public.card_sub_line(m) || jsonb_build_object('fg', x.st->>'sub_fg'),
    'placeholder', jsonb_build_object('kind', public.card_placeholder_kind(m.pack_qty, m.pack_type)),
    'layout', jsonb_build_object(
      'text_lines', coalesce((select (value #>> '{}')::int from public.app_settings where key = 'card.text_lines'), 3),
      'name_max_lines', 2),
    'price', coalesce(x.b->'price', '{}'::jsonb) || jsonb_build_object('mrp_struck', true, 'mrp_fg', x.st->>'mrp_fg'),
    -- CMD #2160 — Product card v6.
    'v6', jsonb_build_object(
      'image_pct', coalesce((x.v6->>'image_pct')::int, 92),
      'scheme', public.card_scheme_short(m, p_pricing),
      'unavail_chip', jsonb_build_object(
        'has', not coalesce((x.b#>>'{availability,is_available}')::boolean, false),
        'label', coalesce((select value from storefront_ui_label where key = 'card_chip_unavailable'), ''),
        'bg', coalesce(x.v6->>'unavail_bg', '#FEE2E2'),
        'fg', coalesce(x.v6->>'unavail_fg', '#991B1B')),
      'notify_pill', jsonb_build_object(
        'bg', coalesce(x.v6->>'notify_bg', '#DC2626'),
        'fg', coalesce(x.v6->>'notify_fg', '#FFFFFF'))))
  from (select public._product_card_base(m, p_pricing, p_avail, p_qty, p_notified) b,
               public.card_pack_chip(m.pack_qty, m.pack_type) pc,
               public.card_style() st,
               coalesce((select value from public.app_settings where key = 'card.v6'), '{}'::jsonb) v6
        offset 0) x   -- CMD #2145: evaluate _product_card_base once, not per use of x.b
$function$;

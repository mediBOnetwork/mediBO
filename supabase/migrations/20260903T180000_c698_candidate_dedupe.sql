-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #698 (part D) — THREE CHOICES MUST BE THREE CHOICES
--
-- The first live ask offered:
--     Choice 1  AMLOkind 10mg Tablet · Mankind · 15 tablets in 1 strip
--     Choice 2  AMLOkind 10mg Tablet · Mankind · 10 tablets in 1 strip
--     Choice 3  AMlip 10 Tablet      · Cipla   · 10 tablets in 1 strip
--
-- which is two choices wearing three rows. The catalogue carries one row per
-- PACK, and the filter only compared each candidate against the ORIGINAL's
-- company — never against the other candidates. A pharmacist tapping "the
-- first one" was ranking a strip size, not a product.
--
-- So the candidate list is now one row per product+company, and the pack it
-- keeps is the one nearest the original's own strip size, because that is the
-- pack that converts most cleanly in substitute_equivalent_qty().
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.substitute_candidates(
  p_product_id bigint,
  p_zone_id    smallint default null,
  p_customer_id uuid default null,
  p_limit      integer default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  m       public."MEDICINE"%rowtype;
  v_zone  smallint := p_zone_id;
  v_lim   int := coalesce(p_limit,
                   (select (value #>> '{}')::int from app_settings
                     where key = 'substitute_ask_max_options'), 3);
  v_units numeric;
  v_items jsonb;
begin
  select * into m from public."MEDICINE" where id = p_product_id;
  if m.id is null or not public.med_substitutable(p_product_id) then
    return jsonb_build_object('has', false, 'salt_key', '', 'items', '[]'::jsonb);
  end if;
  v_zone  := coalesce(v_zone, public.zone_default_id());
  v_units := nullif(regexp_replace(coalesce(m.pack_qty,''), '\D', '', 'g'), '')::numeric;

  with pool as (
    -- Bounded on purpose: the salt index hands back the same-salt shelf, and
    -- everything expensive below (zone standby, purchase history) only ever
    -- runs over that shelf, never over the 563k-row catalogue.
    select s.id, s.product_name, s.marketer, s.salt_composition,
           s.pack_type, s.pack_qty, s.pack_size, s.image_url_1,
           coalesce(s.supplier_count, 0) as supplier_count,
           coalesce(s.sales_count, 0)    as sales_count,
           nullif(regexp_replace(coalesce(s.pack_qty,''), '\D', '', 'g'), '')::numeric as units
      from public."MEDICINE" s
     where s.buyable is true
       and s.salt_composition = m.salt_composition
       and s.id <> m.id
       and public._norm_seg(s.pack_type) = public._norm_seg(m.pack_type)
       and public._norm_seg(s.marketer) <> public._norm_seg(coalesce(m.marketer,''))
       and public.med_status_sellable(s.status)
     order by coalesce(s.sales_count, 0) desc, s.id
     limit 60
  ), zoned as (
    select p.*, public.medicine_zone_standby(p.id, v_zone) as zone_count
      from pool p
  ), live as (
    select z.* from zoned z
     where z.zone_count > 0 and public.med_substitutable(z.id)
  ), one_per_product as (
    -- ONE row per product+company. The catalogue is per pack; the customer is
    -- choosing a MEDICINE. Keep the pack nearest the original's strip size —
    -- that is the one substitute_equivalent_qty converts most cleanly.
    select distinct on (public._norm_seg(l.product_name), public._norm_seg(l.marketer)) l.*
      from live l
     order by public._norm_seg(l.product_name), public._norm_seg(l.marketer),
              case when v_units is null or l.units is null
                   then 999999 else abs(l.units - v_units) end,
              l.sales_count desc, l.id
  ), history as (
    select oi.product_id, count(*)::int as bought
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
     where p_customer_id is not null
       and o.customer_id = p_customer_id
       and oi.product_id in (select id from one_per_product)
     group by oi.product_id
  ), ranked as (
    select c.*, coalesce(h.bought, 0) as bought,
           row_number() over (order by coalesce(h.bought,0) desc,
                                       c.supplier_count desc,
                                       c.sales_count desc,
                                       c.id) as rnk
      from one_per_product c
      left join history h on h.product_id = c.id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id',  r.id,
           'name',        coalesce(r.product_name, ''),
           'company',     coalesce(r.marketer, ''),
           'strength',    coalesce(r.salt_composition, ''),
           'pack_label',  coalesce(nullif(btrim(r.pack_qty), ''),
                                   nullif(btrim(r.pack_type), ''),
                                   nullif(btrim(r.pack_size), ''), ''),
           'image',       coalesce(r.image_url_1, ''),
           'bought_before', (r.bought > 0),
           'rank',        r.rnk) order by r.rnk), '[]'::jsonb)
    into v_items
    from ranked r
   where r.rnk <= greatest(v_lim, 1);

  return jsonb_build_object(
    'has',      jsonb_array_length(v_items) > 0,
    'salt_key', coalesce(public.med_composition_key(m.salt_composition, '', m.pack_type), ''),
    'items',    v_items);
end $$;

revoke all on function public.substitute_candidates(bigint, smallint, uuid, integer) from public, anon;
grant execute on function public.substitute_candidates(bigint, smallint, uuid, integer) to authenticated;

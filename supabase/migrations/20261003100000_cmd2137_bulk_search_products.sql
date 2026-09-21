-- CMD #2137 — Bulk Upload's "Search" returns the SAME product payload as a
-- matched row, so a searched result (and the product then picked) prints the
-- identical four lines: name · pack/qty · sale-price badge · availability.
--
-- Before: the panel searched through search_medicines_priority(), whose row
-- has no avail_badge / pricing / pack_qty_label / qty_unit / composition, so
-- Product.fromMap left those blank and ProductRowCard dropped lines 2–4.
-- Ranking stays search_medicines_priority's (same order the buyer saw); only
-- the per-product fields are decided here, column-for-column with the
-- `ranked` CTE of bulk_match_items().

create or replace function public.bulk_product_payload(p_id bigint)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'id',              m.id,
    'product_name',    m.product_name,
    'company',         nullif(btrim(m.marketer),''),
    'pack_type',       nullif(btrim(m.pack_type),''),
    'pack_size',       nullif(btrim(m.pack_size),''),
    'mrp',             m.mrp,
    'buyable',         m.buyable,
    'category',        nullif(btrim(m.therapeutic_class),''),
    'image_url',       nullif(btrim(m.image_url_1),''),
    'gst_percent',     m.gst_percent,
    'availability',    public.storefront_availability(m.id, m.supplier_count),
    'avail_badge',     public.bulk_avail_badge(
                         public.storefront_availability(m.id, m.supplier_count)),
    'pack_type_label', public.sf_pack_type_label(m.pack_type),
    'pack_qty_label',  public.sf_pack_qty_label(m.pack_qty),
    'pack_line',       public.bulk_pack_line(m.pack_type, m.pack_qty, m.pack_size),
    'qty_unit',        public.bulk_qty_unit(m.pack_type),
    'composition',     public.bulk_composition_line(m.salt_composition),
    'pricing',         public.storefront_pricing(
                         nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,
                         null::numeric, m.id)
  )
  from "MEDICINE" m
  where m.id = p_id
$$;

create or replace function public.bulk_search_products(p_term text, p_limit int default 4)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_term  text := btrim(coalesce(p_term,''));
  v_limit int  := least(greatest(coalesce(p_limit,4),1),20);
  v_rows  jsonb;
begin
  if v_term = '' then
    return jsonb_build_object('status','ok','rows','[]'::jsonb);
  end if;
  select coalesce(jsonb_agg(public.bulk_product_payload(s.id) order by s.ord), '[]'::jsonb)
    into v_rows
    from (
      select r.id, row_number() over () as ord
        from public.search_medicines_priority(v_term, 'All', 0, v_limit) r
    ) s;
  return jsonb_build_object('status','ok','rows', v_rows);
end;
$$;

revoke all on function public.bulk_product_payload(bigint) from public, anon;
grant execute on function public.bulk_product_payload(bigint) to authenticated, service_role;
-- Bulk Upload is open to signed-out visitors (bulk_match_items is anon too),
-- so the search that sits beside it is as well.
revoke all on function public.bulk_search_products(text,int) from public;
grant execute on function public.bulk_search_products(text,int) to anon, authenticated, service_role;

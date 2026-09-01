CREATE OR REPLACE FUNCTION public.my_orders_screen(p_view_as_user uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cust uuid;
  v_admin boolean := coalesce((public.my_session()->>'is_admin')::boolean, false);
  v_cfg  jsonb := coalesce((select value from app_settings where key='order_status_config'), '{}'::jsonb);
  v_copy jsonb := coalesce((select value from app_settings where key='orders_screen_copy'), '{}'::jsonb);
  v_unf  jsonb := coalesce((select value from app_settings where key='unfulfilled_copy'), '{}'::jsonb);
  v_tone jsonb := coalesce((select value from app_settings where key='item_status_tones'),
                    '{"green":{"bg":"#E1F5EE","fg":"#0F6E56"},
                      "yellow":{"bg":"#FEF3C7","fg":"#92400E"},
                      "red":{"bg":"#FBE9E7","fg":"#B42318"}}'::jsonb);
  v_rows jsonb; v_title text; v_note text;
begin
  if p_view_as_user is not null and v_admin then
    v_cust := coalesce(public.customer_id_for_user(p_view_as_user), p_view_as_user);
  else
    v_cust := public.my_customer_id();
  end if;

  select coalesce(jsonb_agg(o order by o->>'placed_at' desc), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'id',                coalesce(ord.id::text,''),
      'order_code',        coalesce(ord.order_code,''),
      'placed_at',         coalesce(ord.created_at::text,''),
      'placed_at_label',   public._ist_stamp(ord.created_at),
      'status',            coalesce(ord.status,'pending'),
      'status_label',      coalesce(nullif(v_cfg->lower(coalesce(ord.status,'pending'))->>'label',''),
                                    initcap(coalesce(ord.status,'pending'))),
      'status_color',      coalesce(v_cfg->lower(coalesce(ord.status,'pending'))->>'color',
                                    v_cfg->'_default'->>'color', '#F59E0B'),
      'total',             coalesce(ord.total_amount,0),
      'total_display',     public.inr_money(coalesce(ord.total_amount,0)),
      'placed_by_admin',   coalesce(ord.placed_by_admin,false),
      'unique_item_count', coalesce(g.n_ok,0),
      'unit_count',        coalesce(g.units_ok,0),
      'total_item_count',  coalesce(g.n_ok,0) + coalesce(g.n_bad,0),
      'lines',             coalesce(g.ok_lines, '[]'::jsonb),
      'has_unfulfilled',   (coalesce(g.n_bad,0) > 0),
      'unfulfilled_count', coalesce(g.n_bad,0),
      'unfulfilled_title', coalesce(nullif(v_unf->>'title',''),'Unfulfilled items'),
      'unfulfilled_note',  coalesce(nullif(v_unf->>'note',''),''),
      'unfulfilled_label', coalesce(nullif(v_unf->>'title',''),'Unfulfilled items')
                             || ' (' || coalesce(g.n_bad,0)::text || ')',
      'unfulfilled_collapsed', true,
      'unfulfilled_lines', coalesce(g.bad_lines, '[]'::jsonb),
      -- CHANGE #408 — the edit window travels WITH the order.
      'edit',              public._order_edit_gate(ord.id),
      -- CMD #452 — and so does every other door a buyer has on this order:
      -- track (#133), cancel (#130), returns (#131), help (#132). The card
      -- renders this list in payload order and decides nothing.
      'actions',           public._order_customer_actions(ord.id)
    ) as o
    from orders ord
    left join lateral (
      select
        count(*) filter (where d.unfulfillable = false)                       as n_ok,
        count(*) filter (where d.unfulfillable)                               as n_bad,
        coalesce(sum(d.qty) filter (where d.unfulfillable = false),0)::int     as units_ok,
        jsonb_agg(jsonb_build_object(
            'name', d.product_name, 'quantity', d.qty::int,
            'price', d.unit_price, 'price_display', public.inr_money(d.unit_price),
            'line_total', d.line_total, 'line_total_display', public.inr_money(d.line_total),
            'product_id',  coalesce(d.product_id::text,''),
            'image_url',   coalesce(d.image_url,''),
            'company',     coalesce(d.company,''),
            'pack_label',  coalesce(d.pack_label,''),
            'qty_label',   d.qty_label,
            'rate_label',  public.inr_money(d.unit_price),
            'line_label',  public.inr_money(d.line_total),
            'batch_block', public._order_product_batch_block(ord.id, d.product_id),
            'status_label', d.status_text,
            'status_tone',  d.status_tone,
            'status_ok',    (d.status_text = 'Available'),
            'status_text', d.status_text,
            'status_colors', coalesce(v_tone->d.status_tone, v_tone->'yellow'))
          order by d.product_name) filter (where d.unfulfillable = false)      as ok_lines,
        jsonb_agg(jsonb_build_object(
            'name', d.product_name, 'quantity', d.qty::int,
            'price', d.unit_price, 'price_display', public.inr_money(d.unit_price),
            'line_total', d.line_total, 'line_total_display', public.inr_money(d.line_total),
            'product_id',  coalesce(d.product_id::text,''),
            'image_url',   coalesce(d.image_url,''),
            'company',     coalesce(d.company,''),
            'pack_label',  coalesce(d.pack_label,''),
            'qty_label',   d.qty_label,
            'rate_label',  public.inr_money(d.unit_price),
            'line_label',  public.inr_money(d.line_total),
            'batch_block', public._order_product_batch_block(ord.id, d.product_id),
            'status_label', coalesce(d.reason, d.status_text),
            'status_tone',  'red',
            'status_ok',    false,
            'status_text', coalesce(d.reason, d.status_text),
            'status_colors', coalesce(v_unf->'chip_colors', v_tone->'red'))
          order by d.product_name) filter (where d.unfulfillable)              as bad_lines
      from (
        select oi.product_id,
               max(oi.product_name)                       as product_name,
               sum(coalesce(oi.quantity,0))               as qty,
               max(coalesce(oi.price, oi.mrp, 0))         as unit_price,
               sum(coalesce(oi.line_total,
                     coalesce(oi.quantity,0) * coalesce(oi.price, oi.mrp, 0))) as line_total,
               bool_or(oi.unfulfillable)                  as unfulfillable,
               max(oi.unfulfillable_reason)               as reason,
               coalesce(max(inq.current_status), 'Confirmation Pending') as status_text,
               case coalesce(max(inq.current_status), 'Confirmation Pending')
                 when 'Available'            then 'green'
                 when 'No Supplier Available' then 'red'
                 else 'yellow' end                        as status_tone,
               max(nullif(btrim(m.image_url_1),''))       as image_url,
               max(upper(nullif(btrim(m.marketer),'')))   as company,
               max(nullif(btrim(regexp_replace(coalesce(m.pack_qty,''),'(\d)\.0(\D)','\1\2','g')),'')) as pack_label,
               trim_scale(sum(coalesce(oi.quantity,0)))::text || ' ' ||
                 case when max(m.pack_type) is null
                        then case when sum(coalesce(oi.quantity,0)) > 1 then 'Units' else 'Unit' end
                      when sum(coalesce(oi.quantity,0)) > 1 and lower(max(m.pack_type)) ~ '(s|x|z|ch|sh)$'
                        then max(m.pack_type) || 'es'
                      when sum(coalesce(oi.quantity,0)) > 1 then max(m.pack_type) || 's'
                      else max(m.pack_type) end           as qty_label
        from order_items oi
        left join "MEDICINE" m on m.id = oi.product_id
        left join lateral (
          select q.current_status from inquiry q
           where q.product_id = oi.product_id
             and (q.zone_id is null or coalesce(oi.zone_id, ord.zone_id) is null
                  or q.zone_id = coalesce(oi.zone_id, ord.zone_id))
           order by (q.batch_date = (ord.created_at at time zone 'Asia/Kolkata')::date) desc nulls last,
                    q.batch_date desc nulls last, q.id desc limit 1) inq on true
        where oi.order_id = ord.id
        group by oi.product_id
      ) d
    ) g on true
    where v_cust is not null and ord.customer_id = v_cust
    order by ord.created_at desc
  ) s;

  if v_cust is null and v_admin then
    v_title := 'Admin account';
    v_note  := 'This login is an admin, not a pharmacy. Customer orders live in the admin Orders tab.';
  else
    v_title := coalesce(nullif(v_copy->>'empty_title',''), 'No purchase orders yet');
    v_note  := coalesce(nullif(v_copy->>'empty_note',''),  'Placed orders will appear here.');
  end if;

  return jsonb_build_object(
    'orders',      v_rows,
    'count',       jsonb_array_length(v_rows),
    'has_orders',  (jsonb_array_length(v_rows) > 0),
    'is_admin_session', v_admin,
    'no_customer_account', (v_cust is null),
    'empty_title', v_title,
    'empty_note',  v_note,
    'customer_id', coalesce(v_cust::text,''));
end $function$

;

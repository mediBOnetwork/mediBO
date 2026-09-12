-- CMD #451 · row 129 — my_orders_screen() groups its lines by product, not by
-- order_item, so the card needs the batch block for a PRODUCT on an order.
create or replace function public._order_product_batch_block(p_order_id uuid, p_product_id bigint)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with arr as (
    select coalesce(jsonb_agg(distinct e), '[]'::jsonb) as a
      from order_items oi
      cross join lateral jsonb_array_elements(public._order_item_batches(oi.id)) e
     where oi.order_id = p_order_id
       and oi.product_id is not distinct from p_product_id)
  select jsonb_build_object(
    'has',     jsonb_array_length((select a from arr)) > 0,
    'batches', (select a from arr),
    'label',   coalesce((select string_agg(e->>'label', '   ' order by e->>'batch_no')
                           from jsonb_array_elements((select a from arr)) e), ''),
    'hint',    case when jsonb_array_length((select a from arr)) = 0
                    then public.uic('order_line.batch_pending',
                                    'Batch and expiry are printed once the pack is received.')
                    else '' end);
$function$;


-- ============================================================================
-- CHANGE #460 — MEDIUM customer defects, batch A
-- feature_gaps 162 (reorder predicts a date in the past)
-- feature_gaps 163 (storefront footer links are hardcoded Dart strings)
-- Both are max-backend fixes: the wording moves into ui_copy and the DECISION
-- about which wording to use moves into the RPC. Flutter keeps rendering one
-- string verbatim.
-- ============================================================================

-- ── 163: every storefront footer link label lives in ui_copy ────────────────
-- The row named five labels; the same widget hardcodes twelve. All twelve move,
-- so changing any of them is an UPDATE and never a deploy.
insert into public.ui_copy (key, value) values
  ('storefront_screen.footer_search_medicines', to_jsonb('Search Medicines'::text)),
  ('storefront_screen.footer_bulk_upload',      to_jsonb('Bulk Upload'::text)),
  ('storefront_screen.footer_my_orders',        to_jsonb('My Orders'::text)),
  ('storefront_screen.footer_cart',             to_jsonb('Cart'::text)),
  ('storefront_screen.footer_about_us',         to_jsonb('About Us'::text)),
  ('storefront_screen.footer_contact_us',       to_jsonb('Contact Us'::text)),
  ('storefront_screen.footer_terms',            to_jsonb('Terms & Conditions'::text)),
  ('storefront_screen.footer_privacy',          to_jsonb('Privacy Policy'::text)),
  ('storefront_screen.footer_data_deletion',    to_jsonb('Delete Account & Data'::text)),
  ('storefront_screen.footer_refund',           to_jsonb('Refund & Return'::text)),
  ('storefront_screen.footer_shipping',         to_jsonb('Shipping Policy'::text)),
  ('storefront_screen.footer_cancellation',     to_jsonb('Cancellation Policy'::text))
on conflict (key) do nothing;

-- ── 162: the overdue prediction ────────────────────────────────────────────
-- _reorder_cadence already knows the item is overdue (due = true when the
-- predicted date is <= today+2). reorder_suggestions printed the predicted date
-- regardless, so an item last bought 28 days ago on a 2-day cadence rendered
-- "Next ~ 04 Aug" — a forward-looking label carrying a date 26 days in the past,
-- sitting next to "Due now".
insert into public.ui_copy (key, value) values
  ('reorder.next_today',       to_jsonb('Expected today'::text)),
  ('reorder.next_overdue_one', to_jsonb('Overdue by 1 day'::text)),
  ('reorder.next_overdue',     to_jsonb('Overdue by {n} days'::text))
on conflict (key) do nothing;

create or replace function public.reorder_suggestions()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_cust uuid; v_items jsonb; v_due int;
begin
  v_cust := public.my_customer_id();
  if v_cust is null then
    return jsonb_build_object(
      'ok', true, 'has_history', false, 'items', '[]'::jsonb,
      'due_count', 0, 'has_due', false,
      'title', public._reorder_uic('reorder.title','Reorder'),
      'empty_title', public._reorder_uic('reorder.empty_title','No reorder history yet'),
      'empty_note',  public._reorder_uic('reorder.empty_note','Your regular items will appear here once you have ordered a few times.'));
  end if;

  select coalesce(jsonb_agg(row order by row_order), '[]'::jsonb),
         coalesce(sum(case when (row->>'due')::boolean then 1 else 0 end),0)
    into v_items, v_due
  from (
    select jsonb_build_object(
             'product_id', c.product_id,
             'name', c.name,
             'marketer', c.marketer,
             'pack_size', c.pack_size,
             'image_url', c.image_url,
             'usual_qty', c.usual_qty,
             'qty_label', public._reorder_uic('reorder.usual_prefix','Usual: ') || c.usual_qty::text,
             'days_since_last', c.days_since_last,
             'since_label', c.days_since_last::text || ' ' || public._reorder_uic('reorder.days_ago','days ago'),
             'due', c.due,
             'due_label', case when c.due then public._reorder_uic('reorder.due_now','Due now') else '' end,
             -- CHANGE #460 / gap 162 — the label is chosen HERE, never in Dart,
             -- and a date that has already passed is never printed as a
             -- forward-looking prediction.
             'predicted_label', case
                    when c.predicted_next is null then ''
                    when c.predicted_next > current_date
                      then public._reorder_uic('reorder.next_prefix','Next ~ ') ||
                           to_char(c.predicted_next,'DD Mon')
                    when c.predicted_next = current_date
                      then public._reorder_uic('reorder.next_today','Expected today')
                    when (current_date - c.predicted_next) = 1
                      then public._reorder_uic('reorder.next_overdue_one','Overdue by 1 day')
                    else replace(
                           public._reorder_uic('reorder.next_overdue','Overdue by {n} days'),
                           '{n}', (current_date - c.predicted_next)::text)
                  end,
             'predicted_state', case
                    when c.predicted_next is null then 'none'
                    when c.predicted_next > current_date then 'future'
                    when c.predicted_next = current_date then 'today'
                    else 'overdue' end,
             'overdue_days', case
                    when c.predicted_next is null or c.predicted_next >= current_date then 0
                    else (current_date - c.predicted_next) end,
             'price_display', public._reorder_money(c.mrp),
             'can_add', (c.supplier_count >= 1),
             'unavailable_label', case when c.supplier_count >= 1 then ''
                    else public._reorder_uic('reorder.unavailable','Currently unavailable') end,
             'remind_on', coalesce(rp.notify, false),
             'remind_label', case when coalesce(rp.notify,false)
                    then public._reorder_uic('reorder.remind_on','Reminder on')
                    else public._reorder_uic('reorder.remind_off','Remind me') end,
             'shelf_level', rp.shelf_level,
             'shelf_label', case when rp.shelf_level is not null
                    then public._reorder_uic('reorder.shelf_prefix','Shelf level ') || rp.shelf_level::text
                    else '' end
           ) as row,
           (case when c.due then 0 else 1 end)::text ||
           lpad((100000 - least(c.days_since_last,99999))::text,6,'0') ||
           lpad((100000 - c.buy_count)::text,6,'0') as row_order
      from public._reorder_cadence(v_cust) c
      left join public.reorder_prefs rp
        on rp.customer_id = v_cust and rp.product_id = c.product_id
  ) s;

  return jsonb_build_object(
    'ok', true, 'has_history', (jsonb_array_length(v_items) > 0),
    'items', v_items,
    'due_count', v_due,
    'has_due', (v_due > 0),
    'title', public._reorder_uic('reorder.title','Reorder'),
    'due_title', public._reorder_uic('reorder.due_title','Due for reorder'),
    'all_title', public._reorder_uic('reorder.all_title','Your regular items'),
    'add_all_label', public._reorder_uic('reorder.add_all','Add all due to cart'),
    'add_label', public._reorder_uic('reorder.add','Add'),
    'manage_label', public._reorder_uic('reorder.manage','Manage auto-reorders'),
    'remind_title', public._reorder_uic('reorder.remind_title','Low-stock reminder'),
    'remind_note', public._reorder_uic('reorder.remind_note','We will message you on WhatsApp before you run out, so you can reorder in one reply.'),
    'shelf_hint', public._reorder_uic('reorder.shelf_hint','Shelf level (optional) — units you like to keep in stock'),
    'remind_save', public._reorder_uic('reorder.remind_save','Save reminder'),
    'remind_clear', public._reorder_uic('reorder.remind_clear','Turn reminder off'),
    'generic_error', public._reorder_uic('reorder.add_generic_error','Something went wrong'),
    'empty_title', public._reorder_uic('reorder.empty_title','No reorder history yet'),
    'empty_note',  public._reorder_uic('reorder.empty_note','Your regular items will appear here once you have ordered a few times.'));
end $function$;

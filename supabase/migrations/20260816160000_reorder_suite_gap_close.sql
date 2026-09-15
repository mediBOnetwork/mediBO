-- ============================================================================
-- CHANGE #173 (part B) — reorder suite gap closure.
--
-- Part A shipped the cadence engine, suggestions, smart diff, subscriptions,
-- prefs and the two crons. This part closes the gaps that stopped the spec's
-- acceptance line from being true end to end:
--
--   1. WhatsApp could never actually SEND. Both reorder routes were created
--      with auto_manage=true but no auto_template_name and no template seed,
--      so wa_send_event() always returned route_disabled — meaning the inbound
--      YES/SKIP handler could never be triggered in the first place. Seed both
--      templates (with the quick-reply buttons the inbound switchboard matches
--      on) and point the routes at them, like every other auto-managed event.
--   2. Inbound "YES"/"SKIP" — closed by the sibling migration
--      20260816160000_reorder_wa_inbound.sql (reorder_wa_inbound() + the
--      wa_reorder_reply_trg trigger). Nothing about the inbound path is
--      re-declared here.
--   3. reorder_prefs_set had no frontend, so the low-stock cron (which only
--      nudges opted-in customers) could never fire for anybody. Suggestions
--      now carry each item's reminder state + labels so the screen can render
--      and toggle it, and prefs_set returns the refreshed payload.
--
-- Plus the admin surface the spec asks for (view + manage), server-rendered.
-- Max-backend: every string, amount and tone below is decided here.
-- ============================================================================

-- ─── 1. WhatsApp tokens for the reorder nudge ───────────────────────────────
-- Standing lesson (storefront): a 'computed' wa_tokens key only fills if its
-- source_ref exists in wa_token_sources — otherwise the send falls back to the
-- blank fallback. Both resolvers are added with the token.
insert into public.wa_token_sources(key, label, sql_expr, description, needs_order)
values
 ('reorder_pending_amount', 'Reorder nudge — order value',
  '(select p.amount from public.reorder_pending p where p.customer_id = $1 and p.status = ''open'' order by p.created_at limit 1)',
  'Value of the open reorder nudge for this customer', false),
 ('reorder_pending_items', 'Reorder nudge — item count',
  '(select jsonb_array_length(p.items) from public.reorder_pending p where p.customer_id = $1 and p.status = ''open'' order by p.created_at limit 1)',
  'Number of items in the open reorder nudge', false)
on conflict (key) do update
  set label = excluded.label, sql_expr = excluded.sql_expr,
      description = excluded.description, needs_order = excluded.needs_order;

insert into public.wa_tokens(key, label, source_kind, source_ref, group_label, format, fallback, example, sort_order)
values
 ('reorder_amount', 'Reorder value (same as last time)', 'computed', 'reorder_pending_amount', 'Reorder', 'money', '', 'Rs 12,447', 90),
 ('reorder_items',  'Reorder item count',                'computed', 'reorder_pending_items',  'Reorder', 'plain', '',  '6', 91)
on conflict (key) do update
  set label = excluded.label, source_kind = excluded.source_kind,
      source_ref = excluded.source_ref, format = excluded.format;

-- ─── 2. Template seeds for the two reorder routes ───────────────────────────
-- The buttons carry the exact words the inbound switchboard matches on, so a
-- tap on either button routes straight into reorder_confirm / reorder_skip.
insert into public.wa_event_template_seeds(name, language, category, components, token_map)
values
 ('reorder_due', 'en', 'MARKETING',
  jsonb_build_array(
    jsonb_build_object(
      'type','BODY',
      'text','Hi {{1}}, your usual order is due — {{2}} items, about {{3}}, same as last time. Tap Reorder YES and we will build the order for you, or Reorder SKIP to skip this time.',
      'example', jsonb_build_object('body_text', jsonb_build_array(
        jsonb_build_array('Chandra Medicom','6','Rs 12,447')))),
    jsonb_build_object('type','FOOTER','text','mediBO — B2B pharmacy supply'),
    jsonb_build_object('type','BUTTONS','buttons', jsonb_build_array(
      jsonb_build_object('type','QUICK_REPLY','text','Reorder YES'),
      jsonb_build_object('type','QUICK_REPLY','text','Reorder SKIP')))),
  jsonb_build_array('customer_name','reorder_items','reorder_amount')),
 ('reorder_confirmed', 'en', 'UTILITY',
  jsonb_build_array(
    jsonb_build_object(
      'type','BODY',
      'text','Hi {{1}}, we have rebuilt your order — {{2}} items, about {{3}}. Our team will confirm availability and pricing shortly.',
      'example', jsonb_build_object('body_text', jsonb_build_array(
        jsonb_build_array('Chandra Medicom','6','Rs 12,447')))),
    jsonb_build_object('type','FOOTER','text','mediBO — B2B pharmacy supply')),
  jsonb_build_array('customer_name','reorder_items','reorder_amount'))
on conflict (name) do nothing;

update public.wa_event_routes
   set auto_template_name = 'reorder_due',
       language           = coalesce(language, 'en'),
       variable_map       = jsonb_build_array('{{customer_name}}','{{reorder_items}}','{{reorder_amount}}'),
       description        = 'Monthly reorder nudge — customer replies YES to reorder or SKIP',
       updated_at         = now()
 where event_key = 'reorder_due';

update public.wa_event_routes
   set auto_template_name = 'reorder_confirmed',
       language           = coalesce(language, 'en'),
       variable_map       = jsonb_build_array('{{customer_name}}','{{reorder_items}}','{{reorder_amount}}'),
       description        = 'Sent when a WhatsApp YES rebuilt the customer''s order',
       updated_at         = now()
 where event_key = 'reorder_confirmed';

-- ─── 3. Low-stock: shelf level counts too, opt-in still respected ───────────
-- A pharmacy that set a shelf level is telling us when to nudge; one that only
-- flipped the reminder on is nudged on cadence. Both paths open the same
-- pending row, so the inbound reply handler works for either.
create or replace function public.reorder_lowstock_check()
returns integer language plpgsql security definer set search_path to 'public' as $$
declare p record; v_items jsonb; v_pid uuid; n int := 0;
begin
  for p in
    select distinct customer_id from public.reorder_prefs where notify = true
  loop
    select coalesce(jsonb_agg(jsonb_build_object(
             'product_id', cd.product_id, 'qty', cd.usual_qty, 'name', cd.name)), '[]'::jsonb)
      into v_items
      from public._reorder_cadence(p.customer_id) cd
      join public.reorder_prefs rp
        on rp.customer_id = p.customer_id and rp.product_id = cd.product_id and rp.notify = true
     where cd.supplier_count >= 1
       and ( cd.due
             -- a shelf level the pharmacy set: nudge once the quantity they
             -- usually buy no longer covers the shelf they want to hold.
             or (rp.shelf_level is not null and cd.usual_qty <= rp.shelf_level) );
    if v_items <> '[]'::jsonb then
      v_pid := public._reorder_open_pending(p.customer_id, 'lowstock', v_items, null);
      if v_pid is not null then
        perform public.wa_send_event('reorder_due', p.customer_id, jsonb_build_object(), null, null);
        n := n + 1;
      end if;
    end if;
  end loop;
  return n;
end $$;

-- ─── 4. Suggestions carry each item's reminder state (feature 3 frontend) ───
create or replace function public.reorder_suggestions()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
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
             'predicted_label', case when c.predicted_next is not null
                    then public._reorder_uic('reorder.next_prefix','Next ~ ') ||
                         to_char(c.predicted_next,'DD Mon') else '' end,
             'price_display', public._reorder_money(c.mrp),
             'can_add', (c.supplier_count >= 1),
             'unavailable_label', case when c.supplier_count >= 1 then ''
                    else public._reorder_uic('reorder.unavailable','Currently unavailable') end,
             -- CHANGE #173B — low-stock reminder state, rendered not decided.
             'remind_on', coalesce(rp.notify, false),
             'remind_label', case when coalesce(rp.notify,false)
                    then public._reorder_uic('reorder.remind_on','Reminder on')
                    else public._reorder_uic('reorder.remind_off','Remind me') end,
             'shelf_level', rp.shelf_level,
             'shelf_label', case when rp.shelf_level is not null
                    then public._reorder_uic('reorder.shelf_prefix','Shelf level ') || rp.shelf_level::text
                    else '' end
           ) as row,
           -- due first, then most-overdue, then most-frequent
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
end $$;

-- prefs_set answers with the refreshed screen, so nothing is recomputed client side.
create or replace function public.reorder_prefs_set(
  p_product_id text, p_shelf_level int default null, p_notify boolean default true)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_cust uuid;
begin
  v_cust := public.my_customer_id();
  if v_cust is null then
    return jsonb_build_object('ok', false, 'message', public._reorder_uic('reorder.login','Please log in'));
  end if;
  insert into public.reorder_prefs(customer_id, product_id, shelf_level, notify, updated_at)
  values (v_cust, p_product_id, p_shelf_level, coalesce(p_notify,true), now())
  on conflict (customer_id, product_id) do update
    set shelf_level=excluded.shelf_level, notify=excluded.notify, updated_at=now();
  return jsonb_build_object('ok', true,
    'message', case when coalesce(p_notify,true)
                    then public._reorder_uic('reorder.pref_saved','Reorder reminder saved')
                    else public._reorder_uic('reorder.pref_cleared','Reorder reminder turned off') end,
    'suggestions', public.reorder_suggestions());
end $$;

-- ─── 5. Admin surface: view every auto-reorder + nudge, and manage them ─────
create or replace function public.reorder_admin_overview()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_subs jsonb; v_pend jsonb; v_active int; v_open int; v_custs int;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false,
      'message', public._reorder_uic('reorder.admin_denied','Admins only'));
  end if;

  select count(*) filter (where status='active') into v_active from public.reorder_subscriptions;
  select count(*) into v_open from public.reorder_pending where status='open';
  select count(distinct customer_id) into v_custs from public.reorder_subscriptions where status='active';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id,
           'customer', coalesce(pp.pharmacy_name, '—'),
           'cadence_label', public._reorder_uic('reorder.every','Every ') || s.cadence_days::text
                            || ' ' || public._reorder_uic('reorder.days','days'),
           'items_label', jsonb_array_length(s.items)::text || ' ' || public._reorder_uic('reorder.items','items'),
           'next_label', public._reorder_uic('reorder.next_run','Next: ') || to_char(s.next_run_date,'DD Mon'),
           'status_label', case s.status
                             when 'active' then public._reorder_uic('reorder.sub_active','Active')
                             when 'paused' then public._reorder_uic('reorder.sub_paused','Paused')
                             else public._reorder_uic('reorder.sub_cancelled','Cancelled') end,
           'status_tone', case s.status when 'active' then 'success'
                                        when 'paused' then 'warning' else 'neutral' end,
           'actions', case s.status
                        when 'active' then jsonb_build_array(
                          jsonb_build_object('key','pause','label', public._reorder_uic('reorder.pause','Pause')),
                          jsonb_build_object('key','cancel','label', public._reorder_uic('reorder.cancel','Cancel')))
                        when 'paused' then jsonb_build_array(
                          jsonb_build_object('key','resume','label', public._reorder_uic('reorder.resume','Resume')),
                          jsonb_build_object('key','cancel','label', public._reorder_uic('reorder.cancel','Cancel')))
                        else '[]'::jsonb end)
         order by s.status, s.next_run_date), '[]'::jsonb)
    into v_subs
  from public.reorder_subscriptions s
  left join public.pharmacy_profiles pp on pp.id = s.customer_id
  where s.status <> 'cancelled';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id,
           'customer', coalesce(pp.pharmacy_name, '—'),
           'kind_label', case p.kind
                           when 'subscription' then public._reorder_uic('reorder.kind_sub','Auto-reorder')
                           when 'lowstock' then public._reorder_uic('reorder.kind_low','Low stock')
                           else public._reorder_uic('reorder.kind_pred','Predicted') end,
           'items_label', jsonb_array_length(p.items)::text || ' ' || public._reorder_uic('reorder.items','items'),
           'amount_display', public._reorder_money(p.amount),
           'age_label', (current_date - (p.created_at at time zone 'Asia/Kolkata')::date)::text
                        || ' ' || public._reorder_uic('reorder.days_ago','days ago'),
           'status_label', public._reorder_uic('reorder.pending_open','Waiting for reply'),
           'status_tone', 'warning')
         order by p.created_at desc), '[]'::jsonb)
    into v_pend
  from public.reorder_pending p
  left join public.pharmacy_profiles pp on pp.id = p.customer_id
  where p.status = 'open';

  return jsonb_build_object(
    'ok', true,
    'title', public._reorder_uic('reorder.admin_title','Reorder & auto-reorders'),
    'stats', jsonb_build_array(
      jsonb_build_object('label', public._reorder_uic('reorder.admin_stat_active','Active auto-reorders'), 'value', v_active::text),
      jsonb_build_object('label', public._reorder_uic('reorder.admin_stat_open','Awaiting WhatsApp reply'), 'value', v_open::text),
      jsonb_build_object('label', public._reorder_uic('reorder.admin_stat_custs','Customers subscribed'), 'value', v_custs::text)),
    'subs_title', public._reorder_uic('reorder.admin_subs','Auto-reorders'),
    'subs', v_subs,
    'subs_empty', public._reorder_uic('reorder.admin_subs_empty','No auto-reorders yet'),
    'pending_title', public._reorder_uic('reorder.admin_pending','Open reorder nudges'),
    'pending', v_pend,
    'pending_empty', public._reorder_uic('reorder.admin_pending_empty','Nothing waiting for a reply'));
end $$;

create or replace function public.reorder_admin_sub_update(p_id uuid, p_action text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_new text;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false,
      'message', public._reorder_uic('reorder.admin_denied','Admins only'));
  end if;
  v_new := case lower(coalesce(p_action,''))
             when 'pause' then 'paused' when 'resume' then 'active'
             when 'cancel' then 'cancelled' else null end;
  if v_new is null then
    return jsonb_build_object('ok', false, 'message', 'bad_action');
  end if;
  update public.reorder_subscriptions
     set status = v_new, updated_at = now(),
         next_run_date = case when v_new='active' then current_date + cadence_days else next_run_date end
   where id = p_id;
  if not found then
    return jsonb_build_object('ok', false,
      'message', public._reorder_uic('reorder.sub_not_found','Auto-reorder not found'));
  end if;
  return public.reorder_admin_overview();
end $$;

-- ─── 6. Copy for everything added above ─────────────────────────────────────
insert into public.ui_copy(key, value) values
 ('reorder.remind_on', to_jsonb('Reminder on'::text)),
 ('reorder.remind_off', to_jsonb('Remind me'::text)),
 ('reorder.shelf_prefix', to_jsonb('Shelf level '::text)),
 ('reorder.remind_title', to_jsonb('Low-stock reminder'::text)),
 ('reorder.remind_note', to_jsonb('We will message you on WhatsApp before you run out, so you can reorder in one reply.'::text)),
 ('reorder.shelf_hint', to_jsonb('Shelf level (optional) — units you like to keep in stock'::text)),
 ('reorder.remind_save', to_jsonb('Save reminder'::text)),
 ('reorder.remind_clear', to_jsonb('Turn reminder off'::text)),
 ('reorder.pref_cleared', to_jsonb('Reorder reminder turned off'::text)),
 ('reorder.admin_title', to_jsonb('Reorder & auto-reorders'::text)),
 ('reorder.admin_denied', to_jsonb('Admins only'::text)),
 ('reorder.admin_stat_active', to_jsonb('Active auto-reorders'::text)),
 ('reorder.admin_stat_open', to_jsonb('Awaiting WhatsApp reply'::text)),
 ('reorder.admin_stat_custs', to_jsonb('Customers subscribed'::text)),
 ('reorder.admin_subs', to_jsonb('Auto-reorders'::text)),
 ('reorder.admin_subs_empty', to_jsonb('No auto-reorders yet'::text)),
 ('reorder.admin_pending', to_jsonb('Open reorder nudges'::text)),
 ('reorder.admin_pending_empty', to_jsonb('Nothing waiting for a reply'::text)),
 ('reorder.pending_open', to_jsonb('Waiting for reply'::text)),
 ('reorder.kind_sub', to_jsonb('Auto-reorder'::text)),
 ('reorder.kind_low', to_jsonb('Low stock'::text)),
 ('reorder.kind_pred', to_jsonb('Predicted'::text)),
 ('reorder.admin_entry', to_jsonb('Reorder & auto-reorders'::text)),
 ('reorder.admin_entry_note', to_jsonb('Auto-reorders, low-stock nudges and WhatsApp replies'::text))
on conflict (key) do nothing;

grant execute on function public.reorder_admin_overview() to authenticated;
grant execute on function public.reorder_admin_sub_update(uuid, text) to authenticated;

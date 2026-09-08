-- CHANGE #713 (final) — the doors, DECLARED, and the customer's own way in.
--
-- A screen with no declared route is a tile with no door (#570, #821): the
-- widget compiles, the RPC answers, and every tap falls through the shell's
-- switch into the backend-worded "route unavailable" branch. So the door is
-- registered on surface_route and handled by shellExtraRouteScreen(), where
-- the shell already looks, and rg_check's c821_shell_doors target can see it.

insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values
  ('order_threads', 'partner.order_threads', 'feature', 'home_shell',
   'CHANGE #713 — customer messages waiting on an answer, plus the calls '
   'somebody owes a customer. Opened by shellExtraRouteScreen() in '
   'lib/screens/shell/shell_extra_routes.dart. thread_inbox() answers a '
   'partner with their own zone and the office with all of them and refuses '
   'anyone who is neither, so the door is not the guard.',
   true)
on conflict (route_key, feature_key) do update
   set kind       = excluded.kind,
       handled_by = excluded.handled_by,
       note       = excluded.note,
       is_active  = excluded.is_active,
       updated_at = now();

-- The nav tile. badge_source is the nav_badge_counts() key added in (6/8), so
-- the count on the tile and the rows in the screen come from ONE clamp.
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface,
   roles_allowed, deep_link, search_terms, description,
   partner_feature_key, canonical_key, badge_source, badge_noun)
values
  ('partner.order_threads', 'Customer messages', 'Support', 'forum',
   'order_threads', 6, 'partner', true, 'write', true, 'orders', 'dashboard',
   '{admin,super_admin}', '/admin/go/order_threads',
   'message thread chat support ticket reply sla escalation call back whatsapp',
   'Every customer message on an order, who owns it, and the calls somebody owes a customer.',
   'partner.order_threads', 'partner.order_threads',
   'customer_threads', 'messages waiting')
on conflict (feature_key) do update
  set label          = excluded.label,
      group_label    = excluded.group_label,
      route_key      = excluded.route_key,
      icon_key       = excluded.icon_key,
      sort_order     = excluded.sort_order,
      owner          = excluded.owner,
      partner_eligible = excluded.partner_eligible,
      default_access = excluded.default_access,
      is_active      = true,
      category       = excluded.category,
      surface        = excluded.surface,
      roles_allowed  = excluded.roles_allowed,
      deep_link      = excluded.deep_link,
      search_terms   = excluded.search_terms,
      description    = excluded.description,
      badge_source   = excluded.badge_source,
      badge_noun     = excluded.badge_noun;

-- ── the customer's door, in the list the order card already draws ───────────
-- _order_customer_actions() is the backend-driven action row on every order
-- card. 'thread' joins it with its own unread badge, so the conversation is
-- one tap from the order rather than a screen the customer has to find.
create or replace function public._order_customer_actions(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_cancel jsonb; v_ret numeric; v_out jsonb := '[]'::jsonb;
        v_open_tickets int; v_returns int; v_unread int;
begin
  v_cancel := public._order_customer_cancel_gate(p_order_id);

  select count(*) into v_open_tickets from public.support_ticket
   where order_id = p_order_id and status <> 'closed';
  select count(*) into v_returns from public.order_returns where order_id = p_order_id;

  select coalesce(sum(public._return_returnable_qty(oi.id)),0) into v_ret
    from public.order_items oi where oi.order_id = p_order_id;

  -- Track already has its own backend-labelled chip on the card (CHANGE #629);
  -- this list is the doors that had none.
  if coalesce((v_cancel->>'show')::boolean, false) then
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'key', 'cancel',
      'label', coalesce(nullif(v_cancel->>'label',''), public._c('cancel.cust_action_label')),
      'enabled', coalesce((v_cancel->>'can_cancel')::boolean, false),
      'tone', 'danger',
      'badge', '',
      'note', coalesce(v_cancel->>'note','')));
  end if;

  if coalesce(v_ret,0) > 0 or v_returns > 0 then
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'key', 'returns', 'label', public._c('returns.cust_action_label'),
      'enabled', true, 'tone', 'normal',
      'badge', case when v_returns > 0 then v_returns::text else '' end,
      'note', ''));
  end if;

  -- CHANGE #713 — the order's conversation. The badge counts what WE said that
  -- this customer has not read yet, so it goes quiet the moment they open it.
  select count(*) into v_unread
    from public.order_thread t
    join public.order_thread_message m on m.thread_id = t.id
   where t.order_id = p_order_id
     and m.actor_role <> 'customer'
     and not exists (select 1 from public.order_thread_read r
                      where r.message_id = m.id and r.viewer_kind = 'customer');

  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'key', 'thread', 'label', public._c('thread.customer_action_label'),
    'enabled', true, 'tone', 'normal',
    'badge', case when coalesce(v_unread,0) > 0 then v_unread::text else '' end,
    'note', ''));

  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'key', 'help', 'label', public._c('support.order_action_label'),
    'enabled', true, 'tone', 'normal',
    'badge', case when v_open_tickets > 0 then v_open_tickets::text else '' end,
    'note', ''));

  return v_out;
end $$;

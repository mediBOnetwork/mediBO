-- CMD #1929 — the entry point, registered in the BACKEND.
--
-- The admin nav is nav_registry() over feature_registry (the Dart list this
-- command first appended to was deleted on the live base, correctly: a nav row
-- is data). So the Payment alerts row is an INSERT, its badge is one more key
-- in nav_badge_counts(), and neither needs a deploy to change again.

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface,
   badge_source, badge_noun, roles_allowed, description, search_terms)
values
  ('admin.payment_alerts',
   'Payment alerts',
   'Money',
   'phonelink_ring',
   'payment_alerts',
   45,                              -- sits with Payment UPI (40) under Money
   'medibo',
   true,                            -- the partner's own phone is what feeds it
   'none',
   true,
   'home_money',
   'dashboard',
   'payment_alerts_unmatched',
   'to check',
   array['admin','super_admin']::text[],
   'Payment notifications forwarded from the partner phone, and what each one was matched to.',
   'payment alert notification upi utr gpay phonepe paytm bhim bank credit unmatched')
on conflict (feature_key) do update set
  label            = excluded.label,
  group_label      = excluded.group_label,
  icon_key         = excluded.icon_key,
  route_key        = excluded.route_key,
  sort_order       = excluded.sort_order,
  owner            = excluded.owner,
  partner_eligible = excluded.partner_eligible,
  is_active        = excluded.is_active,
  category         = excluded.category,
  surface          = excluded.surface,
  badge_source     = excluded.badge_source,
  badge_noun       = excluded.badge_noun,
  roles_allowed    = excluded.roles_allowed,
  description      = excluded.description,
  search_terms     = excluded.search_terms;

-- The badge counts what a human still has to look at, in the caller's own
-- zone, using the SAME zone rule the screen uses — so the badge can never
-- promise work the screen then hides.
create or replace function public._pa_badge_count()
returns bigint language sql stable security definer set search_path to 'public' as $$
  select count(*)
    from public.payment_alerts a
   where a.status = 'unmatched'
     and (public.admin_active_zone() is null or a.zone_id = public.admin_active_zone());
$$;

create or replace function public.nav_badge_counts()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'pending_orders',     (select count(*) from orders where status = 'pending'),
    'flagged_bills',      (select count(*) from pending_bills where verdict in ('needs_approval','fake')),
    'pending_customers',  (select count(*) from pharmacy_profiles where coalesce(approved,false) = false),
    'deletion_requests',  (select count(*) from account_deletion_requests where status = 'pending'),
    'order_alerts',       (select count(*) from order_alert where actioned_at is null),
    'disputes',           (select count(*) from supplier_disputes where coalesce(status,'open') = 'open'),
    'contact_inquiries',  (select count(*) from contact_inquiries),
    -- CHANGE #713 — customer messages waiting on an answer, in the caller's
    -- own zone (all zones for the office). The count is the same clamp the
    -- inbox uses, so the badge can never promise work the screen then hides.
    'customer_threads',   public._thread_badge_count(),
    -- CHANGE #696 -- partner issues waiting on the caller's OWN side: a
    -- partner sees the ones the office handed back to them, the office
    -- sees every partner's. Same clamp as partner_ticket_list(), so the
    -- badge can never promise work the screen then hides.
    'partner_issues',     public._pt_badge_count(),
    -- CMD #1929 — forwarded payments nobody has matched yet.
    'payment_alerts_unmatched', public._pa_badge_count()
  );
$$;

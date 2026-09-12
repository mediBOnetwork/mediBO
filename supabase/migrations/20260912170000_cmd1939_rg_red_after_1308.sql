-- CMD #1939 — the regression guard went red after CHANGE #1308 (CMD #1929,
-- Payment alerts). Five CRITICAL behaviours failed and ZERO schema diffs were
-- reported, so nothing here is a rebaseline: a behaviour failure is a bug in
-- the code that caused it (rule: behaviour failures and missing_critical are
-- never rebaselined).
--
-- All five trace to the same migration, 20260912120000_cmd1929_payment_alerts:
--
--   c643_realtime_publication_small   supabase_realtime published 9 tables (max 8)
--   c646_registry_matches_publication payment_alert_speak published, not in the registry
--   c643_noop_updates_suppressed      payment_alert_speak had no zzz_c643_suppress_noop
--   c634_every_feature_declares_...   admin.payment_alerts has no test contract
--   c1094_staff_rpcs_are_zone_scoped  nav_badge_counts changed_still_unscoped
--
-- Idempotent: safe to replay on live, and safe to replay twice.


-- ═══════════════════════════════════════════════════════════════════════
-- 1. REALTIME — payment_alert_speak is a PULLED feed, not a published one.
-- ═══════════════════════════════════════════════════════════════════════
--
-- #1929 ran `alter publication supabase_realtime add table payment_alert_speak`
-- by hand, which is the one thing realtime_table_registry exists to stop: it
-- took the publication to 9 tables against a ceiling of 8 (realtime decodes the
-- WAL once per published table per subscriber), and it left the registry and
-- the publication disagreeing.
--
-- The feature does not need it. #1929 shipped payment_alert_speak_pull(limit),
-- which hands out the unspoken rows and stamps spoken_at — a PULL API — and no
-- client subscribes to the table: there is no realtime channel for it anywhere
-- in lib/, and payment_alerts_screen.dart reads its RPC and nothing else. So
-- the decision is recorded where every other one of these is recorded, the
-- registry, and the publication is put back to what the registry says.
insert into public.realtime_table_registry
  (table_name, live, filter_required, poll_seconds, surface, reason)
values
  ('payment_alert_speak', false, false, 15, 'admin/payment_alerts spoken queue',
   'The spoken alert is PULLED: payment_alert_speak_pull() hands out the '
   || 'unspoken rows and stamps spoken_at, and no client opens a channel on '
   || 'this table. #1929 published it anyway, which made a ninth published '
   || 'table against a ceiling of eight (CMD #1939).')
on conflict (table_name) do update set
  live            = excluded.live,
  filter_required = excluded.filter_required,
  poll_seconds    = excluded.poll_seconds,
  surface         = excluded.surface,
  reason          = excluded.reason,
  updated_at      = now();

-- realtime_publication_sync() drops whatever the registry does not mark live,
-- adds whatever it does, and installs the zzz_c643_suppress_noop trigger on
-- every published table — so this one call closes all three realtime failures.
--
-- It is GATED on the registry actually covering the publication. sync() drops
-- every published table the registry does not mention, which is right when the
-- registry is the record and wrong when the registry is merely incomplete — a
-- build branch carries the schema but not this table's rows, and running it
-- there emptied the publication outright. On live every published table has a
-- row (payment_alert_speak included, inserted above), so the gate is open and
-- exactly one table is dropped.
do $$
declare v_unknown int; v_res jsonb;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    return;                                  -- no realtime here at all
  end if;
  select count(*) into v_unknown
    from pg_publication_tables pt
   where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public'
     and not exists (select 1 from public.realtime_table_registry g
                      where g.table_name = pt.tablename);
  if v_unknown > 0 then
    raise notice 'CMD #1939: % published table(s) are not in realtime_table_registry — skipping sync so an incomplete registry cannot empty the publication', v_unknown;
    return;
  end if;
  v_res := public.realtime_publication_sync();
  raise notice 'CMD #1939: realtime_publication_sync -> %', v_res;
end $$;

-- The no-op guard is installed for its own sake too: it is what
-- c643_noop_updates_suppressed asserts, and it must hold on every published
-- table whether or not the sync above ran.
do $$ begin
  perform public.realtime_suppress_noop_install();
exception when others then null;
end $$;


-- ═══════════════════════════════════════════════════════════════════════
-- 2. c634 — admin.payment_alerts declares its test contract.
-- ═══════════════════════════════════════════════════════════════════════
--
-- #1929 inserted the feature_registry row without the four test_* columns, so
-- rg_contract_gap() reported an active feature nothing can prove. The contract
-- is the same shape every other admin screen uses: authenticate as the role,
-- open the deep link, let it settle, and expect the render log to say painted.
-- The route is real — surface_route says payment_alerts is handled by
-- home_shell, and shell_extra_routes.dart returns PaymentAlertsScreen for it.
update public.feature_registry set
  test_automatable  = true,
  test_skip_reason  = null,
  test_entry        = '/admin/go/payment_alerts',
  test_roles        = array['admin','super_admin']::text[],
  test_steps        = jsonb_build_array(
                        jsonb_build_object('kind','auth',  'role','{role}'),
                        jsonb_build_object('kind','goto',  'path','/admin/go/payment_alerts'),
                        jsonb_build_object('kind','settle','ms',6000)),
  test_expect       = jsonb_build_object(
                        'kind','visible','source','render_log',
                        'key','boot_status','equals','painted')
where feature_key = 'admin.payment_alerts';


-- ═══════════════════════════════════════════════════════════════════════
-- 3. c1094 — nav_badge_counts is zone-scoped again.
-- ═══════════════════════════════════════════════════════════════════════
--
-- nav_badge_counts() was grandfathered by zone_scope_baseline: unscoped, but
-- untouched, so it could not block. #1929 added the payment_alerts key to its
-- body, which is exactly the moment the rule stops grandfathering it
-- ('changed_still_unscoped'). Grandfathering it again is not on the table —
-- the fix is the clamp.
--
-- Every key below is judged on its own table, because a badge that promises
-- work the screen then hides is the bug this rule exists to stop:
--
--   pending_orders  orders.zone_id — ops_board, the screen it opens, clamps on
--                   coalesce(p_zone, admin_active_zone()), so the badge does too.
--   order_alerts    order_alert.zone_id — admin_alert_new_since is zone-scoped.
--   flagged_bills   pending_bills has NO zone column: supplier bills arrive by
--                   email per supplier, not per zone. Global on purpose.
--   pending_customers  a signup that has not been zoned yet (2 of the 6 open
--                   ones right now) belongs to no zone, and clamping would
--                   leave it visible to nobody. Approval is an office queue.
--   deletion_requests / disputes / contact_inquiries  office queues with no
--                   zone dimension at all.
--   customer_threads / partner_issues / payment_alerts_unmatched  already
--                   carry their own clamp inside their helper.
--
-- admin_active_zone() is NULL for the office, which is why every clamp is
-- written as "no active zone, or this row's zone" — the office count does not
-- move, and a zone-locked admin stops counting another zone's work.
create or replace function public.nav_badge_counts()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select jsonb_build_object(
    'pending_orders',     (select count(*) from orders o
                            where o.status = 'pending'
                              and (public.admin_active_zone() is null
                                   or o.zone_id = public.admin_active_zone())),
    'flagged_bills',      (select count(*) from pending_bills
                            where verdict in ('needs_approval','fake')),
    'pending_customers',  (select count(*) from pharmacy_profiles
                            where coalesce(approved,false) = false),
    'deletion_requests',  (select count(*) from account_deletion_requests where status = 'pending'),
    'order_alerts',       (select count(*) from order_alert a
                            where a.actioned_at is null
                              and (public.admin_active_zone() is null
                                   or a.zone_id = public.admin_active_zone())),
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
$fn$;

-- The DATE half is exempted, with a reason, exactly as fw_list_unfillable and
-- customer_credit_list are: a nav badge is a live backlog that DRAINS, not a
-- day's ledger that closes. Clamping it to the picked business date would make
-- yesterday's unanswered work vanish from the nav while it is still open. The
-- zone half above is not exempted and now binds.
insert into public.zone_scope_allow (fn_pattern, dimension, reason, added_by)
values ('nav_badge_counts', 'date',
        'A nav badge counts what is still open right now — a backlog that '
        || 'drains, not a day that closes. Clamping it to admin_active_date() '
        || 'would hide yesterday''s unanswered work from the nav while it is '
        || 'still waiting. The zone half binds and was added in CMD #1939.',
        'cmd-1939')
on conflict (fn_pattern) do update set
  dimension = excluded.dimension,
  reason    = excluded.reason,
  added_by  = excluded.added_by;

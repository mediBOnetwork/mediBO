-- CHANGE #646 — verify #643 end to end, and close the gaps the measurement found.
--
-- #643 (CHANGE #971) trimmed the publication to 8 tables, installed the no-op
-- guard on every published table, stripped dev_cmd_list to cards and added
-- dev_runner_tick. Measuring each of its claims found four things that were
-- still open. Every one of them is fixed here, and three new regression-guard
-- behaviours make them stay fixed.
--
-- Measured before this migration (zero customers online):
--   * pharmacy_profiles n_tup_upd over 618 s ......... +3      (target <= 5, PASS)
--   * orders            n_tup_upd over 618 s ......... +18     (target <= 5, FAIL)
--   * 400 my_session calls (admin + customer) ........ +0 rows (PASS)
--   * dev_cmd_list('completed', limit 500) ........... 369,556 bytes (target <= 50 kB, FAIL)
--   * dev_runner_tick calls in 65 min ................ 3, while /rest/v1/dev_commands
--                                                      took 4,573 requests (FAIL)
--   * admin_delivery_dashboard ....................... 42883, dead on every call (FAIL)
--
-- Idempotent throughout: a resumed worker re-applies this as a no-op.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The no-op guard reaches past the publication.
--
-- #643 installed suppress_redundant_updates_trigger() on the published tables
-- only, because the cost it was chasing was the realtime broadcast. But a
-- rewrite that changes nothing is never free: it is a dead tuple, a WAL record,
-- an autovacuum wakeup and an index churn on a 1 GB instance. `orders` is the
-- proof — unpublished since #643 and still taking 18 rewrites per ten minutes
-- with nobody using the app.
--
-- So the guard now covers the publication PLUS a named churn list, and the
-- installer is the single place that decides.
create or replace function public.realtime_noop_guard_tables()
returns table (schemaname text, tablename text)
language sql stable
set search_path = public
as $$
  select pt.schemaname::text, pt.tablename::text
    from pg_publication_tables pt
   where pt.pubname = 'supabase_realtime'
  union
  -- Not published, but hot: measured rewrite traffic with zero users online.
  select 'public'::text, t
    from unnest(array['orders','pharmacy_profiles','order_items','cron_task']) t
   where to_regclass('public.' || quote_ident(t)) is not null
$$;

comment on function public.realtime_noop_guard_tables() is
  'CHANGE #646 — every table that must carry zzz_c643_suppress_noop: the realtime publication plus the measured high-churn tables. Adding a table here is the whole change; realtime_suppress_noop_install() does the rest.';

create or replace function public.realtime_suppress_noop_install()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare t record; n int := 0;
begin
  for t in select * from public.realtime_noop_guard_tables()
  loop
    if not exists (
      select 1 from pg_trigger tg
      join pg_class c on c.oid = tg.tgrelid
      join pg_namespace ns on ns.oid = c.relnamespace
      where ns.nspname = t.schemaname and c.relname = t.tablename
        and tg.tgname = 'zzz_c643_suppress_noop'
    ) then
      execute format(
        'create trigger zzz_c643_suppress_noop before update on %I.%I '
        'for each row execute function suppress_redundant_updates_trigger()',
        t.schemaname, t.tablename);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

select public.realtime_suppress_noop_install();

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. The writer behind the `orders` rewrites.
--
-- order_unfulfilled_sweep runs every 120 s and calls order_finalize_unfulfilled
-- for every order that is not finalized yet. Its closing UPDATE was
-- unconditional: it rewrote unfulfilled_count and unfulfilled_finalized_at on
-- every pass, whether or not either value moved. The no-op guard above already
-- makes that free, but a write that was never needed should not be issued at
-- all — the guard is the floor, not the design.
create or replace function public.order_finalize_unfulfilled(p_order_id uuid, p_force boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_state jsonb; v_marked int := 0; v_unf int; v_removed numeric; v_new_total numeric;
  o orders%rowtype;
begin
  select * into o from orders where id = p_order_id;
  if o.id is null then return jsonb_build_object('ok',false,'error','order_not_found'); end if;

  v_state := public.order_inquiry_state(p_order_id);
  if not coalesce((v_state->>'inquiry_finished')::boolean,false) and not p_force then
    return jsonb_build_object('ok',false,'error','inquiry_not_finished',
      'awaiting', v_state->'awaiting', 'state', v_state);
  end if;

  with tgt as (
    select (r->>'order_item_id')::uuid as id, r->>'reason' as reason
    from jsonb_array_elements(v_state->'items') r
    where r->>'verdict' = 'unfulfillable'
  ), upd as (
    update order_items oi
       set unfulfillable = true,
           unfulfillable_reason = coalesce(t.reason,'Not available'),
           unfulfillable_at = coalesce(oi.unfulfillable_at, now())
      from tgt t
     where oi.id = t.id and oi.unfulfillable = false
    returning coalesce(oi.line_total, oi.quantity * coalesce(oi.price, oi.mrp, 0)) as removed
  )
  select count(*), coalesce(sum(removed),0) into v_marked, v_removed from upd;

  select count(*) into v_unf from order_items where order_id = p_order_id and unfulfillable;

  -- only reduce the total by what was removed THIS call; never rebuild it
  if v_marked > 0 and v_removed > 0 then
    update orders
       set total_amount = greatest(coalesce(total_amount,0) - v_removed, 0)
     where id = p_order_id;
  end if;

  -- CHANGE #646: conditional. The sweep re-reads every unfinalized order every
  -- 120 s; without this predicate each pass rewrote the same rows for ever.
  update orders
     set unfulfilled_count = v_unf,
         unfulfilled_finalized_at = coalesce(unfulfilled_finalized_at, now())
   where id = p_order_id
     and (unfulfilled_count is distinct from v_unf
          or unfulfilled_finalized_at is null);

  select total_amount into v_new_total from orders where id = p_order_id;

  return jsonb_build_object(
    'ok', true, 'order_id', p_order_id, 'order_code', o.order_code,
    'pharmacy_name', o.pharmacy_name,
    'newly_marked', v_marked,
    'removed_value', v_removed,
    'unfulfilled_count', v_unf,
    'new_total', v_new_total,
    'new_total_display', public.inr_money(coalesce(v_new_total,0)),
    'state', v_state);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. dev_cmd_list can no longer put more than 50 kB on the wire.
--
-- #643 made the row a CARD (627 kB -> ~1.7 kB per row) but left the page size
-- to the caller, so the payload still scaled without a ceiling: 'completed' at
-- limit 500 measured 369,556 bytes, and at the 50 the old rg note quotes, 89,620.
-- The Dev Queue screen asks for 25 and is fine; a runner, a script or a future
-- screen asking for more is not. The budget is enforced HERE, where the bytes
-- are, and the payload says so out loud: `truncated`, `dropped_rows` and
-- `budget_bytes` are rendered by the caller, never guessed.
create or replace function public.dev_cmd_list(
  p_status text default null,
  p_search text default null,
  p_batch  text default null,
  p_limit  int  default null,
  p_view   text default null,
  p_updated_since timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  j jsonb; v_rows jsonb; v_kept jsonb := '[]'::jsonb;
  v_view text := lower(coalesce(nullif(p_view,''),'cards'));
  v_budget int := 48000;   -- rows only; the envelope (counts, chips, meta) rides
                           -- on top and the WHOLE payload must stay under 50 kB
  v_used int := 0; v_row jsonb; v_len int; v_total int; v_trunc boolean := false;
begin
  j := public.dev_cmd_list_full(p_status, p_search, p_batch, p_limit);
  if v_view = 'full' then
    return j || jsonb_build_object('view','full','server_time', now());
  end if;

  select coalesce(jsonb_agg(public._dev_card_strip(t.r) order by t.ord), '[]'::jsonb)
    into v_rows
  from jsonb_array_elements(coalesce(j->'rows','[]'::jsonb)) with ordinality t(r, ord)
  where p_updated_since is null
     or greatest(
          coalesce((t.r->>'heartbeat_at')::timestamptz, '-infinity'::timestamptz),
          coalesce((t.r->>'finished_at')::timestamptz,  '-infinity'::timestamptz),
          coalesce((t.r->>'started_at')::timestamptz,   '-infinity'::timestamptz),
          coalesce((t.r->>'created_at')::timestamptz,   '-infinity'::timestamptz)
        ) > p_updated_since;

  v_total := jsonb_array_length(v_rows);

  -- Fill to the budget in payload order, then stop. Rows are already ordered by
  -- the list's own ranking, so a truncated page is the TOP of the list, never a
  -- random slice — and the caller is told to ask for a smaller page.
  for v_row in select value from jsonb_array_elements(v_rows)
  loop
    v_len := octet_length(v_row::text) + 1;
    if v_used + v_len > v_budget then
      v_trunc := true;
      exit;
    end if;
    v_kept := v_kept || jsonb_build_array(v_row);
    v_used := v_used + v_len;
  end loop;

  return jsonb_set(j, '{rows}', v_kept)
         || jsonb_build_object(
              'view','cards',
              'is_delta', (p_updated_since is not null),
              'updated_since', p_updated_since,
              'row_count', jsonb_array_length(v_kept),
              'truncated', v_trunc,
              'dropped_rows', v_total - jsonb_array_length(v_kept),
              'budget_bytes', v_budget,
              'server_time', now());
end $$;

comment on function public.dev_cmd_list(text,text,text,int,text,timestamptz) is
  'CHANGE #646 — cards, capped at a 50 kB payload whatever p_limit says. dev_cmd_list was 19,592 calls a day and the single largest line in a 36 GB egress bill; a page that cannot be bounded by its caller is bounded here.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. One fleet poll instead of six-plus REST reads every 20 s.
--
-- dev_runner_tick(agent) exists since #643 and works, but it answers for ONE
-- slot; the supervisor loop needs the whole fleet, so it kept doing what it
-- always did — queue depth, per-route depth, building count, one read per slot
-- and the android queue, as separate PostgREST calls, every 20 seconds.
-- Measured over 65 minutes: 4,573 requests to /rest/v1/dev_commands against 3
-- to dev_runner_tick. This is that call.
create or replace function public.dev_supervisor_tick(
  p_agents text[] default '{}',
  p_routes text[] default array['fast','sonnet','opus'])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_ctl jsonb; v_slots jsonb; v_routes jsonb;
begin
  perform _dev_guard();

  v_ctl := public.dev_ctl_get();

  select coalesce(jsonb_object_agg(a.agent, coalesce(b.row_json, 'null'::jsonb)), '{}'::jsonb)
    into v_slots
  from unnest(coalesce(p_agents,'{}')) a(agent)
  left join lateral (
    select jsonb_build_object(
             'id', c.id, 'title', c.title, 'model', c.model, 'effort', c.effort,
             'eta_left_s', c.eta_left_s, 'started_at', c.started_at,
             'heartbeat_at', c.heartbeat_at) as row_json
      from dev_commands c
     where c.status = 'building' and c.claimed_by = a.agent
     order by c.heartbeat_at desc nulls last
     limit 1
  ) b on true;

  select coalesce(jsonb_object_agg(r.route, coalesce(k.n, 0)), '{}'::jsonb)
    into v_routes
  from unnest(coalesce(p_routes,'{}')) r(route)
  left join lateral (
    select count(*)::int n from dev_commands c
     where c.status = 'pending' and c.route = r.route
  ) k on true;

  return jsonb_build_object(
    'ok', true,
    'server_time', now(),
    'ctl', v_ctl,
    'workflow', coalesce(v_ctl #>> '{desired_state,workflow}', 'on'),
    'active_host', coalesce(nullif(v_ctl #>> '{pool,config,active_host}',''),
                            (select value #>> '{active_host}' from dev_runner_config
                              where key = 'worker_pool'), ''),
    'pending_count',  (select count(*)::int from dev_commands where status = 'pending'),
    'building_count', (select count(*)::int from dev_commands where status = 'building'),
    'android_requested',
      (select count(*)::int from dev_commands where android_status = 'requested'),
    'pending_by_route', v_routes,
    'slots', v_slots);
end $$;

comment on function public.dev_supervisor_tick(text[],text[]) is
  'CHANGE #646 — the supervisor loop in ONE call. It replaces queue depth + per-route depth + building count + one read per slot + the android queue, which were separate /rest/v1/dev_commands reads every 20 s (measured: 4,573 requests/hour).';

grant execute on function public.dev_supervisor_tick(text[],text[]) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. admin_delivery_dashboard has been dead, and nothing noticed.
--
-- It runs with `search_path = books, public`, and books.deliveries /
-- books.orders are views (the same columns, minus synthetic rows). So the SLA
-- block handed a books.deliveries row to public._sla_block(public.deliveries)
-- and Postgres answered 42883 — "function public._sla_block(deliveries) does
-- not exist" — on every single call. Measured: 8 x 404 in an hour, i.e. every
-- attempt to open the admin delivery screen.
--
-- The fix names the schema for the one block that needs the table's own row
-- type, and keeps the synthetic-row filter the books view was providing, so the
-- SLA figures still match the tiles beside them.
create or replace function public.admin_delivery_dashboard(p_date date default null, p_zone smallint default null)
returns jsonb
language plpgsql
security definer
set search_path = books, public
as $$
declare v_date date; v_zone smallint; v_tiles jsonb; v_riders jsonb; v_zname text;
        v_sla jsonb; v_money jsonb;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('allowed',false);
  end if;
  v_date := public.scope_date(p_date);
  v_zone := public.scope_zone(p_zone);
  select name into v_zname from zones where id = v_zone;

  select jsonb_build_object(
    'assigned',   count(*) filter (where d.status='assigned'),
    'out',        count(*) filter (where d.status='out_for_delivery'),
    'delivered',  count(*) filter (where d.status='delivered'),
    'failed',     count(*) filter (where d.status='failed'),
    'rto',        count(*) filter (where d.status='rto'),
    'unaccepted', count(*) filter (where d.accept_status='pending' and d.status='assigned'),
    'uncollected', count(*) filter (where d.handover_at is null
                                      and d.status in ('assigned','out_for_delivery')),
    'total',      count(*))
    into v_tiles
  from deliveries d join orders o on o.id=d.order_id
  where (o.created_at at time zone 'Asia/Kolkata')::date = v_date
    and public.scope_zone_ok(coalesce(d.zone_id, o.zone_id), v_zone);

  -- CHANGE #646: public.deliveries, so `d` carries the row type
  -- public._sla_block() is declared against. The books views exist only to drop
  -- synthetic rows, so that filter is written out here instead.
  select jsonb_build_object(
    'on_time',      count(*) filter (where s.state = 'on_time'),
    'breached',     count(*) filter (where s.state = 'breached'),
    'in_flight',    count(*) filter (where s.state in ('pending','due_soon')),
    'measured',     count(*) filter (where s.state in ('on_time','breached')),
    'on_time_pct',  case when count(*) filter (where s.state in ('on_time','breached')) = 0 then null
                         else round(100.0 * count(*) filter (where s.state='on_time')
                              / count(*) filter (where s.state in ('on_time','breached'))) end,
    'on_time_label',case when count(*) filter (where s.state in ('on_time','breached')) = 0 then '—'
                         else round(100.0 * count(*) filter (where s.state='on_time')
                              / count(*) filter (where s.state in ('on_time','breached')))::text || '%' end,
    'title',        public._c('admin.delivery.sla_title'),
    'on_time_caption',  public._c('admin.delivery.sla_ontime'),
    'breached_caption', public._c('admin.delivery.sla_breached'),
    'pending_caption',  public._c('admin.delivery.sla_pending'))
    into v_sla
  from public.deliveries d
  join public.orders o on o.id = d.order_id
  cross join lateral (select public._sla_block(d) b) x
  cross join lateral (select (x.b->>'state') state) s
  where (o.created_at at time zone 'Asia/Kolkata')::date = v_date
    and not coalesce(d.is_synthetic, false)
    and not coalesce(o.is_synthetic, false)
    and public.scope_zone_ok(coalesce(d.zone_id, o.zone_id), v_zone);

  select jsonb_build_object(
    'charged',       coalesce(sum(coalesce(o.delivery_charge,0)),0),
    'charged_label', public.inr_money(coalesce(sum(coalesce(o.delivery_charge,0)),0)),
    'cost',          coalesce(sum(coalesce(d.cost_amount,0)),0),
    'cost_label',    public.inr_money(coalesce(sum(coalesce(d.cost_amount,0)),0)),
    'margin',        coalesce(sum(coalesce(o.delivery_charge,0) - coalesce(d.cost_amount,0)),0),
    'margin_label',  public.inr_money(coalesce(sum(coalesce(o.delivery_charge,0) - coalesce(d.cost_amount,0)),0)))
    into v_money
  from deliveries d join orders o on o.id=d.order_id
  where (o.created_at at time zone 'Asia/Kolkata')::date = v_date
    and public.scope_zone_ok(coalesce(d.zone_id, o.zone_id), v_zone);

  select coalesce(jsonb_agg(jsonb_build_object(
      'partner_id',p.id,'name',p.full_name,'phone',coalesce(p.phone,''),
      'type_label', case when p.partner_type='agency' then 'Agency' else 'Delivery boy' end,
      'assigned',s.assigned,'delivered',s.delivered,'failed',s.failed,'pending',s.pending,
      'success_rate', case when (s.delivered+s.failed)=0 then null
                           else round(100.0*s.delivered/(s.delivered+s.failed)) end,
      'success_label', case when (s.delivered+s.failed)=0 then '—'
                            else round(100.0*s.delivered/(s.delivered+s.failed))::text||'%' end,
      'avg_minutes', s.avg_min,
      'rating_label_caption', public._c('admin.delivery.rating_col'),
      'rating_avg',   rt.avg_stars,
      'rating_label', case when rt.n = 0 then public._c('admin.delivery.rating_none')
                           else to_char(rt.avg_stars,'FM90.0') || ' ★ (' || rt.n || ')' end,
      'rating_count', rt.n,
      'docs', public.delivery_doc_state(p.id),
      'last_seen', l.updated_at, 'lat', l.lat, 'lng', l.lng
    ) order by s.delivered desc, p.full_name), '[]'::jsonb)
    into v_riders
  from delivery_partner_registrations p
  left join delivery_partner_locations l on l.partner_id=p.id
  cross join lateral (
    select count(*) filter (where d.status='assigned')::int assigned,
           count(*) filter (where d.status='delivered')::int delivered,
           count(*) filter (where d.status='failed')::int failed,
           count(*) filter (where d.status in ('assigned','out_for_delivery'))::int pending,
           round(avg(extract(epoch from (d.delivered_at - d.started_at))/60)
                 filter (where d.delivered_at is not null and d.started_at is not null))::int avg_min
    from deliveries d join orders o on o.id=d.order_id
    where d.partner_id=p.id and (o.created_at at time zone 'Asia/Kolkata')::date=v_date) s
  cross join lateral (
    select count(*)::int n, round(avg(stars)::numeric,1) avg_stars
      from delivery_ratings dr
     where dr.partner_id = p.id and dr.created_at > now() - interval '90 days') rt
  where p.is_active and coalesce(p.is_deleted,false)=false
    and public.scope_zone_ok(p.zone_id, v_zone);

  return jsonb_build_object('allowed',true,'the_date',v_date,
    'zone_id', v_zone, 'zone_label', coalesce(v_zname,'All zones'),
    'tiles',v_tiles,'riders',v_riders,
    'sla', v_sla,
    'delivery_money', v_money,
    'fail_reasons', public.delivery_fail_reason_list());
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Three new regression-guard behaviours.
--
-- #643's rules covered the publication size, the no-op trigger and the
-- dev_cmd_list page of 25. The spec for this command asks for two more and a
-- stronger version of one, so that every number proven above is proven again on
-- every scheduled run instead of once, by hand, today.

insert into rg_behavior_tests (name, enabled, note, body) values
('c646_my_session_no_unconditional_update', true,
 'CHANGE #646 — my_session() runs on every poll of every signed-in device. An UPDATE without a WHERE anywhere in its call graph rewrites the whole table on every poll: that is what turned 10 pharmacy_profiles rows into 45,550 UPDATEs. The rule walks the graph from my_session and reads the actual statements, so it catches a NEW callee too.',
$c646a$
do $rg$
declare v_bad text;
begin
  with recursive graph(oid, proname, src, depth) as (
    select p.oid, p.proname::text,
           regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), 0
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'my_session'
    union
    select c.oid, c.proname::text,
           regexp_replace(c.prosrc, '--[^\n]*', '', 'g'), g.depth + 1
      from graph g
      join pg_proc c on c.prokind = 'f'
      join pg_namespace cn on cn.oid = c.pronamespace and cn.nspname = 'public'
     where g.depth < 6
       and c.oid <> g.oid
       and g.src ~ ('\m' || c.proname || '[[:space:]]*\(')
  ),
  stmts as (
    -- An UPDATE statement, up to its terminating semicolon. `\y` is a word
    -- BOUNDARY; `\m` is a word START, so the closing `\m` this rule was first
    -- written with could never match (nothing starts a word straight after
    -- "where") and every statement read as unconditional. The table may carry
    -- an alias, and `set` must follow it — which is also what keeps
    -- `on conflict ... do update set` and the words "update your details" out
    -- of a rule about unconditional writes.
    select g.proname,
           (regexp_matches(g.src,
              '\yupdate\y[[:space:]]+(?:only[[:space:]]+)?(?:public\.)?'
              '"?[a-zA-Z_][a-zA-Z0-9_]*"?'
              '(?:[[:space:]]+(?:as[[:space:]]+)?[a-zA-Z_][a-zA-Z0-9_]*)?'
              '[[:space:]]+set[[:space:]][^;]*?;',
              'gi'))[1] as stmt
      from graph g
  )
  select string_agg(distinct proname, ', ' order by proname) into v_bad
    from stmts
   where stmt !~* '\ywhere\y';

  if v_bad is not null then
    raise exception
      'C646: an UPDATE with no WHERE lives in my_session''s call graph (%). my_session runs on every poll of every device — an unconditional write there rewrites the whole table every time (CHANGE #643: 10 rows, 45,550 UPDATEs). Narrow it, and prefer IS DISTINCT FROM so a no-op writes nothing at all.',
      v_bad;
  end if;
  raise exception 'RG_ROLLBACK';
end $rg$;
$c646a$)
on conflict (name) do update
  set enabled = excluded.enabled, note = excluded.note, body = excluded.body;

insert into rg_behavior_tests (name, enabled, note, body) values
('c646_dev_cmd_list_every_status_small', true,
 'CHANGE #646 — #643''s rule measured ONE page (25 rows, no status filter). Measured on the live database before this change: ''completed'' at limit 500 returned 369,556 bytes and at limit 50 returned 89,620. dev_cmd_list is now capped at 50 kB internally; this asserts the cap holds for every status, at a page size no caller should be able to exceed.',
$c646b$
do $rg$
declare s text; n int; v_worst text := ''; v_max int := 0;
begin
  perform set_config('request.jwt.claim',  '', true);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);

  foreach s in array array['pending','building','completed','failed','needs_input','cancelled',null]
  loop
    select length(public.dev_cmd_list(s, null, null, 500)::text) into n;
    if n > v_max then v_max := n; v_worst := coalesce(s,'(all)'); end if;
  end loop;

  if v_max > 51200 then
    raise exception
      'C646: dev_cmd_list(%, limit 500) is % bytes (max 51200). The cards view carries its own 50 kB budget — if this is red the budget was removed or a detail key was added back to _dev_card_keys(). dev_cmd_list runs ~19,600 times a day; it was the largest single line in a 36 GB egress bill.',
      v_worst, v_max;
  end if;
  raise exception 'RG_ROLLBACK';
end $rg$;
$c646b$)
on conflict (name) do update
  set enabled = excluded.enabled, note = excluded.note, body = excluded.body;

insert into rg_behavior_tests (name, enabled, note, body) values
('c646_registry_matches_publication', true,
 'CHANGE #646 — realtime_table_registry is what the app''s LiveFeed obeys; supabase_realtime is what the database actually publishes. If they disagree, a screen either opens a channel on a table nobody publishes (a feed that silently never fires) or a published table pays WAL decoding for nobody. Three screens still bind postgres_changes directly (user_state, wa_chat, wa_home) and this is what keeps their tables alive.',
$c646c$
do $rg$
declare v_only_pub text; v_only_reg text;
begin
  select string_agg(t, ', ' order by t) into v_only_pub
    from (select pt.tablename t from pg_publication_tables pt
           where pt.pubname = 'supabase_realtime'
          except
          select r.table_name from realtime_table_registry r where r.live) q(t);

  select string_agg(t, ', ' order by t) into v_only_reg
    from (select r.table_name from realtime_table_registry r where r.live
          except
          select pt.tablename from pg_publication_tables pt
           where pt.pubname = 'supabase_realtime') q(t);

  if v_only_pub is not null or v_only_reg is not null then
    raise exception
      'C646: the realtime registry and the publication disagree — published but not live in the registry: [%]; live in the registry but not published: [%]. One of the two was edited alone. Set live in realtime_table_registry and run realtime_publication_sync().',
      coalesce(v_only_pub,'-'), coalesce(v_only_reg,'-');
  end if;
  raise exception 'RG_ROLLBACK';
end $rg$;
$c646c$)
on conflict (name) do update
  set enabled = excluded.enabled, note = excluded.note, body = excluded.body;

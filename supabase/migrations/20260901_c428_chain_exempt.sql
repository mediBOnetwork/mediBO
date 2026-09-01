-- CHANGE #428 — the conflict scheduler stops serialising the queue.
--
-- #327 decided collisions in SQL before a worker booted, and that was right.
-- What was wrong was WHAT it called a collision. `dev_cmd_predict_files` maps a
-- spec to paths through `file_predict_rule`, and those rules fire on words that
-- appear in nearly every feature spec — "route", "boot", "entry point",
-- "dashboard", "bill", "gst". So almost every pending command predicted
-- home_shell.dart / admin_nav_entries.dart / cust_pay_panel.dart, every command
-- overlapped every other command, and `dev_cmd_autochain` chained the lot.
--
-- Measured on the live queue the morning this landed: 28 pending commands, 27
-- of them chained, #427 carrying 20 blockers, exactly ONE command claimable —
-- while 2 of 5 runners sat idle with a full queue. Parallelism was dead, and it
-- was dead silently.
--
-- Two causes, both the same mistake — treating a SHARED surface as a conflict:
--
--   1. Shared append-only files. feature_registry seeds, nav registration,
--      notify/wa event routes, ui_copy keys, scheduled_tasks registrations and
--      add-only migrations are APPENDED to by nearly every feature. Two
--      commands appending different rows to the same registry is not a
--      conflict — the #324 merge queue merges exactly that, and merging it is
--      its job.
--   2. A glob prediction. `lib/screens/supplier/%` is an AREA HINT, not a file
--      identity: it cannot name the file two commands would both write. 11
--      pending commands predicted that one glob and were chained into a line
--      even though their real files never touch.
--
-- So a chain now needs a REAL conflict: two EXACT, non-shared paths that are
-- equal — two commands rewriting the same screen, RPC or table definition.
-- Everything else is optimistic, and file leases (`lease_try_all` /
-- `lease_try_split`) remain the runtime correctness guard underneath: two
-- writers still never share a file. The predictor can afford to be optimistic
-- precisely because the lease cannot.
--
-- Idempotent: every statement is create-if-not-exists / create-or-replace /
-- on-conflict, so a resumed worker re-applying this file is a silent no-op.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. The conflict-exempt list — DATA, so a new shared surface is one INSERT.
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.file_shared_surface (
  id          bigserial primary key,
  label       text        not null,
  path        text        not null unique,   -- exact path or a '%' glob
  kind        text        not null default 'append_only',
  reason      text        not null,          -- rendered verbatim on the card
  active      boolean     not null default true,
  note        text,
  created_at  timestamptz not null default now()
);

comment on table public.file_shared_surface is
  'CHANGE #428 — append-only surfaces that must NEVER create a dependency '
  'chain. Two commands appending to the same registry is a merge, not a '
  'conflict; the #324 merge queue handles it and file leases guard the write.';

-- Same shape as file_predict_rule / god_file_debt: RLS on, no direct read.
-- Everything reaches it through SECURITY DEFINER RPCs.
alter table public.file_shared_surface enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='file_shared_surface'
                    and policyname='file_shared_surface_no_public') then
    create policy file_shared_surface_no_public on public.file_shared_surface
      for select using (false);
  end if;
end $$;

insert into public.file_shared_surface (label, path, kind, reason) values
  ('Admin nav registration',   'lib/screens/admin/admin_nav_entries.dart',
   'append_only', 'nav entries are appended, never rewritten — the merge queue merges them'),
  ('Nav registry view',        'lib/screens/admin/nav_registry_view.dart',
   'append_only', 'feature_registry rows are appended, never rewritten'),
  ('Command palette',          'lib/screens/admin/command_palette.dart',
   'append_only', 'palette entries are appended, never rewritten'),
  ('Admin dashboard cards',    'lib/screens/admin/admin_dashboard_screen.dart',
   'append_only', 'dashboard cards are appended per feature, never rewritten'),
  ('Admin shell chrome',       'lib/screens/shell/shell_admin_chrome.dart',
   'append_only', 'admin chrome registration is append-only'),
  ('App entry / route table',  'lib/main.dart',
   'append_only', 'a new route is one appended entry — the predictor fires on the word "route" for almost every spec'),
  ('Shell routing table',      'lib/screens/home_shell.dart',
   'append_only', 'route registration is append-only; a genuine shell rewrite is still caught by the file lease'),
  ('Add-only SQL migrations',  'supabase/migrations/%',
   'append_only', 'each command writes its own timestamped file that only ADDS objects'),
  ('Backend copy strings',     'db:ui_copy',
   'append_only', 'ui_copy keys are appended per feature — a string is never a build conflict'),
  ('Feature registry rows',    'db:feature_registry',
   'append_only', 'feature_registry rows are appended per feature'),
  ('WhatsApp / notify routes', 'db:wa_event_routes',
   'append_only', 'notify() event routes are appended per event'),
  ('Scheduled task rows',      'db:scheduled_tasks',
   'append_only', 'CHANGE #305 registrations are appended per task'),
  ('Cron dispatcher rows',     'db:cron_task',
   'append_only', 'a new job is one appended cron_task row')
on conflict (path) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. Is this path a shared surface?
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.dev_path_is_shared(p_path text)
returns boolean
language sql stable
security definer
set search_path to 'public'
as $$
  -- '_' is a LIKE wildcard and every Dart filename is full of them, so only a
  -- member that actually carries '%' is treated as a glob (same rule as
  -- dev_paths_overlap), and its underscores are escaped first.
  select exists (
    select 1 from file_shared_surface s
     where s.active
       and ( s.path = p_path
          or (position('%' in s.path) > 0
              and p_path like replace(s.path, '_', '\_')) )
  );
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. The REAL conflict between two footprints.
--
--    dev_paths_overlap() stays exactly as it is — leases still use it, and a
--    lease must keep matching a glob. This is the SCHEDULER's stricter test:
--    only two exact, non-shared, equal paths are a reason to hold a command
--    back before it ever claims.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.dev_paths_conflict(a text[], b text[])
returns text[]
language sql stable
security definer
set search_path to 'public'
as $$
  select coalesce(array_agg(distinct x order by x), '{}')
    from unnest(coalesce(a,'{}')) x
    join unnest(coalesce(b,'{}')) y on y = x
   where position('%' in x) = 0        -- a glob is an area hint, not a file
     and not dev_path_is_shared(x);    -- an append-only surface is not a fight
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. The chainer, rewritten.
--    FIRST-ORDER ONLY: a command chains on its own direct conflicts and never
--    inherits its blocker's chain. CAPPED: at most `chain.max_blockers` true
--    conflicts, lowest ids first (they finish soonest, so the chain releases
--    soonest, and autochain_sweep re-derives the rest two minutes later).
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.dev_cmd_autochain(p_id bigint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r record; v_all bigint[]; v_paths text[]; v_blockers bigint[];
  v_reason text; v_tpl text; v_tpl_f text; v_max int;
  n int := 0; v_capped int := 0; v_out jsonb := '[]'::jsonb;
begin
  select coalesce((value->'chain'->>'max_blockers')::int, 3) into v_max
    from dev_runner_config where key = 'worker_pool';
  v_max := greatest(coalesce(v_max, 3), 1);

  select value#>>'{}' into v_tpl   from ui_copy where key = 'dev_queue.chain_chip';
  select value#>>'{}' into v_tpl_f from ui_copy where key = 'dev_queue.chain_chip_files';
  v_tpl   := coalesce(v_tpl,   'Queued after {ids} — same files');
  v_tpl_f := coalesce(v_tpl_f, 'Queued after {ids} — both write {files}');

  for r in
    select c.id, c.predicted_files, coalesce(c.chain_auto,'{}') as chain_auto
      from dev_commands c
     where c.status = 'pending'
       and (p_id is null or c.id = p_id)
     order by c.id
  loop
    -- Direct intersection only. `o` is judged on its FOOTPRINT (actual leases
    -- once it is building, the prediction while it is still pending) and never
    -- on what o itself is queued behind — that is what stopped a chain from
    -- growing down the whole queue.
    select coalesce(array_agg(o.id order by o.id), '{}')
      into v_all
      from dev_commands o
     where o.id < r.id
       and o.status in ('pending','building')
       and coalesce(array_length(r.predicted_files,1),0) > 0
       and coalesce(array_length(
             dev_paths_conflict(dev_cmd_footprint(o.id), r.predicted_files), 1), 0) > 0;

    v_blockers := v_all[1:v_max];

    -- the actual files the chain is about — the card names them, so a chain is
    -- never again a number nobody can argue with
    select coalesce(array_agg(distinct p order by p), '{}')
      into v_paths
      from unnest(coalesce(v_blockers,'{}')) bid,
           unnest(dev_paths_conflict(dev_cmd_footprint(bid), r.predicted_files)) p;
    if coalesce(array_length(v_all,1),0) > v_max then
      v_capped := v_capped + 1;
    end if;

    -- Drop every auto-dep this pass no longer justifies; keep manual ones.
    update dev_commands
       set depends_on = (select coalesce(array_agg(distinct d), '{}')
                           from unnest(coalesce(depends_on,'{}')) d
                          where not (d = any(r.chain_auto)) or d = any(v_blockers))
     where id = r.id;

    if coalesce(array_length(v_blockers,1),0) = 0 then
      update dev_commands set chain_auto = '{}', chain_reason = null
       where id = r.id
         and (chain_reason is not null or coalesce(chain_auto,'{}') <> '{}');
      continue;
    end if;

    v_reason := case
      when coalesce(array_length(v_paths,1),0) > 0 then
        replace(replace(v_tpl_f, '{ids}',
          (select string_agg('#'||b::text, ', ' order by b) from unnest(v_blockers) b)),
          '{files}',
          (select string_agg(regexp_replace(p, '^.*/', ''), ', ' order by p)
             from unnest(v_paths[1:3]) p))
      else
        replace(v_tpl, '{ids}',
          (select string_agg('#'||b::text, ', ' order by b) from unnest(v_blockers) b))
    end;

    update dev_commands
       set depends_on = (select coalesce(array_agg(distinct d), '{}')
                           from unnest(coalesce(depends_on,'{}') || v_blockers) d),
           chain_auto = v_blockers,
           chain_reason = v_reason
     where id = r.id;
    n := n + 1;
    v_out := v_out || jsonb_build_object('id', r.id, 'after', to_jsonb(v_blockers),
                                         'files', to_jsonb(v_paths), 'reason', v_reason);
  end loop;

  return jsonb_build_object('ok', true, 'chained', n, 'capped', v_capped,
                            'max_blockers', v_max, 'rows', v_out);
end $function$;

insert into ui_copy (key, value) values
  ('dev_queue.chain_chip_files', to_jsonb('Queued after {ids} — both write {files}'::text))
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. The watchdog. This state must never be silent again: a full queue that
--    is chained while a runner sits idle is the exact failure #428 exists to
--    end, and nobody noticed it for hours.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.dev_chain_watchdog()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  cfg jsonb; v_on boolean; v_min_chained int; v_idle_min int;
  v_chained int; v_pending int; v_state jsonb; v_now timestamptz := now();
  v_idle jsonb := '{}'::jsonb; w jsonb; v_id text; v_since timestamptz;
  v_worst_s int := 0; v_worst text; v_idle_n int := 0; v_alert boolean;
begin
  select value->'chain'->'watchdog' into cfg from dev_runner_config where key='worker_pool';
  v_on          := coalesce((cfg->>'enabled')::boolean, true);
  v_min_chained := greatest(coalesce((cfg->>'min_chained')::int, 5), 1);
  v_idle_min    := greatest(coalesce((cfg->>'idle_min')::int, 5), 1);
  if not v_on then
    return jsonb_build_object('ok', true, 'skipped', 'disabled');
  end if;

  select count(*) filter (where coalesce(chain_reason,'') <> ''), count(*)
    into v_chained, v_pending
    from dev_commands where status = 'pending';

  -- pool_state is a snapshot with no idle-since, so the watchdog keeps its own:
  -- the first tick that sees a worker idle stamps it, any non-idle tick clears
  -- it. That makes "idle for 5 minutes" a fact rather than a guess.
  select coalesce(value->'idle_since', '{}'::jsonb) into v_state
    from dev_runner_config where key = 'chain_watchdog';
  v_state := coalesce(v_state, '{}'::jsonb);

  for w in select jsonb_array_elements(coalesce(value->'workers','[]'::jsonb))
             from dev_runner_config where key = 'pool_state'
  loop
    v_id := w->>'id';
    if coalesce(w->>'status','') = 'idle' then
      v_since := coalesce((v_state->>v_id)::timestamptz, v_now);
      v_idle := v_idle || jsonb_build_object(v_id, v_since);
      v_idle_n := v_idle_n + 1;
      if extract(epoch from (v_now - v_since))::int > v_worst_s then
        v_worst_s := extract(epoch from (v_now - v_since))::int;
        v_worst := v_id;
      end if;
    end if;
  end loop;

  insert into dev_runner_config (key, value)
  values ('chain_watchdog', jsonb_build_object('idle_since', v_idle, 'checked_at', v_now))
  on conflict (key) do update set value = excluded.value;

  v_alert := v_chained >= v_min_chained and v_worst_s >= v_idle_min * 60;

  if v_alert then
    insert into rg_alerts (fingerprint, severity, kind, name, detail)
    values (md5('build_lane|chain_starvation|' || to_char(date_trunc('hour', v_now),'YYYY-MM-DD HH24')),
            'warn', 'chain_starvation',
            format('%s pending command(s) chained while %s runner(s) sit idle — %s idle for %s min',
                   v_chained, v_idle_n, coalesce(v_worst,'—'), (v_worst_s/60)),
            jsonb_build_object('chained', v_chained, 'pending', v_pending,
                               'idle_workers', v_idle_n, 'worst_worker', v_worst,
                               'worst_idle_s', v_worst_s,
                               'min_chained', v_min_chained, 'idle_min', v_idle_min))
    on conflict (fingerprint) do update
      set last_seen = now(), seen_count = rg_alerts.seen_count + 1,
          detail = excluded.detail, name = excluded.name;
  end if;

  return jsonb_build_object('ok', true, 'alert', v_alert, 'chained', v_chained,
    'pending', v_pending, 'idle_workers', v_idle_n, 'worst_worker', v_worst,
    'worst_idle_s', v_worst_s, 'min_chained', v_min_chained, 'idle_min', v_idle_min);
end $function$;

revoke all on function public.dev_chain_watchdog() from public, anon;
revoke all on function public.dev_path_is_shared(text) from anon;
revoke all on function public.dev_paths_conflict(text[], text[]) from anon;

-- config knobs (a change here is a pool_set, never a deploy)
update dev_runner_config
   set value = jsonb_set(value, '{chain}',
        coalesce(value->'chain','{}'::jsonb) ||
        jsonb_build_object(
          'max_blockers', coalesce((value->'chain'->>'max_blockers')::int, 3),
          'note', 'CHANGE #428 — only exact, non-shared, equal paths chain. '
               || 'Globs are area hints and file_shared_surface rows are append-only; '
               || 'file leases are the runtime guard.',
          'watchdog', coalesce(value->'chain'->'watchdog','{}'::jsonb) ||
            jsonb_build_object('enabled', true, 'min_chained', 5, 'idle_min', 5)),
        true)
 where key = 'worker_pool';

-- ride the ONE cron dispatcher (#273) — never a bare */N pg_cron job
insert into cron_task (name, ord, mode, work_sql, base_interval_s, max_interval_s,
                       current_interval_s, enabled, dml, note)
values ('chain_watchdog', 105, 'poll', 'select public.dev_chain_watchdog()',
        180, 600, 180, true, true,
        'CHANGE #428 — alerts when pending commands are chained while a runner idles')
on conflict (name) do update
   set work_sql = excluded.work_sql, enabled = true, note = excluded.note;

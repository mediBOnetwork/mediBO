-- CHANGE #530 — Runner crash-safe boot: the workspace doctor's record.
--
-- A VM stop mid-build left `.git/index.lock`, a half-finished rebase and an
-- in-flight row still marked `building`. The next worker booted straight into
-- that debris and every build it claimed inherited a poisoned workspace.
--
-- `boot_doctor.sh` now runs on EVERY runner start, BEFORE any claim: it repairs
-- the workspace, verifies the toolchain end to end, releases the runner's own
-- stale claims, and reports the verdict here. A red verdict means the loop
-- refuses to claim, so a broken box goes quiet instead of shipping damage.
--
-- Everything Om reads about that is worded HERE. The Dart section renders the
-- payload of `runner_boot_status()` in payload order and computes nothing.

-- ── 1. the record ───────────────────────────────────────────────────────────
create table if not exists runner_boot_event (
  id             bigserial primary key,
  at             timestamptz  not null default now(),
  host           text         not null default '',
  agent          text         not null default '',
  verdict        text         not null default 'red',   -- green | red
  boot_reason    text         not null default 'start',
  checks         jsonb        not null default '[]'::jsonb,
  repairs        jsonb        not null default '[]'::jsonb,
  released_rows  int          not null default 0,
  duration_ms    int          not null default 0,
  doctor_version text         not null default ''
);

create index if not exists runner_boot_event_at_idx on runner_boot_event (at desc);
create index if not exists runner_boot_event_agent_idx on runner_boot_event (agent, at desc);

alter table runner_boot_event enable row level security;

-- ── 2. the writer — the doctor's own report ────────────────────────────────
create or replace function runner_boot_report(
  p_agent       text,
  p_host        text,
  p_verdict     text,
  p_checks      jsonb default '[]'::jsonb,
  p_repairs     jsonb default '[]'::jsonb,
  p_released    int   default 0,
  p_duration_ms int   default 0,
  p_reason      text  default 'start',
  p_version     text  default ''
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_verdict text;
begin
  perform _dev_guard();
  -- The verdict is a two-valued fact, never free text: anything that is not
  -- literally 'green' is a refusal to claim.
  v_verdict := case when coalesce(p_verdict,'') = 'green' then 'green' else 'red' end;

  insert into runner_boot_event
    (host, agent, verdict, boot_reason, checks, repairs,
     released_rows, duration_ms, doctor_version)
  values
    (coalesce(p_host,''), coalesce(p_agent,''), v_verdict, coalesce(p_reason,'start'),
     coalesce(p_checks,'[]'::jsonb), coalesce(p_repairs,'[]'::jsonb),
     greatest(coalesce(p_released,0),0), greatest(coalesce(p_duration_ms,0),0),
     coalesce(p_version,''))
  returning id into v_id;

  -- A red boot is an operational event, not a log line: raise it where the
  -- rest of the fleet's alarms already live so it is visible without opening
  -- the card. Best-effort — a missing alerts table never fails a boot.
  if v_verdict = 'red' then
    begin
      insert into rg_alerts (level, source, message, details)
      values ('warn', 'runner_boot',
              format('%s refused to claim — boot doctor red', coalesce(p_agent,'runner')),
              jsonb_build_object('event_id', v_id, 'checks', coalesce(p_checks,'[]'::jsonb)));
    exception when others then null;
    end;
  end if;

  -- Keep the table small on its own: this is a boot log, not history.
  delete from runner_boot_event where at < now() - interval '30 days';

  return jsonb_build_object('ok', true, 'id', v_id, 'verdict', v_verdict);
end $$;

-- ── 3. the reader — render-ready, one card per runner ──────────────────────
create or replace function runner_boot_status(p_limit int default 12)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rows     jsonb;
  v_recent   jsonb;
  v_green    int;
  v_red      int;
  v_total    int;
begin
  perform _dev_guard();

  -- Latest boot per agent — that is the state of the fleet right now.
  with latest as (
    select distinct on (agent) *
      from runner_boot_event
     where at > now() - interval '7 days'
     order by agent, at desc
  )
  select coalesce(jsonb_agg(x order by x->>'agent'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'agent',        l.agent,
      'host',         l.host,
      'verdict',      l.verdict,
      'verdict_label', case when l.verdict = 'green'
                            then 'Green — claiming'
                            else 'Red — refusing to claim' end,
      'tone',          case when l.verdict = 'green' then 'success' else 'error' end,
      'at_label',      to_char(l.at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST',
      'reason_label',  'Boot: ' || l.boot_reason,
      'timing_label',  case when l.duration_ms > 0
                            then 'Doctor ran in ' || round(l.duration_ms / 1000.0, 1)::text || 's'
                            else 'Doctor timing not recorded' end,
      'released_label', case
                          when l.released_rows = 0 then 'No stale claims to release'
                          when l.released_rows = 1 then '1 stale claim released'
                          else l.released_rows::text || ' stale claims released'
                        end,
      'repairs_label', case
                          when jsonb_array_length(coalesce(l.repairs,'[]'::jsonb)) = 0
                            then 'Workspace was already clean'
                          when jsonb_array_length(l.repairs) = 1
                            then '1 repair applied'
                          else jsonb_array_length(l.repairs)::text || ' repairs applied'
                        end,
      'repairs',       coalesce(l.repairs, '[]'::jsonb),
      'checks',        coalesce(l.checks,  '[]'::jsonb),
      'failed_label',  (
                        select case when count(*) = 0 then ''
                                    else count(*)::text || ' check(s) failed' end
                          from jsonb_array_elements(coalesce(l.checks,'[]'::jsonb)) e
                         where coalesce((e->>'ok')::boolean, false) = false
                       )
    ) as x
    from latest l
  ) s;

  select count(*) filter (where verdict = 'green'),
         count(*) filter (where verdict = 'red'),
         count(*)
    into v_green, v_red, v_total
    from (select distinct on (agent) agent, verdict
            from runner_boot_event
           where at > now() - interval '7 days'
           order by agent, at desc) q;

  select coalesce(jsonb_agg(jsonb_build_object(
           'at_label', to_char(at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST',
           'agent',    agent,
           'verdict',  verdict,
           'tone',     case when verdict = 'green' then 'success' else 'error' end,
           'detail',   case when verdict = 'green'
                            then 'Workspace green — claims allowed'
                            else 'Refused to claim until the doctor passes' end
         ) order by at desc), '[]'::jsonb)
    into v_recent
  from (select * from runner_boot_event order by at desc limit greatest(coalesce(p_limit,12),1)) r;

  return jsonb_build_object(
    'ok', true,
    'title', 'Runner boot',
    'subtitle',
      'Every runner runs the workspace doctor before it claims: git debris cleared, '
      || 'workspace reset to origin/main, toolchain proven, stale claims released. '
      || 'A red verdict means that runner refuses to claim until it is green.',
    'mode_label', case
                    when v_total = 0 then 'No boots recorded'
                    when v_red = 0   then 'All runners green'
                    when v_red = 1   then '1 runner red'
                    else v_red::text || ' runners red'
                  end,
    'mode_tone', case when v_total = 0 then 'neutral'
                      when v_red = 0 then 'success' else 'error' end,
    'counts_label', v_green::text || ' green · ' || v_red::text || ' red (last 7 days)',
    'runners', v_rows,
    'runners_head', 'Latest boot per runner',
    'empty_label', 'No runner has booted since this was switched on. '
                   || 'The next runner start writes the first verdict here.',
    'recent_head', 'Recent boots',
    'recent', v_recent
  );
end $$;

grant execute on function runner_boot_report(text,text,text,jsonb,jsonb,int,int,text,text)
  to service_role;
grant execute on function runner_boot_status(int) to service_role, authenticated;

-- ── 4. the copy (an UPDATE changes the wording, never a deploy) ─────────────
insert into ui_copy (key, value) values
  ('dev_queue.runner_boot_unreachable',
     to_jsonb('Runner boot could not be read right now.'::text))
on conflict (key) do nothing;

-- ── 5. anon never reaches an admin surface ─────────────────────────────────
-- Every SECURITY DEFINER function inherits Postgres's default GRANT TO PUBLIC,
-- and the anon key ships inside the web bundle and the APK — so a new admin_*
-- RPC is a public endpoint until someone revokes it. `rg_check`'s
-- `privileged_rpcs_are_not_anon` behaviour caught three of them in this tree.
-- Idempotent by construction: it revokes whatever currently qualifies, and a
-- second run finds nothing to do.
revoke execute on function runner_boot_status(int) from anon, public;
revoke execute on function runner_boot_report(text,text,text,jsonb,jsonb,int,int,text,text)
  from anon, public;
grant  execute on function runner_boot_status(int) to service_role, authenticated;
grant  execute on function runner_boot_report(text,text,text,jsonb,jsonb,int,int,text,text)
  to service_role;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prosecdef
       and has_function_privilege('anon', p.oid, 'execute')
       and (p.proname like 'admin\_%' or p.proname like 'warehouse\_%')
  loop
    execute format('revoke execute on function %s from anon, public', r.sig);
  end loop;
end $$;

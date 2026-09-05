-- CHANGE #1470 — the build-branch switch-on gate stops failing silently.
--
-- #1149 shipped the branch lifecycle; #1367 found the reason it never turned
-- on (secret_get_runner returns a BARE JSON STRING, so `jq '.value'` errored to
-- empty and the supervisor reported the vault as empty while it held the
-- token). Neither of those is the real defect. The real defect is that a gate
-- which refuses to flip writes NOTHING anybody can read: no dev_audit_log row,
-- a `display` that says the same flat "branch: off" whether the feature is
-- resting or blocked, and — the part that made a whole day disappear — no
-- Flutter surface rendering the sentence at all. Om was told "off" and there
-- was, by construction, nowhere for the reason to appear.
--
-- So: every attempt and every error is audited, the refusal reason is kept on
-- the config row, `display` becomes "Branch blocked: <reason>" while one is
-- outstanding, and dev_ctl_get carries a render-ready card the app prints.

-- ── 1. where the last attempt / the outstanding refusal live ────────────────
alter table public.build_branch_config
  add column if not exists last_attempt_at    timestamptz,
  add column if not exists last_attempt_phase text,
  add column if not exists last_attempt_ok    boolean,
  add column if not exists blocked_reason     text;

-- ── 2. copy (a display string in Dart is a bug) ─────────────────────────────
insert into public.ui_copy (key, value) values
  ('dev_queue.branch_blocked',       to_jsonb('Branch blocked: {reason}'::text)),
  ('dev_queue.branch_title',         to_jsonb('Build branch'::text)),
  ('dev_queue.branch_ref',           to_jsonb('{ref} · {builds} builds'::text)),
  ('dev_queue.branch_attempts',      to_jsonb('Recent attempts'::text)),
  ('dev_queue.branch_attempts_none', to_jsonb('No attempt has been recorded yet.'::text))
on conflict (key) do update set value = excluded.value;

-- ── 3. every attempt and every error is written down ────────────────────────
-- p_audit=false updates the OUTSTANDING REASON without writing a row: a hold
-- that is re-asserted every 20-second tick must stay readable on the card
-- without turning dev_audit_log into a tape of the same sentence.
create or replace function public.build_branch_attempt(
  p_phase  text,
  p_ok     boolean default true,
  p_reason text    default null,
  p_detail jsonb   default '{}'::jsonb,
  p_audit  boolean default true
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_reason text := coalesce(nullif(trim(p_reason), ''), null); v_id bigint;
begin
  perform public._build_branch_guard();

  if coalesce(p_audit, true) then
  insert into public.dev_audit_log (actor, action, subject, detail)
  values ('supervisor',
          case when coalesce(p_ok, true) then 'build_branch.attempt' else 'build_branch.error' end,
          coalesce(nullif(trim(p_phase), ''), 'unknown'),
          coalesce(p_detail, '{}'::jsonb)
            || jsonb_build_object('phase', coalesce(nullif(trim(p_phase),''), 'unknown'),
                                  'ok', coalesce(p_ok, true))
            || case when v_reason is null then '{}'::jsonb
                    else jsonb_build_object('reason', v_reason) end)
  returning id into v_id;
  end if;

  -- An OK attempt supersedes whatever was blocking; a failure IS the block.
  update public.build_branch_config
     set last_attempt_at    = now(),
         last_attempt_phase = coalesce(nullif(trim(p_phase), ''), 'unknown'),
         last_attempt_ok    = coalesce(p_ok, true),
         blocked_reason     = case when coalesce(p_ok, true) then null else v_reason end,
         updated_at         = now()
   where id;

  return jsonb_build_object('ok', true, 'audit_id', v_id, 'blocked', not coalesce(p_ok, true));
end $fn$;

-- ── 4. the state sentence can no longer be a silent "off" ───────────────────
create or replace function public.build_branch_state()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare b public.build_branch; cfg public.build_branch_config;
        v_disp text; v_age text; v_tone text; v_blocked text;
begin
  select * into cfg from public.build_branch_config where id;
  select * into b from public.build_branch
   where status in ('creating','on','deleting') order by created_at desc limit 1;
  v_age := public._build_branch_age_label(coalesce(b.ready_at, b.created_at));
  v_blocked := nullif(trim(coalesce(cfg.blocked_reason, '')), '');

  if coalesce(b.status,'off') = 'on' then
    v_disp := replace(public._c('dev_queue.branch_on'), '{age}', v_age); v_tone := 'completed';
  elsif b.status = 'creating' then
    v_disp := public._c('dev_queue.branch_creating'); v_tone := 'building';
  elsif b.status = 'deleting' then
    v_disp := public._c('dev_queue.branch_deleting'); v_tone := 'building';
  elsif v_blocked is not null then
    -- OFF with an outstanding refusal: say WHY, in the backend's words.
    v_disp := replace(public._c('dev_queue.branch_blocked'), '{reason}', v_blocked);
    v_tone := 'failed';
  else
    v_disp := public._c('dev_queue.branch_off'); v_tone := 'cancelled';
  end if;

  return jsonb_build_object(
    'ok', true, 'enabled', cfg.enabled,
    'status', coalesce(b.status,'off'),
    'id', b.id, 'branch_id', b.branch_id, 'project_ref', b.project_ref, 'api_url', b.api_url,
    'created_at', b.created_at, 'ready_at', b.ready_at, 'last_build_at', b.last_build_at,
    'builds', coalesce(b.builds,0), 'age_label', v_age, 'display', v_disp, 'tone', v_tone,
    'blocked', v_blocked is not null, 'blocked_reason', v_blocked,
    'last_attempt_at', cfg.last_attempt_at, 'last_attempt_phase', cfg.last_attempt_phase,
    'last_attempt_ok', cfg.last_attempt_ok,
    'idle_delete_min', cfg.idle_delete_min, 'cost_guard_hours', cfg.cost_guard_hours,
    'hourly_usd', cfg.hourly_usd);
end $fn$;

-- ── 5. the render-ready card (the app composes nothing) ─────────────────────
create or replace function public.build_branch_card()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare s jsonb; cfg public.build_branch_config; v_rows jsonb; v_sub text;
begin
  select * into cfg from public.build_branch_config where id;
  if cfg.id is null or not coalesce(cfg.enabled, false) then
    return jsonb_build_object('has', false);
  end if;
  s := public.build_branch_state();

  if coalesce(s->>'project_ref','') <> '' then
    v_sub := replace(replace(public._c('dev_queue.branch_ref'),
                             '{ref}', s->>'project_ref'),
                     '{builds}', coalesce(s->>'builds','0'));
  end if;

  select jsonb_agg(r order by r_at desc) into v_rows from (
    select jsonb_build_object(
             'at_display', to_char(a.at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'),
             'label',
               coalesce(nullif(a.detail->>'phase',''), replace(a.action, 'build_branch.', ''))
               || case when coalesce(nullif(a.detail->>'reason',''), '') <> ''
                       then ' — ' || (a.detail->>'reason') else '' end,
             'tone',
               case when a.action like '%.error' or a.action like '%.failed' then 'failed'
                    when a.action like '%.ready' then 'completed'
                    when a.action like '%.off'   then 'cancelled'
                    else 'building' end) as r,
           a.at as r_at
      from public.dev_audit_log a
     where a.action like 'build_branch.%'
     order by a.at desc limit 8) t;

  return jsonb_build_object(
    'has', true,
    'title',          public._c('dev_queue.branch_title'),
    'display',        s->>'display',
    'tone',           s->>'tone',
    'blocked',        (s->>'blocked')::boolean,
    'sub',            v_sub,
    'attempts_title', public._c('dev_queue.branch_attempts'),
    'attempts',       coalesce(v_rows, '[]'::jsonb),
    'attempts_none',  public._c('dev_queue.branch_attempts_none'));
end $fn$;

-- ── 6. it rides the payload the control card already fetches ────────────────
create or replace function public.dev_ctl_get()
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v jsonb; v_ctx jsonb; v_blocked jsonb; v_disk jsonb; v_auth jsonb; v_branch jsonb;
begin
  v := public.dev_ctl_get_core();
  begin v_ctx := public.dev_context_metrics_cached(60);
  exception when others then v_ctx := jsonb_build_object('ok', false, 'has', false);
  end;
  begin v_blocked := public.runner_blocked_badge();
  exception when others then v_blocked := jsonb_build_object('has', false);
  end;
  begin v_disk := public.runner_disk_state();
  exception when others then v_disk := jsonb_build_object('has', false);
  end;
  begin v_auth := public.claude_auth_status();
  exception when others then v_auth := jsonb_build_object('has', false);
  end;
  -- CHANGE #1470 — the build branch rides the SAME payload, so the reason the
  -- gate refused can never again have nowhere to appear.
  begin v_branch := public.build_branch_card();
  exception when others then v_branch := jsonb_build_object('has', false);
  end;
  if coalesce((v->'health'->>'ok')::boolean, false) then
    v := jsonb_set(v, '{health,metrics}',
           coalesce(v->'health'->'metrics','[]'::jsonb)
           || jsonb_build_array(public.runner_health_disk_metric()));
  end if;

  return v || jsonb_build_object('context', v_ctx, 'blocked', v_blocked, 'disk', v_disk,
                                 'claude_auth', v_auth, 'build_branch', v_branch);
end $fn$;

drop function if exists public.build_branch_attempt(text, boolean, text, jsonb);
revoke all on function public.build_branch_attempt(text, boolean, text, jsonb, boolean) from public;
grant execute on function public.build_branch_attempt(text, boolean, text, jsonb, boolean) to service_role;
grant execute on function public.build_branch_card() to authenticated, service_role;

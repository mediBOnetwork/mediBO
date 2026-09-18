-- CMD #2075 — FEATURE JOURNEY GATE (control plane: dev-queue project only).
-- This file is NOT replayed by the deploy lane (migration_replay.sh only runs
-- supabase/migrations/ against production). It is applied by hand with:
--   psql "$(cat ~/.medibo/dev_dburl)" -f supabase/devqueue/2075_feature_journey.sql
-- It is idempotent; re-running it is a no-op.
--
-- WHAT IT ADDS. Every command that changes a screen ships ONE browser journey of
-- its own — feat-<id>, kind=browser, runner=playwright — declared as data:
--   open <route> → tap <Semantics identifier> → expect_nav <route> →
--   expect_rpc <fn seen in the page's network log> → assert_sql <DB effect>.
-- scripts/autotest/feature_journey.js drives it (Playwright, 360px and 412px,
-- inside a purging TEST MODE session) on the branch preview before the upload
-- and on medibo.in after verify_live.sh, and records each lane here. The finish
-- gate's new condition "Feature journey green on live" reads ONLY a live run:
-- reused, cached, skipped or unknown journeys never count, and a pass for a
-- different change number than the one that is live never counts either.
-- Everything a script or the app prints about it comes from
-- _dev_feature_journey_state() — the one truth the gate, dev_cmd_complete,
-- dev_cmd_qa_detail and the card all read.

begin;

-- ── 1. schema ──────────────────────────────────────────────────────────────
alter table dev_journeys add column if not exists command_id bigint;
alter table dev_journeys add column if not exists runner text not null default 'probe';
alter table dev_journeys add column if not exists plan_meta jsonb not null default '{}'::jsonb;
create index if not exists dev_journeys_command_id_idx on dev_journeys(command_id);
do $d$ begin
  if not exists (select 1 from pg_constraint where conname = 'dev_journeys_runner_chk') then
    alter table dev_journeys add constraint dev_journeys_runner_chk
      check (runner in ('probe','playwright'));
  end if;
end $d$;

-- ── 2. the rule (backend-owned copy; gate name c_feature_journey) ───────────
update dev_runner_config
   set value = jsonb_set(coalesce(value,'{}'::jsonb), '{feature_journey}', $j${
  "gate": "c_feature_journey",
  "rule": "Every command with a UI spec item ships its own browser journey (feat-<id>: open route → tap → expected navigation → expected RPC in the network log → DB effect asserted by SQL, no stub steps). It runs on the branch preview before the upload and on medibo.in after the deploy, at 360px and 412px, in a purging TEST MODE session; the command cannot complete until the LIVE run is green.",
  "why": "A feature nobody can open, tap and see land in the database on medibo.in does not exist — screenshots and RPC probes proved the parts, never the click.",
  "change": 2075,
  "widths": [360, 412],
  "budget_s": 300,
  "max_reruns": 2,
  "lanes": ["preview", "live"],
  "verdict": "rg_runner_verdict — feature_journey_gate (scripts/feature_journey_check.sh)",
  "prompt_line": "FEATURE JOURNEY (build_rules.feature_journey, gate c_feature_journey): a command that changes a screen ships its OWN browser journey, declared as data before you deploy: devcmd.sh feature_journey <id> set '<plan-json>' — five steps, open route → tap <Semantics identifier> → expect_nav <route> → expect_rpc <fn> → assert_sql <select … returning boolean>; no stub text, every field filled (devcmd.sh feature_journey <id> derive drafts it from the spec; devcmd.sh feature_journey <id> show prints it). The deploy runs it twice by itself — on the branch preview before the upload and on medibo.in after verify_live — at 360px and 412px inside a purging TEST MODE session, one Playwright launch, scripts only. The finish gate condition \"Feature journey green on live\" accepts ONLY a passed LIVE run for the change number that is live: reused, cached, skipped or unknown journeys never count. Red → fix on your branch and rerun (devcmd.sh feature_journey <id> run live, max 2 reruns); dev_cmd_complete is refused until it is green. Backend-only commands (no UI spec item, no lib/ file) skip it."
}$j$::jsonb, true)
 where key = 'build_rules';

-- enforcement knobs: pool_set flips them, no deploy. enforce starts FALSE and is
-- flipped by the command that ships the runner door, so no row is ever gated
-- before the door it needs exists. effective_at protects rows already in flight.
update dev_runner_config
   set value = jsonb_set(coalesce(value,'{}'::jsonb), '{feature_journey}',
         coalesce(value->'feature_journey','{}'::jsonb) || $j${
  "enforce": false,
  "max_reruns": 2,
  "budget_s": 300,
  "widths": [360, 412],
  "lanes": ["preview", "live"],
  "required_kinds": ["open", "tap", "expect_nav", "expect_rpc", "assert_sql"],
  "stub_words": ["IMPLEMENT", "TODO", "TBD", "PLACEHOLDER", "???", "<fill", "FIXME"],
  "no_reuse_kinds": ["browser"],
  "note": "CMD #2075 — enforce:false until the runner door (devcmd.sh feature_journey) shipped; effective_at is set when enforce flips so in-flight rows are never ambushed."
}$j$::jsonb, true)
 where key = 'worker_pool';

-- ── 3. copy (the app and the gate print these verbatim) ─────────────────────
insert into ui_copy (key, value) values
  ('dev_queue.gate_feature_journey',      to_jsonb('Feature journey green on live'::text)),
  ('dev_queue.fj_title',                  to_jsonb('Feature journey'::text)),
  ('dev_queue.fj_not_needed',             to_jsonb('Not needed — no screen changes in this command'::text)),
  ('dev_queue.fj_not_declared',           to_jsonb('Not declared yet — the builder sets it with devcmd.sh feature_journey <id> set'::text)),
  ('dev_queue.fj_invalid',                to_jsonb('Plan invalid'::text)),
  ('dev_queue.fj_pending',                to_jsonb('Waiting for the live run'::text)),
  ('dev_queue.fj_green',                  to_jsonb('Green on live'::text)),
  ('dev_queue.fj_red',                    to_jsonb('Red on live'::text)),
  ('dev_queue.fj_stale',                  to_jsonb('Live pass is for an older change'::text)),
  ('dev_queue.fj_lane_preview',           to_jsonb('Branch preview'::text)),
  ('dev_queue.fj_lane_live',              to_jsonb('medibo.in'::text)),
  ('dev_queue.fj_no_run',                 to_jsonb('not run yet'::text)),
  ('dev_queue.fj_role',                   to_jsonb('Runs as'::text)),
  ('dev_queue.fj_widths',                 to_jsonb('Widths'::text)),
  ('dev_queue.fj_attempts',               to_jsonb('Attempts'::text)),
  ('dev_queue.fj_video',                  to_jsonb('Video'::text)),
  ('dev_queue.fj_network',                to_jsonb('Network log'::text)),
  ('dev_queue.fj_sql',                    to_jsonb('SQL proof'::text)),
  ('dev_queue.fj_steps_title',            to_jsonb('Steps'::text)),
  ('dev_queue.fj_rerun_hint',             to_jsonb('Red → fix on the branch, then: devcmd.sh feature_journey {id} run live'::text))
on conflict (key) do nothing;

-- ── 4. config reader — one merged view, nothing decided in a script ─────────
create or replace function public._dev_fj_cfg()
returns jsonb language sql stable security definer set search_path = public as $fn$
  select coalesce((select value->'feature_journey' from dev_runner_config where key = 'build_rules'), '{}'::jsonb)
      || coalesce((select value->'feature_journey' from dev_runner_config where key = 'worker_pool'), '{}'::jsonb);
$fn$;
revoke all on function public._dev_fj_cfg() from public, anon, authenticated;
grant execute on function public._dev_fj_cfg() to service_role;

-- ── 5. does THIS command need a feature journey? ────────────────────────────
-- A spec item that talks about a screen, a tap, a route or a widget is a UI
-- item; so is a footprint that touches lib/**.dart. The words are data.
create or replace function public._dev_spec_item_is_ui(p_text text)
returns boolean language sql immutable as $fn$
  select coalesce(p_text, '') ~* '\m(screen|page|button|tap|taps|tapping|card|cards|chip|chips|menu|header|banner|sheet|dialog|route|render|renders|rendered|shows?|display|displays|layout|list|tab|tabs|form|field|toast|icon|widget|dropdown|block|section|badge|pill|viewport|mobile|phone|frontend|ui|flutter|dart|pdp|storefront|checkout|cart)\M'
      or coalesce(p_text, '') ~ '(^|\s)/[a-z][a-z0-9_/-]+';
$fn$;

create or replace function public._dev_feature_journey_needed(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare r record; v_item record; v_files text[];
begin
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('needed', false, 'why', 'no such command'); end if;
  if coalesce(r.kind,'dev') <> 'dev' then
    return jsonb_build_object('needed', false, 'why', 'kind ' || r.kind || ' never ships a screen');
  end if;
  if coalesce(r.route,'') = 'fast' then
    return jsonb_build_object('needed', false, 'why', 'fast-lane command');
  end if;
  if not coalesce(r.targets_web, false) then
    return jsonb_build_object('needed', false, 'why', 'does not target the web app');
  end if;
  if exists (select 1 from dev_journeys j where j.command_id = p_id and j.runner = 'playwright') then
    return jsonb_build_object('needed', true, 'why', 'a feature journey is declared for this command');
  end if;
  select n, text into v_item from dev_command_spec_item
   where command_id = p_id and status <> 'dropped' and _dev_spec_item_is_ui(text)
   order by n limit 1;
  if found then
    return jsonb_build_object('needed', true, 'why', 'UI spec item #' || v_item.n || ': ' || left(v_item.text, 80));
  end if;
  v_files := coalesce(public.dev_cmd_footprint(p_id), '{}');
  if exists (select 1 from unnest(v_files) f where f like 'lib/%.dart') then
    return jsonb_build_object('needed', true, 'why', 'the footprint touches lib/ (' ||
      (select string_agg(f, ', ') from (select f from unnest(v_files) f where f like 'lib/%.dart' limit 3) s) || ')');
  end if;
  return jsonb_build_object('needed', false, 'why', 'no UI spec item and no lib/ file in the footprint');
end $fn$;

-- ── 6. the plan is data, and it is validated — no stub steps ────────────────
create or replace function public._dev_feature_plan_check(p_plan jsonb)
returns text language plpgsql stable security definer set search_path = public as $fn$
declare cfg jsonb := _dev_fj_cfg(); s jsonb; i int := 0; k text; v text;
        v_kinds text[] := '{}'; v_req text[]; v_missing text[] := '{}'; w text; sql_txt text;
begin
  if p_plan is null or jsonb_typeof(p_plan) <> 'array' or jsonb_array_length(p_plan) = 0 then
    return 'plan is empty — declare the five steps';
  end if;
  select coalesce(array_agg(x), '{}') into v_req
    from jsonb_array_elements_text(coalesce(cfg->'required_kinds',
           '["open","tap","expect_nav","expect_rpc","assert_sql"]'::jsonb)) x;
  for s in select * from jsonb_array_elements(p_plan) loop
    i := i + 1;
    if jsonb_typeof(s) <> 'object' then return format('step %s is not an object', i); end if;
    k := coalesce(s->>'kind', '');
    if k not in ('open','tap','expect_nav','expect_rpc','assert_sql') then
      return format('step %s has unknown kind "%s"', i, k);
    end if;
    v_kinds := array_append(v_kinds, k);
    -- stub text anywhere in the step is a stub step
    for w in select * from jsonb_array_elements_text(coalesce(cfg->'stub_words', '["IMPLEMENT","TODO","TBD"]'::jsonb)) loop
      if position(upper(w) in upper(s::text)) > 0 then
        return format('step %s (%s) carries stub text "%s"', i, k, w);
      end if;
    end loop;
    case k
      when 'open' then
        if coalesce(btrim(s->>'route'),'') = '' then return format('step %s (open) has no route', i); end if;
      when 'tap' then
        if coalesce(btrim(s->>'identifier'),'') = '' then return format('step %s (tap) has no Semantics identifier', i); end if;
      when 'expect_nav' then
        if coalesce(btrim(s->>'route'),'') = '' and coalesce(btrim(s->>'contains'),'') = '' then
          return format('step %s (expect_nav) has no route', i);
        end if;
      when 'expect_rpc' then
        if coalesce(btrim(s->>'fn'),'') = '' then return format('step %s (expect_rpc) has no fn', i); end if;
      when 'assert_sql' then
        sql_txt := coalesce(btrim(s->>'sql'),'');
        if sql_txt = '' then return format('step %s (assert_sql) has no sql', i); end if;
        if sql_txt !~* '^\s*select\M' then return format('step %s (assert_sql) must be a single SELECT', i); end if;
        if sql_txt ~* '\m(insert|update|delete|drop|alter|create|grant|revoke|truncate|copy)\M' or position(';' in sql_txt) > 0 then
          return format('step %s (assert_sql) may only read', i);
        end if;
        if coalesce(s->>'lane','app') not in ('app','dev') then
          return format('step %s (assert_sql) lane must be app or dev', i);
        end if;
    end case;
  end loop;
  select coalesce(array_agg(x), '{}') into v_missing
    from unnest(v_req) x where not (x = any (v_kinds));
  if coalesce(array_length(v_missing, 1), 0) > 0 then
    return 'missing step kinds: ' || array_to_string(v_missing, ', ');
  end if;
  return null;
end $fn$;

-- readable lines for the card and for dev_journeys.steps (the library prints steps)
create or replace function public._dev_feature_plan_lines(p_plan jsonb)
returns jsonb language sql immutable as $fn$
  select coalesce(jsonb_agg(
    (ord::text || '. ' ||
     case s->>'kind'
       when 'open'       then 'open ' || coalesce(s->>'route','')
       when 'tap'        then 'tap ' || coalesce(s->>'identifier','')
       when 'expect_nav' then 'expect navigation to ' || coalesce(nullif(s->>'route',''), s->>'contains', '')
       when 'expect_rpc' then 'expect rpc ' || coalesce(s->>'fn','') || ' in the network log'
       when 'assert_sql' then 'assert sql (' || coalesce(s->>'lane','app') || '): ' || coalesce(nullif(s->>'label',''), left(s->>'sql', 60))
       else coalesce(s->>'kind','?') end) order by ord), '[]'::jsonb)
  from jsonb_array_elements(coalesce(p_plan,'[]'::jsonb)) with ordinality as t(s, ord);
$fn$;

-- role guess from the area — a default the builder overrides with set(..., p_role)
create or replace function public._dev_fj_role_guess(p_area text)
returns text language sql immutable as $fn$
  select case lower(coalesce(p_area,''))
    when 'storefront' then 'customer' when 'customer' then 'customer' when 'customers' then 'customer'
    when 'orders' then 'customer' when 'supplier' then 'supplier' when 'delivery' then 'delivery'
    when 'pharmacy' then 'customer'
    else 'super_admin' end;
$fn$;

-- ── 7. set / derive / get ───────────────────────────────────────────────────
create or replace function public.dev_feature_journey_set(p_command_id bigint, p_plan jsonb,
                                                          p_role text default null, p_title text default null)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare r record; v_err text; v_name text; v_id bigint; v_assert jsonb; v_role text;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_command_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  v_err := _dev_feature_plan_check(p_plan);
  if v_err is not null then
    return jsonb_build_object('ok', false, 'valid', false, 'error', v_err,
      'line', 'feature journey NOT set — ' || v_err);
  end if;
  v_name := 'feat-' || p_command_id::text;
  v_role := coalesce(nullif(btrim(p_role),''),
                     (select as_role from dev_journeys where name = v_name),
                     _dev_fj_role_guess(r.area));
  select coalesce(jsonb_agg(s), '[]'::jsonb) into v_assert
    from jsonb_array_elements(p_plan) s where s->>'kind' = 'assert_sql';
  insert into dev_journeys (name, area, kind, steps, assertions, source_bug, required, enabled,
                            as_role, files, probe_on, plan, command_id, runner, plan_meta)
  values (v_name, r.area, 'browser', _dev_feature_plan_lines(p_plan), v_assert, p_command_id, false, true,
          v_role, coalesce(public.dev_cmd_footprint(p_command_id), '{}'), 'branch', p_plan,
          p_command_id, 'playwright',
          jsonb_build_object('source', 'set', 'set_at', now(), 'title', coalesce(p_title, r.title)))
  on conflict (name) do update
     set area = excluded.area, kind = 'browser', steps = excluded.steps, assertions = excluded.assertions,
         source_bug = excluded.source_bug, enabled = true, as_role = excluded.as_role,
         files = excluded.files, plan = excluded.plan, command_id = excluded.command_id,
         runner = 'playwright', plan_meta = excluded.plan_meta
  returning id into v_id;
  return jsonb_build_object('ok', true, 'valid', true, 'journey_id', v_id, 'name', v_name,
    'role', v_role, 'steps', _dev_feature_plan_lines(p_plan),
    'line', format('feature journey %s set (%s steps, runs as %s) — the deploy runs it on the preview and on medibo.in',
                   v_name, jsonb_array_length(p_plan), v_role));
end $fn$;
revoke all on function public.dev_feature_journey_set(bigint, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.dev_feature_journey_set(bigint, jsonb, text, text) to service_role;

-- derive: a DRAFT from the spec — never a stub that passes. Whatever cannot be
-- read from the spec is left empty, which the check names, so the builder fills
-- exactly the fields the spec did not carry. A plan the builder has SET is
-- never overwritten.
create or replace function public.dev_feature_journey_derive(p_command_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare r record; v_need jsonb; v_name text; v_existing record; v_route text; v_fn text;
        v_plan jsonb; v_err text; v_id bigint; v_role text; v_spec text;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_command_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  v_need := _dev_feature_journey_needed(p_command_id);
  v_name := 'feat-' || p_command_id::text;
  select * into v_existing from dev_journeys where name = v_name;
  if found and coalesce(v_existing.plan_meta->>'source','') = 'set' then
    v_err := _dev_feature_plan_check(v_existing.plan);
    return jsonb_build_object('ok', true, 'needed', (v_need->>'needed')::boolean, 'why', v_need->>'why',
      'name', v_name, 'journey_id', v_existing.id, 'valid', v_err is null, 'error', v_err,
      'plan', v_existing.plan, 'role', v_existing.as_role, 'source', 'set',
      'line', 'feature journey ' || v_name || ' is already set by the builder — left as is');
  end if;
  if not (v_need->>'needed')::boolean then
    return jsonb_build_object('ok', true, 'needed', false, 'why', v_need->>'why',
      'line', 'no feature journey needed — ' || (v_need->>'why'));
  end if;
  v_spec := coalesce(r.enriched_spec, '') || E'\n' || coalesce(r.spec, '');
  -- the first route-looking path in the spec, else the app root
  v_route := coalesce((select (regexp_matches(v_spec, '(?:^|\s)(/[a-z][a-z0-9_/-]+(?:\?[a-z0-9_=&-]+)?)', 'i'))[1] limit 1), '/');
  -- the first rpc-looking name (something_something_v2 or a known dev_ prefix)
  v_fn := coalesce((select (regexp_matches(v_spec, '\m([a-z]+_[a-z0-9_]+(?:_v[0-9]+)?)\('))[1] limit 1),
                   (select (regexp_matches(v_spec, '\m((?:dev_|storefront_|cart_|order_|admin_|fw_|pack_)[a-z0-9_]+)\M'))[1] limit 1),
                   '');
  v_role := _dev_fj_role_guess(r.area);
  v_plan := jsonb_build_array(
    jsonb_build_object('kind','open','route', v_route),
    jsonb_build_object('kind','tap','identifier',''),
    jsonb_build_object('kind','expect_nav','route',''),
    jsonb_build_object('kind','expect_rpc','fn', v_fn),
    jsonb_build_object('kind','assert_sql','lane', case when r.area in ('devops','admin','platform','infra') then 'dev' else 'app' end,
                       'sql','', 'label',''));
  v_err := _dev_feature_plan_check(v_plan);
  insert into dev_journeys (name, area, kind, steps, assertions, source_bug, required, enabled,
                            as_role, files, probe_on, plan, command_id, runner, plan_meta)
  values (v_name, r.area, 'browser', _dev_feature_plan_lines(v_plan), '[]'::jsonb, p_command_id, false, true,
          v_role, coalesce(public.dev_cmd_footprint(p_command_id), '{}'), 'branch', v_plan,
          p_command_id, 'playwright', jsonb_build_object('source','derived','derived_at', now()))
  on conflict (name) do update
     set plan = excluded.plan, steps = excluded.steps, area = excluded.area, files = excluded.files,
         command_id = excluded.command_id, runner = 'playwright', plan_meta = excluded.plan_meta,
         as_role = coalesce(dev_journeys.as_role, excluded.as_role), enabled = true
  returning id into v_id;
  return jsonb_build_object('ok', true, 'needed', true, 'why', v_need->>'why', 'name', v_name,
    'journey_id', v_id, 'valid', v_err is null, 'error', v_err, 'plan', v_plan, 'role', v_role,
    'source', 'derived',
    'line', case when v_err is null then 'feature journey ' || v_name || ' derived and valid'
                 else 'feature journey ' || v_name || ' drafted from the spec — ' || v_err ||
                      '. Fill it and run: devcmd.sh feature_journey ' || p_command_id || ' set ''<plan-json>''' end);
end $fn$;
revoke all on function public.dev_feature_journey_derive(bigint) from public, anon, authenticated;
grant execute on function public.dev_feature_journey_derive(bigint) to service_role;

-- get: everything the Playwright runner needs; the script decides nothing.
-- {cmd} in a route / sql is the command id; {run} and {session} are filled by
-- the SQL-assert RPCs at run time.
create or replace function public.dev_feature_journey_get(p_command_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare j record; cfg jsonb := _dev_fj_cfg(); v_need jsonb; v_err text; r record;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_command_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  v_need := _dev_feature_journey_needed(p_command_id);
  select * into j from dev_journeys where name = 'feat-' || p_command_id::text and runner = 'playwright';
  if not found then
    return jsonb_build_object('ok', true, 'has', false, 'needed', (v_need->>'needed')::boolean,
      'why', v_need->>'why', 'widths', coalesce(cfg->'widths','[360,412]'::jsonb),
      'budget_s', coalesce((cfg->>'budget_s')::int, 300));
  end if;
  v_err := _dev_feature_plan_check(j.plan);
  return jsonb_build_object('ok', true, 'has', true, 'needed', (v_need->>'needed')::boolean,
    'why', v_need->>'why', 'journey_id', j.id, 'name', j.name, 'area', j.area,
    'role', coalesce(j.as_role, _dev_fj_role_guess(j.area)),
    'title', coalesce(j.plan_meta->>'title', r.title),
    'valid', v_err is null, 'error', v_err,
    'plan', replace(j.plan::text, '{cmd}', p_command_id::text)::jsonb,
    'lines', j.steps,
    'widths', coalesce(cfg->'widths','[360,412]'::jsonb),
    'budget_s', coalesce((cfg->>'budget_s')::int, 300),
    'max_reruns', coalesce((cfg->>'max_reruns')::int, 2),
    'lanes', coalesce(cfg->'lanes','["preview","live"]'::jsonb));
end $fn$;
revoke all on function public.dev_feature_journey_get(bigint) from public, anon, authenticated;
grant execute on function public.dev_feature_journey_get(bigint) to service_role;

-- ── 8. attempts + record ────────────────────────────────────────────────────
create or replace function public.dev_feature_journey_attempt(p_command_id bigint, p_lane text,
                                                              p_change_no integer default null)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare cfg jsonb := _dev_fj_cfg(); v_max int; v_n int; v_jid bigint;
begin
  perform _dev_guard();
  v_max := coalesce((cfg->>'max_reruns')::int, 2);
  select id into v_jid from dev_journeys where name = 'feat-' || p_command_id::text;
  if v_jid is null then
    return jsonb_build_object('allowed', false, 'attempt_no', 0, 'max', 1 + v_max,
      'note', 'no feature journey declared for #' || p_command_id);
  end if;
  select count(*) into v_n from dev_journey_runs
   where command_id = p_command_id and journey_id = v_jid and lane = p_lane
     and (p_change_no is null or (evidence->>'change_no') = p_change_no::text)
     and coalesce(evidence->>'reused','') <> 'true';
  return jsonb_build_object('allowed', v_n < 1 + v_max, 'attempt_no', v_n + 1, 'max', 1 + v_max,
    'note', case when v_n < 1 + v_max
                 then format('attempt %s of %s on %s', v_n + 1, 1 + v_max, p_lane)
                 else format('%s attempts already used on %s for CHANGE #%s — max_reruns is %s; a new deploy resets the count',
                             v_n, p_lane, coalesce(p_change_no::text, '?'), v_max) end);
end $fn$;
revoke all on function public.dev_feature_journey_attempt(bigint, text, integer) from public, anon, authenticated;
grant execute on function public.dev_feature_journey_attempt(bigint, text, integer) to service_role;

create or replace function public.dev_feature_journey_record(p_command_id bigint, p_lane text, p_status text,
                                                             p_evidence jsonb default '{}'::jsonb,
                                                             p_change_no integer default null,
                                                             p_commit text default null,
                                                             p_duration_ms integer default null)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare cfg jsonb := _dev_fj_cfg(); v_jid bigint; st text; v_run bigint; v_state jsonb;
begin
  perform _dev_guard();
  if p_lane is null or not (coalesce(cfg->'lanes','["preview","live"]'::jsonb) ? p_lane) then
    return jsonb_build_object('ok', false, 'error', 'lane must be one of ' || coalesce(cfg->'lanes','["preview","live"]'::jsonb)::text);
  end if;
  select id into v_jid from dev_journeys where name = 'feat-' || p_command_id::text and runner = 'playwright';
  if v_jid is null then return jsonb_build_object('ok', false, 'error', 'no feature journey declared for #' || p_command_id); end if;
  st := coalesce(p_status, 'skipped');
  if st not in ('passed','failed','skipped') then st := 'skipped'; end if;
  insert into dev_journey_runs (command_id, journey_id, status, evidence, duration_ms, commit_sha, lane)
  values (p_command_id, v_jid, st,
          coalesce(p_evidence, '{}'::jsonb)
            || jsonb_build_object('runner', 'playwright', 'lane', p_lane, 'recorded_at', now())
            || case when p_change_no is not null then jsonb_build_object('change_no', p_change_no) else '{}'::jsonb end,
          p_duration_ms, p_commit, p_lane)
  returning id into v_run;
  if st = 'passed' then
    update dev_commands set journey_pass_count = coalesce(journey_pass_count,0) + 1 where id = p_command_id;
  end if;
  v_state := _dev_feature_journey_state(p_command_id);
  return jsonb_build_object('ok', true, 'run_id', v_run, 'status', st, 'lane', p_lane,
    'green', coalesce((v_state->>'green')::boolean, false),
    'line', format('feature journey %s on %s: %s — %s', 'feat-' || p_command_id, p_lane, upper(st), v_state->>'detail'));
end $fn$;
revoke all on function public.dev_feature_journey_record(bigint, text, text, jsonb, integer, text, integer) from public, anon, authenticated;
grant execute on function public.dev_feature_journey_record(bigint, text, text, jsonb, integer, text, integer) to service_role;

-- a SQL assertion on the CONTROL PLANE (lane dev). Read-only, bounded, one
-- boolean. {cmd} {run} {session} are substituted before it runs.
create or replace function public.dev_journey_sql_assert(p_command_id bigint, p_sql text,
                                                         p_run_id bigint default null, p_session_id bigint default null)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare v_sql text; v_ok boolean; v_err text;
begin
  perform _dev_guard();
  v_sql := coalesce(btrim(p_sql), '');
  if v_sql !~* '^\s*select\M' or position(';' in v_sql) > 0
     or v_sql ~* '\m(insert|update|delete|drop|alter|create|grant|revoke|truncate|copy|pg_sleep)\M' then
    return jsonb_build_object('ok', false, 'value', null, 'error', 'assert_sql may only be one read-only SELECT');
  end if;
  v_sql := replace(replace(replace(v_sql, '{cmd}', p_command_id::text),
                           '{run}', coalesce(p_run_id::text, 'null')),
                   '{session}', coalesce(p_session_id::text, 'null'));
  begin
    perform set_config('statement_timeout', '5000', true);
    execute 'select coalesce((' || v_sql || ')::boolean, false)' into v_ok;
  exception when others then
    v_err := sqlerrm;
  end;
  if v_err is not null then return jsonb_build_object('ok', false, 'value', null, 'error', left(v_err, 300)); end if;
  return jsonb_build_object('ok', coalesce(v_ok, false), 'value', v_ok, 'error', null);
end $fn$;
revoke all on function public.dev_journey_sql_assert(bigint, text, bigint, bigint) from public, anon, authenticated;
grant execute on function public.dev_journey_sql_assert(bigint, text, bigint, bigint) to service_role;

-- ── 9. THE ONE TRUTH: _dev_feature_journey_state ────────────────────────────
create or replace function public._dev_feature_journey_state(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare r record; j record; cfg jsonb := _dev_fj_cfg(); v_need jsonb; v_err text;
        live record; prev record; v_change int; v_green boolean := false; v_detail text;
        v_widths jsonb; v_wp jsonb; v_max int; v_n_live int := 0; v_n_prev int := 0;
        v_on boolean; v_eff timestamptz; v_lines jsonb := '[]'::jsonb;
begin
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('needed', false, 'why', 'no such command', 'green', false, 'detail', 'no such command'); end if;
  v_need := _dev_feature_journey_needed(p_id);
  v_widths := coalesce(cfg->'widths', '[360,412]'::jsonb);
  v_max := coalesce((cfg->>'max_reruns')::int, 2);
  v_on := coalesce((cfg->>'enforce')::boolean, false);
  v_eff := coalesce((cfg->>'effective_at')::timestamptz, now());
  select coalesce(r.web_deploy_no,
           (select d.change_no from deploy_direct d where d.command_id = p_id and d.status = 'deployed' and d.change_no is not null order by d.id desc limit 1),
           (select q.change_no from deploy_queue q where q.command_id = p_id and q.status = 'deployed' and q.change_no is not null order by q.id desc limit 1))
    into v_change;
  select * into j from dev_journeys where name = 'feat-' || p_id::text and runner = 'playwright';
  if found then
    v_err := _dev_feature_plan_check(j.plan);
    v_lines := coalesce(j.steps, '[]'::jsonb);
    select * into live from dev_journey_runs where command_id = p_id and journey_id = j.id and lane = 'live'
      and coalesce(evidence->>'reused','') <> 'true' order by id desc limit 1;
    select * into prev from dev_journey_runs where command_id = p_id and journey_id = j.id and lane = 'preview'
      and coalesce(evidence->>'reused','') <> 'true' order by id desc limit 1;
    select count(*) into v_n_live from dev_journey_runs where command_id = p_id and journey_id = j.id and lane = 'live'
      and (v_change is null or (evidence->>'change_no') = v_change::text);
    select count(*) into v_n_prev from dev_journey_runs where command_id = p_id and journey_id = j.id and lane = 'preview';
  end if;

  if not (v_need->>'needed')::boolean then
    v_detail := v_need->>'why';
  elsif j.id is null then
    v_detail := 'not declared — devcmd.sh feature_journey ' || p_id || ' derive, then set';
  elsif v_err is not null then
    v_detail := 'plan invalid: ' || v_err || ' — devcmd.sh feature_journey ' || p_id || ' set ''<plan-json>''';
  elsif live.id is null then
    v_detail := 'no live run yet — the deploy runs it after verify_live.sh (or: devcmd.sh feature_journey ' || p_id || ' run live)';
  elsif coalesce(live.evidence->>'cached','') = 'true' then
    v_detail := 'the latest live run was cached — a cached run never counts; rerun it';
  elsif live.status <> 'passed' then
    v_detail := format('live run %s at %s — %s (attempt %s of %s) — fix on the branch, then: devcmd.sh feature_journey %s run live',
                       upper(live.status), to_char(live.at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'),
                       coalesce(live.evidence->>'failed_step', live.evidence->>'note', 'no detail'),
                       v_n_live, 1 + v_max, p_id);
  elsif v_change is null then
    v_detail := 'a live pass is recorded but no change number is live for this command yet';
  elsif coalesce(live.evidence->>'change_no','') <> v_change::text then
    v_detail := format('the live pass is for CHANGE #%s, but CHANGE #%s is what is live — rerun: devcmd.sh feature_journey %s run live',
                       coalesce(live.evidence->>'change_no','?'), v_change, p_id);
  else
    v_wp := coalesce(live.evidence->'widths_passed', '[]'::jsonb);
    if not (v_wp @> v_widths) then
      v_detail := format('passed at %s only — every width in %s must pass', v_wp::text, v_widths::text);
    else
      v_green := true;
      v_detail := format('green on medibo.in at %s (CHANGE #%s, %s)',
                         (select string_agg(w || 'px', ' + ') from jsonb_array_elements_text(v_widths) w),
                         v_change, to_char(live.at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'));
    end if;
  end if;

  return jsonb_build_object(
    'needed', (v_need->>'needed')::boolean, 'why', v_need->>'why',
    'enforced', v_on and r.started_at >= v_eff,
    'has', j.id is not null, 'journey_id', j.id, 'name', 'feat-' || p_id::text,
    'role', j.as_role, 'valid', (j.id is not null and v_err is null), 'plan_error', v_err,
    'lines', v_lines, 'source', j.plan_meta->>'source',
    'deployed_change', v_change,
    'widths', v_widths, 'max_attempts', 1 + v_max,
    'live', case when live.id is null then null else jsonb_build_object(
              'run_id', live.id, 'status', live.status, 'at', live.at,
              'at_display', to_char(live.at at time zone 'Asia/Kolkata', 'DD Mon, HH24:MI'),
              'change_no', live.evidence->>'change_no', 'widths_passed', live.evidence->'widths_passed',
              'video', live.evidence->>'video', 'network_log', live.evidence->>'network_log',
              'sql_proof', live.evidence->>'sql_proof', 'failed_step', live.evidence->>'failed_step',
              'note', live.evidence->>'note', 'duration_ms', live.duration_ms, 'attempts', v_n_live) end,
    'preview', case when prev.id is null then null else jsonb_build_object(
              'run_id', prev.id, 'status', prev.status, 'at', prev.at,
              'at_display', to_char(prev.at at time zone 'Asia/Kolkata', 'DD Mon, HH24:MI'),
              'change_no', prev.evidence->>'change_no', 'widths_passed', prev.evidence->'widths_passed',
              'video', prev.evidence->>'video', 'network_log', prev.evidence->>'network_log',
              'sql_proof', prev.evidence->>'sql_proof', 'failed_step', prev.evidence->>'failed_step',
              'note', prev.evidence->>'note', 'duration_ms', prev.duration_ms, 'attempts', v_n_prev) end,
    'green', v_green, 'detail', v_detail);
end $fn$;
revoke all on function public._dev_feature_journey_state(bigint) from public, anon, authenticated;
grant execute on function public._dev_feature_journey_state(bigint) to service_role;

-- the card block: labels, tones and lines, built here so the app prints them
create or replace function public._dev_feature_journey_card(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare s jsonb := _dev_feature_journey_state(p_id); v_label text; v_tone text; v_lines jsonb := '[]'::jsonb;
        v_links jsonb := '[]'::jsonb; lane jsonb; lane_key text;
begin
  if not coalesce((s->>'needed')::boolean, false) then
    v_label := c_ui('dev_queue.fj_not_needed'); v_tone := 'neutral';
  elsif not coalesce((s->>'has')::boolean, false) then
    v_label := c_ui('dev_queue.fj_not_declared'); v_tone := 'warning';
  elsif not coalesce((s->>'valid')::boolean, false) then
    v_label := c_ui('dev_queue.fj_invalid'); v_tone := 'error';
  elsif coalesce((s->>'green')::boolean, false) then
    v_label := c_ui('dev_queue.fj_green'); v_tone := 'success';
  elsif s->'live' is null or s->'live' = 'null'::jsonb then
    v_label := c_ui('dev_queue.fj_pending'); v_tone := 'info';
  elsif (s->'live'->>'status') = 'passed' then
    v_label := c_ui('dev_queue.fj_stale'); v_tone := 'warning';
  else
    v_label := c_ui('dev_queue.fj_red'); v_tone := 'error';
  end if;
  foreach lane_key in array array['preview','live'] loop
    lane := s->lane_key;
    v_lines := v_lines || jsonb_build_object(
      'label', c_ui('dev_queue.fj_lane_' || lane_key),
      'value', case when lane is null or lane = 'null'::jsonb then c_ui('dev_queue.fj_no_run')
                    else upper(coalesce(lane->>'status','')) || ' · ' || coalesce(lane->>'at_display','')
                         || case when coalesce(lane->>'change_no','') <> '' then ' · CHANGE #' || (lane->>'change_no') else '' end
                         || case when lane->'widths_passed' is not null then ' · ' ||
                              (select string_agg(w || 'px', '+') from jsonb_array_elements_text(lane->'widths_passed') w) else '' end end,
      'tone', case when lane is null or lane = 'null'::jsonb then 'neutral'
                   when lane->>'status' = 'passed' then 'success'
                   when lane->>'status' = 'failed' then 'error' else 'neutral' end);
    if lane is not null and lane <> 'null'::jsonb then
      if coalesce(lane->>'video','') <> '' then
        v_links := v_links || jsonb_build_object('label', c_ui('dev_queue.fj_video') || ' · ' || lane_key, 'path', lane->>'video');
      end if;
      if coalesce(lane->>'network_log','') <> '' then
        v_links := v_links || jsonb_build_object('label', c_ui('dev_queue.fj_network') || ' · ' || lane_key, 'path', lane->>'network_log');
      end if;
      if coalesce(lane->>'sql_proof','') <> '' then
        v_links := v_links || jsonb_build_object('label', c_ui('dev_queue.fj_sql') || ' · ' || lane_key, 'path', lane->>'sql_proof');
      end if;
    end if;
  end loop;
  if coalesce(s->>'role','') <> '' then
    v_lines := v_lines || jsonb_build_object('label', c_ui('dev_queue.fj_role'), 'value', s->>'role', 'tone', 'neutral');
  end if;
  return s || jsonb_build_object(
    'title', c_ui('dev_queue.fj_title'),
    'status_label', v_label, 'status_tone', v_tone,
    'rows', v_lines, 'links', v_links,
    'steps_title', c_ui('dev_queue.fj_steps_title'),
    'hint', case when coalesce((s->>'needed')::boolean,false) and not coalesce((s->>'green')::boolean,false)
                 then replace(c_ui('dev_queue.fj_rerun_hint'), '{id}', p_id::text) else '' end);
end $fn$;
revoke all on function public._dev_feature_journey_card(bigint) from public, anon, authenticated;
grant execute on function public._dev_feature_journey_card(bigint) to service_role;

-- ── 10. dev_journeys_plan — browser journeys are NEVER reused; playwright
--        journeys are never handed to the API probe (they run in the browser lane)
create or replace function public.dev_journeys_plan(p_command_id bigint, p_area text, p_after_id bigint DEFAULT NULL::bigint, p_limit integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  j record; v_cfg jsonb; v_limit int; v_reuse_min int; v_commit text; v_files text[]; v_prev timestamptz;
  v_cursor bigint := coalesce(p_after_id, 0); v_last bigint := coalesce(p_after_id, 0);
  v_scanned int := 0; reused int := 0; v_more boolean;
  runs jsonb := '[]'; probe jsonb := '[]'; browser jsonb := '[]'; v_no_reuse jsonb;
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role' then
    raise exception 'dev_journeys_plan: runner only';
  end if;
  select coalesce(value->'journeys', '{}'::jsonb) into v_cfg from dev_runner_config where key = 'worker_pool';
  v_cfg := coalesce(v_cfg, '{}'::jsonb);
  v_limit := greatest(1, least(coalesce(p_limit, nullif(v_cfg->>'max_per_run', '')::int, 8), 40));
  select coalesce((value->'qa'->>'journey_reuse_min')::int, 60) into v_reuse_min
    from dev_runner_config where key = 'worker_pool';
  v_reuse_min := greatest(coalesce(v_reuse_min, 60), 0);
  -- CMD #2075 — kinds that may never reuse an earlier pass (browser journeys):
  -- a screen must be driven again on every command, never inherited.
  v_no_reuse := coalesce(_dev_fj_cfg()->'no_reuse_kinds', '["browser"]'::jsonb);
  select nullif(btrim(coalesce(resume_commit, '')), '') into v_commit from dev_commands where id = p_command_id;
  v_files := coalesce(public.dev_cmd_footprint(p_command_id), '{}');

  for j in
    select dj.id, dj.name, dj.required, dj.files, dj.probe_on, dj.kind, dj.runner
      from dev_journeys dj
     where dj.enabled
       and (dj.area is null or dj.area = p_area)
       and dj.id > v_cursor
       and (dj.area is null or dj.files is null
            or coalesce(array_length(dj.files, 1), 0) = 0
            or coalesce(array_length(public.dev_paths_conflict(dj.files, v_files), 1), 0) > 0)
     order by dj.id
     limit v_limit
  loop
    v_scanned := v_scanned + 1; v_last := j.id; v_prev := null;
    -- CMD #2075 — a playwright journey is driven by scripts/autotest/feature_journey.js,
    -- never by the API probe; it is listed so the caller knows it exists.
    if coalesce(j.runner, 'probe') = 'playwright' then
      browser := browser || jsonb_build_object('journey_id', j.id, 'name', j.name, 'required', j.required, 'lane', 'browser');
      continue;
    end if;
    if v_commit is not null and v_reuse_min > 0 and not (v_no_reuse ? coalesce(j.kind, 'api')) then
      select r.at into v_prev from dev_journey_runs r
       where r.journey_id = j.id and r.status = 'passed' and r.commit_sha = v_commit
         and r.at > now() - make_interval(mins => v_reuse_min)
       order by r.at desc limit 1;
    end if;
    if v_prev is not null then
      reused := reused + 1;
      insert into dev_journey_runs(command_id, journey_id, status, evidence, duration_ms, commit_sha)
      values (p_command_id, j.id, 'passed',
              jsonb_build_object('reused', true, 'reused_from', v_prev, 'commit', v_commit, 'window_min', v_reuse_min),
              0, v_commit);
      runs := runs || jsonb_build_object('journey', j.name, 'status', 'passed', 'reused', true,
                'evidence', jsonb_build_object('reused_from', v_prev), 'duration_ms', 0);
      continue;
    end if;
    probe := probe || jsonb_build_object('journey_id', j.id, 'name', j.name, 'required', j.required,
                                         'probe_on', coalesce(j.probe_on, 'production'));
  end loop;

  if reused > 0 then
    update dev_commands set journey_pass_count = journey_pass_count + reused where id = p_command_id;
  end if;
  select exists (select 1 from dev_journeys where enabled and (area is null or area = p_area) and id > v_last)
    into v_more;
  return jsonb_build_object('ok', true, 'area', p_area, 'commit', coalesce(v_commit, ''),
    'to_probe', probe, 'browser_lane', browser, 'reused', reused, 'reused_runs', runs, 'reuse_window_min', v_reuse_min,
    'no_reuse_kinds', v_no_reuse,
    'scanned', v_scanned, 'row_ceiling', v_limit,
    'has_more', coalesce(v_more, false), 'next_after_id', v_last);
end $function$;

-- ── 11. the deploy card knows the new phase ────────────────────────────────
-- direct_deploy.sh reports 'journey' after the lock is released and before
-- 'deployed', while the feature journey runs on medibo.in.
create or replace function public._deploy_direct_phase(p_status text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case p_status
    when 'starting'     then jsonb_build_object('where','queue','word','starting')
    when 'waiting_lock' then jsonb_build_object('where','queue','word','waiting for the deploy lock')
    when 'merging'      then jsonb_build_object('where','lock','word','merging the branch onto the live base')
    when 'testing'      then jsonb_build_object('where','lock','word','running the protected suite')
    when 'building'     then jsonb_build_object('where','lock','word','building the web bundle')
    when 'migrating'    then jsonb_build_object('where','lock','word','replaying migrations on live')
    when 'verifying'    then jsonb_build_object('where','lock','word','verifying live')
    when 'journey'      then jsonb_build_object('where','done','word','running the feature journey on medibo.in')
    when 'deployed'     then jsonb_build_object('where','done','word','live')
    when 'failed'       then jsonb_build_object('where','done','word','failed')
    else jsonb_build_object('where','lock','word', p_status)
  end
$function$;

commit;

-- CMD #1950 — MOBILE-FIRST BUILD RULE, the production half.
-- 99% of mediBO users are on phones, so "it works on a phone" stops being a
-- habit and becomes a guard: the rule text lives in config, and rg_check goes
-- red when the rule goes missing or when a top screen overflows on a phone.
-- Idempotent: every statement is create-if-not-exists / on-conflict.

-- 1 ── the rule, mirrored onto production so rg can read it without a second
--      database. The control-plane copy (dev_runner_config on the dev-queue
--      project) is what the runner prompt reads; this copy is what the guard
--      asserts. They are the same text, kept in step by rg.
insert into dev_runner_config (key, value) values ('build_rules', '{}'::jsonb)
  on conflict (key) do nothing;

update dev_runner_config
   set value = jsonb_set(coalesce(value,'{}'::jsonb), '{mobile_first}', $j${
  "gate": "c_mobile_first",
  "rule": "Design, build, QA and screenshot proof on a phone viewport (360px and 412px) FIRST; desktop/web is secondary and must not degrade the phone layout",
  "why": "99% of mediBO users are on phones.",
  "proof_widths": [360, 412],
  "sweep_widths": [320, 360, 412, 480],
  "tablet_width": 768,
  "min_touch_px": 44,
  "change": 1950
}$j$::jsonb, true)
 where key = 'build_rules';

-- 2 ── verdicts a browser writes and SQL asserts. rg_check runs inside
--      Postgres; it cannot open a page. The responsive sweep does that after
--      every deploy and reports here, exactly as rg_config_verdict_write
--      already does for the config registry.
create table if not exists rg_runner_verdict (
  name        text primary key,
  ok          boolean not null,
  detail      text,
  payload     jsonb   not null default '{}'::jsonb,
  build_hash  text,
  at          timestamptz not null default now()
);
revoke all on rg_runner_verdict from anon, authenticated;

create or replace function public.rg_runner_verdict_write(
  p_name text, p_ok boolean, p_detail text default null,
  p_payload jsonb default '{}'::jsonb, p_build_hash text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'rg_runner_verdict_write: runner only';
  end if;
  insert into rg_runner_verdict(name, ok, detail, payload, build_hash, at)
       values (p_name, coalesce(p_ok,false), p_detail, coalesce(p_payload,'{}'::jsonb), p_build_hash, now())
    on conflict (name) do update
       set ok = excluded.ok, detail = excluded.detail, payload = excluded.payload,
           build_hash = excluded.build_hash, at = now();
  return jsonb_build_object('ok', true, 'name', p_name, 'verdict_ok', coalesce(p_ok,false), 'at', now());
end $$;
revoke all on function public.rg_runner_verdict_write(text,boolean,text,jsonb,text) from anon, authenticated;
grant execute on function public.rg_runner_verdict_write(text,boolean,text,jsonb,text) to service_role;

create or replace function public.rg_runner_verdict_read(p_name text)
returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce((select to_jsonb(v) from rg_runner_verdict v where v.name = p_name), 'null'::jsonb);
$$;
revoke all on function public.rg_runner_verdict_read(text) from anon, authenticated;
grant execute on function public.rg_runner_verdict_read(text) to service_role;

-- 3 ── (a) the rule itself cannot quietly disappear.
insert into rg_behavior_tests (name, enabled, note, body) values (
 'mobile_first_rule_present', true,
 'CMD #1950 — mobile-first is the default: build_rules.mobile_first must exist with its rule text and the phone proof widths, and the runner prompt builder must still inject it (verdict mobile_first_prompt, written by scripts/responsive_sweep.js).',
 $t$do $b$
declare v jsonb; v_verdict jsonb; v_max_age int;
begin
  select value->'mobile_first' into v from dev_runner_config where key='build_rules';
  if v is null or coalesce(v->>'rule','') = '' then
    raise exception 'RG_FAIL: dev_runner_config.build_rules.mobile_first is missing or has no rule text (CMD #1950). 99%% of mediBO users are on phones — the rule is what makes the phone viewport the default.';
  end if;
  if coalesce(v->>'gate','') <> 'c_mobile_first' then
    raise exception 'RG_FAIL: build_rules.mobile_first.gate is %, expected c_mobile_first', coalesce(v->>'gate','(null)');
  end if;
  if not (v->'proof_widths' @> '360'::jsonb and v->'proof_widths' @> '412'::jsonb) then
    raise exception 'RG_FAIL: build_rules.mobile_first.proof_widths must contain 360 and 412, found %', coalesce(v->>'proof_widths','(null)');
  end if;

  -- The other half of the rule lives in the runner prompt builder, which no
  -- SQL can read. The sweep greps it and reports the answer here; a verdict
  -- that says "not injected" is as red as a missing config key. A verdict that
  -- has never been written is "not measured yet", not a regression.
  select to_jsonb(r) into v_verdict from rg_runner_verdict r where r.name='mobile_first_prompt';
  select coalesce((value->'mobile_first'->>'verdict_max_age_h')::int, 72)
    into v_max_age from dev_runner_config where key='worker_pool';
  if v_verdict is not null then
    if not coalesce((v_verdict->>'ok')::boolean,false) then
      raise exception 'RG_FAIL: the runner prompt builder no longer injects the mobile-first rule — %',
        coalesce(v_verdict->>'detail','(no detail)');
    end if;
    if (v_verdict->>'at')::timestamptz < now() - make_interval(hours => coalesce(v_max_age,72)) then
      raise exception 'RG_FAIL: the mobile_first_prompt verdict is stale (last written %) — scripts/responsive_sweep.js has not run since',
        (v_verdict->>'at');
    end if;
  end if;
  raise exception 'RG_ROLLBACK';
end $b$;$t$)
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

-- 4 ── (b) no top screen may overflow on a phone.
insert into rg_behavior_tests (name, enabled, note, body) values (
 'responsive_no_overflow', true,
 'CMD #1950 — after every deploy scripts/responsive_sweep.js loads the top staff and customer screens at 320/360/412/480 px (plus one tablet width) and reads the render log the app writes about itself. Any Flutter overflow, an unpainted screen, or a tap target under the configured minimum makes the verdict red, and this turns rg_check red with the screen and the width named.',
 $t$do $b$
declare v_verdict jsonb; v_max_age int;
begin
  select to_jsonb(r) into v_verdict from rg_runner_verdict r where r.name='responsive_no_overflow';
  select coalesce((value->'mobile_first'->>'verdict_max_age_h')::int, 72)
    into v_max_age from dev_runner_config where key='worker_pool';

  -- Never measured is not a regression: the first sweep writes the verdict and
  -- every deploy after re-writes it. A timeout is not a measurement (#962).
  if v_verdict is not null then
    if not coalesce((v_verdict->>'ok')::boolean,false) then
      raise exception 'RG_FAIL: a top screen overflows on a phone viewport — %',
        coalesce(v_verdict->>'detail','(no detail)');
    end if;
    if (v_verdict->>'at')::timestamptz < now() - make_interval(hours => coalesce(v_max_age,72)) then
      raise exception 'RG_FAIL: the responsive sweep has not run since % — the phone layouts are unproven',
        (v_verdict->>'at');
    end if;
  end if;
  raise exception 'RG_ROLLBACK';
end $b$;$t$)
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

-- 5 ── the sweep reads the rule rather than re-typing it.
create or replace function public.dev_build_rules()
returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(value, '{}'::jsonb) from dev_runner_config where key='build_rules';
$$;
revoke all on function public.dev_build_rules() from anon, authenticated;
grant execute on function public.dev_build_rules() to service_role;

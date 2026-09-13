-- CMD #1950 — MOBILE-FIRST BUILD RULE (control plane: dev-queue project only).
-- This file is NOT replayed by the deploy lane (migration_replay.sh only runs
-- supabase/migrations/ against production). It is applied by hand with:
--   psql "$(cat ~/.medibo/dev_dburl)" -f supabase/devqueue/1950_mobile_first.sql
-- It is idempotent; re-running it is a no-op.
--
-- 99% of mediBO users are on phones, so the phone viewport is the DEFAULT for
-- every command, the same way zone/date scoping is. The rule text itself lives
-- in dev_runner_config.build_rules.mobile_first — the runner prompt and the app
-- render it verbatim, so the wording is an UPDATE, never a deploy.

begin;

-- 1 ── the rule (backend-owned copy; gate name c_mobile_first) ──────────────
update dev_runner_config
   set value = jsonb_set(coalesce(value,'{}'::jsonb), '{mobile_first}', $j${
  "gate": "c_mobile_first",
  "rule": "Design, build, QA and screenshot proof on a phone viewport (360px and 412px) FIRST; desktop/web is secondary and must not degrade the phone layout",
  "why": "99% of mediBO users are on phones.",
  "proof_widths": [360, 412],
  "sweep_widths": [320, 360, 412, 480],
  "tablet_width": 768,
  "min_touch_px": 44,
  "change": 1950,
  "verdict": "rg_runner_verdict — responsive_no_overflow / mobile_first_prompt",
  "prompt_line": "MOBILE-FIRST (build_rules.mobile_first, gate c_mobile_first): 99% of mediBO users are on phones. Design, build, QA and screenshot proof on a phone viewport (360px and 412px) FIRST; desktop/web is secondary and must not degrade the phone layout. Layouts adapt fluidly to any width - no fixed widths, no horizontal overflow, text scales, chips wrap or scroll, every tap target >= 44px. A UI command with no 360px AND 412px capture in dev-cmd-proofs cannot complete (finish gate condition \"mobile proof\"): devcmd.sh phoneproof <id> <url>."
}$j$::jsonb, true)
 where key = 'build_rules';

-- 2 ── enforcement knob: pool_set flips it, no deploy. effective_at protects
--      every command that was already in flight when the rule landed.
update dev_runner_config
   set value = jsonb_set(coalesce(value,'{}'::jsonb), '{mobile_first}',
         coalesce(value->'mobile_first','{}'::jsonb) || jsonb_build_object(
           'enforce', coalesce((value->'mobile_first'->>'enforce')::boolean, true),
           'desktop_min_px', coalesce((value->'mobile_first'->>'desktop_min_px')::int, 900),
           'verdict_max_age_h', coalesce((value->'mobile_first'->>'verdict_max_age_h')::int, 72),
           'effective_at', coalesce(value->'mobile_first'->>'effective_at', now()::text)
         ), true)
 where key = 'worker_pool';

-- 3 ── the proof ledger learns the viewport it was captured at ──────────────
alter table dev_proof_ledger add column if not exists width_px int;
create index if not exists dev_proof_ledger_cmd_width_idx
  on dev_proof_ledger (command_id, width_px);

drop function if exists public.dev_proof_note(text, bigint);
create or replace function public.dev_proof_note(
  p_name text, p_command_id bigint default null, p_width_px int default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_cmd bigint;
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role' then
    raise exception 'dev_proof_note: runner only';
  end if;
  v_cmd := coalesce(p_command_id,
             nullif((regexp_match(p_name, '^(?:cmd[-_]?)?(\d+)/'))[1], '')::bigint);
  insert into dev_proof_ledger(name, command_id, width_px)
       values (p_name, v_cmd, p_width_px)
    on conflict (name) do update
       set command_id = coalesce(excluded.command_id, dev_proof_ledger.command_id),
           width_px   = coalesce(excluded.width_px,   dev_proof_ledger.width_px),
           at = now();
  return jsonb_build_object('ok', true, 'name', p_name, 'command_id', v_cmd,
                            'width_px', p_width_px);
end $$;

-- 4 ── one place decides whether a command has phone proof ──────────────────
create or replace function public._dev_mobile_proof(p_id bigint)
returns jsonb language sql stable security definer set search_path=public as $$
  with cfg as (
    select coalesce((value->'mobile_first'->>'desktop_min_px')::int, 900) as desk_px
      from dev_runner_config where key='worker_pool'
  ), p as (
    select l.width_px, l.at from dev_proof_ledger l
     where l.command_id = p_id
        or l.name ~ ('^(cmd[-_]?)?' || p_id::text || '/')
  ), w as (
    select min(at) filter (where width_px = 360) as at360,
           min(at) filter (where width_px = 412) as at412,
           min(at) filter (where width_px >= (select desk_px from cfg)) as atdesk,
           count(*) as n
      from p
  )
  select jsonb_build_object(
    'has_360', at360 is not null,
    'has_412', at412 is not null,
    'phone_first', atdesk is null
                   or (at360 is not null and at412 is not null
                       and greatest(at360, at412) <= atdesk),
    'total', n,
    'ok', at360 is not null and at412 is not null
          and (atdesk is null or greatest(at360, at412) <= atdesk),
    'detail', case
      when at360 is null and at412 is null
        then 'no 360px or 412px capture in dev-cmd-proofs — run: devcmd.sh phoneproof '||p_id||' <url>'
      when at360 is null
        then 'no 360px capture — run: devcmd.sh phoneproof '||p_id||' <url>'
      when at412 is null
        then 'no 412px capture — run: devcmd.sh phoneproof '||p_id||' <url>'
      when atdesk is not null and greatest(at360, at412) > atdesk
        then 'a desktop capture was taken before the phone captures — the phone viewport comes first'
      else '360px + 412px captured first' end)
  from w;
$$;

-- 5 ── the card chip: "Phone proof" once both captures exist ────────────────
create or replace function public._dev_phone_proof_chip(p_id bigint)
returns text language sql stable security definer set search_path=public as $$
  select case when (_dev_mobile_proof(p_id)->>'ok')::boolean then '📱 Phone proof'
              when (_dev_mobile_proof(p_id)->>'has_360')::boolean
                or (_dev_mobile_proof(p_id)->>'has_412')::boolean then '📱 Phone proof partial'
              else '' end;
$$;

create or replace function public._dev_phone_proof_tone(p_id bigint)
returns text language sql stable security definer set search_path=public as $$
  select case when (_dev_mobile_proof(p_id)->>'ok')::boolean then 'success'
              when (_dev_mobile_proof(p_id)->>'has_360')::boolean
                or (_dev_mobile_proof(p_id)->>'has_412')::boolean then 'warning'
              else 'neutral' end;
$$;

commit;

-- 6 ── doors the runner uses (the rule text is read, never re-typed) ────────
create or replace function public.dev_build_rules()
returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(value, '{}'::jsonb) from dev_runner_config where key='build_rules';
$$;

create or replace function public.dev_mobile_proof(p_id bigint)
returns jsonb language sql stable security definer set search_path=public as $$
  select _dev_mobile_proof(p_id);
$$;

grant execute on function public.dev_build_rules() to service_role, authenticated;
grant execute on function public.dev_mobile_proof(bigint) to service_role, authenticated;

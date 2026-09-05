-- CHANGE #1761 — medibo-dev overrides, part 2 (journeys that probe the control plane itself).
-- Applied ON medibo-dev after medibo_dev_overrides.sql and after the _journey_* bundle
-- (supabase/dev/medibo_dev_journey_fns.sql, extracted verbatim from production).
--
-- A journey probe runs wherever the tables it reads live: almost all read app data and
-- run on production; the few that inspect dev tables (bug-821, qa-1149-508, …) run HERE.
-- `dev_journeys.probe_on` says which, `dev_journeys_plan` hands it to devcmd.sh, and the
-- registry itself is mirrored back to production (mutation audits there still read it).

alter table public.dev_journeys add column if not exists probe_on text not null default 'production';
alter table public.dev_journeys drop constraint if exists dev_journeys_probe_on_chk;
alter table public.dev_journeys add constraint dev_journeys_probe_on_chk check (probe_on in ('production', 'dev'));

-- Journeys whose probe function reads a moved table run on the control plane.
update public.dev_journeys set probe_on = 'dev'
 where name in ('bug-821', 'qa-1149-508', 'qa319-version', 'qa-319-version');

create or replace function public.dev_journeys_plan(p_command_id bigint, p_area text,
                                                    p_after_id bigint default null, p_limit integer default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  j record; v_cfg jsonb; v_limit int; v_reuse_min int; v_commit text; v_files text[]; v_prev timestamptz;
  v_cursor bigint := coalesce(p_after_id, 0); v_last bigint := coalesce(p_after_id, 0);
  v_scanned int := 0; reused int := 0; v_more boolean;
  runs jsonb := '[]'; probe jsonb := '[]';
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
  select nullif(btrim(coalesce(resume_commit, '')), '') into v_commit from dev_commands where id = p_command_id;
  v_files := coalesce(public.dev_cmd_footprint(p_command_id), '{}');

  for j in
    select dj.id, dj.name, dj.required, dj.files, dj.probe_on
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
    if v_commit is not null and v_reuse_min > 0 then
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
    'to_probe', probe, 'reused', reused, 'reused_runs', runs, 'reuse_window_min', v_reuse_min,
    'scanned', v_scanned, 'row_ceiling', v_limit,
    'has_more', coalesce(v_more, false), 'next_after_id', v_last);
end $$;

-- The registry is mirrored to production (mutation audits and the production-side probe
-- read it there). Fire-and-forget, one row per change.
create or replace function public._dev_journeys_mirror_trg()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_url text; v_key text; v_row jsonb;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'PROD_SUPABASE_URL';
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'PROD_SERVICE_ROLE_KEY';
  if v_url is null or v_key is null then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then
    perform net.http_delete(
      url := v_url || '/rest/v1/dev_journeys?id=eq.' || old.id,
      headers := jsonb_build_object('apikey', v_key, 'Authorization', 'Bearer ' || v_key),
      timeout_milliseconds := 8000);
    return old;
  end if;
  v_row := to_jsonb(new);
  perform net.http_post(
    url := v_url || '/rest/v1/dev_journeys?on_conflict=id',
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', v_key,
                                  'Authorization', 'Bearer ' || v_key,
                                  'Prefer', 'resolution=merge-duplicates,return=minimal'),
    body := jsonb_build_array(v_row),
    timeout_milliseconds := 8000);
  return new;
exception when others then
  return coalesce(new, old);
end $$;
drop trigger if exists dev_journeys_mirror_to_prod on public.dev_journeys;
create trigger dev_journeys_mirror_to_prod
  after insert or update or delete on public.dev_journeys
  for each row execute function public._dev_journeys_mirror_trg();

-- The real probe (restored from production in the bundle) may run here for probe_on='dev'
-- journeys; anything else asked of it here is refused loudly rather than guessed.
grant execute on function public.dev_journey_probe(text) to service_role;
revoke execute on function public.dev_journey_probe(text) from public, anon, authenticated;

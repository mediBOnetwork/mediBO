-- CHANGE #290 — mutation_trial_suite: break ONE target, run the WHOLE suite.
--
-- mutation_trial() (shipped earlier in this command) answers "does the journey
-- that owns this target notice when the target breaks?". The audit spec asks a
-- second, stricter question: with one target broken, what does the ENTIRE suite
-- say? That catches two failure modes a single-journey trial cannot see:
--
--   * a journey that goes red for a break that has nothing to do with it
--     (cross-talk — one broken target poisoning an unrelated verdict), and
--   * a suite that stays 100% green while a real target is broken, which is the
--     exact "audit theatre" this command exists to end.
--
-- Same atomicity contract as mutation_trial: the break and every probe run
-- inside one plpgsql exception block (a real subtransaction) that is ALWAYS
-- left by RAISE, so Postgres reverts the mutation for us. plpgsql variables are
-- not transactional, so the verdict survives the rollback. Nothing can leave
-- residue — not even a probe that dies half way.
--
-- Idempotent: create or replace + revoke. Re-applying is a no-op.

create or replace function public.mutation_trial_suite(p_journey text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
set statement_timeout to '900000'
as $$
declare
  v_recipe jsonb;
  v_before jsonb := '{}'::jsonb;
  v_after  jsonb := '{}'::jsonb;
  v_rows bigint := 0;
  v_err text := null;
  v_caught boolean := null;
  v_collateral jsonb := '[]'::jsonb;
  j record;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'mutation_trial_suite: runner only';
  end if;
  if not exists (select 1 from dev_journeys where name = p_journey and enabled) then
    return jsonb_build_object('journey', p_journey, 'verdict', 'unknown_journey');
  end if;

  v_recipe := _mutation_recipe(p_journey);
  if v_recipe is null then
    return jsonb_build_object('journey', p_journey, 'verdict', 'no_recipe');
  end if;

  -- Baseline: the whole suite, untouched.
  for j in select name from dev_journeys where enabled order by id loop
    v_before := v_before || jsonb_build_object(j.name, (dev_journey_probe(j.name))->>'status');
  end loop;

  if coalesce(v_before->>p_journey,'') <> 'passed' then
    return jsonb_build_object('journey', p_journey, 'mutation', v_recipe->>'mutation',
      'baseline', v_before, 'verdict', 'baseline_not_passed');
  end if;

  begin
    execute (v_recipe->>'sql');
    get diagnostics v_rows = row_count;
    if (v_recipe->>'kind') = 'dml' and v_rows = 0 then
      raise exception using errcode = 'MUT00', message = 'mutation affected 0 rows';
    end if;

    for j in select name from dev_journeys where enabled order by id loop
      v_after := v_after || jsonb_build_object(j.name, (dev_journey_probe(j.name))->>'status');
    end loop;

    -- Always leave by the exception door: that is what reverts the mutation.
    raise exception using errcode = 'MUT01', message = 'planned rollback';
  exception
    when sqlstate 'MUT01' then null;
    when sqlstate 'MUT00' then v_err := 'mutation affected 0 rows';
    when others then v_err := sqlerrm;
  end;

  if v_err is not null then
    return jsonb_build_object('journey', p_journey, 'mutation', v_recipe->>'mutation',
      'baseline', v_before, 'error', v_err, 'verdict', 'not_applied', 'reverted', true);
  end if;

  v_caught := coalesce(v_after->>p_journey,'') is distinct from 'passed';

  -- Every OTHER journey whose verdict moved. A non-empty list is cross-talk:
  -- one broken target changed a verdict that does not belong to it.
  select coalesce(jsonb_agg(jsonb_build_object(
           'journey', k, 'before', v_before->>k, 'after', v_after->>k)), '[]'::jsonb)
    into v_collateral
  from jsonb_object_keys(v_before) k
  where k <> p_journey and (v_before->>k) is distinct from (v_after->>k);

  return jsonb_build_object(
    'journey',    p_journey,
    'mutation',   v_recipe->>'mutation',
    'rows',       v_rows,
    'baseline',   v_before,
    'after',      v_after,
    'caught',     v_caught,
    'collateral', v_collateral,
    'verdict',    case when v_caught then 'caught' else 'escaped' end,
    'reverted',   true);
end $$;

revoke execute on function public.mutation_trial_suite(text) from public, anon, authenticated;

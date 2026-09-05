-- CHANGE #635 — the PROMOTE half of the critical-path smoke gate.
--
-- It is a separate file because it is on the other side of #1761's split:
-- preview_mark writes dev_commands, which lives on the CONTROL PLANE, while
-- test_runs — the record of whether the smoke passed — stayed on production.
-- No function can read across the two, so the verdict is computed on
-- production (test_smoke_gate(), in 20260905180000_c635_journey_bot.sql),
-- carried by the merge worker, and REFUSED here.
--
-- What this actually guarantees, stated honestly: a promote that arrives
-- carrying a FAILED smoke is refused, and a promote that arrives carrying no
-- smoke at all is recorded as such instead of being indistinguishable from a
-- proven one. The merge worker is what guarantees the smoke runs; this is what
-- makes its verdict binding and its absence visible.

alter table public.dev_commands
  add column if not exists smoke_status text,
  add column if not exists smoke_commit text;

drop function if exists public.preview_mark(bigint, text);
drop function if exists public.preview_mark(bigint, text, text);
create or replace function public.preview_mark(
  p_command_id bigint,
  p_status     text,
  p_commit     text default null,
  p_smoke      text default null)   -- 'passed' | 'failed' | null (did not run)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_smoke text := nullif(p_smoke, '');
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'preview_mark: runner only';
  end if;
  if p_status not in ('deployed','promoted') then raise exception 'preview_mark: bad status'; end if;

  update public.dev_commands
     set smoke_status = coalesce(v_smoke, smoke_status),
         smoke_commit = coalesce(nullif(p_commit,''), smoke_commit)
   where id = p_command_id;

  -- 'deployed' is never blocked: the build IS live on preview, and saying it
  -- is not would be a lie. Only the PROMOTE — the claim that this is the
  -- change that shipped — waits on the smoke.
  if p_status = 'promoted' and v_smoke = 'failed' then
    return jsonb_build_object('ok', false, 'blocked', true, 'status','deployed',
      'smoke', v_smoke,
      'message', 'Critical-path smoke failed for ' || coalesce(nullif(p_commit,''),'this build') ||
                 ' — deployed, not promoted.');
  end if;

  update public.dev_commands set preview_status = p_status where id = p_command_id;
  return jsonb_build_object('ok', true, 'status', p_status, 'smoke', coalesce(v_smoke,'not_run'));
end $function$;

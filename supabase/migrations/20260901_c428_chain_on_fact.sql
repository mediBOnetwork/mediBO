-- CHANGE #428 (2/3) — chain on FACT, not on two guesses.
--
-- 20260901_c428_chain_exempt.sql exempted the shared append-only surfaces and
-- capped depends_on, and that took #427 from 20 blockers to 3. It was not
-- enough: 24 of 28 pending rows were still chained, and every remaining chain
-- was two PREDICTIONS meeting on a god-file. cust_pay_panel.dart appears in 19
-- pending specs and admin_upi_screen.dart in 17, because file_predict_rule
-- fires on the words "bill", "payment" and "gst". Neither command has claimed,
-- neither has planned its files, and most of them will never open that file.
--
-- A prediction is a guess. Two guesses are not a conflict. What #327 was built
-- for was #325 parking because #326 was BUILDING and HOLDING home_shell.dart —
-- a FACT, on the lease table. That case still chains, and it is the only one
-- that does: a pending command is held back only when its prediction hits a
-- path a building command genuinely holds.
--
-- Everything else is left to the runtime guard that cannot be fooled: two
-- writers still never share a file, because lease_try_all / lease_try_split say
-- so, and a contended path is DEFERRED inside the build (#327 layer 3) instead
-- of parking a whole command before it starts.
--
-- Reversible with no deploy: worker_pool.chain.require_lease = false restores
-- prediction-vs-prediction chaining (still exempt-filtered and still capped).
--
-- Idempotent: create-or-replace / on-conflict throughout.

create or replace function public.dev_cmd_leased_footprint(p_id bigint)
returns text[]
language sql stable
security definer
set search_path to 'public'
as $$
  -- the ACTUAL footprint only — never the prediction fallback that
  -- dev_cmd_footprint() carries for a command that has not leased yet
  select coalesce((select array_agg(path) from file_leases where command_id = p_id), '{}');
$$;
revoke all on function public.dev_cmd_leased_footprint(bigint) from anon;

create or replace function public.dev_cmd_autochain(p_id bigint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r record; v_all bigint[]; v_paths text[]; v_blockers bigint[];
  v_reason text; v_tpl text; v_tpl_f text; v_max int; v_fact boolean;
  n int := 0; v_capped int := 0; v_out jsonb := '[]'::jsonb;
begin
  select coalesce((value->'chain'->>'max_blockers')::int, 3),
         coalesce((value->'chain'->>'require_lease')::boolean, true)
    into v_max, v_fact
    from dev_runner_config where key = 'worker_pool';
  v_max  := greatest(coalesce(v_max, 3), 1);
  v_fact := coalesce(v_fact, true);

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
    -- FIRST-ORDER ONLY: `o` is judged on its own footprint and never on what
    -- o itself is queued behind, so a chain can never grow down the queue.
    select coalesce(array_agg(o.id order by o.id), '{}')
      into v_all
      from dev_commands o
     where o.id <> r.id
       and coalesce(array_length(r.predicted_files,1),0) > 0
       and case when v_fact
                then o.status = 'building'
                else o.id < r.id and o.status in ('pending','building') end
       and coalesce(array_length(
             dev_paths_conflict(
               case when v_fact then dev_cmd_leased_footprint(o.id)
                    else dev_cmd_footprint(o.id) end,
               r.predicted_files), 1), 0) > 0;

    v_blockers := v_all[1:v_max];
    if coalesce(array_length(v_all,1),0) > v_max then
      v_capped := v_capped + 1;
    end if;

    select coalesce(array_agg(distinct p), '{}')
      into v_paths
      from unnest(coalesce(v_blockers,'{}')) bid,
           unnest(dev_paths_conflict(
                    case when v_fact then dev_cmd_leased_footprint(bid)
                         else dev_cmd_footprint(bid) end,
                    r.predicted_files)) p;

    -- drop every auto-dep this pass no longer justifies; keep manual ones
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
                            'max_blockers', v_max, 'require_lease', v_fact,
                            'rows', v_out);
end $function$;

insert into ui_copy (key, value) values
  ('dev_queue.chain_chip_held', to_jsonb('Queued after {ids} — holding {files} right now'::text))
on conflict (key) do nothing;

update dev_runner_config
   set value = jsonb_set(value, '{chain}',
        coalesce(value->'chain','{}'::jsonb) ||
        jsonb_build_object(
          'require_lease', true,
          'note', 'CHANGE #428 — a chain needs a FACT: the blocker must be BUILDING and actually hold the file lease. Two predictions never chain each other; exempt surfaces and globs never chain at all; file leases are the runtime guard.'),
        true)
 where key = 'worker_pool';

-- Post-deploy correction (same command): `revoke ... from anon` above does
-- NOT remove the grant anon actually holds — that one comes from PUBLIC, which
-- every function inherits by default. So these three helpers shipped executable
-- by an anonymous caller, leaking repo file paths and live lease state. They
-- are internal helpers of SECURITY DEFINER callers (which run as owner and are
-- unaffected), so PUBLIC loses execute and service_role keeps it.
revoke all on function public.dev_path_is_shared(text) from public, anon, authenticated;
revoke all on function public.dev_paths_conflict(text[], text[]) from public, anon, authenticated;
revoke all on function public.dev_cmd_leased_footprint(bigint) from public, anon, authenticated;
revoke all on function public.dev_chain_watchdog() from public, anon, authenticated;

grant execute on function public.dev_path_is_shared(text) to service_role;
grant execute on function public.dev_paths_conflict(text[], text[]) to service_role;
grant execute on function public.dev_cmd_leased_footprint(bigint) to service_role;
grant execute on function public.dev_chain_watchdog() to service_role;

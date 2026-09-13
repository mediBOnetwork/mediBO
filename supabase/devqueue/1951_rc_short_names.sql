-- CMD #1951 — SHORT REMOTE CONTROL SESSION NAMES (control plane: dev-queue only).
-- This file is NOT replayed by the deploy lane (migration_replay.sh only runs
-- supabase/migrations/ against production). It is applied by hand with:
--   psql "$(cat ~/.medibo/dev_dburl)" -f supabase/devqueue/1951_rc_short_names.sql
-- It is idempotent; re-running it is a no-op.
--
-- Sessions were named "mediBO · runner-1 · #1948 Harness: …" and the Claude app
-- truncated before the TITLE — the one field that says which build a card is —
-- had started. The new name is "mBO • R1 · #1948 · <title>": the fixed part is
-- as short as it can be, the id stays in front of the title, and the title is
-- passed through WHOLE (the app does its own truncation; a name trimmed twice
-- loses exactly the words that tell two builds apart).
--
-- The name itself is composed in ONE place — mediBO-runner/remote_control.sh,
-- `remote_control.sh name <agent> [id] [title]`. supervisor.sh asks that script
-- for each worker chip's short_id/session_name, so the Dev Queue card and the
-- phone's Code list cannot drift apart. This file holds the two things that
-- live in the database: the config the script reads, and the strip's label.

begin;

-- 1 ── the config the name is built from (prefix / runner_short / sep) ───────
update dev_runner_config
   set value = jsonb_set(coalesce(value,'{}'::jsonb), '{remote_control}',
        coalesce(value->'remote_control','{}'::jsonb) || jsonb_build_object(
          'prefix',       'mBO',
          'runner_short', 'R',
          'sep',          '•',
          'name_note',    'CMD #1951 — the session name Om reads on his phone. Format: <prefix> <sep> <runner_short><n> · #<id> · <title>; host and deploy keep their word in place of the slot. The title is NOT trimmed here — the Claude app truncates, and a name trimmed twice loses the words that tell two builds apart.'))
 where key = 'worker_pool';

insert into dev_config_registry
  (key_path, description, type, default_value, owner_change, read_by, label, editable)
values
 ('worker_pool.remote_control.runner_short',
  'Short letter the Remote Control name uses for a runner slot', 'string', '"R"'::jsonb, 1951,
  '{harness:remote_control.sh,harness:supervisor.sh}', 'Runner short form', false),
 ('worker_pool.remote_control.sep',
  'Separator between the prefix and the slot in a Remote Control name', 'string', '"•"'::jsonb, 1951,
  '{harness:remote_control.sh,harness:supervisor.sh}', 'Name separator', false)
on conflict (key_path) do update
   set description   = excluded.description,
       type          = excluded.type,
       default_value = excluded.default_value,
       owner_change  = excluded.owner_change,
       read_by       = excluded.read_by,
       label         = excluded.label,
       updated_at    = now();

-- 2 ── the runner strip prints the same short slot the phone shows ──────────
-- label was w->>'id' ("runner-4"). It is now the short_id the naming script
-- itself composed, with the whole session name carried alongside it so the
-- card can show what the Code list shows. Older snapshots (written before the
-- supervisor started sending short_id) still fall back to the raw agent id.
create or replace function public.strip_v3_workers()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare ps jsonb; out_j jsonb := '[]'::jsonb; w jsonb; v_pend int;
begin
  select value into ps from dev_runner_config where key = 'pool_state';
  ps := coalesce(ps, '{}'::jsonb);
  for w in select value from jsonb_array_elements(coalesce(ps->'workers','[]'::jsonb)) loop
    select count(*) into v_pend from runner_action_queue
     where agent = w->>'id' and done_at is null;
    out_j := out_j || jsonb_build_array(jsonb_build_object(
      'agent',  w->>'id',
      'label',  coalesce(nullif(w->>'short_id',''), nullif(w->>'id',''), '—'),
      'session_name', coalesce(w->>'session_name',''),
      'status', coalesce(w->>'status',''),
      'title',  coalesce(w->>'title',''),
      'sub',    trim(both ' ·' from concat_ws(' · ', nullif(w->>'meta',''),
                     case when (w->>'command_id') is null then null else '#'||(w->>'command_id') end,
                     nullif(w->>'eta_display',''))),
      'tone',   case coalesce(w->>'status','') when 'building' then 'info'
                     when 'idle' then 'neutral' when 'offline' then 'danger' else 'neutral' end,
      'busy',   v_pend > 0,
      'actions', jsonb_build_array(
        jsonb_build_object('key','restart',
          'label', public._c_or('dev_queue.worker_restart','Restart'), 'tone','neutral',
          'confirm', public._c_or('dev_queue.worker_restart_confirm','Restart this worker? Its command goes back to the queue.')),
        jsonb_build_object('key','kill',
          'label', public._c_or('dev_queue.worker_kill','Stop'), 'tone','danger',
          'confirm', public._c_or('dev_queue.worker_kill_confirm','Stop this worker? Its command goes back to the queue.')))));
  end loop;
  return out_j;
end $function$;

commit;

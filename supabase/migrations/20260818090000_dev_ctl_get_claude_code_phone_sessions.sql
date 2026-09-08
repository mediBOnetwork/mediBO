-- CHANGE #237 — surface the Claude Code (Anthropic Remote Control) sessions.
--
-- Applied live 2026-08-18. Recorded here so a rebuilt database reproduces it.
--
-- runner_status.remote_control is mediBO's OWN live-view bridge (#233/#772).
-- It says "On phone" whenever medibo-bridge is reachable, which is why the Dev
-- Queue looked healthy while Om's Claude Code app listed no devices at all:
-- they are two different bridges and only one of them was ever running.
--
-- phone_sessions / phone_names are written by supervisor.sh from
-- `remote_control.sh status` — the count of live Claude sessions that actually
-- hold an Anthropic bridgeSessionId. That is the same fact the phone app lists,
-- so >0 here means a non-empty device list there.
--
-- Idempotent by design (#233): re-applying it is a silent no-op.

insert into ui_copy(key, value) values
  ('dev_queue.ctl_phone_on',        '"Claude app · {n} live"'::jsonb),
  ('dev_queue.ctl_phone_off',       '"Claude app · no session"'::jsonb),
  ('dev_queue.ctl_phone_hint_on',   '"Open Claude Code on your phone — each worker slot is listed by command id."'::jsonb),
  ('dev_queue.ctl_phone_hint_off',  '"No worker has opened a Remote Control session yet. It appears when a slot starts or claims a build."'::jsonb)
on conflict (key) do update set value = excluded.value;

do $mig$
declare
  v_def text;
  v_anchor text := $a$    'remote_tone', CASE WHEN v_rc='on' THEN 'success' ELSE 'neutral' END);$a$;
  v_add text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'dev_ctl_get';

  if v_def is null then
    raise exception 'dev_ctl_get not found';
  end if;

  if position('phone_display' in v_def) > 0 then
    return;
  end if;

  if position(v_anchor in v_def) = 0 then
    raise exception 'dev_ctl_get: remote_tone anchor not found — refusing to patch blind';
  end if;

  v_add := v_anchor || E'\n' || $a$
  -- ── Claude Code Remote Control sessions (CHANGE #237) ─────────────────────
  -- Separate from remote_control above: that is mediBO's bridge, this is the
  -- Anthropic session bridge that populates the Claude Code app's device list.
  v_rs := v_rs || jsonb_build_object(
    'phone_sessions', CASE WHEN v_rs_stale THEN 0
                           ELSE coalesce((v_rs->>'phone_sessions')::int, 0) END,
    'phone_names',    CASE WHEN v_rs_stale THEN '[]'::jsonb
                           ELSE coalesce(v_rs->'phone_names', '[]'::jsonb) END);
  v_rs := v_rs || jsonb_build_object(
    'phone_display', CASE WHEN (v_rs->>'phone_sessions')::int > 0
        THEN replace((SELECT value#>>'{}' FROM ui_copy WHERE key='dev_queue.ctl_phone_on'),
                     '{n}', (v_rs->>'phone_sessions'))
        ELSE (SELECT value#>>'{}' FROM ui_copy WHERE key='dev_queue.ctl_phone_off') END,
    'phone_tone', CASE WHEN (v_rs->>'phone_sessions')::int > 0 THEN 'success' ELSE 'warning' END,
    'phone_hint', CASE WHEN (v_rs->>'phone_sessions')::int > 0
        THEN (SELECT value#>>'{}' FROM ui_copy WHERE key='dev_queue.ctl_phone_hint_on')
        ELSE (SELECT value#>>'{}' FROM ui_copy WHERE key='dev_queue.ctl_phone_hint_off') END);$a$;

  v_def := replace(v_def, v_anchor, v_add);
  execute v_def;
end $mig$;

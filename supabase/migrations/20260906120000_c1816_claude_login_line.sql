-- CHANGE #1816 — Claude login state on the Runner card. DISPLAY ONLY.
--
-- #1369 tried to do this and grew into doctor checks, a claim gate, phone
-- re-login and a churn breaker; it was cancelled. This file deliberately does
-- none of that: no alert, no gate, no re-login, no auto-anything. It reads the
-- VM's real credential facts, keeps them in dev_runner_config, and renders one
-- sentence plus two sub-lines the card prints verbatim.
--
-- The expiry a human means is claudeAiOauth.refreshTokenExpiresAt — .expiresAt
-- is the ACCESS token and rotates in hours, so a line built on it would say
-- "expires in 4 hours" twice a day and mean nothing.
--
-- NOTHING here guesses a date. The last-login moment is not written anywhere on
-- the box, so it is DERIVED FROM OBSERVATION: the VM reports a fingerprint of
-- the refresh token (never the token), and the first tick that sees a NEW
-- fingerprint is the login. Until a change has been observed the line says
-- "credential first seen …", which is true, instead of a made-up login time.

-- ── 1. the writer — the VM reports facts, the BACKEND decides what changed ───
create or replace function public.claude_login_write(
  p_host        text,
  p_expires_at  timestamptz default null,
  p_cred_fp     text default null,
  p_cli_version text default null
) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_cur     jsonb;
  v_prev_fp text;
  v_login   timestamptz;
  v_source  text;
  v_has     boolean;
  v_changed boolean := false;
  v_next    jsonb;
begin
  perform _dev_guard();

  select value into v_cur from dev_runner_config where key = 'claude_login';
  v_prev_fp := nullif(v_cur->>'cred_fp', '');
  v_has     := coalesce(nullif(p_cred_fp, ''), '') <> '';

  if not v_has then
    -- The credential file is gone or unreadable. Keep the last known login so
    -- the card can still say when it was, and mark the credential absent.
    v_login  := nullif(v_cur->>'login_at', '')::timestamptz;
    v_source := coalesce(nullif(v_cur->>'login_source', ''), 'first_seen');
  elsif v_prev_fp is null then
    v_login  := now();
    v_source := 'first_seen';
    v_changed := true;
  elsif v_prev_fp <> p_cred_fp then
    v_login  := now();
    v_source := 'observed';   -- a re-login actually happened while we watched
    v_changed := true;
  else
    v_login  := nullif(v_cur->>'login_at', '')::timestamptz;
    v_source := coalesce(nullif(v_cur->>'login_source', ''), 'first_seen');
  end if;

  v_next := jsonb_build_object(
    'host',         coalesce(nullif(p_host, ''), 'unknown'),
    'has_cred',     v_has,
    'cred_fp',      coalesce(nullif(p_cred_fp, ''), null),
    'expires_at',   p_expires_at,
    'login_at',     v_login,
    'login_source', v_source,
    'cli_version',  coalesce(nullif(p_cli_version, ''), null),
    'observed_at',  now());

  insert into dev_runner_config(key, value) values ('claude_login', v_next)
  on conflict (key) do update set value = excluded.value;

  return jsonb_build_object('ok', true, 'changed', v_changed,
                            'login_at', v_login, 'expires_at', p_expires_at);
end $fn$;

grant execute on function public.claude_login_write(text, timestamptz, text, text)
  to postgres, service_role;

-- ── 2. the reader — one sentence + its sub-lines, every word backend-owned ───
create or replace function public.claude_login_line()
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v          jsonb;
  v_exp      timestamptz;
  v_login    timestamptz;
  v_obs      timestamptz;
  v_secs     numeric;
  v_days     numeric;
  v_warn     numeric;
  v_stale    numeric;
  v_state    text;
  v_tone     text;
  v_status   text;
  v_left     text;
  v_lines    jsonb := '[]'::jsonb;
begin
  perform _dev_guard();

  select value into v from dev_runner_config where key = 'claude_login';
  -- Zone/date live in the header picker and are echoed, never re-picked here:
  -- a VM's login is host-scoped infrastructure with no zone or day dimension.
  if v is null then
    return jsonb_build_object('has', false,
      'zone', admin_active_zone(), 'date', admin_active_date());
  end if;

  v_exp   := nullif(v->>'expires_at', '')::timestamptz;
  v_login := nullif(v->>'login_at', '')::timestamptz;
  v_obs   := nullif(v->>'observed_at', '')::timestamptz;
  v_warn  := coalesce((select (value->'claude_login'->>'warn_days')::numeric
                         from dev_runner_config where key = 'worker_pool'), 3);
  v_stale := coalesce((select (value->'claude_login'->>'stale_min')::numeric
                         from dev_runner_config where key = 'worker_pool'), 20);

  if coalesce((v->>'has_cred')::boolean, false) is not true or v_exp is null then
    v_state  := 'missing';
    v_tone   := 'danger';
    v_status := _c_or('dev_queue.claude_login_missing',
                      'no credential on the VM · run /login there');
  else
    v_secs := extract(epoch from (v_exp - now()));
    v_days := v_secs / 86400.0;
    if v_secs <= 0 then
      v_state  := 'expired';
      v_tone   := 'danger';
      v_status := _c_or('dev_queue.claude_login_expired',
                        'expired · run /login on the VM');
    elsif v_days <= v_warn then
      v_state := 'soon';
      v_tone  := 'warning';
      v_left  := case
                   when v_days < 1 then _fmt_dur(v_secs)
                   when ceil(v_days) = 1 then _c_or('dev_queue.claude_login_day', '1 day')
                   else replace(_c_or('dev_queue.claude_login_days', '{n} days'),
                                '{n}', ceil(v_days)::int::text)
                 end;
      v_status := replace(_c_or('dev_queue.claude_login_soon', 'expires in {left}'),
                          '{left}', v_left);
    else
      v_state  := 'ok';
      v_tone   := 'neutral';
      v_status := _c_or('dev_queue.claude_login_ok', 'logged in');
    end if;
  end if;

  if v_login is not null then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'key',  'last_login',
      'text', replace(
        case when coalesce(v->>'login_source', '') = 'observed'
             then _c_or('dev_queue.claude_login_last', 'last login {when}')
             else _c_or('dev_queue.claude_login_first', 'credential first seen {when}')
        end, '{when}', _ist_stamp(v_login) || ' IST')));
  end if;

  if v_exp is not null then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'key',  'valid_until',
      'text', replace(_c_or('dev_queue.claude_login_valid', 'valid until {when}'),
                      '{when}', _ist_stamp(v_exp) || ' IST')));
  end if;

  -- A reading nobody has refreshed says so, rather than letting a frozen date
  -- read as current. Still display: no alert is raised anywhere.
  if v_obs is null or extract(epoch from (now() - v_obs)) / 60.0 > v_stale then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'key',  'read',
      'text', replace(_c_or('dev_queue.claude_login_read', 'last read {age}'),
                      '{age}', coalesce(nullif(_ist_age(v_obs), ''), '—'))));
  end if;

  return jsonb_build_object(
    'has',    true,
    'state',  v_state,
    'tone',   v_tone,
    'label',  _c_or('dev_queue.claude_login_label', 'Claude login'),
    'status', v_status,
    'title',  _c_or('dev_queue.claude_login_label', 'Claude login') || ' — ' || v_status,
    'lines',  v_lines,
    'host',   coalesce(v->>'host', ''),
    'zone',   admin_active_zone(),
    'date',   admin_active_date());
end $fn$;

grant execute on function public.claude_login_line()
  to postgres, anon, authenticated, service_role;

-- ── 3. it rides dev_ctl_get, so the card needs no second call ────────────────
-- Patched from the definition that is live at replay time so this file never
-- reverts an unrelated change to that composer.
do $mig$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'dev_ctl_get' limit 1;
  if v_src is null then return; end if;
  if position('claude_login' in v_src) > 0 then return; end if;

  v_new := replace(v_src,
    'declare v jsonb; v_ctx jsonb; v_blocked jsonb; v_disk jsonb; v_auth jsonb; v_branch jsonb;',
    'declare v jsonb; v_ctx jsonb; v_blocked jsonb; v_disk jsonb; v_auth jsonb; v_branch jsonb; v_login jsonb;');
  v_new := replace(v_new,
    'begin v_branch := public.build_branch_card();',
    'begin v_login := public.claude_login_line();
  exception when others then v_login := jsonb_build_object(''has'', false);
  end;
  begin v_branch := public.build_branch_card();');
  v_new := replace(v_new,
    '''claude_auth'', v_auth, ''build_branch'', v_branch)',
    '''claude_auth'', v_auth, ''build_branch'', v_branch, ''claude_login'', v_login)');

  if v_new = v_src then
    raise notice 'c1816: dev_ctl_get shape changed — claude_login not spliced';
    return;
  end if;
  execute v_new;
end $mig$;

-- ── 4. every visible word ───────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('dev_queue.claude_login_label',   to_jsonb('Claude login'::text)),
  ('dev_queue.claude_login_ok',      to_jsonb('logged in'::text)),
  ('dev_queue.claude_login_soon',    to_jsonb('expires in {left}'::text)),
  ('dev_queue.claude_login_day',     to_jsonb('1 day'::text)),
  ('dev_queue.claude_login_days',    to_jsonb('{n} days'::text)),
  ('dev_queue.claude_login_expired', to_jsonb('expired · run /login on the VM'::text)),
  ('dev_queue.claude_login_missing', to_jsonb('no credential on the VM · run /login there'::text)),
  ('dev_queue.claude_login_last',    to_jsonb('last login {when}'::text)),
  ('dev_queue.claude_login_first',   to_jsonb('credential first seen {when}'::text)),
  ('dev_queue.claude_login_valid',   to_jsonb('valid until {when}'::text)),
  ('dev_queue.claude_login_read',    to_jsonb('last read {age}'::text))
on conflict (key) do nothing;

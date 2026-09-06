-- CHANGE #1816 (follow-up) — the login line must not depend on helpers that
-- only exist on the BUILD BRANCH.
--
-- The first cut used _ist_stamp() and _ist_age(). Both exist on the branch every
-- build runs against, so every state tested green there — and on PRODUCTION the
-- RPC answered `function _ist_stamp(timestamp with time zone) does not exist`,
-- i.e. the card's one line was an error the moment it went live. The branch is
-- AHEAD of production by whatever every other in-flight command has applied to
-- it; a display RPC may only lean on functions that are demonstrably live.
--
-- Same reason the dev_ctl_get splice in the first file quietly did nothing on
-- production: that composer's source there is not the source the branch holds.
-- The card now reads claude_login_line() itself, so nothing depends on winning
-- a text patch against a shared function.
--
-- So: two private helpers, owned by this change, and no other new dependency.

create or replace function public._c1816_ist(p_ts timestamptz)
returns text language sql immutable set search_path = public as $fn$
  select case when p_ts is null then ''
              else to_char(p_ts at time zone 'Asia/Kolkata', 'DD Mon YYYY, hh12:mi AM') end;
$fn$;

create or replace function public._c1816_age(p_ts timestamptz)
returns text language sql stable set search_path = public as $fn$
  select case
    when p_ts is null then ''
    when now() - p_ts < interval '1 minute' then 'just now'
    when now() - p_ts < interval '1 hour'
      then (extract(epoch from now() - p_ts)::int / 60)::text || 'm ago'
    when now() - p_ts < interval '1 day'
      then (extract(epoch from now() - p_ts)::int / 3600)::text || 'h ago'
    else (extract(epoch from now() - p_ts)::int / 86400)::text || 'd ago'
  end;
$fn$;

grant execute on function public._c1816_ist(timestamptz) to postgres, anon, authenticated, service_role;
grant execute on function public._c1816_age(timestamptz) to postgres, anon, authenticated, service_role;

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
                   when v_secs < 86400
                     then (v_secs / 3600)::int::text || 'h'
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
        end, '{when}', _c1816_ist(v_login) || ' IST')));
  end if;

  if v_exp is not null then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'key',  'valid_until',
      'text', replace(_c_or('dev_queue.claude_login_valid', 'valid until {when}'),
                      '{when}', _c1816_ist(v_exp) || ' IST')));
  end if;

  -- A reading nobody has refreshed says so, rather than letting a frozen date
  -- read as current. Still display: no alert is raised anywhere.
  if v_obs is null or extract(epoch from (now() - v_obs)) / 60.0 > v_stale then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'key',  'read',
      'text', replace(_c_or('dev_queue.claude_login_read', 'last read {age}'),
                      '{age}', coalesce(nullif(_c1816_age(v_obs), ''), '—'))));
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

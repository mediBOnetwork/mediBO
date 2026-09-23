-- CMD #2172 — the bottom bars: the banner is JOINED to the nav, its ground and
-- its round icon are the BACKEND's, and the nav hides on scroll.
--
-- WHAT WAS WRONG ON LIVE
--  1. The banner's ground (#F3FAF5) and its glyph (Icons.settings_outlined /
--     person_outline / assignment_outlined) were Dart literals inside
--     DockBarRow, so "make the banner white" was a deploy. Om's design now says
--     the ground is WHITE and the round icon carries its own two colours — none
--     of which Dart is allowed to know.
--  2. `shell.nav_hide_on_scroll` was 'false', so #2080's driver ran and the bar
--     never moved a pixel. The behaviour shipped switched off.
--
-- Everything here is one UPDATE away from being retuned again: the style lives
-- in app_settings, the switch lives in ui_copy, and no colour, icon key or
-- distance is written in Dart.

-- ── 1. The style, per bar kind ──────────────────────────────────────────────
-- One row, one object per kind, so a new kind is an UPDATE and an unknown kind
-- falls back to the shared default rather than to a Dart guess.
insert into public.app_settings (key, value)
values ('shell.bar_style', jsonb_build_object(
  'default', jsonb_build_object(
    'bg',       '#FFFFFF',
    'icon_url', '',
    'icon_key', 'info',
    'icon_bg',  '#F3FAF5',
    'icon_fg',  '#1B7A43'),
  'update', jsonb_build_object(
    'bg',       '#FFFFFF',
    'icon_url', '',
    'icon_key', 'update',
    'icon_bg',  '#F3FAF5',
    'icon_fg',  '#1B7A43'),
  'login', jsonb_build_object(
    'bg',       '#FFFFFF',
    'icon_url', '',
    'icon_key', 'person',
    'icon_bg',  '#F3FAF5',
    'icon_fg',  '#1B7A43'),
  'registration', jsonb_build_object(
    'bg',       '#FFFFFF',
    'icon_url', '',
    'icon_key', 'assignment',
    'icon_bg',  '#F3FAF5',
    'icon_fg',  '#1B7A43')))
-- DO NOTHING, never DO UPDATE: a replay of this file must not undo a colour an
-- admin has since changed. The seed is a starting point, not a re-assertion.
on conflict (key) do nothing;

-- The reader. Merged over 'default' so a kind that was never given a row of its
-- own still answers with a complete object, and every key is always present —
-- absence is explicit ('' for no image), never a missing field the app has to
-- invent a value for.
create or replace function public.shell_bar_style(p_kind text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with cfg as (
    select coalesce((select value from public.app_settings
                      where key = 'shell.bar_style'), '{}'::jsonb) as v
  )
  select jsonb_build_object(
           'bg',       '#FFFFFF',
           'icon_url', '',
           'icon_key', '',
           'icon_bg',  '#FFFFFF',
           'icon_fg',  '#111827')
      || coalesce((select v->'default' from cfg), '{}'::jsonb)
      || coalesce((select v->coalesce(p_kind,'') from cfg), '{}'::jsonb)
  from cfg;
$function$;

-- It is read only from inside the two SECURITY DEFINER bars, which run as the
-- owner, so nothing outside needs EXECUTE on it (§ every new RPC gets a grant
-- review — this one is deliberately not reachable).
revoke all on function public.shell_bar_style(text) from public;
revoke all on function public.shell_bar_style(text) from anon;
revoke all on function public.shell_bar_style(text) from authenticated;

-- ── 2. The banner's style rides its own payload ─────────────────────────────
create or replace function public.customer_registration_bar()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_reg  jsonb;
  v_pend jsonb;
begin
  -- CMD #2114 — SIGNED OUT IS AN ASK, NOT A SILENCE. A visitor who has never
  -- logged in had no way of knowing there was anything to log in to: the bar
  -- slot was empty for exactly the person who needed it most.
  if auth.uid() is null then
    return jsonb_build_object(
      'show',         true,
      'kind',         'login',
      'reason',       'signed_out',
      'title',        coalesce(nullif(public._c('loginbar.title'),''), 'New Here?'),
      'cta',          coalesce(nullif(public._c('loginbar.cta'),''),   'Login'),
      'route',        '/login',
      'anchor',       '',
      -- CMD #2172 — the banner's ground and its round icon.
      'style',        public.shell_bar_style('login'),
      'poll_seconds', 300);
  end if;

  begin
    v_reg := public.customer_registration_payload();
  exception when others then
    return jsonb_build_object('show', false, 'kind', 'none', 'reason', 'error');
  end;

  if coalesce((v_reg->>'needs')::boolean, false) is not true then
    return jsonb_build_object('show', false, 'kind', 'none', 'reason', 'nothing_owed');
  end if;

  v_pend := coalesce(v_reg->'docs_pending', '{}'::jsonb);

  return jsonb_build_object(
    'show',         true,
    'kind',         'registration',
    'reason',       case when coalesce((v_pend->>'show')::boolean, false)
                         then 'documents_pending' else 'registration_pending' end,
    -- ONE sentence, whatever is owed: the pill has a single line and the
    -- detail belongs on the form, not on a strip above the bottom nav.
    'title',        public._c('custreg.bar_title'),
    'cta',          public._c('custreg.bar_cta'),
    'route',        coalesce(nullif(v_reg->>'route',''), '/complete-registration'),
    -- Resume lands on the papers when the papers are what is out.
    -- Imported by staff and not started yet → open at General, not the papers.
    'anchor',       case when coalesce((v_pend->>'show')::boolean, false)
                          and not coalesce((v_reg->>'fresh_import')::boolean, false)
                         then 'documents' else '' end,
    'required_left', coalesce((v_reg->>'required_left')::int, 0),
    -- CMD #2172 — same block the login bar reads, so the two asks cannot drift.
    'style',        public.shell_bar_style('registration'),
    'poll_seconds', 300);
end
$function$;

create or replace function public.app_update_bar(
  p_platform text default 'web',
  p_version_code integer default 0,
  p_build text default null,
  p_live_build text default null)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  -- An old bundle cannot report Play's verdict (it never asked), so Android
  -- gets 'unknown' here — which is exactly the answer that keeps the bar off
  -- a phone Play has nothing for. The web half is unchanged.
  select public.app_update_check(
           p_platform,
           case when lower(coalesce(p_platform, 'web')) = 'android'
                then nullif(coalesce(p_version_code, 0), 0)::text
                else p_build end,
           p_live_build,
           null, null, null)
      || jsonb_build_object(
           'label',        _c('app_update_bar.label'),
           'button_label', _c('app_update_bar.button'),
           -- CMD #2172 — the update banner is the same row as the other two,
           -- so it reads its ground and its icon from the same place.
           'style',        public.shell_bar_style('update'),
           'bottom_gap',   coalesce((select (value->>'bottom_gap')::numeric
                                       from app_settings where key = 'app_update_bar'), 128));
$function$;

-- ── 3. The behaviour was switched off ──────────────────────────────────────
-- #2080 shipped the driver and left the flag 'false', so the nav never hid.
-- Om's design (#2172) makes it the behaviour on every customer tab.
insert into public.ui_copy (key, value)
values ('shell.nav_hide_on_scroll', 'true'::jsonb)
on conflict (key) do update set value = 'true'::jsonb;

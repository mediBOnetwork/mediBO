-- CMD #2114 — the LOGIN bar, and where a login and a logout land.
--
-- 1. A signed-out visitor never saw where to log in. The bottom-stack bar slot
--    (CMD #2066/#2091/#2112) already holds EITHER the update bar or the
--    registration bar; it now holds a third: "New Here?" with a Login button,
--    in the same box, same shape, same colour, same show logic.
--
--    ONE RPC decides all three asks, because one slot can only ever hold one:
--      signed out                    -> the LOGIN bar
--      signed in, registration owed  -> the REGISTRATION bar
--      signed in, nothing owed       -> no bar
--    The update bar outranks both and is decided on the device (Play / the web
--    version watcher), so the precedence update > login > registration is the
--    slot's, and this function never has to know about it.
--
--    `customer_registration_bar()` keeps its name and its shape — every word,
--    the button label, the address the button opens and the poll cadence are
--    still the backend's, and the payload now also names WHICH bar it is
--    (`kind`) so the app never has to infer that from a route.
--
-- 2. LANDING. After a login the user already lands on `home_route`, which
--    my_session() reads out of `login_role_config` keyed by `get_my_role()`.
--    That table is seeded here for every role get_my_role() can return, so no
--    role can fall through to the '/store' default. After a LOGOUT the user
--    lands on the mediBO public home, and that address is named by the backend
--    too: the `signed_out` row of the same table, published on every session
--    payload as `logout_route`.
--
-- Idempotent: safe to replay on live (CMD #1928).
begin;

-- ── 1. The words. ui_copy, so rewording is an UPDATE and never a deploy. ────
insert into public.ui_copy(key, value) values
  ('loginbar.title', to_jsonb('New Here?'::text)),
  ('loginbar.cta',   to_jsonb('Login'::text))
on conflict (key) do nothing;

-- ── 2. Where each role lives, and where a logout lands. ────────────────────
-- ON CONFLICT DO NOTHING: production already carries rows for the roles it has
-- configured and those wordings are Om's, not this migration's.
insert into public.login_role_config(role, home_route, home_label, sort) values
  ('super_admin', '/dashboard', 'Dashboard', 10),
  ('admin',       '/dashboard', 'Dashboard', 20),
  ('partner',     '/dashboard', 'Dashboard', 30),
  ('supplier',    '/supplier',  'Supplier',  40),
  ('delivery',    '/delivery',  'Delivery',  50),
  ('worker',      '/dashboard', 'Dashboard', 60),
  ('company',     '/dashboard', 'Dashboard', 70),
  ('mr',          '/dashboard', 'Dashboard', 80),
  ('customer',    '/store',     'Store',     90),
  -- The public home. `/` is the app root, which is the role-aware shell: with
  -- no account behind it that IS the mediBO public storefront.
  ('signed_out',  '/',          'mediBO',    99)
on conflict (role) do nothing;

-- ── 3. `logout_route` on every session payload. ────────────────────────────
-- A patch wrapper rather than an edit to my_session_core(): the same shape the
-- signup, header and partner patches already use, so one concern stays in one
-- readable function.
create or replace function public._session_logout_patch(p jsonb)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(p,'{}'::jsonb) || jsonb_build_object(
    'logout_route',
      coalesce((select nullif(btrim(home_route),'')
                from public.login_role_config where role = 'signed_out'), '/'),
    'logout_label',
      coalesce((select nullif(btrim(home_label),'')
                from public.login_role_config where role = 'signed_out'), ''));
$function$;

revoke all on function public._session_logout_patch(jsonb) from public;
grant execute on function public._session_logout_patch(jsonb) to anon, authenticated, service_role;

create or replace function public.my_session()
returns jsonb
language sql
security definer
set search_path to 'public'
as $function$
  select public._session_logout_patch(
           public._session_signup_patch(
             public._session_header_short(
               public._session_partner_overlay(public.my_session_core()))));
$function$;

-- ── 4. The one bar decision. ───────────────────────────────────────────────
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
    'anchor',       case when coalesce((v_pend->>'show')::boolean, false)
                         then 'documents' else '' end,
    'required_left', coalesce((v_reg->>'required_left')::int, 0),
    'poll_seconds', 300);
end
$function$;

-- PUBLIC ON PURPOSE (constraint #92, lesson 197). A signed-out visitor is
-- exactly who the login bar is for, so anon must be able to ask. The anon
-- branch reads nothing: it returns constants and two ui_copy strings, and it
-- returns BEFORE customer_registration_payload() is ever reached, so no
-- account state is exposed to an unauthenticated caller.
revoke all on function public.customer_registration_bar() from public;
grant execute on function public.customer_registration_bar() to anon, authenticated, service_role;

commit;

-- CMD #2059 — Customer onboarding: no forced registration redirect, an instant
-- form, an autosaved draft, and a login-derived prefill.
--
-- Four things changed, and all four are decided HERE:
--   1. Signing up no longer force-opens the registration form. `signup_route`
--      is what the login screen pushes on top of Home, so it is now gated on
--      app_settings.login_signup.signup_autoopen (default FALSE). The address
--      itself stays available as `signup_form_route`, because the banner, the
--      cart sheet and the step list all still need to name it. Turning the
--      old behaviour back on is one UPDATE, never a deploy.
--   2. `order_gate.action_kind` says HOW the blocker is answered. Only the
--      unregistered case answers with a sheet, and the backend says so.
--   3. `customer_registration_payload()` is the whole registration surface in
--      one object: the form schema, the prefill, the saved draft, the two
--      steps and every string around them. It rides along with the home feed
--      (storefront_home_v2().registration) so the form is already in the app's
--      hands before the user taps Continue.
--   4. `customer_reg_draft` keeps what was typed, field by field, so closing
--      the form — or the whole app — loses nothing.
--
-- Idempotent: every object is create-or-replace / if-not-exists, and every
-- ui_copy row is ON CONFLICT DO NOTHING so live wording is never reset.

-- ── 1. The draft ──────────────────────────────────────────────────────────
create table if not exists public.customer_reg_draft (
  auth_user_id uuid primary key,
  form_context text        not null default 'signup',
  data         jsonb       not null default '{}'::jsonb,
  updated_at   timestamptz not null default now(),
  created_at   timestamptz not null default now()
);

alter table public.customer_reg_draft enable row level security;

-- No policies by design: the draft is reached only through the security
-- definer RPCs below, which scope every read and write to auth.uid().
revoke all on table public.customer_reg_draft from anon, authenticated;

-- Merge a patch into this user's draft. One field change = one call; the
-- payload the app sends is a partial map, never the whole form.
create or replace function public.customer_reg_draft_save(
  p_patch jsonb, p_context text default 'signup')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_data jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'saved', false);
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    return jsonb_build_object('ok', false, 'saved', false);
  end if;

  insert into public.customer_reg_draft(auth_user_id, form_context, data)
  values (auth.uid(), coalesce(nullif(btrim(p_context),''), 'signup'), p_patch)
  on conflict (auth_user_id) do update
    set data = public.customer_reg_draft.data || excluded.data,
        form_context = excluded.form_context,
        updated_at = now()
  returning data into v_data;

  return jsonb_build_object(
    'ok', true, 'saved', true,
    'saved_label', public._c('custreg.draft_saved'),
    'fields', (select count(*) from jsonb_object_keys(coalesce(v_data,'{}'::jsonb))));
end $function$;

create or replace function public.customer_reg_draft_get(p_context text default 'signup')
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v jsonb;
begin
  if auth.uid() is null then return '{}'::jsonb; end if;
  select data into v from public.customer_reg_draft
   where auth_user_id = auth.uid()
     and form_context = coalesce(nullif(btrim(p_context),''), 'signup');
  return coalesce(v, '{}'::jsonb);
end $function$;

create or replace function public.customer_reg_draft_clear(p_context text default 'signup')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if auth.uid() is null then return jsonb_build_object('ok', false); end if;
  delete from public.customer_reg_draft
   where auth_user_id = auth.uid()
     and form_context = coalesce(nullif(btrim(p_context),''), 'signup');
  return jsonb_build_object('ok', true);
end $function$;

revoke all on function public.customer_reg_draft_save(jsonb, text) from public, anon;
revoke all on function public.customer_reg_draft_get(text) from public, anon;
revoke all on function public.customer_reg_draft_clear(text) from public, anon;
grant execute on function public.customer_reg_draft_save(jsonb, text) to authenticated, service_role;
grant execute on function public.customer_reg_draft_get(text) to authenticated, service_role;
grant execute on function public.customer_reg_draft_clear(text) to authenticated, service_role;

-- ── 2. Copy ───────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('custreg.step_of',          '"Step {n} of {total}"'::jsonb),
  ('custreg.step1_label',      '"Business details"'::jsonb),
  ('custreg.step2_label',      '"Documents"'::jsonb),
  ('custreg.state_done',       '"Done"'::jsonb),
  ('custreg.state_current',    '"Now"'::jsonb),
  ('custreg.state_todo',       '"Next"'::jsonb),
  ('custreg.progress_label',   '"{done} of {total} steps done"'::jsonb),
  ('custreg.draft_saved',      '"Saved"'::jsonb),
  ('custreg.draft_saving',     '"Saving…"'::jsonb),
  ('custreg.draft_resumed',    '"We kept what you filled in last time."'::jsonb),
  ('custreg.sheet_title',      '"Register to place your order"'::jsonb),
  ('custreg.sheet_line',       '"Your cart is saved. Fill these details and come straight back to it."'::jsonb),
  ('custreg.sheet_close',      '"Not now"'::jsonb),
  ('custreg.sheet_done',       '"Details saved — back to your cart."'::jsonb),
  ('custreg.banner_title',     '"Complete your registration"'::jsonb),
  ('custreg.banner_details',   '"Add your pharmacy details to start ordering."'::jsonb),
  ('custreg.banner_documents', '"Upload your documents to finish."'::jsonb),
  ('custreg.banner_cta',       '"Continue"'::jsonb),
  ('custreg.steps_title',      '"Registration"'::jsonb)
on conflict (key) do nothing;

-- ── 3. The registration surface, in one payload ───────────────────────────
-- Everything the form, the banner, the step strip and the cart sheet need.
-- The app holds this object and renders it; it computes nothing about it.
create or replace function public.customer_registration_payload()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_sess jsonb; v_needs_profile boolean := false; v_cid uuid;
  v_stage text; v_chk jsonb := '{}'::jsonb;
  v_step1 boolean := false; v_step2 boolean := false;
  v_done int := 0; v_left int := 0;
  v_schema jsonb := '{}'::jsonb; v_draft jsonb := '{}'::jsonb;
  v_map jsonb; v_pre jsonb := '{}'::jsonb; v_u record;
  v_route1 text; v_route2 text; v_needs boolean;
begin
  if auth.uid() is null then
    return jsonb_build_object('needs', false, 'stage', 'none', 'signed_in', false);
  end if;

  begin v_sess := public.my_session_core(); exception when others then v_sess := '{}'::jsonb; end;
  v_needs_profile := coalesce((v_sess->>'needs_profile')::boolean, false);
  v_cid := nullif(v_sess->>'customer_id','')::uuid;

  -- A staff or supplier account is not a half-registered pharmacy: the banner
  -- already refuses to show for them, and so does this.
  if not v_needs_profile and v_cid is null then
    return jsonb_build_object('needs', false, 'stage', 'none', 'signed_in', true);
  end if;

  v_route1 := coalesce(public.login_signup_cfg()->>'signup_route', '/complete-registration');
  v_route2 := '/customer/documents';

  v_step1 := (not v_needs_profile and v_cid is not null);

  if v_step1 then
    select registration_stage::text into v_stage from public.pharmacy_profiles where id = v_cid;
    begin v_chk := public.kyc_doc_checklist(); exception when others then v_chk := '{}'::jsonb; end;
    v_left  := coalesce((v_chk->>'required_left')::int, 0);
    v_step2 := coalesce((v_chk->>'done')::boolean, v_left = 0);
    if coalesce(v_stage,'') in ('approved','verified') then v_step2 := true; v_left := 0; end if;
  end if;

  v_done  := (case when v_step1 then 1 else 0 end) + (case when v_step2 then 1 else 0 end);
  v_needs := (v_done < 2);

  -- The form itself, and what the user already typed into it.
  if not v_step1 then
    begin v_schema := public.customer_form_schema('signup'); exception when others then v_schema := '{}'::jsonb; end;
    v_draft := public.customer_reg_draft_get('signup');

    -- Prefill from the identity they logged in with. Which form field each
    -- identity value belongs in is DATA, so a renamed field is an UPDATE.
    v_map := coalesce((select value from public.app_settings where key = 'signup_prefill_map'),
                      jsonb_build_object('name','customer_name','email','email','whatsapp','whatsapp_no'));
    select coalesce(nullif(btrim(coalesce(u.raw_user_meta_data->>'full_name','')),''),
                    nullif(btrim(coalesce(u.raw_user_meta_data->>'name','')),''),
                    '') as nm,
           case when lower(coalesce(u.email,'')) like
                     ('%@' || coalesce(public.login_signup_cfg()->>'internal_email_domain','wa.medibo.in'))
                then '' else coalesce(u.email,'') end as em,
           coalesce(nullif(right(regexp_replace(coalesce(u.phone,''),'\D','','g'),10),''),
                    coalesce(u.raw_user_meta_data->>'phone','')) as ph
      into v_u
      from auth.users u where u.id = auth.uid();
    v_pre := jsonb_strip_nulls(jsonb_build_object(
      coalesce(v_map->>'name','customer_name'),     nullif(coalesce(v_u.nm,''),''),
      coalesce(v_map->>'email','email'),            nullif(coalesce(v_u.em,''),''),
      coalesce(v_map->>'whatsapp','whatsapp_no'),   nullif(coalesce(v_u.ph,''),'')));
  end if;

  return jsonb_build_object(
    'signed_in', true,
    'needs',     v_needs,
    'stage',     case when not v_step1 then 'details'
                      when not v_step2 then 'documents'
                      else 'done' end,
    'route',     case when not v_step1 then v_route1 else v_route2 end,
    'title',     public._c('custreg.steps_title'),
    'step',      jsonb_build_object(
                   'n',     case when not v_step1 then 1 else 2 end,
                   'total', 2,
                   'label', public._cf('custreg.step_of', jsonb_build_object(
                              'n', (case when not v_step1 then 1 else 2 end)::text,
                              'total', '2')),
                   'done',  v_done,
                   'ratio', round(v_done::numeric / 2, 2),
                   'progress_label', public._cf('custreg.progress_label',
                              jsonb_build_object('done', v_done::text, 'total', '2'))),
    'steps', jsonb_build_array(
      jsonb_build_object(
        'n', 1, 'key', 'details',
        'label', public._c('custreg.step1_label'),
        'step_label', public._cf('custreg.step_of', jsonb_build_object('n','1','total','2')),
        'route', v_route1,
        'done', v_step1,
        'state', case when v_step1 then 'done' else 'current' end,
        'state_label', case when v_step1 then public._c('custreg.state_done')
                            else public._c('custreg.state_current') end),
      jsonb_build_object(
        'n', 2, 'key', 'documents',
        'label', public._c('custreg.step2_label'),
        'step_label', public._cf('custreg.step_of', jsonb_build_object('n','2','total','2')),
        'route', v_route2,
        'done', v_step2,
        'state', case when v_step2 then 'done'
                      when v_step1 then 'current' else 'todo' end,
        'state_label', case when v_step2 then public._c('custreg.state_done')
                            when v_step1 then public._c('custreg.state_current')
                            else public._c('custreg.state_todo') end)),
    'required_left', v_left,
    'schema',  v_schema,
    'prefill', v_pre,
    'draft',   v_draft,
    'has_draft', (v_draft <> '{}'::jsonb),
    'draft_note', case when v_draft <> '{}'::jsonb then public._c('custreg.draft_resumed') else '' end,
    'autosave', jsonb_build_object(
                  'enabled', true, 'debounce_ms', 800,
                  'saving_label', public._c('custreg.draft_saving'),
                  'saved_label',  public._c('custreg.draft_saved')),
    'sheet', jsonb_build_object(
               'title',        public._c('custreg.sheet_title'),
               'line',         public._c('custreg.sheet_line'),
               'close_label',  public._c('custreg.sheet_close'),
               'done_message', public._c('custreg.sheet_done')));
end $function$;

revoke all on function public.customer_registration_payload() from public, anon;
grant execute on function public.customer_registration_payload() to authenticated, service_role;

-- ── 4. my_session(): no forced redirect, a named form address, a prefilled
--      name, and a gate that says HOW it is answered ─────────────────────────
create or replace function public._session_signup_patch(p jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_cfg jsonb; v_auto boolean; v_gate jsonb; v_name text;
begin
  if p is null or coalesce((p->>'signed_in')::boolean, false) is not true then
    return coalesce(p, '{}'::jsonb);
  end if;
  v_cfg  := public.login_signup_cfg();
  v_auto := coalesce((v_cfg->>'signup_autoopen')::boolean, false);
  v_gate := coalesce(p->'order_gate', '{}'::jsonb);

  select coalesce(nullif(btrim(coalesce(u.raw_user_meta_data->>'full_name','')),''),
                  nullif(btrim(coalesce(u.raw_user_meta_data->>'name','')),''), '')
    into v_name from auth.users u where u.id = auth.uid();

  return p || jsonb_build_object(
    -- The login screen pushes signup_route on top of Home. Empty means it
    -- pushes nothing, which is the whole of "no forced redirect".
    'signup_route', case when v_auto then coalesce(p->>'signup_route','') else '' end,
    -- …and this is where that form lives, for everyone who asks on purpose.
    'signup_form_route', coalesce(v_cfg->>'signup_route','/complete-registration'),
    'signup_autoopen', v_auto,
    'signup_prefill', coalesce(p->'signup_prefill','{}'::jsonb)
                      || jsonb_build_object('name', coalesce(v_name,'')),
    'order_gate', v_gate || jsonb_build_object(
      'action_kind', case when coalesce(v_gate->>'reason','') = 'not_registered'
                          then 'registration_sheet' else '' end));
end $function$;

create or replace function public.my_session()
returns jsonb
language sql
security definer
set search_path to 'public'
as $function$
  select public._session_signup_patch(
           public._session_header_short(
             public._session_partner_overlay(public.my_session_core())));
$function$;

-- ── 5. The banner names BOTH steps ────────────────────────────────────────
create or replace function public.customer_registration_banner()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_reg jsonb;
begin
  if auth.uid() is null then return jsonb_build_object('show', false); end if;
  v_reg := public.customer_registration_payload();
  if coalesce((v_reg->>'needs')::boolean, false) is not true then
    return jsonb_build_object('show', false);
  end if;
  return jsonb_build_object(
    'show',  true,
    'stage', v_reg->>'stage',
    'required_left', coalesce((v_reg->>'required_left')::int, 0),
    'title', public._c('custreg.banner_title'),
    'line',  case when v_reg->>'stage' = 'details'
                  then public._c('custreg.banner_details')
                  else public._c('custreg.banner_documents') end,
    'cta',   public._c('custreg.banner_cta'),
    'route', v_reg->>'route',
    -- CMD #2059 — both steps are reachable from the banner, not just the
    -- current one, and each one says where it is.
    'steps', coalesce(v_reg->'steps', '[]'::jsonb),
    'step',  coalesce(v_reg->'step', '{}'::jsonb));
end $function$;

revoke all on function public.customer_registration_banner() from public, anon;
grant execute on function public.customer_registration_banner() to authenticated, service_role;

-- ── 6. The home feed carries the registration surface ─────────────────────
CREATE OR REPLACE FUNCTION public.storefront_home_v2(p_items integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_zone smallint; v_key text; v_n int := greatest(coalesce(p_items, 100), 1);
  v_cached jsonb; v_ords jsonb; v_built timestamptz; v_payload jsonb;
  v_rv jsonb; v_idx int; v_t0 timestamptz;
begin
  v_zone := public._viewer_zone_or_null();
  v_key  := coalesce('zone:' || v_zone::text, 'anon') || ':' || v_n;

  select payload, ords, built_at into v_cached, v_ords, v_built
    from public.storefront_home_cache where cache_key = v_key;

  -- An anonymous caller has a 3 s budget and a 2-4 s build: it NEVER rebuilds
  -- inline while any copy exists (the warm tick refreshes anon rows every few
  -- minutes; a stale hero number is worth more than a Retry screen). Approved
  -- viewers (8 s budget) rebuild a stale row themselves, one at a time.
  if v_cached is null or (v_zone is not null and v_built < now() - interval '10 minutes') then
    if v_cached is not null
       and not pg_try_advisory_xact_lock(hashtext('c678_home:' || v_key)) then
      v_payload := v_cached;                 -- someone else is rebuilding; stale is fine
    else
      v_t0 := clock_timestamp();
      v_payload := public._storefront_home_build(v_n);
      v_ords    := coalesce(v_payload -> '_ords', '[]'::jsonb);
      v_payload := v_payload - '_ords';
      insert into public.storefront_home_cache (cache_key, payload, ords, built_at, build_ms)
      values (v_key, v_payload, v_ords, now(),
              (extract(epoch from clock_timestamp() - v_t0) * 1000)::int)
      on conflict (cache_key) do update
        set payload = excluded.payload, ords = excluded.ords,
            built_at = now(), build_ms = excluded.build_ms;
    end if;
  else
    v_payload := v_cached;
  end if;

  if auth.uid() is not null then
    v_rv := public._storefront_home_recent(v_n);
    if v_rv is not null then
      select count(*) into v_idx
        from jsonb_array_elements_text(coalesce(v_ords, '[]'::jsonb)) o
       where o::int < (v_rv ->> '_ord')::int;
      v_payload := jsonb_set(v_payload, '{sections}',
        jsonb_insert(coalesce(v_payload -> 'sections', '[]'::jsonb),
                     array[v_idx::text], v_rv - '_ord'));
    end if;
  end if;

  -- CMD #2059 — the registration surface rides with the home feed, so the
  -- form is already in the app's hands before Continue is tapped. It is added
  -- AFTER the shared zone cache, because it is per-user.
  if auth.uid() is not null then
    begin
      v_payload := v_payload || jsonb_build_object(
        'registration', public.customer_registration_payload());
    exception when others then null;
    end;
  end if;

  return v_payload;
end
$function$;

-- storefront_home_v2 keeps the grants it already had (anon may read the feed);
-- the registration block is only built for a signed-in caller.

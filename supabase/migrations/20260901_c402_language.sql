-- CHANGE #402 (1 of 3) — PER-USER LANGUAGE.
--
-- Supplier screens already render every string through ui_copy (`c()`/`cf()`),
-- so the English-only problem was never in Dart: `ui_copy` held exactly one
-- value per key and `ui_boot()` handed it to everybody. This migration adds the
-- second value and the per-user preference that chooses between them, in the
-- BACKEND, so a language switch is a preference row — never a deploy and never
-- a Dart branch.
--
-- Fallback is a coalesce, not a decision: a key with no Hindi row resolves to
-- English, and the gap is REPORTED (ui_language_report) instead of hidden.
--
-- Every statement is idempotent — a resumed worker re-applies it silently.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. THE LANGUAGES, THE TRANSLATIONS, THE PREFERENCE
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.app_language (
  code         text primary key,
  label        text not null,          -- the name in English
  native_label text not null,          -- the name in its own script
  sort_order   int  not null default 100,
  is_active    boolean not null default true
);

insert into public.app_language(code, label, native_label, sort_order, is_active)
values ('en','English','English',10,true),
       ('hi','Hindi','हिन्दी',20,true)
on conflict (code) do update
  set label = excluded.label, native_label = excluded.native_label,
      sort_order = excluded.sort_order, is_active = true;

-- One row per (key, language). English lives in ui_copy and is NEVER duplicated
-- here — that is what makes English the guaranteed fallback for every key.
create table if not exists public.ui_copy_i18n (
  key        text not null,
  lang       text not null references public.app_language(code) on delete cascade,
  value      jsonb not null,
  source     text,                     -- 'seed' | 'admin' | …
  updated_at timestamptz not null default now(),
  updated_by text,
  primary key (key, lang)
);

create index if not exists ui_copy_i18n_lang_idx on public.ui_copy_i18n (lang);

alter table public.ui_copy_i18n enable row level security;

-- Readable by everyone (the storefront boots anonymously and must get words);
-- writable only through the admin RPC below.
drop policy if exists ui_copy_i18n_read on public.ui_copy_i18n;
create policy ui_copy_i18n_read on public.ui_copy_i18n for select using (true);

create table if not exists public.user_language_pref (
  user_id    uuid primary key,
  lang       text not null references public.app_language(code) on delete cascade,
  updated_at timestamptz not null default now()
);

alter table public.user_language_pref enable row level security;

drop policy if exists user_language_pref_self on public.user_language_pref;
create policy user_language_pref_self on public.user_language_pref
  for select using (user_id = auth.uid());

-- Which surfaces are EXPECTED to be translated. A gap inside a scope is a
-- reportable hole; a key outside every scope is simply not in scope yet, so
-- the report never drowns in 3,200 admin-only strings.
create table if not exists public.ui_i18n_scope (
  prefix     text primary key,
  label      text not null,
  sort_order int not null default 100,
  is_active  boolean not null default true
);

insert into public.ui_i18n_scope(prefix, label, sort_order, is_active) values
  ('supplier_shell.',    'Supplier shell',        10, true),
  ('supplier_home.',     'Supplier home',         20, true),
  ('supplier_inquiry.',  'Supplier inquiry',      30, true),
  ('supplier_orders.',   'Supplier orders',       40, true),
  ('supplier_disputes.', 'Supplier disputes',     50, true),
  ('supplier_add_med.',  'Supplier add medicine', 60, true),
  ('supplier_staff.',    'Supplier staff',        70, true),
  ('supplier_payout.',   'Supplier payout',       80, true),
  ('supplier_lang.',     'Language switch',       90, true)
on conflict (prefix) do update
  set label = excluded.label, sort_order = excluded.sort_order, is_active = true;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. RESOLUTION — one place decides which language a caller reads
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.my_language()
returns text
language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(
    (select p.lang
       from user_language_pref p
       join app_language al on al.code = p.lang and al.is_active
      where p.user_id = auth.uid()),
    'en')
$function$;

-- The string a caller should read for one key. Every RPC in this change writes
-- its copy through this, so a Hindi user gets Hindi from an RPC payload for the
-- same reason they get it from ui_boot: one resolver, one fallback rule.
create or replace function public.ui_text(p_key text)
returns text
language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(
    nullif((select i.value #>> '{}' from ui_copy_i18n i
             where i.key = p_key and i.lang = public.my_language()), ''),
    nullif((select c.value #>> '{}' from ui_copy c where c.key = p_key), ''),
    '')
$function$;

-- Same, with {placeholders} filled. The WORDING stays backend-owned; only the
-- value is substituted.
create or replace function public.ui_text_f(p_key text, p_vars jsonb default '{}'::jsonb)
returns text
language plpgsql stable security definer set search_path to 'public'
as $function$
declare s text := public.ui_text(p_key); k text;
begin
  if s = '' or p_vars is null then return s; end if;
  for k in select jsonb_object_keys(p_vars) loop
    s := replace(s, '{' || k || '}', coalesce(p_vars ->> k, ''));
  end loop;
  return s;
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. THE BOOT PAYLOAD — same signature, now language-resolved
-- ═══════════════════════════════════════════════════════════════════════════

-- Hindi over English, key by key. A missing/blank Hindi row falls through to
-- the English value, so the app can never render an empty screen because a
-- translation is late.
create or replace function public.ui_copy_all()
returns jsonb
language sql security definer set search_path to 'public'
as $function$
  with l as (select public.my_language() as lang)
  select coalesce(jsonb_object_agg(s.key, s.value), '{}'::jsonb)
  from (
    select b.key,
           coalesce(
             (select i.value from ui_copy_i18n i, l
               where i.key = b.key and i.lang = l.lang and l.lang <> 'en'
                 and nullif(i.value #>> '{}', '') is not null),
             b.value) as value
      from ui_copy b
  ) s
$function$;

-- The language block the app renders verbatim: which language is on, what the
-- other options are called in their OWN script, and the words for the switch.
create or replace function public.ui_language_block()
returns jsonb
language sql stable security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
    'code',   public.my_language(),
    'label',  (select al.native_label from app_language al where al.code = public.my_language()),
    'title',  public.ui_text('supplier_lang.title'),
    'subtitle', public.ui_text('supplier_lang.subtitle'),
    'options', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', al.code,
               'label', al.native_label,
               'sub_label', al.label,
               'selected', al.code = public.my_language())
             order by al.sort_order, al.code)
        from app_language al where al.is_active), '[]'::jsonb))
$function$;

create or replace function public.ui_boot()
returns jsonb
language sql security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
    'copy',     public.ui_copy_all(),
    'design',   ui_design_get(),
    'language', public.ui_language_block())
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. THE SWITCH
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.ui_language_get()
returns jsonb
language sql stable security definer set search_path to 'public'
as $function$
  select public.ui_language_block() || jsonb_build_object('ok', true)
$function$;

create or replace function public.ui_language_set(p_lang text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_uid uuid := auth.uid(); v_ok boolean;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in', 'tone', 'danger',
      'message', public.ui_text('supplier_lang.err_not_signed_in'));
  end if;
  select true into v_ok from app_language where code = p_lang and is_active;
  if not coalesce(v_ok,false) then
    return jsonb_build_object('ok', false, 'error', 'unknown_language', 'tone', 'danger',
      'message', public.ui_text('supplier_lang.err_unknown'));
  end if;

  insert into user_language_pref(user_id, lang, updated_at)
  values (v_uid, p_lang, now())
  on conflict (user_id) do update set lang = excluded.lang, updated_at = now();

  -- Composed AFTER the write, so the confirmation already speaks the new
  -- language — the switch proves itself.
  return public.ui_language_block()
       || jsonb_build_object('ok', true, 'tone', 'success',
                             'message', public.ui_text('supplier_lang.saved'));
exception when others then
  return jsonb_build_object('ok', false, 'error', 'exception', 'tone', 'danger',
    'message', replace(public.ui_text('supplier_lang.err_failed'), '{detail}', SQLERRM),
    'sqlstate', SQLSTATE);
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. THE GAP REPORT — a fallback is visible, never silent
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.ui_language_report(p_lang text default 'hi',
                                                     p_limit int default 200)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_lang text := coalesce(nullif(p_lang,''),'hi'); v_scopes jsonb; v_missing jsonb;
        v_total int; v_done int;
begin
  if not (public.is_admin() or public.get_my_role() in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'tone', 'danger',
      'message', public.ui_text('admin_i18n.err_not_authorized'));
  end if;

  with scoped as (
    select c.key, c.value #>> '{}' as english, s.prefix, s.label, s.sort_order,
           nullif((select i.value #>> '{}' from ui_copy_i18n i
                    where i.key = c.key and i.lang = v_lang), '') as translated
      from ui_copy c
      join ui_i18n_scope s
        on s.is_active and c.key like s.prefix || '%'
  )
  select
    coalesce(jsonb_agg(x order by x_sort, x_prefix), '[]'::jsonb),
    coalesce(sum(x_total), 0), coalesce(sum(x_done), 0)
  into v_scopes, v_total, v_done
  from (
    select prefix as x_prefix, sort_order as x_sort,
           count(*)::int as x_total,
           count(translated)::int as x_done,
           jsonb_build_object(
             'prefix', prefix,
             'label', label,
             'total', count(*),
             'translated', count(translated),
             'missing', count(*) - count(translated),
             'coverage_label', (100 * count(translated) / greatest(count(*),1))::int || '%',
             'detail_label', count(translated) || ' / ' || count(*),
             'tone', case when count(translated) = count(*) then 'success'
                          when count(translated) = 0 then 'danger' else 'warning' end
           ) as x
      from scoped group by prefix, label, sort_order
  ) g;

  -- A CTE lives for exactly one statement, so the scoped set is rebuilt here
  -- rather than referenced — the first attempt referenced it and raised 42P01.
  with scoped as (
    select c.key, c.value #>> '{}' as english, s.label,
           nullif((select i.value #>> '{}' from ui_copy_i18n i
                    where i.key = c.key and i.lang = v_lang), '') as translated
      from ui_copy c
      join ui_i18n_scope s
        on s.is_active and c.key like s.prefix || '%'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', m.key, 'english', m.english, 'scope_label', m.label) order by m.key), '[]'::jsonb)
    into v_missing
  from (select * from scoped where translated is null order by key limit greatest(p_limit,1)) m;

  return jsonb_build_object(
    'ok', true,
    'lang', v_lang,
    'lang_label', (select native_label from app_language where code = v_lang),
    'title', public.ui_text('admin_i18n.title'),
    'subtitle', public.ui_text('admin_i18n.subtitle'),
    'total', v_total,
    'translated', v_done,
    'missing', v_total - v_done,
    'headline', replace(replace(replace(public.ui_text('admin_i18n.headline'),
                  '{done}', v_done::text), '{total}', v_total::text),
                  '{pct}', (100 * v_done / greatest(v_total,1))::int::text),
    'tone', case when v_done = v_total then 'success'
                 when v_done = 0 then 'danger' else 'warning' end,
    'scopes', v_scopes,
    'missing_heading', public.ui_text('admin_i18n.missing_heading'),
    'missing_rows', v_missing,
    'empty_label', public.ui_text('admin_i18n.empty'),
    'save_label', public.ui_text('admin_i18n.save'),
    'hint_label', public.ui_text('admin_i18n.hint'));
end $function$;

-- Fill a gap straight from the report — finding a hole and being unable to
-- close it is how a report becomes wallpaper.
create or replace function public.ui_i18n_set(p_key text, p_lang text, p_value text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_ok boolean;
begin
  if not (public.is_admin() or public.get_my_role() in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'tone', 'danger',
      'message', public.ui_text('admin_i18n.err_not_authorized'));
  end if;
  select true into v_ok from app_language where code = p_lang and is_active;
  if not coalesce(v_ok,false) or p_lang = 'en' then
    return jsonb_build_object('ok', false, 'error', 'unknown_language', 'tone', 'danger',
      'message', public.ui_text('supplier_lang.err_unknown'));
  end if;
  if not exists (select 1 from ui_copy where key = p_key) then
    return jsonb_build_object('ok', false, 'error', 'unknown_key', 'tone', 'danger',
      'message', public.ui_text('admin_i18n.err_unknown_key'));
  end if;

  if nullif(btrim(coalesce(p_value,'')),'') is null then
    delete from ui_copy_i18n where key = p_key and lang = p_lang;
  else
    insert into ui_copy_i18n(key, lang, value, source, updated_by, updated_at)
    values (p_key, p_lang, to_jsonb(btrim(p_value)), 'admin',
            coalesce(public.my_login_email(),'admin'), now())
    on conflict (key, lang) do update
      set value = excluded.value, source = 'admin',
          updated_by = excluded.updated_by, updated_at = now();
  end if;

  return jsonb_build_object('ok', true, 'tone', 'success',
    'message', public.ui_text('admin_i18n.saved'));
exception when others then
  return jsonb_build_object('ok', false, 'error', 'exception', 'tone', 'danger',
    'message', replace(public.ui_text('supplier_lang.err_failed'), '{detail}', SQLERRM),
    'sqlstate', SQLSTATE);
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. GRANTS — a definer function is a public endpoint until it is revoked
--    (standing lesson from #25 / #353 / #394 / #422)
-- ═══════════════════════════════════════════════════════════════════════════

-- Read paths stay open: the storefront boots anonymously and must get words.
grant execute on function public.ui_boot()            to anon, authenticated;
grant execute on function public.ui_copy_all()        to anon, authenticated;
grant execute on function public.ui_language_block()  to anon, authenticated;
grant execute on function public.ui_language_get()    to anon, authenticated;
grant execute on function public.ui_text(text)        to anon, authenticated;
grant execute on function public.ui_text_f(text, jsonb) to anon, authenticated;
grant execute on function public.my_language()        to anon, authenticated;

-- Write paths are signed-in / admin only, so anon loses the default grant.
revoke all on function public.ui_language_set(text) from public, anon;
grant execute on function public.ui_language_set(text) to authenticated;
revoke all on function public.ui_language_report(text, int) from public, anon;
grant execute on function public.ui_language_report(text, int) to authenticated;
revoke all on function public.ui_i18n_set(text, text, text) from public, anon;
grant execute on function public.ui_i18n_set(text, text, text) to authenticated;

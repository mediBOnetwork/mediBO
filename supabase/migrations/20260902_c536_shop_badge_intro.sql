-- CHANGE #536 — Om's placement decision, the two halves the app cannot invent.
--
-- "a FIFTH BOTTOM TAB named My Shop: Home · Catalogue · Orders · My Shop ·
--  Bulk … with badge counts (expiry at risk, khata due) on the tab icon where
--  meaningful … For accounts that are plain ordering customers with no shop
--  activity yet, the tab still shows with a simple intro state — do not hide it."
--
-- Both are BACKEND decisions:
--   * WHETHER a badge is meaningful, what it counts and how it reads.
--   * WHETHER an account is a shop yet, and what the intro says.
-- The app draws a number it is handed and a paragraph it is handed. It never
-- decides that 0 means hide, and it never writes the intro.
--
-- Idempotent throughout: create or replace, and the copy upserts on conflict.

-- ── 1. The copy ────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('cshop.intro_title',  to_jsonb('Your counter, once you set it up'::text)),
  ('cshop.intro_body',   to_jsonb('You order stock here today. When you are ready, the same account runs the counter: billing, shelf stock, expiry and the khata book all live in this tab.'::text)),
  ('cshop.badge_expiry', to_jsonb('expiry at risk'::text)),
  ('cshop.badge_khata',  to_jsonb('khata due'::text))
on conflict (key) do update set value = excluded.value;

-- ── 2. The tab badge ───────────────────────────────────────────────────────
--
-- One cheap call, asked once per boot by a shell that already knows the viewer
-- is a signed-in non-admin. It answers with a NUMBER and the words for it; the
-- tab renders `count_label` when `show` is true and draws nothing when it is
-- not. Nothing here is computed in Dart, including "is this worth a badge".
--
-- What counts as attention:
--   expiry — return windows that are OPEN and close within 60 days. A window
--            that has already closed is not an alert; the money is gone and
--            nagging about it is noise (the same rule _c413_home draws its
--            alert list by).
--   khata  — accounts carrying a positive balance.
create or replace function public.customer_shop_badge()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_role   text := coalesce(public.get_my_role(), 'none');
  v_shop   uuid;
  v_expiry int := 0;
  v_khata  int := 0;
  v_total  int;
  v_parts  jsonb := '[]'::jsonb;
begin
  if auth.uid() is null
     or not (v_role = any (array['customer', 'super_admin'])) then
    return jsonb_build_object('ok', true, 'show', false);
  end if;

  v_shop := public.my_customer_id();
  if v_shop is null then
    -- A plain ordering customer with no shop yet. The tab still shows (Om's
    -- rule); it simply has nothing to shout about.
    return jsonb_build_object('ok', true, 'show', false);
  end if;

  select count(*)::int into v_expiry
    from public._c413_rows(v_shop) r
   where r.window_state = 'open'
     and r.days_to_close <= 60;

  select count(*)::int into v_khata
    from public.khata_account ka
   where ka.pharmacy_id = v_shop
     and coalesce(ka.balance, 0) > 0;

  v_total := coalesce(v_expiry, 0) + coalesce(v_khata, 0);

  if v_expiry > 0 then
    v_parts := v_parts || jsonb_build_object(
      'key', 'expiry', 'count', v_expiry,
      'label', public.ui_text('cshop.badge_expiry'));
  end if;
  if v_khata > 0 then
    v_parts := v_parts || jsonb_build_object(
      'key', 'khata', 'count', v_khata,
      'label', public.ui_text('cshop.badge_khata'));
  end if;

  return jsonb_build_object(
    'ok',    true,
    'show',  v_total > 0,
    'count', v_total,
    -- The app never formats this. A three-digit badge is unreadable on a tab
    -- icon, so the cap is decided here, once, in words the app prints.
    'count_label', case when v_total > 99 then '99+' else v_total::text end,
    'parts', v_parts);
end
$function$;

revoke all on function public.customer_shop_badge() from public, anon;
grant execute on function public.customer_shop_badge() to authenticated;

-- ── 3. The intro state ─────────────────────────────────────────────────────
--
-- customer_shop_home() gains an `intro` block. Everything else in this body is
-- byte-for-byte what was already live; only the two `intro` lines and the
-- v_shop lookup are new.
create or replace function public.customer_shop_home()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_role     text  := coalesce(public.get_my_role(), 'none');
  v_uid      uuid  := auth.uid();
  v_shop     uuid;
  v_sections jsonb;
  v_txt      jsonb;
begin
  select coalesce(jsonb_object_agg(replace(k.key, 'cshop.', ''), k.value #>> '{}'), '{}'::jsonb)
    into v_txt from ui_copy k where k.key like 'cshop.%';

  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in',
      'message', coalesce(v_txt ->> 'err_signed_out', ''));
  end if;

  if not (v_role = any (array['customer', 'super_admin'])) then
    return jsonb_build_object('ok', false, 'error', 'not_pharmacy',
      'message', coalesce(v_txt ->> 'err_not_pharmacy', ''));
  end if;

  -- Om: a plain ordering customer with no shop activity yet KEEPS the tab and
  -- gets a simple intro. Absence is explicit, so the app tests a flag rather
  -- than inferring emptiness from a missing key.
  v_shop := public.my_customer_id();

  select coalesce(jsonb_agg(s.sec order by s.sec_sort), '[]'::jsonb)
    into v_sections
    from (
      select nc.sort_order as sec_sort,
             jsonb_build_object(
               'key',      nc.category_key,
               'label',    nc.label,
               'icon_key', nc.icon_key,
               'items',    jsonb_agg(
                 jsonb_build_object(
                   'feature_key',  f.feature_key,
                   'label',        f.label,
                   'caption',      coalesce(f.description, ''),
                   'icon_key',     f.icon_key,
                   'icon_letter',  upper(left(f.label, 1)),
                   'nav_key',      f.route_key
                 ) order by f.sort_order)
             ) as sec
        from nav_category nc
        join feature_registry f on f.category = nc.category_key
       where nc.is_active
         and f.is_active
         and f.surface = 'customer_shop'
         and f.route_key <> ''
         and v_role = any (f.roles_allowed)
       group by nc.category_key, nc.label, nc.icon_key, nc.sort_order
    ) s;

  return jsonb_build_object(
    'ok',            true,
    'role',          v_role,
    'title',         coalesce(v_txt ->> 'title', ''),
    'subtitle',      coalesce(v_txt ->> 'subtitle', ''),
    'empty_message', coalesce(v_txt ->> 'empty', ''),
    'retry_label',   coalesce(v_txt ->> 'retry', ''),
    'intro',         jsonb_build_object(
                       'has',   v_shop is null,
                       'title', coalesce(v_txt ->> 'intro_title', ''),
                       'body',  coalesce(v_txt ->> 'intro_body', '')),
    'sections',      v_sections);
end
$function$;

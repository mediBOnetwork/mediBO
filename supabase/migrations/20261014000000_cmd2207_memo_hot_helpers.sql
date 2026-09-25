-- CMD #2207 — Customer screens under 10 ms.
--
-- CAUSE (EXPLAIN + per-call timing on live, 25 Sep 2026): the customer RPCs are
-- not slow because of a missing index. They are slow because a handful of
-- STABLE, viewer-scoped helpers re-read their configuration on EVERY call, and
-- the card builders call them once per row:
--
--     ui_language_block()      10.25 ms/call
--     _cat_avail_zone()         9.95 ms/call
--     my_cart_discount_pct()    4.92 ms/call
--     _product_card_chrome()    2.81 ms/call
--     viewer_cart_user()        2.18 ms/call
--     ui_copy_etag()            2.03 ms/call
--     _viewer_zone_or_null()    1.69 ms/call
--     get_my_role()             0.80 ms/call
--
-- Every one of them answers the same thing for the whole of one request: the
-- viewer does not change, and neither does app_settings. So each now keeps its
-- answer in a TRANSACTION-LOCAL GUC and returns it on the second and every
-- later call inside the same PostgREST request. This is not a new idea in this
-- schema: viewer_is_approved_customer() and _wish_owner() already do exactly
-- this, and they are the two cheapest helpers measured (27 us).
--
-- The memo is keyed on the credential (auth.uid(), or 'anon'), so one viewer's
-- answer can never be served to another, and set_config(..., true) drops it at
-- COMMIT — a pooled connection carries nothing into the next request.
--
-- Output is byte-identical by construction: the ORIGINAL body is kept verbatim
-- and only wrapped. Proof: 64 md5(payload) hashes over 32 real inputs x
-- {signed-out, approved customer}, before and after.

-- ── the memo, said once ────────────────────────────────────────────────────
create or replace function public._memo_viewer_key()
returns text language sql stable
set search_path to 'public'
as $fn$ select coalesce(auth.uid()::text, 'anon') $fn$;

comment on function public._memo_viewer_key() is
  'CMD #2207 — credential the per-request helper memos are keyed on.';

-- ── 1. _viewer_zone_or_null() ──────────────────────────────────────────────
create or replace function public._viewer_zone_or_null()
returns smallint
language plpgsql stable security definer
set search_path to 'public'
as $fn$
declare v_key text := public._memo_viewer_key();
        v_memo text := nullif(current_setting('medibo.m_vzone', true), '');
        v_ans smallint; v_val text;
begin
  if v_memo is not null and split_part(v_memo, '|', 1) = v_key then
    return nullif(split_part(v_memo, '|', 2), '')::smallint;
  end if;

  select case when public.viewer_is_approved_customer()
              then coalesce((select pp.zone_id from public.pharmacy_profiles pp
                              where pp.id = public.my_customer_id()),
                            (select zone_id from public._storefront_viewer()))
         end
    into v_ans;

  perform set_config('medibo.m_vzone', v_key || '|' || coalesce(v_ans::text, ''), true);
  return v_ans;
end $fn$;

-- ── 2. _cat_avail_zone() ───────────────────────────────────────────────────
create or replace function public._cat_avail_zone()
returns smallint
language plpgsql stable security definer
set search_path to 'public'
as $fn$
declare v_key text := public._memo_viewer_key();
        v_memo text := nullif(current_setting('medibo.m_cazone', true), '');
        v_ans smallint;
begin
  if v_memo is not null and split_part(v_memo, '|', 1) = v_key then
    return nullif(split_part(v_memo, '|', 2), '')::smallint;
  end if;

  select z.zid
    into v_ans
    from (select coalesce(public._viewer_zone_or_null(), public.my_zone_id()) as zid) z
   where z.zid is not null
     and exists (select 1 from public.catalogue_facet_count c
                  where c.zone_id = z.zid and c.facet = 'meta');

  perform set_config('medibo.m_cazone', v_key || '|' || coalesce(v_ans::text, ''), true);
  return v_ans;
end $fn$;

-- ── 3. my_cart_discount_pct() ──────────────────────────────────────────────
create or replace function public.my_cart_discount_pct()
returns numeric
language plpgsql stable security definer
set search_path to 'public'
as $fn$
declare v_key text := public._memo_viewer_key();
        v_memo text := nullif(current_setting('medibo.m_cartpct', true), '');
        v_ans numeric;
begin
  if v_memo is not null and split_part(v_memo, '|', 1) = v_key then
    return nullif(split_part(v_memo, '|', 2), '')::numeric;
  end if;

  select coalesce((public.cart_state(null)->>'discount_pct')::numeric, 0) into v_ans;

  perform set_config('medibo.m_cartpct', v_key || '|' || coalesce(v_ans::text, ''), true);
  return v_ans;
end $fn$;

-- ── 4. viewer_cart_user() ──────────────────────────────────────────────────
create or replace function public.viewer_cart_user()
returns uuid
language plpgsql stable security definer
set search_path to 'public'
as $fn$
declare v_key text := public._memo_viewer_key();
        v_memo text := nullif(current_setting('medibo.m_cartuser', true), '');
        v_ans uuid;
begin
  if v_memo is not null and split_part(v_memo, '|', 1) = v_key then
    return nullif(split_part(v_memo, '|', 2), '')::uuid;
  end if;

  select coalesce(public.my_acting_as(), auth.uid()) into v_ans;

  perform set_config('medibo.m_cartuser', v_key || '|' || coalesce(v_ans::text, ''), true);
  return v_ans;
end $fn$;

-- ── 5. get_my_role() ───────────────────────────────────────────────────────
-- The body is #307/#352's, unchanged; only the memo is new.
create or replace function public.get_my_role()
returns text
language plpgsql stable security definer
set search_path to 'public'
as $fn$
declare
  v_email text; v_keys text[]; v_is_admin boolean; v_is_super boolean; v_type text;
  v_key text := public._memo_viewer_key();
  v_memo text := nullif(current_setting('medibo.m_role', true), '');
  v_ans text;
begin
  if v_memo is not null and split_part(v_memo, '|', 1) = v_key then
    return nullif(split_part(v_memo, '|', 2), '');
  end if;

  v_ans := null;
  select lower(btrim(u.email)) into v_email from auth.users u where u.id = auth.uid();
  v_keys := public.my_identity_keys();

  select true, coalesce(a.is_super,false) into v_is_admin, v_is_super
  from admins a
  where lower(btrim(a.email)) = v_email or identity_norm(a.email) = any (v_keys)
  limit 1;

  if v_is_admin then
    v_ans := case when v_is_super then 'super_admin' else 'admin' end;
  elsif public.my_partner_id() is not null then
    v_ans := case when public.partner_rpc_allowed() then 'admin' else 'partner' end;
  elsif v_email is null and (v_keys is null or cardinality(v_keys) = 0) then
    v_ans := 'none';
  elsif public.my_supplier_id() is not null then
    v_ans := 'supplier';
  else
    select li.owner_type into v_type
    from login_identities li
    where li.identity = any (v_keys)
      and li.owner_type in ('company','mr','delivery','worker')
    order by case li.owner_type when 'mr' then 1 when 'delivery' then 2
                                when 'company' then 3 else 4 end, li.id
    limit 1;
    v_ans := coalesce(v_type, 'customer');
  end if;

  perform set_config('medibo.m_role', v_key || '|' || coalesce(v_ans, ''), true);
  return v_ans;
end $fn$;

-- ── 6. ui_copy_etag() — global, not viewer-scoped ──────────────────────────
create or replace function public.ui_copy_etag()
returns text
language plpgsql stable security definer
set search_path to 'public'
as $fn$
declare v_memo text := nullif(current_setting('medibo.m_copyetag', true), '');
        v_ans text;
begin
  if v_memo is not null then return v_memo; end if;

  select md5(coalesce((select max(updated_at)::text || '|' || count(*)::text from ui_copy), '')
           || '|' || coalesce((select max(updated_at)::text || '|' || count(*)::text
                                 from ui_copy_i18n), ''))
    into v_ans;

  perform set_config('medibo.m_copyetag', coalesce(v_ans, ''), true);
  return v_ans;
end $fn$;

-- ── 7. ui_language_block() — 10.25 ms, the whole of ui_boot's cost ─────────
create or replace function public.ui_language_block()
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $fn$
declare v_key text := public._memo_viewer_key();
        v_memo text := nullif(current_setting('medibo.m_langblock', true), '');
        v_ans jsonb;
begin
  if v_memo is not null and split_part(v_memo, '|', 1) = v_key then
    return nullif(substr(v_memo, strpos(v_memo, '|') + 1), '')::jsonb;
  end if;

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
    into v_ans;

  perform set_config('medibo.m_langblock', v_key || '|' || coalesce(v_ans::text, ''), true);
  return v_ans;
end $fn$;

-- ── 8. _product_card_chrome() — 2.81 ms, and the list builders call it ─────
-- Global (app_settings / storefront_ui_label / ui_copy), so no viewer key.
create or replace function public._product_card_chrome()
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $fn$
declare v_memo text := nullif(current_setting('medibo.m_chrome', true), '');
        v_ans jsonb;
begin
  if v_memo is not null then return v_memo::jsonb; end if;

  select jsonb_build_object(
    'style', s.st,
    'layout', s.ly || jsonb_build_object(
      'text_lines', coalesce((select (value #>> '{}')::int from public.app_settings
                               where key = 'card.text_lines'), 3),
      'name_max_lines', coalesce((s.ly->>'name_lines')::int, 2)),
    'show', s.sh,
    'layout_screens', s.sc,
    'sub_fg', s.st->>'sub_fg',
    'mrp_fg', s.st->>'mrp_fg',
    'image_pct', coalesce((s.ly->>'image_pct')::int, (s.v6->>'image_pct')::int, 92),
    'unavail_label', coalesce((select value from public.storefront_ui_label
                                where key = 'card_chip_unavailable'), ''),
    'unavail_bg', coalesce(s.v6->>'unavail_bg', '#FEE2E2'),
    'unavail_fg', coalesce(s.v6->>'unavail_fg', '#991B1B'),
    'notify_bg', coalesce(s.v6->>'notify_bg', '#DC2626'),
    'notify_fg', coalesce(s.v6->>'notify_fg', '#FFFFFF'),
    'rx_map', jsonb_build_object(
      'Rx',  public.rx_card_badge('Rx'),
      'OTC', public.rx_card_badge('OTC'),
      ''  ,  public.rx_card_badge('')),
    'wish_cfg', jsonb_build_object(
      'has', coalesce((select (value->>'wish')::boolean from public.app_settings
                          where key = 'card.show'), true),
      'add_label', coalesce((select value from public.storefront_ui_label
                                where key = 'card_wish_add'), ''),
      'remove_label', coalesce((select value from public.storefront_ui_label
                                   where key = 'card_wish_remove'), '')),
    'avail_in_label', coalesce((select value from public.storefront_ui_label
                                   where key = 'card_avail_in'), ''),
    'scheme_chip_label', public.uic('catalogue.scheme_chip','Scheme available'))
    into v_ans
  from (select public.card_style() st,
               public.card_layout() ly,
               public.card_show() sh,
               public.card_layout_screens() sc,
               coalesce((select value from public.app_settings where key = 'card.v6'),
                        '{}'::jsonb) v6
        offset 0) s;

  perform set_config('medibo.m_chrome', coalesce(v_ans::text, ''), true);
  return v_ans;
end $fn$;

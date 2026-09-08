-- CHANGE #536 — QA round 3 fixes, both of them backend-owned by design.
--
-- MINOR (finding 300): "A signed-out visitor deep-linking My Shop is told to
-- check their connection." customer_shop_home() has ALWAYS had the right
-- answer for that caller — its first branch returns
-- {ok:false, error:'not_signed_in', message:'Sign in to open your shop.'} —
-- but anon held no EXECUTE on it, so the call died with a 42501 before the
-- function ever ran, the screen's catch-all fired, and the visitor read
-- my_shop.load_failed: "Check your connection and try again." The connection
-- was fine. The fix is the GRANT, not new wording and not a Dart branch: with
-- it, the refusal the backend already wrote is the sentence that arrives.
--
-- Safe to grant: with auth.uid() null the function returns that object on its
-- first statement and touches no table. It is not caught by the anon-grant
-- guard either — rpc_anon_rule matches `admin\_%` and `pack\_%` only — and it
-- reads nothing but ui_copy and feature_registry metadata for a signed-in
-- caller regardless.
--
-- MINOR (finding 302): "intro.has answers 'not a pharmacy at all', not Om's
-- 'no shop activity yet'." Om's rule was: "For accounts that are plain
-- ordering customers with no shop activity yet, the tab still shows with a
-- simple intro state." `v_shop is null` only catches an account with no
-- pharmacy_profiles row at all; a REGISTERED pharmacy that has never counted a
-- shelf, never entered a bill and never opened a khata — the exact account Om
-- described — was dropped straight into the counter tools with no intro. The
-- flag now answers the question Om actually asked.
--
-- Idempotent: create or replace + a bare grant, both safe to re-apply.

-- ── 1. The signed-out visitor gets the sentence, not a network excuse ───────
grant execute on function public.customer_shop_home() to anon;

-- ── 2. intro.has means "no shop activity yet" ───────────────────────────────
--
-- ACTIVITY is any trace of the counter having been used: stock on the shelf,
-- a purchase bill, a sale sheet, a khata entry, a parcel count. Each is an
-- EXISTS that stops at the first row, and `or` short-circuits, so a shop that
-- is plainly running answers on the first probe. A shop with none of them has
-- not started, whatever its registration says.
--
-- `intro.reason` is returned so the state is EXPLICIT rather than inferred
-- from `has` — the app still reads one flag, but the payload says which of the
-- two cases it is, and a future surface can word them apart without a deploy.
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
  v_active   boolean := false;
  v_reason   text;
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

  if v_shop is null then
    v_reason := 'no_shop';
  else
    select exists (select 1 from pharmacy_stock         t where t.pharmacy_id = v_shop)
        or exists (select 1 from pharmacy_purchase_bill t where t.pharmacy_id = v_shop)
        or exists (select 1 from pharmacy_sale_sheet    t where t.pharmacy_id = v_shop)
        or exists (select 1 from khata_entry            t where t.pharmacy_id = v_shop)
        or exists (select 1 from pharmacy_parcel_count  t where t.pharmacy_id = v_shop)
      into v_active;
    v_reason := case when v_active then 'active' else 'no_activity' end;
  end if;

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
                       'has',    not v_active,
                       'reason', v_reason,
                       'title',  coalesce(v_txt ->> 'intro_title', ''),
                       'body',   coalesce(v_txt ->> 'intro_body', '')),
    'sections',      v_sections);
end
$function$;

grant execute on function public.customer_shop_home() to anon, authenticated;

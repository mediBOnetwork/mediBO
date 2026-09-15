-- CMD #451 · feature_gaps rows 84 + 85 — the availability verdict.
--
-- 84: 4,649 rows were buyable AND 'NOT FOR SALE', and the card printed that
--     status beside an enabled "Add to cart", because the verdict read
--     supplier_count and nothing else. Status is now part of the verdict, in
--     the ONE function every surface already funnels through, so all 11 callers
--     inherit the fix without an edit.
-- 85: a signed-out visitor was told every one of 562,549 products was
--     available (storefront_effective_count returned greatest(global,1) for
--     anyone not approved); 86.6% of them flipped to Unavailable the moment the
--     pharmacy was approved. A prospect now browses the same truth we can
--     actually honour — the global supplier count — with the backend's own
--     "sign in for your area" note instead of an optimistic Add to cart.

insert into public.ui_copy (key, value) values
  ('storefront.status_blocked_note', to_jsonb('This product is not for sale.'::text)),
  ('storefront.signed_out_note',     to_jsonb('Sign in to see availability in your area.'::text)),
  ('storefront.no_supplier_note',    to_jsonb('No supplier for this product right now'::text))
on conflict (key) do nothing;

-- -1 is not a count: it is the verdict "blocked by catalogue status", carried
-- through the one integer these two functions already pass between them so no
-- caller signature changes. storefront_cta is the only reader.
create or replace function public.storefront_effective_count(p_product_id bigint, p_global integer)
returns integer
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_approved boolean; v_zone smallint; v_status text;
begin
  select m.status into v_status from public."MEDICINE" m where m.id = p_product_id;
  if not public.med_status_sellable(v_status) then
    return -1;                       -- banned / discontinued / not for sale
  end if;

  if auth.uid() is null then
    return greatest(coalesce(p_global,0), 0);   -- #451: the real count, not 1
  end if;
  select approved, zone_id into v_approved, v_zone from public._storefront_viewer();
  if coalesce(v_approved,false) and v_zone is not null then
    return public.medicine_zone_standby(p_product_id, v_zone);  -- zone truth
  end if;
  return greatest(coalesce(p_global,0), 0);     -- #451: the real count, not 1
end $function$;

-- One verdict, three states. Dropped and recreated with a defaulted third
-- argument so every existing two-argument call still resolves here.
drop function if exists public.storefront_cta(integer, boolean);

create or replace function public.storefront_cta(
  p_supplier_count integer,
  p_resolved boolean default true,
  p_status text default null)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  select case
    -- BLOCKED BY STATUS. Outranks everything, signed in or not: a banned or
    -- discontinued product is never addable to anybody.
    when coalesce(p_supplier_count, 0) < 0
      or (p_status is not null and not public.med_status_sellable(p_status)) then
      jsonb_build_object('is_available', false, 'can_add', false,
        'cta_label', coalesce(public.med_status_block(p_status)->>'label', 'Not for sale'),
        'gated', public.viewer_is_approved_customer(),
        'blocked_by', 'status',
        'note', coalesce(nullif(public.med_status_block(p_status)->>'reason',''),
                         public.uic('storefront.status_blocked_note','This product is not for sale.')),
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='not_for_sale_label'), 'Not for sale'),
        'colors', jsonb_build_object('bg','#FEE2E2','fg','#991B1B'))

    when not coalesce(p_resolved, true) then
      jsonb_build_object('is_available', true, 'can_add', true,
        'cta_label','Add to cart','gated', public.viewer_is_approved_customer(),
        'unresolved', true,
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='card_add_label'), 'ADD'),
        'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF'))

    when coalesce(p_supplier_count, 0) >= 1 then
      jsonb_build_object('is_available', true, 'can_add', true,
        'cta_label','Add to cart','gated', public.viewer_is_approved_customer(),
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='card_add_label'), 'ADD'),
        'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF'))

    else
      jsonb_build_object('is_available', false, 'can_add', false,
        'cta_label','Unavailable','gated', public.viewer_is_approved_customer(),
        'blocked_by', 'no_supplier',
        -- signed out we can only speak for the catalogue, not for a zone, and
        -- we say so instead of pretending the product is addable.
        'note', case when auth.uid() is null
                     then public.uic('storefront.signed_out_note',
                                     'Sign in to see availability in your area.')
                     else public.uic('storefront.no_supplier_note',
                                     'No supplier for this product right now') end,
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='stock_out_label'), 'Out of stock'),
        'colors', jsonb_build_object('bg','#F3F4F6','fg','#9CA3AF'))
  end;
$function$;

-- storefront_gate() states the rule the app renders in the "why is this
-- unavailable" sheet. It said status was irrelevant; it no longer is.
create or replace function public.storefront_gate()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'gated', public.viewer_is_approved_customer(),
    'acting_as', public.my_acting_as(),
    'reason', case when public.my_acting_as() is not null then 'admin acting as a customer'
                   when public.viewer_is_approved_customer() then 'approved customer'
                   else 'signed out — catalogue-wide supplier truth, no zone' end,
    'rule', 'a product is available when its catalogue status is sellable AND it has at least one supplier',
    'min_supplier_count', 1, 'field', 'supplier_count',
    'status_field', 'status',
    'blocked_statuses', (select coalesce(jsonb_agg(s.status_key order by s.sort_rank), '[]'::jsonb)
                           from public.medicine_status_policy s where not s.sellable),
    'available', jsonb_build_object('is_available', true, 'can_add', true,
      'cta_label','Add to cart', 'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF')),
    'unavailable', jsonb_build_object('is_available', false, 'can_add', false,
      'cta_label','Unavailable',
      'note', public.uic('storefront.no_supplier_note','No supplier for this product right now'),
      'colors', jsonb_build_object('bg','#F3F4F6','fg','#9CA3AF')),
    'not_for_sale', jsonb_build_object('is_available', false, 'can_add', false,
      'cta_label','Not for sale',
      'note', public.uic('storefront.status_blocked_note','This product is not for sale.'),
      'colors', jsonb_build_object('bg','#FEE2E2','fg','#991B1B')),
    'blocked_add_message','This product has no supplier right now, so it cannot be ordered.');
$function$;


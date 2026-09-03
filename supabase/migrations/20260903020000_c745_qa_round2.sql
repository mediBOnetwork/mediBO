-- CHANGE #745 — hostile QA round 1, three findings, all in the backend.
--
-- 1. BLOCKER: a signed-in account with no pharmacy row lost its way OUT.
--    Logout became a placement row, and customer_surfaces() short-circuits to
--    an empty payload when my_customer_id() is null — so a customer who signed
--    in with the wrong account, saw the registration form and wanted to sign
--    out again had no button anywhere on a phone. Logout is an IDENTITY
--    action, not a pharmacy feature: `needs_account` says so, and the
--    no-account branch now returns exactly the entries that do not need one.
--    That also un-breaks cust.loyalty_admin, whose audience is super_admin —
--    no super admin owns a pharmacy row, so the row could never render.
--
-- 2. MAJOR: the widgets still switched on 'cust.wishlist' / 'cust.rewards' to
--    decide what to print beside a label, which is the Dart feature list this
--    change exists to delete: moving the wishlist to another placement would
--    have printed "My Wishlist" over the rewards lines. Every entry now
--    carries its OWN finished `badge` and `lines`, composed here.
--
-- 3. MINOR: the home strip read two placements and concatenated them in Dart,
--    so sort_order could only order WITHIN a placement. `home_strip` is one
--    ordered list now, so the badge can be put before the chip with an UPDATE.
--
-- Idempotent (#233).

begin;

alter table public.customer_feature_placement
  add column if not exists needs_account boolean not null default true;

update public.customer_feature_placement
   set needs_account = false, updated_at = now()
 where feature_key in ('cust.logout', 'cust.loyalty_admin')
   and needs_account;

insert into public.ui_copy (key, value) values
  ('cust_menu.offline_note', to_jsonb('Showing your last saved menu.'::text))
on conflict (key) do nothing;

create or replace function public.customer_surfaces()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_role   text := coalesce(public.get_my_role(), 'none');
  v_cust   uuid := public.my_customer_id();
  v_prof   record;
  v_term   text;
  v_code   text;
  v_absent text := coalesce(public._c('cust_menu.value_absent'), '');
  v_place  jsonb := '{}'::jsonb;
  v_items  jsonb;
  v_wish   int := 0;
  v_wlabel text := '';
  v_rw     jsonb;
  v_rbadge text := '';
  v_rlines jsonb := '[]'::jsonb;
  v_has    boolean := (auth.uid() is not null and v_cust is not null);
  p        text;
begin
  if auth.uid() is null then
    -- A visitor has no chrome of their own. Explicit absence, never an error.
    return jsonb_build_object('ok', true, 'role', v_role, 'has_account', false,
                              'placements', '{}'::jsonb);
  end if;

  if v_has then
    select pp.* into v_prof from public.pharmacy_profiles pp where pp.id = v_cust;

    select count(*)::int into v_wish
      from public.wishlist_items w where w.account_id = v_cust;
    v_wlabel := case when v_wish > 0 then v_wish::text else '' end;

    v_rw := public.loyalty_my_rewards();
    if coalesce((v_rw->'points'->>'on')::boolean, false) then
      v_rbadge := coalesce(v_rw->'points'->>'balance_label', '');
    else
      v_rbadge := coalesce(v_rw->'tier'->>'current_label', '');
    end if;

    -- The Rewards card's body, composed here so the screen prints lines it was
    -- handed rather than joining two fields with a Dart space.
    if coalesce((v_rw->>'any_on')::boolean, false) then
      select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_rlines from (
        select 1 as ord, v_rw->'points'->>'balance_label' as x
         where coalesce((v_rw->'points'->>'on')::boolean, false)
        union all
        select 2, v_rw->'tier'->>'current_label'
         where coalesce((v_rw->'tier'->>'on')::boolean, false)
        union all
        select 3, btrim(coalesce(v_rw->'referral'->>'code_label','') || ' '
                        || coalesce(v_rw->'referral'->>'code',''))
         where coalesce((v_rw->'referral'->>'on')::boolean, false)
      ) s where coalesce(x, '') <> '';
    else
      v_rlines := jsonb_build_array(coalesce(public._c('cust_menu.rewards_off'), ''));
      v_rlines := (select coalesce(jsonb_agg(e), '[]'::jsonb)
                     from jsonb_array_elements_text(v_rlines) e where e <> '');
    end if;
  end if;

  foreach p in array array['profile_account','catalogue_appbar','orders_section',
                           'home_strip']
  loop
    select coalesce(jsonb_agg(jsonb_build_object(
             'feature_key', f.feature_key,
             'label',       f.label,
             'caption',     coalesce(f.description, ''),
             'icon_key',    f.icon_key,
             'icon_letter', upper(left(f.label, 1)),
             'route_key',   f.route_key,
             'render_kind', cp.render_kind,
             -- The entry's own trailing text and body. The SCREEN never asks
             -- which feature this is.
             'badge', case f.feature_key
                        when 'cust.wishlist' then v_wlabel
                        when 'cust.rewards'  then v_rbadge
                        else '' end,
             'lines', case f.feature_key
                        when 'cust.rewards' then v_rlines
                        else '[]'::jsonb end)
           order by cp.sort_order, cp.placement, f.sort_order), '[]'::jsonb)
      into v_items
      from public.customer_feature_placement cp
      join public.feature_registry f on f.feature_key = cp.feature_key
     -- 'home_strip' is the chip row and the badge row rendered as ONE ordered
     -- list, so their relative order is sort_order's to decide.
     where cp.placement = any (case when p = 'home_strip'
                                    then array['home_chip','home_badge']
                                    else array[p] end)
       and cp.is_active
       and f.is_active
       and v_role = any (f.roles_allowed)
       -- The account gate: without a pharmacy row a caller still gets the
       -- entries that never needed one (Logout above all).
       and (v_has or not cp.needs_account);
    v_place := v_place || jsonb_build_object(p, v_items);
  end loop;

  if not v_has then
    return jsonb_build_object(
      'ok', true, 'role', v_role, 'has_account', false,
      'placements', v_place,
      'account_title', coalesce(public._c('cust_menu.account_title'), ''));
  end if;

  v_term := nullif(btrim(coalesce(v_prof.payment_term, '')), '');
  if v_term is null then
    v_term := nullif(btrim(coalesce(
      (select value #>> '{}' from public.app_settings
        where key = 'customer_default_payment_term'), '')), '');
  end if;
  v_code := nullif(btrim(coalesce(v_prof.customer_code, '')), '');

  return jsonb_build_object(
    'ok', true,
    'role', v_role,
    'has_account', true,
    'placements', v_place,
    'offline_note', coalesce(public._c('cust_menu.offline_note'), ''),
    'account_setup', jsonb_build_object(
      'title', coalesce(public._c('cust_menu.setup_title'), ''),
      'rows', jsonb_build_array(
        jsonb_build_object(
          'key',      'payment_term',
          'label',    coalesce(public._c('cust_menu.row_payment_term'), ''),
          'value',    coalesce(v_term, v_absent),
          'has',      v_term is not null,
          'icon_key', 'payments'),
        jsonb_build_object(
          'key',      'customer_code',
          'label',    coalesce(public._c('cust_menu.row_customer_code'), ''),
          'value',    coalesce(v_code, v_absent),
          'has',      v_code is not null,
          'icon_key', 'rule'))),
    'account_title', coalesce(public._c('cust_menu.account_title'), ''),
    'wishlist', jsonb_build_object(
      'has',   v_wish > 0,
      'count', v_wish,
      'count_label', v_wlabel,
      'tooltip', coalesce(public._c('cust_menu.wishlist_tooltip'), '')),
    'rewards', jsonb_build_object(
      'has',        coalesce((v_rw->>'any_on')::boolean, false),
      'title',      coalesce(v_rw->>'title', ''),
      'open_label', coalesce(public._c('cust_menu.rewards_open'), ''),
      'off_note',   coalesce(public._c('cust_menu.rewards_off'), ''),
      'badge_label', v_rbadge,
      'lines',      v_rlines));
end $$;

-- A signed-out caller reaches this through the storefront's own chrome and is
-- answered with the empty shape, so anon keeps EXECUTE on purpose. (Round 1 QA:
-- the previous `revoke ... from public` read as a restriction the default ACL
-- was never going to enforce.)
grant execute on function public.customer_surfaces() to anon, authenticated, service_role;

commit;

-- The chip reads first and the badge sits beside it; both were sort_order 10,
-- so the tiebreak (placement name) put the badge first. One UPDATE, as promised.
begin;
update public.customer_feature_placement
   set sort_order = 20, updated_at = now()
 where placement = 'home_badge' and feature_key = 'cust.rewards';
commit;

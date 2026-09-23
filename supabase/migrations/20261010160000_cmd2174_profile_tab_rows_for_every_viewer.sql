-- CMD #2174 — the Profile tab that had no way out.
--
-- Om, live at 412dp: a signed-in account whose pharmacy is not registered
-- opened Profile and saw the name card and the "Not Registered" chip and
-- nothing else. No rows, so NO LOG OUT.
--
-- What was actually happening, measured across every live account:
--
--   customer_nav() offers the `profile` slot to EVERY signed-in role — all 8
--   QA identities come back with profile_slot=1 — but customer_profile_tab()
--   filtered every row on `v_role = any (f.roles_allowed)`, and
--   feature_registry holds {customer, super_admin} for all 23 `cust.*`
--   features because that column is shared with the surfaces those features
--   really belong to. So a supplier, a delivery rider, an MR, a company
--   login, a shop worker or a non-super admin was handed a tab with a header
--   and an EMPTY list: 19 live accounts, and every one of them stuck.
--
--   An unregistered CUSTOMER was never the broken case: they already get the
--   three sections and the seven rows the bug report describes. That is why
--   the web tab is not the fix — it renders whatever it is handed, which
--   test/protected/profile_tab_test.dart now pins.
--
-- The rule, on the column that was already there: a row that NEEDS AN ACCOUNT
-- keeps its role gate and its account gate; a row that needs no account —
-- Your cart, Notifications, Share the app, About mediBO, Privacy, Terms and
-- Log out — is offered to anyone signed in who is offered this tab at all.
-- Which rows those are stays DATA (`customer_feature_placement.needs_account`),
-- so moving a row in or out of the signed-out set is still one UPDATE.
--
-- Idempotent: CREATE OR REPLACE plus one ui_copy upsert.

create or replace function public.customer_profile_tab()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_role  text := coalesce(public.get_my_role(), 'none');
  v_cust  uuid := public.my_customer_id();
  v_has   boolean := (auth.uid() is not null and v_cust is not null);
  pp      record;
  v_name  text := '';
  v_sub   text := '';
  v_chip  jsonb := '{}'::jsonb;
  v_wish  text := '';
  v_rbadge text := '';
  v_rw    jsonb;
  v_notif jsonb := '{}'::jsonb;
  v_nlabel text := '';
  v_sections jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'signed_out');
  end if;

  if v_has then
    select * into pp from public.pharmacy_profiles where id = v_cust;
    v_name := coalesce(nullif(btrim(coalesce(pp.pharmacy_name,'')),''),
                       nullif(btrim(coalesce(pp.customer_name,'')),''),
                       nullif(btrim(coalesce(pp.owner_name,'')),''), '');
    v_sub := array_to_string(array_remove(array[
               nullif(btrim(coalesce(pp.phone,'')),''),
               nullif(btrim(coalesce(pp.customer_code,'')),'')], null), ' · ');
    v_chip := case
      when coalesce(pp.approved,false) and coalesce(pp.status,'') = 'suspended'
        then jsonb_build_object('label', public._c('profile.badge_suspended'), 'tone', 'danger')
      when coalesce(pp.approved,false)
        then jsonb_build_object('label', public._c('profile.badge_approved'), 'tone', 'success')
      else jsonb_build_object('label', public._c('profile.badge_pending'), 'tone', 'warning')
    end;
    select case when count(*) > 0 then count(*)::text else '' end into v_wish
      from public.wishlist_items w where w.account_id = public._wish_owner();
    begin
      v_rw := public.loyalty_my_rewards();
      if coalesce((v_rw->'points'->>'on')::boolean, false) then
        v_rbadge := coalesce(v_rw->'points'->>'balance_label', '');
      end if;
    exception when others then v_rbadge := '';
    end;
  else
    v_name := coalesce(nullif(btrim(coalesce(
                (select raw_user_meta_data->>'full_name' from auth.users where id = auth.uid()),'')),''), '');
    v_chip := jsonb_build_object('label', public._c('profile.badge_not_registered'), 'tone', 'neutral');
  end if;

  begin
    v_notif := coalesce(public.notif_inbox_unread(), '{}'::jsonb);
  exception when others then v_notif := '{}'::jsonb;
  end;
  if coalesce((v_notif->>'show')::boolean, false) then
    v_nlabel := coalesce(v_notif->>'label', '');
  end if;

  with rows as (
    select cp.section,
           min(cp.sort_order) over (partition by cp.section) as section_sort,
           cp.sort_order,
           jsonb_build_object(
             'feature_key', f.feature_key,
             'label',  coalesce(nullif(public._c(cp.label_key),''), f.label),
             'caption', coalesce(nullif(public._c(cp.caption_key),''), ''),
             'icon_key', f.icon_key,
             'route_key', f.route_key,
             'tab', coalesce(f.tab_screen, ''),
             'render_kind', cp.render_kind,
             'tone', case when f.route_key in ('cust_logout','logout') then 'danger' else 'default' end,
             'badge', case f.feature_key
                        when 'cust.wishlist'      then v_wish
                        when 'cust.rewards'       then v_rbadge
                        when 'cust.notifications' then v_nlabel
                        else '' end) as item
      from public.customer_feature_placement cp
      join public.feature_registry f on f.feature_key = cp.feature_key
     where cp.placement = 'profile_tab'
       and cp.is_active and f.is_active
       -- CMD #2174 — an account row still needs the account AND the role it
       -- was written for; a row that needs no account belongs to whoever is
       -- looking at the tab, because Log out is one of them.
       and (case when cp.needs_account
                 then (v_has and v_role = any (f.roles_allowed))
                 else true end)
  ), grouped as (
    select section, min(section_sort) as s_sort,
           jsonb_agg(item order by sort_order) as items
      from rows group by section
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'key',   g.section,
           'kind',  case g.section when 'tiles' then 'tiles'
                                   when 'my_shop' then 'hero'
                                   else 'rows' end,
           'title', public._c('profile_tab.section_' || g.section),
           'items', g.items) order by g.s_sort), '[]'::jsonb)
    into v_sections
    from grouped g;

  return jsonb_build_object(
    'ok', true,
    'has_account', v_has,
    'header', jsonb_build_object(
      'avatar_label', upper(left(coalesce(nullif(v_name,''), '·'), 1)),
      'title',    v_name,
      'subtitle', v_sub,
      'chip',     v_chip),
    'sections', v_sections,
    -- CMD #2174 — a tab that comes back with nothing says so in the backend's
    -- own words instead of drawing a header over a blank page. It should be
    -- unreachable now; it is here so that the next cause of an empty list is
    -- a sentence on the screen and not another account with no way out.
    'empty_label', public._c('profile_tab.empty'),
    'share_text',   public._c('profile_tab.share_text'),
    'share_copied', public._c('profile_tab.share_copied'));
end $function$;

revoke all on function public.customer_profile_tab() from public, anon;
grant execute on function public.customer_profile_tab() to authenticated, service_role;

insert into public.ui_copy (key, value)
values ('profile_tab.empty',
        to_jsonb('Nothing to show here yet. Pull down to refresh.'::text))
on conflict (key) do nothing;

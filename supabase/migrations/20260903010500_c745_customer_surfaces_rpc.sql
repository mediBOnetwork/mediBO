-- CHANGE #745 (part 2) — one call for the whole customer chrome, and the
-- Account Setup rows stop being em-dashes.
--
-- Om: "Payment term and Customer code show real values (both render '—'
-- today)". They rendered a dash because Dart wrote the dash: _InfoRow does
-- `value.isNotEmpty ? value : '—'` over pharmacy_profiles columns that are
-- NULL on the accounts Om looks at (his own shop had neither), while every
-- ordering customer carries APL100 / NIT123 and 'Advance Payment'. Two fixes,
-- both server-side: a code is derived and kept for good, and the term falls
-- back to the platform default. The screen now prints a finished string.

begin;

-- ── 1. every pharmacy has a customer code, for good ─────────────────────────
create or replace function public._cust_code_for(p_name text, p_id uuid)
returns text
language plpgsql
as $$
declare
  v_stem text;
  v_try  text;
  v_n    int := 101;
begin
  -- Letters only, first three, upper — the shape every existing code has
  -- (APOLLO -> APL100, Nitesh -> NIT123). A nameless row falls back to the
  -- id so the result is still unique and still stable.
  v_stem := upper(left(regexp_replace(coalesce(p_name,''), '[^A-Za-z]', '', 'g'), 3));
  if length(v_stem) < 3 then
    v_stem := 'CUS';
  end if;
  loop
    v_try := v_stem || v_n::text;
    exit when not exists (select 1 from public.pharmacy_profiles where customer_code = v_try)
          and not exists (select 1 from public.supplier_profiles where supplier_code = v_try);
    v_n := v_n + 1;
    if v_n > 9999 then
      -- Never loop for ever: fall back to the row's own id, which cannot clash.
      v_try := v_stem || upper(left(replace(p_id::text,'-',''), 6));
      exit;
    end if;
  end loop;
  return v_try;
end $$;

create or replace function public._cust_code_assign()
returns trigger
language plpgsql
as $$
begin
  if nullif(btrim(coalesce(new.customer_code,'')), '') is null then
    new.customer_code := public._cust_code_for(new.pharmacy_name, new.id);
  end if;
  return new;
end $$;

drop trigger if exists trg_cust_code_assign on public.pharmacy_profiles;
create trigger trg_cust_code_assign
  before insert on public.pharmacy_profiles
  for each row execute function public._cust_code_assign();

-- Backfill the accounts that never got one. Additive only: a row that already
-- carries a code is never touched, so re-running this changes nothing.
do $$
declare r record;
begin
  for r in select id, pharmacy_name from public.pharmacy_profiles
            where nullif(btrim(coalesce(customer_code,'')),'') is null
            order by created_at
  loop
    update public.pharmacy_profiles
       set customer_code = public._cust_code_for(r.pharmacy_name, r.id)
     where id = r.id;
  end loop;
end $$;

-- ── 2. the platform's default payment term ──────────────────────────────────
-- Data, not a literal: changing the default is an UPDATE.
insert into public.app_settings (key, value)
values ('customer_default_payment_term', to_jsonb('Advance Payment'::text))
on conflict (key) do nothing;

-- ── 3. copy ─────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('cust_menu.account_title',      to_jsonb('Account'::text)),
  ('cust_menu.setup_title',        to_jsonb('Account setup'::text)),
  ('cust_menu.row_payment_term',   to_jsonb('Payment term'::text)),
  ('cust_menu.row_customer_code',  to_jsonb('Customer code'::text)),
  ('cust_menu.value_absent',       to_jsonb('Not set yet'::text)),
  ('cust_menu.wishlist_tooltip',   to_jsonb('My Wishlist'::text)),
  ('cust_menu.rewards_open',       to_jsonb('View rewards'::text)),
  ('cust_menu.rewards_off',        to_jsonb('Rewards are not running yet'::text))
on conflict (key) do nothing;

-- ── 4. the one call the customer chrome renders ─────────────────────────────
create or replace function public.customer_surfaces()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_role  text := coalesce(public.get_my_role(), 'none');
  v_cust  uuid := public.my_customer_id();
  v_prof  record;
  v_term  text;
  v_code  text;
  v_absent text := coalesce(nullif(public._c('cust_menu.value_absent'),''), '');
  v_place jsonb := '{}'::jsonb;
  v_items jsonb;
  v_wish  int := 0;
  v_rw    jsonb;
  p       text;
begin
  if auth.uid() is null or v_cust is null then
    -- Explicit absence, never an error: a signed-out visitor and an admin with
    -- no pharmacy account both get an empty chrome and the app renders nothing.
    return jsonb_build_object('ok', true, 'role', v_role, 'has_account', false,
                              'placements', '{}'::jsonb);
  end if;

  foreach p in array array['profile_account','catalogue_appbar','home_chip',
                           'orders_section','home_badge']
  loop
    select coalesce(jsonb_agg(jsonb_build_object(
             'feature_key', f.feature_key,
             'label',       f.label,
             'caption',     coalesce(f.description, ''),
             'icon_key',    f.icon_key,
             'icon_letter', upper(left(f.label, 1)),
             'route_key',   f.route_key,
             'render_kind', cp.render_kind)
           order by cp.sort_order, f.sort_order), '[]'::jsonb)
      into v_items
      from public.customer_feature_placement cp
      join public.feature_registry f on f.feature_key = cp.feature_key
     where cp.placement = p
       and cp.is_active
       and f.is_active
       and v_role = any (f.roles_allowed);
    v_place := v_place || jsonb_build_object(p, v_items);
  end loop;

  select pp.* into v_prof from public.pharmacy_profiles pp where pp.id = v_cust;

  v_term := nullif(btrim(coalesce(v_prof.payment_term, '')), '');
  if v_term is null then
    v_term := nullif(btrim(coalesce(
      (select value #>> '{}' from public.app_settings
        where key = 'customer_default_payment_term'), '')), '');
  end if;
  v_code := nullif(btrim(coalesce(v_prof.customer_code, '')), '');

  select count(*)::int into v_wish
    from public.wishlist_items w where w.account_id = v_cust;

  v_rw := public.loyalty_my_rewards();

  return jsonb_build_object(
    'ok', true,
    'role', v_role,
    'has_account', true,
    'placements', v_place,
    'account_setup', jsonb_build_object(
      'title', coalesce(nullif(public._c('cust_menu.setup_title'),''), ''),
      'rows', jsonb_build_array(
        jsonb_build_object(
          'key',      'payment_term',
          'label',    coalesce(nullif(public._c('cust_menu.row_payment_term'),''), ''),
          'value',    coalesce(v_term, v_absent),
          'has',      v_term is not null,
          'icon_key', 'payments'),
        jsonb_build_object(
          'key',      'customer_code',
          'label',    coalesce(nullif(public._c('cust_menu.row_customer_code'),''), ''),
          'value',    coalesce(v_code, v_absent),
          'has',      v_code is not null,
          'icon_key', 'rule'))),
    'account_title', coalesce(nullif(public._c('cust_menu.account_title'),''), ''),
    'wishlist', jsonb_build_object(
      'has',   v_wish > 0,
      'count', v_wish,
      'count_label', case when v_wish > 0 then v_wish::text else '' end,
      'tooltip', coalesce(nullif(public._c('cust_menu.wishlist_tooltip'),''), '')),
    'rewards', jsonb_build_object(
      'has',        coalesce((v_rw->>'any_on')::boolean, false),
      'title',      coalesce(v_rw->>'title', ''),
      'open_label', coalesce(nullif(public._c('cust_menu.rewards_open'),''), ''),
      'off_note',   coalesce(nullif(public._c('cust_menu.rewards_off'),''), ''),
      'tier_on',    coalesce((v_rw->'tier'->>'on')::boolean, false),
      'tier_label', coalesce(v_rw->'tier'->>'current_label', ''),
      'tier_note',  coalesce(v_rw->'tier'->>'progress_label', ''),
      'points_label', coalesce(v_rw->'points'->>'balance_label', ''),
      'points_worth', coalesce(v_rw->'points'->>'worth_label', ''),
      'points_on',    coalesce((v_rw->'points'->>'on')::boolean, false),
      'referral_on',    coalesce((v_rw->'referral'->>'on')::boolean, false),
      'referral_label', coalesce(v_rw->'referral'->>'code_label', ''),
      'referral_code',  coalesce(v_rw->'referral'->>'code', ''),
      'badge_label', case
        when coalesce((v_rw->'points'->>'on')::boolean, false)
          then coalesce(v_rw->'points'->>'balance_label', '')
        else coalesce(v_rw->'tier'->>'current_label', '') end));
end $$;

revoke all on function public.customer_surfaces() from public;
grant execute on function public.customer_surfaces() to authenticated, service_role;

commit;

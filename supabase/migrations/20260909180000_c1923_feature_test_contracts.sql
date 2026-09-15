-- replay-target: production
-- CMD #1923 — the two features CMD #1914 registered get their test contracts.
--
-- The regression guard went red on the scheduled run after CHANGE #1298 with
-- one CRITICAL signal: behaviour c634_every_feature_declares_a_test_contract
-- reported "2 active feature(s) have no test contract: cust.notifications,
-- cust.profile_home". Both rows were inserted at 19:20 UTC by CMD #1914 (the
-- profile dropdown: the wishlist and the notification bell moved out of the
-- header) with test_entry '', test_roles NULL, test_steps [] and test_expect
-- {} — has_test_contract is a GENERATED column, so the guard saw the gap the
-- moment the rows went active.
--
-- A behaviour failure is never rebaselined: the fix is the contract itself.
-- The shape is the one every other customer_menu row with a real address
-- already uses (cust.wishlist, cust.rewards, cust.address_book): authenticate
-- as the role, open the deep_link, let it settle, and assert the render-log
-- says the app painted. `/notifications` has been a real route since #298;
-- `/profile` becomes one in this same command (lib/main.dart), because a
-- registry deep_link is a URL and not a promise (#745).
--
-- Idempotent: it sets the four contract fields for two known keys by value.

update public.feature_registry set
  test_automatable  = true,
  test_skip_reason  = null,
  test_entry        = '/notifications',
  test_roles        = array['customer','super_admin']::text[],
  test_steps        = '[{"kind": "auth", "role": "{role}"}, {"kind": "goto", "path": "/notifications"}, {"ms": 6000, "kind": "settle"}]'::jsonb,
  test_expect       = '{"key": "boot_status", "kind": "visible", "equals": "painted", "source": "render_log"}'::jsonb,
  test_contract_at  = now()
where feature_key = 'cust.notifications'
  and coalesce(btrim(test_entry), '') = '';

update public.feature_registry set
  test_automatable  = true,
  test_skip_reason  = null,
  test_entry        = '/profile',
  test_roles        = array['customer','super_admin']::text[],
  test_steps        = '[{"kind": "auth", "role": "{role}"}, {"kind": "goto", "path": "/profile"}, {"ms": 6000, "kind": "settle"}]'::jsonb,
  test_expect       = '{"key": "boot_status", "kind": "visible", "equals": "painted", "source": "render_log"}'::jsonb,
  test_contract_at  = now()
where feature_key = 'cust.profile_home'
  and coalesce(btrim(test_entry), '') = '';

-- Prove the two rows this migration owns really carry a contract now, and say
-- so about any OTHER uncontracted feature without taking this deploy hostage
-- for a row that belongs to another command.
do $c1923$
declare v_mine text; v_rest text;
begin
  select coalesce(string_agg(feature_key, ', ' order by feature_key), '')
    into v_mine
    from public.rg_contract_gap()
   where feature_key in ('cust.notifications', 'cust.profile_home');
  if coalesce(v_mine, '') <> '' then
    raise exception 'c1923/c634: the contract did not take for %', v_mine;
  end if;

  select coalesce(string_agg(feature_key, ', ' order by feature_key), '')
    into v_rest
    from public.rg_contract_gap();
  if coalesce(v_rest, '') <> '' then
    raise notice 'c1923/c634: other active feature(s) still have no test contract: %', left(v_rest, 400);
  end if;
end
$c1923$;

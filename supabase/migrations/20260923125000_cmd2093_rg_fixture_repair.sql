-- CMD #2093 (d) — a repair this command tripped over, fixed here rather than
-- reported.
--
-- rg_check() was RED on five CHANGE #704 behaviours, all with the same line:
-- "no synthetic pharmacy / priced product fixture". The fixture is kept alive
-- by test_customer_shop_ensure(), which a nightly cron_task calls — and on
-- production that function has been raising
--
--     function public.identity_norm(unknown) does not exist
--
-- since before this command started. identity_norm() was introduced by
-- 20260905183000_c668_test_cust1_owns_seeded_shop.sql, which predates the
-- migration replay ledger, so it exists on every build branch and never
-- reached live. The nightly refill has therefore been failing silently, the
-- synthetic shop aged out, and the #704 proofs lost their fixture.
--
-- Re-declaring it is idempotent and touches nothing else: same name, same
-- signature, same body as the one every branch already has.
create or replace function public.identity_norm(v text)
returns text language sql immutable as $$
  select case
    when v is null or btrim(v) = '' then null
    when position('@' in v) > 0 then lower(btrim(v))
    when length(regexp_replace(v,'\D','','g')) >= 10 then right(regexp_replace(v,'\D','','g'),10)
    else null
  end
$$;

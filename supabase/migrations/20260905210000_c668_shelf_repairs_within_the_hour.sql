-- CHANGE #668 (live proof round 2) — the shelf must repair itself in minutes,
-- not overnight.
--
-- 20260905170500 seeded five lots on live at 17:14 and by 20:5x live held ZERO:
--   select count(*) from pharmacy_stock where is_synthetic  ->  0
--   select count(*) from khata_account   where is_synthetic ->  2  (kept)
-- That split names the actor exactly. test_purge() loops a hardcoded table list
-- and runs `delete from public.<t> where is_synthetic` over it; pharmacy_stock
-- is on that list and khata_account is not. So an ORDINARY QA action — Test
-- Mode -> Purge, the thing this command exists to serve — empties the shelf,
-- and the c668 repair was pinned to run_at_ist '03:17', up to 24 hours later.
-- For most of a working day the four screens would render "0 rows" with no
-- refusal in sight: a feature that looks alive and proves nothing, which is the
-- exact shape #668 was raised to end.
--
-- test_purge() is #573's function and stays untouched — deleting synthetic rows
-- is precisely its job and narrowing it would break the guarantee QA relies on.
-- What changes is the REPAIR: the same cron_task row becomes an ordinary poll
-- task on the one dispatcher (never a bare */N — see the connection-exhaustion
-- outage), so the shop, its shelf, its return window, its expiring batch and
-- its khata book are back within a quarter of an hour of any purge.
--
-- Cost: ~15 upserts against rows keyed by pharmacy_id, and the dispatcher's own
-- adaptive backoff (base 900 s, max 3600 s) stretches the interval while
-- nothing changes. Idempotent; re-applying is a no-op.

update public.cron_task
   set run_at_ist        = null,
       night_only        = false,
       base_interval_s   = 900,
       max_interval_s    = 3600,
       current_interval_s= 900,
       next_run_at       = least(coalesce(next_run_at, now()), now()),
       enabled           = true,
       note              = 'CHANGE #668 — keeps test.cust1 shop, shelf, expiry window and khata alive; '
                           || 'polls so a test_purge() is repaired within the quarter hour, not overnight'
 where name = 'c668_test_customer_shop';

-- The row is created by 20260905170500; if that file has not been replayed on
-- this database yet, create it here so the two orders of replay agree.
insert into public.cron_task
  (name, ord, mode, work_sql, dml, enabled, note, step_timeout_ms,
   base_interval_s, max_interval_s, current_interval_s, night_only)
select 'c668_test_customer_shop', 640, 'poll',
       'select public.test_customer_shop_ensure()', true, true,
       'CHANGE #668 — keeps test.cust1 shop, shelf, expiry window and khata alive; '
       || 'polls so a test_purge() is repaired within the quarter hour, not overnight',
       20000, 900, 3600, 900, false
 where not exists (select 1 from public.cron_task where name = 'c668_test_customer_shop');

-- Repair now, so this deploy leaves the shelf full rather than waiting a tick.
do $c668fix$
declare v jsonb;
begin
  if to_regprocedure('public.test_customer_shop_ensure()') is not null then
    execute 'select public.test_customer_shop_ensure()' into v;
    raise notice 'c668 repair: %', v;
  end if;
end
$c668fix$;

-- The guard: a replay that silently no-ops is how a repair disappears.
do $c668guard$
declare v_int int; v_pin time;
begin
  select base_interval_s, run_at_ist into v_int, v_pin
    from public.cron_task where name = 'c668_test_customer_shop';
  if v_int is null or v_int > 3600 or v_pin is not null then
    raise exception 'c668: the shelf repair is still pinned to a daily slot (interval=%, run_at_ist=%)',
      v_int, v_pin;
  end if;
end
$c668guard$;

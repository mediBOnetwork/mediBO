-- CHANGE #229 (auto-heal retry #1) — bound the two closure guards.
--
-- WHY: rg_check() runs on every deploy AND inside every dev_cmd_complete, and
-- these two bodies build REAL fixtures (a cloned order, bill lines, supplier
-- receipts). A client that gives up (curl timeout, killed shell) does NOT stop
-- the server side, so stacked abandoned runs sit on the instance's 60
-- connection slots — the documented slot-starvation outage mode. A hard cap
-- makes an abandoned run free its slot by itself, and a guard that cannot
-- finish inside the cap goes RED, which is the right answer for a guard that
-- slow, instead of grinding the instance.
--
-- Written as a surgical, idempotent patch rather than a full-body rewrite so it
-- can never silently regress the bodies seeded by 20260818160000.

do $mig$
declare
  cap text := E'\nbegin\n  set local statement_timeout = ''60s'';\n  set local lock_timeout = ''5s'';\n  set local idle_in_transaction_session_timeout = ''60s'';\n';
begin
  update rg_behavior_tests
     set body = regexp_replace(body, E'\nbegin\n', cap)
   where name in ('order_closure_customer', 'order_closure_supplier')
     and position('statement_timeout' in body) = 0;

  if exists (select 1 from rg_behavior_tests
              where name in ('order_closure_customer', 'order_closure_supplier')
                and position('set local statement_timeout' in body) = 0) then
    raise exception 'CHANGE #229: closure guard cap did not apply';
  end if;
end $mig$;

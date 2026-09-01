-- CMD #451 · row 128 (part 4) — "generate the tax invoice server-side AT
-- DISPATCH ... never depend on a human upload".
--
-- Without this the number was still assigned lazily, by whichever read of
-- customer_bill() happened first. That is idempotent and never wrong, but it
-- makes a statutory series depend on somebody opening a screen. The dispatch
-- event itself now raises the invoice and queues the render.
create or replace function public._orders_issue_invoice_on_dispatch()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  -- only on the transition INTO a supplied state, and only once
  if new.invoice_no is null
     and new.status in ('shipped','delivered','completed')
     and coalesce(old.status,'') is distinct from new.status then
    begin
      if coalesce((public._bill_ready(new.id)->>'ready')::boolean, false) then
        perform public.customer_invoice_issue(new.id);
        perform public.bill_job_enqueue(new.id, false);
      end if;
    exception when others then
      -- an invoice that cannot be raised must never block a dispatch; the
      -- bill-jobs cron retries it on its own schedule.
      insert into public.rg_alerts (level, source, message)
      values ('warn', 'invoice_on_dispatch',
              'order ' || new.id::text || ': ' || sqlerrm)
      on conflict do nothing;
    end;
  end if;
  return new;
end $function$;

drop trigger if exists _orders_issue_invoice_on_dispatch_trg on public.orders;
create trigger _orders_issue_invoice_on_dispatch_trg
after update of status on public.orders
for each row execute function public._orders_issue_invoice_on_dispatch();


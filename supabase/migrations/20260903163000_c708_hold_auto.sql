-- CHANGE #708 (4/6) — the hold looks after itself.
--
-- A hold with a resume date that a human has to remember is a hold that
-- expires into a forgotten order. One sweep on the cron dispatcher (never a
-- bare */N — the #outage lesson) does three things, all of them idempotent:
--
--   * reminds the day before (config remind_days), once per hold
--   * RESUMES on the resume date, through order_resume() itself so the
--     re-rank, the notification and the SLA credit are the same code the app
--     calls — a second resume path is a second set of bugs
--   * CANCELS a hold that has sat past auto_cancel_days, through order_cancel's
--     own core so releases, inquiries and refunds behave exactly as they do
--     for a hand-cancelled order, and tells the customer why
--
-- Idempotent throughout.

insert into public.order_reason_option (scope, code, label)
select 'cancel', 'held_too_long', 'Cancelled after sitting on hold'
where not exists (select 1 from public.order_reason_option
                   where scope = 'cancel' and code = 'held_too_long');

create or replace function public.order_hold_sweep()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_cfg jsonb := coalesce((select value from app_settings where key='order_hold'),'{}'::jsonb);
  v_remind int := coalesce((v_cfg->>'remind_days')::int, 1);
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  h record;
  v_reminded int := 0; v_resumed int := 0; v_cancelled int := 0; v_failed int := 0;
  v_code text; v_cust uuid; v_phone text; v_days int;
begin
  -- 1. the reminder, once per hold
  for h in
    select oh.* from order_hold oh
     where oh.status = 'active'
       and oh.resume_on is not null
       and oh.reminded_at is null
       and oh.resume_on - v_remind <= v_today
       and oh.resume_on >= v_today
  loop
    begin
      select o.order_code, o.customer_id,
             coalesce(nullif(pp.whatsapp_no,''), nullif(pp.phone,''), o.phone)
        into v_code, v_cust, v_phone
        from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
       where o.id = h.order_id;
      perform public.wa_send_event('order_hold_reminder', v_cust,
        jsonb_build_object('code', coalesce(v_code,''),
                           'd', to_char(h.resume_on,'DD/MM/YYYY'),
                           'link','https://medibo.in/'),
        v_phone, h.order_id);
    exception when others then null;
    end;
    update order_hold set reminded_at = now() where id = h.id;
    v_reminded := v_reminded + 1;
  end loop;

  -- 2. auto-resume on the date the pharmacy picked
  for h in
    select oh.* from order_hold oh
     where oh.status = 'active'
       and oh.resume_on is not null
       and oh.resume_on <= v_today
  loop
    begin
      if coalesce((public.order_resume(h.order_id,
            _c('order_hold.held_by_system'), 'system')->>'ok')::boolean, false)
        then v_resumed := v_resumed + 1;
        else v_failed := v_failed + 1;
      end if;
    exception when others then v_failed := v_failed + 1;
    end;
  end loop;

  -- 3. auto-cancel a hold nobody came back for
  for h in
    select oh.* from order_hold oh
     where oh.status = 'active'
       and oh.auto_cancel_on is not null
       and oh.auto_cancel_on <= v_today
  loop
    v_days := greatest(v_today - h.held_at::date, 0);
    begin
      select o.order_code, o.customer_id,
             coalesce(nullif(pp.whatsapp_no,''), nullif(pp.phone,''), o.phone)
        into v_code, v_cust, v_phone
        from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
       where o.id = h.order_id;

      -- the SAME core a hand-cancelled order uses: releases, inquiries, refund
      perform public._order_cancel_core(h.order_id, 'held_too_long',
                _cf('order_hold.timeline_cancelled', jsonb_build_object('n', v_days::text)),
                null, 'system');

      update order_hold
         set status = 'cancelled', resumed_at = now(), resumed_kind = 'system',
             held_seconds = greatest(0, extract(epoch from (now() - held_at)))::bigint,
             resume_note = _cf('order_hold.timeline_cancelled',
                             jsonb_build_object('n', v_days::text))
       where id = h.id;

      begin
        perform public.wa_send_event('order_hold_cancelled', v_cust,
          jsonb_build_object('code', coalesce(v_code,''), 'n', v_days::text,
                             'link','https://medibo.in/'),
          v_phone, h.order_id);
      exception when others then null;
      end;
      v_cancelled := v_cancelled + 1;
    exception when others then v_failed := v_failed + 1;
    end;
  end loop;

  if v_failed > 0 then
    insert into rg_alerts(fingerprint, severity, kind, name, detail,
                          first_seen, last_seen, seen_count)
    values ('order_hold_sweep_failed', 'warn', 'orders', 'Order hold sweep had failures',
            jsonb_build_object('failed', v_failed, 'day', v_today), now(), now(), 1)
    on conflict (fingerprint) do update
      set last_seen = now(), seen_count = rg_alerts.seen_count + 1, detail = excluded.detail;
  end if;

  return jsonb_build_object('ok', true, 'reminded', v_reminded, 'resumed', v_resumed,
                            'cancelled', v_cancelled, 'failed', v_failed, 'today', v_today);
end
$fn$;

revoke all on function public.order_hold_sweep() from public, anon, authenticated;
grant execute on function public.order_hold_sweep() to service_role;

insert into public.cron_task (name, ord, mode, work_sql, enabled, run_at_ist,
                              business_hours_only, note)
values ('order-hold-sweep', 538, 'poll', 'select public.order_hold_sweep();', true,
        time '07:10:00', false,
        'CHANGE #708 — reminds the day before, resumes on the date the pharmacy '
        'picked, and cancels a hold that has sat past the limit. Twenty minutes '
        'after the KYC sweep so the two never start together.')
on conflict (name) do nothing;

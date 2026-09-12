-- CHANGE #708 (spec item 5) — the journeys.
--
-- Three probes, each running the REAL chain against real functions on a real
-- open order and rolling every write back. Registering them is an INSERT: the
-- dispatcher asks _dev_journey_by_convention() first (CHANGE #705), so
-- c708-hold-stages resolves to _journey_c708_hold_stages().
-- Idempotent throughout.

-- ── 1. the stage gate, then hold -> freeze -> resume ──────────────────────
create or replace function public._journey_c708_hold_stages()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_order uuid; v_stage text;
  v_allowed text := ''; v_refused text := ''; v_mismatch text := '';
  v_in_pack_before boolean; v_in_pack_held boolean; v_in_pack_after boolean;
  v_deliv jsonb; v_inv jsonb; v_frozen boolean := false;
  v_hold jsonb; v_resume jsonb; v_badge text := '';
  v_chain text := 'not run'; r record; v_sheet jsonb; v_ok boolean;
  v_stage_rows int; v_reasons int;
begin
  perform public._dev_guard();

  select count(*)::int into v_stage_rows from order_hold_stage where allow;
  select count(*)::int into v_reasons from order_hold_reason where is_active;

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;

  select o.id into v_order from orders o
   where o.status <> 'cancelled' and o.closed_at is null
   order by o.created_at desc limit 1;

  if v_admin is not null and v_order is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);

      -- (a) the gate answers exactly what the CONFIG says, stage by stage
      for r in select s.stage_key, s.allow from order_hold_stage s
                join sla_stage st on st.stage_key = s.stage_key
               order by st.sort_order
      loop
        delete from order_stage_history where order_id = v_order;
        insert into order_stage_history(order_id, stage_key, entered_at)
        values (v_order, r.stage_key, now() - interval '2 hours');
        v_sheet := public.order_hold_sheet(v_order);
        if coalesce((v_sheet->>'can_hold')::boolean,false) = r.allow then
          if r.allow then
            v_allowed := v_allowed || r.stage_key || ' ';
          else
            v_refused := v_refused || r.stage_key || ' ';
          end if;
        else
          v_mismatch := v_mismatch || r.stage_key || ' ';
        end if;
      end loop;

      -- (b) at an allowed stage: hold, and every surface goes quiet
      delete from order_stage_history where order_id = v_order;
      insert into order_stage_history(order_id, stage_key, entered_at)
      values (v_order, 'supplier_order', now() - interval '2 hours');

      v_in_pack_before := exists (
        select 1 from jsonb_array_elements(public.pack_list_orders_core(null,false)->'orders') x
         where x->>'order_id' = v_order::text);

      v_hold := public.order_hold(v_order, 'shop_closed', 'journey', null);
      v_badge := public.order_hold_state(v_order)->>'badge';

      v_in_pack_held := exists (
        select 1 from jsonb_array_elements(public.pack_list_orders_core(null,false)->'orders') x
         where x->>'order_id' = v_order::text);
      v_deliv := public.delivery_eligibility(v_order);
      v_inv   := public.customer_invoice_issue(v_order);
      v_frozen := coalesce((select bool_and(public._c708_inquiry_held(oi.inquiry_id))
                              from order_items oi
                             where oi.order_id = v_order and oi.inquiry_id is not null), true);

      -- (c) resume, and it carries on from exactly where it was
      v_resume := public.order_resume(v_order, 'journey');
      v_stage  := public._c708_stage(v_order);
      v_in_pack_after := exists (
        select 1 from jsonb_array_elements(public.pack_list_orders_core(null,false)->'orders') x
         where x->>'order_id' = v_order::text);

      v_chain := 'ran';
      raise exception using errcode='ZZ708', message='c708 journey rollback';
    exception
      when sqlstate 'ZZ708' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_chain = 'ran'
      and v_stage_rows = 4 and v_reasons >= 5
      and btrim(coalesce(v_mismatch,'')) = ''
      and btrim(coalesce(v_allowed,'')) <> ''
      and btrim(coalesce(v_refused,'')) <> ''
      and coalesce((v_hold->>'ok')::boolean,false)
      and coalesce(v_badge,'') <> ''
      and coalesce(v_in_pack_held,true) = false
      and coalesce((v_deliv->>'can_assign')::boolean,true) = false
      and coalesce((v_inv->>'ok')::boolean,true) = false
      and coalesce(v_inv->>'reason','') = 'on_hold'
      and v_frozen
      and coalesce((v_resume->>'ok')::boolean,false)
      and v_stage = 'supplier_order'
      and coalesce(v_in_pack_after,false) = coalesce(v_in_pack_before,false);

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | stages the config allows='||v_stage_rows::text
   || ' reasons='||v_reasons::text
   || ' | gate said YES at: '||coalesce(nullif(btrim(v_allowed),''),'-')
   || ' | gate said NO at: '||coalesce(nullif(btrim(v_refused),''),'-')
   || ' | disagreements with the config: '||coalesce(nullif(btrim(v_mismatch),''),'none')
   || ' | hold ok='||coalesce(v_hold->>'ok','?')||' badge='||coalesce(v_badge,'?')
   || ' | pack queue before='||coalesce(v_in_pack_before::text,'?')
   || ' held='||coalesce(v_in_pack_held::text,'?')
   || ' after resume='||coalesce(v_in_pack_after::text,'?')
   || ' | rider can_assign='||coalesce(v_deliv->>'can_assign','?')
   || ' -> '||coalesce(v_deliv->>'blocked_label','')
   || ' | invoice='||coalesce(v_inv->>'reason','?')
   || ' | inquiry rows frozen='||v_frozen::text
   || ' | resume ok='||coalesce(v_resume->>'ok','?')
   || ' stage after resume='||coalesce(v_stage,'?')));
end
$fn$;

-- ── 2. the reminder and the auto-resume ───────────────────────────────────
create or replace function public._journey_c708_hold_auto_resume()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_order uuid;
  v_s1 jsonb; v_s2 jsonb; v_s3 jsonb; v_held_after boolean := true;
  v_reminders int := 0; v_chain text := 'not run'; v_cron boolean; v_ok boolean;
begin
  perform public._dev_guard();

  select coalesce(enabled,false) into v_cron from cron_task where name = 'order-hold-sweep';

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;
  select o.id into v_order from orders o
   where o.status <> 'cancelled' and o.closed_at is null
   order by o.created_at desc limit 1;

  if v_admin is not null and v_order is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      delete from order_stage_history where order_id = v_order;
      insert into order_stage_history(order_id, stage_key, entered_at)
      values (v_order, 'supplier_order', now() - interval '2 hours');

      -- due to resume tomorrow: the reminder goes once, and only once
      perform public.order_hold(v_order, 'cash_later', null,
                ((now() at time zone 'Asia/Kolkata')::date + 1));
      v_s1 := public.order_hold_sweep();
      v_s2 := public.order_hold_sweep();
      select count(*)::int into v_reminders from order_hold
       where order_id = v_order and reminded_at is not null;

      -- the date arrives: the sweep resumes it, through order_resume itself
      update order_hold set resume_on = (now() at time zone 'Asia/Kolkata')::date
       where order_id = v_order and status = 'active';
      v_s3 := public.order_hold_sweep();
      v_held_after := coalesce((public.order_hold_state(v_order)->>'held')::boolean, true);

      v_chain := 'ran';
      raise exception using errcode='ZZ708', message='c708 journey rollback';
    exception
      when sqlstate 'ZZ708' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_chain = 'ran'
      and coalesce(v_cron,false)
      and coalesce((v_s1->>'reminded')::int,0) = 1
      and coalesce((v_s2->>'reminded')::int,1) = 0
      and v_reminders = 1
      and coalesce((v_s3->>'resumed')::int,0) = 1
      and v_held_after = false;

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | cron_task order-hold-sweep enabled='||coalesce(v_cron,false)::text
   || ' | sweep 1 reminded='||coalesce(v_s1->>'reminded','?')
   || ' | sweep 2 reminded='||coalesce(v_s2->>'reminded','?')||' (must be 0)'
   || ' | reminder rows on the hold='||v_reminders::text
   || ' | sweep 3 resumed='||coalesce(v_s3->>'resumed','?')
   || ' | still held afterwards='||v_held_after::text||' (must be false)'));
end
$fn$;

-- ── 3. the auto-cancel ────────────────────────────────────────────────────
create or replace function public._journey_c708_hold_auto_cancel()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_order uuid; v_sweep jsonb;
  v_status text := ''; v_hold_status text := ''; v_reason text := '';
  v_chain text := 'not run'; v_days int; v_ok boolean;
begin
  perform public._dev_guard();

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;
  select o.id into v_order from orders o
   where o.status <> 'cancelled' and o.closed_at is null
   order by o.created_at desc limit 1;

  if v_admin is not null and v_order is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      delete from order_stage_history where order_id = v_order;
      insert into order_stage_history(order_id, stage_key, entered_at)
      values (v_order, 'accept', now() - interval '2 hours');

      perform public.order_hold(v_order, 'stock_elsewhere', null, null);
      update order_hold
         set auto_cancel_on = (now() at time zone 'Asia/Kolkata')::date - 1,
             held_at = now() - interval '20 days'
       where order_id = v_order and status = 'active';

      v_sweep := public.order_hold_sweep();
      select o.status into v_status from orders o where o.id = v_order;
      select h.status, coalesce(h.resume_note,'') into v_hold_status, v_reason
        from order_hold h where h.order_id = v_order order by h.id desc limit 1;
      select count(*)::int into v_days from order_cancellations
       where order_id = v_order and reason_code = 'held_too_long';

      v_chain := 'ran';
      raise exception using errcode='ZZ708', message='c708 journey rollback';
    exception
      when sqlstate 'ZZ708' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_chain = 'ran'
      and coalesce((v_sweep->>'cancelled')::int,0) = 1
      and v_status = 'cancelled'
      and v_hold_status = 'cancelled'
      and v_reason <> ''
      and coalesce(v_days,0) = 1;

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | sweep cancelled='||coalesce(v_sweep->>'cancelled','?')
   || ' | order status='||coalesce(nullif(v_status,''),'?')
   || ' | hold row='||coalesce(nullif(v_hold_status,''),'?')
   || ' | the sentence on it='||coalesce(nullif(v_reason,''),'<empty>')
   || ' | cancellation rows with reason held_too_long='||coalesce(v_days,0)::text));
end
$fn$;

insert into public.dev_journeys (name, area, kind, steps, assertions, required, enabled)
values
  ('c708-hold-stages','orders','api',
   jsonb_build_array('the gate answers exactly what order_hold_stage says, stage by stage',
                     'a hold at an allowed stage takes the order out of the pack queue',
                     'no rider can be assigned and no invoice can be raised',
                     'the inquiry rows are frozen where they stood',
                     'resume puts it back at the same stage and back in the queue'),
   jsonb_build_array('_journey_c708_hold_stages'), false, true),
  ('c708-hold-auto-resume','orders','api',
   jsonb_build_array('the reminder goes once and the re-run is silent',
                     'the sweep resumes it on the date the pharmacy picked',
                     'the order is no longer held afterwards'),
   jsonb_build_array('_journey_c708_hold_auto_resume'), false, true),
  ('c708-hold-auto-cancel','orders','api',
   jsonb_build_array('a hold past the limit cancels the order',
                     'through the same core a hand-cancelled order uses',
                     'with reason held_too_long and its own sentence'),
   jsonb_build_array('_journey_c708_hold_auto_cancel'), false, true)
on conflict (name) do update
  set area = excluded.area, steps = excluded.steps,
      assertions = excluded.assertions, enabled = true;

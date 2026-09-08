-- CHANGE #294 (part I) — a failed TEMPLATE send must raise the alarm too.
--
-- Hostile QA of part G found the hole: trg_wa_out_failed skipped every
-- routed_to='campaign' row to avoid the alert recursing into itself. But the
-- template path is now the NORMAL path for an out-of-window customer, so a
-- template that Meta rejects was landing in exactly the silence this change
-- exists to end. Campaign rows are back in scope; recursion is stopped by
-- name — the alert's own message never triggers another alert.

create or replace function public.trg_wa_out_failed()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare v_event text; v_order uuid; v_code text; v jsonb; v_is_campaign boolean;
begin
  if NEW.direction <> 'out'
     or NEW.wa_status <> 'failed'
     or coalesce(OLD.wa_status,'') = 'failed'
     or coalesce(NEW.routed_to,'') in ('bot_reply','admin_reply','bot_send_error','send_error')
  then
    return null;
  end if;

  v_is_campaign := coalesce(NEW.routed_to,'') = 'campaign';

  -- The alert's own outbound message must never alert about itself.
  if v_is_campaign and coalesce(NEW.text_body,'') like '%wa_send_failed%' then
    return null;
  end if;

  v_event := public.wa_event_key_for_routed(NEW.routed_to);

  v_code := nullif(btrim(split_part(replace(coalesce(NEW.file_name,''),'mediBO-',''), '.', 1)),'');
  if v_code is not null then
    select o.id into v_order from orders o where o.order_code = v_code limit 1;
  end if;
  if v_order is null then
    select o.id into v_order
      from orders o
      join pharmacy_profiles pp on pp.user_id = o.user_id
     where right(regexp_replace(coalesce(pp.whatsapp_no, pp.phone,''),'\D','','g'),10)
         = right(regexp_replace(NEW.sender_phone,'\D','','g'),10)
     order by o.created_at desc
     limit 1;
  end if;

  -- Retrying a TEMPLATE as a template would just fail the same way; only a
  -- free-form send that hit the window has a template to fall back to.
  if not v_is_campaign and coalesce(NEW.wa_fail_reason,'') ilike '%re-engagement%' then
    if v_event is not null then
      v := public.wa_send_event_or_fallback(v_event, null, '{}'::jsonb, NEW.sender_phone, v_order);
      perform public._wa_log_attempt(v_event, v_order, NEW.sender_phone, 'template_retry',
                                     coalesce((v->>'ok')::boolean,false),
                                     coalesce(v->>'reason','retried_as_template'), v);
      if coalesce((v->>'ok')::boolean,false) then
        return null;   -- recovered: the customer got the template. No alarm.
      end if;
    else
      perform public._wa_log_attempt(coalesce(NEW.routed_to,'unknown'), v_order, NEW.sender_phone,
                                     'skipped', false,
                                     'no_event_route_for_' || coalesce(NEW.routed_to,'null'));
    end if;
  end if;

  perform public.wa_send_failed_alert(
    coalesce(v_event, case when v_is_campaign then 'template_send' end, NEW.routed_to, 'unknown'),
    NEW.sender_phone, v_order,
    coalesce(NEW.wa_fail_reason,'send_failed'), v);
  return null;
end $$;

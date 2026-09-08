-- CHANGE #294 (part H) — the ledger row should not repeat itself.
--
-- Live review of the section: a delivered row printed "Approved template" and
-- then, underneath, the word "order_placed" — the event key, which is already
-- the row's title. The reason line only earns its space when it says something
-- the chips do not: why a send did NOT land, or that a DIFFERENT template stood
-- in for the one the event asked for.

create or replace function public.wa_send_health(p_hours integer default 48)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_rows jsonb; v_tot int; v_ok int; v_bad int; v_since timestamptz;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  v_since := now() - make_interval(hours => greatest(1, least(coalesce(p_hours,48), 720)));

  select count(*), count(*) filter (where a.ok), count(*) filter (where not a.ok)
    into v_tot, v_ok, v_bad
  from wa_send_attempts a
  where a.created_at >= v_since and a.path <> 'alert';

  select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'id', a.id,
      'at', a.created_at,
      'when_label', to_char(a.created_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI am'),
      'title', coalesce(r.label, a.event_key),
      'order_code', o.order_code,
      'phone_label', case when a.phone is null then 'No number on file'
                          else '+91 ' || right(a.phone,10) end,
      'path_label', case a.path
                      when 'template'       then 'Approved template'
                      when 'template_retry' then 'Template retry'
                      when 'freeform'       then 'Free-form (window open)'
                      when 'alert'          then 'Admin alert'
                      else 'Not sent' end,
      'status_label', case when a.ok then 'Delivered to Meta' else 'Not delivered' end,
      'tone', case when a.ok then 'good' when a.path = 'skipped' then 'warn' else 'bad' end,
      -- Only when it adds something: the failure reason, or the stand-in template.
      'reason', case
                  when not a.ok then a.reason
                  when a.reason = 'already_delivered_recently'
                    then 'Already delivered — not sent again'
                  when a.path in ('template','template_retry')
                       and a.reason is not null and a.reason <> a.event_key
                    then 'Sent with the ' || a.reason || ' template'
                  else null end,
      'can_retry', (not a.ok) and a.path <> 'alert' and a.order_id is not null,
      'event_key', a.event_key
    ) as x
    from wa_send_attempts a
    left join wa_event_routes r on r.event_key = a.event_key
    left join orders o on o.id = a.order_id
    where a.created_at >= v_since
    order by a.created_at desc
    limit 60
  ) s;

  return jsonb_build_object(
    'ok', true,
    'heading', 'Notification delivery',
    'window_note', 'Free-form messages are only allowed for 24h after the customer '
                   'writes to us. Outside that window mediBO sends the approved template.',
    'range_label', 'Last ' || greatest(1, least(coalesce(p_hours,48), 720)) || ' hours',
    'summary_label', v_tot || ' attempts · ' || v_ok || ' delivered · ' || v_bad || ' not delivered',
    'summary_tone', case when v_bad = 0 then 'good' when v_bad <= 2 then 'warn' else 'bad' end,
    'empty_label', 'No customer notifications in this window yet.',
    'retry_label', 'Resend',
    'rows', v_rows);
end $$;

grant execute on function public.wa_send_health(integer) to authenticated;

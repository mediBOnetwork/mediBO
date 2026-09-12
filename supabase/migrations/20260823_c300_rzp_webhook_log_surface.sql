-- CHANGE #300 — Part B: give the webhook delivery log an operator surface.
--
-- #293 built rzp_webhook_log_recent() and nothing ever called it: the log that
-- answers "did Razorpay actually reach us, and did we act on it?" was invisible
-- in the app. #300's whole point is the handled flag, so the flag needs a
-- screen. This turns the RPC into a render-ready payload — title, subtitle,
-- empty-state copy, per-row status label and tone all decided HERE — and the
-- card prints it verbatim.
insert into public.razorpay_copy(key, value) values
  ('log_title',       'Webhook deliveries'),
  ('log_subtitle',    'What Razorpay has sent this endpoint'),
  ('log_empty',       'No deliveries yet. Razorpay posts here the moment a QR is paid or closed.'),
  ('log_handled',     'Acted on'),
  ('log_ignored',     'Acknowledged'),
  ('log_count_one',   '1 delivery'),
  ('log_count_many',  '%s deliveries')
on conflict (key) do nothing;

create or replace function public.rzp_webhook_log_recent(p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v jsonb; v_n integer;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    raise exception 'not_authorized';
  end if;

  select count(*) into v_n from public.razorpay_webhook_log;

  select coalesce(jsonb_agg(jsonb_build_object(
           'event', l.event,
           'handled', l.handled,
           -- the chip is the backend's word and the backend's tone; Dart never
           -- turns a boolean into "Acted on" or picks a colour for it
           'status_label', case when l.handled then public._rzp_copy('log_handled')
                                else public._rzp_copy('log_ignored') end,
           'status_tone',  case when l.handled then 'success' else 'neutral' end,
           'payload_id', coalesce(l.payload_id,''),
           'at_label', to_char(l.received_at at time zone 'Asia/Kolkata','DD Mon, FMHH12:MI am'))
         order by l.received_at desc), '[]'::jsonb)
    into v
    from (select * from public.razorpay_webhook_log
           order by received_at desc limit greatest(coalesce(p_limit,20),1)) l;

  return jsonb_build_object(
    'ok', true,
    'title',    public._rzp_copy('log_title'),
    'subtitle', public._rzp_copy('log_subtitle'),
    'empty',    public._rzp_copy('log_empty'),
    'has',      (v_n > 0),
    'count_label', case when v_n = 1 then public._rzp_copy('log_count_one')
                        else replace(public._rzp_copy('log_count_many'), '%s', v_n::text) end,
    'rows', v);
end $function$;

grant execute on function public.rzp_webhook_log_recent(integer) to authenticated;

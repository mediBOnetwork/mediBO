-- CMD #451 · gap 82 (part 2) — the inbox now HAS rows, so they must read like
-- notifications rather than like database keys. 172 'campaign' rows and every
-- radar_* row carried no title and no wa_event_routes label, so the inbox
-- printed the raw event_key.
--
-- Titles are DATA (ui_copy), never Dart and never a CASE in this function:
-- rewording an event is an UPDATE. A key with no copy still degrades to a
-- humanised form ('radar_reply' -> 'Radar Reply') instead of a raw slug.

insert into public.ui_copy (key, value) values
  ('notif_event.campaign',               to_jsonb('mediBO update'::text)),
  ('notif_event.order_placed',           to_jsonb('Order placed'::text)),
  ('notif_event.order_accepted',         to_jsonb('Order accepted'::text)),
  ('notif_event.order_updated',          to_jsonb('Order updated'::text)),
  ('notif_event.order_rejected',         to_jsonb('Order cancelled'::text)),
  ('notif_event.order_alert_new',        to_jsonb('New order'::text)),
  ('notif_event.payment_qr',             to_jsonb('Payment requested'::text)),
  ('notif_event.payment_received',       to_jsonb('Payment received'::text)),
  ('notif_event.bill_ready',             to_jsonb('Invoice ready'::text)),
  ('notif_event.out_for_delivery',       to_jsonb('Out for delivery'::text)),
  ('notif_event.delivered',              to_jsonb('Order delivered'::text)),
  ('notif_event.radar_reply',            to_jsonb('Stock radar reply'::text)),
  ('notif_event.radar_month',            to_jsonb('Monthly expiry radar'::text)),
  ('notif_event.radar_urgent',           to_jsonb('Expiry return window closing'::text)),
  ('notif_event.radar_bill_read',        to_jsonb('Purchase bill read'::text)),
  ('notif_event.pharmacy_expiry_digest', to_jsonb('Weekly expiry summary'::text)),
  ('notif_event.pharmacy_expiry_urgent', to_jsonb('Return window closing'::text)),
  ('notif_event.user_notify_login',      to_jsonb('New sign-in'::text)),
  ('notif_inbox.hidden_events',          to_jsonb('login_otp,otp,auth_otp,test_send'::text))
on conflict (key) do nothing;

-- Humanise an event_key as the LAST resort: 'radar_bill_read' -> 'Radar Bill Read'.
create or replace function public._notif_event_title(p_event_key text, p_route_label text)
returns text
language sql
stable security definer
set search_path to 'public'
as $function$
  select coalesce(
           nullif(public.uic('notif_event.' || coalesce(p_event_key,''), ''), ''),
           nullif(btrim(coalesce(p_route_label,'')), ''),
           nullif(initcap(replace(replace(coalesce(p_event_key,''),'_',' '),'.',' ')), ''),
           public.uic('notif_inbox.untitled', 'Notification'));
$function$;

create or replace function public.notif_inbox_list(p_limit integer default 30, p_offset integer default 0)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_uid uuid := auth.uid(); v_ph text; v_rows jsonb; v_total int; v_lim int;
        v_hidden text[];
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error','not_signed_in',
      'title', public.uic('notif_inbox.title','Notifications'),
      'empty_title', public.uic('notif_inbox.signed_out_title',
                                'Sign in to see your notifications'),
      'empty_hint',  public.uic('notif_inbox.signed_out_hint',''),
      'items','[]'::jsonb, 'has_more', false);
  end if;
  v_lim := least(greatest(coalesce(p_limit,30), 1), 100);
  v_ph  := public.my_phone10();
  v_hidden := string_to_array(public.uic('notif_inbox.hidden_events',''), ',');

  select count(*) into v_total from notification_log l
   where (l.user_id = v_uid or (v_ph is not null and l.recipient = v_ph))
     and coalesce(l.status,'') <> 'skipped'
     and not (coalesce(l.event_key,'') = any(coalesce(v_hidden,'{}')));

  select coalesce(jsonb_agg(x order by (x->>'id')::bigint desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
             'id', l.id,
             'event_key', l.event_key,
             'title', coalesce(nullif(l.title,''),
                               public._notif_event_title(l.event_key, r.label)),
             'body',  coalesce(nullif(l.body,''), nullif(l.subject,''), ''),
             'deep_link', l.deep_link,
             'channel', l.channel,
             'channel_label', public.uic('notif_channel.' || lower(coalesce(l.channel,'')),
                                         initcap(coalesce(l.channel,''))),
             'unread', (l.read_at is null),
             'when_label', public.ist_fmt(l.created_at, 'rel'),
             'status', l.status) as x
      from notification_log l
      left join wa_event_routes r on r.event_key = l.event_key
     where (l.user_id = v_uid or (v_ph is not null and l.recipient = v_ph))
       and coalesce(l.status,'') <> 'skipped'
       and not (coalesce(l.event_key,'') = any(coalesce(v_hidden,'{}')))
     order by l.id desc
     limit v_lim offset greatest(coalesce(p_offset,0),0)
  ) s;

  return jsonb_build_object(
    'ok', true,
    'title',       public.uic('notif_inbox.title','Notifications'),
    'empty_title', public.uic('notif_inbox.empty_title','No notifications yet'),
    'empty_hint',  public.uic('notif_inbox.empty_hint',''),
    'mark_all',    public.uic('notif_inbox.mark_all','Mark all read'),
    'load_more',   public.uic('notif_inbox.load_more','Load more'),
    'items', v_rows,
    'total', v_total,
    'has_more', greatest(coalesce(p_offset,0),0) + v_lim < v_total);
end $function$;


-- Data repair that shipped with the fix (idempotent): stamp the owner on the
-- 1,221 notification_log rows written before the trigger existed.
with own as (
  select pp.user_id, pp.id as customer_id,
         nullif(right(regexp_replace(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone),'\D','','g'),10),'') as ph10
    from pharmacy_profiles pp where pp.user_id is not null
)
update notification_log l
   set user_id = o.user_id, customer_id = coalesce(l.customer_id, o.customer_id)
  from own o
 where l.user_id is null
   and o.ph10 is not null
   and nullif(right(regexp_replace(coalesce(l.recipient,''),'\D','','g'),10),'') = o.ph10;

-- CHANGE #298 — the channel chip is a NAME, not initcap() of a slug.
--
-- notif_inbox_list() printed initcap(l.channel), so the inbox called the
-- channel "Whatsapp" (and would call an SMS row "Sms"). A brand's own casing is
-- copy, so it comes from ui_copy like every other string, with initcap() left
-- as the fallback for a channel nobody has named yet. Caught by reading the
-- real payload during this command's QA pass. Idempotent.
insert into ui_copy (key, value) values
  ('notif_channel.whatsapp', to_jsonb('WhatsApp'::text)),
  ('notif_channel.push',     to_jsonb('Push'::text)),
  ('notif_channel.email',    to_jsonb('Email'::text)),
  ('notif_channel.sms',      to_jsonb('SMS'::text))
on conflict (key) do nothing;

create or replace function public.notif_inbox_list(p_limit integer default 30, p_offset integer default 0)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_uid uuid := auth.uid(); v_ph text; v_rows jsonb; v_total int; v_lim int;
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

  select count(*) into v_total from notification_log l
   where (l.user_id = v_uid or (v_ph is not null and l.recipient = v_ph))
     and coalesce(l.status,'') <> 'skipped';

  select coalesce(jsonb_agg(x order by (x->>'id')::bigint desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
             'id', l.id,
             'event_key', l.event_key,
             'title', coalesce(nullif(l.title,''), r.label, l.event_key),
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

-- CHANGE #298 — a signed-out inbox is still a screen, so it must say something.
--
-- notif_inbox_list()'s not_signed_in branch returned no empty_title/empty_hint,
-- and notifications_inbox_screen.dart prints exactly what the payload carries
-- (`p?.emptyTitle ?? ''`), so /notifications rendered a title bar over a blank
-- page for anyone not signed in. The screenshot proof for this command is what
-- caught it — the second time on #298 that taking one paid for itself.
--
-- The copy lives in ui_copy like every other string; the branch now reads it.
-- Idempotent: on-conflict-do-nothing + create-or-replace.
insert into ui_copy (key, value) values
  ('notif_inbox.signed_out_title', to_jsonb('Sign in to see your notifications'::text)),
  ('notif_inbox.signed_out_hint',  to_jsonb('Order updates, payment reminders and delivery alerts are kept against your account.'::text))
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
             'channel_label', initcap(l.channel),
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

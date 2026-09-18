-- CMD #2071 — the SQL half of the bot-reply-cap proof.
-- Replay against the build branch:  psql "$(devcmd.sh dburl <id>)" -f scripts/test_bot_reply_cap.sql
-- Everything runs inside a transaction that rolls back; it writes nothing.
begin;
delete from whatsapp_messages where sender_phone = '919999900071';

-- 25 automated assistant replies inside the rolling window
insert into whatsapp_messages (sender_phone, direction, routed_to, msg_type, text_body, received_at)
select '919999900071','out','wa_assistant','text','auto '||g, now() - (g || ' minutes')::interval
from generate_series(1,25) g;

-- plus a reply an admin typed (routed_to null) and an OTP template.
-- Neither is on the capped-route allowlist, so neither counts.
insert into whatsapp_messages (sender_phone, direction, routed_to, msg_type, text_body, received_at)
values ('919999900071','out',null,'text','typed by admin', now()),
       ('919999900071','out','login_otp','template','OTP', now());

do $$
declare v jsonb; n int;
begin
  -- 1. the 26th automated reply is refused
  v := public.wa_bot_reply_allowed('919999900071','wa_assistant','wa_assistant_reply');
  if coalesce((v->>'allowed')::boolean, true) then
    raise exception 'FAIL: 26th bot reply was allowed: %', v; end if;
  if v->>'reason' <> 'bot_reply_cap' then
    raise exception 'FAIL: wrong reason: %', v; end if;

  -- 2. the menu/greeting bot lane is shut too
  if public.wa_bot_enabled('919999900071') then
    raise exception 'FAIL: wa_bot_enabled still true at the cap'; end if;

  -- 3. a manual admin reply and an OTP still send
  if not (public.wa_bot_reply_allowed('919999900071','manual_admin','admin_typed')->>'allowed')::boolean then
    raise exception 'FAIL: a manual admin reply was capped'; end if;
  if not (public.wa_bot_reply_allowed('919999900071','login_otp','login_otp')->>'allowed')::boolean then
    raise exception 'FAIL: an OTP was capped'; end if;
  if not (public.wa_bot_reply_allowed('919999900071','order_notify_placed','order_notify_placed')->>'allowed')::boolean then
    raise exception 'FAIL: an order notification was capped'; end if;

  -- 4. the skip is logged
  select count(*) into n from whatsapp_bot_skip_log
   where phone = '9999900071' and reason = 'bot_reply_cap';
  if n < 1 then raise exception 'FAIL: the skip was not logged'; end if;

  -- 5. the cap is per number
  if not (public.wa_bot_reply_allowed('919999900072','wa_assistant','wa_assistant_reply')->>'allowed')::boolean then
    raise exception 'FAIL: another number was capped too'; end if;

  -- 6. the window rolls: age the replies past 24h and the bot resumes itself
  update whatsapp_messages set received_at = now() - interval '25 hours'
   where sender_phone = '919999900071';
  if not (public.wa_bot_reply_allowed('919999900071','wa_assistant','wa_assistant_reply')->>'allowed')::boolean then
    raise exception 'FAIL: the rolling window did not release the cap'; end if;

  raise notice 'PASS: bot reply cap — 6/6';
end $$;
rollback;

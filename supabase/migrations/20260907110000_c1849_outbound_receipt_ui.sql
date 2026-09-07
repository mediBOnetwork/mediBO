-- CMD #1849 — THE RECEIPT IS THE DELIVERABLE.
--
-- A test session used to end in silence. It now ends in a transcript: would
-- have messaged supplier A, then supplier B after no answer, would have charged
-- this amount, would have paged the admin at this time. Every line here is a
-- backend-rendered sentence; the sheet that shows it prints strings and counts
-- nothing.

-- ---------------------------------------------------------------------------
-- 1. THE WORDS. All of them, in ui_copy, so a rewording is an UPDATE.
-- ---------------------------------------------------------------------------
insert into public.ui_copy (key, value) values
  ('outbound.sandboxed',        to_jsonb('Test mode: recorded on the receipt instead of sent.'::text)),
  ('outbound.held',             to_jsonb('This message was held: the system could not tell whether it belonged to a test run. Nothing was sent.'::text)),
  ('outbound.recipient_unknown',to_jsonb('Unnamed recipient'::text)),
  ('outbound.recipient_http',   to_jsonb('An external service'::text)),
  ('outbound.scan_clean',       to_jsonb('Every outbound call site is routed through the dispatcher.'::text)),
  ('outbound.scan_leak',        to_jsonb('An outbound call site does not go through the dispatcher.'::text)),
  ('receipt.title',             to_jsonb('What this session would have sent'::text)),
  ('receipt.subtitle',          to_jsonb('Nothing below left the building. This is the record of every message, charge and page the flow produced.'::text)),
  ('receipt.empty',             to_jsonb('Nothing has tried to leave yet. Walk the flow and every message it would send appears here.'::text)),
  ('receipt.one',               to_jsonb('1 outbound effect recorded'::text)),
  ('receipt.many',              to_jsonb('{n} outbound effects recorded'::text)),
  ('receipt.channel.whatsapp',  to_jsonb('WhatsApp'::text)),
  ('receipt.channel.push',      to_jsonb('Push'::text)),
  ('receipt.channel.email',     to_jsonb('Email'::text)),
  ('receipt.channel.payment',   to_jsonb('Payment'::text)),
  ('receipt.channel.admin_page',to_jsonb('Admin paging'::text)),
  ('receipt.channel.http',      to_jsonb('Other outbound calls'::text)),
  ('receipt.channel.unknown',   to_jsonb('Other'::text)),
  ('receipt.line.whatsapp',     to_jsonb('Would have messaged {who} on WhatsApp'::text)),
  ('receipt.line.push',         to_jsonb('Would have pushed a notification to {who}'::text)),
  ('receipt.line.email',        to_jsonb('Would have emailed {who}'::text)),
  ('receipt.line.payment',      to_jsonb('Would have charged {amount} to {who}'::text)),
  ('receipt.line.payment_noamt',to_jsonb('Would have asked Razorpay for a payment on {who}'::text)),
  ('receipt.line.admin_page',   to_jsonb('Would have paged the admin'::text)),
  ('receipt.line.http',         to_jsonb('Would have called {who}'::text)),
  ('receipt.line.unknown',      to_jsonb('Would have sent an outbound message to {who}'::text)),
  ('receipt.verdict.sandboxed', to_jsonb('recorded'::text)),
  ('receipt.verdict.held',      to_jsonb('held — could not tell whether this was a test row'::text)),
  ('receipt.verdict.leaked_blocked', to_jsonb('blocked at the wire — this call site is not routed yet'::text)),
  ('receipt.count_one',         to_jsonb('1 line'::text)),
  ('receipt.count_many',        to_jsonb('{n} lines'::text)),
  ('receipt.on_order',          to_jsonb('on {code}'::text))
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. ONE LINE OF THE TRANSCRIPT, rendered here and nowhere else.
-- ---------------------------------------------------------------------------
create or replace function public._outbound_receipt_line(r public.outbound_receipt)
 returns text language plpgsql stable security definer set search_path to 'public'
as $$
declare v text; v_who text;
begin
  v_who := coalesce(nullif(btrim(coalesce(r.recipient_label,'')),''),
                    nullif(btrim(coalesce(r.recipient,'')),''),
                    public.uic('outbound.recipient_unknown','Unnamed recipient'));
  if r.channel = 'payment' and r.amount is not null then
    v := replace(replace(public.uic('receipt.line.payment','Would have charged {amount} to {who}'),
                         '{amount}', public.inr_money(r.amount)), '{who}', v_who);
  elsif r.channel = 'payment' then
    v := replace(public.uic('receipt.line.payment_noamt','Would have asked Razorpay for a payment on {who}'), '{who}', v_who);
  elsif r.channel = 'admin_page' then
    v := public.uic('receipt.line.admin_page','Would have paged the admin');
  else
    v := replace(public.uic('receipt.line.'||coalesce(r.channel,'unknown'),
                            public.uic('receipt.line.unknown','Would have sent an outbound message to {who}')),
                 '{who}', v_who);
  end if;
  if coalesce(r.order_code,'') <> '' then
    v := v || ' ' || replace(public.uic('receipt.on_order','on {code}'), '{code}', r.order_code);
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 3. THE TRANSCRIPT. Payload order is the order it happened in.
-- ---------------------------------------------------------------------------
create or replace function public.test_session_receipt(p_session_id bigint default null)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_sess  bigint;
  v_admin boolean := false;
  v_lines jsonb;
  v_groups jsonb;
  v_n int;
begin
  begin v_admin := public.is_admin(); exception when others then v_admin := false; end;
  v_sess := coalesce(p_session_id, public.test_session_mine());
  if v_sess is null then
    return jsonb_build_object('has', false);
  end if;
  -- A person reads their OWN session's receipt; an admin reads any.
  if p_session_id is not null and not v_admin and p_session_id <> coalesce(public.test_session_mine(), -1) then
    return jsonb_build_object('has', false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',            r.id,
           'channel',       r.channel,
           'channel_label', public.uic('receipt.channel.'||coalesce(r.channel,'unknown'),
                                       public.uic('receipt.channel.unknown','Other')),
           'at_label',      public.ist_fmt(r.at, 'time12'),
           'line',          public._outbound_receipt_line(r),
           'template',      coalesce(nullif(btrim(coalesce(r.template,'')),''), r.event_key),
           'body',          r.body,
           'verdict',       r.verdict,
           'verdict_label', public.uic('receipt.verdict.'||r.verdict, r.verdict),
           'tone',          case r.verdict when 'sandboxed' then 'info'
                                           when 'held' then 'warning'
                                           else 'danger' end
         ) order by r.id), '[]'::jsonb)
    into v_lines
    from public.outbound_receipt r
   where r.session_id = v_sess;

  v_n := jsonb_array_length(v_lines);

  select coalesce(jsonb_agg(g order by g->>'first_id'), '[]'::jsonb) into v_groups
    from (
      select jsonb_build_object(
               'channel', l->>'channel',
               'label',   l->>'channel_label',
               'count_label', case when count(*) = 1
                                   then public.uic('receipt.count_one','1 line')
                                   else replace(public.uic('receipt.count_many','{n} lines'), '{n}', count(*)::text) end,
               'first_id', lpad(min((l->>'id')::bigint)::text, 20, '0'),
               'lines', jsonb_agg(l order by (l->>'id')::bigint)) as g
        from jsonb_array_elements(v_lines) l
       group by l->>'channel', l->>'channel_label'
    ) s;

  return jsonb_build_object(
    'has',         true,
    'session_id',  v_sess,
    'title',       public.uic('receipt.title','What this session would have sent'),
    'subtitle',    public.uic('receipt.subtitle',''),
    'empty_label', public.uic('receipt.empty',''),
    'count_label', case when v_n = 0 then ''
                        when v_n = 1 then public.uic('receipt.one','1 outbound effect recorded')
                        else replace(public.uic('receipt.many','{n} outbound effects recorded'), '{n}', v_n::text) end,
    'count',       v_n,
    'lines',       v_lines,
    'groups',      v_groups);
exception when others then
  return jsonb_build_object('has', false);
end $$;

revoke all on function public.test_session_receipt(bigint) from public, anon;
revoke all on function public._outbound_receipt_line(public.outbound_receipt) from public, anon;
grant execute on function public.test_session_receipt(bigint) to authenticated, service_role;
grant execute on function public._outbound_receipt_line(public.outbound_receipt) to authenticated, service_role;

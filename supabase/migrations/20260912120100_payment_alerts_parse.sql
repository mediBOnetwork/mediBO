-- CMD #1929 (2/9) — the parse engine and the ingest door.
--
-- The phone posts raw text. It never parses, never decides, never formats.
-- Everything below is server-side and every regex comes from
-- payment_alert_rules, so a new payment app is an INSERT.

-- ─── helpers ────────────────────────────────────────────────────────────────

-- A rupee figure as printed ("1,20,500.50") into a number.
create or replace function public._pa_amount(p text)
returns numeric language sql immutable as $$
  select case
    when coalesce(btrim(p),'') = '' then null
    else nullif(regexp_replace(p, '[^0-9.]', '', 'g'), '')::numeric
  end;
$$;

-- The first NON-NULL capture group of a regex over the notification text.
-- Non-null rather than [1] on purpose: a rule may spell one field as two
-- alternatives ("X paid you" / "received from X"), each with its own group.
-- Case-insensitive: notification wording is not stable.
create or replace function public._pa_cap(p_text text, p_re text)
returns text language plpgsql immutable as $$
declare m text[]; i int;
begin
  if coalesce(btrim(p_re),'') = '' or coalesce(p_text,'') = '' then return null; end if;
  begin
    m := regexp_match(p_text, p_re, 'i');
  exception when others then
    return null;                      -- a bad regex in the table is data, not a crash
  end;
  if m is null then return null; end if;
  for i in 1 .. coalesce(array_length(m,1),0) loop
    if nullif(btrim(coalesce(m[i],'')),'') is not null then return btrim(m[i]); end if;
  end loop;
  return null;
end $$;

-- Digits only, for UTR comparison. UTRs are printed with spaces and dashes.
create or replace function public._pa_digits(p text)
returns text language sql immutable as $$
  select nullif(regexp_replace(coalesce(p,''), '\D', '', 'g'), '');
$$;

-- ─── the rule pass ──────────────────────────────────────────────────────────
-- Returns the parsed fields and which rule produced them. The caller decides
-- what to do when nothing matched.
create or replace function public.payment_alert_parse_rules(p_package text, p_title text, p_text text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  r record; v_blob text; v_amt numeric; v_utr text; v_vpa text; v_sender text;
begin
  v_blob := btrim(coalesce(p_title,'') || E'\n' || coalesce(p_text,''));
  if v_blob = '' then
    return jsonb_build_object('ok', false, 'reason','empty_text');
  end if;

  -- The package's own rules first (priority), then the '*' fallback.
  for r in
    select * from public.payment_alert_rules
     where enabled
       and (package_name = p_package or package_name = '*')
     order by (package_name = '*')::int, priority, id
  loop
    -- A refusal rule wins before anything is read out of the text: a collect
    -- REQUEST and a debit both carry a ₹ figure and neither is money arriving.
    if coalesce(r.ignore_regex,'') <> '' and v_blob ~* r.ignore_regex then
      return jsonb_build_object('ok', false, 'reason','not_credit',
        'rule_id', r.id, 'rule_label', coalesce(r.label,''));
    end if;

    v_amt    := public._pa_amount(public._pa_cap(v_blob, r.amount_regex));
    if v_amt is null then continue; end if;   -- no money read: try the next rule

    v_utr    := public._pa_cap(v_blob, r.utr_regex);
    v_vpa    := public._pa_cap(v_blob, r.vpa_regex);
    v_sender := public._pa_cap(v_blob, r.sender_regex);

    return jsonb_build_object(
      'ok', true, 'source','rule',
      'rule_id', r.id, 'rule_label', coalesce(r.label,''),
      'amount', v_amt,
      'utr',    v_utr,
      'vpa',    v_vpa,
      'sender', v_sender);
  end loop;

  return jsonb_build_object('ok', false, 'reason','no_rule_matched');
end $$;

-- ─── the AI prompt, built in the BACKEND ────────────────────────────────────
-- The edge function is transport only: it asks for this prompt, posts it to
-- gemini-ocr, and hands the answer back. No wording lives in TypeScript.
create or replace function public.payment_alert_ai_prompt(p_alert_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare a public.payment_alerts%rowtype; v_blob text;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  v_blob := btrim(coalesce(a.raw_title,'') || E'\n' || coalesce(a.raw_text,''));

  return jsonb_build_object('ok', true, 'alert_id', a.id,
    'prompt',
      'You are reading ONE Android payment notification from an Indian payment app. '
      || 'Return STRICT JSON only, no markdown, no commentary, exactly this shape: '
      || '{"is_credit":true|false,"amount":number|null,"utr":"string|null",'
      || '"vpa":"string|null","sender":"string|null"}.'
      || E'\n\nRULES — read before answering:\n'
      || '- Copy text EXACTLY as printed. You are a camera, not a database. Never expand, '
      || 'correct, translate or normalise a name, and never apply world knowledge about who '
      || 'a business belongs to.' || E'\n'
      || '- is_credit is true ONLY when money ARRIVED in our account. A collect request, a '
      || 'reminder, a debit, a payment we sent, a failure, a refund and a balance notice are '
      || 'all false.' || E'\n'
      || '- amount is the rupee figure as a plain number, no symbol, no commas (500, 1250.50).' || E'\n'
      || '- utr is the UPI reference / UTR / RRN / transaction id digits exactly as printed, '
      || 'null when the notification does not carry one. Never invent or pad one.' || E'\n'
      || '- vpa is the payer UPI handle (something@something) exactly as printed, else null.' || E'\n'
      || '- sender is the payer name exactly as printed, else null.' || E'\n'
      || '- Every field you cannot read from the text is null. Guessing is wrong.'
      || E'\n\nNOTIFICATION PACKAGE: ' || coalesce(a.package_name,'')
      || E'\nNOTIFICATION TEXT:\n' || v_blob);
end $$;

-- ─── the ingest door ────────────────────────────────────────────────────────
-- Authenticated partner or admin only. Idempotent on
-- (device, package, posted_at, md5(text)) — the same notification forwarded
-- twice is one row and the second call returns the first row's verdict.
create or replace function public.payment_alert_ingest(
  p_device text, p_package text, p_title text, p_text text,
  p_posted_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_role text := coalesce(public.get_my_role(),'');
  v_is_partner boolean := coalesce(public.is_partner(), false);
  v_zone smallint; v_id uuid; v_md5 text; v_posted timestamptz;
  v_parse jsonb; v_key text;
begin
  if auth.uid() is null or not (v_is_partner or v_role in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_alert.not_authorized','Only a partner or an admin phone can forward payment alerts.'));
  end if;
  if coalesce(btrim(p_device),'') = '' or coalesce(btrim(p_package),'') = '' then
    return jsonb_build_object('ok', false, 'error','bad_request',
      'message', public.uic('pay_alert.bad_request','A device id and a package name are required.'));
  end if;

  v_posted := coalesce(p_posted_at, now());
  v_md5    := md5(coalesce(p_text,''));
  v_zone   := coalesce(public.partner_zone_id(), public.admin_active_zone(), public.zone_default_id());

  insert into public.payment_alerts
    (device_id, package_name, raw_title, raw_text, posted_at, text_md5, zone_id, business_date, status)
  values
    (btrim(p_device), btrim(p_package), nullif(btrim(coalesce(p_title,'')),''),
     p_text, v_posted, v_md5, v_zone,
     (v_posted at time zone 'Asia/Kolkata')::date, 'new')
  on conflict (device_id, package_name, posted_at, text_md5) do nothing
  returning id into v_id;

  if v_id is null then
    -- Already seen. Say so, and hand back the verdict we already reached.
    select id into v_id from public.payment_alerts
     where device_id = btrim(p_device) and package_name = btrim(p_package)
       and posted_at = v_posted and text_md5 = v_md5;
    return public.payment_alert_state(v_id) || jsonb_build_object('duplicate', true);
  end if;

  -- Parse now, with the rules. Only a rule pass that read nothing pays for AI.
  v_parse := public.payment_alert_parse_rules(btrim(p_package), p_title, p_text);

  if (v_parse->>'ok')::boolean then
    update public.payment_alerts
       set parsed_amount = nullif(v_parse->>'amount','')::numeric,
           parsed_utr    = nullif(v_parse->>'utr',''),
           parsed_vpa    = nullif(v_parse->>'vpa',''),
           parsed_sender = nullif(v_parse->>'sender',''),
           parse_source  = 'rule',
           parse_rule_id = nullif(v_parse->>'rule_id','')::bigint,
           parse_note    = nullif(v_parse->>'rule_label',''),
           updated_at    = now()
     where id = v_id;
    perform public.payment_alert_match(v_id);

  elsif (v_parse->>'reason') = 'not_credit' then
    -- Money did not arrive. Nothing to match, and nothing to look at.
    update public.payment_alerts
       set status = 'ignored', parse_source = 'rule',
           parse_rule_id = nullif(v_parse->>'rule_id','')::bigint,
           parse_note = public.uic('pay_alert.ignored.not_credit','Not money coming in.'),
           updated_at = now()
     where id = v_id;

  else
    -- No rule could read it: hand it to the AI fallback (parse_source='ai'
    -- is stamped by payment_alert_ai_apply, never here).
    update public.payment_alerts
       set parse_note = v_parse->>'reason', updated_at = now()
     where id = v_id;
    perform public._pa_ai_enqueue(v_id);
  end if;

  return public.payment_alert_state(v_id);
end $$;

-- ─── the AI fallback, enqueued ──────────────────────────────────────────────
create or replace function public._pa_ai_enqueue(p_alert_id uuid)
returns void language plpgsql security definer set search_path to 'public', 'net' as $$
declare v_key text;
begin
  begin
    select decrypted_secret into v_key from vault.decrypted_secrets
     where name = 'SERVICE_ROLE_KEY' limit 1;
    perform net.http_post(
      url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/payment-alert-ai',
      headers := jsonb_build_object('Content-Type','application/json',
                   'Authorization', 'Bearer '||coalesce(v_key,'')),
      body := jsonb_build_object('alert_id', p_alert_id),
      timeout_milliseconds := 30000);
  exception when others then
    -- The alert still exists and the sweep will pick it up. Never lose a row
    -- because the dispatcher was unavailable.
    update public.payment_alerts
       set parse_note = 'ai_enqueue_failed: ' || left(sqlerrm, 180), updated_at = now()
     where id = p_alert_id;
  end;
end $$;

-- What the AI read, applied. parse_source='ai' is stamped HERE, so an alert
-- can never claim an AI parse it did not get.
create or replace function public.payment_alert_ai_apply(
  p_alert_id uuid, p_parsed jsonb, p_model text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a public.payment_alerts%rowtype; v_amt numeric; v_credit boolean;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  if a.status <> 'new' or a.parse_source = 'rule' then
    return public.payment_alert_state(a.id) || jsonb_build_object('skipped','already_parsed');
  end if;

  v_credit := coalesce((p_parsed->>'is_credit')::boolean, false);
  v_amt    := nullif(p_parsed->>'amount','')::numeric;

  if not v_credit or v_amt is null or v_amt <= 0 then
    update public.payment_alerts
       set parse_source = 'ai', ai_model = p_model, updated_at = now(),
           status = case when not v_credit then 'ignored' else 'unmatched' end,
           match_reason = case when not v_credit
             then public.uic('pay_alert.ignored.not_credit','Not money coming in.')
             else public.uic('pay_alert.unmatched.no_amount','The notification carried no amount.') end
     where id = p_alert_id;
    return public.payment_alert_state(p_alert_id);
  end if;

  update public.payment_alerts
     set parsed_amount = v_amt,
         parsed_utr    = nullif(btrim(coalesce(p_parsed->>'utr','')),''),
         parsed_vpa    = nullif(btrim(coalesce(p_parsed->>'vpa','')),''),
         parsed_sender = nullif(btrim(coalesce(p_parsed->>'sender','')),''),
         parse_source  = 'ai',
         ai_model      = p_model,
         updated_at    = now()
   where id = p_alert_id;

  perform public.payment_alert_match(p_alert_id);
  return public.payment_alert_state(p_alert_id);
end $$;

-- Anything the dispatcher dropped: re-enqueued. Cheap, bounded, idempotent.
create or replace function public.payment_alert_ai_sweep(p_limit int default 20)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_n int := 0; r record;
begin
  for r in
    select id from public.payment_alerts
     where status = 'new' and parse_source = 'none'
       and created_at < now() - interval '2 minutes'
       and created_at > now() - interval '2 days'
     order by created_at limit greatest(coalesce(p_limit,20),1)
  loop
    perform public._pa_ai_enqueue(r.id);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'enqueued', v_n);
end $$;

revoke all on function public.payment_alert_ai_apply(uuid, jsonb, text) from anon, authenticated;
revoke all on function public.payment_alert_ai_prompt(uuid) from anon;
revoke all on function public.payment_alert_ai_sweep(int) from anon, authenticated;
grant execute on function public.payment_alert_ingest(text, text, text, text, timestamptz) to authenticated;

-- CHANGE #173 (part 5 completion) — WhatsApp one-reply reorder: make the
-- inbound side actually DO something.
--
-- What was wrong after the first pass:
--   1. app_settings.wa_quick_reply_actions gained 'reorder_confirm'/'reorder_skip'
--      rows, but wa_quick_reply_action only LOGGED the action and returned a
--      canned "we have rebuilt your order" reply. Nothing was ever rebuilt, so
--      the customer was told an order existed when it did not.
--   2. That function exits on the FIRST config entry whose `match` is a
--      substring of the reply. The generic 'reorder' entry sits earlier in the
--      array, so 'reorder yes' matched 'reorder' and the two new actions were
--      unreachable in principle.
--   3. Nothing in the inbound path routes a plain "YES"/"SKIP" to the reorder
--      engine at all.
--
-- Fixes here:
--   * wa_quick_reply_action picks the LONGEST matching entry (order-independent)
--     and executes the reorder actions, returning the backend's truthful copy.
--   * reorder_wa_inbound() is a narrow, reorder-only entry point, driven by an
--     AFTER INSERT trigger on the inbound message log (see the bottom of this
--     file). It answers ONLY when that customer has an OPEN reorder_pending row — i.e.
--     only when mediBO actually asked them. A stray "yes" in a normal chat is
--     never read as an order. It deliberately does NOT wake the other dormant
--     quick-reply actions (send_bill / call_me / opt_out), which have never run
--     in production and are out of scope for this command.

-- ─── Reply copy (backend-owned, like the rest of the suite) ──────────────────
insert into public.ui_copy(key, value) values
 ('reorder.wa_confirmed',  to_jsonb('Done — your usual items are back in your cart. Our team will confirm shortly.'::text)),
 ('reorder.wa_skipped',    to_jsonb('No problem — we have skipped this reorder. Reply anytime to order.'::text)),
 ('reorder.wa_nothing',    to_jsonb('You have no reorder waiting right now. Open mediBO to browse your regular items.'::text)),
 ('reorder.wa_none_added', to_jsonb('Those items are not available right now. Our team will call you shortly.'::text))
on conflict (key) do nothing;

-- ─── Match words (backend config, not Dart, not hardcoded in the handler) ────
insert into public.app_settings(key, value) values
 ('reorder_wa_inbound', jsonb_build_object(
    'enabled', true,
    -- exact-match tokens: an exact word, so "no supplier for this" is never a SKIP
    'yes',  jsonb_build_array('yes','y','haan','han','ha','ok','okay','confirm','reorder yes'),
    'skip', jsonb_build_array('skip','no','nahi','na','cancel','reorder skip')))
on conflict (key) do nothing;

-- ─── The reorder-only inbound handler ───────────────────────────────────────
create or replace function public.reorder_wa_inbound(p_phone text, p_text text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_cfg jsonb; v_norm text; v_ph text; v_cust uuid;
  v_intent text; v_res jsonb; v_pending uuid;
begin
  select value into v_cfg from app_settings where key='reorder_wa_inbound';
  if not coalesce((v_cfg->>'enabled')::boolean, false) then
    return jsonb_build_object('handled', false, 'reason','disabled');
  end if;

  -- normalise: lowercase, strip punctuation/emoji-ish trailing chars, collapse spaces
  v_norm := btrim(regexp_replace(lower(coalesce(p_text,'')), '[^a-z0-9 ]', '', 'g'));
  v_norm := regexp_replace(v_norm, '\s+', ' ', 'g');
  if v_norm = '' then
    return jsonb_build_object('handled', false, 'reason','empty');
  end if;

  -- EXACT token match only (never substring) so ordinary chat is not hijacked
  if exists (select 1 from jsonb_array_elements_text(coalesce(v_cfg->'yes','[]'::jsonb)) t
              where t = v_norm) then
    v_intent := 'confirm';
  elsif exists (select 1 from jsonb_array_elements_text(coalesce(v_cfg->'skip','[]'::jsonb)) t
                 where t = v_norm) then
    v_intent := 'skip';
  else
    return jsonb_build_object('handled', false, 'reason','no_match');
  end if;

  v_ph := public.wa_normalize_phone(p_phone);
  select id into v_cust from pharmacy_profiles
   where public.wa_normalize_phone(coalesce(nullif(btrim(whatsapp_no),''), phone)) = v_ph
     and coalesce(is_deleted,false) = false
   limit 1;
  if v_cust is null then
    return jsonb_build_object('handled', false, 'reason','unknown_customer');
  end if;

  -- THE GATE: only treat this as a reorder answer if we actually asked.
  select id into v_pending from public.reorder_pending
   where customer_id = v_cust and status = 'open'
   order by created_at limit 1;
  if v_pending is null then
    return jsonb_build_object('handled', false, 'reason','no_pending');
  end if;

  if v_intent = 'skip' then
    perform public.reorder_skip_pending(v_cust);
    return jsonb_build_object('handled', true, 'action','reorder_skip',
      'customer_id', v_cust, 'phone', v_ph,
      'reply', public._reorder_uic('reorder.wa_skipped','No problem — we have skipped this reorder.'));
  end if;

  v_res := public.reorder_confirm_pending(v_cust);
  if coalesce((v_res->>'ok')::boolean, false) and coalesce((v_res->>'added')::int, 0) > 0 then
    perform public.wa_send_event('reorder_confirmed', v_cust, jsonb_build_object(), v_ph, null);
    return jsonb_build_object('handled', true, 'action','reorder_confirm',
      'added', (v_res->>'added')::int, 'customer_id', v_cust, 'phone', v_ph,
      'reply', public._reorder_uic('reorder.wa_confirmed','Done — your usual items are back in your cart.'));
  end if;

  -- pending existed but nothing could be added (everything went out of stock)
  return jsonb_build_object('handled', true, 'action','reorder_confirm_empty',
    'added', 0, 'customer_id', v_cust, 'phone', v_ph,
    'reply', public._reorder_uic('reorder.wa_none_added','Those items are not available right now.'));
end $$;

grant execute on function public.reorder_wa_inbound(text, text) to service_role;

-- ─── Generic switchboard: longest match + actually execute the reorder actions ─
create or replace function public.wa_quick_reply_action(p_phone text, p_button_text text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_cfg jsonb; a jsonb; v_norm text; v_ph text; v_cust uuid;
        v_action text; v_reply text; v_best int := -1; v_res jsonb;
begin
  select value into v_cfg from app_settings where key='wa_quick_reply_actions';
  if not coalesce((v_cfg->>'enabled')::boolean, false) then
    return jsonb_build_object('handled', false, 'reason','disabled');
  end if;

  v_norm := lower(btrim(coalesce(p_button_text,'')));
  if v_norm = '' then return jsonb_build_object('handled', false, 'reason','empty'); end if;

  -- LONGEST match wins, so a specific 'reorder yes' is never swallowed by the
  -- generic 'reorder'. Config order no longer decides behaviour.
  for a in select value from jsonb_array_elements(coalesce(v_cfg->'actions','[]'::jsonb)) loop
    if v_norm like '%' || lower(a->>'match') || '%'
       and length(coalesce(a->>'match','')) > v_best then
      v_best   := length(coalesce(a->>'match',''));
      v_action := a->>'action';
      v_reply  := coalesce(a->>'reply_hi', a->>'reply_en');
    end if;
  end loop;

  if v_action is null then return jsonb_build_object('handled', false, 'reason','no_match'); end if;

  v_ph := public.wa_normalize_phone(p_phone);
  select id into v_cust from pharmacy_profiles
   where public.wa_normalize_phone(coalesce(nullif(btrim(whatsapp_no),''), phone)) = v_ph
     and coalesce(is_deleted,false) = false limit 1;

  if v_action = 'opt_out' then
    perform public.wa_suppress(v_ph, 'quick_reply_stop');

  -- these two used to be logged and answered with a lie; now they run.
  elsif v_action = 'reorder_confirm' and v_cust is not null then
    v_res := public.reorder_confirm_pending(v_cust);
    if not coalesce((v_res->>'ok')::boolean, false) then
      v_reply := public._reorder_uic('reorder.wa_nothing','You have no reorder waiting right now.');
    elsif coalesce((v_res->>'added')::int,0) = 0 then
      v_reply := public._reorder_uic('reorder.wa_none_added','Those items are not available right now.');
    else
      v_reply := public._reorder_uic('reorder.wa_confirmed','Done — your usual items are back in your cart.');
    end if;

  elsif v_action = 'reorder_skip' and v_cust is not null then
    perform public.reorder_skip_pending(v_cust);
    v_reply := public._reorder_uic('reorder.wa_skipped','No problem — we have skipped this reorder.');
  end if;

  insert into wa_quick_reply_log(phone, customer_id, button_text, action)
  values (v_ph, v_cust, p_button_text, v_action);

  return jsonb_build_object('handled', true, 'action', v_action, 'reply', v_reply,
                            'customer_id', v_cust, 'phone', v_ph);
end $$;

-- ─── Inbound trigger: the loop closes without touching whatsapp-webhook ──────
-- Same idiom as _wa_login_button / trg_wa_inbound_stop: an AFTER INSERT trigger
-- on the inbound message log that calls the wa-reply function through pg_net.
-- wa-reply already exists for exactly this (its default tag is 'quick_reply').
-- Editing the 59 KB production webhook was the alternative; this needs none of
-- it, so inbound WhatsApp (payments, supplier "packed", the bot) is untouched.
-- `exception when others then return new` — a reorder failure must NEVER block
-- an inbound message, matching the sibling triggers.
create or replace function public.trg_wa_reorder_reply()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_res jsonb;
begin
  if coalesce(new.direction,'') <> 'in' then return new; end if;
  if coalesce(new.msg_type,'') not in ('text','button','interactive') then return new; end if;
  if coalesce(btrim(new.text_body),'') = '' then return new; end if;

  v_res := public.reorder_wa_inbound(new.sender_phone, new.text_body);
  if coalesce((v_res->>'handled')::boolean, false) and coalesce(v_res->>'reply','') <> '' then
    perform net.http_post(
      url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/wa-reply',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body := jsonb_build_object('to', v_res->>'phone', 'tag','reorder_reply',
                                 'text', v_res->>'reply'));
  end if;
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists wa_reorder_reply_trg on public.whatsapp_messages;
create trigger wa_reorder_reply_trg after insert on public.whatsapp_messages
for each row execute function public.trg_wa_reorder_reply();

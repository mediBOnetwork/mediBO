-- CHANGE #705 (3/5) — the gates.
--
-- A verified drug licence is now the condition for trading, on both sides:
--   * a pharmacy or supplier cannot be APPROVED without one (trigger — it
--     catches the admin console, an import and a hand-written UPDATE alike);
--   * a pharmacy cannot PLACE AN ORDER without one (cart_rx_gate, the block the
--     cart and _place_order_v2_core already both read);
--   * a supplier does not RECEIVE INQUIRIES without one (start_inquiry_for_
--     suppliers, the same shape a closed shop already had).
--
-- Existing approved accounts keep trading for kyc_gate.grace_days (14) — the
-- block lands when the grace runs out, never the moment this deploys. The
-- backend words every refusal; nothing here is a Dart string.
-- Idempotent throughout.

insert into public.ui_copy (key, value) values
  ('kyc_gate.block_title',       to_jsonb('Drug licence needed'::text)),
  ('kyc_gate.block_missing',     to_jsonb('Upload your drug licence and we will verify it. Ordering opens as soon as it is verified.'::text)),
  ('kyc_gate.block_pending',     to_jsonb('Your drug licence is with us for verification. Ordering opens as soon as it is verified.'::text)),
  ('kyc_gate.block_rejected',    to_jsonb('Your drug licence was rejected. Please upload a corrected copy.'::text)),
  ('kyc_gate.block_expired',     to_jsonb('Your drug licence has expired. Upload the renewed licence to start trading again.'::text)),
  ('kyc_gate.grace_note',        to_jsonb('Upload your drug licence before {d} to keep ordering.'::text)),
  ('kyc_gate.approve_blocked',   to_jsonb('This account cannot be approved until its drug licence is uploaded and verified.'::text)),
  ('kyc_gate.action_label',      to_jsonb('Upload licence'::text)),
  ('kyc_gate.action_route',      to_jsonb('/account/kyc'::text)),
  ('kyc_gate.short_label',       to_jsonb('Licence pending'::text)),
  ('kyc_gate.supplier_blocked',  to_jsonb('This supplier is not being asked: its drug licence is missing, rejected or expired.'::text))
on conflict (key) do nothing;

-- The order gate's own copy table, so the session payload words it the way
-- every other blocker is worded.
update public.app_settings
   set value = value || jsonb_build_object('kyc_blocked', jsonb_build_object(
         'title',        public._c('kyc_gate.block_title'),
         'message',      public._c('kyc_gate.block_missing'),
         'action_label', public._c('kyc_gate.action_label'),
         'action_route', public._c('kyc_gate.action_route'),
         'short_label',  public._c('kyc_gate.short_label')))
 where key = 'order_gate_copy';

-- ── the decision, in one place ─────────────────────────────────────────────
create or replace function public.kyc_gate(p_owner_kind text, p_owner_id uuid,
                                           p_action text default 'trade')
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  st jsonb := public.kyc_state(p_owner_kind, p_owner_id);
  v_state text; v_blocked boolean; v_msg text;
begin
  if not coalesce((st->>'ok')::boolean, false) then
    return jsonb_build_object('allowed', true, 'blocked', false, 'reason','unknown_owner',
                              'title','', 'message','', 'state', st);
  end if;
  v_state := st->>'state';

  -- Approval is the one action grace does NOT cover: an account being approved
  -- today is a NEW decision, and it needs the document on file.
  if lower(coalesce(p_action,'trade')) = 'approve' then
    v_blocked := coalesce((st->>'enforce')::boolean, true) and v_state <> 'verified';
    v_msg := public._c('kyc_gate.approve_blocked');
  else
    v_blocked := coalesce((st->>'enforce')::boolean, true)
                 and v_state <> 'verified'
                 and not coalesce((st->>'in_grace')::boolean, false);
    v_msg := case v_state
               when 'pending'  then public._c('kyc_gate.block_pending')
               when 'rejected' then public._c('kyc_gate.block_rejected')
               when 'expired'  then public._c('kyc_gate.block_expired')
               else public._c('kyc_gate.block_missing') end;
  end if;

  return jsonb_build_object(
    'allowed', not v_blocked,
    'blocked', v_blocked,
    'reason',  case when v_blocked then 'kyc_'||v_state else 'none' end,
    'title',   case when v_blocked then public._c('kyc_gate.block_title') else '' end,
    'message', case when v_blocked then v_msg else '' end,
    'action_label', public._c('kyc_gate.action_label'),
    'action_route', public._c('kyc_gate.action_route'),
    'grace_note', case when coalesce((st->>'in_grace')::boolean,false) and v_state <> 'verified'
                       then public._cf('kyc_gate.grace_note',
                              jsonb_build_object('d',
                                to_char((st->>'grace_until')::date, 'FMDD Mon YYYY')))
                       else '' end,
    'state', st);
end
$fn$;

-- A supplier is addressed by NAME everywhere in the inquiry engine.
create or replace function public.kyc_supplier_blocked(p_supplier_name text)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare v_id uuid;
begin
  select id into v_id from supplier_profiles
   where supplier_name = p_supplier_name and not coalesce(is_deleted,false)
   order by coalesce(approved,false) desc limit 1;
  if v_id is null then return false; end if;   -- unknown name: not our business
  return coalesce((public.kyc_gate('supplier', v_id, 'trade')->>'blocked')::boolean, false);
end
$fn$;

-- ── the approval guard — every path, not one RPC ───────────────────────────
create or replace function public._kyc_approval_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_kind text; v_gate jsonb;
begin
  -- only on the transition INTO approved, and only when enforcement is on
  if coalesce(new.approved,false) is not true then return new; end if;
  if tg_op = 'UPDATE' and coalesce(old.approved,false) is true then return new; end if;
  if not coalesce((select (value->>'enforce')::boolean from app_settings where key='kyc_gate'), true)
    then return new; end if;

  v_kind := case tg_table_name when 'pharmacy_profiles' then 'pharmacy' else 'supplier' end;
  v_gate := public.kyc_gate(v_kind, new.id, 'approve');
  if coalesce((v_gate->>'blocked')::boolean, false) then
    -- RAISE cannot take a format string AND a MESSAGE option; the applicant's
    -- own sentence IS the message, so it goes in the option and the machine
    -- name goes in DETAIL.
    raise exception using errcode = 'P0001',
            message = coalesce(nullif(v_gate->>'message',''), 'kyc_not_verified'),
            detail  = 'kyc_not_verified',
            hint    = 'kyc_gate: '||coalesce(v_gate->'state'->>'state','');
  end if;
  return new;
end
$fn$;

drop trigger if exists trg_kyc_approval_guard_pharmacy on public.pharmacy_profiles;
create trigger trg_kyc_approval_guard_pharmacy
  before insert or update of approved on public.pharmacy_profiles
  for each row execute function public._kyc_approval_guard();

drop trigger if exists trg_kyc_approval_guard_supplier on public.supplier_profiles;
create trigger trg_kyc_approval_guard_supplier
  before insert or update of approved on public.supplier_profiles
  for each row execute function public._kyc_approval_guard();

-- ── the order gate — the block the cart and place_order already both read ──
create or replace function public.cart_rx_gate(p_customer uuid, p_items jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_rx   int := 0;
  v_lic  jsonb := public.rx_licence_state(p_customer);
  v_block boolean;
  v_title text := ''; v_msg text := '';
  v_kyc  jsonb;                                   -- CHANGE #705
  v_kyc_block boolean := false;
begin
  select count(*) into v_rx
    from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) it
    join "MEDICINE" m on m.id = nullif(it->>'product_id','')::bigint
   where upper(btrim(coalesce(m.rx_required,''))) = 'RX';

  if v_rx > 0 and not coalesce((v_lic->>'has')::boolean, false) then
    if (v_lic->>'reason') = 'expired' then
      v_title := public._c('rx.licence_expired_title');
      v_msg   := public._cf('rx.licence_expired_msg',
                   jsonb_build_object('date', to_char((v_lic->>'expiry')::date, 'DD Mon YYYY')));
    else
      v_title := public._c('rx.licence_missing_title');
      v_msg   := case when v_rx = 1
                      then public._c('rx.licence_missing_msg_one')
                      else public._cf('rx.licence_missing_msg_many',
                             jsonb_build_object('count', v_rx::text)) end;
    end if;
  end if;

  v_block := (v_rx > 0)
             and not coalesce((v_lic->>'has')::boolean, false)
             and coalesce((v_lic->>'enforced')::boolean, false);

  -- CHANGE #705 — KYC parity. The Rx gate above asks "is there a licence
  -- NUMBER on file, and does this basket contain Schedule H stock?"; this asks
  -- "has a human VERIFIED the licence document?", and it applies to the whole
  -- basket, not only to Rx lines. Existing approved pharmacies keep ordering
  -- through their grace window; kyc_gate decides, this only renders it.
  v_kyc := public.kyc_gate('pharmacy', p_customer, 'trade');
  v_kyc_block := coalesce((v_kyc->>'blocked')::boolean, false);
  if v_kyc_block then
    v_title := coalesce(nullif(v_kyc->>'title',''), v_title);
    v_msg   := coalesce(nullif(v_kyc->>'message',''), v_msg);
  elsif v_msg = '' and coalesce(v_kyc->>'grace_note','') <> '' then
    v_msg := v_kyc->>'grace_note';                -- a warning, never a block
  end if;

  return jsonb_build_object(
    'has',        (v_rx > 0),
    'rx_count',   v_rx,
    'rx_note',    case when v_rx = 0 then ''
                       when v_rx = 1 then public._c('rx.cart_rx_note_one')
                       else public._cf('rx.cart_rx_note_many',
                              jsonb_build_object('count', v_rx::text)) end,
    'licence',    v_lic,
    'kyc',        v_kyc,
    'can_order',  not (v_block or v_kyc_block),
    'blocked',    (v_block or v_kyc_block),
    'is_warning', (v_msg <> '' and not (v_block or v_kyc_block)),
    'title',      v_title,
    'message',    v_msg,
    'tone',       case when (v_block or v_kyc_block) then jsonb_build_object('bg','#FEE2E2','fg','#991B1B')
                       when v_msg <> '' then jsonb_build_object('bg','#FEF3C7','fg','#92400E')
                       else jsonb_build_object('bg','#D1FAE5','fg','#065F46') end);
end
$fn$;

grant execute on function public.kyc_gate(text,uuid,text) to authenticated;
grant execute on function public.kyc_supplier_blocked(text) to authenticated;

-- ── a blocked supplier is not asked ────────────────────────────────────────
-- Reproduced verbatim from the live definition with ONE block added, so a
-- resumed worker re-applies exactly this and never re-derives it.
CREATE OR REPLACE FUNCTION public.start_inquiry_for_suppliers(p_supplier_names text[] DEFAULT NULL::text[], p_force boolean DEFAULT false)
 RETURNS TABLE(supplier_name text, token text, status text, expires_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_suppliers text[]; v_sup text; v_token text; v_status text;
  v_expires timestamptz; v_ready jsonb; v_started boolean;
  v_ttl_sent int; v_ttl_draft int;
BEGIN
  v_ttl_sent  := coalesce((select (value #>> '{}')::int from app_settings where key='inquiry_form_ttl_minutes'), 10);
  v_ttl_draft := coalesce((select (value #>> '{}')::int from app_settings where key='inquiry_draft_ttl_minutes'), 1440);

  v_ready := public.inquiry_send_readiness();
  IF NOT (v_ready->>'can_send')::boolean THEN
    IF p_force AND get_my_role() = 'super_admin' THEN NULL;
    ELSE RAISE EXCEPTION 'inquiry_send_blocked' USING HINT = v_ready::text; END IF;
  END IF;

  v_started := public.inquiry_locked();

  IF p_supplier_names IS NULL THEN
    SELECT ARRAY_AGG(DISTINCT sup) INTO v_suppliers
    FROM ( SELECT i.current_supplier AS sup FROM inquiry i WHERE i.current_supplier IS NOT NULL
           UNION
           SELECT i.next_supplier AS sup FROM inquiry i WHERE i.next_supplier IS NOT NULL ) t;
  ELSE
    v_suppliers := p_supplier_names;
  END IF;
  IF v_suppliers IS NULL OR array_length(v_suppliers, 1) = 0 THEN RETURN; END IF;

  FOREACH v_sup IN ARRAY v_suppliers LOOP
    -- cmd #401: a closed shop is skipped here, and the inquiries pointed at him
    -- are advanced rather than left to time out against him.
    IF public.supplier_closed_now(v_sup) THEN
      PERFORM public._inquiry_advance_past_closed(v_sup);
      RETURN QUERY SELECT v_sup, NULL::text, 'closed'::text, NULL::timestamptz;
      CONTINUE;
    END IF;

    -- CHANGE #705: a supplier whose drug licence is missing, rejected or
    -- expired does not receive inquiries. Exactly the closed-shop shape above:
    -- skipped here, and the inquiries pointed at him are ADVANCED rather than
    -- left to time out against an account that cannot legally answer.
    IF public.kyc_supplier_blocked(v_sup) THEN
      PERFORM public._inquiry_advance_past_closed(v_sup);
      RETURN QUERY SELECT v_sup, NULL::text, 'kyc_blocked'::text, NULL::timestamptz;
      CONTINUE;
    END IF;

    IF v_started THEN
      -- cmd #526 gap 28: the token AND the secret ROTATE on every send, and the
      -- window comes from app_settings instead of a literal. A forwarded link
      -- from the last round is dead the moment a new one goes out.
      INSERT INTO inquiry_forms (supplier_name, last_sent_at, expires_at, status, token, link_secret)
      VALUES (v_sup, now(), now() + (v_ttl_sent || ' minutes')::interval, 'pending',
              replace(gen_random_uuid()::text,'-',''), public.gen_link_secret())
      ON CONFLICT ON CONSTRAINT inquiry_forms_supplier_name_key DO UPDATE SET
        last_sent_at = now(), expires_at = now() + (v_ttl_sent || ' minutes')::interval,
        token        = replace(gen_random_uuid()::text,'-',''),
        link_secret  = public.gen_link_secret(),
        status = CASE WHEN inquiry_forms.status IN ('expired','draft') THEN 'pending' ELSE inquiry_forms.status END;
      UPDATE inquiry SET asked_at = COALESCE(asked_at, now()),
                         inquiry_phase = 'sent'
       WHERE (current_supplier = v_sup OR next_supplier = v_sup)
         AND coalesce(inquiry_phase,'draft') IN ('draft','sent');
    ELSE
      -- cmd #526 gap 28: a DRAFT link is bounded too. expires_at NULL was the
      -- permanent bearer token — 10 of the 11 live rows sat in exactly this state.
      INSERT INTO inquiry_forms (supplier_name, last_sent_at, expires_at, status, token, link_secret)
      VALUES (v_sup, now(), now() + (v_ttl_draft || ' minutes')::interval, 'draft',
              replace(gen_random_uuid()::text,'-',''), public.gen_link_secret())
      ON CONFLICT ON CONSTRAINT inquiry_forms_supplier_name_key DO UPDATE SET
        last_sent_at = now(), expires_at = now() + (v_ttl_draft || ' minutes')::interval,
        token        = replace(gen_random_uuid()::text,'-',''),
        link_secret  = public.gen_link_secret(),
        status = CASE WHEN inquiry_forms.status IN ('pending','expired') THEN 'draft' ELSE inquiry_forms.status END;
      UPDATE inquiry SET asked_at = NULL,
                         inquiry_phase = 'draft'
       WHERE (current_supplier = v_sup OR next_supplier = v_sup)
         AND coalesce(inquiry_phase,'draft') IN ('draft','sent');
    END IF;

    SELECT f.token, f.status, f.expires_at INTO v_token, v_status, v_expires
    FROM inquiry_forms f WHERE f.supplier_name = v_sup;
    RETURN QUERY SELECT v_sup, v_token, v_status, v_expires;
  END LOOP;
END;
$function$;

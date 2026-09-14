-- CMD #1930 — Payment alerts admin screen.
--
-- #1929 built the ingest, the parser and the automatic match. This adds the
-- three things an admin does with what the matcher could NOT decide:
--   1. link an unmatched alert to a pending claim by hand (same verify path),
--   2. ignore it,
--   3. teach the parser a new payment app WITHOUT a deploy.
-- Every label below lives in ui_copy or is built here: Flutter renders only.

-- ── 1. LINK TO CLAIM — the candidate list ────────────────────────────────────
-- The closest pending claims, ranked by how far each is from the alert: the
-- amount first (an exact rupee match is the strongest signal a human has), the
-- clock second. The ranking, the wording of the distance and the tone of each
-- row are all decided here.
create or replace function public.payment_alert_link_options(
  p_alert_id uuid, p_limit integer default 8)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $fn$
declare
  a public.payment_alerts%rowtype;
  v_zone smallint; v_date date;
  v_lim int := least(greatest(coalesce(p_limit,8),1), 25);
  v_rows jsonb;
begin
  if coalesce(public.get_my_role(),'') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_alert.link_denied',
                            'Only an admin can link a payment to an order.'));
  end if;

  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public.uic('pay_alert.not_found','That payment alert is gone.'));
  end if;

  -- The alert carries the scope it was ingested in; the header picker is the
  -- fallback for a legacy row that has none.
  v_zone := coalesce(a.zone_id, public.admin_active_zone());
  v_date := coalesce(a.business_date, public.admin_active_date());

  select coalesce(jsonb_agg(q.r order by q.ord), '[]'::jsonb) into v_rows
  from (
    select
      row_number() over (
        order by abs(coalesce(c.amount,0) - coalesce(a.parsed_amount,0)),
                 abs(extract(epoch from (coalesce(c.paid_ts, c.received_at, c.created_at) - a.posted_at)))
      ) as ord,
      jsonb_build_object(
        'claim_id',  c.id,
        'order_id',  c.order_id,
        'title_label', coalesce(nullif(btrim(pp.pharmacy_name),''),
                                nullif(btrim(c.payee_name),''),
                                nullif(btrim(c.sender_phone),''),
                                public.uic('pay_alert.link.unknown_payer','Payer not named')),
        'order_label', coalesce(nullif(btrim(o.order_code),''),
                                'PO-'||upper(right(replace(c.order_id::text,'-',''),4))),
        'amount_label', public.inr_money(coalesce(c.amount,0)),
        'time_label',   to_char(coalesce(c.paid_ts, c.received_at, c.created_at)
                                  at time zone 'Asia/Kolkata','DD Mon, hh12:mi am'),
        'utr_label',    coalesce(nullif(c.utr,''), nullif(c.txn_id,''),
                                 public.uic('pay_alert.link.no_utr','No reference on this payment')),
        -- How far this claim is from the alert, in words. Dart never subtracts.
        'delta_label',  case
           when a.parsed_amount is null then public.uic('pay_alert.link.no_amount','Alert carried no amount')
           when round(coalesce(c.amount,0),2) = round(a.parsed_amount,2)
             then public.uic('pay_alert.link.exact','Exactly this amount')
           when coalesce(c.amount,0) > a.parsed_amount
             then replace(public.uic('pay_alert.link.more','{d} more than the alert'),
                          '{d}', public.inr_money(round(coalesce(c.amount,0) - a.parsed_amount, 2)))
           else replace(public.uic('pay_alert.link.less','{d} less than the alert'),
                        '{d}', public.inr_money(round(a.parsed_amount - coalesce(c.amount,0), 2)))
         end,
        'delta_tone',   case
           when a.parsed_amount is not null
            and round(coalesce(c.amount,0),2) = round(a.parsed_amount,2) then 'success'
           else 'warning' end,
        'pick_label',   public.uic('pay_alert.link.pick','Link this payment')
      ) as r
    from public._pa_open_claims() c
    left join public.orders o on o.id = c.order_id
    left join public.pharmacy_profiles pp on pp.id = public._pa_customer_of_order(c.order_id)
    where (v_zone is null or coalesce(c.zone_id, v_zone) = v_zone)
      and (v_date is null or coalesce(c.business_date, v_date) = v_date)
    order by abs(coalesce(c.amount,0) - coalesce(a.parsed_amount,0)),
             abs(extract(epoch from (coalesce(c.paid_ts, c.received_at, c.created_at) - a.posted_at)))
    limit v_lim
  ) q;

  return jsonb_build_object(
    'ok', true,
    'alert_id',    a.id,
    'title',       public.uic('pay_alert.link.title','Link this payment'),
    'subtitle',    replace(public.uic('pay_alert.link.subtitle',
                     'Pick the order this {amt} belongs to. The payment is verified the same way a manual verify is.'),
                     '{amt}', case when a.parsed_amount is null
                                   then public.uic('pay_alert.no_amount','No amount read')
                                   else public.inr_money(a.parsed_amount) end),
    'empty_label', public.uic('pay_alert.link.empty','Nothing is waiting to be paid here.'),
    'empty_hint',  public.uic('pay_alert.link.empty_hint',
                     'Only unverified payments for this zone and date can be linked.'),
    'cancel_label',public.uic('pay_alert.link.cancel','Close'),
    'rows',        v_rows);
end $fn$;

-- ── 2. LINK TO CLAIM — the action ────────────────────────────────────────────
-- Runs the SAME verify core the automatic match and the manual verify screen
-- run, so a hand-linked payment lands in exactly the state an auto-matched one
-- does: claim verified, order accepted, customer notified, sender learned,
-- partner phone told.
create or replace function public.payment_alert_link(
  p_alert_id uuid, p_claim_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
declare
  a public.payment_alerts%rowtype;
  c public.payment_claims%rowtype;
  v_verify jsonb;
begin
  if coalesce(public.get_my_role(),'') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_alert.link_denied',
                            'Only an admin can link a payment to an order.'));
  end if;

  select * into a from public.payment_alerts where id = p_alert_id for update;
  if a.id is null then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public.uic('pay_alert.not_found','That payment alert is gone.'));
  end if;
  if a.status = 'matched' then
    return jsonb_build_object('ok', false, 'error','already_matched',
      'message', public.uic('pay_alert.link.already',
                            'This alert is already on an order.'));
  end if;

  select * into c from public.payment_claims where id = p_claim_id;
  if c.id is null or c.order_id is null then
    return jsonb_build_object('ok', false, 'error','claim_not_found',
      'message', public.uic('pay_alert.link.claim_gone',
                            'That payment is no longer waiting.'));
  end if;

  v_verify := public._payment_claim_verify_core(c.id, c.order_id, 'manual_payment_alert');
  if not coalesce((v_verify->>'ok')::boolean, false) then
    return jsonb_build_object('ok', false, 'error','verify_failed',
      'message', public.uic('pay_alert.link.verify_failed',
                            'The payment could not be verified. Try again.'));
  end if;

  update public.payment_alerts
     set status = 'matched',
         matched_claim_id = c.id,
         matched_order_id = c.order_id,
         matched_customer_id = public._pa_customer_of_order(c.order_id),
         match_reason = public.uic('pay_alert.match.manual','Linked by an admin'),
         updated_at = now()
   where id = a.id;

  perform public._pa_learn_sender(a.id, c.id);
  perform public._pa_speak(a.id);

  return public.payment_alert_state(a.id)
         || jsonb_build_object('toast', public.uic('pay_alert.link.done',
                                                   'Payment linked and verified.'));
end $fn$;

-- ── 3. THE BADGE — it must never promise work the screen hides ───────────────
-- #1929 registered the nav row and its badge in feature_registry
-- (badge_source 'payment_alerts_unmatched' -> _pa_badge_count), so the entry
-- point is already data. But that count filtered the ZONE only, while
-- payment_alerts_screen() filters zone AND the header's date: on any day but
-- today the badge offered work the screen then refused to show. One source of
-- truth, scoped the same way the screen is.
create or replace function public._pa_badge_count()
returns bigint language sql stable security definer set search_path to 'public' as $fn$
  select count(*)
    from public.payment_alerts a
   where a.status = 'unmatched'
     and (public.admin_active_zone() is null or a.zone_id = public.admin_active_zone())
     and (public.admin_active_date() is null or a.business_date = public.admin_active_date());
$fn$;

-- ── 4. RULE EDITOR — the list ────────────────────────────────────────────────
-- Super admin only: a regex is a loaded gun, and a wrong one silently stops
-- every payment of one app from being read.
create or replace function public.payment_alert_rules_screen()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $fn$
declare v_rows jsonb;
begin
  if coalesce(public.get_my_role(),'') <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_rule.denied',
                            'Only a super admin can edit the payment parser.'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id',            r.id,
      'label',         coalesce(nullif(btrim(r.label),''), r.package_name),
      'package_name',  r.package_name,
      'package_label', case when r.package_name = '*'
                            then public.uic('pay_rule.any_app','Every payment app')
                            else r.package_name end,
      'amount_regex',  coalesce(r.amount_regex,''),
      'utr_regex',     coalesce(r.utr_regex,''),
      'vpa_regex',     coalesce(r.vpa_regex,''),
      'sender_regex',  coalesce(r.sender_regex,''),
      'ignore_regex',  coalesce(r.ignore_regex,''),
      'priority',      r.priority,
      'enabled',       r.enabled,
      'note',          coalesce(r.note,''),
      'status_label',  case when r.enabled then public.uic('pay_rule.on','On')
                                           else public.uic('pay_rule.off','Off') end,
      'status_tone',   case when r.enabled then 'success' else 'muted' end,
      'toggle_label',  case when r.enabled then public.uic('pay_rule.disable','Turn off')
                                           else public.uic('pay_rule.enable','Turn on') end,
      'edit_label',    public.uic('pay_rule.edit','Edit'),
      'test_label',    public.uic('pay_rule.test','Test'),
      'order_label',   replace(public.uic('pay_rule.order_tpl','Tried #{n}'),
                               '{n}', r.priority::text))
    order by (r.package_name = '*')::int, r.priority, r.id), '[]'::jsonb)
  into v_rows from public.payment_alert_rules r;

  return jsonb_build_object(
    'ok', true,
    'title',        public.uic('pay_rule.title','Payment parser rules'),
    'subtitle',     public.uic('pay_rule.subtitle',
                      'One rule per payment app. Adding an app here never needs a new build.'),
    'empty_label',  public.uic('pay_rule.empty','No parser rules yet.'),
    'empty_hint',   public.uic('pay_rule.empty_hint',
                      'Add one rule per payment app whose notifications should be read.'),
    'add_label',    public.uic('pay_rule.add','Add a payment app'),
    'save_label',   public.uic('pay_rule.save','Save rule'),
    'cancel_label', public.uic('pay_rule.cancel','Cancel'),
    'test_title',   public.uic('pay_rule.test_title','Test this rule'),
    'test_hint',    public.uic('pay_rule.test_hint',
                      'Paste a real notification here and the rule reads it in front of you.'),
    'test_run_label', public.uic('pay_rule.test_run','Run the test'),
    'fields', jsonb_build_array(
      jsonb_build_object('key','label','label', public.uic('pay_rule.f_label','Name'),
        'hint', public.uic('pay_rule.f_label_hint','Google Pay'), 'required', true, 'lines', 1),
      jsonb_build_object('key','package_name','label', public.uic('pay_rule.f_package','App package'),
        'hint', public.uic('pay_rule.f_package_hint','com.google.android.apps.nbu.paisa.user'),
        'required', true, 'lines', 1),
      jsonb_build_object('key','amount_regex','label', public.uic('pay_rule.f_amount','Amount pattern'),
        'hint', public.uic('pay_rule.f_amount_hint','Rs\.?\s*([0-9,]+(?:\.[0-9]{2})?)'),
        'required', true, 'lines', 2),
      jsonb_build_object('key','utr_regex','label', public.uic('pay_rule.f_utr','Reference (UTR) pattern'),
        'hint', public.uic('pay_rule.f_utr_hint','UPI[/ ]?([0-9]{6,})'), 'required', false, 'lines', 2),
      jsonb_build_object('key','vpa_regex','label', public.uic('pay_rule.f_vpa','UPI id pattern'),
        'hint', public.uic('pay_rule.f_vpa_hint','([a-z0-9._-]+@[a-z]+)'), 'required', false, 'lines', 2),
      jsonb_build_object('key','sender_regex','label', public.uic('pay_rule.f_sender','Sender pattern'),
        'hint', public.uic('pay_rule.f_sender_hint','from ([A-Za-z ]+)'), 'required', false, 'lines', 2),
      jsonb_build_object('key','ignore_regex','label', public.uic('pay_rule.f_ignore','Skip when it matches'),
        'hint', public.uic('pay_rule.f_ignore_hint','requesting|debited'), 'required', false, 'lines', 2),
      jsonb_build_object('key','note','label', public.uic('pay_rule.f_note','Note'),
        'hint', public.uic('pay_rule.f_note_hint','What this rule is for'), 'required', false, 'lines', 2)),
    'rows', v_rows);
end $fn$;

-- ── 5. RULE EDITOR — save / add / disable ────────────────────────────────────
create or replace function public.payment_alert_rule_save(p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
declare
  v_id bigint := nullif(p_patch->>'id','')::bigint;
  v_pkg text := btrim(coalesce(p_patch->>'package_name',''));
  v_lab text := btrim(coalesce(p_patch->>'label',''));
  v_amt text := btrim(coalesce(p_patch->>'amount_regex',''));
  k text; v text;
begin
  if coalesce(public.get_my_role(),'') <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_rule.denied',
                            'Only a super admin can edit the payment parser.'));
  end if;

  -- A disable/enable is the whole patch: nothing else has to be sent back.
  if v_id is not null and p_patch ? 'enabled' and not (p_patch ? 'package_name') then
    update public.payment_alert_rules
       set enabled = (p_patch->>'enabled')::boolean, updated_at = now()
     where id = v_id;
    return public.payment_alert_rules_screen()
           || jsonb_build_object('toast', public.uic('pay_rule.saved','Rule saved.'));
  end if;

  if v_pkg = '' or v_lab = '' or v_amt = '' then
    return jsonb_build_object('ok', false, 'error','incomplete',
      'message', public.uic('pay_rule.incomplete',
                            'A rule needs a name, an app package and an amount pattern.'));
  end if;

  -- Every pattern is compiled here before it can ever run against a real
  -- notification: a broken regex in this table reads as "this app stopped
  -- working" hours later, with nothing on screen to say why.
  foreach k in array array['amount_regex','utr_regex','vpa_regex','sender_regex','ignore_regex'] loop
    v := btrim(coalesce(p_patch->>k,''));
    if v <> '' then
      begin
        perform 'probe' ~* v;
      exception when others then
        return jsonb_build_object('ok', false, 'error','bad_regex', 'field', k,
          'message', replace(public.uic('pay_rule.bad_regex','{f} is not a valid pattern.'),
                             '{f}', k));
      end;
    end if;
  end loop;

  if v_id is null then
    insert into public.payment_alert_rules
      (package_name, label, amount_regex, utr_regex, vpa_regex, sender_regex,
       ignore_regex, priority, enabled, note, updated_at)
    values (v_pkg, v_lab, v_amt,
            nullif(btrim(coalesce(p_patch->>'utr_regex','')),''),
            nullif(btrim(coalesce(p_patch->>'vpa_regex','')),''),
            nullif(btrim(coalesce(p_patch->>'sender_regex','')),''),
            nullif(btrim(coalesce(p_patch->>'ignore_regex','')),''),
            coalesce(nullif(p_patch->>'priority','')::int, 100),
            coalesce((p_patch->>'enabled')::boolean, true),
            nullif(btrim(coalesce(p_patch->>'note','')),''), now())
    returning id into v_id;
  else
    update public.payment_alert_rules
       set package_name = v_pkg, label = v_lab, amount_regex = v_amt,
           utr_regex    = nullif(btrim(coalesce(p_patch->>'utr_regex','')),''),
           vpa_regex    = nullif(btrim(coalesce(p_patch->>'vpa_regex','')),''),
           sender_regex = nullif(btrim(coalesce(p_patch->>'sender_regex','')),''),
           ignore_regex = nullif(btrim(coalesce(p_patch->>'ignore_regex','')),''),
           priority     = coalesce(nullif(p_patch->>'priority','')::int, priority),
           enabled      = coalesce((p_patch->>'enabled')::boolean, enabled),
           note         = nullif(btrim(coalesce(p_patch->>'note','')),''),
           updated_at   = now()
     where id = v_id;
  end if;

  return public.payment_alert_rules_screen()
         || jsonb_build_object('toast', public.uic('pay_rule.saved','Rule saved.'),
                               'saved_id', v_id);
end $fn$;

-- ── 6. RULE EDITOR — the test box ────────────────────────────────────────────
-- Runs the patch's OWN patterns (saved or not) against pasted notification
-- text, so a rule is proven before it is turned on.
create or replace function public.payment_alert_rule_test(
  p_patch jsonb, p_title text default '', p_text text default '')
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $fn$
declare
  v_blob text; v_amt numeric; v_utr text; v_vpa text; v_sender text;
  v_ignore text; v_ok boolean; v_reason text;
begin
  if coalesce(public.get_my_role(),'') <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_rule.denied',
                            'Only a super admin can edit the payment parser.'));
  end if;

  v_blob := btrim(coalesce(p_title,'') || E'\n' || coalesce(p_text,''));
  if v_blob = '' then
    return jsonb_build_object('ok', false, 'error','empty',
      'message', public.uic('pay_rule.test_empty',
                            'Paste a notification first.'));
  end if;

  v_ignore := nullif(btrim(coalesce(p_patch->>'ignore_regex','')),'');
  if v_ignore is not null then
    begin
      if v_blob ~* v_ignore then
        return jsonb_build_object('ok', true, 'matched', false,
          'verdict_label', public.uic('pay_rule.test_ignored',
                             'Skipped — this is not money arriving.'),
          'verdict_tone','warning',
          'rows', '[]'::jsonb);
      end if;
    exception when others then null;
    end;
  end if;

  v_amt    := public._pa_amount(public._pa_cap(v_blob, p_patch->>'amount_regex'));
  v_utr    := public._pa_cap(v_blob, p_patch->>'utr_regex');
  v_vpa    := public._pa_cap(v_blob, p_patch->>'vpa_regex');
  v_sender := public._pa_cap(v_blob, p_patch->>'sender_regex');
  v_ok     := v_amt is not null;
  v_reason := case when v_ok then public.uic('pay_rule.test_ok','This rule reads the notification.')
                   else public.uic('pay_rule.test_no_amount',
                          'No amount was read — the alert would go to the queue unread.') end;

  return jsonb_build_object(
    'ok', true,
    'matched', v_ok,
    'verdict_label', v_reason,
    'verdict_tone',  case when v_ok then 'success' else 'danger' end,
    'rows', jsonb_build_array(
      jsonb_build_object('label', public.uic('pay_rule.t_amount','Amount'),
        'value', case when v_amt is null then public.uic('pay_rule.t_none','Not found')
                      else public.inr_money(v_amt) end,
        'tone',  case when v_amt is null then 'danger' else 'success' end),
      jsonb_build_object('label', public.uic('pay_rule.t_utr','Reference (UTR)'),
        'value', coalesce(v_utr, public.uic('pay_rule.t_none','Not found')),
        'tone',  case when v_utr is null then 'muted' else 'success' end),
      jsonb_build_object('label', public.uic('pay_rule.t_vpa','UPI id'),
        'value', coalesce(v_vpa, public.uic('pay_rule.t_none','Not found')),
        'tone',  case when v_vpa is null then 'muted' else 'success' end),
      jsonb_build_object('label', public.uic('pay_rule.t_sender','Sender'),
        'value', coalesce(v_sender, public.uic('pay_rule.t_none','Not found')),
        'tone',  case when v_sender is null then 'muted' else 'success' end)));
end $fn$;

grant execute on function public.payment_alert_link_options(uuid, integer) to authenticated;
grant execute on function public.payment_alert_link(uuid, uuid)            to authenticated;
grant execute on function public.payment_alert_rules_screen()              to authenticated;
grant execute on function public.payment_alert_rule_save(jsonb)            to authenticated;
grant execute on function public.payment_alert_rule_test(jsonb, text, text) to authenticated;

-- The parser's own field hints are EXAMPLES of a package name and of a regex,
-- shown greyed inside the input. They look like source because that is exactly
-- what a super admin has to type there — the guard is told so once, here.
insert into public.ui_copy_source_exempt (key, reason) values
  ('pay_rule.f_package_hint', 'Parser rule editor — example Android package name shown as an input hint'),
  ('pay_rule.f_amount_hint',  'Parser rule editor — example regex shown as an input hint'),
  ('pay_rule.f_utr_hint',     'Parser rule editor — example regex shown as an input hint'),
  ('pay_rule.f_vpa_hint',     'Parser rule editor — example regex shown as an input hint'),
  ('pay_rule.f_sender_hint',  'Parser rule editor — example regex shown as an input hint'),
  ('pay_rule.f_ignore_hint',  'Parser rule editor — example regex shown as an input hint')
on conflict (key) do nothing;

-- ── 7. The copy. Every string above is an UPDATE away from being reworded. ───
insert into public.ui_copy (key, value) values
  ('pay_alert.nav_label',        to_jsonb('Payment alerts'::text)),
  ('pay_alert.link_denied',      to_jsonb('Only an admin can link a payment to an order.'::text)),
  ('pay_alert.link.title',       to_jsonb('Link this payment'::text)),
  ('pay_alert.link.subtitle',    to_jsonb('Pick the order this {amt} belongs to. The payment is verified the same way a manual verify is.'::text)),
  ('pay_alert.link.empty',       to_jsonb('Nothing is waiting to be paid here.'::text)),
  ('pay_alert.link.empty_hint',  to_jsonb('Only unverified payments for this zone and date can be linked.'::text)),
  ('pay_alert.link.cancel',      to_jsonb('Close'::text)),
  ('pay_alert.link.pick',        to_jsonb('Link this payment'::text)),
  ('pay_alert.link.exact',       to_jsonb('Exactly this amount'::text)),
  ('pay_alert.link.more',        to_jsonb('{d} more than the alert'::text)),
  ('pay_alert.link.less',        to_jsonb('{d} less than the alert'::text)),
  ('pay_alert.link.no_utr',      to_jsonb('No reference on this payment'::text)),
  ('pay_alert.link.no_amount',   to_jsonb('Alert carried no amount'::text)),
  ('pay_alert.link.unknown_payer', to_jsonb('Payer not named'::text)),
  ('pay_alert.link.already',     to_jsonb('This alert is already on an order.'::text)),
  ('pay_alert.link.claim_gone',  to_jsonb('That payment is no longer waiting.'::text)),
  ('pay_alert.link.verify_failed', to_jsonb('The payment could not be verified. Try again.'::text)),
  ('pay_alert.link.done',        to_jsonb('Payment linked and verified.'::text)),
  ('pay_alert.link_label',       to_jsonb('Link to an order'::text)),
  ('pay_alert.match.manual',     to_jsonb('Linked by an admin'::text)),
  ('pay_alert.rules_label',      to_jsonb('Parser rules'::text)),
  ('pay_rule.denied',            to_jsonb('Only a super admin can edit the payment parser.'::text)),
  ('pay_rule.title',             to_jsonb('Payment parser rules'::text)),
  ('pay_rule.subtitle',          to_jsonb('One rule per payment app. Adding an app here never needs a new build.'::text)),
  ('pay_rule.empty',             to_jsonb('No parser rules yet.'::text)),
  ('pay_rule.empty_hint',        to_jsonb('Add one rule per payment app whose notifications should be read.'::text)),
  ('pay_rule.add',               to_jsonb('Add a payment app'::text)),
  ('pay_rule.save',              to_jsonb('Save rule'::text)),
  ('pay_rule.cancel',            to_jsonb('Cancel'::text)),
  ('pay_rule.saved',             to_jsonb('Rule saved.'::text)),
  ('pay_rule.on',                to_jsonb('On'::text)),
  ('pay_rule.off',               to_jsonb('Off'::text)),
  ('pay_rule.enable',            to_jsonb('Turn on'::text)),
  ('pay_rule.disable',           to_jsonb('Turn off'::text)),
  ('pay_rule.edit',              to_jsonb('Edit'::text)),
  ('pay_rule.test',              to_jsonb('Test'::text)),
  ('pay_rule.any_app',           to_jsonb('Every payment app'::text)),
  ('pay_rule.order_tpl',         to_jsonb('Tried #{n}'::text)),
  ('pay_rule.incomplete',        to_jsonb('A rule needs a name, an app package and an amount pattern.'::text)),
  ('pay_rule.bad_regex',         to_jsonb('{f} is not a valid pattern.'::text)),
  ('pay_rule.test_title',        to_jsonb('Test this rule'::text)),
  ('pay_rule.test_hint',         to_jsonb('Paste a real notification here and the rule reads it in front of you.'::text)),
  ('pay_rule.test_run',          to_jsonb('Run the test'::text)),
  ('pay_rule.test_empty',        to_jsonb('Paste a notification first.'::text)),
  ('pay_rule.test_ok',           to_jsonb('This rule reads the notification.'::text)),
  ('pay_rule.test_no_amount',    to_jsonb('No amount was read — the alert would go to the queue unread.'::text)),
  ('pay_rule.test_ignored',      to_jsonb('Skipped — this is not money arriving.'::text)),
  ('pay_rule.t_amount',          to_jsonb('Amount'::text)),
  ('pay_rule.t_utr',             to_jsonb('Reference (UTR)'::text)),
  ('pay_rule.t_vpa',             to_jsonb('UPI id'::text)),
  ('pay_rule.t_sender',          to_jsonb('Sender'::text)),
  ('pay_rule.t_none',            to_jsonb('Not found'::text)),
  ('pay_rule.f_label',           to_jsonb('Name'::text)),
  ('pay_rule.f_label_hint',      to_jsonb('Google Pay'::text)),
  ('pay_rule.f_package',         to_jsonb('App package'::text)),
  ('pay_rule.f_package_hint',    to_jsonb('com.google.android.apps.nbu.paisa.user'::text)),
  ('pay_rule.f_amount',          to_jsonb('Amount pattern'::text)),
  ('pay_rule.f_utr',             to_jsonb('Reference (UTR) pattern'::text)),
  ('pay_rule.f_vpa',             to_jsonb('UPI id pattern'::text)),
  ('pay_rule.f_sender',          to_jsonb('Sender pattern'::text)),
  ('pay_rule.f_ignore',          to_jsonb('Skip when it matches'::text)),
  ('pay_rule.f_ignore_hint',     to_jsonb('requesting|debited'::text)),
  ('pay_rule.f_note',            to_jsonb('Note'::text)),
  ('pay_rule.f_note_hint',       to_jsonb('What this rule is for'::text)),
  ('pay_rule.f_amount_hint',     to_jsonb('Rs\.?\s*([0-9,]+(?:\.[0-9]{2})?)'::text)),
  ('pay_rule.f_utr_hint',        to_jsonb('UPI[/ ]?([0-9]{6,})'::text)),
  ('pay_rule.f_vpa_hint',        to_jsonb('([a-z0-9._-]+@[a-z]+)'::text)),
  ('pay_rule.f_sender_hint',     to_jsonb('from ([A-Za-z ]+)'::text))
on conflict (key) do nothing;

-- ── 8. THE MONEY TAB'S OWN ENTRY ─────────────────────────────────────────────
-- #1929 registered the nav row in feature_registry under category 'home_money',
-- and the home guard rehomed it to the More grid because no nav_category row
-- called 'home_money' claims the Money tab. Two fixes, both data:
--   a. give the Money tab its category, but never overwrite one that is
--      already pointed somewhere on purpose;
--   b. put the row back where #1929 asked for it.
-- icon_key is a foreign key into ui_icon and that table differs per
-- environment, so the icon is whatever is already installed — the category
-- exists for its home_tab, not for its picture.
insert into public.nav_category (category_key, label, icon_key, sort_order, is_active, home_tab)
select 'home_money', 'Money',
       coalesce((select i.icon_key from public.ui_icon i
                  where i.icon_key in ('rupee','currency_rupee','payments') limit 1),
                (select i.icon_key from public.ui_icon i order by i.icon_key limit 1)),
       30, true, 'money'
 where exists (select 1 from public.ui_icon)
on conflict (category_key) do update
  set home_tab  = coalesce(public.nav_category.home_tab, 'money'),
      is_active = true;

update public.feature_registry
   set category = 'home_money'
 where feature_key = 'admin.payment_alerts'
   and category <> 'home_money';

-- The Money SCREEN itself now carries the entry, so the queue is one tap from
-- where an admin already counts money — and the badge beside it is the same
-- number the nav tile shows, because both read _pa_badge_count().
create or replace function public.admin_money_home()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $fn$
declare v_claims int; v_unmatched int; v_bills int; v_recv numeric; v_alerts int;
begin
  if not is_admin() then raise exception 'not_authorized'; end if;

  select count(*)::int into v_claims from payment_claims where status='received';
  select count(*)::int into v_unmatched from payment_claims
   where order_id is null and coalesce(status,'') not in ('rejected','cancelled');
  select count(*)::int into v_bills from pending_bills where coalesce(status,'pending')='pending';
  select coalesce(sum(round(coalesce(o.total_amount,0) - coalesce(paid.amt,0),2)),0)
    into v_recv
    from orders o
    left join lateral (select sum(p.amount) amt from payment_claims p
                        where p.order_id=o.id and p.status='verified') paid on true
   where coalesce(o.status,'pending') in ('pending','accepted')
     and coalesce(o.fulfillment_status,'open') <> 'cancelled'
     and round(coalesce(o.total_amount,0) - coalesce(paid.amt,0),2) > 0;

  v_alerts := public._pa_badge_count()::int;

  return jsonb_build_object(
    'ok', true,
    'title', 'Money',
    'subtitle', 'What is owed, what arrived, and what is still waiting on somebody.',
    -- Rows that leave this screen for another one. Rendered above the tabs,
    -- in payload order; an unknown route_key is skipped, never a crash.
    'links', jsonb_build_array(
      jsonb_build_object(
        'route_key',  'payment_alerts',
        'icon_key',   'phonelink_ring',
        'label',      public.uic('pay_alert.nav_label','Payment alerts'),
        'sub_label',  public.uic('pay_alert.subtitle',
                        'Payment notifications forwarded from the partner phone'),
        'badge',      case when v_alerts > 0 then v_alerts::text else '' end,
        'badge_tone', case when v_alerts > 0 then 'warn' else 'good' end,
        'badge_label',case when v_alerts = 0 then ''
                          when v_alerts = 1 then public.uic('pay_alert.badge_one','1 payment needs a look')
                          else replace(public.uic('pay_alert.badge_tpl','{n} payments need a look'),
                                       '{n}', v_alerts::text) end)),
    'tabs', jsonb_build_array(
      jsonb_build_object('tab_key','receivables', 'label','Owed to us',
        'badge', case when v_recv > 0 then public.inr_money_compact(v_recv) else '' end,
        'badge_tone', case when v_recv > 0 then 'bad' else 'good' end),
      jsonb_build_object('tab_key','claims', 'label','To verify',
        'badge', case when v_claims > 0 then v_claims::text else '' end,
        'badge_tone', case when v_claims > 0 then 'warn' else 'good' end),
      jsonb_build_object('tab_key','unmatched', 'label','Unattached money',
        'badge', case when v_unmatched > 0 then v_unmatched::text else '' end,
        'badge_tone', case when v_unmatched > 0 then 'bad' else 'good' end),
      jsonb_build_object('tab_key','bills', 'label','Supplier bills',
        'badge', case when v_bills > 0 then v_bills::text else '' end,
        'badge_tone', case when v_bills > 0 then 'warn' else 'good' end)
    ),
    'unknown_tab_label', '');
end $fn$;

insert into public.ui_copy (key, value) values
  ('pay_alert.badge_one', to_jsonb('1 payment needs a look'::text)),
  ('pay_alert.badge_tpl', to_jsonb('{n} payments need a look'::text))
on conflict (key) do nothing;


-- ── 9. THE ROW SHAPE GAINS ITS THIRD BUTTON ─────────────────────────────────
-- Every other label on the card already arrives from payment_alert_state();
-- the link button must not be the one string Dart is trusted to know.
CREATE OR REPLACE FUNCTION public.payment_alert_state(p_alert_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  a public.payment_alerts%rowtype; v_rule text; v_cust text; v_code text;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public.uic('pay_alert.not_found','That payment alert is gone.'));
  end if;

  select coalesce(label, package_name) into v_rule
    from public.payment_alert_rules where id = a.parse_rule_id;
  select coalesce(nullif(btrim(pp.pharmacy_name),''), '') into v_cust
    from public.pharmacy_profiles pp where pp.id = a.matched_customer_id;
  select coalesce(nullif(btrim(o.order_code),''),
                  'PO-'||upper(right(replace(o.id::text,'-',''),4)))
    into v_code from public.orders o where o.id = a.matched_order_id;

  return jsonb_build_object(
    'ok', true,
    'alert_id',      a.id,
    'status',        a.status,
    'status_label',  public.uic('pay_alert.status.'||a.status, initcap(a.status)),
    'status_tone',   case a.status when 'matched' then 'success'
                                   when 'unmatched' then 'warning'
                                   when 'ignored' then 'muted'
                                   else 'info' end,
    'source',        a.parse_source,
    'source_label',  public.uic('pay_alert.source.'||a.parse_source, a.parse_source),
    'rule_label',    coalesce(v_rule, ''),
    'app_label',     coalesce(v_rule, a.package_name),
    'amount',        a.parsed_amount,
    'amount_label',  case when a.parsed_amount is null
                          then public.uic('pay_alert.no_amount','No amount read')
                          else public.inr_money(a.parsed_amount) end,
    'utr_label',     coalesce(nullif(a.parsed_utr,''),
                              public.uic('pay_alert.no_utr','No UTR in the notification')),
    'has_utr',       nullif(a.parsed_utr,'') is not null,
    'sender_label',  coalesce(nullif(a.parsed_sender,''), nullif(a.parsed_vpa,''),
                              public.uic('pay_alert.no_sender','Sender not named')),
    'vpa',           coalesce(a.parsed_vpa,''),
    'raw_title',     coalesce(a.raw_title,''),
    'raw_text',      coalesce(a.raw_text,''),
    'posted_label',  to_char(a.posted_at at time zone 'Asia/Kolkata','DD Mon, hh12:mi am'),
    'match_reason',  coalesce(a.match_reason, a.parse_note, ''),
    -- Both buttons on the card. Absent on a matched row, because a verified
    -- payment is not re-matched or ignored from this screen.
    'retry_match_label', case when a.status = 'matched' then ''
                              else public.uic('pay_alert.retry_match','Match again') end,
    'ignore_label',      case when a.status = 'matched' then ''
                              else public.uic('pay_alert.ignore','Ignore') end,
    -- CMD #1930 — the third button. Present for exactly as long as the other
    -- two are: a verified payment is not re-linked from this screen.
    'link_label',        case when a.status = 'matched' then ''
                              else public.uic('pay_alert.link_label','Link to an order') end,
    'claim_id',      a.matched_claim_id,
    'order_id',      a.matched_order_id,
    'order_code',    coalesce(v_code,''),
    'customer_id',   a.matched_customer_id,
    'customer_label',coalesce(nullif(v_cust,''), ''),
    'zone_id',       a.zone_id,
    'business_date', a.business_date);
end $function$;

-- replay-target: production
-- CMD #1886 (2/2) — THE SURFACES. Every word, tone, count and refusal a
-- registration screen prints is built here. Flutter renders and decides
-- nothing: the chip word, the "3 fields missing: Drug licence, GSTIN" sentence,
-- the WhatsApp button's own label and the approve refusal all arrive as text.
--
-- Zone and date: every list below reads admin_active_zone() and
-- admin_active_date(). A partner/zone admin sees their zone; a super admin with
-- no zone picked sees all. A person who has SIGNED UP has no profile and so no
-- zone of their own — their row carries the zone of whoever took them on
-- (customer_signup_followup.zone_id), and an unclaimed row is visible in every
-- zone, because a lead nobody owns must not be invisible to the one office that
-- would have called them.

begin;

-- ── copy ───────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('cust_pipeline.title',            '"Registration pipeline"'::jsonb),
  ('cust_pipeline.tab_signed_up',    '"Signed up"'::jsonb),
  ('cust_pipeline.tab_followups',    '"My follow-ups"'::jsonb),
  ('cust_pipeline.tab_needs',        '"Needs attention"'::jsonb),
  ('cust_pipeline.empty_signed_up',  '"Nobody has signed in without finishing the form."'::jsonb),
  ('cust_pipeline.empty_followups',  '"Nothing assigned to you. Pick a row and set a follow-up date."'::jsonb),
  ('cust_pipeline.empty_needs',      '"Every registration has the fields it needs."'::jsonb),
  ('cust_pipeline.wa_button',        '"Send WhatsApp"'::jsonb),
  ('cust_pipeline.wa_no_phone',      '"No phone on this login"'::jsonb),
  ('cust_pipeline.wa_sent',          '"WhatsApp sent."'::jsonb),
  ('cust_pipeline.assign_button',    '"Assign"'::jsonb),
  ('cust_pipeline.assign_saved',     '"Follow-up saved."'::jsonb),
  ('cust_pipeline.unassigned',       '"Unassigned"'::jsonb),
  ('cust_pipeline.no_next_action',   '"No date set"'::jsonb),
  ('cust_pipeline.overdue_prefix',   '"Overdue — "'::jsonb),
  ('cust_pipeline.never_signed_in',  '"Never"'::jsonb),
  ('cust_pipeline.approve_ok',       '"Approve"'::jsonb),
  ('cust_pipeline.approve_fix',      '"Fix"'::jsonb),
  ('cust_pipeline.missing_none',     '"Nothing missing"'::jsonb),
  ('cust_pipeline.not_authorized',   '"This screen is for the office team."'::jsonb),
  ('cust_pipeline.col_person',       '"Person"'::jsonb),
  ('cust_pipeline.col_joined',       '"Joined"'::jsonb),
  ('cust_pipeline.col_last_login',   '"Last login"'::jsonb),
  ('cust_pipeline.col_contact',      '"Contact"'::jsonb),
  ('cust_pipeline.col_owner',        '"Owner"'::jsonb),
  ('cust_pipeline.col_next',         '"Next action"'::jsonb),
  ('cust_pipeline.col_stage',        '"Stage"'::jsonb),
  ('cust_pipeline.col_missing',      '"Missing"'::jsonb),
  ('cust_pipeline.col_action',       '"Action"'::jsonb),
  ('cust_pipeline.no_name',          '"(no name given)"'::jsonb),
  ('cust_stage.signed_up',           '"Signed up"'::jsonb),
  ('cust_stage.details',             '"Details"'::jsonb),
  ('cust_stage.documents',           '"Documents"'::jsonb),
  ('cust_stage.verified',            '"Verified"'::jsonb),
  ('cust_stage.approved',            '"Approved"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── the chip: one stage, one word, one tone ────────────────────────────────
create or replace function public.customer_stage_chip(p_stage public.registration_stage)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'stage_key', coalesce(p_stage::text, 'signed_up'),
    'label', public.uic('cust_stage.'||coalesce(p_stage::text,'signed_up'),
                        initcap(replace(coalesce(p_stage::text,'signed_up'),'_',' '))),
    'tone', case coalesce(p_stage::text,'signed_up')
              when 'approved'  then 'success'
              when 'verified'  then 'info'
              when 'documents' then 'brand'
              when 'details'   then 'warning'
              else 'neutral' end);
$$;

-- ── the approve gate, worded ───────────────────────────────────────────────
-- The button is NEVER hidden. It is either live, or it is disabled carrying the
-- sentence that says why and the field that would fix it.
create or replace function public.customer_approve_gate(p_customer_id uuid)
returns jsonb language plpgsql stable as $$
declare v_gate jsonb; v_missing jsonb; v_first jsonb; v_stage public.registration_stage;
begin
  select registration_stage into v_stage from public.pharmacy_profiles where id = p_customer_id;
  if v_stage = 'approved' then
    return jsonb_build_object('can', false, 'is_approved', true,
      'label', public.uic('cust_stage.approved','Approved'),
      'reason', '', 'has_fix', false);
  end if;

  v_missing := public.customer_missing_fields(p_customer_id);
  begin
    v_gate := public.kyc_gate('pharmacy', p_customer_id, 'approve');
  exception when others then v_gate := jsonb_build_object('blocked', false);
  end;

  if coalesce((v_gate->>'blocked')::boolean, false) then
    v_first := (select e from jsonb_array_elements(v_missing) e
                 where e->>'stage_key' = 'documents' limit 1);
    return jsonb_build_object(
      'can', false, 'is_approved', false,
      'label',  public.uic('cust_pipeline.approve_ok','Approve'),
      -- the gate's own sentence first; if the copy row is missing, the fields
      -- that are actually absent still say WHY, so this is never blank.
      'reason', coalesce(nullif(v_gate->>'message',''), nullif(v_gate->>'warn_message',''),
                         public.customer_missing_sentence(v_missing)),
      'has_fix', v_first is not null,
      'fix_label', public.uic('cust_pipeline.approve_fix','Fix'),
      'fix_field', coalesce(v_first->>'field_key',''),
      'fix_field_label', coalesce(v_first->>'label',''));
  end if;

  if jsonb_array_length(v_missing) > 0 then
    v_first := v_missing->0;
    return jsonb_build_object(
      'can', false, 'is_approved', false,
      'label',  public.uic('cust_pipeline.approve_ok','Approve'),
      'reason', public.customer_missing_sentence(v_missing),
      'has_fix', true,
      'fix_label', public.uic('cust_pipeline.approve_fix','Fix'),
      'fix_field', v_first->>'field_key',
      'fix_field_label', v_first->>'label');
  end if;

  return jsonb_build_object('can', true, 'is_approved', false,
    'label', public.uic('cust_pipeline.approve_ok','Approve'),
    'reason', '', 'has_fix', false);
end $$;

-- the missing-field sentence, pluralised HERE and never in Dart
create or replace function public.customer_missing_sentence(p_missing jsonb)
returns text language sql immutable as $$
  select case
    when coalesce(jsonb_array_length(p_missing),0) = 0
      then public.uic('cust_pipeline.missing_none','Nothing missing')
    when jsonb_array_length(p_missing) = 1
      then '1 field missing: ' || (p_missing->0->>'label')
    else jsonb_array_length(p_missing)::text || ' fields missing: ' ||
         (select string_agg(e->>'label', ', ') from jsonb_array_elements(p_missing) e)
  end;
$$;

commit;

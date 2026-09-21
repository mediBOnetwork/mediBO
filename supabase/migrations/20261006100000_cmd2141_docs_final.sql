-- CMD #2141 — Documents step, final rules (Om, 22 Sep 2026) + the QA round.
--  • Mandatory means mandatory: customer "Submit registration" stays off until
--    every Mandatory paper is in; custreg.v4_submit_gate is the one line
--    printed above it. The Documents footnote said the same thing a second
--    time under the list ("no helper text"), so it is emptied.
--  • custreg_contact_check (QA): staff got a green ✓ for a WhatsApp number
--    that already has an account (only the customer side was checked); the
--    field's kind now comes from custreg_wizard.checks instead of "anything
--    that is not exactly 'email' is a phone"; and 'abc@gmail..com' /
--    'a,b@c.com' are no longer valid emails.
-- Idempotent: a new wording is never overwritten by a replay; the function is
-- a create or replace.

insert into public.ui_copy(key, value) values
  ('custreg.v4_submit_gate', to_jsonb('Add the mandatory papers to submit'::text))
on conflict (key) do nothing;

update public.ui_copy set value = to_jsonb(''::text), updated_at = now()
 where key = 'custreg.lic_footnote' and value is distinct from to_jsonb(''::text);

create or replace function public.custreg_contact_check(p_field text, p_value text,
                                                        p_customer_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid   uuid := auth.uid();
  v_staff boolean := coalesce(public.is_admin(), false);
  v_kind  text;
  v_raw   text := btrim(coalesce(p_value, ''));
  v_n     text; v_own uuid; v_own_user uuid; v_taken boolean := false; v_dom text;
  v_cfg   jsonb := coalesce((select value from app_settings where key = 'custreg_wizard'), '{}'::jsonb);
  v_total int := coalesce((v_cfg->>'phone_digits')::int, 10);
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'state', 'not_signed_in', 'blocks', false);
  end if;
  -- The field's kind is the wizard's own map (whatsapp_no → phone, email →
  -- email); a field it does not name is not checked at all.
  v_kind := coalesce(v_cfg->'checks'->>coalesce(p_field, ''),
                     case p_field when 'email' then 'email'
                                  when 'whatsapp_no' then 'phone' end);
  if v_kind is null or v_kind not in ('phone', 'email') then
    return jsonb_build_object('ok', false, 'field', p_field, 'state', 'unknown_field', 'blocks', false);
  end if;
  if v_raw = '' then
    return jsonb_build_object('ok', true, 'field', p_field, 'state', 'empty', 'blocks', false,
                              'suffix', '', 'tone', 'neutral');
  end if;
  -- The row being filled in: a customer's own number is never "already
  -- registered", and neither is the number of the customer staff are resuming.
  if not v_staff then
    select id into v_own from public.pharmacy_profiles
     where user_id = v_uid and coalesce(is_deleted,false) = false
     order by created_at desc limit 1;
  else
    v_own := p_customer_id;
  end if;
  if v_own is not null then
    select user_id into v_own_user from public.pharmacy_profiles where id = v_own;
  end if;

  if v_kind = 'phone' then
    v_n := regexp_replace(v_raw, '\D', '', 'g');
    if length(v_n) > v_total and left(v_n, 2) = '91' then v_n := substr(v_n, 3); end if;
    if length(v_n) > v_total and left(v_n, 1) = '0' then v_n := substr(v_n, 2); end if;
    if length(v_n) < v_total then
      return jsonb_build_object('ok', true, 'field', p_field, 'state', 'typing', 'blocks', true,
        'suffix', public._cf('custreg.v4_counter', jsonb_build_object('n', length(v_n), 'total', v_total)),
        'tone', 'neutral');
    end if;
    if length(v_n) <> v_total or v_n !~ '^[6-9]' then
      return jsonb_build_object('ok', true, 'field', p_field, 'state', 'invalid', 'blocks', true,
        'suffix', public._c('custreg.v4_invalid'), 'tone', 'danger');
    end if;
    -- Staff too (QA): a number that already has an account is never "✓" —
    -- the Add customer line under the box still offers its own actions.
    v_dom := coalesce(public.login_signup_cfg()->>'internal_email_domain', 'wa.medibo.in');
    v_taken := exists (select 1 from public.pharmacy_profiles pp
                        where coalesce(pp.is_deleted,false) = false
                          and pp.id is distinct from v_own
                          and pp.user_id is distinct from v_uid
                          and public._phone10(coalesce(pp.whatsapp_no, pp.phone, '')) = v_n)
            or exists (select 1 from auth.users u
                        where u.id <> v_uid
                          and u.id is distinct from v_own_user
                          and (right(regexp_replace(coalesce(u.phone,''),'\D','','g'), 10) = v_n
                               or lower(coalesce(u.email,'')) = v_n || '@' || v_dom));
  else
    v_n := lower(v_raw);
    if v_n !~ '^[a-z0-9_%+-]+(\.[a-z0-9_%+-]+)*@([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' then
      return jsonb_build_object('ok', true, 'field', p_field, 'state', 'invalid', 'blocks', true,
        'suffix', public._c('custreg.v4_invalid'), 'tone', 'danger');
    end if;
    v_taken := exists (select 1 from public.pharmacy_profiles pp
                        where coalesce(pp.is_deleted,false) = false
                          and pp.id is distinct from v_own
                          and (v_staff or pp.user_id is distinct from v_uid)
                          and lower(btrim(coalesce(pp.email,''))) = v_n)
            or (not v_staff and exists (select 1 from auth.users u
                                         where u.id <> v_uid and lower(coalesce(u.email,'')) = v_n));
  end if;

  if v_taken then
    return jsonb_build_object('ok', true, 'field', p_field, 'state', 'taken', 'blocks', true,
      'suffix', public._c('custreg.v4_taken'), 'tone', 'warning',
      'card', jsonb_build_object(
        'line', public._c(case when v_kind = 'phone' then 'custreg.v4_taken_phone' else 'custreg.v4_taken_email' end),
        'login_label', case when v_staff then '' else public._c('custreg.v4_login') end,
        'login_number', case when v_kind = 'phone' and not v_staff then v_n else '' end));
  end if;
  return jsonb_build_object('ok', true, 'field', p_field, 'state', 'ok', 'blocks', false,
    'suffix', public._c('custreg.v4_ok'), 'tone', 'success', 'value', v_n);
end $$;
revoke all on function public.custreg_contact_check(text, text, uuid) from public, anon;
grant execute on function public.custreg_contact_check(text, text, uuid) to authenticated;

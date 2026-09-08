-- replay-target: production
-- CMD #1886 (3/3) — THE LISTS.

begin;

-- Who is a "signed up" person: an auth login that is not a customer, not a
-- supplier, not an admin, not partner staff, not a delivery partner — and not a
-- QA fixture. One definition, three readers.
create or replace function public._c1886_is_signed_up(p_uid uuid, p_email text)
returns boolean language sql stable as $$
  select not exists (select 1 from public.pharmacy_profiles pp where pp.user_id = p_uid)
     and not exists (select 1 from public.supplier_profiles sp where sp.user_id = p_uid)
     and not exists (select 1 from public.partner_users pu where pu.auth_user_id = p_uid)
     and not exists (select 1 from public.delivery_partner_registrations dr where dr.user_id = p_uid)
     and not exists (select 1 from public.admins a
                      where lower(btrim(a.email)) = lower(btrim(coalesce(p_email,'@none'))))
     -- QA fixtures never appear on a customer list (spec item 6)
     and not exists (select 1 from public.test_session_actor ta where ta.user_id = p_uid)
     and not exists (select 1 from public.qa_test_identities qi
                      where lower(btrim(coalesce(qi.identity,''))) = lower(btrim(coalesce(p_email,'@none'))))
     and not exists (select 1 from public.customer_signup_followup f
                      where f.auth_user_id = p_uid and f.is_synthetic);
$$;

create or replace function public._c1886_when(p_ts timestamptz, p_never text)
returns text language sql stable as $$
  select case when p_ts is null then p_never
              else to_char(p_ts at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI am') end;
$$;


-- Every caption on a row's controls, so Dart holds no word of its own.
create or replace function public._c1886_actions()
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'assign_label',  public.uic('cust_pipeline.assign_button','Assign'),
    'save_label',    public.uic('cust_pipeline.save','Save'),
    'owner_label',   public.uic('cust_pipeline.col_owner','Owner'),
    'date_label',    public.uic('cust_pipeline.col_next','Next action'),
    'no_date_label', public.uic('cust_pipeline.no_next_action','No date set'),
    'note_label',    public.uic('cust_pipeline.note_label','Note'));
$$;

-- ── the "Signed up" tab ────────────────────────────────────────────────────
create or replace function public.customers_signed_up()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_role text := coalesce(public.role_for_medibo_only(),'none');
  v_zone smallint := public.admin_active_zone();
  v_end  timestamptz := (public.ist_day_bounds(public.admin_active_date())->>'end_utc')::timestamptz;
  v_rows jsonb;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'allowed', false,
      'message', public.uic('cust_pipeline.not_authorized','This screen is for the office team.'));
  end if;

  select coalesce(jsonb_agg(r order by r->>'joined_at' desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'user_id',   u.id,
      'name',      coalesce(nullif(btrim(coalesce(u.raw_user_meta_data->>'full_name',
                                                  u.raw_user_meta_data->>'name','')),''),
                            public.uic('cust_pipeline.no_name','(no name given)')),
      'email',     coalesce(u.email,''),
      'phone',     coalesce(nullif(btrim(coalesce(u.raw_user_meta_data->>'phone','')),''),
                            coalesce(u.phone,'')),
      'joined_at',    u.created_at,
      'joined_label', public._c1886_when(u.created_at, ''),
      'last_login_label', public._c1886_when(u.last_sign_in_at,
                            public.uic('cust_pipeline.never_signed_in','Never')),
      'stage_chip', public.customer_stage_chip('signed_up'::public.registration_stage),
      'assigned_to',    f.assigned_to,
      'assigned_label', coalesce(nullif(btrim(coalesce(au.email,'')),''),
                                 public.uic('cust_pipeline.unassigned','Unassigned')),
      'next_action_at',    f.next_action_at,
      'next_action_label', public._c1886_followup_label(f.next_action_at),
      'next_action_tone',  public._c1886_followup_tone(f.next_action_at),
      'note', coalesce(f.note,''),
      'wa', public._c1886_wa_button(coalesce(nullif(btrim(coalesce(u.raw_user_meta_data->>'phone','')),''),
                                             coalesce(u.phone,'')))
    ) as r
    from auth.users u
    left join public.customer_signup_followup f on f.auth_user_id = u.id
    left join auth.users au on au.id = f.assigned_to
    where u.created_at < v_end
      and public._c1886_is_signed_up(u.id, u.email)
      and (v_zone is null or f.zone_id is null or f.zone_id = v_zone)
  ) t;

  return jsonb_build_object(
    'ok', true, 'allowed', true,
    'title', public.uic('cust_pipeline.tab_signed_up','Signed up'),
    'empty_label', public.uic('cust_pipeline.empty_signed_up',''),
    'count', jsonb_array_length(v_rows),
    'columns', jsonb_build_array(
      jsonb_build_object('key','name',        'label', public.uic('cust_pipeline.col_person','Person')),
      jsonb_build_object('key','contact',     'label', public.uic('cust_pipeline.col_contact','Contact')),
      jsonb_build_object('key','joined',      'label', public.uic('cust_pipeline.col_joined','Joined')),
      jsonb_build_object('key','last_login',  'label', public.uic('cust_pipeline.col_last_login','Last login')),
      jsonb_build_object('key','owner',       'label', public.uic('cust_pipeline.col_owner','Owner')),
      jsonb_build_object('key','next',        'label', public.uic('cust_pipeline.col_next','Next action')),
      jsonb_build_object('key','action',      'label', public.uic('cust_pipeline.col_action','Action'))),
    'actions', public._c1886_actions(),
    'rows', v_rows);
end $$;

create or replace function public._c1886_followup_label(p_at timestamptz)
returns text language sql stable as $$
  select case
    when p_at is null then public.uic('cust_pipeline.no_next_action','No date set')
    when p_at < now() then public.uic('cust_pipeline.overdue_prefix','Overdue — ')
                            || to_char(p_at at time zone 'Asia/Kolkata','DD Mon')
    else to_char(p_at at time zone 'Asia/Kolkata','DD Mon YYYY') end;
$$;

create or replace function public._c1886_followup_tone(p_at timestamptz)
returns text language sql stable as $$
  select case when p_at is null then 'neutral'
              when p_at < now() then 'danger'
              else 'info' end;
$$;

create or replace function public._c1886_wa_button(p_phone text)
returns jsonb language sql stable as $$
  select case when public.wa_normalize_phone(p_phone) is null
    then jsonb_build_object('can', false,
           'label', public.uic('cust_pipeline.wa_button','Send WhatsApp'),
           'reason', public.uic('cust_pipeline.wa_no_phone','No phone on this login'))
    else jsonb_build_object('can', true,
           'label', public.uic('cust_pipeline.wa_button','Send WhatsApp'),
           'reason', '') end;
$$;

-- ── "Needs attention" ──────────────────────────────────────────────────────
create or replace function public.customers_needs_attention()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_role text := coalesce(public.role_for_medibo_only(),'none');
  v_zone smallint := public.admin_active_zone();
  v_end  timestamptz := (public.ist_day_bounds(public.admin_active_date())->>'end_utc')::timestamptz;
  v_rows jsonb;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'allowed', false,
      'message', public.uic('cust_pipeline.not_authorized','This screen is for the office team.'));
  end if;

  select coalesce(jsonb_agg(r order by (r->>'stage_ord')::int, r->>'name'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'customer_id', pp.id,
      'name', coalesce(nullif(btrim(coalesce(pp.pharmacy_name,'')),''),
                       nullif(btrim(coalesce(pp.owner_name,'')),''),
                       public.uic('cust_pipeline.no_name','(no name given)')),
      'contact', coalesce(nullif(btrim(coalesce(pp.phone,'')),''), coalesce(pp.whatsapp_no,''), coalesce(pp.email,'')),
      'stage_chip', public.customer_stage_chip(pp.registration_stage),
      'stage_ord', array_position(array['signed_up','details','documents','verified','approved'],
                                  coalesce(pp.registration_stage::text,'signed_up')),
      'missing', m.missing,
      'missing_label', public.customer_missing_sentence(m.missing),
      'assigned_to', pp.assigned_to,
      'assigned_label', coalesce(nullif(btrim(coalesce(au.email,'')),''),
                                 public.uic('cust_pipeline.unassigned','Unassigned')),
      'next_action_at', pp.next_action_at,
      'next_action_label', public._c1886_followup_label(pp.next_action_at),
      'next_action_tone', public._c1886_followup_tone(pp.next_action_at),
      'approve', public.customer_approve_gate(pp.id)
    ) as r
    from public.pharmacy_profiles pp
    cross join lateral (select public.customer_missing_fields(pp.id) as missing) m
    left join auth.users au on au.id = pp.assigned_to
    where coalesce(pp.is_deleted,false) = false
      and not coalesce(pp.is_synthetic,false)
      and pp.created_at < v_end
      and (v_zone is null or pp.zone_id = v_zone)
      and jsonb_array_length(m.missing) > 0
  ) t;

  return jsonb_build_object(
    'ok', true, 'allowed', true,
    'title', public.uic('cust_pipeline.tab_needs','Needs attention'),
    'empty_label', public.uic('cust_pipeline.empty_needs',''),
    'count', jsonb_array_length(v_rows),
    'columns', jsonb_build_array(
      jsonb_build_object('key','name',    'label', public.uic('cust_pipeline.col_person','Person')),
      jsonb_build_object('key','stage',   'label', public.uic('cust_pipeline.col_stage','Stage')),
      jsonb_build_object('key','missing', 'label', public.uic('cust_pipeline.col_missing','Missing')),
      jsonb_build_object('key','owner',   'label', public.uic('cust_pipeline.col_owner','Owner')),
      jsonb_build_object('key','action',  'label', public.uic('cust_pipeline.col_action','Action'))),
    'actions', public._c1886_actions(),
    'rows', v_rows);
end $$;

-- ── "My follow-ups" — both kinds of row, one list ──────────────────────────
create or replace function public.customer_followups_mine()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_role text := coalesce(public.role_for_medibo_only(),'none');
  v_zone smallint := public.admin_active_zone();
  v_me   uuid := auth.uid();
  v_rows jsonb;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'allowed', false,
      'message', public.uic('cust_pipeline.not_authorized','This screen is for the office team.'));
  end if;

  select coalesce(jsonb_agg(r order by (r->>'sort_at')), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'kind','customer', 'subject_id', pp.id,
      'name', coalesce(nullif(btrim(coalesce(pp.pharmacy_name,'')),''),
                       public.uic('cust_pipeline.no_name','(no name given)')),
      'contact', coalesce(nullif(btrim(coalesce(pp.phone,'')),''), coalesce(pp.whatsapp_no,'')),
      'stage_chip', public.customer_stage_chip(pp.registration_stage),
      'next_action_at', pp.next_action_at,
      'next_action_label', public._c1886_followup_label(pp.next_action_at),
      'next_action_tone',  public._c1886_followup_tone(pp.next_action_at),
      'overdue', (pp.next_action_at is not null and pp.next_action_at < now()),
      'note', coalesce(pp.followup_note,''),
      'sort_at', coalesce(to_char(pp.next_action_at,'YYYY-MM-DD HH24:MI'),'9999')
    ) as r
    from public.pharmacy_profiles pp
    where pp.assigned_to = v_me
      and coalesce(pp.is_deleted,false) = false
      and not coalesce(pp.is_synthetic,false)
      and (v_zone is null or pp.zone_id = v_zone)
    union all
    select jsonb_build_object(
      'kind','signup', 'subject_id', f.auth_user_id,
      'name', coalesce(nullif(btrim(coalesce(u.raw_user_meta_data->>'full_name',
                                             u.raw_user_meta_data->>'name','')),''),
                       coalesce(u.email, public.uic('cust_pipeline.no_name','(no name given)'))),
      'contact', coalesce(nullif(btrim(coalesce(u.raw_user_meta_data->>'phone','')),''),
                          coalesce(u.phone,''), coalesce(u.email,'')),
      'stage_chip', public.customer_stage_chip('signed_up'::public.registration_stage),
      'next_action_at', f.next_action_at,
      'next_action_label', public._c1886_followup_label(f.next_action_at),
      'next_action_tone',  public._c1886_followup_tone(f.next_action_at),
      'overdue', (f.next_action_at is not null and f.next_action_at < now()),
      'note', coalesce(f.note,''),
      'sort_at', coalesce(to_char(f.next_action_at,'YYYY-MM-DD HH24:MI'),'9999')
    ) as r
    from public.customer_signup_followup f
    join auth.users u on u.id = f.auth_user_id
    where f.assigned_to = v_me
      and not coalesce(f.is_synthetic,false)
      and (v_zone is null or f.zone_id is null or f.zone_id = v_zone)
  ) t;

  return jsonb_build_object(
    'ok', true, 'allowed', true,
    'title', public.uic('cust_pipeline.tab_followups','My follow-ups'),
    'empty_label', public.uic('cust_pipeline.empty_followups',''),
    'count', jsonb_array_length(v_rows),
    'overdue_count', (select count(*) from jsonb_array_elements(v_rows) e where (e->>'overdue')::boolean),
    'columns', jsonb_build_array(
      jsonb_build_object('key','name',   'label', public.uic('cust_pipeline.col_person','Person')),
      jsonb_build_object('key','stage',  'label', public.uic('cust_pipeline.col_stage','Stage')),
      jsonb_build_object('key','next',   'label', public.uic('cust_pipeline.col_next','Next action')),
      jsonb_build_object('key','action', 'label', public.uic('cust_pipeline.col_action','Action'))),
    'actions', public._c1886_actions(),
    'rows', v_rows);
end $$;

commit;

-- captions this file's payloads name
begin;
insert into public.ui_copy(key, value) values
  ('cust_pipeline.save',       '"Save"'::jsonb),
  ('cust_pipeline.note_label', '"Note"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();
commit;

-- replay-target: production
-- CMD #1886 (4/4) — THE ACTIONS, THE HOME PAYLOAD, THE NUDGE AND THE PURGE.

begin;

insert into public.ui_copy(key, value) values
  ('cust_pipeline.assign_unknown',   '"That person is not on the office team."'::jsonb),
  ('cust_pipeline.assign_no_subject','"That row no longer exists."'::jsonb),
  ('cust_pipeline.nudge_failed',     '"WhatsApp did not go out: "'::jsonb),
  ('cust_pipeline.zone_all',         '"All zones"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── assign an owner and a date, to either kind of row ──────────────────────
create or replace function public.customer_followup_set(
  p_kind text, p_subject_id uuid, p_assigned_to uuid default null,
  p_next_action_at timestamptz default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_role text := coalesce(public.role_for_medibo_only(),'none');
  v_zone smallint := public.admin_active_zone();
  v_n integer;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false,
      'message', public.uic('cust_pipeline.not_authorized','This screen is for the office team.'));
  end if;

  -- an owner must be somebody on the office team, resolved by their login
  if p_assigned_to is not null and not exists (
       select 1 from public.admins a join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email))
        where u.id = p_assigned_to) then
    return jsonb_build_object('ok', false,
      'message', public.uic('cust_pipeline.assign_unknown','That person is not on the office team.'));
  end if;

  if lower(coalesce(p_kind,'')) = 'customer' then
    update public.pharmacy_profiles
       set assigned_to = p_assigned_to,
           next_action_at = p_next_action_at,
           followup_note = coalesce(p_note, followup_note)
     where id = p_subject_id;
    get diagnostics v_n = row_count;
  else
    insert into public.customer_signup_followup(auth_user_id, assigned_to, next_action_at, note, zone_id)
    values (p_subject_id, p_assigned_to, p_next_action_at, p_note, v_zone)
    on conflict (auth_user_id) do update
      set assigned_to = excluded.assigned_to,
          next_action_at = excluded.next_action_at,
          note = coalesce(excluded.note, public.customer_signup_followup.note),
          zone_id = coalesce(excluded.zone_id, public.customer_signup_followup.zone_id),
          updated_at = now();
    get diagnostics v_n = row_count;
  end if;

  if v_n = 0 then
    return jsonb_build_object('ok', false,
      'message', public.uic('cust_pipeline.assign_no_subject','That row no longer exists.'));
  end if;
  return jsonb_build_object('ok', true,
    'message', public.uic('cust_pipeline.assign_saved','Follow-up saved.'),
    'next_action_label', public._c1886_followup_label(p_next_action_at),
    'next_action_tone',  public._c1886_followup_tone(p_next_action_at));
end $$;

-- ── the one-tap WhatsApp nudge ─────────────────────────────────────────────
-- The template is an APPROVED one; the route is DATA, so the day a dedicated
-- "finish your registration" template is approved by Meta this is one UPDATE.
insert into public.wa_event_routes(event_key, label, description, template_id, template_name,
                                   language, variable_map, enabled, audience)
select 'customer_signup_nudge', 'Finish your registration',
       'CMD #1886 — one tap from the Signed up tab to a person who signed in and stopped.',
       r.template_id, r.template_name, r.language, r.variable_map, true, r.audience
from public.wa_event_routes r where r.event_key = 'customer_registration'
on conflict (event_key) do update
  set template_id   = coalesce(public.wa_event_routes.template_id, excluded.template_id),
      template_name = coalesce(public.wa_event_routes.template_name, excluded.template_name),
      label         = excluded.label,
      description   = excluded.description;

create or replace function public.customer_signup_nudge(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_role text := coalesce(public.role_for_medibo_only(),'none');
  v_phone text; v_name text; v_res jsonb;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false,
      'message', public.uic('cust_pipeline.not_authorized','This screen is for the office team.'));
  end if;

  select coalesce(nullif(btrim(coalesce(u.raw_user_meta_data->>'phone','')),''), u.phone),
         coalesce(nullif(btrim(coalesce(u.raw_user_meta_data->>'full_name',
                                        u.raw_user_meta_data->>'name','')),''),
                  split_part(coalesce(u.email,''),'@',1))
    into v_phone, v_name
  from auth.users u where u.id = p_user_id;

  if public.wa_normalize_phone(v_phone) is null then
    return jsonb_build_object('ok', false,
      'message', public.uic('cust_pipeline.wa_no_phone','No phone on this login'));
  end if;

  v_res := public.wa_send_event('customer_signup_nudge', null,
             jsonb_build_object('customer_name', v_name), v_phone, null);

  if coalesce((v_res->>'ok')::boolean, false) then
    insert into public.customer_signup_followup(auth_user_id, nudged_at, nudge_count, zone_id)
    values (p_user_id, now(), 1, public.admin_active_zone())
    on conflict (auth_user_id) do update
      set nudged_at = now(),
          nudge_count = public.customer_signup_followup.nudge_count + 1,
          updated_at = now();
    return jsonb_build_object('ok', true,
      'message', public.uic('cust_pipeline.wa_sent','WhatsApp sent.'));
  end if;

  return jsonb_build_object('ok', false,
    'message', public.uic('cust_pipeline.nudge_failed','WhatsApp did not go out: ')
               || coalesce(nullif(v_res->>'message',''), v_res->>'reason', ''));
end $$;

-- ── the chip + approve gate for EVERY row the Customers screen already draws ─
create or replace function public.customers_stage_meta()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_role text := coalesce(public.role_for_medibo_only(),'none');
  v_zone smallint := public.admin_active_zone();
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'allowed', false, 'by_id', '{}'::jsonb);
  end if;
  return jsonb_build_object('ok', true, 'allowed', true,
    'by_id', coalesce((
      select jsonb_object_agg(pp.id::text, jsonb_build_object(
               'chip', public.customer_stage_chip(pp.registration_stage),
               'approve', public.customer_approve_gate(pp.id),
               'missing_label', public.customer_missing_sentence(public.customer_missing_fields(pp.id))))
      from public.pharmacy_profiles pp
      where coalesce(pp.is_deleted,false) = false
        and not coalesce(pp.is_synthetic,false)
        and (v_zone is null or pp.zone_id = v_zone)), '{}'::jsonb));
end $$;

-- ── the tab strip: labels and counts, both from here ───────────────────────
create or replace function public.customer_pipeline_home()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_role text := coalesce(public.role_for_medibo_only(),'none');
  v_zone smallint := public.admin_active_zone();
  v_signed int; v_needs int; v_mine int; v_overdue int;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'allowed', false,
      'message', public.uic('cust_pipeline.not_authorized','This screen is for the office team.'));
  end if;

  v_signed  := coalesce((public.customers_signed_up()      ->>'count')::int, 0);
  v_needs   := coalesce((public.customers_needs_attention()->>'count')::int, 0);
  v_mine    := coalesce((public.customer_followups_mine()  ->>'count')::int, 0);
  v_overdue := coalesce((public.customer_followups_mine()  ->>'overdue_count')::int, 0);

  return jsonb_build_object(
    'ok', true, 'allowed', true,
    'title', public.uic('cust_pipeline.title','Registration pipeline'),
    'zone_id', v_zone,
    'zone_label', coalesce((select z.name from public.zones z where z.id = v_zone),
                           public.uic('cust_pipeline.zone_all','All zones')),
    'date_label', to_char(public.admin_active_date(), 'DD Mon YYYY'),
    'tabs', jsonb_build_array(
      jsonb_build_object('key','signed_up','label', public.uic('cust_pipeline.tab_signed_up','Signed up'),
                         'count', v_signed, 'count_label', v_signed::text, 'tone','neutral'),
      jsonb_build_object('key','followups','label', public.uic('cust_pipeline.tab_followups','My follow-ups'),
                         'count', v_mine, 'count_label', v_mine::text,
                         'tone', case when v_overdue > 0 then 'danger' else 'neutral' end),
      jsonb_build_object('key','needs','label', public.uic('cust_pipeline.tab_needs','Needs attention'),
                         'count', v_needs, 'count_label', v_needs::text,
                         'tone', case when v_needs > 0 then 'warning' else 'neutral' end)),
    'assignees', coalesce((
      select jsonb_agg(jsonb_build_object('value', u.id, 'label', a.email) order by a.email)
      from public.admins a join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email))), '[]'::jsonb));
end $$;

-- ── spec item 6: the nightly purge of QA fixtures ──────────────────────────
create or replace function public.customer_synthetic_purge()
returns jsonb language plpgsql security definer set search_path = public as $$
declare n1 int; n2 int;
begin
  delete from public.customer_signup_followup where is_synthetic; get diagnostics n1 = row_count;
  delete from public.pharmacy_profiles
   where is_synthetic
     and created_at < now() - interval '1 day'
     and not exists (select 1 from public.orders o where o.customer_id = pharmacy_profiles.id);
  get diagnostics n2 = row_count;
  return jsonb_build_object('ok', true, 'signup_followups', n1, 'profiles', n2);
end $$;

insert into public.cron_task(name, ord, mode, gate_sql, work_sql, enabled, note, base_interval_s)
values ('c1886-synthetic-customer-purge', 780, 'poll',
        $g$select (now() at time zone 'Asia/Kolkata')::time >= time '02:10'
              and (now() at time zone 'Asia/Kolkata')::time <  time '03:10'$g$,
        'select public.customer_synthetic_purge()', true,
        'CMD #1886 — QA customer fixtures never survive into a real morning.', 3600)
on conflict (name) do update
  set gate_sql = excluded.gate_sql, work_sql = excluded.work_sql,
      enabled = excluded.enabled, note = excluded.note,
      base_interval_s = excluded.base_interval_s;

-- ── grants: never PUBLIC, never anon (the #436/#205 pattern) ───────────────
do $$
declare f text;
begin
  foreach f in array array[
    'public.customers_signed_up()',
    'public.customers_needs_attention()',
    'public.customer_followups_mine()',
    'public.customer_pipeline_home()',
    'public.customers_stage_meta()',
    'public.customer_approve_gate(uuid)',
    'public.customer_missing_fields(uuid)',
    'public.customer_stage_of(uuid)',
    'public.customer_synthetic_purge()',
    'public.customer_signup_nudge(uuid)',
    'public.customer_followup_set(text,uuid,uuid,timestamptz,text)']
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

commit;

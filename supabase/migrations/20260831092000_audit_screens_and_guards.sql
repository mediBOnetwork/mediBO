-- CHANGE #394 — PART 3 of 3: the guards on the RPCs, and the two screens.
--
-- Part 1 made the log un-bypassable, Part 2 made access grantable. This part
-- (a) puts admin_require() inside the money RPCs so the fence is in the
-- BACKEND and not in a Flutter `if`, (b) adds audit_write() where a row diff
-- does not tell the story (a claim decided, a payout paid, a customer
-- suspended), and (c) renders both surfaces entirely server-side: every
-- label, every date, every diff line arrives as a string the app prints.

-- ══════════════════════════════════════════════════════════════════════════
-- A. THE FENCE — admin_require() inside the RPCs themselves
-- ══════════════════════════════════════════════════════════════════════════

-- Discount slabs: one gate, four callers. The list needs read; the three
-- mutations need write, checked separately so "can look at pricing" and "can
-- change pricing" stop being the same grant.
create or replace function public._slab_can_admin()
returns boolean
language sql
stable security definer
set search_path to 'public'
as $function$
  select coalesce(public.get_my_role(),'') in ('admin','super_admin')
     and public.admin_can('admin.discount_slabs','read');
$function$;

create or replace function public.admin_discount_slab_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_min numeric; v_pct numeric; v_from date; v_note text; v_id bigint;
begin
  if not public._slab_can_admin()
     or not public.admin_can('admin.discount_slabs','write') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'message', public._c('slabs.not_authorized'));
  end if;

  v_min := public._slab_num(p->>'min_amount');
  v_pct := public._slab_num(p->>'discount_pct');
  v_id  := public._slab_num(p->>'id')::bigint;

  -- An unreadable date is not a silent "today": it is the date field's own
  -- error, so the admin sees which box was wrong.
  begin
    v_from := coalesce(nullif(btrim(coalesce(p->>'effective_from','')),'')::date,
                       (now() at time zone 'Asia/Kolkata')::date);
  exception when others then
    return jsonb_build_object('ok', false, 'error','bad_effective_from',
                              'message', public._c('slabs.err_effective_from'));
  end;

  v_note := nullif(btrim(coalesce(p->>'note','')),'');

  if v_min is null or v_min < 0 then
    return jsonb_build_object('ok', false, 'error','bad_min_amount',
                              'message', public._c('slabs.err_min_amount'));
  end if;
  if v_pct is null or v_pct < 0 or v_pct > 100 then
    return jsonb_build_object('ok', false, 'error','bad_discount_pct',
                              'message', public._c('slabs.err_discount_pct'));
  end if;

  if exists (select 1 from public.discount_slabs s
              where s.min_amount = v_min and s.effective_from = v_from
                and (v_id is null or s.id <> v_id)) then
    return jsonb_build_object('ok', false, 'error','duplicate',
                              'message', public._c('slabs.err_duplicate'));
  end if;

  if v_id is not null then
    update public.discount_slabs
       set min_amount = v_min, discount_pct = v_pct, effective_from = v_from,
           note = v_note,
           active = coalesce((p->>'active')::boolean, active),
           updated_at = now()
     where id = v_id;
  else
    insert into public.discount_slabs (min_amount, discount_pct, effective_from, note, active)
    values (v_min, v_pct, v_from, v_note, coalesce((p->>'active')::boolean, true))
    returning id into v_id;
  end if;

  return public.admin_discount_slabs()
         || jsonb_build_object('toast', public._c('slabs.saved_toast'), 'saved_id', v_id);
end $function$;

create or replace function public.admin_discount_slab_delete(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not public._slab_can_admin()
     or not public.admin_can('admin.discount_slabs','write') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'message', public._c('slabs.not_authorized'));
  end if;
  delete from public.discount_slabs where id = p_id;
  return public.admin_discount_slabs()
         || jsonb_build_object('toast', public._c('slabs.deleted_toast'));
end $function$;

create or replace function public.admin_discount_slab_set_active(p_id bigint, p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not public._slab_can_admin()
     or not public.admin_can('admin.discount_slabs','write') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'message', public._c('slabs.not_authorized'));
  end if;
  update public.discount_slabs
     set active = coalesce(p_active, true), updated_at = now()
   where id = p_id;
  return public.admin_discount_slabs()
         || jsonb_build_object('toast', public._c('slabs.saved_toast'));
end $function$;

-- Bill edits / re-runs.
create or replace function public.admin_bill_pipeline_action(p_order_id uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v jsonb;
begin
  if get_my_role() not in ('admin','super_admin')
     or not public.admin_can('admin.bill_pipeline','write') then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  if lower(coalesce(p_action,'')) not in ('retry','enqueue') then
    return jsonb_build_object('ok', false, 'error','bad_action');
  end if;
  v := public.bill_job_enqueue(p_order_id, true);
  perform public.audit_write('bill.' || lower(p_action), 'order', p_order_id::text,
            null, jsonb_build_object('action', lower(p_action), 'result', v));
  return v || jsonb_build_object('toast', case when (v->>'ok')::boolean
                                               then public._bpl('action.retry_done')
                                               else public._bpl('action.blocked') end);
end $function$;

-- Payment-claim decisions: approve/reject is the money decision, so the
-- BEFORE and AFTER are captured explicitly rather than left to a row diff on
-- a table nobody is watching.
create or replace function public.admin_claim_decide(p_claim_id uuid, p_action text, p_amount numeric default null, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare c public.delivery_claims%rowtype; a public.delivery_claims%rowtype;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin')
     or not public.admin_can('admin.delivery_ops','write') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  select * into c from public.delivery_claims where id = p_claim_id;
  if c.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if c.status <> 'open' then
    return jsonb_build_object('ok',false,'error','already_decided','status',c.status);
  end if;

  if p_action = 'approve' then
    update public.delivery_claims
       set status='approved', amount = coalesce(p_amount, amount),
           reviewed_by=auth.uid(), reviewed_at=now()
     where id = p_claim_id;
  elsif p_action = 'reject' then
    update public.delivery_claims
       set status='rejected', reject_reason=nullif(btrim(coalesce(p_reason,'')),''),
           reviewed_by=auth.uid(), reviewed_at=now()
     where id = p_claim_id;
  else
    return jsonb_build_object('ok',false,'error','bad_action');
  end if;

  select * into a from public.delivery_claims where id = p_claim_id;
  perform public.audit_write('payment_claim.' || p_action, 'payment_claim',
            p_claim_id::text, to_jsonb(c), to_jsonb(a));

  return jsonb_build_object('ok',true,'claim_id',p_claim_id,'status',a.status);
end $function$;

-- Rider / partner payout.
create or replace function public.admin_payout_pay(p_period_id uuid, p_ref text default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_rows int; v_p public.delivery_payout_periods%rowtype; v_b public.delivery_payout_periods%rowtype;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin')
     or not public.admin_can('admin.settlement','write') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  select * into v_b from public.delivery_payout_periods where id = p_period_id;

  -- LOCK 3 — the transition is guarded inside the UPDATE itself. Two admins
  -- tapping at once: one updates a row, the other updates none.
  update public.delivery_payout_periods
     set status='paid', paid_at=now(), paid_by=auth.uid(),
         paid_ref=nullif(btrim(coalesce(p_ref,'')),''),
         note=coalesce(nullif(btrim(coalesce(p_note,'')),''), note)
   where id = p_period_id and status = 'unpaid';
  get diagnostics v_rows = row_count;

  select * into v_p from public.delivery_payout_periods where id = p_period_id;
  if v_p.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  if v_rows = 0 then
    return jsonb_build_object('ok',false,'error','already_paid','status',v_p.status,
      'message', public._c('admin.delivery.payout_already_paid'),
      'paid_at', v_p.paid_at);
  end if;

  perform public.audit_write('payout.pay', 'payout_period', p_period_id::text,
            to_jsonb(v_b), to_jsonb(v_p));

  return jsonb_build_object('ok',true,'period_id',p_period_id,'status','paid',
    'paid_at', v_p.paid_at,
    'amount_label', public.inr_money(v_p.net_amount));
end $function$;

-- Customer approve / suspend / delete.
create or replace function public.admin_customer_action(p_customer_id uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_role text := coalesce(public.role_for_medibo_only(), 'none');
  v_who  text;
  v_cfg  jsonb := coalesce((select value from app_settings where key='customer_status_values'), '{}'::jsonb);
  pp pharmacy_profiles%rowtype;
  bb pharmacy_profiles%rowtype;
begin
  if v_role not in ('admin','super_admin')
     or not public.admin_can('admin.customers','write') then
    raise exception 'forbidden' using hint = 'Only an admin may change customer status.';
  end if;

  select * into pp from pharmacy_profiles where id = p_customer_id;
  if not found then raise exception 'customer_not_found'; end if;
  bb := pp;

  v_who := coalesce(nullif(public.my_login_email(),''), auth.uid()::text, 'unknown');

  if p_action = 'approve' then
    update pharmacy_profiles set
      approved = true,
      status = coalesce(v_cfg->>'approved','approved'),
      approved_at = now(),
      approved_by = v_who
    where id = p_customer_id;

  elsif p_action = 'reject' then
    update pharmacy_profiles set
      approved = false, status = coalesce(v_cfg->>'rejected','rejected')
    where id = p_customer_id;

  elsif p_action = 'suspend' then
    update pharmacy_profiles set status = coalesce(v_cfg->>'suspended','suspended')
    where id = p_customer_id;

  elsif p_action = 'reactivate' then
    update pharmacy_profiles set status = coalesce(v_cfg->>'approved','approved')
    where id = p_customer_id;

  elsif p_action = 'delete' then
    update pharmacy_profiles set
      is_deleted = true, deleted_at = now(), deleted_by = v_who,
      deleted_snapshot = to_jsonb(pp)
    where id = p_customer_id;

  elsif p_action = 'restore' then
    update pharmacy_profiles set
      is_deleted = false, deleted_at = null, deleted_by = null, deleted_snapshot = null
    where id = p_customer_id;

  else
    raise exception 'unknown_action: %', p_action;
  end if;

  select * into pp from pharmacy_profiles where id = p_customer_id;

  perform public.audit_write('customer.' || p_action, 'customer', p_customer_id::text,
            jsonb_build_object('approved', bb.approved, 'status', bb.status,
                               'is_deleted', bb.is_deleted),
            jsonb_build_object('approved', pp.approved, 'status', pp.status,
                               'is_deleted', pp.is_deleted));

  return jsonb_build_object(
    'ok',            true,
    'action',        p_action,
    'customer_id',   coalesce(pp.id::text,''),
    'pharmacy_name', coalesce(pp.pharmacy_name,''),
    'user_id',       coalesce(pp.user_id::text,''),
    'email',         coalesce(pp.email,''),
    'approved',      coalesce(pp.approved,false),
    'status',        coalesce(pp.status,''),
    'is_deleted',    coalesce(pp.is_deleted,false),
    'acted_by',      v_who);
end $function$;

-- ══════════════════════════════════════════════════════════════════════════
-- B. THE COPY — every string the two screens print
-- ══════════════════════════════════════════════════════════════════════════
insert into public.ui_copy(key, value) values
  ('audit.title',            '"Audit trail"'::jsonb),
  ('audit.subtitle',         '"Every consequential change, with who made it and what it looked like before."'::jsonb),
  ('audit.empty_title',      '"Nothing recorded yet"'::jsonb),
  ('audit.empty_hint',       '"Changes appear here the moment somebody makes one."'::jsonb),
  ('audit.filter_all',       '"All"'::jsonb),
  ('audit.filter_actor',     '"Who"'::jsonb),
  ('audit.filter_entity',    '"What"'::jsonb),
  ('audit.filter_action',    '"Action"'::jsonb),
  ('audit.filter_days',      '"When"'::jsonb),
  ('audit.more_label',       '"Load more"'::jsonb),
  ('audit.history_title',    '"Full history"'::jsonb),
  ('audit.no_change_label',  '"No field changed"'::jsonb),
  ('audit.before_label',     '"Before"'::jsonb),
  ('audit.after_label',      '"After"'::jsonb),
  ('audit.created_label',    '"Created"'::jsonb),
  ('audit.deleted_label',    '"Deleted"'::jsonb),
  ('audit.not_authorized',   '"You do not have access to the audit trail. Ask a super admin to grant it."'::jsonb),
  ('audit.system_actor',     '"System"'::jsonb),
  ('roles.title',            '"Admin roles"'::jsonb),
  ('roles.subtitle',         '"What each admin can open, and whether they can change it. Super admins always see everything."'::jsonb),
  ('roles.preset_label',     '"Apply a preset"'::jsonb),
  ('roles.preset_hint',      '"A preset replaces every grant this admin has."'::jsonb),
  ('roles.super_label',      '"Super admin — full access"'::jsonb),
  ('roles.saved_toast',      '"Saved"'::jsonb),
  ('roles.preset_toast',     '"Preset applied"'::jsonb),
  ('roles.not_authorized',   '"Only a super admin can change admin roles."'::jsonb),
  ('roles.access_none',      '"No access"'::jsonb),
  ('roles.access_read',      '"View"'::jsonb),
  ('roles.access_write',     '"Edit"'::jsonb),
  ('roles.granted_label',    '"{n} granted"'::jsonb),
  ('roles.open_label',       '"Roles & access"'::jsonb),
  ('roles.empty_title',      '"No other admins yet"'::jsonb),
  ('roles.empty_hint',       '"Add an admin above, then grant the screens they need."'::jsonb)
on conflict (key) do update set value = excluded.value;

-- ══════════════════════════════════════════════════════════════════════════
-- C. THE AUDIT SCREEN — one RPC, printed verbatim
-- ══════════════════════════════════════════════════════════════════════════

-- A jsonb scalar as the one line a human reads. Never a raw {"a":1} blob.
create or replace function public._audit_val(p jsonb)
returns text
language sql
immutable
as $$
  select case
    when p is null or jsonb_typeof(p) = 'null' then '—'
    when jsonb_typeof(p) = 'string'  then nullif(p #>> '{}', '')
    when jsonb_typeof(p) = 'boolean' then case when (p)::text = 'true' then 'Yes' else 'No' end
    else p::text
  end
$$;

create or replace function public._audit_when(p timestamptz)
returns text
language sql
stable
as $$
  select to_char(p at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM')
$$;

-- The one row shape both surfaces render.
create or replace function public._audit_row(l public.audit_log)
returns jsonb
language sql
stable
set search_path to 'public'
as $$
  select jsonb_build_object(
    'id',            l.id,
    'title',         coalesce((select c.label from public.audit_table_config c
                                where c.entity_type = l.entity_type limit 1),
                              initcap(replace(l.entity_type,'_',' '))),
    'action_label',  initcap(replace(split_part(l.action, '.', 2), '_', ' ')),
    'action',        l.action,
    'entity_type',   l.entity_type,
    'entity_id',     coalesce(l.entity_id,''),
    'entity_label',  case when coalesce(l.entity_id,'') = '' then ''
                          else '#' || left(l.entity_id, 12) end,
    'actor_label',   coalesce(nullif(l.actor_email,''), public._c('audit.system_actor')),
    'actor_role',    coalesce(l.actor_role,''),
    'when_label',    public._audit_when(l.at),
    'zone_label',    case when l.zone_id is null then '' else 'Zone ' || l.zone_id::text end,
    'source_label',  coalesce(l.source,''),
    'tone',          case
                       when l.action like '%.delete' or l.action like '%.reject'
                         or l.action like '%.suspend' then 'danger'
                       when l.action like '%.insert' or l.action like '%.approve'
                         or l.action like '%.pay'    then 'success'
                       else 'info' end,
    'changes',       coalesce((
        select jsonb_agg(jsonb_build_object(
                 'field',  k,
                 'label',  initcap(replace(k, '_', ' ')),
                 'before', public._audit_val(l.before -> k),
                 'after',  public._audit_val(l.after  -> k)) order by k)
          from unnest(coalesce(l.changed_keys, '{}'::text[])) as k), '[]'::jsonb),
    'changes_label', case
        when l.before is null then public._c('audit.created_label')
        when l.after  is null then public._c('audit.deleted_label')
        when coalesce(cardinality(l.changed_keys),0) = 0 then public._c('audit.no_change_label')
        else array_to_string(
               (select array_agg(initcap(replace(k,'_',' ')) order by k)
                  from unnest(l.changed_keys) k), ', ') end)
$$;

create or replace function public.admin_audit_screen(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_limit  int  := least(greatest(coalesce((p->>'limit')::int, 40), 1), 200);
  v_offset int  := greatest(coalesce((p->>'offset')::int, 0), 0);
  v_actor  text := nullif(btrim(coalesce(p->>'actor','')), '');
  v_entity text := nullif(btrim(coalesce(p->>'entity_type','')), '');
  v_action text := nullif(btrim(coalesce(p->>'action','')), '');
  v_days   int  := nullif(coalesce(p->>'days',''), '')::int;
  v_rows   jsonb;
  v_total  bigint;
begin
  if not public.admin_can('admin.audit_log','read') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'title', public._c('audit.title'),
      'message', public._c('audit.not_authorized'));
  end if;

  with hit as (
    select l.* from public.audit_log l
     where (v_actor  is null or l.actor_email = v_actor)
       and (v_entity is null or l.entity_type = v_entity)
       and (v_action is null or l.action = v_action)
       and (v_days   is null or l.at >= now() - make_interval(days => v_days))
     order by l.id desc
  ), page as (
    select * from hit offset v_offset limit v_limit
  )
  select coalesce((select jsonb_agg(public._audit_row(pg.*) order by pg.id desc) from page pg), '[]'::jsonb),
         (select count(*) from hit)
    into v_rows, v_total;

  return jsonb_build_object(
    'ok',          true,
    'title',       public._c('audit.title'),
    'subtitle',    public._c('audit.subtitle'),
    'can_write',   public.admin_can('admin.audit_log','write'),
    'rows',        v_rows,
    'count',       v_total,
    'count_label', v_total::text || case when v_total = 1 then ' change' else ' changes' end,
    'has_more',    (v_offset + jsonb_array_length(v_rows)) < v_total,
    'more_label',  public._c('audit.more_label'),
    'next_offset', v_offset + jsonb_array_length(v_rows),
    'empty_title', public._c('audit.empty_title'),
    'empty_hint',  public._c('audit.empty_hint'),
    'before_label',public._c('audit.before_label'),
    'after_label', public._c('audit.after_label'),
    'history_title', public._c('audit.history_title'),
    'applied',     jsonb_build_object('actor', coalesce(v_actor,''),
                                      'entity_type', coalesce(v_entity,''),
                                      'action', coalesce(v_action,''),
                                      'days', coalesce(v_days::text,'')),
    'filters', jsonb_build_array(
      jsonb_build_object('key','actor','label', public._c('audit.filter_actor'),
        'options', jsonb_build_array(jsonb_build_object('value','','label',public._c('audit.filter_all')))
          || coalesce((select jsonb_agg(jsonb_build_object('value', a, 'label', a) order by a)
                         from (select distinct actor_email a from public.audit_log
                                where coalesce(actor_email,'') <> '') s), '[]'::jsonb)),
      jsonb_build_object('key','entity_type','label', public._c('audit.filter_entity'),
        'options', jsonb_build_array(jsonb_build_object('value','','label',public._c('audit.filter_all')))
          || coalesce((select jsonb_agg(jsonb_build_object('value', c.entity_type, 'label', c.label)
                                 order by c.label)
                         from (select distinct on (entity_type) entity_type, label
                                 from public.audit_table_config order by entity_type, label) c), '[]'::jsonb)),
      jsonb_build_object('key','action','label', public._c('audit.filter_action'),
        'options', jsonb_build_array(jsonb_build_object('value','','label',public._c('audit.filter_all')))
          || coalesce((select jsonb_agg(jsonb_build_object('value', a,
                                 'label', initcap(replace(replace(a,'.',' '),'_',' '))) order by a)
                         from (select distinct action a from public.audit_log) s), '[]'::jsonb)),
      jsonb_build_object('key','days','label', public._c('audit.filter_days'),
        'options', jsonb_build_array(
          jsonb_build_object('value','','label', public._c('audit.filter_all')),
          jsonb_build_object('value','1','label','Today'),
          jsonb_build_object('value','7','label','Last 7 days'),
          jsonb_build_object('value','30','label','Last 30 days'),
          jsonb_build_object('value','90','label','Last 90 days')))));
end $function$;

create or replace function public.admin_audit_entity(p_entity_type text, p_entity_id text)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_rows jsonb;
begin
  if not public.admin_can('admin.audit_log','read') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public._c('audit.not_authorized'));
  end if;

  select coalesce(jsonb_agg(public._audit_row(l.*) order by l.id desc), '[]'::jsonb)
    into v_rows
    from public.audit_log l
   where l.entity_type = p_entity_type
     and coalesce(l.entity_id,'') = coalesce(p_entity_id,'');

  return jsonb_build_object(
    'ok',          true,
    'title',       public._c('audit.history_title'),
    'subtitle',    coalesce((select c.label from public.audit_table_config c
                              where c.entity_type = p_entity_type limit 1),
                            initcap(replace(p_entity_type,'_',' ')))
                   || ' #' || left(coalesce(p_entity_id,''), 12),
    'entity_type', p_entity_type,
    'entity_id',   coalesce(p_entity_id,''),
    'rows',        v_rows,
    'count',       jsonb_array_length(v_rows),
    'before_label',public._c('audit.before_label'),
    'after_label', public._c('audit.after_label'),
    'empty_title', public._c('audit.empty_title'),
    'empty_hint',  public._c('audit.empty_hint'));
end $function$;

-- ══════════════════════════════════════════════════════════════════════════
-- D. THE ROLES SCREEN — super-admin only, applied from Manage Admins
-- ══════════════════════════════════════════════════════════════════════════
create or replace function public.admin_roles_screen()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_admins jsonb; v_groups jsonb; v_presets jsonb;
begin
  if not public._is_super() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'title', public._c('roles.title'),
      'message', public._c('roles.not_authorized'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'admin_id',    a.id,
           'email',       a.email,
           'is_super',    coalesce(a.is_super,false),
           'role_label',  case when coalesce(a.is_super,false)
                               then public._c('roles.super_label')
                               else replace(public._c('roles.granted_label'), '{n}',
                                    (select count(*)::text from public.admin_permissions ap
                                      where ap.admin_id = a.id and ap.access <> 'none')) end,
           'zone_label',  case when a.zone_id is null then '' else 'Zone ' || a.zone_id::text end,
           'access',      coalesce((select jsonb_object_agg(ap.feature_key, ap.access)
                                      from public.admin_permissions ap where ap.admin_id = a.id),
                                   '{}'::jsonb)
         ) order by coalesce(a.is_super,false) desc, a.email), '[]'::jsonb)
    into v_admins from public.admins a;

  select coalesce(jsonb_agg(g order by g->>'label'), '[]'::jsonb) into v_groups
    from (select jsonb_build_object(
                   'label', f.group_label,
                   'features', jsonb_agg(jsonb_build_object(
                       'feature_key', f.feature_key,
                       'label',       f.label,
                       'hint',        coalesce(f.description,'')) order by f.sort_order)) as g
            from public.feature_registry f
           where f.is_active and f.owner = 'medibo' and f.feature_key like 'admin.%'
           group by f.group_label) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'preset_key', pr.preset_key, 'label', pr.label, 'hint', pr.description,
           'count_label', (select count(*)::text from public.admin_role_preset_feature pf
                            where pf.preset_key = pr.preset_key) || ' screens')
         order by pr.sort_order), '[]'::jsonb)
    into v_presets from public.admin_role_preset pr where pr.is_active;

  return jsonb_build_object(
    'ok', true,
    'title',        public._c('roles.title'),
    'subtitle',     public._c('roles.subtitle'),
    'preset_label', public._c('roles.preset_label'),
    'preset_hint',  public._c('roles.preset_hint'),
    'empty_title',  public._c('roles.empty_title'),
    'empty_hint',   public._c('roles.empty_hint'),
    'admins',       v_admins,
    'groups',       v_groups,
    'presets',      v_presets,
    'access_options', jsonb_build_array(
      jsonb_build_object('value','none', 'label', public._c('roles.access_none'), 'tone','neutral'),
      jsonb_build_object('value','read', 'label', public._c('roles.access_read'), 'tone','info'),
      jsonb_build_object('value','write','label', public._c('roles.access_write'),'tone','success')));
end $function$;

create or replace function public.admin_perm_set(p_email text, p_feature_key text, p_access text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_id uuid;
begin
  if not public._is_super() then
    return jsonb_build_object('ok',false,'error','not_authorized',
      'message', public._c('roles.not_authorized'));
  end if;
  if coalesce(p_access,'') not in ('none','read','write') then
    return jsonb_build_object('ok',false,'error','bad_access');
  end if;
  select a.id into v_id from public.admins a where lower(btrim(a.email)) = lower(btrim(p_email));
  if v_id is null then return jsonb_build_object('ok',false,'error','admin_not_found'); end if;
  if not exists (select 1 from public.feature_registry f
                  where f.feature_key = p_feature_key and f.is_active
                    and f.owner = 'medibo' and f.feature_key like 'admin.%') then
    return jsonb_build_object('ok',false,'error','feature_not_admin_eligible');
  end if;

  -- The row trigger on admin_permissions is what writes the audit entry, so a
  -- grant changed straight through PostgREST is recorded identically.
  insert into public.admin_permissions(admin_id, feature_key, access, updated_at, updated_by)
  values (v_id, p_feature_key, p_access, now(), public.my_login_email())
  on conflict (admin_id, feature_key)
    do update set access = excluded.access, updated_at = now(), updated_by = excluded.updated_by;

  return jsonb_build_object('ok',true,'access',p_access,'feature_key',p_feature_key,
    'email', lower(btrim(p_email)), 'toast', public._c('roles.saved_toast'));
end $function$;

create or replace function public.admin_perm_apply_preset(p_email text, p_preset_key text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_id uuid; v_n int;
begin
  if not public._is_super() then
    return jsonb_build_object('ok',false,'error','not_authorized',
      'message', public._c('roles.not_authorized'));
  end if;
  select a.id into v_id from public.admins a where lower(btrim(a.email)) = lower(btrim(p_email));
  if v_id is null then return jsonb_build_object('ok',false,'error','admin_not_found'); end if;
  if not exists (select 1 from public.admin_role_preset where preset_key = p_preset_key and is_active) then
    return jsonb_build_object('ok',false,'error','preset_not_found');
  end if;

  -- A preset REPLACES: the grants it does not name become 'none', explicitly,
  -- so the audit trail records the removal instead of a silent gap.
  update public.admin_permissions ap set access = 'none', updated_at = now(),
         updated_by = public.my_login_email()
   where ap.admin_id = v_id and ap.access <> 'none'
     and not exists (select 1 from public.admin_role_preset_feature pf
                      where pf.preset_key = p_preset_key and pf.feature_key = ap.feature_key);

  insert into public.admin_permissions(admin_id, feature_key, access, updated_at, updated_by)
  select v_id, pf.feature_key, pf.access, now(), public.my_login_email()
    from public.admin_role_preset_feature pf where pf.preset_key = p_preset_key
  on conflict (admin_id, feature_key)
    do update set access = excluded.access, updated_at = now(), updated_by = excluded.updated_by;
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok',true,'preset_key',p_preset_key,'applied',v_n,
    'email', lower(btrim(p_email)), 'toast', public._c('roles.preset_toast'));
end $function$;

grant execute on function public.admin_audit_screen(jsonb)          to authenticated;
grant execute on function public.admin_audit_entity(text, text)     to authenticated;
grant execute on function public.admin_roles_screen()               to authenticated;
grant execute on function public.admin_perm_set(text, text, text)   to authenticated;
grant execute on function public.admin_perm_apply_preset(text,text) to authenticated;

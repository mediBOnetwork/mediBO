-- CHANGE #707 — the task board, the worker's list, and the two writers.
--
-- Everything a caller reads is finished here: labels, tones, plurals, the
-- promised time, the chips. Dart prints. It does not decide who is eligible,
-- it does not sort by promise, and it does not word a refusal.
--
-- Idempotent: create or replace throughout; the one ALTER is `if not exists`.

-- The stage a role is qualified for is DATA, not a CASE in a function: a new
-- stage that needs a specialist is one UPDATE.
alter table public.fulfil_task_config
  add column if not exists stage_roles jsonb not null
  default '{"count":"counting","pack":"packing"}'::jsonb;

-- ── who is asking ───────────────────────────────────────────────────────────
-- A partner's staff authorise as 'admin' against fulfilment RPCs (CHANGE #307),
-- so get_my_role() cannot tell a partner from the office. role_for_medibo_only()
-- can, and partner_can() answers for the partner side.
create or replace function public._c707_can(p_need text)
returns boolean
language sql stable security definer set search_path to 'public' as $fn$
  select public.role_for_medibo_only() in ('admin','super_admin')
      or public.partner_can('partner.fulfil_tasks', coalesce(p_need,'read'))
$fn$;

create or replace function public._c707_zone(p_zone smallint)
returns smallint
language sql stable security definer set search_path to 'public' as $fn$
  select case when public.my_partner_id() is not null then public.partner_zone_id()
              else coalesce(p_zone, public.admin_active_zone()) end
$fn$;

create or replace function public._c707_actor()
returns text
language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(public.my_login_email(), 'system')
$fn$;

-- ── the open task for a stage, created on demand ────────────────────────────
-- The board is the thing that discovers a stage needs doing, so the board is
-- what materialises the task. `on conflict do nothing` against the partial
-- unique index is what makes "one open task per order-stage" true under two
-- boards refreshing at the same instant.
create or replace function public._c707_ensure_task(
  p_order uuid, p_stage text, p_supplier text, p_zone smallint, p_partner bigint)
returns bigint
language plpgsql security definer set search_path to 'public' as $fn$
declare v_id bigint;
begin
  select id into v_id from public.fulfil_task
   where order_id = p_order and stage_key = p_stage
     and coalesce(supplier_key,'') = coalesce(p_supplier,'') and done_at is null;
  if v_id is not null then return v_id; end if;

  insert into public.fulfil_task (partner_id, zone_id, order_id, stage_key, supplier_key)
  values (p_partner, p_zone, p_order, p_stage, nullif(p_supplier,''))
  on conflict do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.fulfil_task
     where order_id = p_order and stage_key = p_stage
       and coalesce(supplier_key,'') = coalesce(p_supplier,'') and done_at is null;
  end if;
  return v_id;
end $fn$;

-- ── who should get it ───────────────────────────────────────────────────────
-- Round-robin, expressed as a rule rather than a cursor: among the workers who
-- are ON SHIFT today and qualified for the stage, the one carrying the fewest
-- open tasks; ties break to whoever was assigned longest ago, so a fresh roster
-- fans out instead of piling onto whoever sorts first.
create or replace function public._c707_auto_pick(
  p_zone smallint, p_partner bigint, p_stage text)
returns bigint
language sql stable security definer set search_path to 'public' as $fn$
  with cfg as (select * from public._c707_cfg(p_zone)),
  need as (select (select stage_roles->>p_stage from cfg) as role_needed),
  today as (select (now() at time zone 'Asia/Kolkata')::date as d),
  eligible as (
    select w.id,
           (select count(*) from public.fulfil_task t
             where t.worker_id = w.id and t.done_at is null)          as open_n,
           coalesce((select max(t.assigned_at) from public.fulfil_task t
                      where t.worker_id = w.id), 'epoch'::timestamptz) as last_at
      from public.partner_worker w
      join public.partner_worker_shift s
        on s.worker_id = w.id and s.shift_date = (select d from today)
     where w.is_active
       and s.status in ('present','half')
       and (p_partner is null or w.partner_id = p_partner)
       and (p_zone is null or w.zone_id = p_zone or w.zone_id is null)
       and ((select role_needed from need) is null
            or w.work_role = 'both'
            or w.work_role = (select role_needed from need)))
  select id from eligible order by open_n, last_at, id limit 1
$fn$;

-- ── one task, rendered ──────────────────────────────────────────────────────
create or replace function public._c707_task_block(p_task_id bigint)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare t record; w record; v_qty text;
begin
  select * into t from public.fulfil_task where id = p_task_id;
  if not found then return jsonb_build_object('has', false); end if;
  if t.worker_id is not null then
    select coalesce(nullif(btrim(coalesce(display_name,'')),''), identity) as name
      into w from public.partner_worker where id = t.worker_id;
  end if;

  v_qty := case when coalesce(t.qty_handled,0) = 0 then public._c('ft.qty_none')
                when t.qty_handled = 1            then public._c('ft.qty_one')
                else public._cf('ft.qty_label',
                       jsonb_build_object('n', trim(to_char(t.qty_handled,'FM999999990.###')))) end;

  return jsonb_build_object(
    'has',            true,
    'task_id',        t.id,
    'assigned',       (t.worker_id is not null),
    'worker_id',      t.worker_id,
    'worker_label',   case when t.worker_id is null then public._c('ft.unassigned')
                           when t.source = 'auto'
                             then public._cf('ft.assigned_auto', jsonb_build_object('worker', w.name))
                           else public._cf('ft.assigned_to', jsonb_build_object('worker', w.name)) end,
    'worker_name',    coalesce(w.name, ''),
    'worker_tone',    case when t.worker_id is null then 'warning' else 'success' end,
    'source',         t.source,
    'source_label',   case t.source when 'auto' then public._c('ft.source_auto')
                                    else public._c('ft.source_manual') end,
    'started',        (t.started_at is not null),
    'state_label',    case
                        when t.done_at is not null
                          then public._cf('ft.done_label',
                                 jsonb_build_object('ago', public.ist_fmt(t.done_at,'relative')))
                        when t.started_at is not null
                          then public._cf('ft.started_label',
                                 jsonb_build_object('ago', public.ist_fmt(t.started_at,'relative')))
                        else public._cf('ft.waiting_label',
                               jsonb_build_object('ago', public.ist_fmt(t.created_at,'relative'))) end,
    'qty_label',      v_qty,
    'qty_handled',    t.qty_handled,
    'is_override',    (t.override_by is not null),
    'override_chip',  case when t.override_by is not null
                           then public._c('ft.override_chip') else null end,
    'start_label',    public._c('ft.start'),
    'finish_label',   public._c('ft.finish'));
end $fn$;

-- ── the partner / admin board ───────────────────────────────────────────────
create or replace function public.fulfil_task_board(p_zone smallint default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_zone smallint; v_partner bigint := public.my_partner_id();
  cfg public.fulfil_task_config; v_rows jsonb; v_workers jsonb; r record; v_task bigint;
begin
  if not public._c707_can('read') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'tone', 'danger',
      'title', public._c('ft.title'), 'message', public._c('ft.not_authorized'),
      'rows', '[]'::jsonb);
  end if;
  v_zone := public._c707_zone(p_zone);
  cfg    := public._c707_cfg(v_zone);

  -- Materialise a task for every live order sitting at a stage this zone runs.
  for r in
    select s.order_id, s.stage_key, s.zone_id
      from public._ops_order_stage(v_zone) s
     where s.stage_key = any (cfg.stages)
  loop
    v_task := public._c707_ensure_task(r.order_id, r.stage_key, null,
                                       coalesce(r.zone_id, v_zone), v_partner);
    -- Auto-assign is a ZONE setting, applied where the task is discovered, so
    -- a board refresh and the cron sweep cannot disagree about who owns it.
    if cfg.auto_assign and v_task is not null then
      update public.fulfil_task t
         set worker_id = public._c707_auto_pick(coalesce(r.zone_id, v_zone), v_partner, r.stage_key),
             source = 'auto', assigned_at = now(), assigned_by = 'auto', updated_at = now()
       where t.id = v_task and t.worker_id is null
         and public._c707_auto_pick(coalesce(r.zone_id, v_zone), v_partner, r.stage_key) is not null;
    end if;
  end loop;

  select coalesce(jsonb_agg(x order by x.sort_order, x.entered_at), '[]'::jsonb)
    into v_rows
  from (
    select st.sort_order,
           coalesce(h.entered_at, s.since, s.created_at) as entered_at,
           jsonb_build_object(
             'order_id',     s.order_id::text,
             'order_code',   s.order_code,
             'customer',     s.customer,
             'stage_key',    s.stage_key,
             'stage_label',  st.label,
             'next_action',  st.next_action,
             'age_label',    public.ops_age_label(coalesce(h.entered_at, s.since, s.created_at)),
             'promised_label', case when cfgx.sla_minutes is null then public._c('ft.no_promise')
                                    else public._cf('ft.promised_label', jsonb_build_object(
                                           'time', public.ist_fmt(
                                             coalesce(h.entered_at, s.since, s.created_at)
                                               + make_interval(mins => cfgx.sla_minutes::int), 'hm'))) end,
             'task',         public._c707_task_block(
                               public._c707_ensure_task(s.order_id, s.stage_key, null,
                                                        coalesce(s.zone_id, v_zone), v_partner))
           ) as j
      from public._ops_order_stage(v_zone) s
      join public.sla_stage st on st.stage_key = s.stage_key and st.is_active
      left join public.order_stage_history h
             on h.order_id = s.order_id and h.stage_key = s.stage_key and h.left_at is null
      left join lateral (
             select f.sla_minutes from public.sla_config f
              where f.stage_key = s.stage_key and f.is_active
                and (f.zone_id = s.zone_id or f.zone_id is null)
              order by (f.zone_id is null) limit 1) cfgx on true
     where s.stage_key = any (cfg.stages)
  ) q(sort_order, entered_at, x);

  -- The chips to assign FROM. Only workers who are on shift today appear: a
  -- board that offers an absent worker is a board that gets it wrong.
  select coalesce(jsonb_agg(jsonb_build_object(
           'worker_id', w.id,
           'name',      coalesce(nullif(btrim(coalesce(w.display_name,'')),''), w.identity),
           'role',      w.work_role,
           'role_label',public._pop_c('wk.role_' || w.work_role),
           'shift',     s.status,
           'open_n',    (select count(*) from public.fulfil_task t
                          where t.worker_id = w.id and t.done_at is null))
         order by lower(coalesce(nullif(btrim(coalesce(w.display_name,'')),''), w.identity))), '[]'::jsonb)
    into v_workers
    from public.partner_worker w
    join public.partner_worker_shift s
      on s.worker_id = w.id and s.shift_date = (now() at time zone 'Asia/Kolkata')::date
   where w.is_active and s.status in ('present','half')
     and (v_partner is null or w.partner_id = v_partner)
     and (w.zone_id = v_zone or w.zone_id is null);

  return jsonb_build_object(
    'ok', true,
    'title',            public._c('ft.title'),
    'subtitle',         public._c('ft.subtitle'),
    'empty_label',      public._c('ft.empty'),
    'assign_label',     public._c('ft.assign'),
    'reassign_label',   public._c('ft.reassign'),
    'unassigned_label', public._c('ft.unassigned'),
    'can_write',        public._c707_can('write'),
    'auto_assign',      cfg.auto_assign,
    'auto_label',       public._c('ft.auto_assign'),
    'auto_state_label', case when cfg.auto_assign then public._c('ft.auto_on')
                             else public._c('ft.auto_off') end,
    'workers_title',    public._c('ft.workers_title'),
    'workers',          coalesce(v_workers, '[]'::jsonb),
    'rows',             coalesce(v_rows, '[]'::jsonb),
    'zone_id',          v_zone);
end $fn$;

-- ── assign / reassign / clear ───────────────────────────────────────────────
create or replace function public.fulfil_task_assign(
  p_order_id uuid, p_stage_key text, p_worker_id bigint default null,
  p_supplier_key text default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_partner bigint := public.my_partner_id(); v_zone smallint := public._c707_zone(null);
  v_task bigint; w record; v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if not public._c707_can('write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._c('ft.not_authorized'));
  end if;

  v_task := public._c707_ensure_task(p_order_id, p_stage_key, p_supplier_key, v_zone, v_partner);
  if v_task is null then
    return jsonb_build_object('ok',false,'error','no_task','tone','danger',
      'message', public._c('ft.err_no_task'));
  end if;

  if p_worker_id is null then
    update public.fulfil_task
       set worker_id = null, assigned_at = null, assigned_by = null,
           source = 'manual', updated_at = now()
     where id = v_task;
    return jsonb_build_object('ok',true,'tone','success',
      'message', public._c('ft.unassigned_ok'), 'task', public._c707_task_block(v_task));
  end if;

  select w2.*, coalesce(nullif(btrim(coalesce(w2.display_name,'')),''), w2.identity) as name
    into w from public.partner_worker w2
   where w2.id = p_worker_id and w2.is_active
     and (v_partner is null or w2.partner_id = v_partner);
  if not found then
    return jsonb_build_object('ok',false,'error','no_worker','tone','danger',
      'message', public._c('ft.err_no_worker'));
  end if;

  if not exists (select 1 from public.partner_worker_shift s
                  where s.worker_id = w.id and s.shift_date = v_today
                    and s.status in ('present','half')) then
    return jsonb_build_object('ok',false,'error','off_shift','tone','warning',
      'message', public._cf('ft.err_off_shift', jsonb_build_object('worker', w.name)));
  end if;

  update public.fulfil_task
     set worker_id = w.id, assigned_at = now(), assigned_by = public._c707_actor(),
         source = 'manual', updated_at = now()
   where id = v_task;

  perform public.partner_audit('partner.fulfil_tasks','task_assigned',
    jsonb_build_object('order_id', p_order_id, 'stage', p_stage_key, 'worker_id', w.id,
                       'summary', 'Assigned ' || p_stage_key || ' to ' || w.name));

  return jsonb_build_object('ok',true,'tone','success',
    'message', public._cf('ft.assigned_ok', jsonb_build_object('worker', w.name)),
    'task', public._c707_task_block(v_task));
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', public._cf('ft.err_failed', jsonb_build_object('detail', SQLERRM)));
end $fn$;

-- ── auto-assign, on demand and per zone ─────────────────────────────────────
create or replace function public.fulfil_task_auto_assign(p_zone smallint default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_zone smallint; v_partner bigint := public.my_partner_id();
  t record; v_pick bigint; v_n int := 0;
begin
  if not public._c707_can('write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._c('ft.not_authorized'));
  end if;
  v_zone := public._c707_zone(p_zone);

  for t in select * from public.fulfil_task
            where done_at is null and worker_id is null
              and (zone_id = v_zone or zone_id is null)
              and (v_partner is null or partner_id = v_partner or partner_id is null)
  loop
    v_pick := public._c707_auto_pick(v_zone, v_partner, t.stage_key);
    if v_pick is not null then
      update public.fulfil_task
         set worker_id = v_pick, assigned_at = now(), assigned_by = 'auto',
             source = 'auto', updated_at = now()
       where id = t.id;
      v_n := v_n + 1;
    end if;
  end loop;

  if v_n = 0 then
    return jsonb_build_object('ok',true,'assigned',0,'tone','warning',
      'message', public._c('ft.err_no_one_free'), 'state', public.fulfil_task_board(p_zone));
  end if;
  return jsonb_build_object('ok',true,'assigned',v_n,'tone','success',
    'message', public._cf('ft.prod_open', jsonb_build_object('n', v_n::text)),
    'state', public.fulfil_task_board(p_zone));
end $fn$;

create or replace function public.fulfil_task_config_set(p jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_zone smallint;
begin
  if not public._c707_can('write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._c('ft.not_authorized'));
  end if;
  v_zone := public._c707_zone(nullif(p->>'zone_id','')::smallint);

  insert into public.fulfil_task_config (zone_id, auto_assign, unassigned_alert_min, stages)
  values (v_zone,
          coalesce((p->>'auto_assign')::boolean, false),
          coalesce((p->>'unassigned_alert_min')::int, 20),
          coalesce((select array_agg(v) from jsonb_array_elements_text(p->'stages') v),
                   array['collect','count','bag','pack','dispatch']))
  on conflict ((coalesce(zone_id, (-1)::smallint))) do update
     set auto_assign = coalesce((p->>'auto_assign')::boolean, fulfil_task_config.auto_assign),
         unassigned_alert_min = coalesce((p->>'unassigned_alert_min')::int,
                                         fulfil_task_config.unassigned_alert_min),
         updated_at = now();

  return jsonb_build_object('ok',true,'tone','success',
    'state', public.fulfil_task_board(v_zone));
end $fn$;

-- ── the worker's own list ───────────────────────────────────────────────────
create or replace function public.fulfil_my_tasks()
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_worker bigint := public.my_fulfil_worker_id(); v_rows jsonb;
begin
  if v_worker is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_worker', 'tone','danger',
      'title', public._c('ft.my_title'), 'message', public._c('ft.not_authorized'),
      'rows', '[]'::jsonb);
  end if;

  -- ORDERED BY PROMISED TIME, computed here. A task whose stage has no SLA row
  -- has no promise, and sorts last rather than pretending to be urgent.
  select coalesce(jsonb_agg(j order by promised nulls last, entered_at), '[]'::jsonb)
    into v_rows
  from (
    select coalesce(h.entered_at, t.created_at) as entered_at,
           coalesce(h.entered_at, t.created_at)
             + make_interval(mins => cfgx.sla_minutes::int) as promised,
           jsonb_build_object(
             'order_id',     t.order_id::text,
             'order_code',   coalesce(o.order_code, ''),
             'stage_key',    t.stage_key,
             'stage_label',  st.label,
             'next_action',  st.next_action,
             'promised_label', case when cfgx.sla_minutes is null then public._c('ft.no_promise')
                                    else public._cf('ft.promised_label', jsonb_build_object(
                                           'time', public.ist_fmt(
                                             coalesce(h.entered_at, t.created_at)
                                               + make_interval(mins => cfgx.sla_minutes::int),'hm'))) end,
             'task',         public._c707_task_block(t.id)
           ) as j
      from public.fulfil_task t
      join public.sla_stage st on st.stage_key = t.stage_key
      left join public.orders o on o.id = t.order_id
      left join public.order_stage_history h
             on h.order_id = t.order_id and h.stage_key = t.stage_key and h.left_at is null
      left join lateral (
             select f.sla_minutes from public.sla_config f
              where f.stage_key = t.stage_key and f.is_active
                and (f.zone_id = t.zone_id or f.zone_id is null)
              order by (f.zone_id is null) limit 1) cfgx on true
     where t.worker_id = v_worker
       and (t.done_at is null
            or t.done_at >= (now() at time zone 'Asia/Kolkata')::date)
  ) q;

  return jsonb_build_object(
    'ok', true,
    'title',       public._c('ft.my_title'),
    'subtitle',    public._c('ft.my_subtitle'),
    'empty_label', public._c('ft.my_empty'),
    'worker_id',   v_worker,
    'rows',        coalesce(v_rows, '[]'::jsonb));
end $fn$;

-- ── start / finish, and the guard ───────────────────────────────────────────
create or replace function public.fulfil_task_start(p_task_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare t record; v_worker bigint := public.my_fulfil_worker_id();
begin
  select * into t from public.fulfil_task where id = p_task_id;
  if not found then
    return jsonb_build_object('ok',false,'error','no_task','tone','danger',
      'message', public._c('ft.err_no_task'));
  end if;
  if v_worker is null or t.worker_id is distinct from v_worker then
    if not public._c707_can('write') then
      return jsonb_build_object('ok',false,'error','not_yours','tone','danger',
        'message', public._c('ft.not_authorized'));
    end if;
  end if;
  update public.fulfil_task set started_at = coalesce(started_at, now()), updated_at = now()
   where id = p_task_id;
  return jsonb_build_object('ok',true,'tone','success',
    'message', public._c('ft.started_ok'), 'task', public._c707_task_block(p_task_id));
end $fn$;

-- THE GUARD, and the whole of it: a stage is closed by the worker it was given
-- to. Anyone else needs partner write, and that close is stamped as an
-- override with the name it was taken from — never a silent reassignment.
create or replace function public.fulfil_task_finish(
  p_task_id bigint, p_override_reason text default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  t record; w record; v_worker bigint := public.my_fulfil_worker_id(); v_override boolean := false;
begin
  select * into t from public.fulfil_task where id = p_task_id;
  if not found then
    return jsonb_build_object('ok',false,'error','no_task','tone','danger',
      'message', public._c('ft.err_no_task'));
  end if;
  if t.done_at is not null then
    return jsonb_build_object('ok',true,'tone','success',
      'message', public._c('ft.finished_ok'), 'task', public._c707_task_block(p_task_id));
  end if;

  if t.worker_id is not null then
    select coalesce(nullif(btrim(coalesce(display_name,'')),''), identity) as name
      into w from public.partner_worker where id = t.worker_id;
  end if;

  if t.worker_id is null or v_worker is distinct from t.worker_id then
    if not public._c707_can('write') then
      return jsonb_build_object('ok',false,'error','not_yours','tone','danger',
        'message', public._cf('ft.err_not_yours',
                     jsonb_build_object('worker', coalesce(w.name, public._c('ft.unassigned')))));
    end if;
    v_override := (t.worker_id is not null);
  end if;

  update public.fulfil_task
     set done_at    = now(),
         started_at = coalesce(started_at, now()),
         override_by     = case when v_override then public._c707_actor() else override_by end,
         override_at     = case when v_override then now() else override_at end,
         override_reason = case when v_override then nullif(btrim(coalesce(p_override_reason,'')),'')
                                else override_reason end,
         updated_at = now()
   where id = p_task_id;

  if v_override then
    perform public.partner_audit('partner.fulfil_tasks','task_override_close',
      jsonb_build_object('task_id', p_task_id, 'assigned_worker', t.worker_id,
                         'reason', p_override_reason,
                         'summary', 'Closed ' || t.stage_key || ' assigned to ' || coalesce(w.name,'—')));
    return jsonb_build_object('ok',true,'tone','warning','override',true,
      'message', public._cf('ft.override_ok', jsonb_build_object('worker', coalesce(w.name,'—'))),
      'task', public._c707_task_block(p_task_id));
  end if;

  return jsonb_build_object('ok',true,'tone','success','override',false,
    'message', public._c('ft.finished_ok'), 'task', public._c707_task_block(p_task_id));
end $fn$;

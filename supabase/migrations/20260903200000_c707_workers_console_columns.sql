-- CHANGE #707 (4/4) — the productivity columns, on the screen that already
-- lists the workers.
--
-- Spec item 3 asks for tasks done, items/hour, count-variance rate and pack
-- errors "per worker per day", and asks for them on the partner console's
-- Workers screen. fulfil_worker_productivity() already computes them, but a
-- number that lives in a second RPC is a number the Workers screen would have
-- to JOIN in Dart — and joining two payloads by worker_id is exactly the kind
-- of decision that does not belong in the app. So the math moves into ONE
-- set-returning helper and both callers read it:
--
--   _c707_prod_rows()            -- the arithmetic, once
--     -> fulfil_worker_productivity()  (the standalone report, unchanged shape)
--     -> partner_workers_console()     (a `productivity` block per row)
--
-- Two fixes ride along, both found by reading the helper against real data:
--
-- 1. `count(*) filter (where t.done_at is null)` over a LEFT JOIN counts the
--    WORKER row when a worker has no tasks at all, so every idle worker
--    reported "1 open". It is count(t.id) — the task, not the outer row.
-- 2. items_per_hour divided by held_hours accumulated from `coalesce(t.done_at,
--    now())`, so an open task inflated the denominator forever. Only CLOSED
--    tasks contribute to the rate now; the open ones are reported as the open
--    count, which is what they are.
--
-- Everything the screen prints is still a finished string: the labels, the
-- '—' for "no measurement yet", the '%' on the variance. Dart formats none of
-- it.

-- ── the arithmetic, in one place ────────────────────────────────────────────
create or replace function public._c707_prod_rows(
  p_partner bigint default null, p_days integer default 1)
returns table(worker_id bigint, name text, tasks_done int, block jsonb)
language sql
stable security definer set search_path to 'public' as $fn$
  with b as (
    select ((now() at time zone 'Asia/Kolkata')::date)
             - (greatest(coalesce(p_days,1),1) - 1) as v_from
  ),
  agg as (
    select w.id,
           coalesce(nullif(btrim(coalesce(w.display_name,'')),''), w.identity) as nm,
           count(t.id) filter (where t.done_at is not null)::int  as tasks_done,
           count(t.id) filter (where t.done_at is null)::int      as tasks_open,
           coalesce(sum(t.items_touched), 0)::numeric             as items,
           -- Only a CLOSED task has a duration. An open one is still running,
           -- so counting now() - started_at into the denominator makes the
           -- rate fall for as long as nobody finishes.
           coalesce(sum(extract(epoch from (t.done_at
                       - coalesce(t.started_at, t.assigned_at, t.created_at))))
                    filter (where t.done_at is not null), 0)::numeric / 3600.0
                                                                   as held_hours,
           coalesce(sum(t.items_touched) filter (where t.done_at is not null), 0)::numeric
                                                                   as items_done,
           -- Count variance and pack errors are read off the ITEMS the worker
           -- actually stamped, not off the task: the dispute is raised against
           -- the line, so the line is where the truth is.
           (select count(*) from public.order_items oi, b
             where oi.received_by = w.identity
               and oi.received_at >= b.v_from)::numeric            as counted_lines,
           (select count(*) from public.order_items oi, b
             where oi.received_by = w.identity
               and oi.received_at >= b.v_from
               and coalesce(oi.count_diff, 0) <> 0)::numeric       as variance_lines,
           (select count(*) from public.order_items oi
             where oi.packed_by = w.identity
               and coalesce(oi.count_mismatch, false))::int        as pack_errors
      from public.partner_worker w
      left join public.fulfil_task t
             on t.worker_id = w.id
            and (t.done_at is null
                 or (t.done_at at time zone 'Asia/Kolkata')::date >= (select v_from from b))
     where w.is_active and (p_partner is null or w.partner_id = p_partner)
     group by w.id, w.display_name, w.identity
  )
  select a.id, a.nm, a.tasks_done,
         jsonb_build_object(
           'worker_id',         a.id,
           'name',              a.nm,
           'tasks_done',        a.tasks_done,
           'tasks_open',        a.tasks_open,
           'open_label',        public._cf('ft.prod_open',
                                  jsonb_build_object('n', a.tasks_open::text)),
           'items',             a.items,
           'items_per_hour',    case when a.held_hours > 0
                                     then to_char(a.items_done / a.held_hours, 'FM999990.0')
                                     else public._c('ft.prod_none') end,
           'variance_rate',     case when a.counted_lines > 0
                                     then to_char(100.0 * a.variance_lines / a.counted_lines,
                                                  'FM990.0') || '%'
                                     else public._c('ft.prod_none') end,
           'pack_errors',       a.pack_errors,
           'pack_errors_label', case when a.pack_errors = 0 then public._c('ft.prod_none')
                                     else a.pack_errors::text end)
    from agg a
$fn$;

comment on function public._c707_prod_rows(bigint, integer) is
  'CHANGE #707 — per-worker productivity for a partner over the last N IST days. '
  'The single source for fulfil_worker_productivity() and the Workers console.';

-- ── the standalone report, now reading the shared helper ────────────────────
create or replace function public.fulfil_worker_productivity(p_days integer default 1)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_partner bigint := public.my_partner_id(); v_rows jsonb;
begin
  if not public._c707_can('read') then
    return jsonb_build_object('ok', false, 'error','not_authorized','tone','danger',
      'message', public._c('ft.not_authorized'), 'rows','[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(p.block order by p.tasks_done desc, lower(p.name)), '[]'::jsonb)
    into v_rows
    from public._c707_prod_rows(v_partner, p_days) p;

  return jsonb_build_object(
    'ok', true,
    'title',          public._c('ft.workers_title'),
    'tasks_label',    public._c('ft.prod_tasks'),
    'items_label',    public._c('ft.prod_items'),
    'variance_label', public._c('ft.prod_variance'),
    'packerr_label',  public._c('ft.prod_packerr'),
    'days',           greatest(coalesce(p_days,1),1),
    'rows',           coalesce(v_rows,'[]'::jsonb));
end $fn$;

-- ── the Workers console gains the columns ───────────────────────────────────
-- Reproduced whole because that is what CREATE OR REPLACE means. Byte-identical
-- to the live definition apart from the block marked #707.
CREATE OR REPLACE FUNCTION public.partner_workers_console()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_pid bigint := public.my_partner_id(); v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if v_pid is null or not public.partner_can('partner.workers','read') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pop_c('wk.err_not_authorized'));
  end if;
  return jsonb_build_object(
    'ok', true,
    'screen_title', public._pop_c('wk.title'),
    'intro',        public._pop_c('wk.intro'),
    'can_write',    public.partner_can('partner.workers','write'),
    'add_label',    public._pop_c('wk.add'),
    'remove_label', public._pop_c('wk.remove'),
    'identity_hint',public._pop_c('wk.identity_hint'),
    'name_hint',    public._pop_c('wk.name_hint'),
    'role_label',   public._pop_c('wk.role_label'),
    'empty_text',   public._pop_c('wk.empty'),
    'shift_title',  public._pop_c('wk.shift_title'),
    'shift_hint',   public._pop_c('wk.shift_hint'),
    'today_label',  public.ist_fmt(v_today::timestamptz,'dmy'),
    -- CHANGE #707. The column headings for the productivity block each row now
    -- carries. They are here rather than in the row so the screen can draw a
    -- header once, and they are the SAME strings the standalone report uses.
    'prod_title',    public._c('ft.workers_title'),
    'prod_tasks_label',   public._c('ft.prod_tasks'),
    'prod_items_label',   public._c('ft.prod_items'),
    'prod_variance_label',public._c('ft.prod_variance'),
    'prod_packerr_label', public._c('ft.prod_packerr'),
    -- The role and attendance options are DATA: a new option is one insert.
    'role_options', jsonb_build_array(
       jsonb_build_object('value','counting','label',public._pop_c('wk.role_counting')),
       jsonb_build_object('value','packing', 'label',public._pop_c('wk.role_packing')),
       jsonb_build_object('value','both',    'label',public._pop_c('wk.role_both'))),
    'shift_options', jsonb_build_array(
       jsonb_build_object('value','present','label',public._pop_c('wk.shift_present'),'tone','success'),
       jsonb_build_object('value','half',   'label',public._pop_c('wk.shift_half'),   'tone','warning'),
       jsonb_build_object('value','absent', 'label',public._pop_c('wk.shift_absent'), 'tone','danger')),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', w.id,
               'name', coalesce(nullif(btrim(coalesce(w.display_name,'')),''), w.identity),
               'identity', w.identity,
               'role', w.work_role,
               'role_label', public._pop_c('wk.role_' || w.work_role),
               'shift', coalesce(s.status,''),
               'shift_label', case when s.status is null then public._pop_c('wk.shift_unmarked')
                                   else public._pop_c('wk.shift_' || s.status) end,
               'shift_tone', case s.status when 'present' then 'success'
                                           when 'half'    then 'warning'
                                           when 'absent'  then 'danger'
                                           else 'neutral' end,
               -- CHANGE #707 — today's numbers for this worker, already worded.
               'productivity', p.block)
             order by lower(coalesce(nullif(btrim(coalesce(w.display_name,'')),''), w.identity)))
        from partner_worker w
        left join partner_worker_shift s on s.worker_id = w.id and s.shift_date = v_today
        left join public._c707_prod_rows(v_pid, 1) p on p.worker_id = w.id
       where w.partner_id = v_pid and w.is_active), '[]'::jsonb));
end $function$;

comment on function public.partner_workers_console() is
  'Partner Workers console. CHANGE #707 added a per-row productivity block '
  '(tasks, items/hour, count-variance rate, pack errors) from _c707_prod_rows().';

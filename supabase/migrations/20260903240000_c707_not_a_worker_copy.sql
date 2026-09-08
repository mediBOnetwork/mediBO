-- CHANGE #707 (8/8) — the worker's list refuses in the WRONG WORDS.
--
-- Driving /admin/go/my_tasks as an office admin painted the screen correctly
-- and printed "You do not have access to the task board." on it. That is
-- ft.not_authorized — the BOARD's refusal — reused by fulfil_my_tasks() for a
-- caller who simply is not a worker. Two different refusals wearing one
-- sentence: the reader is told they lack a permission when what has actually
-- happened is that this screen is somebody else's.
--
-- Caught by looking at the screenshot rather than at the exit code: the probe
-- passed, the route painted, the guard fired — and the words were wrong.

insert into public.ui_copy (key, value)
values ('ft.not_a_worker',
        to_jsonb('This list is for counting and packing staff. Your login is not on a worker roster.'::text))
on conflict (key) do update set value = excluded.value;

create or replace function public.fulfil_my_tasks()
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_worker bigint := public.my_fulfil_worker_id(); v_rows jsonb;
begin
  if v_worker is null then
    -- NOT ft.not_authorized: nothing is being withheld. This screen belongs to
    -- a worker and the caller is not one, which is a different sentence.
    return jsonb_build_object('ok', false, 'error', 'not_a_worker', 'tone','warning',
      'title', public._c('ft.my_title'), 'message', public._c('ft.not_a_worker'),
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

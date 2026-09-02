-- CHANGE #643 (4/5) — one runner tick instead of four polls.
--
-- Measured: /dev_commands was hit 121,290 times a day by 8 runner slots, and
-- ~40k requests a week 404'd against RPCs that do not exist. Every worker slot
-- was making the same four requests on a loop:
--   1. dev_ctl_get()                      — is the workflow on?
--   2. /dev_commands?status=building&…    — which row is this slot building?
--   3. /dev_command_messages?…&limit=1    — the message-id baseline
--   4. /dev_command_messages?…&id=gt.N    — has Om replied?
-- dev_runner_tick(agent, since_msg_id) answers all four in ONE call, so the
-- bridge and the runner loop each drop from 2-3 requests a tick to 1.
--
-- It is a READ. It claims nothing, writes nothing and takes no lock — claiming
-- stays dev_cmd_claim and beating stays dev_cmd_heartbeat, because those must
-- keep their own SKIP LOCKED / spool semantics.

create or replace function public.dev_runner_tick(
  p_agent        text,
  p_since_msg_id bigint default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_ctl jsonb; c dev_commands%rowtype; v_msgs jsonb; v_max bigint;
        v_pending int; v_host text; v_active text;
begin
  perform _dev_guard();

  v_ctl := public.dev_ctl_get();

  -- the row THIS slot is building (newest heartbeat wins when a slot somehow
  -- holds more than one — the one it is really working is the one beating)
  select * into c
  from dev_commands
  where status = 'building' and claimed_by = p_agent
  order by heartbeat_at desc nulls last
  limit 1;

  if found then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', m.id, 'sender', m.sender, 'body', m.body,
             'created_at', m.created_at,
             'images', coalesce(m.images, '[]'::jsonb),
             'attachments', coalesce(m.attachments, '[]'::jsonb)) order by m.id), '[]'::jsonb)
      into v_msgs
    from (
      select * from dev_command_messages
      where command_id = c.id
        and sender in ('om','system')
        and (p_since_msg_id is null or id > p_since_msg_id)
      order by id
      limit 5
    ) m;

    select max(id) into v_max from dev_command_messages where command_id = c.id;
  else
    v_msgs := '[]'::jsonb;
  end if;

  select count(*) into v_pending from dev_commands where status = 'pending';

  v_active := coalesce(nullif(v_ctl #>> '{pool,config,active_host}', ''),
                       (select value #>> '{active_host}'
                          from dev_runner_config where key = 'worker_pool'), '');

  return jsonb_build_object(
    'ok', true,
    'agent', p_agent,
    'server_time', now(),
    'ctl', v_ctl,
    'workflow', coalesce(v_ctl #>> '{desired_state,workflow}', 'on'),
    'active_host', v_active,
    'pending_count', v_pending,
    'building', case when c.id is null then null else jsonb_build_object(
        'id', c.id, 'title', c.title, 'status', c.status,
        'started_at', c.started_at, 'heartbeat_at', c.heartbeat_at) end,
    'max_msg_id', coalesce(v_max, 0),
    'messages', v_msgs,
    'message_count', jsonb_array_length(v_msgs));
end $$;

grant execute on function public.dev_runner_tick(text, bigint) to service_role;

comment on function public.dev_runner_tick(text, bigint) is
  'CHANGE #643: one read per runner tick — control switch, this slot''s building '
  'row, Om''s unseen replies and the pending depth. Replaces four REST polls.';

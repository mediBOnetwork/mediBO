-- CHANGE #398 (4/4) — THE EVENING ZONE DIGEST.
--
-- A partner works the queue all day and has, at 8pm, no answer to "how did
-- today go?" — how many orders landed, how many went out, what was collected,
-- and what their share of it is. One message per partner per zone per day,
-- composed in SQL, sent through notify_partner() (push first, WhatsApp behind
-- it) and RECORDED, so the same evening can never be sent twice.
--
-- It rides the ONE cron dispatcher (CHANGE #305 / #273). No new pg_cron job,
-- and no bare */N schedule — the outage of 2026-08-18 was 35 jobs all starting
-- on minute 0.

create table if not exists public.partner_digest_log (
  id           bigserial primary key,
  partner_id   bigint  not null,
  zone_id      smallint,
  digest_date  date    not null,
  orders_received int  not null default 0,
  orders_delivered int not null default 0,
  collected    numeric not null default 0,
  partner_share numeric not null default 0,
  body         text    not null default '',
  send_result  jsonb   not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);
create unique index if not exists partner_digest_log_once
  on public.partner_digest_log(partner_id, digest_date);
alter table public.partner_digest_log enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public'
                   and tablename='partner_digest_log' and policyname='partner_digest_own') then
    create policy partner_digest_own on public.partner_digest_log
      for select to authenticated
      using (partner_id = public.my_partner_id() or public.is_admin());
  end if;
end $$;

-- The digest's wording, as data.
insert into public.app_settings(key, value)
values ('partner_digest_copy', jsonb_build_object(
  'title',  'Today in {{zone}}',
  'line',   '{{received}} received · {{delivered}} delivered · {{collected}} collected',
  'share',  'Your share today: {{share}}',
  'share_pending', 'Your share is calculated when the day settles.',
  'empty',  'No orders in your zone today.'))
on conflict (key) do nothing;

-- ── The numbers ─────────────────────────────────────────────────────────────
-- partner_settlements is the ONLY source for the share (CHANGE #323 owns that
-- arithmetic — this never recomputes a split). Until a day has settlement rows
-- the digest says so in the backend's own words rather than printing ₹0, which
-- would read as "you earned nothing today".
create or replace function public.partner_digest_data(p_partner bigint, p_date date)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_zone smallint; v_recv int; v_deliv int; v_coll numeric; v_share numeric;
  v_has_share boolean; v_zname text;
begin
  select rp.zone_id::smallint into v_zone from region_partners rp where rp.id = p_partner;
  select z.name into v_zname from zones z where z.id = v_zone;

  select count(*) into v_recv
    from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
   where coalesce(o.zone_id, pp.zone_id) = v_zone
     and (o.created_at at time zone 'Asia/Kolkata')::date = p_date;

  select count(*) into v_deliv
    from deliveries d join orders o on o.id = d.order_id
    left join pharmacy_profiles pp on pp.id = o.customer_id
   where coalesce(d.zone_id, o.zone_id, pp.zone_id) = v_zone
     and coalesce(lower(d.status),'') = 'delivered'
     and (coalesce(d.delivered_at, d.created_at) at time zone 'Asia/Kolkata')::date = p_date;

  select coalesce(sum(pc.amount),0) into v_coll
    from payment_claims pc
   where pc.status = 'verified'
     and coalesce(pc.zone_id, v_zone) = v_zone
     and (coalesce(pc.paid_ts, pc.received_at, pc.created_at) at time zone 'Asia/Kolkata')::date = p_date;

  select coalesce(sum(ps.partner_share),0), count(*) > 0
    into v_share, v_has_share
    from partner_settlements ps
   where ps.partner_id = p_partner and ps.order_date = p_date;

  return jsonb_build_object(
    'partner_id', p_partner, 'zone_id', v_zone,
    'zone_label', coalesce(v_zname,''), 'the_date', p_date,
    'orders_received', v_recv, 'orders_delivered', v_deliv,
    'collected', v_coll, 'collected_display', public.inr_money(v_coll),
    'partner_share', v_share, 'share_display', public.inr_money(v_share),
    'has_share', coalesce(v_has_share,false),
    'has_any', (v_recv + v_deliv) > 0 or v_coll > 0);
end $function$;

-- ── The send ────────────────────────────────────────────────────────────────
create or replace function public.partner_daily_digest(p_date date default null,
                                                       p_partner bigint default null,
                                                       p_force boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Kolkata')::date);
  v_copy jsonb := coalesce((select value from app_settings where key='partner_digest_copy'),'{}'::jsonb);
  rp record; d jsonb; v_body text; v_res jsonb;
  v_sent int := 0; v_skipped int := 0; v_out jsonb := '[]'::jsonb;
begin
  for rp in
    select r.id, r.zone_id from region_partners r
     where coalesce(r.is_active,true)
       and (p_partner is null or r.id = p_partner)
       and r.zone_id is not null
     order by r.id
  loop
    if not p_force and exists (select 1 from partner_digest_log l
                                where l.partner_id = rp.id and l.digest_date = v_date) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    d := public.partner_digest_data(rp.id, v_date);

    if coalesce((d->>'has_any')::boolean,false) then
      v_body := public.notif_render(coalesce(v_copy->>'line',''), jsonb_build_object(
                  'received',  (d->>'orders_received'),
                  'delivered', (d->>'orders_delivered'),
                  'collected', (d->>'collected_display')))
                || E'\n'
                || case when coalesce((d->>'has_share')::boolean,false)
                        then public.notif_render(coalesce(v_copy->>'share',''),
                               jsonb_build_object('share', d->>'share_display'))
                        else coalesce(v_copy->>'share_pending','') end;
    else
      v_body := coalesce(v_copy->>'empty','');
    end if;

    begin
      v_res := public.notify_partner('partner_daily_digest', jsonb_build_object(
                 'partner_id', rp.id::text,
                 'zone_id',    coalesce(rp.zone_id,0)::text,
                 'zone',       coalesce(d->>'zone_label',''),
                 'received',   (d->>'orders_received'),
                 'delivered',  (d->>'orders_delivered'),
                 'collected',  (d->>'collected_display'),
                 'share',      case when coalesce((d->>'has_share')::boolean,false)
                                    then (d->>'share_display')
                                    else coalesce(v_copy->>'share_pending','') end,
                 'summary',    v_body));
    exception when others then
      v_res := jsonb_build_object('ok', false, 'reason','send_exception', 'message', sqlerrm);
    end;

    insert into partner_digest_log
      (partner_id, zone_id, digest_date, orders_received, orders_delivered,
       collected, partner_share, body, send_result)
    values (rp.id, rp.zone_id, v_date,
            (d->>'orders_received')::int, (d->>'orders_delivered')::int,
            (d->>'collected')::numeric, (d->>'partner_share')::numeric,
            v_body, coalesce(v_res,'{}'::jsonb))
    on conflict (partner_id, digest_date) do update
      set orders_received = excluded.orders_received,
          orders_delivered = excluded.orders_delivered,
          collected = excluded.collected,
          partner_share = excluded.partner_share,
          body = excluded.body,
          send_result = excluded.send_result;

    v_sent := v_sent + 1;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
               'partner_id', rp.id, 'zone_id', rp.zone_id,
               'body', v_body, 'send', v_res));
  end loop;

  return jsonb_build_object('ok', true, 'the_date', v_date,
    'sent', v_sent, 'skipped_already_sent', v_skipped, 'digests', v_out);
end $function$;

revoke all on function public.partner_daily_digest(date, bigint, boolean) from public, anon, authenticated;
grant execute on function public.partner_daily_digest(date, bigint, boolean) to service_role;

-- The digest is its own event, so its wording and its push are configured like
-- every other notification rather than being hard-coded into the job.
insert into public.wa_event_routes
  (event_key, label, description, audience, enabled, push_enabled, email_enabled,
   auto_manage, wa_category, deep_link_kind, push_title, push_body)
values
  ('partner_daily_digest', 'Partner · evening digest',
   'The end-of-day summary for a partner''s zone.', 'partner', true, true, false,
   false, 'utility', '/partner', 'Today in {{zone}}', '{{summary}}')
on conflict (event_key) do update
  set audience = excluded.audience, push_enabled = excluded.push_enabled,
      deep_link_kind = excluded.deep_link_kind,
      push_title = excluded.push_title, push_body = excluded.push_body;

-- ── Registered on the ONE dispatcher, at an offset minute ───────────────────
insert into public.cron_task (name, ord, mode, work_sql, enabled, note, run_at_ist)
values ('partner-daily-digest', 720, 'poll',
        'select public.partner_daily_digest()', true,
        'CHANGE #398 — one evening summary per partner per zone. Idempotent: '
        'partner_digest_log has a unique (partner_id, digest_date), so a second '
        'run the same day sends nothing.',
        time '20:35')
on conflict (name) do update
  set work_sql = excluded.work_sql, enabled = excluded.enabled,
      run_at_ist = excluded.run_at_ist, note = excluded.note;

-- ── Recorded verification ───────────────────────────────────────────────────
create or replace function public.c398_digest_proof()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'task', (select jsonb_build_object('name',name,'mode',mode,'at',run_at_ist::text,
                                       'enabled',enabled,'work',work_sql)
               from cron_task where name='partner-daily-digest'),
    'route', (select push_title from wa_event_routes where event_key='partner_daily_digest'),
    'new_pg_cron_jobs', (select count(*) from cron.job where jobname like '%partner_digest%'),
    'digest_rows', (select count(*) from partner_digest_log),
    'today', (select jsonb_build_object('received', d->>'orders_received',
                                        'delivered', d->>'orders_delivered',
                                        'collected', d->>'collected_display',
                                        'has_share', d->>'has_share')
                from (select public.partner_digest_data(
                        (select id from region_partners where coalesce(is_active,true)
                          order by id limit 1),
                        (now() at time zone 'Asia/Kolkata')::date) as d) s))
$function$;
grant execute on function public.c398_digest_proof() to service_role;

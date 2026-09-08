-- CHANGE — cmd #433: the monthly waste scan, on the cloud that actually exists.
--
-- gcp_schedules row 3 ("Monthly waste scan") has been enqueueing a command that
-- asked for `gcloud compute disks list` every month. There is no gcloud on this
-- box, no GCP project behind it and `.gcp_capability_off` is present, so
-- `gcp_waste_scan.sh` printed "Google setup pending" and the scan reported
-- nothing, every month — exactly the failure #289 found in the weekly snapshot.
--
-- The four categories the spec asks for map one-for-one onto the real estate:
--   unattached disks   -> EBS volumes in state `available`
--   unused static IPs  -> Elastic IPs with no association
--   prunable snapshots -> EBS snapshots past keep / max_age_days
--   orphan buckets     -> Supabase Storage buckets (and S3, when the key can
--                         read them) that are empty or long stale
--
-- Division of labour: the edge function `cloud-waste-scan` holds the AWS key
-- and returns RAW FACTS. Every rupee, every label and every sentence is
-- composed HERE, from `cloud_waste_rates` and `ui_copy`, so a price change or a
-- wording change is an UPDATE and never a deploy. Nothing in this file deletes
-- anything: the scan is read-only by contract.

-- ── rates: INR per month, editable with no deploy ───────────────────────────
insert into dev_runner_config (key, value) values (
  'cloud_waste_rates',
  jsonb_build_object(
    'currency','INR',
    'ebs_inr_per_gb_month', 8,
    'eip_inr_per_month', 320,
    'snapshot_inr_per_gb_month', 4.4,
    'storage_inr_per_gb_month', 2,
    'storage_included_gb', 100,
    'bucket_stale_days', 90,
    'snapshot_keep', 4,
    'snapshot_max_age_days', 28,
    'note','ap-south-1 list prices converted to INR, rounded up. Edit the numbers here; the scan re-prices with no deploy.'
  )
) on conflict (key) do nothing;

-- ── every human-facing string ───────────────────────────────────────────────
insert into ui_copy (key, value) values
  ('dev_queue.waste_title',        to_jsonb('Unused cloud resources'::text)),
  ('dev_queue.waste_sub',          to_jsonb('Read-only scan. Nothing is ever deleted by it.'::text)),
  ('dev_queue.waste_never',        to_jsonb('Not scanned yet. The scan runs on the 1st of each month, or tap Scan now.'::text)),
  ('dev_queue.waste_btn',          to_jsonb('Scan now'::text)),
  ('dev_queue.waste_ran',          to_jsonb('Scanned {when} · {cloud} {region}'::text)),
  ('dev_queue.waste_total',        to_jsonb('₹{amount}/month if all of it were removed'::text)),
  ('dev_queue.waste_total_zero',   to_jsonb('Nothing reclaimable found — ₹0/month'::text)),
  ('dev_queue.waste_footer',       to_jsonb('Nothing was deleted. Every line above is a suggestion for you to act on.'::text)),
  ('dev_queue.waste_amount',       to_jsonb('₹{amount}/mo'::text)),
  ('dev_queue.waste_free',         to_jsonb('₹0/mo'::text)),
  ('dev_queue.waste_disks',        to_jsonb('Unattached disks'::text)),
  ('dev_queue.waste_disks_none',   to_jsonb('No unattached disks — every volume is in use.'::text)),
  ('dev_queue.waste_disk_row',     to_jsonb('{id} · {size} GB · {zone}'::text)),
  ('dev_queue.waste_ips',          to_jsonb('Reserved but unused IP addresses'::text)),
  ('dev_queue.waste_ips_none',     to_jsonb('No idle IP addresses — every reserved address is attached.'::text)),
  ('dev_queue.waste_ip_row',       to_jsonb('{ip} · reserved, attached to nothing'::text)),
  ('dev_queue.waste_snaps',        to_jsonb('Snapshots past the keep rule'::text)),
  ('dev_queue.waste_snaps_none',   to_jsonb('No prunable snapshots — the newest {keep} are kept and none is older than {days} days.'::text)),
  ('dev_queue.waste_snap_row',     to_jsonb('{name} · {size} GB · {age} days old'::text)),
  ('dev_queue.waste_buckets',      to_jsonb('Buckets worth reviewing'::text)),
  ('dev_queue.waste_buckets_none', to_jsonb('No orphan buckets — every bucket holds recent files.'::text)),
  ('dev_queue.waste_bucket_empty', to_jsonb('{name} · empty, never used'::text)),
  ('dev_queue.waste_bucket_stale', to_jsonb('{name} · {size} · nothing new for {age} days'::text)),
  ('dev_queue.waste_bucket_ok',    to_jsonb('{name} · {size} · in active use'::text)),
  ('dev_queue.waste_storage_free', to_jsonb('Storage is {used} of the {included} GB included in the plan, so it costs nothing extra today.'::text)),
  ('dev_queue.waste_storage_over', to_jsonb('Storage is {used}, over the {included} GB included in the plan.'::text)),
  ('dev_queue.waste_denied',       to_jsonb('Cannot read this — the saved AWS key is missing {action}.'::text)),
  ('dev_queue.waste_denied_fix',   to_jsonb('Add {actions} to the IAM policy for the key used by the builder, then scan again.'::text)),
  ('dev_queue.waste_no_key',       to_jsonb('AWS access key not saved yet, so the EC2 half of the scan was skipped. Add AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY under Secrets.'::text)),
  ('dev_queue.waste_not_aws',      to_jsonb('The builder is not on AWS right now, so only the storage half of the scan ran.'::text)),
  ('dev_queue.waste_error',        to_jsonb('AWS rejected the read: {detail}'::text))
on conflict (key) do nothing;

-- ── storage facts: always readable, no cloud credential involved ────────────
create or replace function public.cloud_waste_storage()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', t.id,
           'objects', t.objects,
           'bytes', t.bytes,
           'last_object_at', t.last_object,
           'idle_days', case when t.last_object is null then null
                             else floor(extract(epoch from (now() - t.last_object)) / 86400)::int end
         ) order by t.bytes desc, t.id), '[]'::jsonb)
  from (
    select b.id,
           count(o.id)::int as objects,
           coalesce(sum((o.metadata->>'size')::bigint), 0)::bigint as bytes,
           max(o.created_at) as last_object
    from storage.buckets b
    left join storage.objects o on o.bucket_id = b.id
    group by b.id
  ) t;
$$;

-- ── size formatting, in one place ───────────────────────────────────────────
create or replace function public._waste_size(p_bytes bigint)
returns text
language sql
immutable
as $$
  select case
    when p_bytes is null or p_bytes = 0 then '0 MB'
    when p_bytes >= 1073741824 then round(p_bytes::numeric / 1073741824, 1)::text || ' GB'
    when p_bytes >= 1048576    then round(p_bytes::numeric / 1048576, 0)::text || ' MB'
    else round(p_bytes::numeric / 1024, 0)::text || ' KB'
  end;
$$;

-- Rupees, formatted once, in the backend. Whole rupees: a waste estimate with
-- paise in it reads like a bill, and it is not one.
create or replace function public._waste_inr(p_amount numeric)
returns text
language sql
stable
as $$
  select case when coalesce(p_amount,0) <= 0
              then public._c('dev_queue.waste_free')
              else public._cf('dev_queue.waste_amount',
                     jsonb_build_object('amount', to_char(round(p_amount), 'FM999,999,999')))
         end;
$$;

-- One group, assembled in one place — because the denied case is the one every
-- renderer would otherwise get wrong. A group we were NOT ALLOWED TO READ has
-- no rows, and a generic "no unattached disks" empty state would then assert,
-- in the app and in the scan's own message, that we looked and found nothing.
-- We did not look. So when a group is blocked the refusal IS the empty state,
-- and `blocked` lets the card tone it as a gap rather than a clean bill.
create or replace function public._waste_group(
  p_key text, p_title text, p_rows jsonb, p_blocked_note text,
  p_note text, p_empty text, p_subtotal numeric)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'key', p_key,
    'title', p_title,
    'rows', coalesce(p_rows, '[]'::jsonb),
    'blocked', p_blocked_note is not null,
    'note', p_note,
    'empty_label', coalesce(p_blocked_note, p_empty),
    'subtotal_display', public._waste_inr(p_subtotal));
$$;

-- ── compose: raw AWS facts + storage + rates -> the rendered payload ────────
-- p_aws is exactly what the edge function saw, and nothing more:
--   {ok, region, cloud, key_present, volumes[], addresses[], snapshots[],
--    denied[], errors[]}
create or replace function public.cloud_waste_compose(p_aws jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_rates   jsonb := coalesce((select value from dev_runner_config where key='cloud_waste_rates'), '{}'::jsonb);
  v_ebs     numeric := coalesce((v_rates->>'ebs_inr_per_gb_month')::numeric, 8);
  v_eip     numeric := coalesce((v_rates->>'eip_inr_per_month')::numeric, 320);
  v_snap    numeric := coalesce((v_rates->>'snapshot_inr_per_gb_month')::numeric, 4.4);
  v_store   numeric := coalesce((v_rates->>'storage_inr_per_gb_month')::numeric, 2);
  v_incl    numeric := coalesce((v_rates->>'storage_included_gb')::numeric, 100);
  v_stale   int     := coalesce((v_rates->>'bucket_stale_days')::int, 90);
  v_keep    int     := coalesce((v_rates->>'snapshot_keep')::int, 4);
  v_maxage  int     := coalesce((v_rates->>'snapshot_max_age_days')::int, 28);
  v_denied  text[]  := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p_aws->'denied','[]'::jsonb)) x), '{}');
  v_groups  jsonb   := '[]'::jsonb;
  v_rows    jsonb;
  v_sub     numeric;
  v_total   numeric := 0;
  v_note    text;
  v_bytes   bigint;
  v_gb      numeric;
  v_state   jsonb;
  r         record;
begin
  -- helper for a whole group that could not be read at all
  -- (each block builds v_rows / v_sub / v_note, then appends.)

  ---------------------------------------------------------------- disks
  v_rows := '[]'::jsonb; v_sub := 0; v_note := null;
  if 'ec2:DescribeVolumes' = any(v_denied) then
    v_note := _cf('dev_queue.waste_denied', jsonb_build_object('action','ec2:DescribeVolumes'));
  else
    for r in select (e->>'id') as id,
                    coalesce((e->>'size_gb')::numeric,0) as size_gb,
                    coalesce(e->>'zone','') as zone
             from jsonb_array_elements(coalesce(p_aws->'volumes','[]'::jsonb)) e
             order by coalesce((e->>'size_gb')::numeric,0) desc
    loop
      v_sub := v_sub + r.size_gb * v_ebs;
      v_rows := v_rows || jsonb_build_object(
        'label', _cf('dev_queue.waste_disk_row', jsonb_build_object(
                   'id', r.id, 'size', trim(to_char(r.size_gb,'FM999999')), 'zone', r.zone)),
        'amount_display', _waste_inr(r.size_gb * v_ebs),
        'copy_text', r.id);
    end loop;
  end if;
  v_total := v_total + v_sub;
  v_groups := v_groups || _waste_group('disks', _c('dev_queue.waste_disks'),
                 v_rows, v_note, null, _c('dev_queue.waste_disks_none'), v_sub);

  ---------------------------------------------------------------- static IPs
  v_rows := '[]'::jsonb; v_sub := 0; v_note := null;
  if 'ec2:DescribeAddresses' = any(v_denied) then
    v_note := _cf('dev_queue.waste_denied', jsonb_build_object('action','ec2:DescribeAddresses'));
  else
    for r in select (e->>'ip') as ip, coalesce(e->>'allocation_id','') as alloc
             from jsonb_array_elements(coalesce(p_aws->'addresses','[]'::jsonb)) e
             order by (e->>'ip')
    loop
      v_sub := v_sub + v_eip;
      v_rows := v_rows || jsonb_build_object(
        'label', _cf('dev_queue.waste_ip_row', jsonb_build_object('ip', r.ip)),
        'amount_display', _waste_inr(v_eip),
        'copy_text', case when r.alloc <> '' then r.alloc else r.ip end);
    end loop;
  end if;
  v_total := v_total + v_sub;
  v_groups := v_groups || _waste_group('ips', _c('dev_queue.waste_ips'),
                 v_rows, v_note, null, _c('dev_queue.waste_ips_none'), v_sub);

  ---------------------------------------------------------------- snapshots
  -- The edge function returns every snapshot it owns, newest first. The keep
  -- rule is applied HERE so it agrees, to the row, with what vm-snapshot
  -- prunes: past the newest `keep`, OR older than `max_age_days`.
  v_rows := '[]'::jsonb; v_sub := 0; v_note := null;
  if 'ec2:DescribeSnapshots' = any(v_denied) then
    v_note := _cf('dev_queue.waste_denied', jsonb_build_object('action','ec2:DescribeSnapshots'));
  else
    for r in select (e->>'id') as id,
                    coalesce(nullif(e->>'name',''), e->>'id') as name,
                    coalesce((e->>'size_gb')::numeric,0) as size_gb,
                    coalesce((e->>'age_days')::int, 0) as age_days,
                    (ord - 1)::int as idx
             from jsonb_array_elements(coalesce(p_aws->'snapshots','[]'::jsonb)) with ordinality as t(e, ord)
             order by ord
    loop
      continue when r.idx < v_keep and r.age_days <= v_maxage;
      v_sub := v_sub + r.size_gb * v_snap;
      v_rows := v_rows || jsonb_build_object(
        'label', _cf('dev_queue.waste_snap_row', jsonb_build_object(
                   'name', r.name, 'size', trim(to_char(r.size_gb,'FM999999')),
                   'age', r.age_days::text)),
        'amount_display', _waste_inr(r.size_gb * v_snap),
        'copy_text', r.id);
    end loop;
  end if;
  v_total := v_total + v_sub;
  v_groups := v_groups || _waste_group('snapshots', _c('dev_queue.waste_snaps'),
                 v_rows, v_note, null,
                 _cf('dev_queue.waste_snaps_none',
                     jsonb_build_object('keep', v_keep::text, 'days', v_maxage::text)),
                 v_sub);

  ---------------------------------------------------------------- buckets
  -- Empty and long-stale buckets. An empty bucket costs nothing, so its amount
  -- is honestly zero — it is listed because it is an orphan, not because it is
  -- expensive. Stale bytes are priced only for what sits ABOVE the plan's
  -- included allowance, which is why the group note says which case applies.
  v_rows := '[]'::jsonb; v_sub := 0;
  select coalesce(sum((e->>'bytes')::bigint),0) into v_bytes
  from jsonb_array_elements(cloud_waste_storage()) e;
  v_gb := round(v_bytes::numeric / 1073741824, 1);
  v_note := case when v_gb <= v_incl
    then _cf('dev_queue.waste_storage_free', jsonb_build_object(
           'used', _waste_size(v_bytes), 'included', trim(to_char(v_incl,'FM999999'))))
    else _cf('dev_queue.waste_storage_over', jsonb_build_object(
           'used', _waste_size(v_bytes), 'included', trim(to_char(v_incl,'FM999999')))) end;

  for r in select (e->>'name') as name,
                  coalesce((e->>'objects')::int,0) as objects,
                  coalesce((e->>'bytes')::bigint,0) as bytes,
                  (e->>'idle_days')::int as idle_days
           from jsonb_array_elements(cloud_waste_storage()) e
           order by coalesce((e->>'bytes')::bigint,0) desc, (e->>'name')
  loop
    if r.objects = 0 then
      v_rows := v_rows || jsonb_build_object(
        'label', _cf('dev_queue.waste_bucket_empty', jsonb_build_object('name', r.name)),
        'amount_display', _waste_inr(0),
        'copy_text', r.name);
    elsif r.idle_days is not null and r.idle_days >= v_stale then
      -- price the bucket's bytes only when the account is over the allowance
      v_sub := v_sub + case when v_gb > v_incl
                            then round(r.bytes::numeric / 1073741824, 2) * v_store else 0 end;
      v_rows := v_rows || jsonb_build_object(
        'label', _cf('dev_queue.waste_bucket_stale', jsonb_build_object(
                   'name', r.name, 'size', _waste_size(r.bytes), 'age', r.idle_days::text)),
        'amount_display', _waste_inr(case when v_gb > v_incl
                            then round(r.bytes::numeric / 1073741824, 2) * v_store else 0 end),
        'copy_text', r.name);
    end if;
  end loop;
  v_total := v_total + v_sub;
  v_groups := v_groups || _waste_group('buckets', _c('dev_queue.waste_buckets'),
                 v_rows, null, v_note, _c('dev_queue.waste_buckets_none'), v_sub);

  ---------------------------------------------------------------- assemble
  v_state := jsonb_build_object(
    'ran_at', now(),
    'cloud', coalesce(p_aws->>'cloud', 'aws'),
    'region', coalesce(p_aws->>'region', ''),
    'groups', v_groups,
    'total_display', case when v_total <= 0
                          then _c('dev_queue.waste_total_zero')
                          else _cf('dev_queue.waste_total',
                                 jsonb_build_object('amount', to_char(round(v_total),'FM999,999,999'))) end,
    'total_inr', round(v_total),
    'footer', _c('dev_queue.waste_footer'),
    'blocked', case when array_length(v_denied,1) is null then null
                    else _cf('dev_queue.waste_denied_fix',
                           jsonb_build_object('actions', array_to_string(v_denied, ', '))) end,
    'denied', to_jsonb(v_denied),
    'warning', case
                 when p_aws ? 'key_present' and (p_aws->>'key_present')::boolean is false
                   then _c('dev_queue.waste_no_key')
                 when p_aws ? 'cloud' and p_aws->>'cloud' <> 'aws'
                   then _c('dev_queue.waste_not_aws')
                 when jsonb_array_length(coalesce(p_aws->'errors','[]'::jsonb)) > 0
                   then _cf('dev_queue.waste_error',
                          jsonb_build_object('detail', p_aws->'errors'->>0))
                 else null end);

  insert into dev_runner_config (key, value) values ('cloud_waste_state', v_state)
  on conflict (key) do update set value = excluded.value;

  return v_state;
end $$;

-- ── read side: what the GCP Control screen draws ────────────────────────────
create or replace function public.dev_cloud_waste_get()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v jsonb := (select value from dev_runner_config where key='cloud_waste_state');
  v_when text;
begin
  perform _dev_guard();
  if v is null then
    return jsonb_build_object(
      'title', _c('dev_queue.waste_title'),
      'subtitle', _c('dev_queue.waste_sub'),
      'button', _c('dev_queue.waste_btn'),
      'has', false,
      'empty_label', _c('dev_queue.waste_never'),
      'groups', '[]'::jsonb);
  end if;
  v_when := to_char((v->>'ran_at')::timestamptz at time zone 'Asia/Kolkata', 'DD Mon, HH12:MI AM');
  return v || jsonb_build_object(
    'title', _c('dev_queue.waste_title'),
    'subtitle', _c('dev_queue.waste_sub'),
    'button', _c('dev_queue.waste_btn'),
    'has', true,
    'ran_label', _cf('dev_queue.waste_ran', jsonb_build_object(
      'when', v_when,
      'cloud', upper(coalesce(v->>'cloud','')),
      'region', coalesce(v->>'region',''))));
end $$;

-- ── hang it off the screen's one payload ────────────────────────────────────
create or replace function public.dev_gcp_get()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v jsonb;
begin
  perform _dev_guard();
  select coalesce(value,'{}') into v from dev_runner_config where key='gcp_status';
  return jsonb_build_object(
    'status', v,
    'uptime', (select jsonb_build_object('state', value->>'state', 'down_count', value->>'down_count', 'last_change', value->>'last_change', 'url', value->>'url') from dev_runner_config where key='uptime'),
    'costs', gcp_costs_get(30),
    'schedules', (select coalesce(jsonb_agg(to_jsonb(g) order by g.hour_ist,g.minute_ist),'[]') from gcp_schedules g),
    'secrets', secret_list(),
    'lessons', dev_lessons_get(NULL),
    'waste', dev_cloud_waste_get(),
    'security', jsonb_build_object('frozen', (_sec_cfg()->>'frozen')::boolean, 'pin_set', (_sec_cfg()->>'pin_hash') is not null,
                                   'daily_cap_inr', (_sec_cfg()->>'daily_cost_cap_inr')::numeric,
                                   'disk_alert_pct', (_sec_cfg()->>'disk_alert_pct')::int),
    'budget', sec_check_budget() - 'over',
    'screen_title','GCP Control');
end $$;

grant execute on function public._waste_group(text,text,jsonb,text,text,text,numeric) to service_role;
grant execute on function public.cloud_waste_storage() to service_role;
grant execute on function public.cloud_waste_compose(jsonb) to service_role;
grant execute on function public.dev_cloud_waste_get() to authenticated, service_role;

-- ── the monthly schedule stops asking for gcloud ────────────────────────────
update gcp_schedules set goal =
  'Run the monthly cloud waste scan: POST {"action":"run"} to the cloud-waste-scan edge function (bash ~/mediBO-runner/gcp_waste_scan.sh run). It is READ-ONLY — it lists unattached EBS volumes, unused Elastic IPs, snapshots past the keep rule, and empty or stale storage buckets, each with the monthly rupee cost, and deletes NOTHING. Report its `message` verbatim and put each line in result_actions as a copy chip. Do NOT use gcloud: the builder is on AWS EC2 and there is no gcloud on the box.'
where id = 3 and label = 'Monthly waste scan';

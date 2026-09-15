-- CHANGE #705 (4/5) — expiry: remind, then block.
--
-- The partner_licence_expiry_sweep pattern, applied to pharmacies and
-- suppliers: one reminder per (owner, kind, expiry, day-bucket) at 30, 7 and 1
-- days, then the document expires and kyc_gate blocks by itself — nothing here
-- flips a flag, because a second copy of "is this account clear?" is how the
-- two answers drift apart. The renew path is the ordinary upload path: a new
-- document supersedes the expired one and the block lifts on its own.
--
-- One cron_task row on the dispatcher. Never a bare */N schedule.
-- Idempotent throughout.

create table if not exists public.kyc_expiry_reminder (
  owner_kind text not null,
  owner_id   uuid not null,
  kind       text not null,
  expiry     date not null,
  bucket_days int not null,
  sent_at    timestamptz not null default now(),
  primary key (owner_kind, owner_id, kind, expiry, bucket_days)
);

comment on table public.kyc_expiry_reminder is
  'CHANGE #705 — one row per reminder actually sent, so a re-run of the sweep '
  'is silent and a re-dated licence is reminded about again (the row is keyed '
  'on the expiry date itself).';

insert into public.ui_copy (key, value) values
  ('kyc_expiry.reminder_title', to_jsonb('Licence expiring'::text)),
  ('kyc_expiry.reminder_body',  to_jsonb('Your {label} expires on {d} ({n} days). Upload the renewed copy to keep trading.'::text)),
  ('kyc_expiry.expired_title',  to_jsonb('Licence expired'::text)),
  ('kyc_expiry.expired_body',   to_jsonb('Your {label} expired on {d}. Upload the renewed copy to start trading again.'::text))
on conflict (key) do nothing;

insert into public.wa_event_routes (event_key, label, description, audience, enabled,
                                    push_enabled, push_title, push_body)
values
  ('kyc_licence_expiring', 'KYC licence expiring',
   'Sent to a pharmacy or supplier 30, 7 and 1 days before an uploaded document expires.',
   'customer', true, true, 'Licence expiring',
   'Your {{label}} expires on {{d}} ({{n}} days). Upload the renewed copy to keep trading.'),
  ('kyc_licence_expired', 'KYC licence expired',
   'Sent to a pharmacy or supplier on the day an uploaded document expires.',
   'customer', true, true, 'Licence expired',
   'Your {{label}} expired on {{d}}. Upload the renewed copy at {{link}} to start trading again.')
on conflict (event_key) do nothing;

create or replace function public.kyc_expiry_sweep()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_cfg   jsonb := coalesce((select value from app_settings where key='kyc_gate'), '{}'::jsonb);
  v_days  int[] := coalesce((select array_agg((x #>> '{}')::int order by (x #>> '{}')::int desc)
                               from jsonb_array_elements(coalesce(v_cfg->'remind_days','[]'::jsonb)) x),
                            array[30,7,1]);
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  r record; v_sent int := 0; v_expired int := 0; v_blocked int := 0;
  v_bucket int; v_label text; v_phone text; v_event text;
begin
  for r in
    select d.id, d.owner_kind, d.owner_id, d.kind, d.valid_to,
           case d.owner_kind when 'pharmacy' then p.pharmacy_name else s.supplier_name end as owner_name,
           case d.owner_kind when 'pharmacy' then coalesce(nullif(p.whatsapp_no,''), p.phone)
                             else coalesce(nullif(s.whatsapp_no,''), s.phone) end as phone
      from kyc_documents d
      left join pharmacy_profiles p on d.owner_kind='pharmacy' and p.id = d.owner_id
      left join supplier_profiles s on d.owner_kind='supplier' and s.id = d.owner_id
     where d.status = 'verified'
       and d.valid_to is not null
       and d.valid_to <= v_today + v_days[1]
  loop
    -- Which bucket is this? The SMALLEST threshold the document has reached,
    -- so a licence 6 days out sends the 7-day reminder once, not the 30 again.
    v_bucket := null;
    if r.valid_to < v_today then
      v_bucket := -1;
    else
      select min(dd) into v_bucket
        from unnest(v_days) dd
       where (r.valid_to - v_today) <= dd;
    end if;
    if v_bucket is null then continue; end if;

    if exists (select 1 from kyc_expiry_reminder m
                where m.owner_kind = r.owner_kind and m.owner_id = r.owner_id
                  and m.kind = r.kind and m.expiry = r.valid_to
                  and m.bucket_days = v_bucket) then
      continue;
    end if;

    v_label := _c('kyc.kind.'||r.kind);
    v_event := case when v_bucket = -1 then 'kyc_licence_expired' else 'kyc_licence_expiring' end;

    -- A missing notification route must never stall the sweep.
    begin
      perform public.wa_send_event(
        v_event,
        case when r.owner_kind = 'pharmacy' then r.owner_id else null end,
        jsonb_build_object('label', v_label, 'name', coalesce(r.owner_name,''),
                           'd', to_char(r.valid_to,'DD/MM/YYYY'),
                           'n', greatest(r.valid_to - v_today, 0)::text,
                           'link', 'https://medibo.in/'),
        r.phone, null);
    exception when others then null;
    end;

    insert into kyc_expiry_reminder(owner_kind, owner_id, kind, expiry, bucket_days)
    values (r.owner_kind, r.owner_id, r.kind, r.valid_to, v_bucket)
    on conflict do nothing;

    v_sent := v_sent + 1;
    if v_bucket = -1 then
      v_expired := v_expired + 1;
      -- kyc_gate reads valid_to directly, so the block is already in force.
      -- Counting it here is reporting, never a second source of truth.
      if coalesce((public.kyc_gate(r.owner_kind, r.owner_id, 'trade')->>'blocked')::boolean, false)
        then v_blocked := v_blocked + 1; end if;
    end if;
  end loop;

  if v_expired > 0 then
    insert into rg_alerts(fingerprint, severity, kind, name, detail, first_seen, last_seen, seen_count)
    values ('kyc_licence_expired', 'warn', 'kyc', 'KYC licence expired',
            jsonb_build_object('count', v_expired, 'blocked', v_blocked), now(), now(), 1)
    on conflict (fingerprint) do update
      set last_seen = now(), seen_count = rg_alerts.seen_count + 1, detail = excluded.detail;
  end if;

  return jsonb_build_object('ok', true, 'reminded', v_sent, 'expired', v_expired,
                            'blocked', v_blocked, 'buckets', to_jsonb(v_days),
                            'today', v_today);
end
$fn$;

insert into public.cron_task (name, ord, mode, work_sql, enabled, run_at_ist, business_hours_only, note)
values ('kyc-expiry-sweep', 537, 'poll', 'select public.kyc_expiry_sweep();', true,
        time '06:50:00', false,
        'CHANGE #705 — 30/7/1-day licence reminders for pharmacies and suppliers, '
        'then the expiry itself blocks through kyc_gate. Ten minutes after the '
        'partner licence sweep so the two never start together.')
on conflict (name) do nothing;

-- CMD #1889 — kyc_expiry_sweep, now that an expiry date actually exists.
--
-- Three things change:
--   * the sweep also reads the PROFILE's dl_expiry, so an account whose date was
--     backfilled by hand is reminded even before a document carries it;
--   * at expiry the ZONE PARTNER is told as well as the customer, on its own
--     ledger key so neither message eats the other;
--   * an expired customer's registration_stage drops back to 'documents', which
--     is the stage that asks for a licence.
-- Reminder days are data (app_settings.kyc_gate.remind_days), defaulting to the
-- 30 and 7 this command specifies plus the day itself.

insert into public.app_settings(key, value)
values ('kyc_gate', jsonb_build_object('grace_days', 14, 'enforce', true,
                                       'required_kinds', jsonb_build_array('drug_licence'),
                                       'remind_days', jsonb_build_array(30, 7)))
on conflict (key) do update
  set value = public.app_settings.value || jsonb_build_object(
        'remind_days', coalesce(public.app_settings.value->'remind_days',
                                jsonb_build_array(30, 7)));

insert into public.wa_event_routes(event_key, label, description, enabled)
values ('kyc_licence_expired_partner', 'Licence expired — partner',
        'Tells the zone partner that a customer licence lapsed today.', true)
on conflict (event_key) do nothing;

create or replace function public.kyc_expiry_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_cfg   jsonb := coalesce((select value from app_settings where key='kyc_gate'), '{}'::jsonb);
  v_days  int[] := coalesce((select array_agg((x #>> '{}')::int order by (x #>> '{}')::int desc)
                               from jsonb_array_elements(coalesce(v_cfg->'remind_days','[]'::jsonb)) x),
                            array[30,7]);
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  r record; v_sent int := 0; v_expired int := 0; v_blocked int := 0;
  v_partner int := 0; v_staged int := 0;
  v_bucket int; v_label text; v_phone text; v_event text; v_pp record;
begin
  for r in
    -- the licence that is in force, whether it lives on a DOCUMENT or was
    -- backfilled straight onto the profile. One row per owner, document first.
    with doc as (
      select distinct on (d.owner_kind, d.owner_id)
             d.owner_kind, d.owner_id, d.kind, d.valid_to
        from kyc_documents d
       where d.status = 'verified' and d.kind = 'drug_licence' and d.valid_to is not null
       order by d.owner_kind, d.owner_id, d.submitted_at desc nulls last
    ),
    prof as (
      select 'pharmacy'::text as owner_kind, p.id as owner_id,
             'drug_licence'::text as kind, p.dl_expiry as valid_to
        from pharmacy_profiles p
       where p.dl_expiry is not null
         and not exists (select 1 from doc where doc.owner_kind='pharmacy' and doc.owner_id = p.id)
      union all
      select 'supplier', s.id, 'drug_licence', s.dl_expiry
        from supplier_profiles s
       where s.dl_expiry is not null
         and not exists (select 1 from doc where doc.owner_kind='supplier' and doc.owner_id = s.id)
    ),
    src as (select * from doc union all select * from prof)
    select s.owner_kind, s.owner_id, s.kind, s.valid_to,
           case s.owner_kind when 'pharmacy' then p.pharmacy_name else sp.supplier_name end as owner_name,
           case s.owner_kind when 'pharmacy' then coalesce(nullif(p.whatsapp_no,''), p.phone)
                             else coalesce(nullif(sp.whatsapp_no,''), sp.phone) end as phone,
           case s.owner_kind when 'pharmacy' then p.zone_id else sp.zone_id end as zone_id
      from src s
      left join pharmacy_profiles p on s.owner_kind='pharmacy' and p.id = s.owner_id
      left join supplier_profiles sp on s.owner_kind='supplier' and sp.id = s.owner_id
     where s.valid_to <= v_today + v_days[1]
  loop
    -- Which bucket is this? The SMALLEST threshold the licence has reached, so
    -- one 6 days out sends the 7-day reminder once, not the 30 again.
    v_bucket := null;
    if r.valid_to < v_today then
      v_bucket := -1;
    else
      select min(dd) into v_bucket from unnest(v_days) dd where (r.valid_to - v_today) <= dd;
    end if;
    if v_bucket is null then continue; end if;

    v_label := _c('kyc.kind.'||r.kind);

    if not exists (select 1 from kyc_expiry_reminder m
                    where m.owner_kind = r.owner_kind and m.owner_id = r.owner_id
                      and m.kind = r.kind and m.expiry = r.valid_to
                      and m.bucket_days = v_bucket) then
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
    end if;

    if v_bucket = -1 then
      v_expired := v_expired + 1;
      if coalesce((public.kyc_gate(r.owner_kind, r.owner_id, 'trade')->>'blocked')::boolean, false)
        then v_blocked := v_blocked + 1; end if;

      -- the ZONE PARTNER hears about it once, on its own ledger key
      if not exists (select 1 from kyc_expiry_reminder m
                      where m.owner_kind = r.owner_kind and m.owner_id = r.owner_id
                        and m.kind = r.kind||'_partner' and m.expiry = r.valid_to
                        and m.bucket_days = -1) then
        for v_pp in
          select pu.identity from partner_users pu
            join region_partners rp on rp.id = pu.partner_id
           where coalesce(pu.is_active,true) and coalesce(rp.is_active,true)
             and rp.zone_id = r.zone_id
             and coalesce(btrim(pu.identity),'') <> ''
        loop
          begin
            perform public.wa_send_event('kyc_licence_expired_partner', null,
              jsonb_build_object('label', v_label, 'name', coalesce(r.owner_name,''),
                                 'd', to_char(r.valid_to,'DD/MM/YYYY'),
                                 'link', 'https://medibo.in/'),
              v_pp.identity, null);
            v_partner := v_partner + 1;
          exception when others then null;
          end;
        end loop;
        insert into kyc_expiry_reminder(owner_kind, owner_id, kind, expiry, bucket_days)
        values (r.owner_kind, r.owner_id, r.kind||'_partner', r.valid_to, -1)
        on conflict do nothing;
      end if;

      -- an expired customer goes back to the stage that asks for documents.
      -- Approval is NOT revoked here: the order gate reads the licence state
      -- directly, so one lapsed date never un-approves an account by itself.
      if r.owner_kind = 'pharmacy' then
        update pharmacy_profiles
           set registration_stage = 'documents'
         where id = r.owner_id
           and registration_stage in ('verified','approved');
        if found then v_staged := v_staged + 1; end if;
      end if;
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
                            'blocked', v_blocked, 'partner_told', v_partner,
                            'staged_back', v_staged,
                            'buckets', to_jsonb(v_days), 'today', v_today);
end $fn$;

-- CHANGE #528 — feature_gaps row 152: onboard the zone-2 fulfilment partner the
-- model was built for. Every isolation defect on this surface was invisible
-- precisely because no second partner existed to leak across.
-- The auth.users login (test.partner2@medibo.in) is created through the Auth
-- admin API, not SQL, and linked below.
insert into public.region_partners
  (partner_name, district, state, zone_id, address, gstin, dl_20b, dl_21b, is_active)
select 'Bilaspur Medical Agency (zone 2 partner)', 'Bilaspur', 'Chhattisgarh', 2,
       'Bilaspur, Chhattisgarh, India', '22AACCB1234D1ZP',
       'WLF20B2026CT000528', 'WLF21B2026CT000528', true
where not exists (select 1 from public.region_partners where zone_id = 2);

insert into public.partner_users (partner_id, identity, display_name, is_active, created_by)
select rp.id, 'test.partner2@medibo.in', 'Zone 2 partner staff', true, 'change-528'
  from public.region_partners rp
 where rp.zone_id = 2
   and not exists (select 1 from public.partner_users pu where pu.partner_id = rp.id)
 limit 1;

-- exactly ONE grant: the whole point of row 142 is that one grant must not
-- open the other five tabs.
insert into public.partner_permissions (partner_id, feature_key, access, updated_by)
select rp.id, 'partner.pack', 'read', 'change-528'
  from public.region_partners rp where rp.zone_id = 2
on conflict (partner_id, feature_key) do update set access = excluded.access;

update public.partner_users pu
   set auth_user_id = u.id, updated_at = now()
  from auth.users u
 where u.email = 'test.partner2@medibo.in'
   and pu.identity = 'test.partner2@medibo.in'
   and pu.auth_user_id is distinct from u.id;

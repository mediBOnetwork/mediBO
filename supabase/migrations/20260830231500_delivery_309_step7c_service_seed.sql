-- CHANGE #309 step 7c — seed serviceability from the customers we ALREADY serve.
--
-- Shipping with an empty table would make every existing pharmacy see "outside
-- our usual delivery area" at checkout on the morning of the deploy — a new
-- warning on a working flow reads as a bug, and it would be one.
--
-- The seed is not a guess: it is the pincode of every approved, non-deleted
-- pharmacy profile. We demonstrably deliver to those. Everything else keeps the
-- 'warn' default until Om lists it in the admin screen.
insert into public.delivery_serviceability(pincode, zone_id, mode, note, is_active, updated_by)
select distinct btrim(pp.pincode), pp.zone_id, 'serviceable',
       'Seeded from an approved customer at this pincode (CHANGE #309).', true, 'system'
  from public.pharmacy_profiles pp
 where pp.approved
   and coalesce(pp.is_deleted,false) = false
   and nullif(btrim(pp.pincode),'') is not null
on conflict (pincode) do nothing;

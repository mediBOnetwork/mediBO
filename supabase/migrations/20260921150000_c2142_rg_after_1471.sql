-- CMD #2142 — RG red after #1471: two behaviour checks that the last two
-- changes outgrew. Both fixes keep the property the check exists to hold down.
-- Idempotent: replace() is a no-op once applied; the allow row upserts.

-- 1. c570_surface_map, check 5. CMD #2125 moved My Shop off the pharmacy
--    bottom bar and into the Profile tab (the 'profile' slot opens it, and
--    cust.my_shop is the hero row of section 'my_shop'). The property is still
--    "the pharmacy can reach its shop" — a slot is one door, the Profile tab
--    is the other. When the fixture pharmacy has an account the rendered
--    Profile tab must actually carry the row.
update public.rg_behavior_tests
   set body = replace(body,
$old$    if not exists (select 1 from jsonb_array_elements(public.customer_nav()->'slots') s
                    where s->>'key' = 'my_shop') then
      raise exception 'my_shop slot vanished from the pharmacy bottom bar';
    end if;$old$,
$new$    -- CMD #2142: a my_shop slot, or the Profile tab carrying cust.my_shop.
    if not exists (select 1 from jsonb_array_elements(public.customer_nav()->'slots') s
                    where s->>'key' = 'my_shop')
       and not (
         exists (select 1 from jsonb_array_elements(public.customer_nav()->'slots') s
                  where s->>'key' = 'profile')
         and exists (select 1 from public.customer_feature_placement cp
                       join public.feature_registry fr on fr.feature_key = cp.feature_key
                      where cp.placement = 'profile_tab' and cp.is_active
                        and cp.feature_key = 'cust.my_shop'
                        and 'customer' = any (fr.roles_allowed))
       ) then
      raise exception 'my_shop vanished from the pharmacy: no bottom-bar slot and no Profile tab row';
    end if;
    v := public.customer_profile_tab();
    if coalesce((v->>'has_account')::boolean, false)
       and not exists (select 1 from jsonb_array_elements(v->'sections') sec,
                                     jsonb_array_elements(sec->'items') it
                        where it->>'feature_key' = 'cust.my_shop') then
      raise exception 'my_shop row missing from a registered pharmacy''s Profile tab';
    end if;$new$)
 where name = 'c570_surface_map'
   and body like '%my_shop slot vanished from the pharmacy bottom bar%';

-- 2. c1094: admin_customers_console is zone-scoped (admin_active_zone() binds
--    every read) but has no date half. It is the customer directory: each row
--    is a pharmacy with its lifetime order count, last order and idle days —
--    a register that stands as of now, not a day's ledger. Clamping it to the
--    picked date would show every pharmacy as idle the moment an admin looked
--    at yesterday. Same reasoning as customer_credit_list (CHANGE #1765).
insert into public.zone_scope_allow (fn_pattern, reason, dimension, added_by)
select 'admin_customers_console',
       'The customer directory: one row per pharmacy with lifetime order count, last order and idle days — a register as it stands now, not a day''s ledger, so admin_active_date() does not apply. The zone half binds (admin_active_zone(), CMD #2129).',
       'date', 'CMD #2142'
 where not exists (select 1 from public.zone_scope_allow where fn_pattern = 'admin_customers_console');

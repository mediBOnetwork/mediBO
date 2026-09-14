-- CMD #1935 — give "Customer documents" its door on the Customers dashboard.
--
-- The tile was registered with a category and a route but no dashboard_section.
-- Since #1893 that is an ORPHAN: the "Also here" strip that used to carry such
-- a tile is gone, so check_nav_orphans.sh (nav_dashboard_orphan_check()) fails
-- the deploy before a change number is burned, and _feature_registry_home_guard
-- re-homes the row into the More grid because nothing places it.
--
-- The section is not hardcoded: it is read from the sibling that already sits
-- where this tile belongs (admin.add_customer — "add a customer / onboarding"),
-- so the tile follows the registry rather than a literal, and dashboard_section
-- carries a foreign key to dashboard_section(section_key) that a literal could
-- violate on a database seeded differently. Idempotent: re-running changes
-- nothing once the row already points at the right section.
do $$
declare
  v_sec text;
begin
  -- 1. The named section, when this database actually defines it.
  select s.section_key into v_sec
    from public.dashboard_section s
   where s.section_key = 'onboarding'
     and coalesce(s.is_active, true);

  -- 2. Otherwise whatever the sibling on the same tab is using — it is already
  --    stored, so it satisfies every constraint this database enforces.
  if v_sec is null then
    select f.dashboard_section into v_sec
      from public.feature_registry f
     where f.feature_key = 'admin.add_customer'
       and f.dashboard_section is not null;
  end if;

  if v_sec is null then
    raise notice 'CMD #1935: no onboarding section on this database — leaving admin.customer_doc_types unplaced.';
    return;
  end if;

  update public.feature_registry
     set dashboard_section = v_sec,
         category = 'home_customers'
   where feature_key = 'admin.customer_doc_types'
     and (dashboard_section is distinct from v_sec or category is distinct from 'home_customers');
exception when others then
  -- A registry that refuses the placement must not take the deploy down with
  -- it; the orphan gate will say so in its own words on the next run.
  raise notice 'CMD #1935: could not place admin.customer_doc_types (%).', sqlerrm;
end $$;

-- CMD #1891 (follow-up, same command) — a tile needs a name that survives
-- leaving home.
--
-- The first pass put every "Also here" door on the Dashboard and the proof
-- shot showed the defect immediately: "Pending Approval" printed TWICE, side
-- by side, one the customer queue and one the supplier queue. On their own
-- screens those captions sit under a Customers / Suppliers heading and are
-- unambiguous; on a shared board they are the same four words.
--
-- The registry label stays exactly as the tab row needs it. `dashboard_label`
-- is the name the DASHBOARD prints when the tab's own caption is only clear
-- next to its host — data, so disambiguating the next one is an UPDATE.

begin;

alter table public.feature_registry
  add column if not exists dashboard_label text;

update public.feature_registry f
   set dashboard_label = v.lbl,
       badge_noun      = v.noun
  from (values
    ('admin.cust_tab.pending', 'Customer approvals', 'customers to approve'),
    ('admin.sup_tab.pending',  'Supplier approvals', 'suppliers to approve'),
    ('admin.cust_tab.leads',   'Customer leads',     'leads'),
    ('admin.sup_tab.leads',    'Supplier leads',     'leads')
  ) as v(feature_key, lbl, noun)
 where f.feature_key = v.feature_key
   and coalesce(f.dashboard_label,'') is distinct from v.lbl;

-- _dashboard_visible() carries the new column through untouched.
create or replace function public._dashboard_visible()
returns table(
  feature_key text, label text, icon_key text, route_key text, sort_order integer,
  category text, surface text, badge_source text, badge_noun text, badge_tone text,
  deep_link text, description text, dashboard_section text, tab_screen text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  with me as (
    select coalesce(public.get_my_role(),'none') as role,
           public.my_partner_id() as partner,
           exists (select 1 from public.admins a
                    where a.id::text = public.my_admin_id()::text
                      and coalesce(a.is_super,false)) as is_super
  ), acc as (select * from public._staff_access())
  -- The DASHBOARD's name for the door, falling back to the registry label.
  select f.feature_key,
         coalesce(nullif(f.dashboard_label,''), f.label) as label,
         f.icon_key, f.route_key, f.sort_order,
         f.category, f.surface, f.badge_source, f.badge_noun, f.badge_tone,
         f.deep_link, f.description, f.dashboard_section, f.tab_screen
    from public.feature_registry f
    cross join me
    left join acc on acc.feature_key = coalesce(nullif(f.canonical_key,''), f.feature_key)
   where f.is_active
     and coalesce(f.dashboard_section,'') <> ''
     and coalesce(f.route_key,'') <> ''
     and case when me.partner is not null
              then f.partner_eligible and coalesce(acc.level,'none') <> 'none'
              when f.surface = 'dev_tools' then me.role = 'super_admin' and me.role = any (f.roles_allowed)
              else me.role = any (f.roles_allowed)
                   and (me.is_super or coalesce(acc.level,'none') <> 'none') end
$function$;

grant execute on function public._dashboard_visible() to authenticated, service_role;

commit;

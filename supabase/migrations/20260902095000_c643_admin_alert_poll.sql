-- CHANGE #643 (6/6) — the admin alert overlay stops holding six channels open.
--
-- AdminAlertOverlay opened SIX unfiltered postgres_changes channels — on
-- pharmacy_profiles, supplier_profiles, orders, mr_registrations,
-- company_profiles and delivery_partner_registrations — purely to notice a new
-- row. Three of those tables were never in the publication at all, so those
-- three channels had been delivering nothing since the day they were written;
-- the other three fanned every INSERT on the two busiest tables in the product
-- to every admin session.
--
-- One read replaces all six: "what has arrived since the last time I asked?"
-- The overlay keeps the cursor and enqueues exactly the rows this returns, so
-- nothing about which alerts appear, or in what order, moves into Dart.

create or replace function public.admin_alert_new_since(
  p_since timestamptz default null,
  p_limit integer     default 25)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_since timestamptz := coalesce(p_since, now() - interval '10 minutes');
        v_lim int := least(greatest(coalesce(p_limit,25),1),50);
        v_rows jsonb;
begin
  if coalesce(public.get_my_role(),'') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'rows', '[]'::jsonb, 'server_time', now());
  end if;

  -- one union, one order, one limit — the overlay renders in payload order
  select coalesce(jsonb_agg(u.x order by u.created_at), '[]'::jsonb) into v_rows
  from (
   select q.created_at, q.x from (
    select p.created_at,
           jsonb_build_object('kind','new_registration','id',p.id::text,'row',to_jsonb(p)) as x
      from pharmacy_profiles p
     where p.created_at > v_since and coalesce(p.approved,false) = false
       and coalesce(p.status,'') in ('','pending')
    union all
    select s.created_at,
           jsonb_build_object('kind','new_supplier','id',s.id::text,'row',to_jsonb(s))
      from supplier_profiles s
     where s.created_at > v_since and coalesce(s.approved,false) = false
       and coalesce(s.status,'') in ('','pending')
    union all
    select m.created_at,
           jsonb_build_object('kind','mr_registration','id',m.id::text,'row',to_jsonb(m))
      from mr_registrations m
     where m.created_at > v_since
    union all
    select c.created_at,
           jsonb_build_object('kind','company_registration','id',c.id::text,'row',to_jsonb(c))
      from company_profiles c
     where c.created_at > v_since
    union all
    select d.created_at,
           jsonb_build_object('kind','dp_registration','id',d.id::text,'row',to_jsonb(d))
      from delivery_partner_registrations d
     where d.created_at > v_since
    union all
    select o.created_at,
           jsonb_build_object('kind','new_order','id',o.id::text,'row',to_jsonb(o))
      from orders o
     where o.created_at > v_since
       and coalesce(o.status,'') in ('','pending')
   ) q
   where q.created_at is not null
   order by q.created_at desc
   limit v_lim
  ) u;

  return jsonb_build_object(
    'ok', true,
    'rows', v_rows,
    'count', jsonb_array_length(v_rows),
    'since', v_since,
    'server_time', now());
end $$;

grant execute on function public.admin_alert_new_since(timestamptz, integer)
  to authenticated, service_role;

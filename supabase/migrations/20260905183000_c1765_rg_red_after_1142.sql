-- CHANGE #1765 — the regression guard went red on the scheduled run after
-- CHANGE #1142 (command #668, "test.cust1 gets a real shop; synthetic hidden
-- from every real surface").
--
-- Thirteen diffs, two criticals. The thirteen are #1142's own work and are
-- rebaselined, not undone: twelve function bodies gained `not
-- coalesce(is_synthetic,false)` and test_customer_shop_ensure() is new. The
-- two criticals are never rebaselined, and they are what this migration fixes.
--
-- ── 1. c1094_staff_rpcs_are_zone_scoped ───────────────────────────────────
-- #1094 grandfathered every staff RPC that was already unscoped, and made the
-- grandfather expire the moment the body CHANGES ('changed_still_unscoped').
-- #1142 edited four of them, so four came due at once: admin_alert_new_since,
-- admin_claim_queue, admin_missing_locations, customer_credit_list. Each is
-- scoped here rather than exempted; only the DATE dimension is exempted, and
-- only where a date genuinely does not exist (fw_list_unfillable's precedent).
--
-- ── 2. account_deletion_flow ──────────────────────────────────────────────
-- The probe picked "the newest pharmacy row with a user" and ASSUMED
-- my_customer_id() would answer with that row. After #1142 the newest row is
-- the synthetic shop owned by test.cust1 — and that same login is also ACTIVE
-- STAFF (customer_users) on an older synthetic pharmacy whose uuid sorts
-- first, so my_customer_id()'s `order by pp.id limit 1` answered with the
-- other one. The request was filed against a customer the probe was not
-- watching, approve soft-deleted THAT customer, and the probe read
-- "pharmacy not soft-deleted" as a product bug. The product is correct.
-- The probe now (a) never runs on synthetic data (#1676's law) and (b) takes
-- its fixture FROM my_customer_id() instead of guessing it.

-- ── helper: which zone does a payment claim belong to? ────────────────────
-- Money must never silently vanish from the queue, so an unknown zone stays
-- NULL and scope_zone_ok() then shows the claim in every zone — the same rule
-- admin_payment_claims already follows.
CREATE OR REPLACE FUNCTION public._c1765_claim_zone(p_claim uuid)
 RETURNS smallint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $c1765$
  select coalesce(
           pc.zone_id,
           (select o.zone_id from public.orders o where o.id = pc.order_id),
           (select p.zone_id from public.pharmacy_profiles p
             where right(regexp_replace(coalesce(p.whatsapp_no, p.phone,''),'\D','','g'),10)
                 = right(regexp_replace(coalesce(pc.sender_phone,''),'\D','','g'),10)
               and coalesce(p.is_deleted,false) = false
               and not coalesce(p.is_synthetic,false)
             limit 1))
    from public.payment_claims pc
   where pc.id = p_claim
$c1765$;

-- ── customer_credit_list ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.customer_credit_list(p_q text DEFAULT NULL::text, p_limit integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb;
        v_zone smallint := public.scope_zone();
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select coalesce(jsonb_agg(x order by (x->>'outstanding')::numeric desc), '[]'::jsonb) into v
  from (
    select public.customer_credit_state(pp.id)
           || jsonb_build_object('customer_id', pp.id,
                                 'customer_name', coalesce(nullif(btrim(pp.pharmacy_name),''),
                                                           nullif(btrim(pp.customer_name),''), '')) as x
      from public.pharmacy_profiles pp
     where coalesce(pp.is_deleted,false) = false
       and not coalesce(pp.is_synthetic,false)
       -- CHANGE #1765 — the header's zone picker binds here too. A customer
       -- with no zone yet is shown in every zone rather than hidden.
       and public.scope_zone_ok(pp.zone_id, v_zone)
       and (p_q is null or btrim(p_q) = ''
            or pp.pharmacy_name ilike '%'||p_q||'%'
            or pp.customer_name ilike '%'||p_q||'%')
       and exists (select 1 from public.orders o where o.customer_id = pp.id)
     limit greatest(coalesce(p_limit,30),1)
  ) s;
  return jsonb_build_object('ok', true, 'items', v);
end $function$;

-- ── admin_missing_locations ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_missing_locations()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb; v_missing int; v_total int;
        s_rows jsonb; s_missing int; s_total int;
        v_zone smallint := public.scope_zone();
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('allowed',false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'pharmacy_id',pp.id,'pharmacy_name',coalesce(pp.pharmacy_name,''),
           'address',coalesce(pp.address,''),'pincode',coalesce(pp.pincode,''),
           'phone',coalesce(pp.phone,''),
           'open_orders',(select count(*) from orders o where o.customer_id=pp.id
                            and coalesce(o.status,'') not in ('cancelled'))) order by pp.pharmacy_name),
         '[]'::jsonb),
         count(*)
    into v_rows, v_missing
  from pharmacy_profiles pp
  where coalesce(pp.is_deleted,false)=false and not coalesce(pp.is_synthetic,false)
    -- CHANGE #1765 — an address queue is worked zone by zone. A row with no
    -- zone yet is exactly the row that needs fixing, so it is never hidden.
    and public.scope_zone_ok(pp.zone_id, v_zone)
    and (pp.latitude is null or pp.longitude is null);

  select count(*) into v_total from pharmacy_profiles pp
   where coalesce(pp.is_deleted,false)=false and not coalesce(pp.is_synthetic,false)
     and public.scope_zone_ok(pp.zone_id, v_zone);

  select coalesce(jsonb_agg(jsonb_build_object(
           'supplier_id', sp.id,
           'supplier_name', coalesce(sp.supplier_name,''),
           'address', btrim(coalesce(nullif(sp.address,''), sp.street_address, '')),
           'pincode', coalesce(nullif(sp.pin_code,''), sp.pincode, ''),
           'phone', coalesce(nullif(sp.phone,''), sp.contact_no, ''),
           'geocode_status', coalesce(sp.geocode_status,'never')) order by sp.supplier_name),
         '[]'::jsonb),
         count(*)
    into s_rows, s_missing
  from supplier_profiles sp
  where coalesce(sp.is_deleted,false)=false and coalesce(sp.approved,false)=true
    and public.scope_zone_ok(sp.zone_id, v_zone)
    and (sp.lat is null or sp.lng is null);

  select count(*) into s_total from supplier_profiles sp
   where coalesce(sp.is_deleted,false)=false and coalesce(sp.approved,false)=true
     and public.scope_zone_ok(sp.zone_id, v_zone);

  return jsonb_build_object('allowed',true,
    'missing_count',coalesce(v_missing,0),'total',coalesce(v_total,0),
    'title', public._cf('missing_loc_customers_title',
               jsonb_build_object('n',coalesce(v_missing,0)::text,'total',coalesce(v_total,0)::text)),
    'note', public._c('missing_loc_customers_note'),
    'rows', v_rows,
    'supplier_missing_count', coalesce(s_missing,0),
    'supplier_total', coalesce(s_total,0),
    'supplier_title', public._cf('missing_loc_suppliers_title',
               jsonb_build_object('n',coalesce(s_missing,0)::text,'total',coalesce(s_total,0)::text)),
    'supplier_note', public._c('missing_loc_suppliers_note'),
    'supplier_rows', s_rows);
end $function$;

-- ── admin_alert_new_since ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_alert_new_since(p_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_since timestamptz := coalesce(p_since, now() - interval '10 minutes');
        v_lim int := least(greatest(coalesce(p_limit,25),1),50);
        v_rows jsonb;
        -- CHANGE #1765 — the overlay pings the admin who is ON that zone. The
        -- DATE dimension does not apply: p_since IS this surface's time
        -- bound, and clamping a live alert to the picked date would silence
        -- it the moment anyone looked at yesterday (zone_scope_allow, 'date').
        v_zone smallint := public.scope_zone();
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
       and not coalesce(p.is_synthetic,false)
       and public.scope_zone_ok(p.zone_id, v_zone)
    union all
    select s.created_at,
           jsonb_build_object('kind','new_supplier','id',s.id::text,'row',to_jsonb(s))
      from supplier_profiles s
     where s.created_at > v_since and coalesce(s.approved,false) = false
       and coalesce(s.status,'') in ('','pending')
       and not coalesce(s.is_synthetic,false)
       and public.scope_zone_ok(s.zone_id, v_zone)
    union all
    -- CHANGE #668: mr_registrations has submitted_at, not created_at. This
    -- arm raised 'column m.created_at does not exist' for EVERY admin, so
    -- the whole new-registration overlay was dead, not just this row.
    -- CHANGE #1765: an MR application carries no zone, so it reaches every
    -- zone rather than none.
    select m.submitted_at,
           jsonb_build_object('kind','mr_registration','id',m.id::text,'row',to_jsonb(m))
      from mr_registrations m
     where m.submitted_at > v_since
    union all
    -- ...and company_profiles is submitted_at too, for the same reason.
    select c.submitted_at,
           jsonb_build_object('kind','company_registration','id',c.id::text,'row',to_jsonb(c))
      from company_profiles c
     where c.submitted_at > v_since
    union all
    select d.created_at,
           jsonb_build_object('kind','dp_registration','id',d.id::text,'row',to_jsonb(d))
      from delivery_partner_registrations d
     where d.created_at > v_since
       and not coalesce(d.is_synthetic,false)
       and public.scope_zone_ok(d.zone_id, v_zone)
    union all
    select o.created_at,
           jsonb_build_object('kind','new_order','id',o.id::text,'row',to_jsonb(o))
      from orders o
     where o.created_at > v_since
       and not coalesce(o.is_synthetic,false)
       and public.scope_zone_ok(o.zone_id, v_zone)
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
end $function$;

-- ── admin_claim_queue ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_claim_queue(p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb; v_open int; v_oldest int; v_no_utr int; v_sum numeric;
        -- CHANGE #1765 — the same clamp admin_payment_claims already applies
        -- to this very table: as of the active date, in the active zone. The
        -- date test is `<=`, so the default (today) hides nothing, and a
        -- claim whose zone is unknown is shown everywhere — money must never
        -- silently vanish from the queue.
        v_zone smallint := public.scope_zone();
        v_date date := public.scope_date();
begin
  if not is_admin() then raise exception 'not_authorized'; end if;

  select coalesce(jsonb_agg(x order by (x->>'age_days')::int desc), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'claim_id',      pc.id,
      'amount_label',  public.inr_money(pc.amount),
      'sender_phone',  pc.sender_phone,
      'customer_name', coalesce(pp.pharmacy_name, 'Unknown sender'),
      'order_code',    coalesce(nullif(btrim(o.order_code),''), ''),
      'linked',        pc.order_id is not null,
      'link_label',    case when pc.order_id is null then 'Not attached to an order'
                            else coalesce(nullif(btrim(o.order_code),''), 'Attached') end,
      'link_tone',     case when pc.order_id is null then 'bad' else 'muted' end,
      'age_days',      public._c450_age_days(pc.received_at),
      'age_label',     public._c450_age_label(pc.received_at),
      'age_tone',      public._c450_age_tone(public._c450_age_days(pc.received_at)),
      'received_label','Received ' || to_char(pc.received_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM'),
      -- The point of the row: a missing UTR is a STATE, never a blank field.
      'utr',           pc.utr,
      'has_utr',       coalesce(nullif(btrim(pc.utr),'') is not null, false),
      'utr_label',     coalesce(nullif(btrim(pc.utr),''), 'No UTR on this claim'),
      'utr_tone',      case when nullif(btrim(pc.utr),'') is null then 'bad' else 'good' end,
      'utr_detail',    case when nullif(btrim(pc.utr),'') is null
                            then 'Without the bank reference this payment cannot be matched to the statement.'
                            else '' end,
      'can_ask_utr',   nullif(btrim(pc.utr),'') is null
                         and coalesce(nullif(btrim(pc.sender_phone),'') is not null, false),
      'ask_utr_label', 'Ask for the UTR',
      'has_proof',     pc.raw_ocr is not null,
      'proof_label',   case when pc.raw_ocr is null then 'No screenshot read' else 'Screenshot read' end,
      'status',        pc.status,
      'status_label',  case pc.status when 'received' then 'Waiting to be verified'
                                      when 'verified' then 'Verified'
                                      else initcap(coalesce(pc.status,'unknown')) end
    ) as x
    from payment_claims pc
    left join orders o on o.id = pc.order_id
    left join lateral (
      select p.pharmacy_name from pharmacy_profiles p
       where right(regexp_replace(coalesce(p.whatsapp_no, p.phone,''),'\D','','g'),10)
           = right(regexp_replace(coalesce(pc.sender_phone,''),'\D','','g'),10)
         and coalesce(p.is_deleted,false) = false
         and not coalesce(p.is_synthetic,false)
       limit 1
    ) pp on true
    where pc.status = 'received'
      and (pc.received_at at time zone 'Asia/Kolkata')::date <= v_date
      and public.scope_zone_ok(public._c1765_claim_zone(pc.id), v_zone)
    order by pc.received_at asc
    limit greatest(1, coalesce(p_limit,100))
  ) q;

  -- The headline counts the same queue the cards came from, never a wider one.
  select count(*)::int,
         coalesce(max(public._c450_age_days(received_at)),0),
         count(*) filter (where nullif(btrim(utr),'') is null)::int,
         coalesce(sum(amount),0)
    into v_open, v_oldest, v_no_utr, v_sum
    from payment_claims pc
   where pc.status = 'received'
     and (pc.received_at at time zone 'Asia/Kolkata')::date <= v_date
     and public.scope_zone_ok(public._c1765_claim_zone(pc.id), v_zone);

  return jsonb_build_object(
    'ok', true,
    'rows', v_rows,
    'count', v_open,
    'headline', case when v_open = 0 then 'Nothing waiting to be verified'
                     when v_open = 1 then '1 payment waiting to be verified'
                     else v_open || ' payments waiting to be verified' end,
    'value_label', public.inr_money(v_sum),
    'oldest_label', case when v_open = 0 then ''
                         else 'Oldest has waited ' || v_oldest ||
                              case when v_oldest = 1 then ' day' else ' days' end end,
    'oldest_tone', public._c450_age_tone(v_oldest),
    'utr_gap_label', case when v_no_utr = 0 then ''
                          when v_no_utr = 1 then '1 of them has no UTR'
                          else v_no_utr || ' of them have no UTR' end,
    'empty_label', 'Every payment that arrived has been verified.',
    'note', 'Oldest first — the longest wait is always the first card.');
end $function$;

-- ── the three date exemptions, each with its reason ──────────────────────
insert into public.zone_scope_allow (fn_pattern, reason, dimension, added_by)
values
  ('admin_alert_new_since',
   'A live arrivals overlay, not a day''s ledger: p_since IS its time bound, so clamping it to the picked date would silence every alert the moment an admin looked at yesterday. The zone half binds and was added in #1765.',
   'date', 'CHANGE #1765'),
  ('admin_missing_locations',
   'A missing latitude is a CURRENT fact, not something that happened on a date — an address queue drains, it does not close at midnight. The zone half binds and was added in #1765.',
   'date', 'CHANGE #1765'),
  ('customer_credit_list',
   'Outstanding credit is a balance as it stands right now; there is no day whose credit list this is. The zone half binds and was added in #1765.',
   'date', 'CHANGE #1765')
on conflict (fn_pattern) do update
  set reason = excluded.reason,
      dimension = excluded.dimension,
      added_by = excluded.added_by;

-- ── the probe: a fixture is what the PRODUCT resolves, never a guess ─────
-- Upsert, not UPDATE: a build branch carries a partial rg_behavior_tests
-- snapshot, and an UPDATE that matches no row is a migration that silently
-- did nothing. The primary key is the name.
insert into public.rg_behavior_tests (name, body, note, enabled)
values ('account_deletion_flow', $c1765$
do $x$
declare v jsonb; v_rid uuid; v_cid uuid; v_uid uuid; v_del boolean;
        r record; v_res uuid;
begin
  -- CHANGE #1765. This used to read "the newest pharmacy row that has an auth
  -- user" and ASSUME my_customer_id() would answer with that same row. #1142
  -- made the newest row the synthetic shop owned by test.cust1 — a login that
  -- is ALSO active staff (customer_users) on an older synthetic pharmacy
  -- whose uuid sorts first, so my_customer_id()'s `order by pp.id limit 1`
  -- answered with the other one. The request was filed against a customer the
  -- probe was not watching, approve soft-deleted THAT customer, and the probe
  -- reported "pharmacy not soft-deleted" against a product that was correct.
  -- Two rules now hold it down: a probe never runs on synthetic data (#1676),
  -- and the fixture is whatever my_customer_id() actually returns.
  v_cid := null;
  for r in
    select pp.id, pp.user_id
      from pharmacy_profiles pp
     where pp.user_id is not null
       and coalesce(pp.is_deleted,false) = false
       and not coalesce(pp.is_synthetic,false)
       and exists (select 1 from auth.users u where u.id = pp.user_id)
     order by pp.created_at desc
     limit 25
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', r.user_id, 'role','authenticated')::text, true);
    begin v_res := public.my_customer_id(); exception when others then v_res := null; end;
    if v_res is not null
       and not exists (select 1 from pharmacy_profiles p
                        where p.id = v_res and coalesce(p.is_synthetic,false))
    then
      v_cid := v_res; v_uid := r.user_id; exit;
    end if;
  end loop;
  if v_cid is null then raise exception 'RG_ROLLBACK'; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_uid,'role','authenticated')::text, true);
  v := public.request_account_deletion('account','rg test');
  if (v->>'ok') <> 'true' or (v->>'request_id') is null then
    raise exception 'submit failed: %', v; end if;
  v_rid := (v->>'request_id')::uuid;

  -- one open request per customer
  v := public.request_account_deletion('account', null);
  if coalesce(v->>'already_open','') <> 'true' then
    raise exception 'dedupe broken: %', v; end if;

  perform set_config('request.jwt.claims',
    (select json_build_object('sub',u.id,'email',u.email,'role','authenticated')::text
       from auth.users u where lower(u.email)='masteromprakashsahu@gmail.com' limit 1), true);
  v := public.admin_deletion_request_list('pending');
  if (v->>'has_rows') <> 'true' or public.admin_deletion_request_count() < 1 then
    raise exception 'admin list/badge broken: %', v; end if;

  v := public.admin_review_deletion_request(v_rid,'approve','rg');
  if (v->>'status') <> 'approved' then raise exception 'approve failed: %', v; end if;
  select is_deleted into v_del from pharmacy_profiles where id=v_cid;
  if coalesce(v_del,false) <> true then raise exception 'pharmacy not soft-deleted'; end if;

  -- re-review is refused
  v := public.admin_review_deletion_request(v_rid,'approve','again');
  if (v->>'ok') <> 'false' then raise exception 'double review allowed: %', v; end if;

  raise exception 'RG_ROLLBACK';
end $x$;
$c1765$,
        'Account deletion: in-app request -> single open per customer -> admin list+badge -> approve soft-deletes pharmacy -> no double review. #1765: the fixture is my_customer_id()''s own answer and is never synthetic.',
        true)
on conflict (name) do update
  set body = excluded.body,
      note = excluded.note,
      enabled = true;

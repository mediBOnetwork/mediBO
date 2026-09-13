-- CMD #1889 — my_session_core gains ONE new order-gate reason: licence_required.
-- Everything else in this function is byte-for-byte what was live; the added
-- block is the only change, and it is wrapped so a gate failure can never
-- white-screen a session.
CREATE OR REPLACE FUNCTION public.my_session_core()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role text; v_owner record; v_name text; v_cfg record;
  v_sup uuid; v_cust uuid; pp pharmacy_profiles%rowtype; sp supplier_profiles%rowtype;
  ap pharmacy_profiles%rowtype;
  v_profile jsonb := '{}'::jsonb; v_registered boolean := false; v_surface text;
  v_has_cust boolean := false; v_suspended boolean := false;
  v_pend_sup_name text := null; v_sup_status text := 'not_found';
  v_is_staff boolean := false; v_can_order boolean := false;
  v_needs_profile boolean := false; v_act uuid;
  v_reason text; v_copy jsonb; v_gate jsonb;
begin
  if auth.uid() is null then
    v_copy := coalesce((select value from app_settings where key='order_gate_copy'), '{}'::jsonb)
              -> 'signed_out';
    return jsonb_build_object(
      'signed_in', false, 'auth_user_id','', 'login_email','', 'role','none',
      'is_admin', false, 'is_super_admin', false, 'is_supplier', false,
      'is_customer', false, 'is_registered_customer', false, 'is_worker', false,
      'surface','public', 'owner_type','', 'owner_id','', 'display_name','',
      'supplier_id','', 'supplier_name','', 'customer_id','', 'customer_name','',
      'home_route','/login', 'home_label','Login', 'header_title','',
      'status_label','', 'profile','{}'::jsonb, 'identities','[]'::jsonb,
      'message','Please log in',
      'has_customer_account', false, 'is_suspended', false,
      'is_pending_supplier', false, 'supplier_status','not_found',
      'needs_profile', false, 'can_place_order', false, 'acting_as','',
      'order_gate', jsonb_build_object(
        'has_blocker',  true, 'reason','signed_out',
        'title',        coalesce(v_copy->>'title',''),
        'message',      coalesce(v_copy->>'message',''),
        'action_label', coalesce(v_copy->>'action_label',''),
        'action_route', coalesce(v_copy->>'action_route',''),
        'short_label',  coalesce(v_copy->>'short_label','')));
  end if;

  perform public.login_sync_current_user();

  v_role := coalesce(public.get_my_role(), 'none');
  select owner_type, owner_id into v_owner from public.my_owner();
  select * into v_cfg from login_role_config where role = v_role;

  v_sup  := public.my_supplier_id();
  v_cust := public.my_customer_id();
  v_act  := public.my_acting_as();
  v_is_staff := v_role in ('admin','super_admin','worker');

  if v_sup is not null then
    select * into sp from supplier_profiles where id = v_sup;
    v_name := sp.supplier_name;
    v_sup_status := 'ok';
  elsif v_cust is not null then
    select * into pp from pharmacy_profiles where id = v_cust;
    v_name := coalesce(nullif(btrim(pp.pharmacy_name),''), nullif(btrim(pp.customer_name),''));
    v_registered := (coalesce(pp.approved,false) = true
                     or lower(coalesce(pp.status,'')) in ('approved','active'));
    v_profile := jsonb_build_object(
      'contact_name',   coalesce(pp.customer_name,''),
      'business_name',  coalesce(pp.pharmacy_name,''),
      'store_type',     coalesce(nullif(btrim(pp.store_type),''), '—'),
      'delivery_range', coalesce(nullif(btrim(pp.range_zone),''), '—'),
      'local_address',  coalesce(nullif(btrim(pp.address_local),''), '—'),
      'city',           coalesce(nullif(btrim(pp.city),''), '—'),
      'state',          coalesce(nullif(btrim(pp.state),''), '—'),
      'phone',          coalesce(pp.phone,''),
      'whatsapp_no',    coalesce(pp.whatsapp_no,''),
      'email',          coalesce(pp.email,''),
      'gstin',          coalesce(nullif(btrim(pp.gstin),''), '—'),
      'drug_license',   coalesce(nullif(btrim(pp.drug_license),''), '—'),
      'payment_term',   coalesce(nullif(btrim(pp.payment_term),''), '—'),
      'note',           'To update your details, contact support.');
  elsif v_role in ('admin','super_admin') then
    v_name := public.my_login_email();
  end if;

  v_has_cust := (v_cust is not null);
  v_suspended := (v_cust is not null and lower(coalesce(pp.status,'')) = 'suspended');

  if v_sup is null then
    select s.supplier_name into v_pend_sup_name
    from supplier_profiles s
    join login_identities li
      on li.owner_type = 'supplier' and li.owner_id = s.id::text
    where li.identity = any (public.my_identity_keys())
      and coalesce(s.is_deleted,false) = false
      and coalesce(s.approved,false) = false
    order by s.id
    limit 1;
    if v_pend_sup_name is not null then v_sup_status := 'pending_approval'; end if;
  end if;

  -- FIX 1: a supplier (approved or pending) is never "missing a profile".
  v_needs_profile := (not v_is_staff and v_sup is null and v_pend_sup_name is null
                      and not v_has_cust and v_act is null);

  v_surface := case
    when v_role in ('admin','super_admin') and v_act is not null then 'customer'
    when v_role in ('admin','super_admin') then 'admin'
    when v_sup is not null then 'supplier'
    when v_pend_sup_name is not null then 'pending_supplier'
    when v_role = 'worker' then 'worker'
    else 'customer' end;

  -- FIX 3: under View As the gate judges the IMPERSONATED customer, which is
  -- the account the order is actually placed for.
  if v_act is not null then
    select * into ap from pharmacy_profiles where id = v_act;
    v_can_order := (ap.id is not null
                    and lower(coalesce(ap.status,'')) <> 'suspended'
                    and (coalesce(ap.approved,false) = true
                         or lower(coalesce(ap.status,'')) in ('approved','active')));
    v_reason := case when v_can_order then 'none' else 'viewas_pending_approval' end;
  else
    v_can_order := (v_has_cust and v_registered and not v_suspended);
    -- FIX 2: order matters — a supplier or staff account is not an
    -- unregistered pharmacy, and must never be told to go and register.
    v_reason := case
      when v_can_order                     then 'none'
      when v_suspended                     then 'suspended'
      when v_sup is not null
        or v_pend_sup_name is not null     then 'supplier_account'
      when v_is_staff                      then 'staff_account'
      when not v_has_cust                  then 'not_registered'
      else 'pending_approval' end;
  end if;

  -- CMD #1889 — an approved customer with no drug licence on file is refused
  -- HERE, by the backend, with the backend's own sentence. Flutter checks
  -- nothing: _place_order_v2_core already raises on this same gate, so the
  -- storefront and the order path can never disagree.
  if v_reason = 'none' then
    declare v_lic uuid := coalesce(v_act, v_cust);
    begin
      if v_lic is not null
         and coalesce((public.licence_order_block(v_lic)->>'blocked')::boolean, false) then
        v_can_order := false;
        v_reason := 'licence_required';
      end if;
    exception when others then null;
    end;
  end if;

  if v_reason = 'none' then
    v_gate := jsonb_build_object('has_blocker', false, 'reason','none',
      'title','', 'message','', 'action_label','', 'action_route','', 'short_label','');
  else
    v_copy := coalesce((select value from app_settings where key='order_gate_copy'), '{}'::jsonb)
              -> v_reason;
    v_gate := jsonb_build_object(
      'has_blocker',  true, 'reason', v_reason,
      'title',        coalesce(v_copy->>'title',''),
      'message',      coalesce(v_copy->>'message',''),
      'action_label', coalesce(v_copy->>'action_label',''),
      'action_route', coalesce(v_copy->>'action_route',''),
      'short_label',  coalesce(v_copy->>'short_label',''));
  end if;

  return jsonb_build_object(
    'signed_in',              true,
    'auth_user_id',           coalesce(auth.uid()::text,''),
    'login_email',            coalesce(public.my_login_email(),''),
    'role',                   v_role,
    'is_admin',               (v_role in ('admin','super_admin')),
    'is_super_admin',         (v_role = 'super_admin'),
    'is_supplier',            (v_sup is not null),
    'is_customer',            (v_cust is not null),
    'is_registered_customer', v_registered,
    'is_worker',              (v_role = 'worker'),
    'surface',                v_surface,
    'owner_type',             coalesce(v_owner.owner_type,
                                case when v_role in ('admin','super_admin') then 'admin' else 'customer' end),
    'owner_id',               coalesce(v_owner.owner_id, v_sup::text, v_cust::text, ''),
    'supplier_id',            coalesce(v_sup::text,''),
    'supplier_name',          coalesce(sp.supplier_name, v_pend_sup_name, ''),
    'customer_id',            coalesce(v_cust::text,''),
    'customer_name',          coalesce(v_name,''),
    'display_name',           coalesce(nullif(ap.pharmacy_name,''),
                                nullif(ap.customer_name,''), v_name, ''),
    'acting_as_name',         coalesce(nullif(ap.pharmacy_name,''),
                                nullif(ap.customer_name,''), ''),
    'header_title',           coalesce(nullif(ap.pharmacy_name,''),
                                nullif(ap.customer_name,''),
                                nullif(v_name,''), 'My Account'),
    'status_label',           public.my_session_status_label(
                                (v_sup is not null), (v_pend_sup_name is not null),
                                v_has_cust, v_registered, v_suspended,
                                (v_role in ('admin','super_admin'))),
    'profile',                v_profile,
    'home_route',             coalesce(v_cfg.home_route,'/store'),
    'home_label',             coalesce(v_cfg.home_label,'Store'),
    'identities',             coalesce((select jsonb_agg(jsonb_build_object(
                                          'identity', coalesce(li.identity,''),
                                          'kind', coalesce(li.kind,''))
                                        order by li.kind, li.identity)
                                        from login_identities li
                                        where li.owner_type = v_owner.owner_type
                                          and li.owner_id = v_owner.owner_id), '[]'::jsonb),
    'message',                'Signed in',
    'has_customer_account',   v_has_cust,
    'is_suspended',           v_suspended,
    'is_pending_supplier',    (v_pend_sup_name is not null),
    'supplier_status',        v_sup_status,
    'needs_profile',          v_needs_profile,
    'can_place_order',        v_can_order,
    'acting_as',              coalesce(v_act::text,''),
    'order_gate',             v_gate,
    'pending_supplier_screen', (select jsonb_build_object(
        'title',   coalesce(c->>'title_prefix','')
                   || coalesce(nullif(v_pend_sup_name,''), c->>'fallback_name', ''),
        'message', coalesce(c->>'message',''),
        'sign_out_label', coalesce(c->>'sign_out_label',''))
      from (select (select value from app_settings where key='pending_supplier_screen') as c) z),
    'bulk_wa_gate',           (select jsonb_build_object(
                                 'label',   coalesce(c->>'label',''),
                                 'note',    coalesce(c->>'note',''),
                                 'enabled', coalesce((c->>'enabled')::boolean,false),
                                 'action',  coalesce(c->>'action','none'),
                                 'has_note',(coalesce(c->>'note','') <> ''))
                               from (select (select value from app_settings
                                             where key='bulk_wa_gate_copy') -> v_reason as c) z));
end $function$



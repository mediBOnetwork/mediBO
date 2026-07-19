-- CHANGE #373: Supplier Inquiry — Copy link / Send buttons must not be hidden
-- by the Auto Meta toggle. get_supplier_inquiry_overview() previously forced
-- can_send=false for every supplier whenever inquiry_auto_meta was ON. That
-- branch is removed; can_send now depends only on engine/lock/is_open, the
-- same logic already used whenever Auto Meta is OFF. needs_auto_send (the
-- actual auto-send trigger) is untouched.
CREATE OR REPLACE FUNCTION public.get_supplier_inquiry_overview()
 RETURNS TABLE(supplier_name text, current_count bigint, next_count bigint, token text, form_status text, expires_at timestamp with time zone, inquiry_code text, rnk integer, is_open boolean, can_send boolean, needs_auto_send boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_suppliers text[]; v_sup text; v_current_count bigint; v_row inquiry%rowtype;
  v_slotidx int; v_ps text; v_as text; v_token text; v_fstatus text;
  v_expires timestamptz; v_code text; v_wa_sent timestamptz;
  v_engine boolean; v_lock boolean; v_auto boolean;
  v_ranked jsonb; v_rnk int; v_isopen boolean; v_cansend boolean; v_needsauto boolean;
begin
  v_engine := COALESCE((SELECT (value #>> '{}')::boolean FROM app_settings WHERE key='inquiry_engine_mode'), false);
  v_lock   := COALESCE((SELECT (value #>> '{}')::boolean FROM app_settings WHERE key='inquiry_lock'), false);
  v_auto   := COALESCE((SELECT (value #>> '{}')::boolean FROM app_settings WHERE key='inquiry_auto_meta'), false);

  SELECT jsonb_object_agg(rs.supplier_name, jsonb_build_object('rnk',rs.rnk,'is_open',rs.is_open))
    INTO v_ranked FROM inquiry_engine_ranked_suppliers() rs;
  v_ranked := COALESCE(v_ranked, '{}'::jsonb);

  select array_agg(distinct inq.current_supplier) into v_suppliers
  from inquiry inq where inq.current_supplier is not null;
  if v_suppliers is null then return; end if;

  foreach v_sup in array v_suppliers loop
    v_current_count := 0;
    for v_row in select * from inquiry inq where inq.current_supplier = v_sup loop
      if inquiry_demand_qty(v_row.product_id, v_sup, true) <= 0 then continue; end if;
      if v_row.supplier_order_id is not null then continue; end if;
      for v_slotidx in 1..30 loop
        execute format('select ($1).%I, ($1).%I', 'PS'||v_slotidx, 'AS'||v_slotidx)
          into v_ps, v_as using v_row;
        if v_ps = v_sup then
          if v_as is null or btrim(v_as) = '' then v_current_count := v_current_count + 1; end if;
          exit;
        end if;
        v_as := null;
      end loop;
    end loop;
    if v_current_count = 0 then continue; end if;

    select f.token, f.status, f.expires_at, f.auto_wa_sent_at
      into v_token, v_fstatus, v_expires, v_wa_sent
    from inquiry_forms f where f.supplier_name = v_sup;
    if v_fstatus = 'expired' or (v_expires is not null and v_expires < now()) then
      v_token := null; v_fstatus := null; v_expires := null;
    end if;

    select i.inquiry_code into v_code from inquiry i
    where i.current_supplier = v_sup and i.inquiry_code is not null
      and btrim(i.inquiry_code) <> '' order by i.id limit 1;

    v_rnk    := (v_ranked -> v_sup ->> 'rnk')::int;
    v_isopen := COALESCE((v_ranked -> v_sup ->> 'is_open')::boolean, false);
    -- CHANGE #373: Copy link / Send visibility must not be hidden by Auto Meta.
    -- The v_auto branch that forced can_send=false whenever Auto Meta was ON is
    -- removed; visibility now depends only on engine/lock/is_open, exactly as it
    -- already did whenever Auto Meta was OFF. Auto Meta still independently
    -- drives v_needsauto below (auto-send), which is unchanged.
    v_cansend := CASE
      WHEN NOT v_engine THEN true
      WHEN v_lock AND v_isopen THEN true
      ELSE false
    END;
    -- Auto Meta: fire only for the open supplier whose form is actually PENDING (live, not
    -- expired) and not yet sent. Frontend fires WA, then calls mark_inquiry_wa_sent(name).
    v_needsauto := (v_engine AND v_auto AND v_lock AND v_isopen
                    AND COALESCE(v_fstatus,'') = 'pending' AND v_wa_sent IS NULL);

    return query select v_sup, v_current_count, 0::bigint, v_token, v_fstatus, v_expires,
                        v_code, v_rnk, v_isopen, v_cansend, v_needsauto;
  end loop;
end; $function$

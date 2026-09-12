begin;
do $$
declare v_shop uuid; v_bill uuid; v_med bigint; v_m date; i int; k int;
        v_units numeric; v_rate numeric; v_before int; v_after int; v_hidden int;
begin
  select id into v_med from public."MEDICINE" order by id limit 1;
  insert into public.zones (id, code, name, is_active)
  values (907,'C427DIS','C427 Dismiss Check', false) on conflict (id) do nothing;
  for i in 1..6 loop
    insert into public.pharmacy_profiles (user_id, pharmacy_name, customer_name, address, city, pincode, zone_id, approved, status)
    values (gen_random_uuid(),'C427 dis shop '||i,'x','x','x','000000',907,true,'approved')
    returning id into v_shop;
    for k in 0..3 loop
      v_m := (public._c427_month() - (k||' months')::interval)::date;
      insert into public.pharmacy_purchase_bill (pharmacy_id, supplier_name, invoice_no, invoice_date, status, source, line_count, confirmed_at)
      values (v_shop,'C427 D','C427D/'||i||'/'||k,(v_m+4)::date,'confirmed','photo',1, now())
      returning id into v_bill;
      insert into public.pharmacy_purchase_bill_line (bill_id, line_no, medicine_id, product_name, qty, unit_cost, match_status)
      values (v_bill,1,v_med,'x',30, case when i=1 then 110.00 else 96.00 end,'matched');
    end loop;
  end loop;
  perform public.network_demand_refresh();
  perform public.network_overpay_refresh();
  select count(*) into v_before from public.pharmacy_overpay_insight i
    join public.pharmacy_profiles p on p.id=i.pharmacy_id where p.zone_id=907 and i.status='new';
  -- the pharmacy hides it
  update public.pharmacy_overpay_insight i set status='dismissed', dismissed_at=now()
    from public.pharmacy_profiles p where p.id=i.pharmacy_id and p.zone_id=907;
  -- tonight's rebuild runs again
  perform public.network_overpay_refresh();
  select count(*) into v_hidden from public.pharmacy_overpay_insight i
    join public.pharmacy_profiles p on p.id=i.pharmacy_id where p.zone_id=907 and i.status='dismissed';
  select count(*) into v_after from public.pharmacy_overpay_insight i
    join public.pharmacy_profiles p on p.id=i.pharmacy_id where p.zone_id=907 and i.status='new';
  raise notice 'C427 DISMISS CHECK: generated=% still_hidden_after_rebuild=% resurfaced=% -> %',
    v_before, v_hidden, v_after, case when v_before=1 and v_hidden=1 and v_after=0 then 'PASS' else 'FAIL' end;
end $$;
rollback;

\set ON_ERROR_STOP on
begin;
set local request.jwt.claim.email = 'test.admin@medibo.in';
set local request.jwt.claims = '{"sub":"c2f2c733-5c40-43ec-b8b6-1ff2f913320d","email":"test.admin@medibo.in","role":"authenticated"}';
do $t$
declare
  v_mid bigint; v_name text; v_chk jsonb; v_req jsonb; v_rec jsonb; v_ex jsonb;
  v_pend bigint; v_appr jsonb; v_status jsonb; v_doc jsonb; v_ids bigint[];
begin
  -- 1. The duplicate guard answers with the product we already have.
  select id, product_name into v_mid, v_name from public."MEDICINE"
   where coalesce(btrim(product_name),'') <> '' order by id limit 1;
  v_chk := public.catalogue_request_check(v_name);
  if coalesce((v_chk->>'duplicate')::boolean,false) is not true
     or (v_chk->'product'->>'id')::bigint is null then
    raise exception 'E2E: duplicate not detected for %: %', v_name, v_chk;
  end if;
  -- ...and an empty name is refused with its own sentence, not an exception.
  if (public.catalogue_request_check('')->>'error') <> 'need_name' then
    raise exception 'E2E: empty name must be refused';
  end if;
  -- ...and a name nobody has is not a duplicate.
  if coalesce((public.catalogue_request_check('Zzq Nonexistent 999 Tablet')->>'duplicate')::boolean,true) then
    raise exception 'E2E: a novel name must not read as a duplicate';
  end if;

  -- 2. The WRITE enforces the same guard, so a stale form cannot slip past it.
  v_req := public.catalogue_request_product(v_name, 'Whoever');
  if (v_req->>'error') <> 'duplicate' then
    raise exception 'E2E: the write must re-check: %', v_req;
  end if;

  -- 3. A genuine request lands in the SAME queue the approver already works.
  v_req := public.catalogue_request_product('Zzq Nonexistent 999 Tablet','Zzq Labs','Testolol 10mg','10 tablets');
  if coalesce(v_req->>'ok','') <> 'true' then raise exception 'E2E: request failed %', v_req; end if;
  v_pend := (v_req->>'request_id')::bigint;
  if not exists (select 1 from public.supplier_pending_medicines
                  where id = v_pend and status='pending' and salt='Testolol 10mg'
                    and pack='10 tablets') then
    raise exception 'E2E: the request did not carry salt/pack';
  end if;

  -- 4. Approval adds the product, STAMPS created_at (which is what makes it
  --    "recently added"), and records which product the request became.
  v_appr := public.admin_approve_pending_medicine(v_pend, 'Zzq Nonexistent 999 Tablet',
                                                  'Zzq Labs', 'Test class', '10');
  if coalesce(v_appr->>'ok','') <> 'true' or (v_appr->>'catalogue_row_added') <> 'true' then
    raise exception 'E2E: approve failed %', v_appr;
  end if;
  if not exists (select 1 from public."MEDICINE"
                  where id = (v_appr->>'product_id')::bigint and created_at is not null) then
    raise exception 'E2E: created_at was not stamped on approval';
  end if;
  if not exists (select 1 from public.supplier_pending_medicines
                  where id = v_pend and status='approved'
                    and approved_product_id = (v_appr->>'product_id')::bigint) then
    raise exception 'E2E: the request was not linked to its product';
  end if;

  -- 5. It is now "recently added", and the card carries the badge.
  v_rec := public.catalogue_recent(30);
  if coalesce(v_rec->>'ok','') <> 'true' or (v_rec->>'count')::int < 1 then
    raise exception 'E2E: recent empty %', (v_rec - 'groups');
  end if;
  if (public._cat_cards(array[(v_appr->>'product_id')::bigint])->0->>'is_new') <> 'true'
     or (public._cat_cards(array[(v_appr->>'product_id')::bigint])->0->>'new_badge') = '' then
    raise exception 'E2E: the New badge is missing';
  end if;
  -- An OLD row (no created_at) must NOT be new.
  if (public._cat_cards(array[v_mid])->0->>'is_new') <> 'false' then
    raise exception 'E2E: a row with no created_at must not read as new';
  end if;
  -- ...and the tab only offers itself now that there IS something.
  if (public.catalogue_extras()->'recent'->>'show') <> 'true' then
    raise exception 'E2E: the recent tab should be offered once something is new';
  end if;

  -- 6. The export. The PAYLOAD is what matters here: four columns, and no
  --    price anywhere in the document.
  select array_agg(id) into v_ids from (
    select id from public."MEDICINE" where coalesce(btrim(product_name),'') <> ''
     order by id limit 5) s;
  v_ex := public.catalogue_export_start(v_ids, 'My list');
  if coalesce(v_ex->>'ok','') <> 'true' or (v_ex->>'count')::int <> 5 then
    raise exception 'E2E: export start wrong %', v_ex;
  end if;
  v_doc := public.catalogue_export_render_input((v_ex->>'export_id')::uuid);
  if coalesce(v_doc->>'ok','') <> 'true'
     or jsonb_array_length(v_doc->'invoice'->'lines') <> 5
     or jsonb_array_length(v_doc->'invoice'->'columns') <> 4 then
    raise exception 'E2E: export payload wrong: %', (v_doc->'invoice'->'columns');
  end if;
  -- The whole point: not one rupee anywhere in the document, and not one
  -- money-shaped KEY on a line or a column. Asserted on the keys and the rupee
  -- glyph rather than on the word "price", because the disclosure deliberately
  -- SAYS "Prices are not shown on this list." - a substring match on the copy
  -- would fail on the very sentence that makes the promise.
  if (v_doc->'invoice')::text like '%₹%' then
    raise exception 'E2E: the export printed a rupee: %', left((v_doc->'invoice')::text, 300);
  end if;
  if exists (select 1 from jsonb_array_elements(v_doc->'invoice'->'lines') l,
                          jsonb_object_keys(l) k
              where k ~* '^(mrp|price|rate|amount|taxable|margin|ptr|pricing|total)$') then
    raise exception 'E2E: a line carries a money key';
  end if;
  if exists (select 1 from jsonb_array_elements(v_doc->'invoice'->'columns') c
              where (c->>'key') ~* '^(mrp|price|rate|amount|taxable|margin|ptr|total)$') then
    raise exception 'E2E: a column is a money column';
  end if;
  if (select array_agg(c->>'key' order by ord)
        from jsonb_array_elements(v_doc->'invoice'->'columns') with ordinality x(c, ord))
     <> array['desc','company','pack','rxflag'] then
    raise exception 'E2E: the export columns changed shape';
  end if;
  if jsonb_array_length(v_doc->'invoice'->'totals') <> 0
     or (v_doc->'invoice'->'net'->>'value') <> '' then
    raise exception 'E2E: a catalogue list has no totals';
  end if;

  -- 7. An empty selection is refused with the backend's sentence.
  if (public.catalogue_export_start(array[]::bigint[])->>'error') <> 'empty' then
    raise exception 'E2E: an empty export must be refused';
  end if;

  raise notice 'C748 E2E OK  request=% product=% recent=% export_rows=%',
    v_pend, (v_appr->>'product_id'), (v_rec->>'count'), (v_ex->>'count');
end $t$;
rollback;

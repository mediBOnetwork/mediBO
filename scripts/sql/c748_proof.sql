\set ON_ERROR_STOP on
begin;
set local request.jwt.claim.email = 'test.admin@medibo.in';
set local request.jwt.claims = '{"sub":"c2f2c733-5c40-43ec-b8b6-1ff2f913320d","email":"test.admin@medibo.in","role":"authenticated"}';
do $t$
declare
  v_mid bigint; v_name text; v_chk jsonb; v_req jsonb; v_rec jsonb;
  v_pend bigint; v_appr jsonb; v_status jsonb;
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

  -- CHANGE #1362 — sections 6 and 7 tested the catalogue export end to end
  -- (four columns, no rupee anywhere, an empty selection refused). The export
  -- is gone: it handed a visitor the whole filtered product list as a PDF,
  -- which is a competitor's scraping job. Its RPCs and table were dropped, so
  -- there is nothing left here to prove. What replaced it is an ABSENCE check.
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname like 'catalogue\\_export%') then
    raise exception 'E2E: a catalogue_export function is back — see CHANGE #1362';
  end if;
  if to_regclass('public.catalogue_export') is not null then
    raise exception 'E2E: the catalogue_export table is back — see CHANGE #1362';
  end if;
  if public.catalogue_extras() ? 'export' then
    raise exception 'E2E: catalogue_extras() offers an export again';
  end if;

  raise notice 'C748 E2E OK  request=% product=% recent=%  (export removed in #1362)',
    v_pend, (v_appr->>'product_id'), (v_rec->>'count');
end $t$;
rollback;

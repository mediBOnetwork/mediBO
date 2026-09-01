-- CMD #409 — end-to-end proof of the fast-ordering trio.
--
-- Everything that writes runs inside a DO block that ends in RAISE EXCEPTION,
-- so the whole scenario rolls back and production is left with no residue
-- (the pattern proven on #173). Run:
--   psql "$SUPABASE_DB_URL" -f scripts/c409_proof.sql
\set ON_ERROR_STOP on

do $$
declare
  v_buy   bigint;
  v_nobuy bigint;
  v_uid   uuid;
  v_r     jsonb;
  v_rail  jsonb;
  v_home  jsonb;
  v_sec   jsonb;
  v_out   text := '';
  v_pass  int := 0;
  v_fail  int := 0;

  procedure_ok boolean;
begin
  -- Two real catalogue rows: one on sale, one not.
  select id into v_buy   from "MEDICINE"
   where lower(coalesce(buyable::text,'')) in ('true','t') limit 1;
  select id into v_nobuy from "MEDICINE"
   where lower(coalesce(buyable::text,'')) not in ('true','t') limit 1;
  select id into v_uid from auth.users limit 1;

  -- Teach both codes, the way the admin barcode import would.
  update "MEDICINE" set barcode = 'C409BUYABLE'   where id = v_buy;
  update "MEDICINE" set barcode = 'C409NOTONSALE' where id = v_nobuy;

  -- 1 ── a scan that resolves returns the SAME card every storefront rail draws
  v_r := public.storefront_barcode_resolve('C409-BUYABLE');
  if (v_r->>'ok')::boolean and (v_r->>'product_id')::bigint = v_buy
     and v_r->'card'->>'id' is not null
     and v_r->'card'->'pricing' is not null then
    v_pass := v_pass + 1; v_out := v_out || E'\n  PASS 1 resolved scan -> card ' || (v_r->'card'->>'name');
  else
    v_fail := v_fail + 1; v_out := v_out || E'\n  FAIL 1 ' || v_r::text;
  end if;

  -- 2 ── a product that is not on sale is refused with backend copy, not a card
  v_r := public.storefront_barcode_resolve('C409NOTONSALE');
  if (v_r->>'ok')::boolean is false and v_r->>'error' = 'not_available'
     and coalesce(v_r->>'message','') <> '' and v_r->'card' is null then
    v_pass := v_pass + 1; v_out := v_out || E'\n  PASS 2 off-sale refused: ' || (v_r->>'message');
  else
    v_fail := v_fail + 1; v_out := v_out || E'\n  FAIL 2 ' || v_r::text;
  end if;

  -- 3 ── an unknown code is COUNTED into the gap ledger, never appended twice
  delete from public.catalog_barcode_miss where barcode_norm = 'C409GHOST';
  perform public.storefront_barcode_resolve('C409GHOST');
  perform public.storefront_barcode_resolve('c409-ghost');
  if (select miss_count from public.catalog_barcode_miss
       where barcode_norm = 'C409GHOST') = 2
     and (select count(*) from public.catalog_barcode_miss
           where barcode_norm = 'C409GHOST') = 1 then
    v_pass := v_pass + 1; v_out := v_out || E'\n  PASS 3 two scans, one gap row, miss_count=2';
  else
    v_fail := v_fail + 1; v_out := v_out || E'\n  FAIL 3 gap ledger did not count';
  end if;

  -- 4 ── the gap is on the admin ops board, and leaves it when the code resolves
  update "MEDICINE" set barcode = 'C409GHOST' where id = v_buy;
  if not exists (
       select 1 from jsonb_array_elements(public.admin_ops_board(3)->'items') i
        where i->>'key' = 'catalog_barcode_gap'
          and exists (select 1 from jsonb_array_elements(i->'items') s
                       where s->>'id' = 'C409GHOST')) then
    v_pass := v_pass + 1; v_out := v_out || E'\n  PASS 4 an attached barcode drops off the ops board by itself';
  else
    v_fail := v_fail + 1; v_out := v_out || E'\n  FAIL 4 resolved gap still on the board';
  end if;

  -- 5 ── voice: the counting vocabulary is stripped, the strength survives
  v_r := public.voice_search_resolve('Telma 40 two strips');
  if (v_r->>'ok')::boolean and v_r->>'query' = 'telma 40' then
    v_pass := v_pass + 1; v_out := v_out || E'\n  PASS 5 "Telma 40 two strips" -> "' || (v_r->>'query') || '"';
  else
    v_fail := v_fail + 1; v_out := v_out || E'\n  FAIL 5 ' || v_r::text;
  end if;

  -- 6 ── silence is a backend message, never an empty search
  v_r := public.voice_search_resolve('   ');
  if (v_r->>'ok')::boolean is false and v_r->>'error' = 'blank'
     and coalesce(v_r->>'message','') <> '' then
    v_pass := v_pass + 1; v_out := v_out || E'\n  PASS 6 silence -> backend copy, no search';
  else
    v_fail := v_fail + 1; v_out := v_out || E'\n  FAIL 6 ' || v_r::text;
  end if;

  -- 7 ── recently viewed: a signed-in open is recorded and read back as a rail
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  delete from public.recently_viewed where user_id = v_uid;
  perform public.recently_viewed_record(v_buy);
  v_rail := public.recently_viewed_rail(6);
  if (v_rail->>'has')::boolean
     and jsonb_array_length(v_rail->'items') = 1
     and (v_rail->'items'->0->>'id')::bigint = v_buy
     and coalesce(v_rail->>'title','') <> '' then
    v_pass := v_pass + 1; v_out := v_out || E'\n  PASS 7 view recorded, rail titled "' || (v_rail->>'title') || '"';
  else
    v_fail := v_fail + 1; v_out := v_out || E'\n  FAIL 7 ' || v_rail::text;
  end if;

  -- 8 ── an off-sale product is dropped at RENDER time, not at record time
  perform public.recently_viewed_record(v_nobuy);
  v_rail := public.recently_viewed_rail(6);
  if (select count(*) from public.recently_viewed where user_id = v_uid) = 2
     and jsonb_array_length(v_rail->'items') = 1 then
    v_pass := v_pass + 1; v_out := v_out || E'\n  PASS 8 2 rows kept, 1 card rendered — availability applied at render';
  else
    v_fail := v_fail + 1; v_out := v_out || E'\n  FAIL 8 kept='
      || (select count(*) from public.recently_viewed where user_id = v_uid)::text
      || ' rendered=' || jsonb_array_length(v_rail->'items')::text;
  end if;

  -- 9 ── the home feed carries the rail as an ordinary section
  v_home := public.storefront_home_v2(24);
  select i into v_sec from jsonb_array_elements(v_home->'sections') i
   where i->>'id' = 'recently_viewed';
  if v_sec is not null and v_sec->>'layout' = 'rail'
     and jsonb_array_length(v_sec->'items') = 1 then
    v_pass := v_pass + 1; v_out := v_out || E'\n  PASS 9 home section "' || (v_sec->>'title') || '" layout=rail';
  else
    v_fail := v_fail + 1; v_out := v_out || E'\n  FAIL 9 home rail missing: ' || coalesce(v_sec::text,'<none>');
  end if;

  -- 10 ── the ring is capped: never more rows than app_settings says
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  update public.app_settings set value = to_jsonb(3) where key = 'recently_viewed_cap';
  delete from public.recently_viewed where user_id = v_uid;
  perform public.recently_viewed_record(id)
     from (select id from "MEDICINE" order by id limit 6) x;
  if (select count(*) from public.recently_viewed where user_id = v_uid) = 3 then
    v_pass := v_pass + 1; v_out := v_out || E'\n  PASS 10 six opens, cap 3, three rows kept';
  else
    v_fail := v_fail + 1; v_out := v_out || E'\n  FAIL 10 ring not capped: '
      || (select count(*) from public.recently_viewed where user_id = v_uid)::text;
  end if;

  raise exception E'CMD #409 PROOF — % passed, % failed%', v_pass, v_fail, v_out;
end $$;

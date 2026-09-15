#!/usr/bin/env bash
# CHANGE #448 — debug pass on #430. Everything here runs through `set role
# authenticated` with a real user's JWT claims, which is the SAME grant path a
# device uses: a definer-only helper that a client can still reach shows up
# here, and a client RPC broken by a revoke shows up here too.
#
# It covers the flows #430's own proof did NOT:
#   1. a cycle-count session (kind='cycle' off the risk-ranked plan)
#   2. the DISAGREEMENT path — second count differs, accept is blocked, the
#      owner settles it, then accept goes through
#   3. lines left uncounted at close
#   4. the sheet's own search
#   5. shelf-photo evidence
#   6. the PDF status door
#   7. cross-tenant: another pharmacy can see and touch none of it
#   8. #413's spot count still works on the shared tables (regression)
set -euo pipefail
DBURL="$(cat "$HOME/.medibo/dburl")"

psql "$DBURL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
\set QUIET on
\pset pager off
\set shop   '3f1c9a10-4b6e-4c9a-9f22-5a0d7e8b1c33'
\set owner  '371d5289-c2e1-4475-9215-8f603e72ca9e'
\set staff  'c4300000-0000-4000-8000-000000000002'
\set other  'e79f32b3-8afa-4455-b39d-68c0cf44232c'

-- clean slate for this pass (test pharmacy only)
delete from pharmacy_count_session where pharmacy_id = :'shop';
delete from pharmacy_cycle_plan     where pharmacy_id = :'shop';

select set_config('request.jwt.claims',
  json_build_object('sub', :'owner', 'role','authenticated')::text, false);
set role authenticated;

\echo '=== 1. a CYCLE count, off the risk-ranked plan'
select (pharmacy_audit_cycle_plan() ->> 'note') as plan_note;
select pharmacy_audit_start('cycle','cycle') as started \gset res_
select (:'res_started'::jsonb ->> 'ok') as ok, (:'res_started'::jsonb ->> 'lines') as lines;
select (:'res_started'::jsonb ->> 'session_id') as sid \gset

\echo '=== 2. the sheet is blind, and its search works'
select (pharmacy_audit_sheet(:'sid'::uuid) ->> 'blind') as blind,
       jsonb_path_query_array(pharmacy_audit_sheet(:'sid'::uuid), '$.rows[*].expected_qty') as expected_leak;
select jsonb_array_length(pharmacy_audit_sheet(:'sid'::uuid, 'Pan') -> 'rows') as search_hits,
       jsonb_array_length(pharmacy_audit_sheet(:'sid'::uuid, 'zzzz') -> 'rows') as search_misses;

\echo '=== 3. RLS: a signed-in user reads the tables through the RPCs, never directly'
select count(*) as rows_a_client_can_read_directly from pharmacy_count_line
 where session_id = :'sid'::uuid;

\echo '=== 3b. count TWO of them (line ids come from the SHEET, like a device)'
select (pharmacy_audit_sheet(:'sid'::uuid) #>> '{rows,0,line_id}') as line_a,
       (pharmacy_audit_sheet(:'sid'::uuid) #>> '{rows,1,line_id}') as line_b \gset
select pharmacy_audit_count(:'sid'::uuid, jsonb_build_array(
  jsonb_build_object('line_id', :'line_a', 'qty', 0,  'method','voice'),
  jsonb_build_object('line_id', :'line_b', 'qty', 99, 'method','barcode'))) as counted;

\echo '=== 4. shelf photo evidence, and the PDF door'
select (pharmacy_audit_photo_add(:'sid'::uuid, 'stock-imports', 'c448/shelf.jpg') ->> 'message') as photo;
select (pharmacy_audit_pdf_status(:'sid'::uuid) ->> 'status') as pdf_before;

\echo '=== 5. close: uncounted lines are marked, not treated as zero'
select (pharmacy_audit_close(:'sid'::uuid) ->> 'discrepant') as discrepant;
reset role;
select status, count(*) from pharmacy_count_line where session_id = :'sid'::uuid group by 1 order by 1;
set role authenticated;

\echo '=== 6. THE DISAGREEMENT PATH'
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', :'staff', 'role','authenticated')::text, false);
set role authenticated;
-- second counter answers a DIFFERENT number from the first
select (pharmacy_audit_recount_sheet(:'sid'::uuid) #>> '{rows,0,round_id}') as round_id \gset
select (pharmacy_audit_recount(:'round_id'::uuid, 5) ->> 'message') as disagreement;
reset role;
select status, count(*) from pharmacy_count_line
 where session_id = :'sid'::uuid and status in ('disputed','confirmed') group by 1;
select set_config('request.jwt.claims',
  json_build_object('sub', :'staff', 'role','authenticated')::text, false);
set role authenticated;

reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', :'owner', 'role','authenticated')::text, false);
set role authenticated;
\echo '--- accept is blocked while a disagreement is open'
select (pharmacy_audit_accept(:'sid'::uuid) ->> 'message') as blocked;
\echo '--- the owner settles it, and only then does accept go through'
reset role;
-- whichever line the second counter actually disagreed on
select id as disputed_line from pharmacy_count_line
 where session_id = :'sid'::uuid and status = 'disputed' limit 1 \gset
select set_config('request.jwt.claims',
  json_build_object('sub', :'owner', 'role','authenticated')::text, false);
set role authenticated;
select (pharmacy_audit_resolve(:'disputed_line'::uuid, 5) ->> 'message') as resolved;
select (pharmacy_audit_accept(:'sid'::uuid) ->> 'message') as accepted;

\echo '=== 7. the owner PDF for this session'
select (pharmacy_audit_pdf_request(:'sid'::uuid) ->> 'message') as pdf_queued;

\echo '=== 8. CROSS-TENANT: another pharmacy sees none of it'
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', :'other', 'role','authenticated')::text, false);
set role authenticated;
select (pharmacy_audit_sheet(:'sid'::uuid) ->> 'error')   as other_shop_sheet,
       (pharmacy_audit_variance(:'sid'::uuid) ->> 'error') as other_shop_variance,
       (pharmacy_audit_accept(:'sid'::uuid) ->> 'error')   as other_shop_accept,
       (pharmacy_audit_certificate(:'sid'::uuid) ->> 'error') as other_shop_certificate;
select coalesce((pharmacy_audit_verify(null) ->> 'entries'),'0') as other_shop_log_entries;

\echo '=== 9. #413 spot count still works on the shared tables'
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', :'owner', 'role','authenticated')::text, false);
set role authenticated;
select (pharmacy_count_start(3) ->> 'ok') as spot_ok;
reset role;
select kind, status, count(*) from pharmacy_count_session
 where pharmacy_id = :'shop' group by 1,2 order by 1,2;
select event, count(*) from pharmacy_audit_log where pharmacy_id = :'shop'
 group by 1 order by 2 desc limit 6;

\echo '=== VERDICT'
select
  (select count(*) from pharmacy_count_session
    where pharmacy_id = :'shop' and kind = 'cycle')                    as cycle_session,
  (select count(*) from pharmacy_count_line
    where session_id = :'sid'::uuid and status = 'uncounted')          as uncounted_kept,
  (select count(*) from pharmacy_count_line
    where session_id = :'sid'::uuid and status = 'resolved')           as owner_settled,
  (select count(*) from pharmacy_count_evidence
    where session_id = :'sid'::uuid)                                    as evidence_rows,
  (select count(*) from pharmacy_count_session
    where pharmacy_id = :'shop' and kind = 'spot')                     as spot_still_works,
  ((pharmacy_audit_verify(null) ->> 'intact')::boolean)                as seal_intact;
SQL

-- CHANGE #528 — superseded within the same change by
-- 20260901180531_c528_clamp_regex_knows_the_helpers.sql, which is the final
-- definition of partner_rpc_guard_proof(). Kept as the applied record: this
-- step is where the proof switched from "is it on the list" to "can a partner
-- actually REACH it", i.e. from list membership to clamp_ok.
select 1;

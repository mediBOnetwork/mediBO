\set ON_ERROR_STOP on
set lock_timeout='20s';

update feature_gaps set status='done', dev_command_id=453, updated_at=now(), notes=
'FIXED (CMD #453). Reproduced: delivery_optimize_run(p_run_id) looked the run up and never compared it to the caller, and PUBLIC held EXECUTE so anon inherited it.
Fix: the sequencer body moved to _delivery_optimize_run_unchecked(); the public delivery_optimize_run() now runs _delivery_run_owned() — the same predicate delivery_apply_google has always used (owner OR _is_admin) — and EXECUTE was revoked from PUBLIC and anon and granted to authenticated + service_role.
Proof (scripts/c453_delivery_proof.sh, one rolled-back transaction, two simulated riders): rider B calling optimize on rider A''s run -> not_authorized with the backend''s own message; the OWNER still gets ok:true; has_function_privilege(anon) is false on all three run RPCs.
Found and fixed en route: the optimiser''s cold-chain re-rank aliased its CTE `r` while `r` was already a record VARIABLE, so that UPDATE raised "column reference r.stop_group is ambiguous" every time it ran — delivery_optimize_run, and delivery_start_run which calls it, had been throwing. The alias is now `q`.'
where id=90;

update feature_gaps set status='done', dev_command_id=453, updated_at=now(), notes=
'FIXED (CMD #453). Reproduced: both functions resolved v_partner from auth.uid() but used a SUPPLIED p_run_id verbatim, so any active rider could start another rider''s run (flipping stops to out_for_delivery, re-optimising and firing delivery_out to every customer) or finish it (marking every open parcel rto).
Fix: after v_run is resolved, both call _delivery_run_owned(v_run) and refuse before any write; delivery_start_run also tolerates an admin caller. EXECUTE revoked from PUBLIC/anon.
Proof: rider B start -> not_authorized AND the run is still status=planned; rider B finish -> not_authorized AND no parcel was marked rto. Both assertions are in scripts/c453_delivery_proof.sh.'
where id=91;

update feature_gaps set status='done', dev_command_id=453, updated_at=now(), notes=
'FIXED (CMD #453). Reproduced both halves: zero Dart references to delivery_attach_signature, and the RPC only wrote signature_path/receiver_name and returned "Signature saved" without ever calling _delivery_complete.
Fix (backend): delivery_attach_signature now takes p_lat/p_lng like every other method, stamps the delivery_events row with them, and ENDS in _delivery_complete(..., ''signature'', ...) — so the custody gate, the cold-chain photo rule and the delivered notification apply to a signature exactly as they do to OTP and photo. The old 3-arg overload was dropped, so PostgREST has exactly one candidate.
Fix (frontend): delivery_proof_sheet.dart gained a fourth method tab (dlv_method_sign) with a signature pad — strokes are flattened to a PNG at submit, uploaded to delivery-proofs/signatures/, and sent as action=signature.
Proof: the RPC body contains _delivery_complete and p_lat; exactly one overload; an unknown delivery id returns not_found rather than silently signing; delivery_replay routes action=signature. Click path: Deliveries -> a stop -> Signature -> sign -> Complete with signature.'
where id=92;

update feature_gaps set status='done', dev_command_id=453, updated_at=now(), notes=
'FIXED (CMD #453). Reproduced: delivery_replay + delivery_action_log existed and covered 8 actions, zero Dart callers, delivery_action_log had 0 rows, and every proof-sheet action called its RPC directly — so an action taken with no signal threw and was lost.
Fix: lib/services/delivery_offline_queue.dart. Every rider write now (1) mints a client_action_id, (2) PERSISTS the action to shared_preferences before sending, (3) sends through delivery_replay, (4) is dropped only once the backend has answered, and (5) drains oldest-first on the next call and at sheet open. All five write paths in delivery_proof_sheet.dart (scan_qr, verify_otp, mark_delivered, fail, partial) plus the new signature path go through it; an unreachable backend returns ok:false + queued:true with the BACKEND''s dlv_offline_queued label, never a Dart-authored sentence.
Proof: test/protected/delivery_batch_a_test.dart — 5 tests, green: unreachable backend queues instead of losing, the action is persisted with its own id and payload, two actions get different ids in order, a failed drain keeps everything queued in order, and the queue survives a restart.'
where id=93;

update feature_gaps set status='done', dev_command_id=453, updated_at=now(), notes=
'FIXED (CMD #453). Reproduced: the function read the log, returned early if a result was found, executed, and only THEN inserted with on-conflict-do-nothing — so two concurrent retries of one key both saw null and both executed; and the result was cached whatever it was, freezing a transient ok:false forever.
Fix: (a) pg_advisory_xact_lock(hashtext(''delivery_replay:''||key)) is taken FIRST, so the second retry waits for the first to commit and then reads its result; (b) only ok:true is written to `result` — a failure goes to the new last_result column and bumps `attempts`, leaving the key retryable.
Proof: attempt 1 on a bad delivery_id returns the real failure; cached rows = 0; last_result rows = 1; the retry re-executes (replayed=false) and attempts=2; a SUCCESSFUL action IS cached and its retry comes back replayed=true; the function body contains pg_advisory_xact_lock.'
where id=94;

update feature_gaps set status='done', dev_command_id=453, updated_at=now(), notes=
'FIXED (CMD #453). Reproduced: grep for "delivery-register" across lib/ returned exactly two hits — the route line in main.dart and the file''s own header comment. Nothing navigated to it.
Fix: a "Deliver with mediBO" row in the account surface (profile_screen.dart, the same _MenuEntryCard shape as Staff logins / Rewards / Wishlist), label from ui_copy key profile.row_deliver_with_us. It is shown to every signed-in account because the screen behind it answers for every case itself. The profile DROPDOWN was not usable for this: feature_registry_surface_ck hard-limits surface=''profile'' to identity.view_profile and identity.logout.
Click path: any account -> Profile -> Deliver with mediBO -> the registration form / application status.'
where id=95;

update feature_gaps set status='done', dev_command_id=453, updated_at=now(), notes=
'FIXED (CMD #453). Re-checked against the live schema: since the audit, admin_review_registration() DOES write status/reviewed_by/reviewed_at (admin_delivery_partners_section.dart calls it), so that half was already closed. Everything else the row names was still missing and is now built.
Fix: (a) review_reason column + admin_review_registration(p_kind,p_id,p_status,p_reason) — the 3-arg overload was dropped so there is still exactly one write path for mr/company/delivery; (b) the applicant is notified through notification_log (channel inapp, so no email trigger fires) on approve and on reject; (c) delivery_partner_register() now writes one inbox row per admin on submit — the alert the audit found missing — and refuses a duplicate application with backend copy; (d) my_delivery_application() is the applicant''s status surface: verdict, tone, reviewer''s reason, submitted/reviewed dates and whether re-applying is offered, all decided server-side; (e) the admin Reject button now opens a reason sheet.
Proof: reject carries the reason back and stores it on the row; the applicant gets an inbox row (event delivery_partner_rejected); my_delivery_application() as that applicant returns status=rejected with status_message = the reviewer''s reason. Click path (admin): Admin -> Delivery -> Delivery Partner -> Reject -> type a reason. (applicant): Profile -> Deliver with mediBO.'
where id=96;

update feature_gaps set status='done', dev_command_id=453, updated_at=now(), notes=
'FIXED (CMD #453). Reproduced both halves: zone_id came from coalesce((p->>''zone_id'')::smallint, v_agency.zone_id) so a payload overrode the agency''s own zone, and user_id was omitted entirely, so every agency-created rider was an account nobody could sign in to (my_delivery_home, my_delivery_run, delivery_shift, delivery_respond, delivery_scan_qr and delivery_start_run all resolve by user_id = auth.uid()).
Fix: (a) the zone is v_agency.zone_id for any non-admin caller — only an admin may name a zone; (b) login provisioning — the rider''s phone/email are registered in login_identities as owner_type=''delivery'' (which is what get_my_role reads), an existing auth account with that phone or email is attached as user_id immediately, and otherwise an 8-char invite_code is minted and returned with backend copy for the agency to pass on; (c) delivery_claim_invite(p_code) lets the rider attach their own login after signing up, with the invite row wired into the Deliver-with-mediBO screen.
Proof: an agency in zone 1 sending zone_id=9 gets a rider in zone 1; the rider has a login_identities row and an 8-char invite code; claiming the invite sets user_id so my_delivery_home resolves them; a bogus code returns invite_not_found with the backend''s own sentence.'
where id=97;

update feature_gaps set status='done', dev_command_id=453, updated_at=now(), notes=
'FIXED (CMD #453). Reproduced: delivery-id-ocr was ACTIVE at version 5 with verify_jwt=true, called from delivery_id_scan.dart:214, and absent from supabase/functions/ in the repo.
Fix: the deployed source was pulled and committed at supabase/functions/delivery-id-ocr/index.ts. Reviewing it against the ABSOLUTE Gemini rule found one deviation: it carried a us-central1 regional fallback, while gemini-ocr (the pattern the row asks it to match) is global-only. It was pinned to the global endpoint alone — same model (gemini-3.5-flash), same GCP_SA_KEY auth, same thinkingLevel=low, retries kept at three — and REDEPLOYED as version 6, so the repo and production are the same file.
The prompt is verbatim-only ("You are a camera, not a database", never invent/expand/correct, unknown fields return ""), which satisfies the OCR NAMING RULE.
Proof: supabase/functions/delivery-id-ocr/index.ts is in the branch; the live function reports version 6; the source contains locations/global and no regional host.'
where id=98;

select id, status, dev_command_id, length(notes) as notes_len from feature_gaps where id between 90 and 98 order by id;

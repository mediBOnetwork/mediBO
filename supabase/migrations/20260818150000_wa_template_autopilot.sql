-- CHANGE #228 — every hardcoded WhatsApp message becomes a Meta template, and
-- mediBO submits them itself. Om never submits a template by hand again.
--
-- Applied to production as the numbered migrations 20260818120000..20260818132000
-- (see supabase_migrations.schema_migrations). This file is the git-side record
-- of what those did and the final shape of every object they touched.
--
-- WHAT WAS WRONG
--   • wa_event_autopilot() already did seed -> draft -> AI review -> lint ->
--     submit -> sync -> auto-enable, but it only ever created drafts from
--     wa_event_template_seeds, and there were 9 seeds for 52 routes. Every other
--     route sat on "Waiting on Meta approval for template X" forever, for a
--     template nothing would ever create. supplier_bill_pending (CHANGE #766)
--     was one of them.
--   • Meta keeps a media header's sample file for a few days. All four handles
--     we held were expired, so any media template submitted today was rejected
--     on the sample alone. Nothing re-uploaded them.
--   • A REJECTED template was a dead end: the route note said "edit it and it
--     will resubmit itself", but nothing ever moved it back into the queue.
--
-- WHAT THIS DOES
--   1. 31 new seeds — one per hardcoded body found in order-notify and its
--      siblings (order-unfulfilled-notify, delivery-notify, supplier-order-notify,
--      stock-notify, inquiry-notify) plus every wa_send_event call site that had
--      no template. Interpolated values became {{1}}..{{n}}; token_map names the
--      wa_tokens key behind each slot; every seed carries Meta example values.
--   2. 33 new wa_tokens (+ the bill_days_waiting computed source) so no slot is
--      left without a real example.
--   3. wa_media_refresh_tick() re-uploads a header sample from our own storage
--      copy whenever the Meta handle is missing or within an hour of expiring,
--      on its own 10-minute cron.
--   4. wa_event_autopilot_run(min_age, allow_unreviewed) replaces the body of
--      wa_event_autopilot(): it carries media headers through from the seed,
--      keeps an unsubmitted draft in sync with its seed WITHOUT stamping on the
--      handle wa-media-header wrote, refuses to submit a media template with no
--      live sample, re-arms a REJECTED template when its seed changes, and caps
--      that at 3 attempts so a rejection can never loop.
--   5. wa_template_pipeline() — the message / template / status / route /
--      approved table, rendered verbatim by the Template pipeline section of
--      WhatsApp Ops.
--   6. Two call-site repairs found on the way: short_dated_push_wa passed its
--      token bag into p_customer_id (a uuid) so the push could never have
--      worked, and wa_send_event had no phone source at all for audience='admin'
--      routes — app_settings.admin_wa_phone existed for exactly that and was
--      never read.
--
-- The function bodies below are the LIVE definitions; re-running this file is a
-- no-op against production.

alter table wa_event_template_seeds add column if not exists header_format text;
alter table wa_event_template_seeds add column if not exists header_media_path text;
alter table wa_event_template_seeds add column if not exists header_media_mime text;
alter table wa_templates add column if not exists submit_attempts int not null default 0;

-- Sample file for the bill_to_customer DOCUMENT header lives at
-- whatsapp-media/templates/medibo_bill_sample.pdf (a one-page sample tax
-- invoice). Meta approved the template on it.

-- wa_media_refresh_tick, _wa_seed_components, wa_event_autopilot_run,
-- wa_event_autopilot, wa_template_pipeline, wa_send_event, short_dated_push_wa
-- and _offer_waitlist_notify_cron are defined by the numbered migrations listed
-- at the top of this file; rg_baseline_all() was re-run afterwards so the
-- regression guard holds their new signatures.

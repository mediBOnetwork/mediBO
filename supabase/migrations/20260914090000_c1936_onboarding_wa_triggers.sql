-- CMD #1936 — Onboarding WhatsApp triggers.
--
-- Four things, all idempotent:
--   1. customer_imported vs customer_registration are now DIFFERENT events.
--      Until today tg_notify_profile_event fired customer_registration on every
--      INSERT into pharmacy_profiles, so an admin import told the shop "we have
--      received your registration" and the customer_imported route — which has
--      existed, enabled, with an approved template — never fired once.
--   2. customer_docs_pending: a daily reminder, 24 h after the account was made,
--      naming the documents customer_doc_types (#1935) still wants. Max 3, and
--      it stops the moment the checklist is complete.
--   3. kyc_document_rejected / kyc_document_verified had NO template, so
--      wa_send_event answered route_disabled and nobody was ever told. They get
--      seeds, and the rejection now carries a link that re-uploads THAT ONE doc
--      rather than the generic https://medibo.in/ everyone was being sent.
--   4. Every queued send records its event_key on the outbox row, so the audit
--      is one index scan instead of a join through audience_params.

-- ════════════════════ 0. schema ════════════════════

-- _customer_event_log has asked to_jsonb(new)->>'created_by_admin' since it
-- shipped and fallen back to is_admin(); the column simply never existed.
-- Adding it makes the answer a FACT on the row rather than a re-reading of
-- whichever session happened to be open — which is what a backfill, a restore
-- or a cron re-insert gets wrong.
alter table public.pharmacy_profiles
  add column if not exists created_by_admin boolean not null default false;

comment on column public.pharmacy_profiles.created_by_admin is
  'CMD #1936 — true when an admin created this row (admin_import_customer / route-tab import). Chooses customer_imported over customer_registration on the WhatsApp switchboard.';

-- A re-upload link that means ONE document, not "your documents". NULL keeps
-- the old whole-checklist behaviour, so every token already minted still works.
alter table public.kyc_upload_token
  add column if not exists kind text;

comment on column public.kyc_upload_token.kind is
  'CMD #1936 — the single kyc_documents.kind this link re-uploads. NULL = the whole checklist (pre-#1936 behaviour).';

-- The outbox row names its own event. Reading "which sends did customer_imported
-- make last week" used to mean joining wa_campaigns and digging audience_params
-- out of jsonb; now it is one index.
alter table public.wa_campaign_recipients
  add column if not exists event_key text;

create index if not exists wa_campaign_recipients_event_key_idx
  on public.wa_campaign_recipients (event_key, created_at desc)
  where event_key is not null;

update public.wa_campaign_recipients r
   set event_key = c.audience_params->>'event_key'
  from public.wa_campaigns c
 where c.id = r.campaign_id
   and r.event_key is null
   and c.audience_kind = 'event_route'
   and coalesce(c.audience_params->>'event_key','') <> '';

-- One row per customer, one reminder ladder. completed_at is the stop: it is
-- written the first time the checklist comes back empty, and the sweep never
-- looks at that customer again.
create table if not exists public.customer_docs_reminder (
  customer_id   uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  sent_count    int  not null default 0,
  last_sent_at  timestamptz,
  last_docs     text,
  completed_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists customer_docs_reminder_open_idx
  on public.customer_docs_reminder (last_sent_at)
  where completed_at is null;

alter table public.customer_docs_reminder enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='customer_docs_reminder'
                    and policyname='customer_docs_reminder_admin_read') then
    create policy customer_docs_reminder_admin_read
      on public.customer_docs_reminder for select
      using (public.is_admin());
  end if;
end $$;

-- ════════════════════ 1. helpers ════════════════════

-- The missing half of #1935's sentence. customer_docs_missing_sentence() wraps
-- the list in the approval-blocked copy; a reminder needs the bare list so the
-- reminder's OWN wording (ui_copy, editable without a deploy) can carry it.
create or replace function public.customer_docs_missing_labels(p_customer_id uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(string_agg(t.label, ', ' order by t.sort_order), '')
    from public.customer_doc_types t
   where t.active and t.required
     and not exists (select 1 from public.kyc_documents kd
                      where kd.owner_kind = 'pharmacy' and kd.owner_id = p_customer_id
                        and kd.kind = t.key
                        and kd.status in ('pending','submitted','verified'));
$function$;

comment on function public.customer_docs_missing_labels(uuid) is
  'CMD #1936 — the required customer_doc_types labels this shop has not answered yet, comma-joined in sort order. Empty string = complete.';

-- One live link per (owner, kind): an unused, unexpired token is REUSED rather
-- than flooding a shop with a new URL on every rejection — the same rule
-- kyc_drive_send already follows for the whole-checklist link.
create or replace function public.kyc_upload_link(
  p_owner_kind text, p_owner_id uuid, p_kind text default null)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_token text;
begin
  if p_owner_id is null then return 'https://medibo.in/'; end if;

  select token into v_token
    from public.kyc_upload_token
   where owner_kind = p_owner_kind and owner_id = p_owner_id
     and kind is not distinct from p_kind
     and used_at is null and expires_at > now()
   order by created_at desc limit 1;

  if v_token is null then
    v_token := replace(gen_random_uuid()::text, '-', '');
    insert into public.kyc_upload_token(token, owner_kind, owner_id, kind)
    values (v_token, p_owner_kind, p_owner_id, p_kind);
  end if;

  update public.kyc_upload_token set sent_at = now() where token = v_token;
  return 'https://medibo.in/kyc-upload/' || v_token;
end $function$;

comment on function public.kyc_upload_link(text, uuid, text) is
  'CMD #1936 — a public re-upload URL. p_kind names ONE document; NULL is the whole checklist.';

-- ════════════════════ 2. imported vs registration ════════════════════

create or replace function public.tg_notify_profile_event()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare ev text; ptype text := TG_ARGV[0];
        new_appr boolean; old_appr boolean; v_phone text; v_name text;
        v_imported boolean; v_extra jsonb := '{}'::jsonb;
begin
  if coalesce(current_setting('medibo.suppress_notify', true), '') = '1' then return NEW; end if;
  if coalesce(NEW.is_deleted, false) then return NEW; end if;

  new_appr := coalesce(NEW.approved, false) or lower(coalesce(NEW.status, '')) in ('approved','active');
  if TG_OP = 'INSERT' then
    -- CMD #1936 — the one line this whole command turns on. The column if the
    -- table carries it, the admin gate if it does not: the SAME answer
    -- _customer_event_log has been writing to customer_event all along, so the
    -- ledger and the message can never disagree about which door a shop walked
    -- in through. A supplier_profiles row has no such column and no import
    -- path, so it reads NULL -> is_admin() -> the old behaviour.
    v_imported := case when ptype = 'customer'
                       then coalesce((to_jsonb(NEW) ->> 'created_by_admin')::boolean,
                                     public.is_admin(), false)
                       else false end;
    ev := case when new_appr then 'approved'
               when v_imported then 'imported'
               else 'registration' end;
  else
    old_appr := coalesce(OLD.approved, false) or lower(coalesce(OLD.status, '')) in ('approved','active');
    if new_appr and not old_appr then ev := 'approved'; else return NEW; end if;
  end if;

  v_phone := public._phone10(coalesce(NEW.whatsapp_no, NEW.phone, ''));
  if not notif_should_send(ptype, ptype || '_' || ev, v_phone) then return NEW; end if;

  if ptype = 'customer' then
    begin
      v_name := coalesce(nullif(btrim(NEW.customer_name),''),
                         nullif(btrim(NEW.owner_name),''), NEW.pharmacy_name, 'there');
    exception when others then v_name := 'there';
    end;

    -- The import message's own tokens: where to sign in, and the checklist it
    -- is asking for. Both are backend strings; Dart never builds either.
    if ev = 'imported' then
      begin
        v_extra := jsonb_build_object(
          'login', 'https://medibo.in/',
          'link',  public.kyc_upload_link('pharmacy', NEW.id, null),
          'docs',  public.customer_docs_missing_labels(NEW.id));
      exception when others then v_extra := jsonb_build_object('login','https://medibo.in/');
      end;
    end if;
  end if;

  begin
    perform public.notify(ptype || '_' || ev, v_phone,
      jsonb_build_object(
        'legacy_url',  'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/user-notify',
        'legacy_body', jsonb_build_object('event', ev, 'ptype', ptype, 'profile_id', NEW.id))
      || case when ptype = 'customer'
              then jsonb_build_object('customer_id', NEW.id, 'customer_name', v_name)
              else '{}'::jsonb end
      || v_extra);
  exception when others then
    perform public._wa_log_attempt(ptype || '_' || ev, null, v_phone, 'skipped', false,
                                   'caller_error: ' || sqlerrm);
  end;
  return NEW;
end $function$;

-- ════════════════════ 3. the import path marks its own rows ════════════════════
--
-- One column on one INSERT. Rather than pasting a 150-line function back —
-- which would quietly revert whatever ANOTHER command changed in it between
-- this branch being cut and this file being replayed on live — the patch is
-- applied to the definition that is actually installed, at replay time, and
-- only when it is not already there.
--
-- lead_import_customer (the route-tab import) calls admin_import_customer, so
-- both import doors are covered by this one edit.
do $patch$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_import_customer'
   limit 1;

  if v_src is null then
    raise notice 'CMD #1936: admin_import_customer not found — nothing to patch';
    return;
  end if;
  if v_src like '%created_by_admin%' then
    return;                                   -- already carries the flag
  end if;

  v_new := replace(v_src,
    E'    customer_code, approved, is_deleted\n  ) VALUES (',
    E'    customer_code, approved, is_deleted, created_by_admin\n  ) VALUES (');
  v_new := replace(v_new,
    E'    v_code, false, false\n  )',
    E'    v_code, false, false, true   -- CMD #1936: the row remembers the import\n  )');

  if v_new = v_src or v_new not like '%created_by_admin%' then
    raise exception 'CMD #1936: could not mark admin_import_customer as an import path — its INSERT no longer matches the expected shape';
  end if;

  execute v_new;
end $patch$;

-- Rows that were imported before this command existed. customer_event already
-- holds the verdict _customer_event_log reached at the time, so the backfill
-- reads the ledger rather than re-guessing.
update public.pharmacy_profiles p
   set created_by_admin = true
 where not p.created_by_admin
   and exists (select 1 from public.customer_event e
                where e.customer_id = p.id and e.event_key = 'customer_imported');

-- ════════════════════ 4. the docs-pending reminder ════════════════════
--
-- Once a day, 24 h after the account was made, while a REQUIRED document from
-- customer_doc_types is still missing. Three at most, and the ladder stops the
-- moment the checklist comes back empty — a shop that finishes after reminder
-- one never sees reminder two.
--
-- The copy names the documents from customer_doc_types.label, so adding a
-- required document (#1935's admin screen) changes what the reminder says with
-- no deploy and no edit here.
create or replace function public.customer_docs_pending_sweep(p_limit int default 200)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_max    int := 3;
  v_gap    interval := interval '20 hours';   -- "once per day", minus clock drift
  v_wait   interval := interval '24 hours';
  r        record;
  v_docs   text;
  v_sent   int := 0; v_done int := 0; v_skipped int := 0;
begin
  for r in
    select p.id, p.pharmacy_name,
           coalesce(nullif(btrim(p.whatsapp_no),''), p.phone) as phone,
           coalesce(rm.sent_count, 0) as sent_count
      from public.pharmacy_profiles p
      left join public.customer_docs_reminder rm on rm.customer_id = p.id
     where not coalesce(p.is_deleted, false)
       and not coalesce(p.approved, false)
       and p.created_at < now() - v_wait
       and rm.completed_at is null
       and coalesce(rm.sent_count, 0) < v_max
       and (rm.last_sent_at is null or rm.last_sent_at < now() - v_gap)
     order by p.created_at
     limit greatest(coalesce(p_limit, 200), 1)
  loop
    v_docs := public.customer_docs_missing_labels(r.id);

    -- Complete: close the ladder and never look at this shop again.
    if coalesce(v_docs, '') = '' then
      insert into public.customer_docs_reminder(customer_id, completed_at, updated_at)
      values (r.id, now(), now())
      on conflict (customer_id) do update
        set completed_at = now(), updated_at = now();
      v_done := v_done + 1;
      continue;
    end if;

    if coalesce(r.phone, '') = '' then
      v_skipped := v_skipped + 1;
      continue;                                 -- nowhere to send it
    end if;

    begin
      perform public.notify('customer_docs_pending', r.phone,
        jsonb_build_object(
          'customer_id',   r.id,
          'customer_name', coalesce(r.pharmacy_name, ''),
          'name',          coalesce(r.pharmacy_name, ''),
          'docs',          v_docs,
          'n',             (r.sent_count + 1)::text,
          'link',          public.kyc_upload_link('pharmacy', r.id, null)));
    exception when others then
      perform public._wa_log_attempt('customer_docs_pending', null, r.phone, 'skipped', false,
                                     'caller_error: ' || sqlerrm);
    end;

    insert into public.customer_docs_reminder(customer_id, sent_count, last_sent_at,
                                              last_docs, updated_at)
    values (r.id, 1, now(), v_docs, now())
    on conflict (customer_id) do update
      set sent_count   = public.customer_docs_reminder.sent_count + 1,
          last_sent_at = now(),
          last_docs    = excluded.last_docs,
          updated_at   = now();
    v_sent := v_sent + 1;
  end loop;

  return jsonb_build_object('ok', true, 'sent', v_sent,
                            'completed', v_done, 'skipped_no_phone', v_skipped);
end $function$;

comment on function public.customer_docs_pending_sweep(int) is
  'CMD #1936 — the daily docs-pending reminder. 24 h after the account was made, max 3, stops when the customer_doc_types checklist is complete.';

-- Once a day at 10:40 IST. Deliberately off the hour and off every other
-- sweep''s minute: pg_cron shares a 60-connection cap and stacking jobs on
-- :00 is what starved the dispatcher the last time.
insert into public.cron_task(name, ord, mode, gate_sql, work_sql, step_timeout_ms,
                             enabled, note, base_interval_s, max_interval_s, run_at_ist, dml)
values ('customer_docs_pending_sweep', 596, 'poll',
        'select exists (select 1 from public.pharmacy_profiles p left join public.customer_docs_reminder rm on rm.customer_id = p.id where not coalesce(p.is_deleted,false) and not coalesce(p.approved,false) and p.created_at < now() - interval ''24 hours'' and rm.completed_at is null and coalesce(rm.sent_count,0) < 3 and (rm.last_sent_at is null or rm.last_sent_at < now() - interval ''20 hours''))',
        'select public.customer_docs_pending_sweep(200);',
        8000, true,
        'CMD #1936 — one WhatsApp reminder a day, naming the customer_doc_types documents a new shop still owes. Max 3, stops when the checklist is complete.',
        86400, 86400, '10:40:00', true)
on conflict (name) do update
  set work_sql   = excluded.work_sql,
      gate_sql   = excluded.gate_sql,
      note       = excluded.note,
      run_at_ist = excluded.run_at_ist,
      enabled    = true;

-- ════════════════════ 5. the rejection carries its own door ════════════════════
--
-- kyc_review_set is the ONE door an admin rules through (kyc_verify_override
-- delegates to it), and it was handing every rejected applicant the site root.
-- Now the rejected document's own re-upload link goes with the reason.
create or replace function public.kyc_review_set(p_doc_id uuid, p_status text, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  d kyc_documents%rowtype;
  v_status text := lower(btrim(coalesce(p_status,'')));
  v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
  v_admin  boolean := public.role_for_medibo_only() in ('admin','super_admin');
  v_zone   int := public.partner_zone_id();
  v_label  text; v_phone text; v_uid uuid; v_name text; v_link text;
begin
  if not public.kyc_can_review('write') then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', _c('kyc_review.err_not_authorized'));
  end if;
  if v_status not in ('verified','rejected') then
    return jsonb_build_object('ok', false, 'error','bad_status', 'tone','danger',
      'message', _c('kyc_review.err_bad_status'));
  end if;
  if v_status = 'rejected' and v_reason is null then
    return jsonb_build_object('ok', false, 'error','no_reason', 'tone','danger',
      'message', _c('kyc_review.err_no_reason'));
  end if;

  select * into d from kyc_documents where id = p_doc_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_doc', 'tone','danger',
      'message', _c('kyc_review.err_no_doc'));
  end if;
  if not v_admin and v_zone is not null and coalesce(d.zone_id,-1) <> v_zone then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', _c('kyc_review.err_not_authorized'));
  end if;

  update kyc_documents
     set status = v_status, reason = v_reason,
         verified_by = auth.uid(), verified_at = now(), updated_at = now()
   where id = p_doc_id;

  v_label := _c('kyc.kind.'||d.kind);
  if d.owner_kind = 'pharmacy' then
    select coalesce(nullif(whatsapp_no,''), phone), user_id, pharmacy_name
      into v_phone, v_uid, v_name from pharmacy_profiles where id = d.owner_id;
  else
    select coalesce(nullif(whatsapp_no,''), phone), user_id, supplier_name
      into v_phone, v_uid, v_name from supplier_profiles where id = d.owner_id;
  end if;

  -- CMD #1936 — a rejection is only actionable if it says where to go. The link
  -- re-uploads THIS document, not "your documents"; a verdict of verified keeps
  -- pointing at the app, where there is nothing left to do for this one.
  begin
    v_link := case when v_status = 'rejected'
                   then public.kyc_upload_link(d.owner_kind, d.owner_id, d.kind)
                   else 'https://medibo.in/' end;
  exception when others then v_link := 'https://medibo.in/';
  end;

  -- The applicant is told, in the app and over WhatsApp. Neither may stall the
  -- verdict: a missing route is not a reason to leave a document unreviewed.
  begin
    perform public.notify(
      case v_status when 'verified' then 'kyc_document_verified'
                    else 'kyc_document_rejected' end,
      v_phone,
      jsonb_build_object('label', v_label, 'reason', coalesce(v_reason,''),
                         'name', coalesce(v_name,''), 'link', v_link)
      || case when d.owner_kind = 'pharmacy'
              then jsonb_build_object('customer_id', d.owner_id,
                                      'customer_name', coalesce(v_name,''))
              else '{}'::jsonb end);
  exception when others then null;
  end;

  return jsonb_build_object('ok', true, 'tone','success',
    'doc_id', p_doc_id, 'status', v_status,
    'message', case v_status when 'verified' then _c('kyc_review.verified_toast')
                             else _c('kyc_review.rejected_toast') end,
    'reupload_link', case when v_status = 'rejected' then v_link end,
    'owner_state', public.kyc_state(d.owner_kind, d.owner_id));
end
$function$;

-- ════════════════════ 6. one link, one document ════════════════════
--
-- A pharmacy's document kinds are customer_doc_types keys (#1935), not the
-- kyc.kind.* copy keys the supplier side uses, so the label comes from the
-- table first and falls back to the copy row.
create or replace function public.kyc_kind_label(p_owner_kind text, p_kind text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(
    (select t.label from public.customer_doc_types t
      where t.key = p_kind and lower(coalesce(p_owner_kind,'')) = 'pharmacy'),
    nullif(public._c('kyc.kind.' || coalesce(p_kind,'')), ''),
    coalesce(p_kind, ''));
$function$;

comment on function public.kyc_kind_label(text, text) is
  'CMD #1936 — the printable name of a document kind: customer_doc_types for a pharmacy, the kyc.kind.* copy row otherwise.';

-- The token form now shows the ONE document its link was minted for. A token
-- with no kind is every pre-#1936 link and keeps the whole-checklist wording.
create or replace function public.kyc_token_form(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare t kyc_upload_token%rowtype; v_name text; v_state jsonb; v_kind text;
begin
  select * into t from kyc_upload_token where token = btrim(coalesce(p_token,''));
  if not found then
    return jsonb_build_object('ok', false, 'error','unknown',
      'title', _c('kyc_token.title'), 'message', _c('kyc_token.err_unknown'));
  end if;
  if t.expires_at < public.now_eff() then
    return jsonb_build_object('ok', false, 'error','expired',
      'title', _c('kyc_token.title'), 'message', _c('kyc_token.err_expired'));
  end if;

  if t.owner_kind = 'pharmacy' then
    select pharmacy_name into v_name from pharmacy_profiles where id = t.owner_id;
  else
    select supplier_name into v_name from supplier_profiles where id = t.owner_id;
  end if;

  update kyc_upload_token set opened_at = coalesce(opened_at, now()) where token = t.token;
  v_state := public.kyc_state(t.owner_kind, t.owner_id);
  v_kind  := coalesce(nullif(btrim(coalesce(t.kind,'')),''), 'drug_licence');

  return jsonb_build_object(
    'ok', true,
    'token', t.token,
    'title', _c('kyc_token.title'),
    'subtitle', _c('kyc_token.subtitle'),
    'for_line', _cf('kyc_token.for_label', jsonb_build_object('name', coalesce(v_name,''))),
    'deadline_line', case when (v_state->>'grace_until') is null then ''
                          else _cf('kyc_token.deadline', jsonb_build_object(
                                 'd', to_char((v_state->>'grace_until')::date,'FMDD Mon YYYY'))) end,
    'kind', v_kind,
    'kind_label', public.kyc_kind_label(t.owner_kind, v_kind),
    'single_doc', (t.kind is not null),
    'number_label', _c('kyc.number_label'),
    'number_hint', _c('kyc_token.number_hint'),
    'expiry_hint', _c('kyc_token.expiry_hint'),
    'file_hint', _c('kyc_token.file_hint'),
    'submit_label', _c('kyc_token.submit'),
    'done_title', _c('kyc_token.done_title'),
    'done_body', _c('kyc_token.done_body'),
    'bucket', 'kyc-docs',
    'upload_prefix', 'token/'||t.token,
    'already_done', (t.used_at is not null),
    'used_message', _c('kyc_token.err_used'),
    'state', v_state);
end
$function$;

create or replace function public.kyc_token_submit(p_token text, p_path text,
  p_number text default null, p_valid_to date default null, p_file_name text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare t kyc_upload_token%rowtype; v_zone smallint; v_doc uuid; v_conf jsonb;
        v_kind text; v_id_kind text;
begin
  select * into t from kyc_upload_token where token = btrim(coalesce(p_token,''));
  if not found then
    return jsonb_build_object('ok', false, 'error','unknown', 'tone','danger',
      'message', _c('kyc_token.err_unknown'));
  end if;
  if t.expires_at < now() then
    return jsonb_build_object('ok', false, 'error','expired', 'tone','danger',
      'message', _c('kyc_token.err_expired'));
  end if;
  if nullif(btrim(coalesce(p_path,'')),'') is null then
    return jsonb_build_object('ok', false, 'error','no_path', 'tone','danger',
      'message', _c('kyc.err_no_path'));
  end if;
  if p_valid_to is not null and p_valid_to < (now() at time zone 'Asia/Kolkata')::date then
    return jsonb_build_object('ok', false, 'error','expiry_past', 'tone','danger',
      'message', _c('kyc.err_expiry_past'));
  end if;

  -- CMD #1936 — the kind the link was minted for. NULL is every pre-#1936
  -- token, and those all meant the drug licence.
  v_kind := coalesce(nullif(btrim(coalesce(t.kind,'')),''), 'drug_licence');
  v_id_kind := case
                 when v_kind in ('drug_licence','dl_20b','dl_21b') then 'dl'
                 when v_kind in ('gst','gst_certificate')          then 'gstin'
               end;

  -- A number is only claimable for the kinds that HAVE a national identity.
  -- A shop photo has no number, and running the licence conflict check on one
  -- would refuse a perfectly good upload.
  if v_id_kind is not null then
    v_conf := public.kyc_identity_conflict(v_id_kind, p_number, t.owner_kind, t.owner_id::text);
    if coalesce((v_conf->>'has')::boolean, false) then
      return jsonb_build_object('ok', false, 'error','duplicate', 'tone','danger',
        'message', v_conf->>'message', 'conflict', v_conf);
    end if;
  end if;

  if t.owner_kind = 'pharmacy' then
    select zone_id into v_zone from pharmacy_profiles where id = t.owner_id;
  else
    select zone_id into v_zone from supplier_profiles where id = t.owner_id;
  end if;

  update kyc_documents set status = 'superseded', updated_at = now()
   where owner_kind = t.owner_kind and owner_id = t.owner_id
     and kind = v_kind and status in ('pending','verified','rejected');

  insert into kyc_documents(owner_kind, owner_id, kind, path, file_name, number,
                            valid_to, zone_id, source)
  values (t.owner_kind, t.owner_id, v_kind, btrim(p_path),
          nullif(btrim(coalesce(p_file_name,'')),''),
          nullif(btrim(coalesce(p_number,'')),''), p_valid_to, v_zone, 'token')
  returning id into v_doc;

  if v_id_kind = 'dl' then
    if t.owner_kind = 'pharmacy' then
      update pharmacy_profiles
         set drug_license = coalesce(nullif(btrim(coalesce(p_number,'')),''), drug_license),
             dl_expiry    = coalesce(p_valid_to, dl_expiry)
       where id = t.owner_id;
    else
      update supplier_profiles
         set drug_license = coalesce(nullif(btrim(coalesce(p_number,'')),''), drug_license),
             dl_expiry    = coalesce(p_valid_to, dl_expiry)
       where id = t.owner_id;
    end if;
  end if;

  update kyc_upload_token set used_at = now() where token = t.token;

  return jsonb_build_object('ok', true, 'tone','success', 'doc_id', v_doc,
    'kind', v_kind, 'kind_label', public.kyc_kind_label(t.owner_kind, v_kind),
    'title', _c('kyc_token.done_title'), 'message', _c('kyc_token.done_body'),
    'verify', public.kyc_verify_panel(v_doc));
end $function$;

-- ════════════════════ 7. the automatic verdict says the same thing ════════════════════
--
-- kyc_verify_doc is the machine's own rejection path. It was handing out the
-- same site root, so an applicant rejected by the checks and an applicant
-- rejected by an admin got two different messages for one outcome. Two token
-- expressions change; the send itself is left exactly as that function wrote
-- it, so this cannot revert whatever else has landed in it.
do $patch$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'kyc_verify_doc'
   limit 1;

  if v_src is null then
    raise notice 'CMD #1936: kyc_verify_doc not found — nothing to patch';
    return;
  end if;
  if v_src like '%kyc_upload_link%' then
    return;                                   -- already carries the direct link
  end if;

  v_new := replace(v_src,
    E'jsonb_build_object(''label'', _c(''kyc.kind.''||d.kind),',
    E'jsonb_build_object(''label'', public.kyc_kind_label(d.owner_kind, d.kind),');
  v_new := replace(v_new,
    E'''name'', coalesce(v_name,''''), ''link'', ''https://medibo.in/''),',
    E'''name'', coalesce(v_name,''''),\n                           ''link'', case when v_tier = ''clear'' then ''https://medibo.in/''\n                                          else public.kyc_upload_link(d.owner_kind, d.owner_id, d.kind) end),');

  if v_new not like '%kyc_upload_link%' or v_new not like '%kyc_kind_label%' then
    raise exception 'CMD #1936: could not point kyc_verify_doc''s rejection at the document it rejected — its send block no longer matches the expected shape';
  end if;

  execute v_new;
end $patch$;

-- ════════════════════ 8. the switchboard ════════════════════
--
-- customer_imported and customer_registration already existed as separate rows
-- with separate templates and separate toggles — only the emitter conflated
-- them. Their emitter_hint is corrected so the switchboard screen tells the
-- truth about which code path fires each, and customer_docs_pending is added.
insert into public.wa_event_routes(event_key, label, description, audience,
                                   enabled, auto_manage, auto_template_name, emitter_hint)
values ('customer_docs_pending',
        'Documents still pending',
        'A daily reminder, 24 hours after the account was created, naming the required documents the shop has not sent yet. At most three, and it stops the moment the checklist is complete.',
        'customer', true, true, 'customer_docs_pending',
        'customer_docs_pending_sweep() — daily cron, max 3 per customer')
on conflict (event_key) do update
  set label       = excluded.label,
      description = excluded.description,
      audience    = excluded.audience,
      auto_manage = true,
      auto_template_name = excluded.auto_template_name,
      emitter_hint = excluded.emitter_hint;

update public.wa_event_routes
   set emitter_hint = 'tg_notify_profile_event — ONLY an admin import (admin_import_customer / route-tab import). Never self-signup.',
       description  = coalesce(nullif(description,''),
         'Sent when an admin adds a shop from the customer list or a route stop: how to sign in, and the documents we need.')
 where event_key = 'customer_imported';

update public.wa_event_routes
   set emitter_hint = 'tg_notify_profile_event — ONLY a self-signup submit. Never an admin import.',
       description  = coalesce(nullif(description,''),
         'Sent when a shop registers itself. An imported shop gets customer_imported instead.')
 where event_key = 'customer_registration';

update public.wa_event_routes
   set emitter_hint = 'kyc_review_set (admin verdict) and kyc_verify_doc (automatic). Carries the reason and a link that re-uploads that one document.',
       auto_manage = true,
       auto_template_name = coalesce(auto_template_name, 'kyc_document_rejected')
 where event_key = 'kyc_document_rejected';

update public.wa_event_routes
   set emitter_hint = 'kyc_review_set (admin verdict) and kyc_verify_doc (automatic).',
       auto_manage = true,
       auto_template_name = coalesce(auto_template_name, 'kyc_document_verified')
 where event_key = 'kyc_document_verified';

update public.wa_event_routes
   set emitter_hint = 'tg_notify_profile_event — approval succeeded (approved/status moved to approved).'
 where event_key = 'customer_approved';

-- Templates. The autopilot turns a seed into a DRAFT, policy-reviews it,
-- submits it to Meta and switches the route on the moment Meta approves — so a
-- seed is the whole of "add a WhatsApp message", and nothing here waits on a
-- human. kyc_document_rejected and kyc_document_verified have had enabled
-- routes and NO template since they shipped, which is why wa_send_event has
-- been answering route_disabled and nobody was ever told about their documents.
insert into public.wa_event_template_seeds(name, category, language, components, token_map)
values
  ('customer_docs_pending', 'UTILITY', 'en',
   jsonb_build_array(
     jsonb_build_object('type','BODY',
       'text', 'Hello {{1}}, your mediBO account is almost ready. We still need: {{2}}. Upload them here: {{3}}'),
     jsonb_build_object('type','FOOTER', 'text','mediBO')),
   jsonb_build_array('name','docs','link')),
  ('kyc_document_rejected', 'UTILITY', 'en',
   jsonb_build_array(
     jsonb_build_object('type','BODY',
       'text', 'Hello {{1}}, we could not accept your {{2}}. Reason: {{3}}. Please upload it again here: {{4}}'),
     jsonb_build_object('type','FOOTER', 'text','mediBO')),
   jsonb_build_array('name','label','reason','link')),
  ('kyc_document_verified', 'UTILITY', 'en',
   jsonb_build_array(
     jsonb_build_object('type','BODY',
       'text', 'Hello {{1}}, your {{2}} has been verified. Thank you.'),
     jsonb_build_object('type','FOOTER', 'text','mediBO')),
   jsonb_build_array('name','label'))
on conflict do nothing;

-- The tokens the template manager offers for these messages. source_kind
-- 'manual' means the emitter supplies the value, which is exactly what the
-- trigger and the sweep now do.
insert into public.wa_tokens(key, label, group_label, source_kind, source_ref, example, enabled, is_system, sort_order)
values
  ('docs',  'Documents still needed', 'Onboarding', 'manual', null, 'Drug Licence 20B, GST Certificate', true, false, 810),
  ('link',  'Action link',            'Onboarding', 'manual', null, 'https://medibo.in/kyc-upload/…',    true, false, 820),
  ('login', 'Sign-in link',           'Onboarding', 'manual', null, 'https://medibo.in/',                true, false, 830),
  ('label', 'Document name',          'Onboarding', 'manual', null, 'Drug Licence 20B',                  true, false, 840),
  ('reason','Rejection reason',       'Onboarding', 'manual', null, 'The licence number was unreadable', true, false, 850)
on conflict (key) do nothing;

-- The Notifications screen's own rows, so each event is a labelled switch and
-- not an unexplained key. notif_is_enabled defaults to ON without them; these
-- exist so an admin can find and turn them off.
insert into public.notification_settings(audience, action_key, label, enabled, channel)
values
  ('customer','customer_imported',      'Account created for you by mediBO', true, 'all'),
  ('customer','customer_registration',  'Registration received',             true, 'all'),
  ('customer','customer_docs_pending',  'Documents still pending',           true, 'all'),
  ('customer','customer_approved',      'Account approved',                  true, 'all'),
  ('customer','kyc_document_rejected',  'Document rejected',                 true, 'all'),
  ('customer','kyc_document_verified',  'Document verified',                 true, 'all')
on conflict do nothing;

-- ════════════════════ 9. the outbox row names its own event ════════════════════
--
-- "Show me every customer_imported we sent this week" meant joining
-- wa_campaigns and reading audience_params out of jsonb — so in practice it was
-- never asked. One column, written where the row is written, and the audit is
-- an index scan. Patched in place for the same reason as the others: this file
-- is replayed on a live function that other commands also edit.
do $patch$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'wa_send_event'
   limit 1;

  if v_src is null then
    raise exception 'CMD #1936: wa_send_event not found';
  end if;
  if v_src like '%is_event, header_media, event_key%' then
    return;                                   -- already stamped
  end if;

  v_new := replace(v_src,
    'insert into wa_campaign_recipients(campaign_id, customer_id, phone, variables, link_code, is_event, header_media)',
    'insert into wa_campaign_recipients(campaign_id, customer_id, phone, variables, link_code, is_event, header_media, event_key)');
  v_new := replace(v_new,
    E'values (v_cid, v_cust, v_ph, public.wa_render_vars(v_varmap, v_tok), v_code, true, v_hdr)',
    E'values (v_cid, v_cust, v_ph, public.wa_render_vars(v_varmap, v_tok), v_code, true, v_hdr, p_event_key)');

  if v_new not like '%is_event, header_media, event_key%'
     or v_new not like '%v_hdr, p_event_key)%' then
    raise exception 'CMD #1936: could not stamp the event key on the outbox row — wa_send_event''s insert no longer matches the expected shape';
  end if;

  execute v_new;
end $patch$;

-- ════════════════════ 10. the admin surface ════════════════════
--
-- Six events decide what a new shop hears, and until now the only way to know
-- whether any of them could actually fire was to read wa_event_routes by hand
-- and notice that two of them had no template. This is that answer, rendered:
-- every string, chip, tone and count is built here and printed verbatim.
create or replace function public.onboarding_notices_screen()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_rows   jsonb := '[]'::jsonb;
  v_queue  jsonb := '[]'::jsonb;
  r        record;
  v_state  text; v_tone text; v_state_label text;
  v_zone   int;
  v_date   date;
  v_pending int := 0; v_ladder_done int := 0;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'title', _c('onboard_notices.title'),
      'message', _c('onboard_notices.err_not_authorized'));
  end if;

  -- Partner admins see their own zone; a super admin sees every zone. The
  -- header picker is the only place a zone is chosen.
  v_zone := public.admin_active_zone();
  -- The header picker owns both. Every window below is measured back from the
  -- chosen DATE, not from wall-clock now(), so scrolling the picker back a week
  -- shows what this screen said a week ago instead of today's answer.
  v_date := coalesce(public.admin_active_date(), (now() at time zone 'Asia/Kolkata')::date);

  for r in
    select er.event_key, er.label, er.description, er.enabled, er.template_id,
           er.template_name, er.emitter_hint, er.pipeline_note,
           coalesce((select wt.status from wa_templates wt where wt.id = er.template_id), '') as tpl_status,
           (select count(*) from wa_campaign_recipients cr
             where cr.event_key = er.event_key
               and cr.created_at >= (v_date - 29) and cr.created_at < (v_date + 1)) as sent_30d,
           (select max(cr.created_at) from wa_campaign_recipients cr
             where cr.event_key = er.event_key
              and cr.created_at < (v_date + 1)) as last_at
      from wa_event_routes er
     where er.event_key = any (array['customer_imported','customer_registration',
                                     'customer_docs_pending','kyc_document_verified',
                                     'kyc_document_rejected','customer_approved'])
     order by array_position(array['customer_imported','customer_registration',
                                   'customer_docs_pending','kyc_document_verified',
                                   'kyc_document_rejected','customer_approved'], er.event_key)
  loop
    if not r.enabled then
      v_state := 'off';
    elsif r.template_id is null or upper(coalesce(r.tpl_status,'')) <> 'APPROVED' then
      v_state := 'waiting';
    else
      v_state := 'live';
    end if;

    v_tone := case v_state when 'live' then 'success'
                           when 'waiting' then 'warning'
                           else 'neutral' end;
    v_state_label := _c('onboard_notices.state_' || v_state);

    v_rows := v_rows || jsonb_build_object(
      'event_key',    r.event_key,
      'label',        r.label,
      'description',  coalesce(r.description, ''),
      'fires_when',   coalesce(r.emitter_hint, ''),
      'state',        v_state,
      'state_label',  v_state_label,
      'state_tone',   v_tone,
      'enabled',      r.enabled,
      'template_label', case when coalesce(r.template_name,'') = ''
                             then _c('onboard_notices.no_template')
                             else _cf('onboard_notices.template_line',
                                      jsonb_build_object('t', r.template_name,
                                                         's', coalesce(nullif(r.tpl_status,''),'—'))) end,
      'note',         coalesce(r.pipeline_note, ''),
      'sent_label',   _cf('onboard_notices.sent_30d', jsonb_build_object('n', r.sent_30d::text)),
      'last_label',   case when r.last_at is null then _c('onboard_notices.never_sent')
                          else _cf('onboard_notices.last_sent',
                                   jsonb_build_object('t', to_char(r.last_at at time zone 'Asia/Kolkata',
                                                                   'FMDD Mon, HH12:MI AM'))) end);
  end loop;

  -- The reminder ladder, as it actually stands. This is the one list that says
  -- whether the docs-pending rule is doing anything at all.
  for r in
    select p.id, p.pharmacy_name, p.customer_code, p.created_at,
           coalesce(rm.sent_count, 0) as sent_count, rm.last_sent_at, rm.completed_at,
           public.customer_docs_missing_labels(p.id) as docs
      from pharmacy_profiles p
      left join customer_docs_reminder rm on rm.customer_id = p.id
     where not coalesce(p.is_deleted, false)
       and not coalesce(p.approved, false)
       and (v_zone is null or p.zone_id = v_zone)
       and p.created_at >= (v_date - 89) and p.created_at < (v_date + 1)
     order by p.created_at desc
     limit 50
  loop
    if coalesce(r.docs, '') = '' then
      v_ladder_done := v_ladder_done + 1;
      continue;
    end if;
    v_pending := v_pending + 1;
    v_queue := v_queue || jsonb_build_object(
      'customer_id', r.id,
      'title',       coalesce(nullif(btrim(r.pharmacy_name),''), coalesce(r.customer_code,'')),
      'subtitle',    _cf('onboard_notices.missing_line', jsonb_build_object('docs', r.docs)),
      'chip_label',  _cf('onboard_notices.reminder_chip',
                         jsonb_build_object('n', r.sent_count::text, 'max', '3')),
      'chip_tone',   case when r.sent_count >= 3 then 'danger'
                          when r.sent_count > 0  then 'warning'
                          else 'neutral' end,
      'meta',        case when r.last_sent_at is null
                          then _c('onboard_notices.no_reminder_yet')
                          else _cf('onboard_notices.last_reminder',
                                   jsonb_build_object('t', to_char(r.last_sent_at at time zone 'Asia/Kolkata',
                                                                   'FMDD Mon, HH12:MI AM'))) end);
  end loop;

  return jsonb_build_object(
    'ok', true,
    'title',          _c('onboard_notices.title'),
    'subtitle',       _c('onboard_notices.subtitle'),
    'events_heading', _c('onboard_notices.events_heading'),
    'queue_heading',  _c('onboard_notices.queue_heading'),
    'queue_hint',     _c('onboard_notices.queue_hint'),
    'queue_empty',    _c('onboard_notices.queue_empty'),
    'events',         v_rows,
    'queue',          v_queue,
    'summary',        _cf('onboard_notices.summary',
                          jsonb_build_object('pending', v_pending::text,
                                             'complete', v_ladder_done::text)),
    'zone_label',     case when v_zone is null then _c('onboard_notices.zone_all')
                           else coalesce((select z.name from zones z where z.id = v_zone),
                                         v_zone::text) end,
    'as_of',          _cf('onboard_notices.as_of',
                          jsonb_build_object('d', to_char(v_date, 'FMDD Mon YYYY'))));
end $function$;

grant execute on function public.onboarding_notices_screen() to authenticated;
grant execute on function public.customer_docs_missing_labels(uuid) to authenticated;
grant execute on function public.kyc_kind_label(text, text) to authenticated;

-- ════════════════════ 11. every word on the screen ════════════════════
--
-- Nothing below is written in Dart. Changing any of it is an UPDATE on this
-- table, not a deploy.
insert into public.ui_copy(key, value) values
  ('onboard_notices.title',             to_jsonb('Onboarding notices'::text)),
  ('onboard_notices.subtitle',          to_jsonb('What a new shop hears from us, and when.'::text)),
  ('onboard_notices.err_not_authorized', to_jsonb('This screen is for mediBO staff.'::text)),
  ('onboard_notices.events_heading',    to_jsonb('Triggers'::text)),
  ('onboard_notices.queue_heading',     to_jsonb('Waiting on documents'::text)),
  ('onboard_notices.queue_hint',        to_jsonb('One reminder a day, three at most. It stops as soon as the checklist is complete.'::text)),
  ('onboard_notices.queue_empty',       to_jsonb('No shop is waiting on documents.'::text)),
  ('onboard_notices.state_live',        to_jsonb('Live'::text)),
  ('onboard_notices.state_waiting',     to_jsonb('Waiting on Meta'::text)),
  ('onboard_notices.state_off',         to_jsonb('Switched off'::text)),
  ('onboard_notices.no_template',       to_jsonb('No template yet'::text)),
  ('onboard_notices.template_line',     to_jsonb('{t} · {s}'::text)),
  ('onboard_notices.sent_30d',          to_jsonb('{n} sent in 30 days'::text)),
  ('onboard_notices.never_sent',        to_jsonb('Never sent'::text)),
  ('onboard_notices.last_sent',         to_jsonb('Last sent {t}'::text)),
  ('onboard_notices.missing_line',      to_jsonb('Still needs: {docs}'::text)),
  ('onboard_notices.reminder_chip',     to_jsonb('Reminder {n} of {max}'::text)),
  ('onboard_notices.no_reminder_yet',   to_jsonb('No reminder sent yet'::text)),
  ('onboard_notices.last_reminder',     to_jsonb('Last reminder {t}'::text)),
  ('onboard_notices.summary',           to_jsonb('{pending} waiting · {complete} complete'::text)),
  ('onboard_notices.zone_all',          to_jsonb('All zones'::text)),
  ('onboard_notices.as_of',             to_jsonb('As of {d}'::text)),
  ('onboard_notices.loading',           to_jsonb('Reading the switchboard…'::text)),
  ('onboard_notices.retry',             to_jsonb('Try again'::text)),
  ('admin_nav.overflow_onboarding_notices', to_jsonb('Onboarding notices'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- The reminder's own wording, kept next to the screen's so both are one edit.
insert into public.ui_copy(key, value) values
  ('custdoc.reminder_body', to_jsonb('Your mediBO account is almost ready — we still need: {docs}'::text))
on conflict (key) do nothing;

-- ════════════════════ 12. the way in ════════════════════
--
-- CHANGE #325 removed the overflow popup: a destination that does not fit the
-- five tabs is a feature_registry row, and the dashboard category, the command
-- palette and /admin/go/<key> all read from there. So this row IS the entry
-- point — there is no second list to keep in step.
-- feature_registry.icon_key is a foreign key into ui_icon, and the icon map in
-- nav_registry_view.dart already knows this key — the row just has to exist.
insert into public.ui_icon(icon_key, label)
values ('phonelink_ring', 'Phone ring')
on conflict (icon_key) do nothing;

insert into public.feature_registry(
  feature_key, label, group_label, icon_key, route_key, sort_order, owner,
  partner_eligible, default_access, is_active, category, surface,
  roles_allowed, deep_link, search_terms, description, canonical_key,
  test_entry, test_roles, test_steps, test_expect,
  test_automatable, test_critical)
values (
  'admin.onboarding_notices', 'Onboarding notices', 'Communication',
  'phonelink_ring', 'onboarding_notices', 65, 'medibo',
  false, 'none', true, 'more_comms', 'dashboard',
  array['admin','super_admin'], '/admin/go/onboarding_notices',
  'onboarding welcome imported registration documents pending kyc rejected approved whatsapp',
  'What a new shop hears from us: the import message, the self-signup message, the daily documents reminder, the two document verdicts and the approval.',
  'admin.onboarding_notices', '/admin/go/onboarding_notices',
  array['admin','super_admin'],
  '[{"kind": "auth", "role": "{role}"}, {"kind": "goto", "path": "/admin/go/onboarding_notices"}, {"ms": 6000, "kind": "settle"}]'::jsonb,
  '{"key": "boot_status", "kind": "visible", "equals": "painted", "source": "render_log"}'::jsonb,
  true, false)
on conflict (feature_key) do update
  set label        = excluded.label,
      group_label  = excluded.group_label,
      icon_key     = excluded.icon_key,
      route_key    = excluded.route_key,
      category     = excluded.category,
      surface      = excluded.surface,
      roles_allowed = excluded.roles_allowed,
      deep_link    = excluded.deep_link,
      search_terms = excluded.search_terms,
      description  = excluded.description,
      is_active    = true;

-- The offline mirror the protected suite checks (test/protected/registered_routes.dart)
-- is generated from THIS table, so the row and the hand-added entry must ship
-- together — the next regeneration after deploy reproduces the same file.
insert into public.surface_route(route_key, feature_key, kind, handled_by, note, is_active)
values ('onboarding_notices', 'admin.onboarding_notices', 'feature', 'home_shell',
        'CMD #1936 — opened by shell_extra_routes.dart, not the shell''s own switch: home_shell.dart sits at 1,998 of a hard 2,000-line guard.',
        true)
on conflict (route_key, feature_key) do update
  set kind        = excluded.kind,
      handled_by  = excluded.handled_by,
      note        = excluded.note,
      is_active   = true;

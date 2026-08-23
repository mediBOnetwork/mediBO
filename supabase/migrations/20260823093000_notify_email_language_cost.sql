-- ═══════════════════════════════════════════════════════════════════════════
-- cmd #299 — PART 3 of 3 of the notification rebuild.
--   • email as the THIRD channel (push → WhatsApp → email) via Resend
--   • per-user language (Hindi / English) across all three channels
--   • per-event cost tracking + an admin cost dashboard
--   • per-event email toggle + per-user opt-outs in notification_settings
--
-- IDEMPOTENT BY CONSTRUCTION. Parts 1 (#297) and 2 (#298) land the notify()
-- dispatcher and the push channel in parallel with this file, and a resumed
-- worker re-applies migrations. So every object here is `if not exists` /
-- `create or replace`, and notification_log is built additively: whoever
-- creates the table first wins the base, everyone else only adds columns.
--
-- This part does NOT own notify(). It attaches to notification_log instead:
--   • a BEFORE INSERT trigger stamps the per-send cost on every channel
--   • an AFTER INSERT trigger fires the email channel as fallback/record
-- That keeps the email channel correct no matter how part 1 writes notify(),
-- and notify() can also call notif_send_email() directly.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────── 1. sending identity config ──
-- The From domain is send.medibo.in — the verified Resend sending subdomain
-- (DKIM resend._domainkey, DMARC p=quarantine). Moving off it breaks DKIM
-- alignment, so it lives in ONE editable row and never as a code literal.
create table if not exists public.notification_email_config (
  id             text primary key default 'singleton',
  enabled        boolean     not null default true,
  from_display   text        not null default 'mediBO <notifications@send.medibo.in>',
  reply_to       text        not null default 'medibonetwork@gmail.com',
  brand_name     text        not null default 'mediBO',
  default_language text      not null default 'en',
  header_en      text        not null default 'mediBO',
  header_hi      text        not null default 'mediBO',
  footer_en      text        not null default 'Jai Mahakal Medical And Surgical (mediBO), Chhattisgarh, India. You are receiving this because you have a mediBO business account.',
  footer_hi      text        not null default 'जय महाकाल मेडिकल एंड सर्जिकल (mediBO), छत्तीसगढ़, भारत। आपको यह ईमेल इसलिए मिला है क्योंकि आपका mediBO व्यापार खाता है।',
  updated_at     timestamptz not null default now()
);
insert into public.notification_email_config (id) values ('singleton')
  on conflict (id) do nothing;

comment on table public.notification_email_config is
  'cmd #299 — the ONE place the email sending identity and branded wrapper live. '
  'from_display must stay on send.medibo.in (verified Resend domain, DKIM aligned).';

-- ───────────────────────────────────────── 2. route columns: email + costing ──
alter table public.wa_event_routes
  add column if not exists email_enabled     boolean not null default false,
  add column if not exists email_mode        text    not null default 'fallback',
  add column if not exists email_subject     text,
  add column if not exists email_body        text,
  add column if not exists email_subject_hi  text,
  add column if not exists email_body_hi     text,
  add column if not exists wa_category       text    not null default 'utility';

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'wa_event_routes_email_mode_ck') then
    alter table public.wa_event_routes
      add constraint wa_event_routes_email_mode_ck
      check (email_mode in ('off','fallback','always'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'wa_event_routes_wa_category_ck') then
    alter table public.wa_event_routes
      add constraint wa_event_routes_wa_category_ck
      check (wa_category in ('utility','marketing','authentication','service'));
  end if;
end $$;

comment on column public.wa_event_routes.email_mode is
  'off = never email. fallback = email only when the earlier channel failed. '
  'always = email every time, as the permanent record.';

-- Marketing-class events are the expensive ones on WhatsApp; naming them here
-- is what makes the savings figure on the cost dashboard honest.
update public.wa_event_routes set wa_category = 'marketing'
 where event_key in ('offer_match','offer_back_in_stock','short_dated_offer',
                     'back_in_stock','reorder_due')
   and wa_category = 'utility';
update public.wa_event_routes set wa_category = 'authentication'
 where event_key in ('delivery_otp') and wa_category = 'utility';

-- ─────────────────────────────────────── 3. notification_log (shared, additive) ──
create table if not exists public.notification_log (
  id           bigserial primary key,
  created_at   timestamptz not null default now(),
  event_key    text,
  channel      text        not null,
  audience     text,
  recipient_id uuid,
  recipient    text,
  ok           boolean,
  status       text        not null default 'queued',
  reason       text,
  detail       jsonb       not null default '{}'::jsonb
);

alter table public.notification_log
  add column if not exists event_key      text,
  add column if not exists channel        text,
  add column if not exists audience       text,
  add column if not exists recipient_id   uuid,
  add column if not exists recipient      text,
  add column if not exists ok             boolean,
  add column if not exists status         text,
  add column if not exists reason         text,
  add column if not exists detail         jsonb,
  add column if not exists language       text,
  add column if not exists provider_id    text,
  add column if not exists order_id       uuid,
  add column if not exists vars           jsonb,
  add column if not exists subject        text,
  add column if not exists body           text,
  add column if not exists wa_category    text,
  add column if not exists cost           numeric(12,4),
  add column if not exists cost_currency  text,
  add column if not exists parent_log_id  bigint,
  add column if not exists sent_at        timestamptz;

alter table public.notification_log alter column detail set default '{}'::jsonb;
alter table public.notification_log alter column vars   set default '{}'::jsonb;
alter table public.notification_log alter column cost   set default 0;
alter table public.notification_log alter column cost_currency set default 'INR';
alter table public.notification_log alter column status set default 'queued';

create index if not exists notification_log_event_idx   on public.notification_log (event_key, created_at desc);
create index if not exists notification_log_channel_idx on public.notification_log (channel, created_at desc);
create index if not exists notification_log_recip_idx   on public.notification_log (recipient, created_at desc);

alter table public.notification_log enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='notification_log'
                    and policyname='notification_log_admin_read') then
    create policy notification_log_admin_read on public.notification_log
      for select using (public.get_my_role() in ('admin','super_admin'));
  end if;
end $$;

-- ──────────────────────────────────────────────── 4. per-send cost config ──
-- Meta bills WhatsApp per conversation category; push and email are ours.
-- Rates are editable config, never literals in a query, because Meta reprices.
create table if not exists public.notification_cost_config (
  channel    text not null,
  category   text not null default 'all',
  unit_cost  numeric(12,4) not null default 0,
  currency   text not null default 'INR',
  label      text not null default '',
  updated_at timestamptz not null default now(),
  primary key (channel, category)
);

insert into public.notification_cost_config (channel, category, unit_cost, label) values
  ('whatsapp','utility',        0.1150, 'WhatsApp utility'),
  ('whatsapp','marketing',      0.7800, 'WhatsApp marketing'),
  ('whatsapp','authentication', 0.1150, 'WhatsApp authentication'),
  ('whatsapp','service',        0.0000, 'WhatsApp service (free window)'),
  ('whatsapp','all',            0.1150, 'WhatsApp (default)'),
  ('push','all',                0.0000, 'Push notification'),
  ('email','all',               0.0000, 'Email (Resend)'),
  ('inapp','all',               0.0000, 'In-app inbox')
on conflict (channel, category) do nothing;

create or replace function public.notif_unit_cost(p_channel text, p_category text)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce(
    (select unit_cost from notification_cost_config
      where channel = p_channel and category = coalesce(nullif(p_category,''),'all')),
    (select unit_cost from notification_cost_config
      where channel = p_channel and category = 'all'),
    0)::numeric;
$$;

-- Whoever inserts the log row — notify(), the WhatsApp layer, the push layer,
-- this file's email dispatch — the charge is stamped here, once, from config.
create or replace function public._notif_stamp_cost()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_cat text;
begin
  new.channel := coalesce(new.channel, 'whatsapp');
  if new.wa_category is null then
    select wa_category into v_cat from wa_event_routes where event_key = new.event_key;
    new.wa_category := coalesce(v_cat, 'utility');
  end if;
  if coalesce(new.cost, 0) = 0 then
    -- Meta bills a conversation that actually went out. A send we refused
    -- (opt-out, no window, suppressed) and a send that failed are both free,
    -- so only a delivered-or-in-flight attempt is charged.
    if coalesce(new.status,'') in ('skipped','blocked','suppressed')
       or new.ok is false then
      new.cost := 0;
    else
      new.cost := public.notif_unit_cost(new.channel, new.wa_category);
    end if;
  end if;
  new.cost_currency := coalesce(new.cost_currency, 'INR');
  return new;
end $$;

drop trigger if exists _notif_stamp_cost_trg on public.notification_log;
create trigger _notif_stamp_cost_trg
  before insert on public.notification_log
  for each row execute function public._notif_stamp_cost();

-- ────────────────────────────────── 5. per-user opt-outs in notification_settings ──
-- The table stays the global matrix it already is: those rows keep user_id NULL.
-- A per-user opt-out is a row with user_id set, so nothing existing moves and
-- no row is deleted — only the key widens to (audience, action_key, channel, user).
alter table public.notification_settings
  add column if not exists user_id uuid,
  add column if not exists channel text not null default 'all';

do $$ begin
  if exists (select 1 from pg_constraint where conname = 'notification_settings_pkey') then
    alter table public.notification_settings drop constraint notification_settings_pkey;
  end if;
end $$;

create unique index if not exists notification_settings_global_uk
  on public.notification_settings (audience, action_key, channel)
  where user_id is null;
create unique index if not exists notification_settings_user_uk
  on public.notification_settings (user_id, audience, action_key, channel)
  where user_id is not null;

-- The pre-existing readers must keep seeing ONLY the global rows, or one
-- opt-out would silently mute an event for everybody.
create or replace function public.notif_is_enabled(p_audience text, p_action_key text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce(
    (select enabled from notification_settings
      where audience = p_audience and action_key = p_action_key
        and user_id is null and channel = 'all'),
    true);
$$;

create or replace function public.set_notification_setting(
  p_audience text, p_action_key text, p_enabled boolean)
returns boolean language plpgsql security definer set search_path to 'public' as $$
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'forbidden'; end if;
  update notification_settings
     set enabled = p_enabled, updated_at = now()
   where audience = p_audience and action_key = p_action_key
     and user_id is null and channel = 'all';
  return found;
end $$;

-- One question, one answer: may this event reach this person on this channel?
create or replace function public.notif_user_allows(
  p_user_id uuid, p_audience text, p_action_key text, p_channel text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select public.notif_is_enabled(p_audience, p_action_key)
     and not exists (
       select 1 from notification_settings
        where user_id = p_user_id
          and audience = p_audience
          and action_key = p_action_key
          and channel in ('all', p_channel)
          and enabled is false);
$$;

-- ────────────────────────────────────────────── 6. per-user language (hi / en) ──
-- One resolver for all three channels. pharmacy_profiles.wa_language already
-- carried the customer's WhatsApp language; it is now THE language of record,
-- so a buyer who reads Hindi gets Hindi on push, WhatsApp and email alike.
create or replace function public.notif_norm_lang(p_lang text)
returns text language sql immutable as $$
  select case when lower(coalesce(p_lang,'')) like 'hi%' then 'hi' else 'en' end;
$$;

create or replace function public.notif_language_for(
  p_user_id uuid default null, p_phone text default null, p_email text default null)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare v text;
begin
  select wa_language into v from pharmacy_profiles
   where (p_user_id is not null and user_id = p_user_id)
      or (p_phone   is not null and p_phone <> '' and right(regexp_replace(coalesce(phone,''),'\D','','g'),10) = right(regexp_replace(p_phone,'\D','','g'),10))
      or (p_email   is not null and p_email <> '' and lower(coalesce(email,'')) = lower(p_email))
   order by (user_id = p_user_id) desc nulls last
   limit 1;
  if v is null or v = '' then
    select default_language into v from notification_email_config where id = 'singleton';
  end if;
  return public.notif_norm_lang(v);
end $$;

comment on function public.notif_language_for(uuid,text,text) is
  'cmd #299 — the ONE language resolver. push, WhatsApp and email all ask it, '
  'so a person never gets two channels in two languages.';

create or replace function public.notif_set_language(p_user_id uuid, p_lang text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_lang text := public.notif_norm_lang(p_lang);
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'forbidden'; end if;
  update pharmacy_profiles set wa_language = v_lang where user_id = p_user_id;
  return jsonb_build_object('ok', found, 'language', v_lang);
end $$;

create or replace function public.notif_set_my_language(p_lang text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_lang text := public.notif_norm_lang(p_lang);
begin
  if auth.uid() is null then raise exception 'forbidden'; end if;
  update pharmacy_profiles set wa_language = v_lang where user_id = auth.uid();
  return jsonb_build_object('ok', true, 'language', v_lang);
end $$;

-- ──────────────────────────────────────── 7. rendering: one variable_map, 3 channels ──
-- {{tokens}} are exactly the ones already listed in wa_event_routes.variable_map,
-- so an email never drifts from the WhatsApp template it mirrors.
create or replace function public.notif_render(p_text text, p_vars jsonb)
returns text language plpgsql immutable as $$
declare v_out text := coalesce(p_text,''); k text;
begin
  if p_vars is null then return v_out; end if;
  for k in select jsonb_object_keys(p_vars) loop
    v_out := replace(v_out, '{{' || k || '}}', coalesce(p_vars->>k, ''));
  end loop;
  -- Any token the caller did not supply renders as nothing, never as "{{x}}".
  return regexp_replace(v_out, '\{\{[a-zA-Z0-9_]+\}\}', '', 'g');
end $$;

create or replace function public.notif_email_template(p_event_key text, p_lang text)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'subject', case when public.notif_norm_lang(p_lang) = 'hi'
                    then coalesce(nullif(r.email_subject_hi,''), r.email_subject)
                    else r.email_subject end,
    'body',    case when public.notif_norm_lang(p_lang) = 'hi'
                    then coalesce(nullif(r.email_body_hi,''), r.email_body)
                    else r.email_body end,
    'label',   r.label,
    'audience',r.audience,
    'language',public.notif_norm_lang(p_lang),
    'variable_map', coalesce(r.variable_map, '[]'::jsonb))
  from wa_event_routes r where r.event_key = p_event_key;
$$;

-- The branded wrapper. Table-based and inline-styled because mail clients are
-- not browsers; colours are the mediBO design tokens, stated once, here.
create or replace function public.notif_email_html(
  p_title text, p_body_text text, p_lang text)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare c record; v_lang text := public.notif_norm_lang(p_lang);
        v_head text; v_foot text; v_body text;
begin
  select * into c from notification_email_config where id = 'singleton';
  v_head := case when v_lang = 'hi' then c.header_hi else c.header_en end;
  v_foot := case when v_lang = 'hi' then c.footer_hi else c.footer_en end;

  v_body := '<p style="margin:0 0 16px 0;">' ||
            replace(replace(
              replace(replace(replace(coalesce(p_body_text,''),'&','&amp;'),'<','&lt;'),'>','&gt;'),
              E'\n\n', '</p><p style="margin:0 0 16px 0;">'),
              E'\n', '<br/>') ||
            '</p>';

  return
  '<!doctype html><html><body style="margin:0;padding:0;background:#F5F6F8;">'
  '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F5F6F8;padding:24px 0;">'
  '<tr><td align="center">'
  '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#FFFFFF;border:1px solid #E5E7EB;border-radius:16px;">'
  '<tr><td style="padding:20px 24px;border-bottom:1px solid #E5E7EB;">'
  '<span style="font:700 20px/1.3 Arial,Helvetica,sans-serif;color:#1B7A43;">' || v_head || '</span>'
  '</td></tr>'
  '<tr><td style="padding:24px;font:400 15px/1.6 Arial,Helvetica,sans-serif;color:#111827;">'
  '<h1 style="margin:0 0 16px 0;font:700 20px/1.3 Arial,Helvetica,sans-serif;color:#111827;">' || coalesce(p_title,'') || '</h1>'
  || v_body ||
  '</td></tr>'
  '<tr><td style="padding:16px 24px;border-top:1px solid #E5E7EB;font:400 13px/1.5 Arial,Helvetica,sans-serif;color:#6B7280;">'
  || v_foot ||
  '</td></tr></table></td></tr></table></body></html>';
end $$;

-- ─────────────────────────────────────────────── 8. the email channel itself ──
-- The edge function closes the row it was handed. The row is opened BEFORE the
-- HTTP call on purpose: if the function never answers, the evidence still exists.
create or replace function public.notif_log_close(
  p_id bigint, p_ok boolean, p_provider_id text default null,
  p_reason text default null, p_detail jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  update notification_log
     set ok       = p_ok,
         status   = case when p_ok then 'sent' else 'failed' end,
         reason   = p_reason,
         provider_id = coalesce(p_provider_id, provider_id),
         detail   = coalesce(detail,'{}'::jsonb) || coalesce(p_detail,'{}'::jsonb),
         sent_at  = case when p_ok then now() else sent_at end,
         -- A send that never left costs nothing, whatever we stamped on open.
         cost     = case when p_ok then cost else 0 end
   where id = p_id;
  return jsonb_build_object('ok', found, 'id', p_id);
end $$;

create or replace function public.notif_send_email(
  p_event_key     text,
  p_to            text    default null,
  p_vars          jsonb   default '{}'::jsonb,
  p_user_id       uuid    default null,
  p_order_id      uuid    default null,
  p_parent_log_id bigint  default null,
  p_dry_run       boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  cfg      record;
  r        record;
  v_to     text := nullif(trim(coalesce(p_to,'')), '');
  v_uid    uuid := p_user_id;
  v_lang   text;
  tpl      jsonb;
  v_subj   text;
  v_bodyt  text;
  v_html   text;
  v_log    bigint;
  v_dedupe int;
begin
  select * into cfg from notification_email_config where id = 'singleton';
  if cfg is null or cfg.enabled is not true then
    return jsonb_build_object('ok', false, 'reason', 'email_channel_off');
  end if;

  select * into r from wa_event_routes where event_key = p_event_key;
  if r is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_event');
  end if;
  if r.email_enabled is not true or r.email_mode = 'off' then
    return jsonb_build_object('ok', false, 'reason', 'email_off_for_event');
  end if;

  -- Address and identity: whichever half the caller knows, we find the other.
  if v_to is null and v_uid is not null then
    select nullif(trim(email),'') into v_to from pharmacy_profiles where user_id = v_uid;
  end if;
  if v_uid is null and v_to is not null then
    select user_id into v_uid from pharmacy_profiles where lower(coalesce(email,'')) = lower(v_to) limit 1;
  end if;
  if v_to is null or position('@' in v_to) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_email_on_file');
  end if;

  if v_uid is not null
     and not public.notif_user_allows(v_uid, r.audience, p_event_key, 'email') then
    return jsonb_build_object('ok', false, 'reason', 'opted_out');
  end if;

  v_lang := public.notif_language_for(v_uid, null, v_to);
  tpl    := public.notif_email_template(p_event_key, v_lang);
  v_subj := public.notif_render(tpl->>'subject', p_vars);
  v_bodyt:= public.notif_render(tpl->>'body',    p_vars);
  if coalesce(v_subj,'') = '' or coalesce(v_bodyt,'') = '' then
    return jsonb_build_object('ok', false, 'reason', 'no_email_template', 'language', v_lang);
  end if;

  -- Same event, same mailbox, inside the route's own dedupe window: one email.
  v_dedupe := coalesce(r.dedupe_minutes, 0);
  if v_dedupe > 0 and exists (
       select 1 from notification_log
        where channel = 'email' and event_key = p_event_key
          and lower(coalesce(recipient,'')) = lower(v_to)
          and created_at > now() - make_interval(mins => v_dedupe)
          and coalesce(status,'') <> 'failed') then
    return jsonb_build_object('ok', false, 'reason', 'deduped');
  end if;

  v_html := public.notif_email_html(v_subj, v_bodyt, v_lang);

  insert into notification_log
    (event_key, channel, audience, recipient_id, recipient, language,
     status, subject, body, vars, order_id, parent_log_id, wa_category)
  values
    (p_event_key, 'email', r.audience, v_uid, v_to, v_lang,
     case when p_dry_run then 'preview' else 'queued' end,
     v_subj, v_bodyt, coalesce(p_vars,'{}'::jsonb), p_order_id, p_parent_log_id, r.wa_category)
  returning id into v_log;

  if p_dry_run then
    return jsonb_build_object('ok', true, 'dry_run', true, 'log_id', v_log,
                              'language', v_lang, 'to', v_to,
                              'subject', v_subj, 'body', v_bodyt, 'html', v_html);
  end if;

  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/email-send',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027',
                                  'Authorization','Bearer ' || public._service_key()),
    body    := jsonb_build_object('to', v_to, 'subject', v_subj, 'html', v_html,
                                  'text', v_bodyt, 'from', cfg.from_display,
                                  'reply_to', cfg.reply_to, 'log_id', v_log,
                                  'event_key', p_event_key),
    timeout_milliseconds := 20000);

  return jsonb_build_object('ok', true, 'log_id', v_log, 'language', v_lang, 'to', v_to);
end $$;

comment on function public.notif_send_email(text,text,jsonb,uuid,uuid,bigint,boolean) is
  'cmd #299 — channel 3. notify() may call this directly; it also fires by itself '
  'from the notification_log trigger, so email works whichever way part 1 dispatches.';

-- Email attaches to the LOG, not to notify()'s internals: every push/WhatsApp
-- attempt part 1 or part 2 records walks past here, and the route decides
-- whether email follows as a fallback or as the permanent record.
create or replace function public._notif_email_after_log()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare r record;
begin
  if new.channel not in ('push','whatsapp') then return new; end if;

  select email_enabled, email_mode into r from wa_event_routes where event_key = new.event_key;
  if not found or r.email_enabled is not true or r.email_mode = 'off' then return new; end if;
  if r.email_mode = 'fallback' and coalesce(new.ok, false) is true then return new; end if;

  begin
    perform public.notif_send_email(
      p_event_key     => new.event_key,
      p_to            => case when position('@' in coalesce(new.recipient,'')) > 0
                              then new.recipient else null end,
      p_vars          => coalesce(new.vars, '{}'::jsonb),
      p_user_id       => new.recipient_id,
      p_order_id      => new.order_id,
      p_parent_log_id => new.id);
  exception when others then
    -- The email channel must never be able to roll back the send it follows.
    insert into notification_log (event_key, channel, status, ok, reason, recipient_id, parent_log_id)
    values (new.event_key, 'email', 'failed', false, left(sqlerrm, 300), new.recipient_id, new.id);
  end;
  return new;
end $$;

drop trigger if exists _notif_email_after_log_trg on public.notification_log;
create trigger _notif_email_after_log_trg
  after insert on public.notification_log
  for each row execute function public._notif_email_after_log();

-- ─────────────────────────────────────────── 9. what every send actually cost ──
-- notification_log is the ledger from part 1 onward. wa_send_attempts is the
-- WhatsApp history that predates it, and it is priced from the same config so
-- the dashboard has real spend on day one. The cutover instant is the first
-- notification_log row, so nothing is ever counted twice.
create or replace view public.notif_cost_events as
  with cutover as (
    select coalesce(min(created_at), 'infinity'::timestamptz) as at
      from notification_log
  )
  select l.created_at, l.event_key, l.channel,
         coalesce(l.ok, false) as ok, coalesce(l.cost, 0) as cost
    from notification_log l
   where coalesce(l.status,'') <> 'preview'
  union all
  select a.created_at, a.event_key, 'whatsapp'::text,
         coalesce(a.ok, false),
         case when coalesce(a.ok,false)
              then public.notif_unit_cost('whatsapp', coalesce(r.wa_category,'utility'))
              else 0 end
    from wa_send_attempts a
    left join wa_event_routes r on r.event_key = a.event_key
   cross join cutover c
   where a.created_at < c.at;

create or replace function public.notif_cost_dashboard(p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_days   integer := greatest(1, least(coalesce(p_days,30), 365));
  v_from   timestamptz := now() - make_interval(days => v_days);
  v_rows   jsonb;
  v_total  numeric := 0;
  v_wa     numeric := 0;
  v_sends  bigint  := 0;
  v_push   bigint  := 0;
  v_email  bigint  := 0;
  v_wacnt  bigint  := 0;
  v_saved  numeric := 0;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'forbidden'; end if;

  select coalesce(sum(cost),0),
         coalesce(sum(cost) filter (where channel='whatsapp'),0),
         count(*),
         count(*) filter (where channel='push'  and ok),
         count(*) filter (where channel='email' and ok),
         count(*) filter (where channel='whatsapp' and ok)
    into v_total, v_wa, v_sends, v_push, v_email, v_wacnt
    from notif_cost_events where created_at >= v_from;

  -- The saving is the WhatsApp bill that never arrived: every event that landed
  -- on push or email is priced at what the SAME event would have cost on
  -- WhatsApp, at that event's own category rate.
  select coalesce(sum(public.notif_unit_cost('whatsapp', coalesce(r.wa_category,'utility'))),0)
    into v_saved
    from notif_cost_events e
    left join wa_event_routes r on r.event_key = e.event_key
   where e.created_at >= v_from and e.ok and e.channel in ('push','email');

  select coalesce(jsonb_agg(x order by x_cost desc, x_sends desc), '[]'::jsonb)
    into v_rows
    from (
      select jsonb_build_object(
               'event_key',   e.event_key,
               'label',       coalesce(r.label, e.event_key),
               'sends_label', to_char(count(*), 'FM999999') || ' sent',
               'whatsapp',    count(*) filter (where e.channel='whatsapp'),
               'push',        count(*) filter (where e.channel='push'),
               'email',       count(*) filter (where e.channel='email'),
               'mix_label',   concat_ws(' · ',
                                nullif('WA ' || count(*) filter (where e.channel='whatsapp'), 'WA 0'),
                                nullif('Push ' || count(*) filter (where e.channel='push'), 'Push 0'),
                                nullif('Email ' || count(*) filter (where e.channel='email'), 'Email 0')),
               'cost_display','₹' || to_char(coalesce(sum(e.cost),0), 'FM999990.00'),
               'share_pct',   case when v_total > 0
                                   then round(100 * coalesce(sum(e.cost),0) / v_total)
                                   else 0 end
             ) as x,
             coalesce(sum(e.cost),0) as x_cost,
             count(*) as x_sends
        from notif_cost_events e
        left join wa_event_routes r on r.event_key = e.event_key
       where e.created_at >= v_from and e.event_key is not null
       group by e.event_key, r.label
    ) t;

  return jsonb_build_object(
    'ok', true,
    'title',       'Notification cost',
    'subtitle',    'What every event costs to deliver, and what push saved.',
    'range_label', 'Last ' || v_days || ' days',
    'totals', jsonb_build_array(
      jsonb_build_object('label','Total spend',
                         'value','₹' || to_char(v_total, 'FM999990.00'),
                         'tone','neutral'),
      jsonb_build_object('label','WhatsApp',
                         'value','₹' || to_char(v_wa, 'FM999990.00'),
                         'tone','warning'),
      jsonb_build_object('label','Notifications sent',
                         'value', to_char(v_sends, 'FM999999'),
                         'tone','neutral'),
      jsonb_build_object('label','Free on push / email',
                         'value', to_char(v_push + v_email, 'FM999999'),
                         'tone','success')),
    'savings', jsonb_build_object(
      'label','Saved versus WhatsApp-only',
      'value','₹' || to_char(v_saved, 'FM999990.00'),
      'note', case when v_push + v_email = 0
                   then 'No push or email deliveries yet in this window.'
                   else to_char(v_push, 'FM999999') || ' push and ' ||
                        to_char(v_email, 'FM999999') || ' email deliveries that would ' ||
                        'otherwise have been billed WhatsApp conversations.' end),
    'rows_heading','Cost per event',
    'rows', v_rows,
    'empty_text','No notifications were sent in this window.',
    'footnote','Rates are the per-conversation charges in notification_cost_config. '
               'Push and email are billed at zero.');
end $$;

comment on function public.notif_cost_dashboard(integer) is
  'cmd #299 — every string the cost dashboard prints. The screen computes nothing.';

-- ──────────────────────────────────────── 10. the admin surface (all strings) ──
create or replace function public.notif_email_admin()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare cfg record; v_rows jsonb;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'forbidden'; end if;
  select * into cfg from notification_email_config where id = 'singleton';

  select coalesce(jsonb_agg(jsonb_build_object(
           'event_key',    r.event_key,
           'label',        r.label,
           'audience',     r.audience,
           'audience_label', initcap(coalesce(r.audience,'')),
           'email_enabled',r.email_enabled,
           'mode',         r.email_mode,
           'mode_label',   case r.email_mode
                             when 'always'   then 'Always email'
                             when 'fallback' then 'Only if WhatsApp fails'
                             else 'Off' end,
           'subject',      coalesce(r.email_subject,''),
           'body',         coalesce(r.email_body,''),
           'subject_hi',   coalesce(r.email_subject_hi,''),
           'body_hi',      coalesce(r.email_body_hi,''),
           'variables',    coalesce(r.variable_map,'[]'::jsonb),
           'status_label', case
                             when r.email_enabled is not true then 'Email off'
                             when coalesce(r.email_subject,'') = '' then 'No template'
                             when coalesce(r.email_subject_hi,'') = '' then 'English only'
                             else 'English + Hindi' end,
           'status_tone',  case
                             when r.email_enabled is not true then 'neutral'
                             when coalesce(r.email_subject,'') = '' then 'danger'
                             when coalesce(r.email_subject_hi,'') = '' then 'warning'
                             else 'success' end)
         order by r.audience, r.label), '[]'::jsonb)
    into v_rows from wa_event_routes r;

  return jsonb_build_object(
    'ok', true,
    'title','Email channel',
    'subtitle','Email is the third channel: push first, then WhatsApp, then email as the fallback and the permanent record.',
    'config', jsonb_build_object(
      'enabled', cfg.enabled,
      'enabled_label', case when cfg.enabled then 'Email channel is on' else 'Email channel is off' end,
      'from_display', cfg.from_display,
      'from_label','Sent from',
      'reply_to', cfg.reply_to,
      'reply_label','Replies go to',
      'domain_note','Sending domain send.medibo.in is verified in Resend. Changing it breaks DKIM.'),
    'mode_options', jsonb_build_array(
      jsonb_build_object('key','off','label','Off'),
      jsonb_build_object('key','fallback','label','Only if WhatsApp fails'),
      jsonb_build_object('key','always','label','Always email')),
    'language_options', jsonb_build_array(
      jsonb_build_object('key','en','label','English'),
      jsonb_build_object('key','hi','label','हिन्दी')),
    'rows', v_rows,
    'empty_text','No notification events are configured yet.');
end $$;

create or replace function public.notif_email_route_set(
  p_event_key text, p_enabled boolean default null, p_mode text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r record;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'forbidden'; end if;
  update wa_event_routes
     set email_enabled = coalesce(p_enabled, email_enabled),
         email_mode    = coalesce(nullif(p_mode,''), email_mode),
         updated_at    = now()
   where event_key = p_event_key
  returning * into r;
  if r is null then
    return jsonb_build_object('ok', false, 'error','unknown_event',
                              'message','That notification event does not exist.');
  end if;
  return jsonb_build_object('ok', true, 'event_key', r.event_key,
    'email_enabled', r.email_enabled, 'mode', r.email_mode,
    'message', case when r.email_enabled then 'Email on for ' || r.label
                    else 'Email off for ' || r.label end);
end $$;

create or replace function public.notif_email_template_save(
  p_event_key text, p_lang text, p_subject text, p_body text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_lang text := public.notif_norm_lang(p_lang);
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'forbidden'; end if;
  if v_lang = 'hi' then
    update wa_event_routes set email_subject_hi = p_subject, email_body_hi = p_body,
           updated_at = now() where event_key = p_event_key;
  else
    update wa_event_routes set email_subject = p_subject, email_body = p_body,
           updated_at = now() where event_key = p_event_key;
  end if;
  if not found then
    return jsonb_build_object('ok', false, 'error','unknown_event',
                              'message','That notification event does not exist.');
  end if;
  return jsonb_build_object('ok', true, 'language', v_lang, 'message','Template saved.');
end $$;

-- Preview renders the real template through the real wrapper and stops short of
-- Resend. No test mail is ever sent to a customer or a supplier from here.
create or replace function public.notif_email_preview(p_event_key text, p_lang text default 'en')
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  r record; tpl jsonb; v_vars jsonb := '{}'::jsonb; tok text;
  v_lang text := public.notif_norm_lang(p_lang); v_subj text; v_body text;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'forbidden'; end if;
  select * into r from wa_event_routes where event_key = p_event_key;
  if r is null then
    return jsonb_build_object('ok', false, 'error','unknown_event',
                              'message','That notification event does not exist.');
  end if;
  for tok in select jsonb_array_elements_text(coalesce(r.variable_map,'[]'::jsonb)) loop
    v_vars := v_vars || jsonb_build_object(
      replace(replace(tok,'{{',''),'}}',''),
      '[' || replace(replace(tok,'{{',''),'}}','') || ']');
  end loop;
  tpl    := public.notif_email_template(p_event_key, v_lang);
  v_subj := public.notif_render(tpl->>'subject', v_vars);
  v_body := public.notif_render(tpl->>'body',    v_vars);
  if coalesce(v_subj,'') = '' then
    return jsonb_build_object('ok', false, 'error','no_template',
                              'message','No email template for this event in this language yet.');
  end if;
  return jsonb_build_object('ok', true, 'language', v_lang, 'subject', v_subj,
                            'body', v_body,
                            'html', public.notif_email_html(v_subj, v_body, v_lang),
                            'note','Preview only — nothing was sent.');
end $$;

-- ─────────────────────────────────────────────── 11. per-user opt-out admin ──
create or replace function public.notif_optout_users(p_search text default '')
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v jsonb;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'forbidden'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id',   p.user_id,
           'name',      coalesce(nullif(p.pharmacy_name,''), coalesce(p.email, p.phone, 'Unnamed')),
           'contact',   concat_ws(' · ', nullif(p.phone,''), nullif(p.email,'')),
           'language',  public.notif_norm_lang(p.wa_language),
           'language_label', case when public.notif_norm_lang(p.wa_language)='hi'
                                  then 'हिन्दी' else 'English' end,
           'optout_count', (select count(*) from notification_settings s
                             where s.user_id = p.user_id and s.enabled is false),
           'optout_label', case when (select count(*) from notification_settings s
                                       where s.user_id = p.user_id and s.enabled is false) = 0
                                then 'All notifications on'
                                else (select count(*) from notification_settings s
                                       where s.user_id = p.user_id and s.enabled is false)::text
                                     || ' turned off' end)
         order by p.pharmacy_name nulls last), '[]'::jsonb)
    into v
    from pharmacy_profiles p
   where p.user_id is not null
     and (coalesce(p_search,'') = ''
          or p.pharmacy_name ilike '%'||p_search||'%'
          or coalesce(p.email,'') ilike '%'||p_search||'%'
          or coalesce(p.phone,'') ilike '%'||p_search||'%');

  return jsonb_build_object('ok', true, 'title','Per-user opt-outs',
    'subtitle','A person can silence any event on any channel. Their language travels with them.',
    'users', v, 'empty_text','No matching accounts.');
end $$;

create or replace function public.notif_optout_detail(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v jsonb; p record;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'forbidden'; end if;
  select * into p from pharmacy_profiles where user_id = p_user_id;
  if p is null then
    return jsonb_build_object('ok', false, 'error','unknown_user',
                              'message','No account with that id.');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'action_key', g.action_key,
           'label',      g.label,
           'audience',   g.audience,
           'channels',   jsonb_build_array(
             jsonb_build_object('key','all',     'label','All channels',
               'enabled', not exists (select 1 from notification_settings s
                          where s.user_id=p_user_id and s.action_key=g.action_key
                            and s.channel='all' and s.enabled is false)),
             jsonb_build_object('key','push',    'label','Push',
               'enabled', not exists (select 1 from notification_settings s
                          where s.user_id=p_user_id and s.action_key=g.action_key
                            and s.channel='push' and s.enabled is false)),
             jsonb_build_object('key','whatsapp','label','WhatsApp',
               'enabled', not exists (select 1 from notification_settings s
                          where s.user_id=p_user_id and s.action_key=g.action_key
                            and s.channel='whatsapp' and s.enabled is false)),
             jsonb_build_object('key','email',   'label','Email',
               'enabled', not exists (select 1 from notification_settings s
                          where s.user_id=p_user_id and s.action_key=g.action_key
                            and s.channel='email' and s.enabled is false))))
         order by g.sort, g.label), '[]'::jsonb)
    into v
    from notification_settings g
   where g.user_id is null and g.channel = 'all'
     and g.audience = 'customer';

  return jsonb_build_object('ok', true,
    'user_id', p_user_id,
    'name', coalesce(nullif(p.pharmacy_name,''), coalesce(p.email, p.phone, 'Unnamed')),
    'language', public.notif_norm_lang(p.wa_language),
    'language_label', case when public.notif_norm_lang(p.wa_language)='hi' then 'हिन्दी' else 'English' end,
    'language_heading','Language for every channel',
    'events_heading','Events this account receives',
    'events', v,
    'empty_text','No events configured for this audience.');
end $$;

create or replace function public.notif_optout_set(
  p_user_id uuid, p_action_key text, p_channel text, p_enabled boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_aud text; v_label text;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'forbidden'; end if;
  select audience, label into v_aud, v_label from notification_settings
   where action_key = p_action_key and user_id is null and channel = 'all' limit 1;
  if v_aud is null then
    return jsonb_build_object('ok', false, 'error','unknown_event',
                              'message','That notification event does not exist.');
  end if;

  if p_enabled then
    delete from notification_settings
     where user_id = p_user_id and action_key = p_action_key and channel = p_channel;
  else
    insert into notification_settings (audience, action_key, label, enabled, user_id, channel)
    values (v_aud, p_action_key, v_label, false, p_user_id, p_channel)
    on conflict (user_id, audience, action_key, channel)
      where user_id is not null
      do update set enabled = false, updated_at = now();
  end if;

  return jsonb_build_object('ok', true,
    'message', case when p_enabled then v_label || ' turned back on.'
                    else v_label || ' turned off for this account.' end);
end $$;

grant execute on function public.notif_cost_dashboard(integer)                 to authenticated;
grant execute on function public.notif_email_admin()                            to authenticated;
grant execute on function public.notif_email_route_set(text,boolean,text)       to authenticated;
grant execute on function public.notif_email_template_save(text,text,text,text) to authenticated;
grant execute on function public.notif_email_preview(text,text)                 to authenticated;
grant execute on function public.notif_optout_users(text)                       to authenticated;
grant execute on function public.notif_optout_detail(uuid)                      to authenticated;
grant execute on function public.notif_optout_set(uuid,text,text,boolean)       to authenticated;
grant execute on function public.notif_set_language(uuid,text)                  to authenticated;
grant execute on function public.notif_set_my_language(text)                    to authenticated;
grant execute on function public.notif_norm_lang(text)                          to authenticated, anon;

-- CMD #2055 — One wording, three channels.
-- The WhatsApp template is the single source. Push and Email are DERIVED from
-- it on every save, in the backend, and rendered verbatim by the app.
-- Editing Push or Email directly marks that channel manual for that language
-- and stops the sync; "Reset to WhatsApp" clears the mark and re-derives.

-- ── 1. the sync state the route carries ──────────────────────────────────────
alter table public.wa_event_routes
  add column if not exists push_manual        boolean not null default false,
  add column if not exists push_manual_hi     boolean not null default false,
  add column if not exists email_manual       boolean not null default false,
  add column if not exists email_manual_hi    boolean not null default false,
  add column if not exists push_extra         jsonb   not null default '{}'::jsonb,
  add column if not exists push_extra_hi      jsonb   not null default '{}'::jsonb,
  add column if not exists email_extra        jsonb   not null default '{}'::jsonb,
  add column if not exists email_extra_hi     jsonb   not null default '{}'::jsonb,
  add column if not exists channels_synced_at timestamptz;

-- ── 2. html escape, one place ────────────────────────────────────────────────
create or replace function public.wa_html_escape(p_text text)
returns text language sql immutable as $fn$
  select replace(replace(replace(coalesce(p_text,''),'&','&amp;'),'<','&lt;'),'>','&gt;');
$fn$;

-- ── 3. THE RULES. One template in, the other two channels out. ───────────────
-- Text-only   -> push title = first line (65), body = the rest (240); email = body.
-- Text+image  -> push big picture;      email image on top.
-- Text+video  -> push thumbnail;        email thumbnail linking to the video.
-- PDF         -> push text only;        email attachment.
-- URL buttons -> push actions (max 3) and email buttons; quick replies push only.
-- Footer      -> email footer.   Subject = first line.   Tokens are untouched.
create or replace function public.wa_channel_derive(p_template_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  t record; c jsonb;
  v_fmt text := 'TEXT'; v_media text; v_hdr_text text;
  v_body text := ''; v_footer text;
  v_urls jsonb := '[]'::jsonb; v_qrs jsonb := '[]'::jsonb;
  v_first text; v_rest text; v_nl int;
  v_style text; v_rule text;
begin
  select * into t from wa_templates where id = p_template_id;
  if t.id is null then return jsonb_build_object('ok', false, 'error','no_template'); end if;

  for c in select value from jsonb_array_elements(coalesce(t.components,'[]'::jsonb)) loop
    case upper(coalesce(c->>'type',''))
      when 'HEADER' then
        v_fmt := upper(coalesce(c->>'format','TEXT'));
        if v_fmt = 'TEXT' then
          v_hdr_text := c->>'text';
        else
          v_media := c->'example'->'header_handle'->>0;
          if coalesce(v_media,'') not like 'https://%' then v_media := null; end if;
        end if;
      when 'BODY'   then v_body   := coalesce(c->>'text','');
      when 'FOOTER' then v_footer := nullif(btrim(coalesce(c->>'text',''), E' \t\r\n'),'');
      when 'BUTTONS' then
        select coalesce(jsonb_agg(jsonb_build_object('text', b->>'text', 'url', b->>'url')
                        order by ord) filter (where upper(coalesce(b->>'type',''))='URL'), '[]'::jsonb),
               coalesce(jsonb_agg(jsonb_build_object('text', b->>'text')
                        order by ord) filter (where upper(coalesce(b->>'type',''))='QUICK_REPLY'), '[]'::jsonb)
          into v_urls, v_qrs
          from jsonb_array_elements(coalesce(c->'buttons','[]'::jsonb)) with ordinality x(b, ord);
      else null;
    end case;
  end loop;

  -- A text header is wording too: it leads the body, so it becomes the first line.
  if coalesce(btrim(coalesce(v_hdr_text,''), E' \t\r\n'),'') <> '' then
    v_body := btrim(v_hdr_text, E' \t\r\n') || E'\n' || v_body;
  end if;
  v_body := btrim(coalesce(v_body,''), E' \t\r\n');

  v_nl := position(E'\n' in v_body);
  if v_nl > 0 then
    v_first := btrim(left(v_body, v_nl - 1), E' \t\r\n');
    v_rest  := btrim(substr(v_body, v_nl + 1), E' \t\r\n');
  else
    v_first := v_body; v_rest := '';
  end if;

  v_style := case v_fmt when 'IMAGE' then 'big_picture'
                        when 'VIDEO' then 'thumbnail'
                        else 'text' end;
  v_rule  := case v_fmt
               when 'IMAGE'    then 'Text + image — push shows the big picture, email puts the image on top.'
               when 'VIDEO'    then 'Text + video — push shows the thumbnail, email links the thumbnail to the video.'
               when 'DOCUMENT' then 'PDF — email carries the attachment, push is text only.'
               else 'Text only — push title is the first line, email is the body.' end;

  return jsonb_build_object(
    'ok', true,
    'template_id', t.id, 'template_name', t.name, 'language', t.language,
    'header_format', v_fmt, 'rule_label', v_rule,
    'source_body', v_body, 'source_footer', coalesce(v_footer,''),
    'push', jsonb_build_object(
      'title', left(v_first, 65),
      'body',  left(case when v_rest <> '' then v_rest else v_first end, 240),
      'extra', jsonb_build_object(
        'style', v_style,
        'style_label', case v_style when 'big_picture' then 'Big picture'
                                    when 'thumbnail'   then 'Thumbnail'
                                    else 'Text only' end,
        'image_url', case when v_fmt = 'IMAGE' then v_media end,
        'thumb_url', case when v_fmt = 'VIDEO' then v_media end,
        'storage_path', case when v_fmt in ('IMAGE','VIDEO') then t.header_media_path end,
        'storage_bucket', case when v_fmt in ('IMAGE','VIDEO') and t.header_media_path is not null
                               then 'whatsapp-media' end,
        'actions', (select coalesce(jsonb_agg(u order by ord),'[]'::jsonb)
                      from (select u, ord from jsonb_array_elements(v_urls) with ordinality q(u, ord)
                             limit 3) z),
        'quick_replies', v_qrs)),
    'email', jsonb_build_object(
      'subject', v_first,
      'body',    v_body,
      'extra', jsonb_build_object(
        'image_url',  case when v_fmt = 'IMAGE' then v_media end,
        'video_url',  case when v_fmt = 'VIDEO' then v_media end,
        'thumb_url',  case when v_fmt = 'VIDEO' then v_media end,
        'pdf_url',    case when v_fmt = 'DOCUMENT' then v_media end,
        'pdf_label',  case when v_fmt = 'DOCUMENT'
                           then coalesce(nullif(regexp_replace(coalesce(t.header_media_path,''),'^.*/',''),''),
                                         'Attachment') end,
        'storage_path', case when v_fmt <> 'TEXT' then t.header_media_path end,
        'storage_bucket', case when v_fmt <> 'TEXT' and t.header_media_path is not null
                               then 'whatsapp-media' end,
        'buttons', v_urls,
        'footer',  coalesce(v_footer,''))));
end $fn$;

-- ── 4. which template is the source for an event in a given language ─────────
create or replace function public.wa_channel_source_template(p_event_key text, p_lang text)
returns uuid language sql stable security definer set search_path to 'public' as $fn$
  with r as (select * from wa_event_routes where event_key = p_event_key),
       base as (select coalesce(
                  (select t.name from wa_templates t, r where t.id = r.template_id),
                  (select r.template_name from r),
                  (select r.auto_template_name from r)) as nm)
  select t.id from wa_templates t, base, r
   where t.name = base.nm
     and lower(coalesce(t.language,'en')) like public.notif_norm_lang(p_lang) || '%'
   order by (t.id = r.template_id) desc, t.updated_at desc nulls last
   limit 1;
$fn$;

-- ── 5. derive both channels for one event, in both languages ─────────────────
-- Manual channels are left exactly as the admin wrote them. Everything else is
-- rewritten from the template, every time it is saved — never waiting on Meta.
create or replace function public.wa_channel_sync_event(p_event_key text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r record; v_en jsonb; v_hi jsonb; v_touched text[] := '{}';
begin
  select * into r from wa_event_routes where event_key = p_event_key;
  if r.event_key is null then return jsonb_build_object('ok', false, 'error','unknown_event'); end if;

  v_en := public.wa_channel_derive(public.wa_channel_source_template(p_event_key,'en'));
  v_hi := public.wa_channel_derive(public.wa_channel_source_template(p_event_key,'hi'));

  if coalesce((v_en->>'ok')::boolean,false) then
    update wa_event_routes set
      push_title   = case when push_manual  then push_title   else v_en->'push'->>'title' end,
      push_body    = case when push_manual  then push_body    else v_en->'push'->>'body'  end,
      push_extra   = case when push_manual  then push_extra   else v_en->'push'->'extra'  end,
      email_subject= case when email_manual then email_subject else v_en->'email'->>'subject' end,
      email_body   = case when email_manual then email_body    else v_en->'email'->>'body'    end,
      email_extra  = case when email_manual then email_extra   else v_en->'email'->'extra'    end,
      channels_synced_at = now(), updated_at = now()
    where event_key = p_event_key;
    v_touched := array_append(v_touched, 'en');
  end if;

  if coalesce((v_hi->>'ok')::boolean,false) then
    update wa_event_routes set
      push_title_hi   = case when push_manual_hi  then push_title_hi   else v_hi->'push'->>'title' end,
      push_body_hi    = case when push_manual_hi  then push_body_hi    else v_hi->'push'->>'body'  end,
      push_extra_hi   = case when push_manual_hi  then push_extra_hi   else v_hi->'push'->'extra'  end,
      email_subject_hi= case when email_manual_hi then email_subject_hi else v_hi->'email'->>'subject' end,
      email_body_hi   = case when email_manual_hi then email_body_hi    else v_hi->'email'->>'body'    end,
      email_extra_hi  = case when email_manual_hi then email_extra_hi   else v_hi->'email'->'extra'    end,
      channels_synced_at = now(), updated_at = now()
    where event_key = p_event_key;
    v_touched := array_append(v_touched, 'hi');
  end if;

  return jsonb_build_object('ok', true, 'event_key', p_event_key,
                            'languages', to_jsonb(v_touched),
                            'rule_label', coalesce(v_en->>'rule_label', v_hi->>'rule_label'));
end $fn$;

-- ── 6. a template was saved -> every event that uses it re-derives ───────────
create or replace function public.wa_channel_sync_template(p_template_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare k text; n int := 0; v_name text;
begin
  select name into v_name from wa_templates where id = p_template_id;
  for k in
    select r.event_key from wa_event_routes r
     where r.template_id = p_template_id
        or (v_name is not null and (r.template_name = v_name or r.auto_template_name = v_name))
  loop
    perform public.wa_channel_sync_event(k);
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'events', n);
end $fn$;

create or replace function public._wa_channel_sync_trg()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
begin
  if tg_table_name = 'wa_templates' then
    perform public.wa_channel_sync_template(new.id);
  else
    perform public.wa_channel_sync_event(new.event_key);
  end if;
  return new;
exception when others then
  -- The sync must never be able to roll back the save it follows.
  return new;
end $fn$;

drop trigger if exists wa_templates_channel_sync on public.wa_templates;
create trigger wa_templates_channel_sync
  after insert or update of components, header_handle, header_media_path, name, language
  on public.wa_templates for each row execute function public._wa_channel_sync_trg();

drop trigger if exists wa_event_routes_channel_sync on public.wa_event_routes;
create trigger wa_event_routes_channel_sync
  after update of template_id, template_name, auto_template_name
  on public.wa_event_routes for each row execute function public._wa_channel_sync_trg();

-- ── 7. editing a channel directly marks it manual, per language ──────────────
create or replace function public.notif_event_push_set(
  p_event_key text, p_enabled boolean, p_title text default null, p_body text default null,
  p_title_hi text default null, p_body_hi text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('push.not_authorized','Not authorized'));
  end if;
  update wa_event_routes set
    push_enabled  = coalesce(p_enabled, push_enabled),
    push_title    = coalesce(p_title,    push_title),
    push_body     = coalesce(p_body,     push_body),
    push_title_hi = coalesce(p_title_hi, push_title_hi),
    push_body_hi  = coalesce(p_body_hi,  push_body_hi),
    -- Wording typed by hand outranks the template until it is reset.
    push_manual    = push_manual    or (p_title    is not null or p_body    is not null),
    push_manual_hi = push_manual_hi or (p_title_hi is not null or p_body_hi is not null),
    updated_at    = now()
  where event_key = p_event_key;
  if not found then return jsonb_build_object('ok', false, 'error','unknown_event'); end if;
  return jsonb_build_object('ok', true, 'event_key', p_event_key,
                            'message', public.uic('push_admin.saved','Saved.'));
end $fn$;

create or replace function public.notif_email_template_save(
  p_event_key text, p_lang text, p_subject text, p_body text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_lang text := public.notif_norm_lang(p_lang);
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'forbidden'; end if;
  if v_lang = 'hi' then
    update wa_event_routes set email_subject_hi = p_subject, email_body_hi = p_body,
           email_manual_hi = true, updated_at = now() where event_key = p_event_key;
  else
    update wa_event_routes set email_subject = p_subject, email_body = p_body,
           email_manual = true, updated_at = now() where event_key = p_event_key;
  end if;
  if not found then
    return jsonb_build_object('ok', false, 'error','unknown_event',
                              'message','That notification event does not exist.');
  end if;
  return jsonb_build_object('ok', true, 'language', v_lang, 'message','Template saved.');
end $fn$;

-- ── 8. Reset to WhatsApp — drop the manual mark and re-derive ────────────────
create or replace function public.wa_channel_reset(
  p_event_key text, p_channel text, p_lang text default 'en')
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_lang text := public.notif_norm_lang(p_lang); v_ch text := lower(coalesce(p_channel,''));
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('channel_sync.not_authorized','Not authorized'));
  end if;
  if v_ch not in ('push','email','both') then
    return jsonb_build_object('ok', false, 'error','unknown_channel',
      'message', public.uic('channel_sync.unknown_channel','That channel does not exist.'));
  end if;
  update wa_event_routes set
    push_manual     = case when v_ch in ('push','both')  and v_lang = 'en' then false else push_manual end,
    push_manual_hi  = case when v_ch in ('push','both')  and v_lang = 'hi' then false else push_manual_hi end,
    email_manual    = case when v_ch in ('email','both') and v_lang = 'en' then false else email_manual end,
    email_manual_hi = case when v_ch in ('email','both') and v_lang = 'hi' then false else email_manual_hi end,
    updated_at = now()
  where event_key = p_event_key;
  if not found then
    return jsonb_build_object('ok', false, 'error','unknown_event',
      'message', public.uic('channel_sync.unknown_event','That notification event does not exist.'));
  end if;
  perform public.wa_channel_sync_event(p_event_key);
  return jsonb_build_object('ok', true, 'event_key', p_event_key, 'channel', v_ch, 'language', v_lang,
    'message', public.uic('channel_sync.reset_done','Back in sync with the WhatsApp template.'));
end $fn$;

-- ── 9. ONE preview of all three channels, per event, per language ────────────
create or replace function public.wa_channel_preview(p_event_key text, p_lang text default 'en')
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  r record; v_lang text := public.notif_norm_lang(p_lang);
  v_src uuid; v_der jsonb; v_wa jsonb;
  v_pm boolean; v_em boolean;
  v_ptitle text; v_pbody text; v_pex jsonb;
  v_subj text; v_ebody text; v_eex jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('channel_sync.not_authorized','Not authorized'));
  end if;
  select * into r from wa_event_routes where event_key = p_event_key;
  if r.event_key is null then
    return jsonb_build_object('ok', false, 'error','unknown_event',
      'message', public.uic('channel_sync.unknown_event','That notification event does not exist.'));
  end if;

  v_src := public.wa_channel_source_template(p_event_key, v_lang);
  v_der := public.wa_channel_derive(v_src);
  v_wa  := case when v_src is not null then public.wa_template_preview(v_src) end;

  if v_lang = 'hi' then
    v_pm := coalesce(r.push_manual_hi,false); v_em := coalesce(r.email_manual_hi,false);
    v_ptitle := coalesce(nullif(r.push_title_hi,''), r.push_title);
    v_pbody  := coalesce(nullif(r.push_body_hi,''),  r.push_body);
    v_pex    := case when coalesce(r.push_extra_hi,'{}'::jsonb) = '{}'::jsonb then r.push_extra else r.push_extra_hi end;
    v_subj   := coalesce(nullif(r.email_subject_hi,''), r.email_subject);
    v_ebody  := coalesce(nullif(r.email_body_hi,''),  r.email_body);
    v_eex    := case when coalesce(r.email_extra_hi,'{}'::jsonb) = '{}'::jsonb then r.email_extra else r.email_extra_hi end;
  else
    v_pm := coalesce(r.push_manual,false); v_em := coalesce(r.email_manual,false);
    v_ptitle := r.push_title; v_pbody := r.push_body; v_pex := r.push_extra;
    v_subj := r.email_subject; v_ebody := r.email_body; v_eex := r.email_extra;
  end if;

  return jsonb_build_object(
    'ok', true,
    'event_key', r.event_key,
    'title', coalesce(r.label, r.event_key),
    'subtitle', public.uic('channel_sync.subtitle',
                 'The WhatsApp template is the wording. Push and Email are written from it automatically.'),
    'language', v_lang,
    'language_options', jsonb_build_array(
      jsonb_build_object('key','en','label','English'),
      jsonb_build_object('key','hi','label','हिन्दी')),
    'rule_label', coalesce(v_der->>'rule_label',
                    public.uic('channel_sync.no_template','No WhatsApp template is linked to this event yet.')),
    'source_label', case when v_src is null
                         then public.uic('channel_sync.no_template','No WhatsApp template is linked to this event yet.')
                         else coalesce(v_der->>'template_name','') || ' · ' || coalesce(v_der->>'language','') end,
    'synced_label', case when r.channels_synced_at is null then public.uic('channel_sync.never','Not derived yet')
                         else 'Derived ' || to_char(r.channels_synced_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM') end,
    'chips', jsonb_build_array(
      jsonb_build_object('channel','whatsapp','channel_label','WhatsApp',
        'label', public.uic('channel_sync.chip_source','Source'), 'tone','good'),
      jsonb_build_object('channel','push','channel_label','Push',
        'label', case when v_pm then public.uic('channel_sync.chip_manual','Manual')
                      else public.uic('channel_sync.chip_synced','Synced') end,
        'tone', case when v_pm then 'warn' else 'good' end),
      jsonb_build_object('channel','email','channel_label','Email',
        'label', case when v_em then public.uic('channel_sync.chip_manual','Manual')
                      else public.uic('channel_sync.chip_synced','Synced') end,
        'tone', case when v_em then 'warn' else 'good' end)),
    'whatsapp', jsonb_build_object(
      'label','WhatsApp',
      'empty_label', case when v_src is null
                          then public.uic('channel_sync.no_template','No WhatsApp template is linked to this event yet.') end,
      'header', v_wa->'header',
      'body', coalesce(v_wa->>'body_plain', v_der->>'source_body', ''),
      'footer', coalesce(v_der->>'source_footer',''),
      'buttons', coalesce(v_wa->'buttons','[]'::jsonb)),
    'push', jsonb_build_object(
      'label','Push',
      'title', coalesce(v_ptitle,''),
      'body',  coalesce(v_pbody,''),
      'empty_label', case when coalesce(nullif(btrim(coalesce(v_pbody,'')),''),'') = ''
                          then public.uic('channel_sync.push_empty','Nothing to show — link a template.') end,
      'style_label', coalesce(v_pex->>'style_label','Text only'),
      'image_url', v_pex->>'image_url',
      'thumb_url', v_pex->>'thumb_url',
      'storage_bucket', v_pex->>'storage_bucket',
      'storage_path', v_pex->>'storage_path',
      'actions', coalesce(v_pex->'actions','[]'::jsonb),
      'quick_replies', coalesce(v_pex->'quick_replies','[]'::jsonb),
      'manual', v_pm,
      'reset_label', public.uic('channel_sync.reset','Reset to WhatsApp')),
    'email', jsonb_build_object(
      'label','Email',
      'subject', coalesce(v_subj,''),
      'body', coalesce(v_ebody,''),
      'empty_label', case when coalesce(nullif(btrim(coalesce(v_ebody,'')),''),'') = ''
                          then public.uic('channel_sync.email_empty','Nothing to show — link a template.') end,
      'image_url', v_eex->>'image_url',
      'thumb_url', v_eex->>'thumb_url',
      'video_url', v_eex->>'video_url',
      'attachment_label', v_eex->>'pdf_label',
      'storage_bucket', v_eex->>'storage_bucket',
      'storage_path', v_eex->>'storage_path',
      'buttons', coalesce(v_eex->'buttons','[]'::jsonb),
      'footer', coalesce(v_eex->>'footer',''),
      'manual', v_em,
      'reset_label', public.uic('channel_sync.reset','Reset to WhatsApp')),
    'note', public.uic('channel_sync.note',
      'Every event sends all three. Edit Push or Email here and that channel stops following the template until you reset it.'));
end $fn$;


-- ── 10. every event card carries its three chips and its Preview ────────────
-- Wrapper, not a rewrite: the base below is the screen exactly as it was, and
-- the wrapper adds ONE `channels` block per row, so nothing that renders today
-- moves. The chips are read straight off the route's own manual marks.
CREATE OR REPLACE FUNCTION public._wa_event_routes_screen_base()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb; v_blocked int;
begin
  if role_for_medibo_only() not in ('admin','super_admin') then return jsonb_build_object('error','not_authorized'); end if;

  select coalesce(jsonb_agg(x order by x->>'event_key'), '[]'::jsonb),
         count(*) filter (where (x->>'blocked')::boolean)::int
    into v_rows, v_blocked
  from (
    select jsonb_build_object(
      'event_key', r.event_key, 'label', r.label, 'description', r.description,
      'audience', r.audience,
      'audience_label', coalesce((select a->>'label' from jsonb_array_elements(public.wa_audience_types()) a
                                   where a->>'value' = r.audience), initcap(r.audience)),
      'audience_sort', coalesce((select (a->>'sort')::int from jsonb_array_elements(public.wa_audience_types()) a
                                  where a->>'value' = r.audience), 99),
      'auto_manage', r.auto_manage,
      'auto_template_name', r.auto_template_name,
      'pipeline_note', r.pipeline_note,
      'meta_status', (select t.status from wa_templates t
                       where t.name = r.auto_template_name order by (t.language='en') desc limit 1),
      'stage', case
        when r.enabled and r.template_id is not null then 'live'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='REJECTED') then 'rejected'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='PENDING') then 'waiting_meta'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='DRAFT') then 'preparing'
        else 'not_started' end,
      'stage_label', case
        when r.enabled and r.template_id is not null then 'Live — switched on automatically'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='REJECTED') then 'Meta rejected the template'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='PENDING') then 'Waiting on Meta approval'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='DRAFT') then 'Being prepared and checked'
        else 'Not started yet' end,
      'stage_tone', case
        when r.enabled and r.template_id is not null then 'good'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='REJECTED') then 'bad'
        else 'warn' end,
      'template_name', coalesce(r.template_name,'—'),
      'language', coalesce(r.language,'—'),
      'enabled', r.enabled,
      'status_label', case when not r.enabled then 'Off'
                           when r.template_id is null then 'No template'
                           else 'On' end,
      'status_tone', case when not r.enabled then 'muted'
                          when r.template_id is null then 'warn' else 'good' end,
      'blocked',       r.enabled and coalesce((bl->>'blocked')::boolean, false),
      'blocker_label', case when r.enabled then coalesce(bl->>'blocker_label','') else '' end,
      'blocker_detail',case when r.enabled then coalesce(bl->>'message','') else '' end,
      'blocker_tone',  case when r.enabled and coalesce((bl->>'blocked')::boolean,false) then 'bad' else 'good' end,
      'bypass_send_window', r.bypass_send_window,
      'dedupe_minutes', r.dedupe_minutes,
      'window_label', case when r.bypass_send_window then 'Sends any time — transactional'
                           else 'Held to the 9am–8pm window' end,
      'variable_map', r.variable_map,
      'sent_30d', (select count(*) from wa_campaign_recipients x join wa_campaigns c on c.id = x.campaign_id
                    where c.audience_kind='event_route' and c.audience_params->>'event_key' = r.event_key
                      and x.status in ('sent','delivered','read') and x.sent_at > now() - interval '30 days'),
      'languages_live', (select coalesce(jsonb_agg(distinct c.language), '[]'::jsonb) from wa_campaigns c
                          where c.audience_kind='event_route' and c.audience_params->>'event_key' = r.event_key),
      'updated_label', to_char(r.updated_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM')
    ) as x
    from wa_event_routes r
    left join lateral (select public._wa_route_blockers_raw(r.event_key, r.template_id) as bl) b on true
  ) q;

  return jsonb_build_object(
    'rows', v_rows,
    'blocked_count', coalesce(v_blocked,0),
    'blocked_label', case when coalesce(v_blocked,0) = 0 then ''
                          when v_blocked = 1 then '1 switched-on event cannot send'
                          else v_blocked || ' switched-on events cannot send' end,
    'blocked_tone', case when coalesce(v_blocked,0) > 0 then 'bad' else 'good' end,
    'blocked_note', 'These are on, so mediBO keeps trying them — and every send is refused before it leaves. Fix the blocker on the row, or switch the event off.',
    'approved_templates', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', t.id, 'name', t.name, 'language', t.language, 'category', t.category,
        'label', t.name || ' (' || t.language || ')') order by t.name), '[]'::jsonb)
      from wa_templates t where t.status='APPROVED'),
    'note', 'Each event sends the approved template you pick here. Change the template and the next message uses it — no deploy. Customers with a language set get that language automatically when an approved variant of the same template exists.');
end $function$;

create or replace function public.wa_event_routes_screen()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v jsonb;
begin
  v := public._wa_event_routes_screen_base();
  if v ? 'error' then return v; end if;
  return jsonb_set(v, '{rows}', coalesce((
    select jsonb_agg(
      x.row || jsonb_build_object('channels', jsonb_build_object(
        'label', public.uic('channel_sync.card_label','All three channels'),
        'preview_label', public.uic('channel_sync.preview','Preview all three'),
        'chips', jsonb_build_array(
          jsonb_build_object('channel','whatsapp','channel_label','WhatsApp',
            'label', public.uic('channel_sync.chip_source','Source'), 'tone','good'),
          jsonb_build_object('channel','push','channel_label','Push',
            'label', case when coalesce(r.push_manual,false)
                          then public.uic('channel_sync.chip_manual','Manual')
                          else public.uic('channel_sync.chip_synced','Synced') end,
            'tone', case when coalesce(r.push_manual,false) then 'warn' else 'good' end),
          jsonb_build_object('channel','email','channel_label','Email',
            'label', case when coalesce(r.email_manual,false)
                          then public.uic('channel_sync.chip_manual','Manual')
                          else public.uic('channel_sync.chip_synced','Synced') end,
            'tone', case when coalesce(r.email_manual,false) then 'warn' else 'good' end))
      )) order by x.row->>'event_key')
    from jsonb_array_elements(coalesce(v->'rows','[]'::jsonb)) x(row)
    left join wa_event_routes r on r.event_key = x.row->>'event_key'
  ), '[]'::jsonb));
end $fn$;

-- ── 11. THE SEND LANE — all three channels, every event, no fallback order ──
CREATE OR REPLACE FUNCTION public.notify_raw(p_event_key text, p_recipient text DEFAULT NULL::text, p_vars jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
declare
  r            record;
  v            jsonb;
  v_vars       jsonb := coalesce(p_vars, '{}'::jsonb);
  v_channel    text  := coalesce(nullif(v_vars->>'channel',''), 'whatsapp');
  v_order      uuid  := nullif(v_vars->>'order_id','')::uuid;
  v_cust       uuid  := nullif(v_vars->>'customer_id','')::uuid;
  v_url        text  := nullif(v_vars->>'legacy_url','');
  v_body       jsonb := case when v_vars ? 'legacy_body' then v_vars->'legacy_body' end;
  v_force_tpl  boolean := coalesce((v_vars->>'force_template')::boolean, false);
  v_retry      bigint := nullif(v_vars->>'_retry_id','')::bigint;
  v_req        bigint;
  v_tokens     jsonb;
  v_ph         text;
  v_aud        text;
  v_win        jsonb;
  v_open       boolean;
  v_reason     text;
  v_push       jsonb;   -- CHANGE #298
  v_uid        uuid;    -- CHANGE #712 — the recipient, for the per-user switch
begin
  -- CMD #1848 — a human test session's rows never leave the building.
  if public.test_order_silenced(nullif(p_vars->>'order_id','')::uuid)
     or public.test_customer_silenced(nullif(p_vars->>'customer_id','')::uuid)
  then
    return jsonb_build_object('ok', false, 'reason','test_mode_silenced');
  end if;
  if coalesce(btrim(p_event_key),'') = '' then
    return jsonb_build_object('ok', false, 'reason','no_event_key');
  end if;

  select * into r from public.wa_event_routes where event_key = p_event_key;
  v_aud := coalesce(r.audience, 'customer');

  v_tokens := v_vars - 'order_id' - 'customer_id' - 'legacy_url' - 'legacy_body'
                     - 'channel' - 'force_template' - '_retry_id' - '_no_push';

  v_ph := nullif(right(regexp_replace(coalesce(p_recipient,''),'\D','','g'),10),'');
  if coalesce(length(v_ph),0) <> 10 and v_order is not null then
    v_ph := right(regexp_replace(coalesce(public._order_customer_phone(v_order),''),'\D','','g'),10);
  end if;
  if coalesce(length(v_ph),0) <> 10 and v_cust is not null then
    select right(regexp_replace(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone, ''),'\D','','g'),10)
      into v_ph from public.pharmacy_profiles pp where pp.id = v_cust;
  end if;
  if coalesce(length(v_ph),0) <> 10 and v_aud = 'admin' then
    v_ph := right(regexp_replace(
              coalesce((select value #>> '{}' from public.app_settings where key='admin_wa_phone'),''),
              '\D','','g'), 10);
  end if;

  -- No route at all → legacy passthrough, byte-for-byte what the caller used
  -- to post on its own, plus a ledger row.
  if r.event_key is null then
    if v_url is null then
      perform public.notify_log(p_event_key, v_ph, v_channel, 'skipped', 'none',
        null, 'unknown_event', null, v_order, v_cust, v_vars);
      return jsonb_build_object('ok', false, 'reason','unknown_event');
    end if;
    select net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := coalesce(v_body,'{}'::jsonb),
      timeout_milliseconds := 20000) into v_req;
    perform public.notify_log(p_event_key, v_ph, v_channel, 'sent', 'legacy',
      v_req::text, null, null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', true, 'path','legacy', 'reason','no_route',
                              'request_id', v_req);
  end if;

  if coalesce(length(v_ph),0) <> 10 then
    perform public._wa_log_attempt(p_event_key, v_order, null, 'skipped', false, 'no_phone');
    perform public.notify_log(p_event_key, null, v_channel, 'skipped', 'none',
      null, 'no_phone', null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', false, 'reason','no_phone');
  end if;

  if not public.notif_should_send(v_aud, p_event_key, v_ph) then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'skipped', false, 'notification_off');
    perform public.notify_log(p_event_key, v_ph, v_channel, 'skipped', 'none',
      null, 'notification_off', null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', false, 'reason','notification_off');
  end if;

  -- CHANGE #712 · the per-user switch, honoured on the WIRE and not only in
  -- the settings screen.
  if v_uid is null then
    if v_order is not null then
      select o.user_id into v_uid from public.orders o where o.id = v_order;
    end if;
    if v_uid is null and v_cust is not null then
      select pp.user_id into v_uid from public.pharmacy_profiles pp where pp.id = v_cust;
    end if;
  end if;

  if v_uid is not null
     and not public.notif_user_allows(v_uid, v_aud, p_event_key, 'whatsapp')
     and not public.notif_phone_allowlisted(v_aud, v_ph) then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'skipped', false, 'user_opted_out');
    perform public.notify_log(p_event_key, v_ph, v_channel, 'skipped', 'none',
      null, 'user_opted_out', null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', false, 'reason','user_opted_out');
  end if;


  -- CMD #2034 — the zone-99 hard wall on the send lane. It sits BELOW the
  -- per-user switch so an opt-out still reports itself as one, and ABOVE
  -- push and every WhatsApp path so a synthetic or test-zone row never
  -- leaves the building.
  if exists (select 1 from public.orders o
              where o.id = v_order
                and public.mode_outbound_blocked(o.is_synthetic, o.zone_id, o.test_session_id))
     or exists (select 1 from public.pharmacy_profiles pp
                 where pp.id = v_cust
                   and public.mode_outbound_blocked(pp.is_synthetic, pp.zone_id, pp.test_session_id))
  then
    perform public.notify_log(p_event_key, v_ph, v_channel, 'skipped', 'none',
      null, 'test_mode_silenced', null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', false, 'reason','test_mode_silenced');
  end if;
  v_win  := public.notify_window(v_ph);
  v_open := coalesce((v_win->>'open')::boolean, false);

  -- 0. PUSH FIRST (CHANGE #298). Free and instant, so it is tried before the
  --    paid channel. WhatsApp stays the fallback.
  if not coalesce((v_vars->>'_no_push')::boolean, false) then
    begin
      v_push := public.notif_push_send(p_event_key, v_ph, v_uid, v_order, v_tokens, v_aud);
    exception when others then
      v_push := jsonb_build_object('ok', false, 'reason', 'push_exception',
                                   'message', sqlerrm);
    end;
    if coalesce((v_push->>'ok')::boolean, false) then
      perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'push', true,
                                     coalesce(v_push->>'reason', 'push_queued'), v_push);
    end if;
    -- CMD #2055 — push no longer ENDS the send. All three channels go out for
    -- every event: push above, WhatsApp below, email off the log row. There is
    -- no fallback order left and none of them waits for another.
  end if;

  -- 1. TEMPLATE FIRST. Always. This is the order_placed fix.
  begin
    v := public.wa_send_event_or_fallback(p_event_key, v_cust, v_tokens, v_ph, v_order);
  exception when others then
    v := jsonb_build_object('ok', false, 'reason','exception', 'message', sqlerrm);
  end;

  -- CMD #1987 — a dedupe swallow is not a send. It is recorded as what it is,
  -- with ok=false, so it can never become the "earlier delivery" that suppresses
  -- the next one, and the log never claims a message that never left.
  if coalesce((v->>'deduped')::boolean, false) then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'deduped', false,
                                   coalesce(v->>'reason','already_delivered_recently'), v);
    perform public.notify_log(p_event_key, v_ph, v_channel, 'deduped', 'deduped',
      null, coalesce(v->>'reason','already_delivered_recently'), null,
      v_order, v_cust, v_vars, v);
    return jsonb_build_object('ok', false, 'path','deduped', 'deduped', true,
                              'reason', coalesce(v->>'reason','already_delivered_recently'),
                              'detail', v);
  end if;

  if coalesce((v->>'ok')::boolean, false) then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'template', true,
                                   coalesce(v->>'used_event', p_event_key), v);
    perform public.notify_log(p_event_key, v_ph, v_channel, 'sent', 'template',
      v->>'recipient_id', null, null, v_order, v_cust, v_vars, v);
    if v_retry is not null then
      update public.notification_retry_queue set status='done', updated_at=now() where id = v_retry;
    end if;
    return jsonb_build_object('ok', true, 'path','template', 'window_open', v_open, 'detail', v, 'push', v_push);
  end if;

  v_reason := coalesce(v->>'reason','template_failed');

  -- CMD #1987 — a route the admin switched OFF is the one thing that is simply
  -- skipped: no free-form, no retry queue, no email. Everything else keeps
  -- falling through.
  if v_reason = 'route_disabled' then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'skipped', false,
                                   'route_disabled', v);
    perform public.notify_log(p_event_key, v_ph, v_channel, 'skipped', 'none',
      null, 'route_disabled', null, v_order, v_cust, v_vars, v);
    return jsonb_build_object('ok', false, 'path','skipped', 'reason','route_disabled');
  end if;

  -- 2. FREE-FORM, and only inside the tracked window.
  if v_url is not null and v_open and not v_force_tpl then
    select net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := coalesce(v_body,'{}'::jsonb),
      timeout_milliseconds := 20000) into v_req;
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'freeform', true,
                                   'window_open_no_template: ' || v_reason, v);
    perform public.notify_log(p_event_key, v_ph, v_channel, 'sent', 'freeform',
      v_req::text, null, null, v_order, v_cust, v_vars, v);
    if v_retry is not null then
      update public.notification_retry_queue set status='done', updated_at=now() where id = v_retry;
    end if;
    return jsonb_build_object('ok', true, 'path','freeform', 'window_open', true,
                              'reason', v_reason, 'request_id', v_req, 'push', v_push);
  end if;

  -- 3. Nothing legal to send right now → QUEUE it. Never a silent drop. The
  --    email channel picks this row up from notification_log (_notif_email_after_log).
  perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'skipped', false, v_reason, v);
  perform public.notify_log(p_event_key, v_ph, v_channel, 'queued', 'none',
    null, v_reason, null, v_order, v_cust, v_vars, v);

  if v_retry is not null then
    update public.notification_retry_queue
       set attempts = attempts + 1, last_reason = v_reason,
           next_attempt_at = now() + public.notify_backoff(attempts + 1),
           status = case when attempts + 1 >= max_attempts then 'dead' else 'pending' end,
           updated_at = now()
     where id = v_retry;
  else
    perform public.notify_enqueue_retry(p_event_key, v_ph, v_vars, v_reason,
                                        v_order, v_cust, v_channel, v_force_tpl);
  end if;

  return jsonb_build_object('ok', coalesce((v_push->>'ok')::boolean,false), 'path','queued',
                            'window_open', v_open, 'reason', v_reason, 'push', v_push);
end $function$;

-- Email is no longer the fallback: it goes out for every event, once, whatever
-- the other two did. The guard list stays — a message that was deliberately not
-- sent is still not emailed — and one email per event/recipient is enforced here
-- so the push row and the WhatsApp row of the same send cannot both raise one.
create or replace function public._notif_email_after_log()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare r record;
begin
  if new.channel not in ('push','whatsapp') then return new; end if;

  if new.status = 'deduped'
     or coalesce(new.reason, new.failure_reason,'') in
        ('route_disabled','notification_off','user_opted_out','test_mode_silenced',
         'already_delivered_recently','legacy_already_delivered') then
    return new;
  end if;

  select email_enabled, email_mode into r from wa_event_routes where event_key = new.event_key;
  if not found or r.email_enabled is not true or r.email_mode = 'off' then return new; end if;

  -- One email per event per recipient per send, whichever channel logs first.
  if exists (select 1 from notification_log l
              where l.channel = 'email' and l.event_key = new.event_key
                and l.created_at > now() - interval '5 minutes'
                and coalesce(l.status,'') <> 'failed'
                and (   (new.order_id is not null and l.order_id = new.order_id)
                     or (new.recipient_id is not null and l.recipient_id = new.recipient_id))) then
    return new;
  end if;

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
    insert into notification_log (event_key, channel, status, ok, reason, recipient_id, parent_log_id)
    values (new.event_key, 'email', 'failed', false, left(sqlerrm, 300), new.recipient_id, new.id);
  end;
  return new;
end $fn$;

-- The email body is the template's body, drawn as HTML: image on top, the video
-- thumbnail linking to the video, the attachment named, the URL buttons, and
-- the template's own footer. Three-arg callers keep working — the extras
-- default to nothing, which renders exactly the mail that went out before.
drop function if exists public.notif_email_html(text, text, text);
create or replace function public.notif_email_html(
  p_title text, p_body_text text, p_lang text, p_extra jsonb default '{}'::jsonb)
returns text language plpgsql stable security definer set search_path to 'public' as $fn$
declare c record; v_lang text := public.notif_norm_lang(p_lang);
        x jsonb := coalesce(p_extra,'{}'::jsonb);
        v_head text; v_foot text; v_body text; v_top text := ''; v_tail text := '';
begin
  select * into c from notification_email_config where id = 'singleton';
  v_head := case when v_lang = 'hi' then c.header_hi else c.header_en end;
  v_foot := case when v_lang = 'hi' then c.footer_hi else c.footer_en end;

  v_body := '<p style="margin:0 0 16px 0;">' ||
            replace(replace(public.wa_html_escape(p_body_text),
              E'\n\n', '</p><p style="margin:0 0 16px 0;">'), E'\n', '<br/>') ||
            '</p>';

  if coalesce(x->>'image_url','') <> '' then
    v_top := '<img src="' || public.wa_html_escape(x->>'image_url') ||
             '" alt="" width="512" style="display:block;width:100%;max-width:512px;'
             'border-radius:12px;margin:0 0 16px 0;"/>';
  elsif coalesce(x->>'thumb_url','') <> '' then
    v_top := '<a href="' || public.wa_html_escape(coalesce(nullif(x->>'video_url',''), x->>'thumb_url')) ||
             '"><img src="' || public.wa_html_escape(x->>'thumb_url') ||
             '" alt="" width="512" style="display:block;width:100%;max-width:512px;'
             'border-radius:12px;margin:0 0 16px 0;"/></a>';
  end if;

  if coalesce(x->>'pdf_url','') <> '' then
    v_tail := v_tail || '<p style="margin:0 0 16px 0;"><a href="' ||
      public.wa_html_escape(x->>'pdf_url') ||
      '" style="color:#1B7A43;font-weight:700;text-decoration:none;">' ||
      public.wa_html_escape(coalesce(nullif(x->>'pdf_label',''),'Attachment')) || '</a></p>';
  end if;

  v_tail := v_tail || coalesce((
    select string_agg('<a href="' || public.wa_html_escape(b->>'url') ||
      '" style="display:inline-block;background:#1B7A43;color:#FFFFFF;font-weight:700;'
      'padding:12px 20px;border-radius:8px;text-decoration:none;margin:0 8px 8px 0;">' ||
      public.wa_html_escape(b->>'text') || '</a>', '')
      from jsonb_array_elements(coalesce(x->'buttons','[]'::jsonb)) b), '');

  if coalesce(x->>'footer','') <> '' then
    v_tail := v_tail || '<p style="margin:16px 0 0 0;font:400 13px/1.5 Arial,Helvetica,sans-serif;'
              'color:#6B7280;">' || public.wa_html_escape(x->>'footer') || '</p>';
  end if;

  return
  '<!doctype html><html><body style="margin:0;padding:0;background:#F5F6F8;">'
  '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F5F6F8;padding:24px 0;">'
  '<tr><td align="center">'
  '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#FFFFFF;border:1px solid #E5E7EB;border-radius:16px;">'
  '<tr><td style="padding:20px 24px;border-bottom:1px solid #E5E7EB;">'
  '<span style="font:700 20px/1.3 Arial,Helvetica,sans-serif;color:#1B7A43;">' || v_head || '</span>'
  '</td></tr>'
  '<tr><td style="padding:24px;font:400 15px/1.6 Arial,Helvetica,sans-serif;color:#111827;">'
  || v_top ||
  '<h1 style="margin:0 0 16px 0;font:700 20px/1.3 Arial,Helvetica,sans-serif;color:#111827;">'
  || public.wa_html_escape(p_title) || '</h1>'
  || v_body || v_tail ||
  '</td></tr>'
  '<tr><td style="padding:16px 24px;border-top:1px solid #E5E7EB;font:400 13px/1.5 Arial,Helvetica,sans-serif;color:#6B7280;">'
  || v_foot ||
  '</td></tr></table></td></tr></table></body></html>';
end $fn$;

-- Every channel writes its own line in the send log, including the one that
-- was skipped because there is no address on file, and the mail carries the
-- template's media, buttons and footer.
CREATE OR REPLACE FUNCTION public.notif_send_email_raw(p_event_key text, p_to text DEFAULT NULL::text, p_vars jsonb DEFAULT '{}'::jsonb, p_user_id uuid DEFAULT NULL::uuid, p_order_id uuid DEFAULT NULL::uuid, p_parent_log_id bigint DEFAULT NULL::bigint, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- CMD #1848 — a human test session's rows never leave the building.
  if public.test_order_silenced(p_order_id) then
    return jsonb_build_object('ok', false, 'reason','test_mode_silenced');
  end if;
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
    -- CMD #2055 — the skip is recorded. Three channels always go out; this
    -- recipient simply has no mailbox, and the log says so.
    insert into notification_log (event_key, channel, audience, recipient_id, status, ok,
                                  reason, order_id, parent_log_id, vars)
    values (p_event_key, 'email', r.audience, v_uid, 'skipped', false,
            'no_email_on_file', p_order_id, p_parent_log_id, coalesce(p_vars,'{}'::jsonb));
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

  v_html := public.notif_email_html(v_subj, v_bodyt, v_lang,
              case when v_lang = 'hi' and coalesce(r.email_extra_hi,'{}'::jsonb) <> '{}'::jsonb
                   then r.email_extra_hi else coalesce(r.email_extra,'{}'::jsonb) end);

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
end $function$;

CREATE OR REPLACE FUNCTION public.notif_push_send_raw(p_event_key text, p_phone10 text, p_user_id uuid DEFAULT NULL::uuid, p_order_id uuid DEFAULT NULL::uuid, p_vars jsonb DEFAULT '{}'::jsonb, p_audience text DEFAULT 'customer'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
declare
  cfg record; r record; u record;
  v_tokens jsonb; v_lang text; v_title text; v_body text; v_link text;
  v_log_id bigint; v_sent int := 0; v_users int := 0; v_req bigint;
begin
  -- CMD #2017 — the hard wall: a synthetic / zone-99 order never leaves.
  if p_order_id is not null and exists (select 1 from public.orders o
        where o.id = p_order_id
          and public.mode_outbound_blocked(o.is_synthetic, o.zone_id::smallint, o.test_session_id))
  then return jsonb_build_object('ok', false, 'reason', 'synthetic_walled'); end if;
  -- CMD #1848 — a human test session's rows never leave the building.
  if public.test_order_silenced(p_order_id)
     or public.test_customer_silenced(nullif(p_vars->>'customer_id','')::uuid) then
    return jsonb_build_object('ok', false, 'reason','test_mode_silenced');
  end if;
  select * into cfg from push_config where id = 'singleton';
  if cfg.id is null or not cfg.enabled or coalesce(nullif(btrim(cfg.sender_id),''),'') = '' then
    return jsonb_build_object('ok', false, 'reason','push_not_configured');
  end if;

  select * into r from wa_event_routes where event_key = p_event_key;
  if r.event_key is null then
    return jsonb_build_object('ok', false, 'reason','unknown_event');
  end if;
  if not coalesce(r.push_enabled, false) then
    return jsonb_build_object('ok', false, 'reason','push_disabled_for_event');
  end if;
  if coalesce(nullif(btrim(r.push_body),''),'') = '' then
    return jsonb_build_object('ok', false, 'reason','no_push_body');
  end if;

  for u in
    select t.user_id, min(t.phone10) as phone10,
           jsonb_agg(distinct t.token) as tokens
      from push_tokens t
     where t.is_active
       and ( (p_user_id is not null and t.user_id = p_user_id)
          or (p_phone10  is not null and t.phone10 = p_phone10) )
     group by t.user_id
  loop
    v_users := v_users + 1;
    if not public.notif_user_allows(u.user_id, coalesce(r.audience,p_audience), p_event_key, 'push') then
      continue;
    end if;

    v_lang  := public.notif_language_for(u.user_id, coalesce(u.phone10, p_phone10), null);
    v_title := public.notif_render(
                 case when v_lang = 'hi' then coalesce(nullif(r.push_title_hi,''), r.push_title)
                      else r.push_title end, p_vars);
    v_body  := public.notif_render(
                 case when v_lang = 'hi' then coalesce(nullif(r.push_body_hi,''), r.push_body)
                      else r.push_body end, p_vars);
    v_link  := public.notif_deep_link(p_event_key, p_order_id, coalesce(r.audience,p_audience), p_vars);
    v_tokens := u.tokens;

    insert into notification_log (event_key, recipient, channel, status, ok,
            audience, recipient_id, user_id, order_id, customer_id, title, body,
            deep_link, language, vars, payload, path)
    values (p_event_key,
            coalesce(nullif(btrim(u.phone10),''), nullif(btrim(p_phone10),''), u.user_id::text),
            'push', 'queued', null,
            coalesce(r.audience, p_audience), u.user_id, u.user_id, p_order_id,
            nullif(p_vars->>'customer_id','')::uuid, v_title, v_body, v_link, v_lang,
            coalesce(p_vars,'{}'::jsonb),
            jsonb_build_object('tokens', jsonb_array_length(v_tokens)), 'push')
    returning id into v_log_id;

    select net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/push-send',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027',
                                    'Authorization','Bearer ' || public._service_key()),
      body    := jsonb_build_object('log_id', v_log_id, 'tokens', v_tokens,
                                    'title', v_title, 'body', v_body,
                                    'deep_link', v_link,
                                    'event_key', p_event_key,
                                    'order_id', p_order_id)
                 -- CMD #2055 — the picture, the thumbnail and the buttons the
                 -- WhatsApp template was built with, derived once and carried
                 -- on the wire. A sender that does not know a key ignores it.
                 || coalesce(case when v_lang = 'hi' and coalesce(r.push_extra_hi,'{}'::jsonb) <> '{}'::jsonb
                                  then r.push_extra_hi else r.push_extra end, '{}'::jsonb),
      timeout_milliseconds := 20000) into v_req;
    v_sent := v_sent + 1;
  end loop;

  if v_users = 0 then
    return jsonb_build_object('ok', false, 'reason','no_active_token');
  end if;
  if v_sent = 0 then
    return jsonb_build_object('ok', false, 'reason','push_opted_out');
  end if;
  -- The reply shape is UNCHANGED from the version this replaces: notify() logs
  -- `reason` verbatim on the push path, so renaming a key here would quietly
  -- rewrite the ledger for every audience.
  return jsonb_build_object('ok', true, 'reason','push_queued',
                            'users', v_sent, 'log_id', v_log_id);
end $function$;

-- Email is not a fallback any more, so the screen stops saying it is.
CREATE OR REPLACE FUNCTION public.notif_email_admin()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
           'mode_label',   case when r.email_mode = 'off' then 'Off' else 'Always email' end,
           'sync_label',   case when coalesce(r.email_manual,false) then 'Manual' else 'Synced' end,
           'sync_tone',    case when coalesce(r.email_manual,false) then 'warning' else 'success' end,
           'sync_label_hi',case when coalesce(r.email_manual_hi,false) then 'Manual' else 'Synced' end,
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
    'subtitle','Email is one of the three channels every event sends. Wording comes from the WhatsApp template unless this event is marked Manual.',
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
      jsonb_build_object('key','always','label','Always email')),
    'language_options', jsonb_build_array(
      jsonb_build_object('key','en','label','English'),
      jsonb_build_object('key','hi','label','हिन्दी')),
    'rows', v_rows,
    'empty_text','No notification events are configured yet.');
end $function$;

-- ── 12. all three channels on, and one first derivation for every event ──────
update public.wa_event_routes
   set push_enabled  = true,
       email_enabled = true,
       email_mode    = case when email_mode = 'fallback' then 'always' else coalesce(email_mode,'always') end
 where coalesce(push_enabled,false) is distinct from true
    or coalesce(email_enabled,false) is distinct from true
    or coalesce(email_mode,'') in ('fallback','');

-- The first derivation is the baseline. Wording typed into Push or Email
-- BEFORE this change is exactly what the template now replaces, so it is not
-- treated as a manual override; only an edit made from here on marks a channel.

select public.wa_channel_sync_event(event_key) from public.wa_event_routes;

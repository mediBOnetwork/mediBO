-- CHANGE #295 — the WhatsApp autopilot must not overwrite a curated pipeline_note.
--
-- Found while verifying #295: gcp_billing_daily had been switched off in step 4
-- with a note explaining that nothing can ever fire it. When Meta approved that
-- template, _wa_route_autoenable() switched the route back on AND replaced the
-- note with the generic 'Live — Meta approved…' string. The diagnosis screen
-- prints pipeline_note VERBATIM, so an ops screen built to expose dead routes
-- was captioning one of them "Live".
--
-- The route flipping itself on is the autopilot's job and stays. What is fixed
-- here is the caption: a note a human (or a command) wrote is preserved, and
-- only the autopilot's OWN previous strings are overwritten. This is strictly
-- write-reducing — no route changes state because of it.

create or replace function public._wa_note_is_auto(p_note text)
returns boolean
language sql
immutable
set search_path to 'public'
as $$
  -- true when the note is blank or was itself written by the autopilot, i.e.
  -- safe to overwrite. Anything else is curated and must survive.
  select p_note is null
      or btrim(p_note) = ''
      or p_note like 'Live — Meta approved%'
      or p_note like 'Meta rejected this template%'
      or p_note like 'Waiting on Meta approval for template%'
      or p_note like 'Waiting on the header sample file%'
      or p_note like 'Held back: the pre-submit review%';
$$;

comment on function public._wa_note_is_auto(text) is
  'CHANGE #295 — true when a wa_event_routes.pipeline_note is blank or autopilot-written, so the autopilot may replace it. A curated note returns false and is preserved.';

-- 1. the per-template-approval trigger
create or replace function public._wa_route_autoenable()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
begin
  if new.status = 'APPROVED' and coalesce(old.status,'') <> 'APPROVED' then
    update wa_event_routes
       set template_id = new.id, template_name = new.name, language = new.language,
           enabled = true,
           pipeline_note = case
             when public._wa_note_is_auto(pipeline_note)
               then 'Live — Meta approved this template and the route switched itself on'
             else pipeline_note
           end,
           updated_at = now()
     where auto_manage and auto_template_name = new.name;
  end if;
  return new;
end $function$;

-- 2. the batch autopilot (same clobber, and the branch that actually hit
--    gcp_billing_daily: a curated route that was switched OFF matches
--    'not r.enabled' on the next run and gets re-enabled + re-captioned).
CREATE OR REPLACE FUNCTION public.wa_event_autopilot_run(p_min_age_minutes integer DEFAULT 10, p_allow_unreviewed boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s record; r record; t record; v_id uuid; v_rid uuid; v_cat text;
        v_created int := 0; v_synced int := 0; v_rearmed int := 0; v_reviewed int := 0;
        v_submitted int := 0; v_enabled int := 0;
        v_blocked jsonb := '[]'::jsonb; v_risk text; v_age interval;
        v_media jsonb; v_want jsonb;
        c_max_attempts constant int := 3;
begin
  v_age := make_interval(mins => greatest(coalesce(p_min_age_minutes,10), 0));

  for s in select * from wa_event_template_seeds loop
    if not exists (select 1 from wa_templates where name = s.name and language = s.language) then
      insert into wa_templates(name, language, category, components, token_map, status,
                               header_format, header_media_path, header_media_mime)
      values (s.name, s.language, s.category, s.components, s.token_map, 'DRAFT',
              s.header_format, s.header_media_path, s.header_media_mime);
      v_created := v_created + 1;
      continue;
    end if;

    select public._wa_seed_components(s.components, tp.header_handle) into v_want
      from wa_templates tp where tp.name = s.name and tp.language = s.language;

    update wa_templates tp
       set components = v_want, token_map = s.token_map, category = s.category,
           header_format = s.header_format, header_media_path = s.header_media_path,
           header_media_mime = s.header_media_mime, updated_at = now()
     where tp.name = s.name and tp.language = s.language
       and tp.submitted_at is null and tp.status = 'DRAFT' and tp.meta_id is null
       and (tp.components is distinct from v_want
            or tp.token_map is distinct from s.token_map
            or coalesce(tp.header_format,'TEXT') is distinct from coalesce(s.header_format,'TEXT'));
    if found then v_synced := v_synced + 1; end if;

    update wa_templates tp
       set components = v_want, token_map = s.token_map, category = s.category,
           header_format = s.header_format, header_media_path = s.header_media_path,
           header_media_mime = s.header_media_mime,
           status = 'DRAFT', submitted_at = null, updated_at = now()
     where tp.name = s.name and tp.language = s.language
       and tp.status = 'REJECTED'
       and tp.submit_attempts < c_max_attempts
       and (tp.components is distinct from v_want or tp.category is distinct from s.category);
    if found then v_rearmed := v_rearmed + 1; end if;
  end loop;

  v_media := public.wa_media_refresh_tick();

  for t in select distinct tp.* from wa_templates tp
           where tp.status = 'DRAFT' and tp.submitted_at is null
             and tp.hidden_at is null
             and tp.submit_attempts < c_max_attempts
             and tp.updated_at < now() - v_age
             and (exists (select 1 from wa_event_template_seeds sd
                           where sd.name = tp.name and sd.language = tp.language)
               or exists (select 1 from wa_event_routes er
                           where er.auto_manage and er.auto_template_name = tp.name))
             and not exists (select 1 from wa_policy_reviews pr
                              where pr.template_id = tp.id
                                and (pr.status = 'done' or pr.created_at > now() - interval '10 minutes')
                                and pr.created_at > tp.updated_at - interval '1 minute')
  loop
    insert into wa_policy_reviews(template_id) values (t.id) returning id into v_rid;
    perform net.http_post(
      url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/wa-policy-review',
      headers := jsonb_build_object('Content-Type','application/json','x-notify-secret','medibo_order_notify_2027'),
      body := jsonb_build_object('review_id', v_rid));
    v_reviewed := v_reviewed + 1;
  end loop;

  for t in select distinct tp.* from wa_templates tp
           where tp.status = 'DRAFT' and tp.submitted_at is null
             and tp.hidden_at is null
             and tp.submit_attempts < c_max_attempts
             and tp.updated_at < now() - v_age
             and (exists (select 1 from wa_event_template_seeds sd
                           where sd.name = tp.name and sd.language = tp.language)
               or exists (select 1 from wa_event_routes er
                           where er.auto_manage and er.auto_template_name = tp.name))
  loop
    select pr.verdict->>'risk' into v_risk from wa_policy_reviews pr
     where pr.template_id = t.id and pr.status = 'done'
     order by pr.created_at desc limit 1;

    if v_risk is null and not p_allow_unreviewed then
      continue;
    elsif v_risk = 'high' then
      v_blocked := v_blocked || jsonb_build_object('template', t.name, 'reason', 'ai_high_risk');
      update wa_event_routes er set pipeline_note =
        'Held back: the pre-submit review rated this high risk. The wording is being reworked.'
       where er.auto_template_name = t.name;
      continue;
    elsif not (wa_template_validate(t.components, t.category)->>'ok')::bool then
      v_blocked := v_blocked || jsonb_build_object('template', t.name, 'reason', 'lint_failed');
      continue;
    elsif coalesce(t.header_format,'TEXT') <> 'TEXT'
          and (t.header_handle is null
               or coalesce(public.wa_header_handle_expiry(t.header_handle), to_timestamp(0)) < now()) then
      v_blocked := v_blocked || jsonb_build_object('template', t.name, 'reason','media_sample_missing');
      update wa_event_routes er set pipeline_note =
        'Waiting on the header sample file — mediBO re-uploads it to Meta automatically, then submits.'
       where er.auto_template_name = t.name;
      continue;
    end if;

    update wa_templates set submit_attempts = submit_attempts + 1 where id = t.id;
    perform net.http_post(
      url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/wa-templates',
      headers := jsonb_build_object('Content-Type','application/json','x-notify-secret','medibo_order_notify_2027'),
      body := jsonb_build_object('action','submit','id', t.id));
    v_submitted := v_submitted + 1;
  end loop;

  update wa_event_routes er set pipeline_note =
      'Meta rejected this template' ||
      coalesce(' — ' || (select rejected_reason from wa_templates wt
                          where wt.name = er.auto_template_name and wt.status='REJECTED' limit 1), '') ||
      '. This message keeps sending as plain text until the wording is reworked.'
   where er.auto_manage
     and exists (select 1 from wa_templates wt2
                  where wt2.name = er.auto_template_name and wt2.status = 'REJECTED');

  for r in select * from wa_event_routes where auto_manage and auto_template_name is not null loop
    select id, category into v_id, v_cat from wa_templates
     where name = r.auto_template_name and status = 'APPROVED'
     order by (language = 'en') desc limit 1;

    if v_id is not null and (r.template_id is distinct from v_id or not r.enabled) then
      update wa_event_routes
         set template_id = v_id, template_name = r.auto_template_name,
             language = (select language from wa_templates where id = v_id),
             enabled = true,
             bypass_send_window = (upper(coalesce(v_cat,'UTILITY')) <> 'MARKETING'),
             pipeline_note = case
               when public._wa_note_is_auto(pipeline_note)
                 then 'Live — Meta approved this template and the route switched itself on'
               else pipeline_note
             end,
             updated_at = now()
       where event_key = r.event_key;
      v_enabled := v_enabled + 1;
    elsif v_id is null and r.template_id is null then
      update wa_event_routes set pipeline_note = coalesce(pipeline_note,
        'Waiting on Meta approval for template "' || r.auto_template_name || '"')
       where event_key = r.event_key;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'drafts_created', v_created, 'drafts_synced', v_synced,
                            'rejected_rearmed', v_rearmed, 'reviews_started', v_reviewed,
                            'submitted', v_submitted, 'routes_enabled', v_enabled,
                            'blocked', v_blocked, 'media', v_media);
end $function$

;

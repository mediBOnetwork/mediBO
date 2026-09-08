-- CHANGE #714 (D) - the console was printing an internal key at an admin.
--
-- The first screenshot of the live console showed two sentences no human wrote
-- for that spot:
--
--   Reorder            reorder_wa_inbound
--   Complaint          Off - every message goes straight to a person.
--
-- The first is the `defer_to` column - a trigger name - rendered verbatim as if
-- it were copy. The second is `switch_off_note`, the MASTER switch's sentence,
-- borrowed by the screen for any always_handoff intent: it says the row is off
-- while the row's own toggle is plainly on.
--
-- Both were Dart deciding what sentence a row deserves, which is the one thing
-- the frontend may not do. So the backend sends the sentence: every intent
-- carries its own `note`, empty when there is nothing to say, and the console
-- prints that and nothing else. Idempotent; the function body is otherwise
-- byte-identical to (A).

insert into public.ui_copy (key, value) values
  ('wa_asst.intent_defer_note',
     to_jsonb('Already answered by an existing automatic reply.'::text)),
  ('wa_asst.intent_handoff_note',
     to_jsonb('Always handed to a person.'::text))
on conflict (key) do nothing;

create or replace function public.wa_assistant_console(p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_rows jsonb; v_intents jsonb; v_zones jsonb; v_global record;
begin
  if coalesce(public.get_my_role(),'none') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'title', public.uic('wa_asst.console_title','WhatsApp assistant'),
      'message', public.uic('wa_asst.console_denied',''));
  end if;

  select * into v_global from public.wa_assistant_config where zone_id = 0;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', r.id::text,
           'phone', r.phone,
           'inbound', coalesce(r.inbound_text,''),
           'intent', coalesce(i.label, coalesce(r.intent,'—')),
           'intent_key', coalesce(r.intent,''),
           'confidence', r.confidence,
           'confidence_label', case when r.confidence is null then '—'
                                    else to_char(round(r.confidence*100), 'FM990') || '%' end,
           'sentiment', coalesce(r.sentiment,''),
           'outcome', r.outcome,
           'outcome_label', case r.outcome
                              when 'answered' then public.uic('wa_asst.outcome_answered','')
                              when 'handoff'  then public.uic('wa_asst.outcome_handoff','')
                              else public.uic('wa_asst.outcome_skipped','') end,
           'outcome_tone', case r.outcome when 'answered' then 'success'
                                          when 'handoff' then 'warning' else 'neutral' end,
           'reason', coalesce(r.reason,''),
           'reply', coalesce(r.reply_text,''),
           'at', public._ist_stamp(r.created_at))
         order by r.created_at desc), '[]'::jsonb)
    into v_rows
    from (select * from public.wa_assistant_reply
           order by created_at desc
           limit greatest(coalesce(p_limit,50),1)) r
    left join public.wa_assistant_intent i on i.key = r.intent;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', t.key, 'label', t.label, 'enabled', t.enabled,
           'always_handoff', t.always_handoff,
           'defer_to', coalesce(t.defer_to,''),
           'needs_order', t.needs_order,
           -- CHANGE #714 (D) — ONE place decides what a row says about itself.
           -- Deferral outranks hand-off: an intent another feature already
           -- answers is never reached by the hand-off rules at all.
           'note', case
                     when coalesce(t.defer_to,'') <> ''
                       then public.uic('wa_asst.intent_defer_note','')
                     when t.always_handoff
                       then public.uic('wa_asst.intent_handoff_note','')
                     else '' end)
         order by t.sort_order), '[]'::jsonb)
    into v_intents from public.wa_assistant_intent t;

  select coalesce(jsonb_agg(jsonb_build_object(
           'zone_id', z.id, 'zone_name', z.name,
           'enabled', coalesce(c.enabled, false))
         order by z.id), '[]'::jsonb)
    into v_zones
    from public.zones z
    left join public.wa_assistant_config c on c.zone_id = z.id
   where z.is_active and not coalesce(z.is_synthetic, false);

  return jsonb_build_object('ok', true,
    'title', public.uic('wa_asst.console_title',''),
    'subtitle', public.uic('wa_asst.console_subtitle',''),
    'empty_note', public.uic('wa_asst.console_empty',''),
    'switch_label', public.uic('wa_asst.switch_label',''),
    'switch_off_note', public.uic('wa_asst.switch_off_note',''),
    'intents_heading', public.uic('wa_asst.intents_heading',''),
    'replies_heading', public.uic('wa_asst.replies_heading',''),
    'zone_heading', public.uic('wa_asst.zone_heading',''),
    'enabled', coalesce(v_global.enabled, false),
    'min_confidence', coalesce(v_global.min_confidence, 0.75),
    'intents', v_intents,
    'zones', v_zones,
    'rows', v_rows);
end $function$;

revoke all on function public.wa_assistant_console(integer) from public, anon;
grant execute on function public.wa_assistant_console(integer) to authenticated;

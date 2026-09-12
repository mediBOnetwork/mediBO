-- CHANGE — #297 part 1: preview sample values.
--
-- The first cut coalesced on a value that is '' rather than null, so every
-- token rendered blank and the preview read "Hi , we have received your order ."
-- Sample values are seeded copy (notify.sample.<token>) so a new token gets a
-- realistic example without a deploy; an unseeded token falls back to its own
-- name in caps, which is still visibly a placeholder rather than a blank.
create or replace function public.notify_preview(p_event_key text, p_vars jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare r record; t record; v_body text; v_tokens jsonb := coalesce(p_vars,'{}'::jsonb);
        v_keys text[]; k text; v_sample jsonb := '{}'::jsonb; v_val text; v_comp jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public._nc('notify.not_authorized','Only an admin can preview a message.'));
  end if;

  select * into r from public.wa_event_routes where event_key = p_event_key;
  if r.event_key is null then
    return jsonb_build_object('ok', false, 'error','unknown_event',
      'message', public._ncf('notify.unknown_event', jsonb_build_object('a', p_event_key),
                             'There is no route called {a}.'));
  end if;

  select * into t from public.wa_templates where id = r.template_id;

  select coalesce(
           case when jsonb_typeof(t.token_map) = 'array'
                  then array(select jsonb_array_elements_text(t.token_map)) end,
           case when jsonb_typeof(r.variable_map) = 'array'
                  then array(select (regexp_matches(el, '^\{\{([a-z0-9_]+)\}\}$'))[1]
                               from jsonb_array_elements_text(r.variable_map) el) end,
           '{}'::text[])
    into v_keys;

  foreach k in array coalesce(v_keys,'{}'::text[]) loop
    v_val := coalesce(nullif(v_tokens->>k, ''),
                      nullif(public._nc('notify.sample.' || k, ''), ''),
                      upper(replace(k,'_',' ')));
    v_sample := v_sample || jsonb_build_object(k, v_val);
  end loop;

  select c->>'text' into v_body
    from jsonb_array_elements(coalesce(t.components,'[]'::jsonb)) c
   where upper(coalesce(c->>'type','')) = 'BODY'
   limit 1;

  if v_body is not null then
    for k in select jsonb_object_keys(v_sample) loop
      v_body := replace(v_body, '{{' || k || '}}', coalesce(v_sample->>k,''));
    end loop;
    for i in 1 .. coalesce(array_length(v_keys,1),0) loop
      v_body := replace(v_body, '{{' || i || '}}', coalesce(v_sample->>v_keys[i],''));
    end loop;
  end if;

  select jsonb_agg(jsonb_build_object('type', upper(coalesce(c->>'type','')),
                                      'text', c->>'text'))
    into v_comp
    from jsonb_array_elements(coalesce(t.components,'[]'::jsonb)) c;

  return jsonb_build_object(
    'ok', true,
    'heading',        public._nc('notify.preview_heading','Preview'),
    'event_key',      r.event_key,
    'title',          coalesce(r.label, r.event_key),
    'audience',       coalesce(r.audience,'customer'),
    'channel_label',  public._nc('notify.channel_whatsapp','WhatsApp'),
    'template_name',  t.name,
    'template_status',upper(coalesce(t.status,'NONE')),
    'status_label',   case when upper(coalesce(t.status,'')) = 'APPROVED'
                           then public._nc('notify.tpl_approved','Approved by Meta')
                           when t.id is null
                           then public._nc('notify.tpl_none','No template linked yet')
                           else public._ncf('notify.tpl_pending', jsonb_build_object('a', coalesce(t.status,'?')),
                                            'Template is {a} — not sendable yet') end,
    'status_tone',    case when upper(coalesce(t.status,'')) = 'APPROVED' then 'good' else 'warn' end,
    'enabled',        coalesce(r.enabled,false),
    'sample_note',    public._nc('notify.preview_sample_note','Sample values — nothing is sent.'),
    'tokens',         v_sample,
    'components',     coalesce(v_comp,'[]'::jsonb),
    'body_preview',   coalesce(v_body, public._nc('notify.no_body','This route has no template body yet.')),
    'empty_label',    public._nc('notify.preview_empty','Nothing to preview until a template is linked.'));
end $$;

insert into public.ui_copy(key, value) values
 ('notify.preview_sample_note','"Sample values — nothing is sent."'::jsonb),
 ('notify.sample.order_code','"MB-1042"'::jsonb),
 ('notify.sample.customer_name','"Sharma Medical Store"'::jsonb),
 ('notify.sample.pharmacy_name','"Sharma Medical Store"'::jsonb),
 ('notify.sample.supplier_name','"Jai Mahakal Distributors"'::jsonb),
 ('notify.sample.amount','"1,240.00"'::jsonb),
 ('notify.sample.today_date','"23 Aug 2026"'::jsonb),
 ('notify.sample.otp','"482913"'::jsonb),
 ('notify.sample.item_count','"12"'::jsonb),
 ('notify.sample.link','"medibo.in/o/MB-1042"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

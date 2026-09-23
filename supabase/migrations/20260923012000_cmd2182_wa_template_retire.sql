-- CMD #2182 — the Delete button on the Templates screen can finish its job.
--
-- Deleting a template needs Meta's permission and this token does not have it
-- ((#100) Need permission on either WhatsApp Business Account or owner/shared
-- business), so Delete has been a dead button for every template that ever
-- reached Meta: wa_template_delete_local refuses a row with a meta_id, and the
-- edge function's delete action hands Meta's refusal back to the admin. That is
-- why six dead customer_imported attempts sat on the screen for a day.
--
-- Retiring is the honest second half of that action: the row goes, the name
-- joins wa_template_retired so no sync can bring it back, and Meta's copy is
-- left untouched and unused. The sentence the admin reads is app_settings copy,
-- not a string in the edge function or in Dart.

insert into public.app_settings (key, value)
select 'wa_templates_copy', '{}'::jsonb
 where not exists (select 1 from public.app_settings where key = 'wa_templates_copy');

update public.app_settings
   set value = value
     || jsonb_build_object(
          'delete_confirm',
          'Delete "{name}"? It is removed from mediBO for good. If Meta will not let us delete it there, it stays in your WhatsApp account, unused.',
          'delete_retired',
          'Removed from mediBO. Meta would not let us delete it there, so it stays in your WhatsApp account — it will never appear on this screen again.')
 where key = 'wa_templates_copy';

create or replace function public.wa_template_retire(p_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare t public.wa_templates%rowtype; v_msg text;
begin
  -- The edge function reaches this with the service role; an admin reaches it
  -- through the screen. Nobody else may retire a template.
  if coalesce(auth.role(),'') <> 'service_role'
     and public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;

  select * into t from public.wa_templates where id = p_id;
  if t.id is null then return jsonb_build_object('error','not_found'); end if;

  if exists (select 1 from public.wa_event_routes er where er.template_id = t.id) then
    return jsonb_build_object('error','in_use','message',
      format('"%s" is bound to an event route — unbind it there first', t.name));
  end if;
  if exists (select 1 from public.wa_campaigns c
              where c.template_id = t.id and coalesce(c.status,'') = 'running') then
    return jsonb_build_object('error','in_use','message',
      format('"%s" is the template of a running campaign', t.name));
  end if;

  insert into public.wa_template_retired (name, language, reason)
  values (t.name, coalesce(t.language,'en'), coalesce(p_reason, 'Retired from the Templates screen'))
  on conflict (name, language) do update set reason = excluded.reason, retired_at = now();

  delete from public.wa_templates where id = t.id;

  select coalesce(value->>'delete_retired', 'Removed from mediBO.')
    into v_msg from public.app_settings where key = 'wa_templates_copy';

  return jsonb_build_object('ok', true, 'retired', true, 'name', t.name, 'message', v_msg);
end $$;

revoke all on function public.wa_template_retire(uuid, text) from public;
grant execute on function public.wa_template_retire(uuid, text) to authenticated, service_role;

-- #297 QA fix (2/2) — the reorder inbound auto-reply was the other send still
-- posting straight at wa-reply, invisible to notification_log, the retry queue
-- and the health scan. Same treatment as the login button: identical payload,
-- routed through notify()'s legacy passthrough so it leaves a ledger row.
-- The reply text already comes from the backend (reorder_wa_inbound), so no
-- copy moves here. Idempotent: create or replace only.
create or replace function public.trg_wa_reorder_reply()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_res jsonb;
begin
  if coalesce(new.direction,'') <> 'in' then return new; end if;
  if coalesce(new.msg_type,'') not in ('text','button','interactive') then return new; end if;
  if coalesce(btrim(new.text_body),'') = '' then return new; end if;

  v_res := public.reorder_wa_inbound(new.sender_phone, new.text_body);
  if coalesce((v_res->>'handled')::boolean, false) and coalesce(v_res->>'reply','') <> '' then
    perform public.notify('reorder_reply', v_res->>'phone', jsonb_build_object(
      'legacy_url', 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/wa-reply',
      'legacy_body', jsonb_build_object('to', v_res->>'phone', 'tag','reorder_reply',
                                        'text', v_res->>'reply')));
  end if;
  return new;
exception when others then
  return new;
end $function$;

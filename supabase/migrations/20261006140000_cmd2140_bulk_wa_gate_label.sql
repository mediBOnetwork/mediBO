-- CMD #2140 — the green WhatsApp button on the Bulk landing was blank.
--
-- my_session_core() reads app_settings.bulk_wa_gate_copy -> <order gate reason>,
-- but two reasons it can return (licence_required, zone_agreement) had no entry,
-- so the label arrived as '' — and the signed-out branch returns no
-- bulk_wa_gate at all. Both are fixed here, in the backend, as copy + one patch
-- layer; Flutter keeps printing the label verbatim.
-- Idempotent: jsonb merge + CREATE OR REPLACE.

update app_settings
   set value = coalesce(value, '{}'::jsonb)
       || jsonb_build_object(
            'none', coalesce(value->'none', '{}'::jsonb)
                    || '{"label":"Send order on WhatsApp"}'::jsonb,
            'licence_required', jsonb_build_object(
              'label','Send order on WhatsApp','note','','action','send','enabled',true),
            'zone_agreement', jsonb_build_object(
              'label','Send order on WhatsApp','note','','action','send','enabled',true))
 where key = 'bulk_wa_gate_copy';

insert into app_settings(key, value)
select 'bulk_wa_gate_copy', jsonb_build_object(
  'none', jsonb_build_object('label','Send order on WhatsApp','note','','action','send','enabled',true),
  'signed_out', jsonb_build_object('label','Login to Send Order','note','Login required to place orders','action','login','enabled',true),
  'licence_required', jsonb_build_object('label','Send order on WhatsApp','note','','action','send','enabled',true),
  'zone_agreement', jsonb_build_object('label','Send order on WhatsApp','note','','action','send','enabled',true))
where not exists (select 1 from app_settings where key = 'bulk_wa_gate_copy');

-- Fills bulk_wa_gate whenever the session payload carries none (signed out) or
-- an empty label (a reason with no copy row): the gate is always the copy row
-- for the order gate's own reason, so the button is never blank.
create or replace function public._session_wa_gate_patch(j jsonb)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    when coalesce(j->'bulk_wa_gate'->>'label','') <> '' then j
    else j || jsonb_build_object('bulk_wa_gate', (
      select jsonb_build_object(
               'label',   coalesce(c->>'label',''),
               'note',    coalesce(c->>'note',''),
               'enabled', coalesce((c->>'enabled')::boolean,false),
               'action',  coalesce(c->>'action','none'),
               'has_note',(coalesce(c->>'note','') <> ''))
        from (select (select value from app_settings where key='bulk_wa_gate_copy')
                     -> coalesce(nullif(j->'order_gate'->>'reason',''),
                                 case when coalesce((j->>'signed_in')::boolean,false)
                                      then 'none' else 'signed_out' end) as c) z))
  end
$$;

revoke all on function public._session_wa_gate_patch(jsonb) from public, anon;

create or replace function public.my_session()
 returns jsonb
 language sql
 security definer
 set search_path to 'public'
as $function$
  select public._session_wa_gate_patch(
           public._session_logout_patch(
             public._session_signup_patch(
               public._session_header_short(
                 public._session_partner_overlay(public.my_session_core())))));
$function$;

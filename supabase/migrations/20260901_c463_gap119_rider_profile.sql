-- CHANGE #463 · register row 119 — "A rider cannot edit their own profile in
-- the app".
--
-- REPRODUCED: my_delivery_profile_update(p jsonb) already existed and was
-- correct — and NOTHING in lib/ called it. `grep -rn my_delivery_profile_update
-- lib/` returned nothing. An orphan backend is not a shipped feature (rule 11),
-- so a rider whose phone changed still had to ask an admin.
--
-- What was missing was the READ half: there was no way to populate the form.
-- my_delivery_home() carries full_name but not vehicle_type/address/city, so it
-- cannot back an edit form.
--
-- my_delivery_profile() is that half, and it ships the FIELD LIST too: the
-- label, the current value, the keyboard and the ordering all come from here,
-- so the sheet renders a payload instead of hard-coding six TextFields. Adding
-- a seventh editable field is a row in this function, not a deploy.

create or replace function public.my_delivery_profile()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v delivery_partner_registrations%rowtype;
begin
  select * into v from delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false) = false
   limit 1;

  if v.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_partner',
      'message', 'This screen is for delivery partners.');
  end if;

  return jsonb_build_object(
    'ok', true,
    'partner_id', v.id,
    'title', 'My details',
    'save_label', 'Save changes',
    -- Verified identity fields are shown but NOT editable: a rider must not be
    -- able to rename themselves out of their own verification.
    'fields', jsonb_build_array(
      jsonb_build_object('key','full_name',   'label','Full name',
                         'value', coalesce(v.full_name,''),   'keyboard','text'),
      jsonb_build_object('key','phone',       'label','Phone',
                         'value', coalesce(v.phone,''),       'keyboard','phone'),
      jsonb_build_object('key','email',       'label','Email',
                         'value', coalesce(v.email,''),       'keyboard','email'),
      jsonb_build_object('key','vehicle_type','label','Vehicle',
                         'value', coalesce(v.vehicle_type,''),'keyboard','text'),
      jsonb_build_object('key','address',     'label','Address',
                         'value', coalesce(v.address,''),     'keyboard','text'),
      jsonb_build_object('key','city',        'label','City',
                         'value', coalesce(v.city,''),        'keyboard','text')));
end
$function$;

revoke all on function public.my_delivery_profile() from public;
grant execute on function public.my_delivery_profile() to authenticated;

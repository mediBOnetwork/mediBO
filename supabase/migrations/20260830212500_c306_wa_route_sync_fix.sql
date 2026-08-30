-- ============================================================================
-- CHANGE #306 — auto-solved on the way past.
--
-- notification_settings grew a `channel` column and its unique key became
-- (audience, action_key, channel) WHERE user_id IS NULL, but the trigger that
-- mirrors a wa_event_routes row into it still said `on conflict (audience,
-- action_key)`. That specification matches no constraint, so EVERY insert of a
-- new event route has been failing with 42P10 — the first new route since the
-- column landed (this one) is what surfaced it. Same behaviour, correct key,
-- and one row, on the channel value every other row already uses.
-- ============================================================================
create or replace function public._wa_route_to_notification()
returns trigger
language plpgsql set search_path to 'public' as $function$
declare v_sort int; v_ch text;
begin
  select coalesce(max(sort),0) + 1 into v_sort
    from notification_settings where audience = new.audience;

  -- Every existing row in this table uses channel 'all'; the settings screen
  -- keys on that, so a new route mirrors to exactly one row, the same shape.
  v_ch := 'all';
  insert into notification_settings(audience, action_key, label, enabled, sort,
                                    channel, updated_at)
  values (new.audience, new.event_key, new.label, true, v_sort, v_ch, now())
  on conflict (audience, action_key, channel) where user_id is null
    do update set label = excluded.label, updated_at = now();  -- never touches enabled

  if tg_op = 'UPDATE' and old.audience is distinct from new.audience then
    delete from notification_settings
     where audience = old.audience and action_key = old.event_key and user_id is null;
  end if;
  return new;
end $function$;

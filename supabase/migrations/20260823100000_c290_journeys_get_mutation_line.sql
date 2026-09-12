-- CHANGE #290 — the mutation audit becomes visible in the app.
--
-- mutation_audits had no surface anywhere: the weekly audit could report that a
-- required journey has no teeth and nobody would ever see it. Rule 11 — no
-- backend without a reachable frontend.
--
-- Done without a single line of Dart. journey_library_screen.dart already
-- renders `assertions[]` verbatim, one bullet per entry, so journeys_get()
-- appends the latest verdict as one more assertion and the Journey Library
-- prints it on the next open. Wording lives in ui_copy, so changing it is an
-- UPDATE and never a deploy.
--
-- Click path: admin menu (super-admin) -> Dev Queue -> header map icon ->
-- Journey Library -> any journey card -> last line under "Assertions".

insert into ui_copy(key, value) values
  ('dev_queue.journey_mutation_line',   '"Mutation audit %s IST — %s: %s"'::jsonb),
  ('dev_queue.journey_mutation_caught', '"CAUGHT"'::jsonb),
  ('dev_queue.journey_mutation_missed', '"NOT CAUGHT — this journey did not notice the break"'::jsonb)
on conflict (key) do nothing;

create or replace function public.journeys_get(p_area text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v jsonb; v_fmt text; v_caught text; v_missed text;
begin
  perform _dev_guard();

  select value #>> '{}' into v_fmt    from ui_copy where key='dev_queue.journey_mutation_line';
  select value #>> '{}' into v_caught from ui_copy where key='dev_queue.journey_mutation_caught';
  select value #>> '{}' into v_missed from ui_copy where key='dev_queue.journey_mutation_missed';

  select coalesce(jsonb_agg(
           to_jsonb(j)
           || jsonb_build_object('assertions',
                coalesce(j.assertions, '[]'::jsonb)
                || case
                     when a.at is null or v_fmt is null then '[]'::jsonb
                     else jsonb_build_array(format(v_fmt,
                            to_char(a.at at time zone 'Asia/Kolkata', 'DD Mon YYYY HH24:MI'),
                            case when a.caught then v_caught else v_missed end,
                            coalesce(a.mutation, '')))
                   end)
           order by j.id), '[]')
    into v
  from dev_journeys j
  left join lateral (
    select m.at, m.caught, m.mutation
      from mutation_audits m
     where m.journey_id = j.id
     order by m.at desc, m.id desc
     limit 1) a on true
  where j.enabled and (p_area is null or j.area is null or j.area = p_area);

  return v;
end $$;

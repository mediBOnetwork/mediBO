-- CHANGE #790, part B1 — the Hinglish / Hindi mapping, and the one place it
-- is resolved.
--
-- The mapping runs BEFORE the product query. "bukhar" is not a brand and never
-- matches one; it is a WORD FOR A CONDITION, so it is resolved to the salt the
-- condition is treated with and the search runs on that. Both the typeahead
-- and the results page call the same resolver, so they can never disagree.

-- `hits` was a column nothing was ever going to write. Dropped before anything
-- depends on it (the table is new in this same change and holds no data).
alter table public.search_synonym drop column if exists hits;

create or replace function public.search_query_expand(p_q text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with n as (select public._norm_name(p_q) as q),
  -- The viewer's notification language does not GATE the mapping — an English
  -- UI must still understand "bukhar" — it only breaks ties, so a term that
  -- exists in both languages resolves the way this viewer reads.
  me as (select public.notif_norm_lang(public.my_language()) as lang),
  hit as (
    select s.*
      from public.search_synonym s, n, me
     where s.active
       and (s.term = n.q or n.q like s.term || ' %' or n.q like '% ' || s.term
            or n.q like '% ' || s.term || ' %')
     order by (s.term = n.q) desc, (s.lang = me.lang) desc, length(s.term) desc
     limit 1
  )
  select case when not exists (select 1 from hit)
    then jsonb_build_object('has', false)
    else (select jsonb_build_object(
            'has', true,
            'term', h.term,
            'display', h.display,
            'lang', h.lang,
            'target_kind', h.target_kind,
            'target', h.target,
            'note', h.note,
            'label', replace(replace(
                       public.uic('search.hinglish_note', '{term} → {target}'),
                       '{term}', h.display), '{target}', h.target))
          from hit h) end;
$function$;

comment on function public.search_query_expand(text) is
  'CHANGE #790 — resolves a Hindi/Hinglish search term to the salt or class it means, before any product query runs.';

grant execute on function public.search_query_expand(text) to anon, authenticated;

-- ── the seed rows ───────────────────────────────────────────────────────────
-- Written once by the `search-synonym-seed` edge function (Vertex AI global,
-- gemini-3.5-flash, GCP_SA_KEY) and editable afterwards from
-- Admin → Search synonyms. The rows below are the floor, not the ceiling: they
-- are the terms a Chhattisgarh pharmacy counter hears every day, so the
-- feature works the moment it ships even if the model is unreachable.
insert into public.search_synonym (term, display, lang, target_kind, target, note, source)
values
  ('bukhar',    'bukhar',   'hi', 'salt',     'Paracetamol',            'fever',            'seed'),
  ('बुखार',      'बुखार',     'hi', 'salt',     'Paracetamol',            'fever',            'seed'),
  ('taap',      'taap',     'hi', 'salt',     'Paracetamol',            'fever',            'seed'),
  ('khansi',    'khansi',   'hi', 'category', 'RESPIRATORY',            'cough',            'seed'),
  ('खांसी',      'खांसी',     'hi', 'category', 'RESPIRATORY',            'cough',            'seed'),
  ('sardi',     'sardi',    'hi', 'category', 'RESPIRATORY',            'cold',             'seed'),
  ('jukam',     'jukam',    'hi', 'category', 'RESPIRATORY',            'common cold',      'seed'),
  ('zukam',     'zukam',    'hi', 'category', 'RESPIRATORY',            'common cold',      'seed'),
  ('dard',      'dard',     'hi', 'salt',     'Diclofenac',             'pain',             'seed'),
  ('sir dard',  'sir dard', 'hi', 'salt',     'Paracetamol',            'headache',         'seed'),
  ('pet dard',  'pet dard', 'hi', 'salt',     'Dicyclomine',            'stomach pain',     'seed'),
  ('gas',       'gas',      'hi', 'salt',     'Pantoprazole',           'acidity / gas',    'seed'),
  ('acidity',   'acidity',  'en', 'salt',     'Pantoprazole',           'acidity',          'seed'),
  ('jalan',     'jalan',    'hi', 'salt',     'Pantoprazole',           'heartburn',        'seed'),
  ('ulti',      'ulti',     'hi', 'salt',     'Ondansetron',            'vomiting',         'seed'),
  ('उल्टी',      'उल्टी',      'hi', 'salt',     'Ondansetron',            'vomiting',         'seed'),
  ('dast',      'dast',     'hi', 'salt',     'Ofloxacin',              'loose motions',    'seed'),
  ('loose motion','loose motion','en','salt', 'Ofloxacin',              'loose motions',    'seed'),
  ('kabz',      'kabz',     'hi', 'category', 'GASTRO INTESTINAL',      'constipation',     'seed'),
  ('sugar',     'sugar',    'hi', 'salt',     'Metformin',              'diabetes',         'seed'),
  ('shugar',    'shugar',   'hi', 'salt',     'Metformin',              'diabetes',         'seed'),
  ('bp',        'bp',       'en', 'salt',     'Amlodipine',             'blood pressure',   'seed'),
  ('khoon ki kami','khoon ki kami','hi','salt','Ferrous Ascorbate',     'anaemia',          'seed'),
  ('kamzori',   'kamzori',  'hi', 'category', 'VITAMINS MINERALS NUTRIENTS', 'weakness',    'seed'),
  ('allergy',   'allergy',  'en', 'salt',     'Levocetirizine',         'allergy',          'seed'),
  ('kharish',   'kharish',  'hi', 'salt',     'Levocetirizine',         'itching',          'seed'),
  ('neend',     'neend',    'hi', 'category', 'NEURO CNS',              'sleep',            'seed'),
  ('sujan',     'sujan',    'hi', 'salt',     'Diclofenac',             'swelling',         'seed'),
  ('chot',      'chot',     'hi', 'salt',     'Diclofenac',             'injury',           'seed'),
  ('galey mein dard','galey mein dard','hi','salt','Azithromycin',      'sore throat',      'seed')
on conflict (term) do nothing;

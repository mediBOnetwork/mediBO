-- CMD #451 · feature_gaps rows 83 + 84 — one policy table for what a catalogue
-- status MEANS, so nothing in Dart and nothing in a query decides it again.
--
-- Why: "MEDICINE" holds 9 distinct status strings, two of which are corrupt
-- concatenations of a status and a sentence
-- ('DISCONTINUEDWE DO NOT FACILITATE SALE OF THIS PRODUCT AT PRESENT', 671 rows;
--  'NOT FOR SALEWE DO NOT FACILITATE...', 5,505 rows;
--  'BANNED FOR SALEAS PER MINISTRY OF HEALTH AND FAMILY WELFARE', 20 rows).
-- 4,649 rows are buyable AND 'NOT FOR SALE' at the same time, and the storefront
-- printed that status next to an enabled "Add to cart" because the availability
-- verdict only ever read supplier_count.

create table if not exists public.medicine_status_policy (
  status_key   text primary key,
  sellable     boolean not null,
  label        text    not null,
  reason       text    not null default '',
  tone         text    not null default 'neutral',
  sort_rank    int     not null default 50,
  updated_at   timestamptz not null default now()
);

insert into public.medicine_status_policy (status_key, sellable, label, reason, tone, sort_rank) values
  ('AVAILABLE',       true,  'Available',       '',                                                              'success', 10),
  ('SOLD OUT',        true,  'Sold out',        '',                                                              'neutral', 20),
  ('COMING SOON',     false, 'Coming soon',     'This product is not on sale yet.',                              'info',    60),
  ('DISCONTINUED',    false, 'Discontinued',    'This product has been discontinued and cannot be ordered.',     'warning', 70),
  ('NOT FOR SALE',    false, 'Not for sale',    'We do not facilitate sale of this product at present.',         'warning', 80),
  ('BANNED FOR SALE', false, 'Banned for sale', 'This product is banned for sale and cannot be ordered.',        'danger',  90)
on conflict (status_key) do update
  set sellable = excluded.sellable, label = excluded.label,
      reason = excluded.reason, tone = excluded.tone,
      sort_rank = excluded.sort_rank, updated_at = now();

-- Raw catalogue status -> canonical key. Longest matching prefix wins, which is
-- what repairs the concatenated strings without touching the 563k-row table.
create or replace function public._med_status_key(p_raw text)
returns text
language sql
immutable
set search_path to 'public'
as $function$
  select coalesce(
    (select s.status_key
       from public.medicine_status_policy s
      where upper(btrim(regexp_replace(coalesce(p_raw,''), '\s+', ' ', 'g')))
            like s.status_key || '%'
      order by length(s.status_key) desc
      limit 1),
    nullif(upper(btrim(coalesce(p_raw,''))), ''));
$function$;

-- Is a raw catalogue status sellable? An UNKNOWN status is sellable — a status
-- nobody has classified must never silently delist a product.
create or replace function public.med_status_sellable(p_raw text)
returns boolean
language sql
stable
set search_path to 'public'
as $function$
  select coalesce((select s.sellable from public.medicine_status_policy s
                    where s.status_key = public._med_status_key(p_raw)), true);
$function$;

-- The display block for a raw status: the repaired label, the policy's reason,
-- its tone, and the sentence that was concatenated onto the status (kept, not
-- thrown away — it is the only place that copy exists).
create or replace function public.med_status_block(p_raw text)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with k as (select public._med_status_key(p_raw) as key),
       p as (select s.* from public.medicine_status_policy s, k where s.status_key = k.key),
       t as (select btrim(substr(btrim(regexp_replace(coalesce(p_raw,''), '\s+',' ','g')),
                                 length((select key from k)) + 1)) as tail)
  select jsonb_build_object(
    'key',      (select key from k),
    'label',    coalesce((select label from p),
                         initcap(lower(coalesce((select key from k), '')))),
    'sellable', coalesce((select sellable from p), true),
    'tone',     coalesce((select tone from p), 'neutral'),
    'reason',   coalesce(nullif((select reason from p), ''),
                         nullif(initcap(lower((select tail from t))), ''),
                         ''),
    'note',     nullif(initcap(lower((select tail from t))), ''));
$function$;


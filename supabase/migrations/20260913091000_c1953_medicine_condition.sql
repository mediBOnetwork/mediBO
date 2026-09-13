-- CMD #1953 — STEP 2: a product carries its own conditions.
--
-- MEDICINE.uses is 372,454 rows of printed prose ("Treatment of Pain relief
-- and fever", "Product Form: Tablet", "Fever\n•Headache"). #1910 answered
-- "which products treat X?" with a 46-bucket vocabulary and a link table.
-- Om's decision for #1953: no second link table. One text[] column on
-- MEDICINE, a GIN index, and a vocabulary DERIVED from the prose itself.
--
-- Everything that decides is DATA:
--   use_extract_rule   — the prefixes stripped, the junk dropped, the extra
--                        delimiters split on. A new rule is one INSERT.
--   use_synonym        — obvious same-thing folds ('loose motion' → diarrhoea).
--   use_extract_config — the keep threshold, the batch size, the tick budget.
-- Changing any of them and re-planning rebuilds the catalogue with no deploy.
--
-- The work is a LEDGER, not one statement: use_condition_plan() writes the
-- batches, use_condition_tick() drains them inside a time budget, and the
-- cron task calls the tick. Every batch is idempotent and re-running a done
-- batch is a no-op, so a statement timeout on the 3.5 GB table costs one
-- batch, never the pass.

-- ── the column ────────────────────────────────────────────────────────────
alter table public."MEDICINE" add column if not exists condition text[];

comment on column public."MEDICINE".condition is
  'CMD #1953 — the display-cased conditions this product is used for, derived
   from MEDICINE.uses by use_condition_tick(). Read by the catalogue Use door
   with `condition @> array[key]`. Never hand-edited: a re-plan overwrites it.';

create index if not exists idx_medicine_condition_gin
  on public."MEDICINE" using gin (condition);

-- ── the rules, as rows ────────────────────────────────────────────────────
create table if not exists public.use_extract_rule (
  kind    text not null check (kind in ('split','strip','junk')),
  pattern text not null,
  ord     int  not null default 100,
  note    text,
  primary key (kind, pattern)
);

create table if not exists public.use_synonym (
  raw       text primary key,
  canonical text not null,
  note      text
);

create table if not exists public.use_extract_config (
  key   text primary key,
  value jsonb not null
);

insert into public.use_extract_config(key, value) values
  ('min_products', to_jsonb(20)),
  ('batch_rows',   to_jsonb(20000)),
  ('budget_ms',    to_jsonb(40000)),
  ('max_len',      to_jsonb(48)),
  ('min_len',      to_jsonb(3))
on conflict (key) do nothing;

-- Extra delimiters beyond newline / bullet / semicolon. ' and ' is here on
-- purpose: "Treatment of Pain relief and fever" is TWO conditions, and Sumo
-- has to appear under both.
insert into public.use_extract_rule(kind, pattern, ord, note) values
  ('split', E'[\n\r;|•·●▪]',        10, 'newline, bullet, semicolon, pipe'),
  ('split', '\s+and\s+',            20, 'Pain relief and fever -> two conditions'),
  ('split', '\s*,\s*',              30, 'comma lists'),
  ('strip', '^treatment\s+and\s+prevention\s+of\s+', 10, null),
  ('strip', '^symptomatic\s+treatment\s+of\s+',      15, null),
  ('strip', '^symptomatic\s+relief\s+of\s+',         16, null),
  ('strip', '^treatment\s+of\s+',   20, null),
  ('strip', '^prevention\s+of\s+',  30, null),
  ('strip', '^relief\s+of\s+',      40, null),
  ('strip', '^management\s+of\s+',  50, null),
  ('strip', '^prophylaxis\s+of\s+', 60, null),
  ('strip', '^used\s+(for|in)\s+',  70, null),
  ('strip', '^for\s+the\s+treatment\s+of\s+', 5, null),
  ('strip', '^(the|a|an|of|in|for)\s+', 90, 'leftover article after a strip'),
  ('junk',  '^product\s+form',      10, 'Product Form: Tablet'),
  ('junk',  '^[0-9\s.%/+-]*$',      20, 'numeric-only / punctuation-only'),
  ('junk',  '^(other|others|misc|miscellaneous|n\s*/?\s*a|nil|none|not\s+applicable)$', 30, null),
  ('junk',  '^(tablet|capsule|syrup|injection|cream|ointment|drop|drops|powder|gel|solution|suspension)$', 40, 'dosage form, not a condition')
on conflict (kind, pattern) do nothing;

insert into public.use_synonym(raw, canonical, note) values
  ('loose motion',        'diarrhoea', null),
  ('loose motions',       'diarrhoea', null),
  ('diarrhea',            'diarrhoea', null),
  ('high blood pressure', 'hypertension', null),
  ('raised blood pressure','hypertension', null),
  ('high bp',             'hypertension', null),
  ('type 2 diabetes mellitus','type 2 diabetes', null),
  ('diabetes mellitus',   'diabetes', null),
  ('diabetes mellitus type 2','type 2 diabetes', null),
  ('high cholesterol',    'high cholesterol', null),
  ('heart burn',          'heartburn', null),
  ('acid reflux',         'acidity', null),
  ('acidity and heartburn','acidity', null),
  ('bacterial infections','bacterial infection', null),
  ('fungal infections',   'fungal infection', null),
  ('viral infections',    'viral infection', null),
  ('joint pain',          'joint pain', null),
  ('body ache',           'body pain', null),
  ('body aches',          'body pain', null),
  ('pain relief',         'pain relief', null),
  ('painful periods',     'period pain', null),
  ('menstrual pain',      'period pain', null),
  ('dysmenorrhoea',       'period pain', null),
  ('dysmenorrhea',        'period pain', null),
  ('worm infestations',   'worm infection', null),
  ('worm infestation',    'worm infection', null),
  ('nutritional deficiency','nutritional deficiencies', null),
  ('vitamin deficiency',  'vitamin deficiencies', null),
  ('common cold',         'cold', null),
  ('running nose',        'runny nose', null),
  ('breathing problems',  'breathing problem', null),
  ('difficulty in breathing','breathing problem', null)
on conflict (raw) do nothing;

grant select on public.use_extract_rule, public.use_synonym, public.use_extract_config
  to authenticated, service_role;

-- ── the extractor ─────────────────────────────────────────────────────────
-- IMMUTABLE on purpose: the rules arrive as arrays from the caller, which
-- reads them ONCE per batch. A STABLE function that queried the rule table
-- per row would be 372,454 lookups a pass.
create or replace function public.use_phrases(
  p_uses  text,
  p_split text[],
  p_strip text[],
  p_junk  text[],
  p_min_len int default 3,
  p_max_len int default 48)
returns text[]
language plpgsql
immutable
set search_path to 'public'
as $fn$
declare
  v_src text; v_parts text[]; v_part text; v_out text[] := '{}'; v_rx text; v_prev text;
begin
  if nullif(btrim(coalesce(p_uses,'')),'') is null then return '{}'; end if;

  -- One string, every delimiter turned into the same one, then split once.
  v_src := lower(p_uses);
  foreach v_rx in array coalesce(p_split,'{}') loop
    v_src := regexp_replace(v_src, v_rx, E'\n', 'g');
  end loop;
  v_parts := string_to_array(v_src, E'\n');

  foreach v_part in array coalesce(v_parts,'{}') loop
    v_part := btrim(regexp_replace(v_part, '\s+', ' ', 'g'));
    v_part := btrim(v_part, ' .:-–—*()[]"''');
    -- Strip the leading prose until nothing more comes off ("Treatment of
    -- the fever" loses both the verb and the article).
    loop
      v_prev := v_part;
      foreach v_rx in array coalesce(p_strip,'{}') loop
        v_part := regexp_replace(v_part, v_rx, '');
      end loop;
      v_part := btrim(v_part, ' .:-–—*()[]"''');
      exit when v_part = v_prev;
    end loop;
    v_part := btrim(regexp_replace(v_part, '\s+', ' ', 'g'));

    if v_part = '' then continue; end if;
    if length(v_part) < p_min_len or length(v_part) > p_max_len then continue; end if;
    continue when exists (select 1 from unnest(coalesce(p_junk,'{}')) j where v_part ~ j);

    if not (v_out @> array[v_part]) then v_out := v_out || v_part; end if;
  end loop;

  return v_out;
end $fn$;

-- The printed form. Lower-cased body with one capital, because the source is
-- SHOUTING half the time and "Pain relief" is what the spec's example prints.
create or replace function public.use_display(p_phrase text)
returns text
language sql
immutable
set search_path to 'public'
as $fn$ select case when nullif(btrim(coalesce(p_phrase,'')),'') is null then null
                    else upper(left(btrim(p_phrase),1)) || substr(btrim(p_phrase),2) end $fn$;

-- ── the derived vocabulary ────────────────────────────────────────────────
create table if not exists public.use_vocab_stage (
  phrase text primary key,
  n      bigint not null default 0
);

create table if not exists public.use_vocab (
  phrase     text primary key,   -- the normalised phrase as extracted
  canonical  text,               -- the DISPLAY string it maps to; null = dropped
  n          bigint not null default 0,
  kept       boolean not null default false,
  updated_at timestamptz not null default now()
);
create index if not exists idx_use_vocab_canonical on public.use_vocab (canonical);

-- ── the ledger ────────────────────────────────────────────────────────────
create table if not exists public.use_backfill_batch (
  ord        int primary key,
  phase      text   not null check (phase in ('scan','decide','apply','facet')),
  lo         bigint,
  hi         bigint,
  state      text   not null default 'pending' check (state in ('pending','done')),
  rows_seen  bigint,
  ms         int,
  ran_at     timestamptz,
  last_error text
);
create index if not exists idx_use_backfill_pending on public.use_backfill_batch (state, ord);

create table if not exists public.use_backfill_state (
  id            boolean primary key default true check (id),
  planned_at    timestamptz,
  finished_at   timestamptz,
  last_note     text,
  phrases_kept  int,
  products_seen bigint
);
insert into public.use_backfill_state(id) values (true) on conflict do nothing;

-- ── plan ──────────────────────────────────────────────────────────────────
create or replace function public.use_condition_plan(p_mode text default 'full')
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_min bigint; v_max bigint; v_step bigint; v_ord int := 0; v_lo bigint;
begin
  v_step := greatest(coalesce((select (value)::text::bigint from public.use_extract_config
                                where key = 'batch_rows'), 20000), 1000);
  select min(id), max(id) into v_min, v_max from public."MEDICINE";
  delete from public.use_backfill_batch;
  if v_min is null then
    update public.use_backfill_state
       set planned_at = now(), finished_at = now(), last_note = 'no products'
     where id;
    return 0;
  end if;

  -- Pass 1: count every phrase in the catalogue.
  v_lo := v_min;
  while v_lo <= v_max loop
    v_ord := v_ord + 1;
    insert into public.use_backfill_batch(ord, phase, lo, hi)
      values (v_ord, 'scan', v_lo, least(v_lo + v_step - 1, v_max));
    v_lo := v_lo + v_step;
  end loop;

  -- Pass 2: decide the vocabulary once, from the counts.
  v_ord := v_ord + 1;
  insert into public.use_backfill_batch(ord, phase) values (v_ord, 'decide');

  -- Pass 3: write MEDICINE.condition.
  v_lo := v_min;
  while v_lo <= v_max loop
    v_ord := v_ord + 1;
    insert into public.use_backfill_batch(ord, phase, lo, hi)
      values (v_ord, 'apply', v_lo, least(v_lo + v_step - 1, v_max));
    v_lo := v_lo + v_step;
  end loop;

  -- Pass 4: hand the new column to the catalogue cache.
  v_ord := v_ord + 1;
  insert into public.use_backfill_batch(ord, phase) values (v_ord, 'facet');

  update public.use_backfill_state
     set planned_at = now(), finished_at = null,
         last_note = 'planned ' || v_ord || ' batches (' || coalesce(p_mode,'full') || ')'
   where id;
  return v_ord;
end $fn$;

-- ── decide ────────────────────────────────────────────────────────────────
-- Synonyms fold first, then plurals (only where the singular was actually
-- seen — "diabetes" must never become "diabete"), then the survivors are
-- counted and the rare ones are folded into the nearest KEPT phrase that
-- appears inside them as whole words. Anything left under the threshold with
-- nowhere to go is dropped.
create or replace function public.use_vocab_decide()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_min int; v_kept int; v_folded int; v_dropped int;
begin
  v_min := greatest(coalesce((select (value)::text::int from public.use_extract_config
                               where key = 'min_products'), 20), 1);

  create temp table _uv_map on commit drop as
  select s.phrase,
         coalesce(sy.canonical, s.phrase) as base,
         s.n
    from public.use_vocab_stage s
    left join public.use_synonym sy on sy.raw = s.phrase;

  -- plural → singular, only when the singular is itself a phrase we saw
  update _uv_map m
     set base = sub.singular
    from (
      select m2.phrase,
             case when m2.base ~ 'ies$' then left(m2.base, length(m2.base)-3) || 'y'
                  when m2.base ~ '[^s]s$' then left(m2.base, length(m2.base)-1)
             end as singular
        from _uv_map m2
    ) sub
   where sub.phrase = m.phrase
     and sub.singular is not null
     and exists (select 1 from _uv_map m3 where m3.base = sub.singular);

  create temp table _uv_tot on commit drop as
  select base, sum(n) as n from _uv_map group by base;

  create temp table _uv_keep on commit drop as
  select base, n from _uv_tot where n >= v_min;

  -- a rare phrase joins the biggest kept phrase that sits inside it as words
  create temp table _uv_fold on commit drop as
  select t.base,
         (select k.base from _uv_keep k
           where (' ' || t.base || ' ') like ('% ' || k.base || ' %')
           order by k.n desc, k.base limit 1) as into_base
    from _uv_tot t
   where t.n < v_min;

  delete from public.use_vocab;
  insert into public.use_vocab(phrase, canonical, n, kept, updated_at)
  select m.phrase,
         public.use_display(coalesce(k.base, f.into_base)),
         m.n,
         (k.base is not null),
         now()
    from _uv_map m
    left join _uv_keep k on k.base = m.base
    left join _uv_fold f on f.base = m.base;

  select count(*) into v_kept    from _uv_keep;
  select count(*) into v_folded  from _uv_fold where into_base is not null;
  select count(*) into v_dropped from _uv_fold where into_base is null;

  update public.use_backfill_state
     set phrases_kept = v_kept,
         last_note = 'vocabulary: ' || v_kept || ' kept, ' || v_folded
                     || ' folded, ' || v_dropped || ' dropped (min ' || v_min || ')'
   where id;

  return jsonb_build_object('ok', true, 'kept', v_kept, 'folded', v_folded,
                            'dropped', v_dropped, 'min_products', v_min);
end $fn$;

-- ── tick ──────────────────────────────────────────────────────────────────
create or replace function public.use_condition_tick(p_budget_ms integer default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  b record; v_t0 timestamptz := clock_timestamp(); v_started timestamptz := clock_timestamp();
  v_budget int; v_rows bigint; v_done int := 0; v_split text[]; v_strip text[]; v_junk text[];
  v_minl int; v_maxl int; v_last text := null; v_err text := null; z record;
begin
  v_budget := coalesce(p_budget_ms,
                (select (value)::text::int from public.use_extract_config where key = 'budget_ms'),
                40000);
  perform set_config('statement_timeout', '120000', true);

  select array_agg(pattern order by ord, pattern) into v_split
    from public.use_extract_rule where kind = 'split';
  select array_agg(pattern order by ord, pattern) into v_strip
    from public.use_extract_rule where kind = 'strip';
  select array_agg(pattern order by ord, pattern) into v_junk
    from public.use_extract_rule where kind = 'junk';
  v_minl := coalesce((select (value)::text::int from public.use_extract_config where key='min_len'), 3);
  v_maxl := coalesce((select (value)::text::int from public.use_extract_config where key='max_len'), 48);

  loop
    exit when (extract(epoch from clock_timestamp() - v_started) * 1000) > v_budget;

    select * into b from public.use_backfill_batch
     where state = 'pending' order by ord limit 1 for update skip locked;
    exit when b.ord is null;

    v_t0 := clock_timestamp(); v_rows := 0; v_err := null;
    begin
      if b.phase = 'scan' then
        -- The first scan batch clears the staging counts: one plan, one sweep.
        if b.ord = (select min(ord) from public.use_backfill_batch where phase = 'scan') then
          delete from public.use_vocab_stage;
        end if;
        insert into public.use_vocab_stage(phrase, n)
        select t.ph, count(distinct t.id)
          from (select m.id,
                       unnest(public.use_phrases(m.uses, v_split, v_strip, v_junk, v_minl, v_maxl)) as ph
                  from public."MEDICINE" m
                 where m.id between b.lo and b.hi) t
         group by t.ph
        on conflict (phrase) do update set n = public.use_vocab_stage.n + excluded.n;
        get diagnostics v_rows = row_count;

      elsif b.phase = 'decide' then
        perform public.use_vocab_decide();
        select count(*) into v_rows from public.use_vocab where kept;

      elsif b.phase = 'apply' then
        update public."MEDICINE" m
           set condition = x.arr
          from (
            select t.id, array_agg(distinct v.canonical order by v.canonical) as arr
              from (select m2.id,
                           unnest(public.use_phrases(m2.uses, v_split, v_strip, v_junk, v_minl, v_maxl)) as ph
                      from public."MEDICINE" m2
                     where m2.id between b.lo and b.hi) t
              join public.use_vocab v on v.phrase = t.ph and v.canonical is not null
             group by t.id
          ) x
         where m.id = x.id and m.condition is distinct from x.arr;
        get diagnostics v_rows = row_count;
        -- every other row in the range has no condition at all, and says so
        update public."MEDICINE" m
           set condition = '{}'::text[]
         where m.id between b.lo and b.hi
           and m.condition is null;

      elsif b.phase = 'facet' then
        -- The counts the doors print are the catalogue cache's job; this only
        -- asks for them. Re-queuing a unit that is already pending is a no-op.
        v_rows := 0;
        for z in select zz.id as zid, a.arg
                   from (select 0::smallint as id
                         union all
                         select id from public.zones
                          where is_active and not coalesce(is_synthetic, false)) zz
                   cross join (values ('condition'), ('meta')) a(arg)
                  order by zz.id, a.arg loop
          -- one row per insert: ord is the table's primary key and a single
          -- set-based insert would hand every row the same max(ord) + 1.
          insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg)
          select coalesce((select max(u.ord) from public.catalogue_refresh_unit u), 0) + 1,
                 'facet', z.zid, z.arg
           where not exists (select 1 from public.catalogue_refresh_unit u2
                              where u2.kind = 'facet' and u2.zone_id = z.zid
                                and u2.arg = z.arg and u2.state = 'pending');
          v_rows := v_rows + 1;
        end loop;
        update public.use_backfill_state set finished_at = now() where id;
      end if;
    exception when others then
      v_err := left(sqlerrm, 400);
    end;

    update public.use_backfill_batch
       set state = case when v_err is null then 'done' else 'pending' end,
           ran_at = now(), rows_seen = v_rows, last_error = v_err,
           ms = (extract(epoch from clock_timestamp() - v_t0) * 1000)::int
     where ord = b.ord;

    if v_err is not null then
      update public.use_backfill_state
         set last_note = 'batch ' || b.ord || ' (' || b.phase || ') failed: ' || v_err
       where id;
      return jsonb_build_object('ok', false, 'ord', b.ord, 'phase', b.phase, 'error', v_err);
    end if;

    v_done := v_done + 1;
    v_last := b.phase || ' ' || b.ord;
    update public.use_backfill_state
       set last_note = v_last || ' → ' || v_rows || ' rows'
     where id;
  end loop;

  return jsonb_build_object('ok', true, 'batches', v_done, 'last', v_last,
    'left', (select count(*) from public.use_backfill_batch where state = 'pending'));
end $fn$;

-- ── what the ledger looks like, in one read ───────────────────────────────
create or replace function public.use_condition_status()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select jsonb_build_object(
    'ok', true,
    'planned_at',  (select planned_at  from public.use_backfill_state where id),
    'finished_at', (select finished_at from public.use_backfill_state where id),
    'note',        (select last_note   from public.use_backfill_state where id),
    'batches_left',(select count(*) from public.use_backfill_batch where state='pending'),
    'batches_total',(select count(*) from public.use_backfill_batch),
    'phrases_seen',(select count(*) from public.use_vocab_stage),
    'conditions',  (select count(distinct canonical) from public.use_vocab where canonical is not null),
    'products',    (select count(*) from public.catalogue_facet_count where facet='condition' and zone_id=0));
$fn$;

revoke all on function public.use_condition_plan(text)    from public, anon, authenticated;
revoke all on function public.use_condition_tick(integer) from public, anon, authenticated;
revoke all on function public.use_vocab_decide()          from public, anon, authenticated;
revoke all on function public.use_condition_status()      from public, anon;
grant execute on function public.use_condition_status()   to authenticated, service_role;
grant execute on function public.use_condition_plan(text), public.use_condition_tick(integer),
                          public.use_vocab_decide() to service_role;

-- ── the cron ──────────────────────────────────────────────────────────────
insert into public.cron_task (name, ord, mode, gate_sql, work_sql, base_interval_s,
                              enabled, dml, note)
values
  ('use_condition_backfill', 46, 'poll',
   $g$select exists (select 1 from public.use_backfill_batch where state = 'pending')$g$,
   $w$select public.use_condition_tick()$w$,
   60, true, true,
   'CMD #1953 — drains the MEDICINE.condition ledger one bounded batch at a time. Gated: nothing pending, no work.'),
  ('use_condition_plan_nightly', 47, 'poll',
   null,
   $w$select public.use_condition_plan('full')$w$,
   86400, true, true,
   'CMD #1953 — re-derives the use vocabulary from MEDICINE.uses nightly, so an edited rule or a new product reaches the Use door without a deploy.')
on conflict (name) do update set
  gate_sql = excluded.gate_sql, work_sql = excluded.work_sql,
  base_interval_s = excluded.base_interval_s, mode = excluded.mode,
  note = excluded.note, enabled = excluded.enabled, dml = excluded.dml;

update public.cron_task
   set night_only = true, run_at_ist = time '01:05'
 where name = 'use_condition_plan_nightly';

-- The first pass is planned by the migration itself: the column exists the
-- moment this file replays, and the cron fills it from the next tick.
select public.use_condition_plan('full');

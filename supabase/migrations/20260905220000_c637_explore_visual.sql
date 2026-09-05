-- CHANGE #637 — Exploratory LLM tester + visual regression, part 4 of the
-- self-testing bot. It catches what an assertion cannot.
--
-- #634 gave the platform a bot that can drive the real app as a real role and
-- record what happened. An assertion, though, only ever answers the question it
-- was written to ask: `expect_render(boot_status=painted)` is perfectly happy
-- with a card showing "₹0.00" as if it were a price, five stacked buttons on
-- one row, a heading that contradicts the number beside it, or a screen with no
-- way out. Two lanes land here, and they share every pipe #634 already built —
-- test_runs / test_results / feature_gaps — because a second reporting stack is
-- how a finding stops being read.
--
--   • EXPLORE. An agent is handed a feature's own spec (its registry row and
--     its contract) plus screenshots of the screen it drove, and judges whether
--     the screen does what the spec says. Its answers are OPINIONS: they never
--     fail a build and they are never auto-approved. They land as feature_gaps
--     rows typed opportunity/partial, carrying the screenshot and the exact
--     spec line they contradict, for Om to accept or reject.
--   • VISUAL. Every registered screen is photographed per role at a phone and
--     a desktop width and compared with an APPROVED baseline. A deliberate
--     redesign is re-baselined in one tap instead of screaming forever.
--
-- The measurements come from the VM (it holds the pixels); every verdict, every
-- threshold and every word comes from here. A node script that decided what
-- "broken" means would be a second product with its own opinions.
--
-- Idempotent throughout: the merge worker replays this file on live once.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. RUN KINDS — and the reason the coverage ledger must know about them
-- ─────────────────────────────────────────────────────────────────────────
-- test_coverage_refresh() reads EVERY test_results row. Left alone, a visual
-- lane that reports "this screen changed" would mark the FEATURE as failing in
-- the ledger Om watches, while its functional test is green — a number that
-- lies is worse than no number. So a run kind now declares whether it counts.
create table if not exists public.test_run_kind (
  kind            text primary key,
  label           text    not null,
  lane            text    not null default 'functional',  -- functional | explore | visual
  counts_coverage boolean not null default true,
  sort_order      int     not null default 0
);

insert into public.test_run_kind (kind, label, lane, counts_coverage, sort_order) values
  ('preview',    'Preview',           'functional', true,  10),
  ('prod_smoke', 'Production smoke',  'functional', true,  20),
  ('full',       'Full run',          'functional', true,  30),
  ('local',      'Local',             'functional', true,  40),
  ('explore',    'Exploratory',       'explore',    false, 50),
  ('visual',     'Visual regression', 'visual',     false, 60)
on conflict (kind) do update
   set label = excluded.label, lane = excluded.lane,
       counts_coverage = excluded.counts_coverage,
       sort_order = excluded.sort_order;

-- Rebuilt with ONE change: results are scoped to run kinds that count. A kind
-- nobody registered still counts (left join + coalesce), so this can never
-- silently drop a lane somebody adds later without reading this file.
create or replace function public.test_coverage_refresh()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_n int;
begin
  insert into public.test_coverage (feature_key, has_contract, automatable, skip_reason, updated_at)
  select f.feature_key, f.has_test_contract, f.test_automatable, f.test_skip_reason, now()
    from public.feature_registry f
   where f.is_active
  on conflict (feature_key) do update
     set has_contract = excluded.has_contract,
         automatable  = excluded.automatable,
         skip_reason  = excluded.skip_reason,
         updated_at   = now();

  with counted as (
    select r.*
      from public.test_results r
      join public.test_runs      tr on tr.id = r.run_id
      left join public.test_run_kind k on k.kind = tr.kind
     where coalesce(k.counts_coverage, true)
  ), last as (
    select distinct on (r.feature_key)
           r.feature_key, r.run_id, r.verdict, r.created_at
      from counted r
     order by r.feature_key, r.created_at desc
  ), green as (
    select r.feature_key, max(r.created_at) as at
      from counted r where r.verdict = 'passed'
     group by r.feature_key
  ), win as (
    select r.feature_key,
           count(*)                                   as runs,
           count(*) filter (where r.verdict='failed') as fails
      from counted r
     where r.created_at > now() - interval '30 days'
     group by r.feature_key
  )
  update public.test_coverage c
     set last_run_id   = l.run_id,
         last_run_at   = l.created_at,
         last_verdict  = l.verdict,
         last_green_at = g.at,
         runs_30d      = coalesce(w.runs, 0),
         fails_30d     = coalesce(w.fails, 0),
         flake_pct     = case when coalesce(w.runs,0) = 0 then 0
                              else round(100.0 * coalesce(w.fails,0) / w.runs, 1) end,
         never_tested  = (l.feature_key is null),
         updated_at    = now()
    from public.test_coverage c2
    left join last  l on l.feature_key = c2.feature_key
    left join green g on g.feature_key = c2.feature_key
    left join win   w on w.feature_key = c2.feature_key
   where c.feature_key = c2.feature_key;

  select count(*) into v_n from public.test_coverage;
  return jsonb_build_object('ok', true, 'features', v_n);
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. THE FINDING CARRIES ITS PROOF — feature_gaps grows four facts
-- ─────────────────────────────────────────────────────────────────────────
-- An opinion with no evidence is an argument. `spec_line` is the sentence the
-- screen contradicted, quoted from the feature's own registry row; the artifact
-- is the screenshot it was seen in. Both are printed beside the finding on the
-- Feature gaps screen Om already reads, which is why no second screen is being
-- built for the bot's output.
alter table public.feature_gaps
  add column if not exists source          text not null default 'human',
  add column if not exists feature_key     text,
  add column if not exists role            text,
  add column if not exists run_id          bigint,
  add column if not exists spec_line       text,
  add column if not exists artifact_bucket text,
  add column if not exists artifact_path   text,
  add column if not exists confidence      text;

comment on column public.feature_gaps.source is
  'CHANGE #637 — who filed it: human | journey | explore | visual.';
comment on column public.feature_gaps.spec_line is
  'CHANGE #637 — the exact spec sentence the finding contradicts, quoted verbatim.';
comment on column public.feature_gaps.artifact_path is
  'CHANGE #637 — object path inside artifact_bucket for the screenshot the finding was seen in.';

create index if not exists feature_gaps_source_idx  on public.feature_gaps (source, status, found_at desc);
create index if not exists feature_gaps_run_idx     on public.feature_gaps (run_id);
create index if not exists feature_gaps_feature_idx on public.feature_gaps (feature_key);

-- ─────────────────────────────────────────────────────────────────────────
-- 3. THE ARTIFACT STORE — private, admin-readable, bot-written
-- ─────────────────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public)
select 'test-artifacts', 'test-artifacts', false
where not exists (select 1 from storage.buckets where id = 'test-artifacts');

drop policy if exists test_artifacts_read on storage.objects;
create policy test_artifacts_read on storage.objects
  for select to authenticated
  using (bucket_id = 'test-artifacts'
         and public.get_my_role() in ('admin','super_admin'));

drop policy if exists test_artifacts_write on storage.objects;
create policy test_artifacts_write on storage.objects
  for insert to authenticated
  with check (bucket_id = 'test-artifacts'
              and public.get_my_role() in ('admin','super_admin'));

-- ─────────────────────────────────────────────────────────────────────────
-- 4. VISUAL REGRESSION — viewports, rules, baselines, shots
-- ─────────────────────────────────────────────────────────────────────────
-- The widths are DATA. "Phone and desktop" is today's answer; a tablet column
-- is one INSERT, never a deploy.
create table if not exists public.visual_viewport (
  key        text primary key,
  label      text not null,
  width      int  not null,
  height     int  not null,
  sort_order int  not null default 0,
  is_active  boolean not null default true
);

insert into public.visual_viewport (key, label, width, height, sort_order) values
  ('phone',   'Phone',   390,  844, 10),
  ('desktop', 'Desktop', 1440, 900, 20)
on conflict (key) do update
   set label = excluded.label, width = excluded.width,
       height = excluded.height, sort_order = excluded.sort_order;

-- What "broken" means, as thresholds rather than as node code. The VM reports
-- four measurements per screenshot — how much of it differs from the baseline,
-- how much of it is one flat colour, how much ink sits on the bottom edge, and
-- whether it rendered at all. Which of those is a finding, at what number, in
-- which words, is decided HERE.
create table if not exists public.visual_rule (
  key          text primary key,
  metric       text    not null,           -- diff_pct | blank_pct | edge_ink_pct | render
  op           text    not null default '>=',
  threshold    numeric not null default 0,
  verdict      text    not null,           -- changed | broken | match | new
  label        text    not null,
  message      text    not null,           -- the sentence printed on the finding
  tone         text    not null default 'warning',
  gap_type     text,                       -- null = record it, do not file a gap
  gap_severity text    not null default 'medium',
  sort_order   int     not null default 0,
  is_active    boolean not null default true
);

insert into public.visual_rule
  (key, metric, op, threshold, verdict, label, message, tone, gap_type, gap_severity, sort_order) values
  ('render_failed','render','=',0,'broken','Did not render',
   'The screen never reported a painted frame at this width, so nothing could be compared.',
   'danger','broken','high',10),
  ('blank','blank_pct','>=',97,'broken','Blank screen',
   'Almost the whole screen is one flat colour at this width — a blank tile, not a layout.',
   'danger','broken','high',20),
  ('edge_cut','edge_ink_pct','>=',35,'broken','Content cut off',
   'Content runs into the bottom edge at this width, so a row is being cut off rather than laid out.',
   'danger','partial','medium',30),
  ('changed','diff_pct','>=',2,'changed','Changed',
   'This screen no longer matches its approved baseline at this width.',
   'warning','partial','medium',40),
  ('match','diff_pct','>=',0,'match','Matches baseline',
   'This screen matches its approved baseline.',
   'success',null,'low',50)
on conflict (key) do update
   set metric = excluded.metric, op = excluded.op, threshold = excluded.threshold,
       verdict = excluded.verdict, label = excluded.label, message = excluded.message,
       tone = excluded.tone, gap_type = excluded.gap_type,
       gap_severity = excluded.gap_severity, sort_order = excluded.sort_order;

-- The approved picture. One per feature × role × viewport, and it only ever
-- changes because a human tapped Approve.
create table if not exists public.visual_baseline (
  id               bigserial primary key,
  feature_key      text        not null,
  role             text        not null default '',
  viewport         text        not null,
  bucket           text        not null default 'test-artifacts',
  path             text        not null,
  fingerprint      text        not null default '',
  width            int,
  height           int,
  from_run_id      bigint,
  from_shot_id     bigint,
  approved_by      uuid,
  approved_by_label text       not null default '',
  approved_at      timestamptz not null default now(),
  note             text
);
create unique index if not exists visual_baseline_key_idx
  on public.visual_baseline (feature_key, role, viewport);

-- One photograph, its measurements and the verdict THIS file decided.
create table if not exists public.visual_shot (
  id            bigserial primary key,
  run_id        bigint      not null references public.test_runs(id) on delete cascade,
  feature_key   text        not null,
  role          text        not null default '',
  viewport      text        not null,
  bucket        text        not null default 'test-artifacts',
  path          text        not null,
  diff_path     text,
  fingerprint   text        not null default '',
  width         int,
  height        int,
  diff_pct      numeric     not null default 0,
  blank_pct     numeric     not null default 0,
  edge_ink_pct  numeric     not null default 0,
  rendered      boolean     not null default true,
  baseline_id   bigint      references public.visual_baseline(id) on delete set null,
  rule_key      text,
  verdict       text        not null default 'new',
  detail        text,
  reviewed      boolean     not null default false,
  gap_id        bigint,
  created_at    timestamptz not null default now()
);
create unique index if not exists visual_shot_unique_idx
  on public.visual_shot (run_id, feature_key, role, viewport);
create index if not exists visual_shot_review_idx
  on public.visual_shot (reviewed, verdict, created_at desc);

alter table public.visual_viewport enable row level security;
alter table public.visual_rule     enable row level security;
alter table public.visual_baseline enable row level security;
alter table public.visual_shot     enable row level security;
alter table public.test_run_kind   enable row level security;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. THE EXPLORATORY AGENT'S BRIEF — every word of it lives here
-- ─────────────────────────────────────────────────────────────────────────
-- The agent is handed a brief, a step budget and an action vocabulary, all of
-- them rows. A prompt written into the node script would be a product decision
-- living on a VM, invisible to everyone and un-editable without a deploy.
create table if not exists public.explore_prompt (
  key        text primary key,
  body       text not null,
  note       text,
  updated_at timestamptz not null default now()
);

insert into public.explore_prompt (key, body, note) values
('brief',
$brief$You are testing a live pharmacy B2B web app (mediBO, India, all money in INR).
You are looking at REAL screenshots of ONE screen, taken in order while a real signed-in
{role} used it. Judge ONE thing: does this screen do what its own specification says?

SPECIFICATION
{spec}

WHAT THE SCREEN DID
{trace}

Report only what you can SEE in the screenshots. Never guess at what is off-screen,
never assume a button works, and never invent a number. Say nothing about styling
preferences; report only things that would mislead, block or embarrass a real user:
 - a value rendered as if it were real data when it is empty or zero (a "₹0.00" price,
   a "-" where an amount belongs, a placeholder shown as a fact)
 - a label that contradicts the value beside it
 - copy that lies about state ("Delivered" on an order that is still packing)
 - a dead end: a screen with no visible way to continue or go back
 - crowding that breaks the screen: buttons stacked on one card, text overlapping,
   a row cut in half, a tile that never filled in
 - anything the specification promises that is plainly absent from the screen

Answer with JSON ONLY, no prose, no markdown fence:
{"verdict":"matches_spec|contradicts_spec|unclear","summary":"one sentence",
 "findings":[{"title":"short title","type":"partial|opportunity","severity":"critical|high|medium|low",
 "evidence":"what you can see, quoted from the screenshot","spec_line":"the exact sentence from the SPECIFICATION this contradicts, copied verbatim, or empty",
 "suggestion":"one sentence","shot":"the screenshot filename this was seen in","confidence":"high|medium|low"}]}
An empty findings array is a perfectly good answer. Report nothing you are not sure you can see.$brief$,
 'The judging brief. {role} {spec} {trace} are substituted by test_explore_manifest().'),
('spec_header',
$spec$Feature: {label} ({feature_key})
Where it lives: {group_label}
What it is for: {description}
Entry point: {entry}
Roles that should reach it: {roles}
The declared happy path: {steps}
The declared end state: {expect}$spec$,
 'How a registry row is turned into the spec the agent is held to.')
on conflict (key) do update set body = excluded.body, note = excluded.note, updated_at = now();

alter table public.explore_prompt enable row level security;

-- What the agent is allowed to do, and how far it may go. Config, not code.
create table if not exists public.explore_config (
  id             int primary key default 1,
  max_steps      int     not null default 6,
  max_shots      int     not null default 5,
  viewport       text    not null default 'phone',
  model_note     text    not null default 'gemini-3.5-flash via the gemini-ocr edge function (Vertex, global, GCP_SA_KEY)',
  min_confidence text    not null default 'low',
  is_active      boolean not null default true,
  constraint explore_config_one_row check (id = 1)
);
insert into public.explore_config (id) values (1) on conflict (id) do nothing;
alter table public.explore_config enable row level security;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. COPY — every word the two new surfaces print
-- ─────────────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('visual.title',            to_jsonb('Visual baselines'::text)),
  ('visual.subtitle',         to_jsonb('Every registered screen, per role, at a phone and a desktop width'::text)),
  ('visual.headline_label',   to_jsonb('Awaiting review'::text)),
  ('visual.headline_none',    to_jsonb('Every screenshot in the last run matches its approved baseline.'::text)),
  ('visual.headline_some',    to_jsonb('{n} screenshot(s) differ from an approved baseline or have none yet.'::text)),
  ('visual.filter_review',    to_jsonb('Needs review'::text)),
  ('visual.filter_changed',   to_jsonb('Changed'::text)),
  ('visual.filter_broken',    to_jsonb('Broken'::text)),
  ('visual.filter_new',       to_jsonb('No baseline'::text)),
  ('visual.filter_all',       to_jsonb('All'::text)),
  ('visual.empty',            to_jsonb('Nothing matches this filter.'::text)),
  ('visual.approve',          to_jsonb('Approve as baseline'::text)),
  ('visual.approve_all',      to_jsonb('Approve every shot in this run'::text)),
  ('visual.approved_toast',   to_jsonb('Baseline approved.'::text)),
  ('visual.approved_all_toast', to_jsonb('{n} baseline(s) approved.'::text)),
  ('visual.run_now',          to_jsonb('Run the visual pass'::text)),
  ('visual.run_queued',       to_jsonb('Queued — the VM picks it up on its next pass.'::text)),
  ('visual.current_label',    to_jsonb('This run'::text)),
  ('visual.baseline_label',   to_jsonb('Approved baseline'::text)),
  ('visual.diff_label',       to_jsonb('What changed'::text)),
  ('visual.no_baseline',      to_jsonb('No approved baseline yet'::text)),
  ('visual.diff_pct',         to_jsonb('{pct}% of the picture differs'::text)),
  ('visual.runs_title',       to_jsonb('Recent visual runs'::text)),
  ('visual.runs_none',        to_jsonb('The visual lane has not run yet.'::text)),
  ('visual.nav_label',        to_jsonb('Visual baselines'::text)),
  ('visual.reviewed_label',   to_jsonb('Reviewed'::text)),
  ('visual.approved_at',      to_jsonb('approved {when}'::text)),
  ('visual.not_authorized',   to_jsonb('Visual baselines are super-admin only.'::text))
on conflict (key) do nothing;

-- The Feature gaps screen grows one dimension: WHO filed the finding.
insert into public.feature_gap_label (key, label, tone, sort_order) values
  ('source.human',   'Filed by hand', 'neutral', 10),
  ('source.journey', 'Journey audit', 'info',    20),
  ('source.explore', 'Exploratory bot', 'warning', 30),
  ('source.visual',  'Visual regression', 'warning', 40),
  ('ui.filter_source', 'Source',      null,      50),
  ('ui.field_spec_line', 'Contradicts', null,    60),
  ('ui.field_shot',  'Seen in',        null,     70),
  ('ui.field_confidence', 'Confidence', null,    80)
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 7. WHOSE SURFACE IS THIS? — a lookup, not a guess
-- ─────────────────────────────────────────────────────────────────────────
-- feature_gaps.surface is one of six words (customer/admin/supplier/delivery/
-- partner/platform); feature_registry.surface is a NAV surface
-- (dashboard/customer_shop/fulfill_tab/…) and the two vocabularies do not
-- overlap at all. Filing every bot finding as 'platform' would put the whole
-- lane behind the one filter Om never opens, so the answer is a MAP: the role
-- the finding was actually seen by first, then the feature key's own prefix.
-- The key is (kind, key), not key: 'admin' is BOTH a role and a feature-key
-- prefix, and a single-column key silently swallowed the second one — which is
-- how every admin finding was landing on 'platform'.
do $c637_map$
begin
  if exists (select 1 from information_schema.tables
              where table_schema = 'public' and table_name = 'gap_surface_map')
     and not exists (select 1 from pg_constraint c
                      where c.conrelid = 'public.gap_surface_map'::regclass
                        and c.contype = 'p' and array_length(c.conkey, 1) = 2)
  then
    drop table public.gap_surface_map;   -- this migration's own seed table, one shape old
  end if;
end
$c637_map$;

create table if not exists public.gap_surface_map (
  key        text not null,      -- a role name, or a feature_key prefix
  kind       text not null,      -- role | prefix
  surface    text not null,
  sort_order int  not null default 0,
  primary key (kind, key)
);

insert into public.gap_surface_map (key, kind, surface, sort_order) values
  ('customer','role','customer',10),
  ('supplier','role','supplier',20),
  ('admin','role','admin',30),
  ('super_admin','role','admin',40),
  ('delivery','role','delivery',50),
  ('rider','role','delivery',60),
  ('partner','role','partner',70),
  ('cust','prefix','customer',110),
  ('shop','prefix','customer',120),
  ('admin','prefix','admin',130),
  ('devtool','prefix','admin',140),
  ('fulfill','prefix','admin',150),
  ('partner','prefix','partner',160),
  ('supplier','prefix','supplier',170),
  ('pharmacy','prefix','admin',180)
on conflict (kind, key) do nothing;

alter table public.gap_surface_map enable row level security;

create or replace function public.gap_surface_for(p_feature text, p_role text)
returns text
language sql stable security definer set search_path to 'public'
as $$
  select coalesce(
    (select m.surface from public.gap_surface_map m
      where m.kind = 'role' and m.key = coalesce(nullif(btrim(p_role),''),'~none~')),
    (select m.surface from public.gap_surface_map m
      where m.kind = 'prefix' and m.key = split_part(coalesce(p_feature,''), '.', 1)),
    'platform');
$$;
grant execute on function public.gap_surface_for(text,text) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 8. THE EXPLORATORY LANE
-- ─────────────────────────────────────────────────────────────────────────
-- One feature's spec, as the agent will be held to it. Composed HERE from the
-- registry row, so "the spec" is the same sentence the app's own registry
-- carries — not a paraphrase somebody typed into a test.
create or replace function public.explore_spec_text(p_feature text)
returns text
language sql stable security definer set search_path to 'public'
as $$
  select replace(replace(replace(replace(replace(replace(replace(replace(
           (select body from public.explore_prompt where key = 'spec_header'),
           '{label}',       coalesce(f.label,'')),
           '{feature_key}', f.feature_key),
           '{group_label}', coalesce(nullif(btrim(f.group_label),''),'(ungrouped)')),
           '{description}', coalesce(nullif(btrim(f.description),''),'(the registry row carries no description)')),
           '{entry}',       coalesce(f.test_entry,'')),
           '{roles}',       coalesce(array_to_string(f.test_roles, ', '),'')),
           '{steps}',       coalesce(f.test_steps::text,'[]')),
           '{expect}',      coalesce(f.test_expect::text,'{}'))
    from public.feature_registry f
   where f.feature_key = p_feature;
$$;
grant execute on function public.explore_spec_text(text) to authenticated, service_role;

-- What to explore, and with whom. Same manifest shape #634 already speaks, so
-- the VM script reuses the harness rather than growing a second driver.
create or replace function public.test_explore_manifest(
  p_feature text default null,
  p_role    text default null,
  p_limit   int  default 0)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_rows jsonb; v_cfg public.explore_config;
begin
  perform public._dev_guard();
  select * into v_cfg from public.explore_config where id = 1;

  with f as (
    select fr.*
      from public.feature_registry fr
     where fr.is_active
       and fr.test_automatable
       and fr.has_test_contract
       and coalesce(nullif(btrim(fr.test_entry),''), '') <> ''
       and (p_feature is null or fr.feature_key = p_feature)
     order by fr.sort_order, fr.feature_key
  ), fr as (
    select f.feature_key, f.label, f.test_entry, f.test_steps, f.test_expect,
           r.role
      from f
      cross join lateral unnest(coalesce(f.test_roles, array[]::text[])) as r(role)
     where (p_role is null or r.role = p_role)
     limit case when coalesce(p_limit,0) > 0 then p_limit else 100000 end
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'feature_key', fr.feature_key,
           'label',       fr.label,
           'role',        fr.role,
           'entry',       fr.test_entry,
           'steps',       fr.test_steps,
           'expect',      fr.test_expect,
           'spec',        public.explore_spec_text(fr.feature_key)) ), '[]'::jsonb)
    into v_rows from fr;

  return jsonb_build_object(
    'ok', true,
    'features', v_rows,
    'max_steps', coalesce(v_cfg.max_steps, 6),
    'max_shots', coalesce(v_cfg.max_shots, 5),
    'viewport',  (select jsonb_build_object('key',key,'label',label,'width',width,'height',height)
                    from public.visual_viewport
                   where key = coalesce(v_cfg.viewport,'phone')),
    'is_active', coalesce(v_cfg.is_active, true),
    'model_note', coalesce(v_cfg.model_note,''));
end $$;
grant execute on function public.test_explore_manifest(text,text,int) to authenticated, service_role;

-- The brief, rendered. The VM posts exactly this text with the screenshots and
-- never writes a sentence of its own.
create or replace function public.test_explore_brief(
  p_feature text,
  p_role    text,
  p_trace   text default '')
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_body text;
begin
  perform public._dev_guard();
  select body into v_body from public.explore_prompt where key = 'brief';
  if v_body is null then
    return jsonb_build_object('ok', false, 'error', 'no_brief');
  end if;
  v_body := replace(v_body, '{role}',  coalesce(nullif(p_role,''),'user'));
  v_body := replace(v_body, '{spec}',  coalesce(public.explore_spec_text(p_feature),''));
  v_body := replace(v_body, '{trace}', coalesce(nullif(p_trace,''),'(no trace was recorded)'));
  return jsonb_build_object('ok', true, 'prompt', v_body,
                            'feature_key', p_feature, 'role', p_role);
end $$;
grant execute on function public.test_explore_brief(text,text,text) to authenticated, service_role;

-- The agent's answer, recorded. Two things happen and they are deliberately
-- different: the RESULT row says the lane ran, and each FINDING becomes a
-- feature_gaps row that is open, typed as an opinion, and approved by nobody.
create or replace function public.test_explore_report(
  p_run_id   bigint,
  p_feature  text,
  p_role     text default '',
  p_verdict  text default 'unclear',
  p_summary  text default '',
  p_findings jsonb default '[]'::jsonb,
  p_steps    jsonb default '[]'::jsonb,
  p_artifacts jsonb default '{}'::jsonb,
  p_duration_ms int default 0)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_run public.test_runs;
  v_surface text;
  v_gap_ids bigint[] := array[]::bigint[];
  v_id bigint;
  v_item jsonb;
  v_type text; v_sev text; v_shot text; v_bucket text;
  v_verdict text;
  v_n int := 0;
begin
  perform public._dev_guard();
  select * into v_run from public.test_runs where id = p_run_id;
  if v_run.id is null then
    return jsonb_build_object('ok', false, 'error', 'no_such_run');
  end if;

  -- An OPINION never fails a run. The exploratory lane reports that it looked
  -- (passed) or that it could not look (blocked); only a driver failure is a
  -- failure. This is why explore runs are excluded from the coverage ledger.
  v_verdict := case when p_verdict = 'blocked' then 'blocked'
                    when p_verdict = 'error'   then 'failed'
                    else 'passed' end;

  insert into public.test_results (run_id, feature_key, role, scenario, verdict,
                                   duration_ms, steps, artifacts, error)
  values (p_run_id, p_feature, coalesce(p_role,''), 'explore', v_verdict,
          coalesce(p_duration_ms,0), coalesce(p_steps,'[]'::jsonb),
          coalesce(p_artifacts,'{}'::jsonb),
          nullif(p_summary,''))
  on conflict (run_id, feature_key, role, scenario) do update
     set verdict = excluded.verdict, duration_ms = excluded.duration_ms,
         steps = excluded.steps, artifacts = excluded.artifacts,
         error = excluded.error;

  v_surface := public.gap_surface_for(p_feature, p_role);

  v_bucket := coalesce(p_artifacts->>'bucket', 'test-artifacts');

  for v_item in select * from jsonb_array_elements(coalesce(p_findings,'[]'::jsonb))
  loop
    -- The type is CLAMPED to the two kinds an opinion may be. The agent cannot
    -- file a 'broken' — that word belongs to something that was measured.
    v_type := case when coalesce(v_item->>'type','') = 'opportunity'
                   then 'opportunity' else 'partial' end;
    v_sev  := case when coalesce(v_item->>'severity','') in ('critical','high','medium','low')
                   then v_item->>'severity' else 'medium' end;
    v_shot := nullif(v_item->>'shot','');

    insert into public.feature_gaps
      (surface, journey_step, title, type, severity, evidence, suggestion,
       effort_guess, status, notes, source, feature_key, role, run_id,
       spec_line, artifact_bucket, artifact_path, confidence)
    values
      (v_surface,
       coalesce(nullif(p_role,''),'') ,
       left(coalesce(nullif(v_item->>'title',''), 'Exploratory finding'), 200),
       v_type, v_sev,
       nullif(v_item->>'evidence',''),
       nullif(v_item->>'suggestion',''),
       null, 'open',
       nullif(p_summary,''),
       'explore', p_feature, coalesce(p_role,''), p_run_id,
       nullif(v_item->>'spec_line',''),
       case when v_shot is not null then v_bucket else null end,
       case when v_shot is not null
            then coalesce(p_artifacts->>'prefix','') || v_shot else null end,
       nullif(v_item->>'confidence',''))
    returning id into v_id;
    v_gap_ids := v_gap_ids || v_id;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'run_id', p_run_id, 'verdict', v_verdict,
                            'gaps', v_n, 'gap_ids', to_jsonb(v_gap_ids));
end $$;
grant execute on function public.test_explore_report(bigint,text,text,text,text,jsonb,jsonb,jsonb,int) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 9. THE VISUAL LANE
-- ─────────────────────────────────────────────────────────────────────────
-- Every registered screen × every role that should reach it × every active
-- width, with the approved baseline attached so the VM can skip re-downloading
-- one it already holds.
create or replace function public.visual_manifest(
  p_feature text default null,
  p_role    text default null,
  p_limit   int  default 0)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_rows jsonb; v_vp jsonb;
begin
  perform public._dev_guard();

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', key, 'label', label, 'width', width, 'height', height)
           order by sort_order), '[]'::jsonb)
    into v_vp from public.visual_viewport where is_active;

  with f as (
    select fr.feature_key, fr.label, fr.test_entry, fr.test_steps, fr.test_roles,
           fr.sort_order
      from public.feature_registry fr
     where fr.is_active
       and fr.test_automatable
       and coalesce(nullif(btrim(fr.test_entry),''),'') <> ''
       and (p_feature is null or fr.feature_key = p_feature)
  ), fr as (
    select f.feature_key, f.label, f.test_entry, f.test_steps, r.role, f.sort_order
      from f cross join lateral unnest(coalesce(f.test_roles, array[]::text[])) as r(role)
     where (p_role is null or r.role = p_role)
     order by f.sort_order, f.feature_key, r.role
     limit case when coalesce(p_limit,0) > 0 then p_limit else 100000 end
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'feature_key', fr.feature_key,
           'label',       fr.label,
           'role',        fr.role,
           'entry',       fr.test_entry,
           'steps',       fr.test_steps,
           'baselines',   (select coalesce(jsonb_object_agg(b.viewport, jsonb_build_object(
                                    'id', b.id, 'bucket', b.bucket, 'path', b.path,
                                    'fingerprint', b.fingerprint,
                                    'width', b.width, 'height', b.height)), '{}'::jsonb)
                             from public.visual_baseline b
                            where b.feature_key = fr.feature_key and b.role = fr.role))), '[]'::jsonb)
    into v_rows from fr;

  return jsonb_build_object('ok', true, 'screens', v_rows, 'viewports', v_vp,
                            'bucket', 'test-artifacts');
end $$;
grant execute on function public.visual_manifest(text,text,int) to authenticated, service_role;

-- The VM measured; this decides. First active rule whose metric passes its
-- threshold wins, in sort order, so "broken" always outranks "changed" and a
-- screen with no baseline is NEW rather than a failure nobody can act on.
create or replace function public.visual_rule_for(
  p_rendered boolean, p_has_baseline boolean,
  p_diff_pct numeric, p_blank_pct numeric, p_edge_ink_pct numeric)
returns public.visual_rule
language plpgsql stable security definer set search_path to 'public'
as $$
declare r public.visual_rule; v numeric;
begin
  for r in select * from public.visual_rule where is_active order by sort_order, key
  loop
    if r.metric = 'render' then
      if not coalesce(p_rendered, true) then return r; end if;
      continue;
    end if;
    -- A diff rule needs something to diff against.
    if r.metric = 'diff_pct' and not coalesce(p_has_baseline, false) then
      continue;
    end if;
    v := case r.metric
           when 'diff_pct'     then coalesce(p_diff_pct, 0)
           when 'blank_pct'    then coalesce(p_blank_pct, 0)
           when 'edge_ink_pct' then coalesce(p_edge_ink_pct, 0)
           else null end;
    if v is null then continue; end if;
    if (r.op = '>=' and v >= r.threshold)
       or (r.op = '>' and v > r.threshold)
       or (r.op = '<=' and v <= r.threshold)
       or (r.op = '<' and v < r.threshold)
       or (r.op = '=' and v = r.threshold) then
      return r;
    end if;
  end loop;
  return null;
end $$;
grant execute on function public.visual_rule_for(boolean,boolean,numeric,numeric,numeric) to authenticated, service_role;

-- One page of photographs, judged and recorded. Layout breakage becomes a
-- feature_gaps row the same way an exploratory opinion does — with its picture
-- attached — but only where there was a baseline to be broken against, or the
-- breakage is absolute (blank, unrendered, cut off).
create or replace function public.visual_shot_report(p_run_id bigint, p_shots jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_run public.test_runs;
  v_item jsonb;
  v_rule public.visual_rule;
  v_base public.visual_baseline;
  v_shot_id bigint; v_gap_id bigint;
  v_surface text; v_role text; v_feature text; v_vp text;
  v_new int := 0; v_changed int := 0; v_broken int := 0; v_match int := 0; v_gaps int := 0;
  v_verdict text; v_result text;
begin
  perform public._dev_guard();
  select * into v_run from public.test_runs where id = p_run_id;
  if v_run.id is null then
    return jsonb_build_object('ok', false, 'error', 'no_such_run');
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_shots,'[]'::jsonb))
  loop
    v_feature := v_item->>'feature_key';
    v_role    := coalesce(v_item->>'role','');
    v_vp      := coalesce(v_item->>'viewport','phone');
    if v_feature is null then continue; end if;

    select * into v_base from public.visual_baseline
     where feature_key = v_feature and role = v_role and viewport = v_vp;

    v_rule := public.visual_rule_for(
                coalesce((v_item->>'rendered')::boolean, true),
                v_base.id is not null,
                coalesce((v_item->>'diff_pct')::numeric, 0),
                coalesce((v_item->>'blank_pct')::numeric, 0),
                coalesce((v_item->>'edge_ink_pct')::numeric, 0));

    v_verdict := case when v_rule.key is null
                      then case when v_base.id is null then 'new' else 'match' end
                      else v_rule.verdict end;
    -- No baseline yet is never a failure: it is a picture waiting for a tap.
    if v_base.id is null and v_verdict = 'match' then v_verdict := 'new'; end if;

    insert into public.visual_shot
      (run_id, feature_key, role, viewport, bucket, path, diff_path, fingerprint,
       width, height, diff_pct, blank_pct, edge_ink_pct, rendered, baseline_id,
       rule_key, verdict, detail)
    values
      (p_run_id, v_feature, v_role, v_vp,
       coalesce(v_item->>'bucket','test-artifacts'),
       coalesce(v_item->>'path',''),
       nullif(v_item->>'diff_path',''),
       coalesce(v_item->>'fingerprint',''),
       nullif(v_item->>'width','')::int, nullif(v_item->>'height','')::int,
       coalesce((v_item->>'diff_pct')::numeric,0),
       coalesce((v_item->>'blank_pct')::numeric,0),
       coalesce((v_item->>'edge_ink_pct')::numeric,0),
       coalesce((v_item->>'rendered')::boolean, true),
       v_base.id, v_rule.key, v_verdict,
       coalesce(v_rule.message, nullif(v_item->>'detail','')))
    on conflict (run_id, feature_key, role, viewport) do update
       set path = excluded.path, diff_path = excluded.diff_path,
           fingerprint = excluded.fingerprint, width = excluded.width,
           height = excluded.height, diff_pct = excluded.diff_pct,
           blank_pct = excluded.blank_pct, edge_ink_pct = excluded.edge_ink_pct,
           rendered = excluded.rendered, baseline_id = excluded.baseline_id,
           rule_key = excluded.rule_key, verdict = excluded.verdict,
           detail = excluded.detail
    returning id into v_shot_id;

    if v_rule.gap_type is not null and v_verdict in ('changed','broken') then
      v_surface := public.gap_surface_for(v_feature, v_role);

      insert into public.feature_gaps
        (surface, journey_step, title, type, severity, evidence, suggestion,
         status, source, feature_key, role, run_id, spec_line,
         artifact_bucket, artifact_path, notes)
      values
        (v_surface, v_role,
         left(coalesce(v_rule.label,'Visual regression') || ' — ' || v_feature
              || ' (' || v_vp || ')', 200),
         v_rule.gap_type, v_rule.gap_severity,
         v_rule.message,
         null, 'open', 'visual', v_feature, v_role, p_run_id, null,
         coalesce(v_item->>'bucket','test-artifacts'),
         coalesce(nullif(v_item->>'diff_path',''), v_item->>'path'),
         null)
      returning id into v_gap_id;
      update public.visual_shot set gap_id = v_gap_id where id = v_shot_id;
      v_gaps := v_gaps + 1;
    end if;

    v_result := case v_verdict when 'broken' then 'failed'
                               when 'changed' then 'failed'
                               when 'new' then 'skipped'
                               else 'passed' end;

    insert into public.test_results (run_id, feature_key, role, scenario, verdict,
                                     duration_ms, steps, artifacts, error)
    values (p_run_id, v_feature, v_role, 'visual:' || v_vp, v_result, 0,
            '[]'::jsonb,
            jsonb_build_object('bucket', coalesce(v_item->>'bucket','test-artifacts'),
                               'path', v_item->>'path',
                               'diff_path', v_item->>'diff_path',
                               'diff_pct', coalesce((v_item->>'diff_pct')::numeric,0)),
            case when v_verdict in ('changed','broken') then v_rule.message else null end)
    on conflict (run_id, feature_key, role, scenario) do update
       set verdict = excluded.verdict, artifacts = excluded.artifacts,
           error = excluded.error;

    v_new     := v_new     + (case when v_verdict = 'new' then 1 else 0 end);
    v_changed := v_changed + (case when v_verdict = 'changed' then 1 else 0 end);
    v_broken  := v_broken  + (case when v_verdict = 'broken' then 1 else 0 end);
    v_match   := v_match   + (case when v_verdict = 'match' then 1 else 0 end);
  end loop;

  return jsonb_build_object('ok', true, 'run_id', p_run_id,
    'new', v_new, 'changed', v_changed, 'broken', v_broken, 'match', v_match,
    'gaps', v_gaps);
end $$;
grant execute on function public.visual_shot_report(bigint,jsonb) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 10. THE ADMIN SURFACE — one tap re-baselines a deliberate redesign
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.visual_copy(p_key text, p_default text default '')
returns text
language sql stable security definer set search_path to 'public'
as $$
  select coalesce((select value #>> '{}' from public.ui_copy where key = 'visual.' || p_key), p_default);
$$;
grant execute on function public.visual_copy(text,text) to authenticated, service_role;

create or replace function public.visual_baseline_home(p_filter text default 'review')
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := coalesce(public.get_my_role(),'none');
  v_filter text := case when p_filter in ('review','changed','broken','new','all')
                        then p_filter else 'review' end;
  v_rows jsonb; v_runs jsonb; v_run bigint;
  v_pending int; v_n_changed int; v_n_broken int; v_n_new int; v_all int;
begin
  if v_role <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.visual_copy('not_authorized','Visual baselines are super-admin only.'));
  end if;

  -- The LAST visual run is the one under review. An older run's pictures are
  -- history, not a queue: re-approving them would re-bless a screen that has
  -- since changed again.
  select max(id) into v_run from public.test_runs where kind = 'visual';

  select count(*) filter (where verdict in ('changed','broken','new') and not reviewed),
         count(*) filter (where verdict = 'changed'),
         count(*) filter (where verdict = 'broken'),
         count(*) filter (where verdict = 'new'),
         count(*)
    into v_pending, v_n_changed, v_n_broken, v_n_new, v_all
    from public.visual_shot where run_id = v_run;

  select coalesce(jsonb_agg(jsonb_build_object(
           'shot_id',       s.id,
           'feature_key',   s.feature_key,
           'label',         coalesce(fr.label, s.feature_key),
           'role_label',    s.role,
           'viewport_label',coalesce(vv.label, s.viewport),
           'sub_label',     s.feature_key || ' · ' || s.role || ' · ' || coalesce(vv.label, s.viewport),
           'status_label',  coalesce(vr.label, initcap(s.verdict)),
           'tone',          coalesce(vr.tone, case s.verdict when 'match' then 'success'
                                                             when 'new' then 'info'
                                                             else 'warning' end),
           'detail',        coalesce(s.detail,''),
           'diff_label',    case when s.baseline_id is null
                                 then public.visual_copy('no_baseline','')
                                 else replace(public.visual_copy('diff_pct','{pct}%'),
                                              '{pct}', trim(to_char(s.diff_pct, 'FM990.00'))) end,
           'current',       jsonb_build_object('label', public.visual_copy('current_label','This run'),
                                               'bucket', s.bucket, 'path', s.path),
           'baseline',      jsonb_build_object(
                              'has',   b.id is not null,
                              'label', public.visual_copy('baseline_label','Approved baseline'),
                              'bucket', coalesce(b.bucket,''), 'path', coalesce(b.path,''),
                              'sub',   case when b.id is null then ''
                                            else replace(public.visual_copy('approved_at','approved {when}'),
                                                         '{when}', public.test_ago_label(b.approved_at)) end),
           'diff',          jsonb_build_object(
                              'has',   coalesce(nullif(s.diff_path,''),'') <> '',
                              'label', public.visual_copy('diff_label','What changed'),
                              'bucket', s.bucket, 'path', coalesce(s.diff_path,'')),
           'can_approve',   not s.reviewed,
           'approve_label', public.visual_copy('approve','Approve as baseline'),
           'reviewed_label',case when s.reviewed then public.visual_copy('reviewed_label','Reviewed') else '' end)
           order by case s.verdict when 'broken' then 0 when 'changed' then 1
                                   when 'new' then 2 else 3 end,
                    s.feature_key, s.role, s.viewport), '[]'::jsonb)
    into v_rows
    from public.visual_shot s
    left join public.feature_registry fr on fr.feature_key = s.feature_key
    left join public.visual_viewport  vv on vv.key = s.viewport
    left join public.visual_rule      vr on vr.key = s.rule_key
    left join public.visual_baseline  b  on b.id = s.baseline_id
   where s.run_id = v_run
     and (v_filter = 'all'
          or (v_filter = 'review'  and s.verdict in ('changed','broken','new') and not s.reviewed)
          or (v_filter = 'changed' and s.verdict = 'changed')
          or (v_filter = 'broken'  and s.verdict = 'broken')
          or (v_filter = 'new'     and s.verdict = 'new'));

  select coalesce(jsonb_agg(jsonb_build_object(
           'label', 'Run ' || r.id::text,
           'sub',   public.test_ago_label(r.started_at) || ' · ' || r.kind,
           'value', coalesce(r.totals->>'total','0'),
           'tone',  case r.status when 'passed' then 'success'
                                  when 'failed' then 'warning' else 'neutral' end)
           order by r.started_at desc), '[]'::jsonb)
    into v_runs
    from (select * from public.test_runs where kind = 'visual'
           order by started_at desc limit 5) r;

  return jsonb_build_object(
    'ok', true,
    'title',    public.visual_copy('title','Visual baselines'),
    'subtitle', public.visual_copy('subtitle',''),
    'run_id',   v_run,
    'headline', jsonb_build_object(
      'value', coalesce(v_pending,0)::text,
      'label', public.visual_copy('headline_label','Awaiting review'),
      'tone',  case when coalesce(v_pending,0) = 0 then 'success' else 'warning' end,
      'sub',   case when coalesce(v_pending,0) = 0
                    then public.visual_copy('headline_none','')
                    else replace(public.visual_copy('headline_some','{n}'), '{n}', coalesce(v_pending,0)::text) end),
    'filters', jsonb_build_array(
      jsonb_build_object('key','review', 'label', public.visual_copy('filter_review','Needs review'),
                         'count', coalesce(v_pending,0),   'selected', v_filter='review'),
      jsonb_build_object('key','changed','label', public.visual_copy('filter_changed','Changed'),
                         'count', coalesce(v_n_changed,0), 'selected', v_filter='changed'),
      jsonb_build_object('key','broken', 'label', public.visual_copy('filter_broken','Broken'),
                         'count', coalesce(v_n_broken,0),  'selected', v_filter='broken'),
      jsonb_build_object('key','new',    'label', public.visual_copy('filter_new','No baseline'),
                         'count', coalesce(v_n_new,0),     'selected', v_filter='new'),
      jsonb_build_object('key','all',    'label', public.visual_copy('filter_all','All'),
                         'count', coalesce(v_all,0),       'selected', v_filter='all')),
    'empty_label', public.visual_copy('empty','Nothing matches this filter.'),
    'approve_all', jsonb_build_object(
      'has',   coalesce(v_pending,0) > 0,
      'label', public.visual_copy('approve_all','Approve every shot in this run'),
      'run_id', v_run),
    'run_now', jsonb_build_object('label', public.visual_copy('run_now','Run the visual pass')),
    'rows', v_rows,
    'runs', jsonb_build_object(
      'title',      public.visual_copy('runs_title','Recent visual runs'),
      'none_label', public.visual_copy('runs_none',''),
      'rows',       v_runs));
end $$;
grant execute on function public.visual_baseline_home(text) to authenticated, service_role;

-- Approve ONE picture as the new truth. The linked finding is closed as
-- rejected in the same breath: a deliberate redesign is not a defect, and a
-- gap that outlives the baseline it complained about is how a register stops
-- being believed.
create or replace function public.visual_baseline_approve(p_shot_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare s public.visual_shot; v_label text; v_uid uuid;
begin
  if coalesce(public.get_my_role(),'none') <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.visual_copy('not_authorized',''));
  end if;
  select * into s from public.visual_shot where id = p_shot_id;
  if s.id is null then
    return jsonb_build_object('ok', false, 'error', 'no_such_shot');
  end if;

  v_uid := auth.uid();
  select coalesce(nullif(btrim(p.full_name),''), '') into v_label
    from public.user_profiles p where p.id = v_uid;

  insert into public.visual_baseline
    (feature_key, role, viewport, bucket, path, fingerprint, width, height,
     from_run_id, from_shot_id, approved_by, approved_by_label, approved_at)
  values (s.feature_key, s.role, s.viewport, s.bucket, s.path, s.fingerprint,
          s.width, s.height, s.run_id, s.id, v_uid, coalesce(v_label,''), now())
  on conflict (feature_key, role, viewport) do update
     set bucket = excluded.bucket, path = excluded.path,
         fingerprint = excluded.fingerprint, width = excluded.width,
         height = excluded.height, from_run_id = excluded.from_run_id,
         from_shot_id = excluded.from_shot_id, approved_by = excluded.approved_by,
         approved_by_label = excluded.approved_by_label, approved_at = now();

  update public.visual_shot
     set reviewed = true, verdict = 'match', diff_pct = 0
   where id = p_shot_id;

  if s.gap_id is not null then
    update public.feature_gaps
       set status = 'rejected', updated_at = now(),
           notes = coalesce(notes,'') || ' · baseline approved'
     where id = s.gap_id and status = 'open';
  end if;

  return jsonb_build_object('ok', true, 'shot_id', p_shot_id,
    'message', public.visual_copy('approved_toast','Baseline approved.'));
end $$;
grant execute on function public.visual_baseline_approve(bigint) to authenticated, service_role;

create or replace function public.visual_baseline_approve_run(p_run_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare r record; v_n int := 0; v_out jsonb;
begin
  if coalesce(public.get_my_role(),'none') <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.visual_copy('not_authorized',''));
  end if;
  for r in select id from public.visual_shot
            where run_id = p_run_id and not reviewed
              and verdict in ('changed','broken','new')
            order by id
  loop
    v_out := public.visual_baseline_approve(r.id);
    if coalesce((v_out->>'ok')::boolean, false) then v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'approved', v_n,
    'message', replace(public.visual_copy('approved_all_toast','{n} approved.'),
                       '{n}', v_n::text));
end $$;
grant execute on function public.visual_baseline_approve_run(bigint) to authenticated, service_role;

-- Ask for a pass. The dispatcher cannot open a browser, so the admin screen
-- QUEUES the run exactly the way the nightly schedule does.
create or replace function public.visual_run_request(p_lane text default 'visual')
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_kind text := case when p_lane = 'explore' then 'explore' else 'visual' end; v jsonb;
begin
  if coalesce(public.get_my_role(),'none') <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.visual_copy('not_authorized',''));
  end if;
  v := public.test_run_request_add(v_kind, jsonb_build_object('scope','all'), 'admin');
  return jsonb_build_object('ok', true, 'request', v,
    'message', public.visual_copy('run_queued','Queued.'));
end $$;
grant execute on function public.visual_run_request(text) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 11. THE FINDING, WHERE OM ALREADY READS IT
-- ─────────────────────────────────────────────────────────────────────────
-- No second screen for the bot's output. Feature gaps (#312) is already the
-- register every audit files into; it grows a SOURCE filter and prints the two
-- facts a bot finding carries that a hand-written one does not — the spec line
-- it contradicts and the picture it was seen in.
-- The old 5-argument signatures are DROPPED, never left beside the new ones:
-- two overloads that both accept the call PostgREST makes is an ambiguous
-- function error at runtime, not a graceful fallback.
drop function if exists public.fg_filters(text,text,text,text,text);

create or replace function public.fg_filters(
  p_surface text, p_type text, p_severity text, p_status text, p_sort text,
  p_source text default 'all')
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with a(all_opt) as (
    select jsonb_build_array(jsonb_build_object(
      'value', 'all', 'label', public.fg_label('ui.all'), 'tone', null))
  )
  select jsonb_build_array(
    jsonb_build_object('key','surface','label',public.fg_label('ui.filter_surface'),
      'value',p_surface,'options', a.all_opt || public.fg_dimension('surface')),
    jsonb_build_object('key','source','label',public.fg_label('ui.filter_source'),
      'value',p_source,'options', a.all_opt || public.fg_dimension('source')),
    jsonb_build_object('key','type','label',public.fg_label('ui.filter_type'),
      'value',p_type,'options', a.all_opt || public.fg_dimension('type')),
    jsonb_build_object('key','severity','label',public.fg_label('ui.filter_severity'),
      'value',p_severity,'options', a.all_opt || public.fg_dimension('severity')),
    jsonb_build_object('key','status','label',public.fg_label('ui.filter_status'),
      'value',p_status,'options', a.all_opt || public.fg_dimension('status')),
    jsonb_build_object('key','sort','label',public.fg_label('ui.filter_sort'),
      'value',p_sort,'options', jsonb_build_array(
        jsonb_build_object('value','severity','label',public.fg_label('ui.sort_severity'),'tone',null),
        jsonb_build_object('value','recent','label',public.fg_label('ui.sort_recent'),'tone',null)))
  ) from a;
$$;
grant execute on function public.fg_filters(text,text,text,text,text,text) to authenticated, service_role;

drop function if exists public.feature_gaps_list(text,text,text,text,text,int,int);

create or replace function public.feature_gaps_list(
  p_surface  text default 'all',
  p_type     text default 'all',
  p_severity text default 'all',
  p_status   text default 'all',
  p_sort     text default 'severity',
  p_limit    int  default 300,
  p_offset   int  default 0,
  p_source   text default 'all')
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  _rows jsonb;
  _total int;
  _all   int;
  _sort  text := case when p_sort = 'recent' then 'recent' else 'severity' end;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'message', public.fg_label('ui.not_authorized'));
  end if;

  select count(*)::int into _total
    from public.feature_gaps g
   where (p_surface  = 'all' or g.surface  = p_surface)
     and (p_type     = 'all' or g.type     = p_type)
     and (p_severity = 'all' or g.severity = p_severity)
     and (p_status   = 'all' or g.status   = p_status)
     and (coalesce(p_source,'all') = 'all' or g.source = p_source);

  with scoped as (
    select g.*
      from public.feature_gaps g
     where (p_surface  = 'all' or g.surface  = p_surface)
       and (p_type     = 'all' or g.type     = p_type)
       and (p_severity = 'all' or g.severity = p_severity)
       and (p_status   = 'all' or g.status   = p_status)
       and (coalesce(p_source,'all') = 'all' or g.source = p_source)
  ), page as (
    select * from scoped
     order by case when _sort = 'severity' then public.fg_severity_rank(severity) end asc nulls last,
              found_at desc
     limit greatest(p_limit, 1) offset greatest(p_offset, 0)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',              p.id,
           'title',           p.title,
           'surface',         p.surface,
           'surface_label',   public.fg_label('surface.' || p.surface),
           'journey_step',    p.journey_step,
           'type',            p.type,
           'type_label',      public.fg_label('type.' || p.type),
           'type_tone',       public.fg_tone('type.' || p.type),
           'severity',        p.severity,
           'severity_label',  public.fg_label('severity.' || p.severity),
           'severity_tone',   public.fg_tone('severity.' || p.severity),
           'status',          p.status,
           'status_label',    public.fg_label('status.' || p.status),
           'status_tone',     public.fg_tone('status.' || p.status),
           'evidence',        p.evidence,
           'suggestion',      p.suggestion,
           'effort_guess',    p.effort_guess,
           'notes',           p.notes,
           'dev_command_id',  p.dev_command_id,
           'found_label',     public.fg_when(p.found_at),
           -- CHANGE #637 — who filed it, what it contradicts, and the picture.
           'source',          p.source,
           'source_label',    public.fg_label('source.' || p.source),
           'source_tone',     public.fg_tone('source.' || p.source),
           'spec_line',       p.spec_line,
           'confidence',      p.confidence,
           'shot',            case when coalesce(p.artifact_path,'') = '' then null
                                   else jsonb_build_object('bucket', p.artifact_bucket,
                                                           'path',   p.artifact_path) end,
           'actions',         public.fg_actions(p.status)
         ) order by case when _sort = 'severity' then public.fg_severity_rank(p.severity) end asc nulls last,
                    p.found_at desc), '[]'::jsonb)
    into _rows
    from page p;

  select count(*)::int into _all from public.feature_gaps;

  return jsonb_build_object(
    'ok', true,
    'title',       public.fg_label('ui.title'),
    'subtitle',    public.fg_label('ui.subtitle'),
    'refresh',     public.fg_label('ui.refresh'),
    'rows',        _rows,
    'has_rows',    jsonb_array_length(_rows) > 0,
    'empty_title', public.fg_label('ui.empty_title'),
    'empty_body',  public.fg_label('ui.empty_body'),
    'field_labels', jsonb_build_object(
      'journey_step', public.fg_label('ui.field_journey'),
      'evidence',     public.fg_label('ui.field_evidence'),
      'suggestion',   public.fg_label('ui.field_suggestion'),
      'effort',       public.fg_label('ui.field_effort'),
      'notes',        public.fg_label('ui.field_notes'),
      'dev_command',  public.fg_label('ui.field_command'),
      'found',        public.fg_label('ui.field_found'),
      'spec_line',    public.fg_label('ui.field_spec_line'),
      'shot',         public.fg_label('ui.field_shot'),
      'confidence',   public.fg_label('ui.field_confidence')
    ),
    'filters',     public.fg_filters(p_surface, p_type, p_severity, p_status, _sort, coalesce(p_source,'all')),
    'counts',      public.fg_counts(p_surface, p_type, p_severity, p_status, _total, _all)
  );
end $$;
grant execute on function public.feature_gaps_list(text,text,text,text,text,int,int,text) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 12. THE DOOR — the tool row, in #349's exact shape, and its own contract
-- ─────────────────────────────────────────────────────────────────────────
-- The glyph is a lookup row, and the FK is why: an icon_key nothing can draw
-- is a tool rendered as a blank square.
insert into public.ui_icon (icon_key, label) values ('photo','Photo')
on conflict (icon_key) do nothing;

insert into public.feature_registry
  (feature_key, label, description, group_label, icon_key, route_key,
   sort_order, owner, partner_eligible, default_access, is_active, category,
   surface, roles_allowed, deep_link, search_terms, badge_source, badge_noun)
values
  ('devtool.visual_baselines','Visual baselines',
   'Every registered screen photographed per role at a phone and a desktop width, diffed against the approved picture',
   'Proof & QA','photo',
   'visual_baselines',16,'medibo',false,'none',true,'system','dev_tools',
   array['super_admin'],null,'visual regression baseline screenshot diff layout',null,null)
on conflict (feature_key) do update
   set label = excluded.label, description = excluded.description,
       group_label = excluded.group_label, icon_key = excluded.icon_key,
       route_key = excluded.route_key, surface = excluded.surface,
       is_active = true;

update public.feature_registry
   set test_entry  = '/admin/go/visual_baselines',
       test_roles  = array['super_admin']::text[],
       test_steps  = jsonb_build_array(
         jsonb_build_object('kind','auth','role','super_admin'),
         jsonb_build_object('kind','goto','path','/admin/go/visual_baselines'),
         jsonb_build_object('kind','settle','ms', 6000)),
       test_expect = jsonb_build_object('kind','visible','source','render_log',
                                        'key','c325_deep_link','equals','visual_baselines'),
       test_automatable = true,
       test_contract_at = now()
 where feature_key = 'devtool.visual_baselines';

-- ─────────────────────────────────────────────────────────────────────────
-- 13. THE SCHEDULE — both lanes ask; the VM answers
-- ─────────────────────────────────────────────────────────────────────────
-- Night window, and never on a bare */N (the #305 dispatcher owns the clock;
-- an offset is what kept 35 jobs off minute 0 after the connection outage).
insert into public.cron_task (name, ord, mode, work_sql, note, enabled,
                              base_interval_s, max_interval_s, night_only)
values
  ('c637_visual_nightly', 615, 'poll',
   $q$select public.test_run_request_add('visual', '{"scope":"all"}'::jsonb, 'dispatcher')$q$,
   'CHANGE #637 — asks for a visual regression pass; the VM claims it and opens the browser.',
   true, 86400, 172800, true),
  ('c637_explore_nightly', 616, 'poll',
   $q$select public.test_run_request_add('explore', '{"scope":"all","limit":12}'::jsonb, 'dispatcher')$q$,
   'CHANGE #637 — asks for an exploratory pass; findings land in feature_gaps for review.',
   true, 86400, 172800, true)
on conflict (name) do update
   set work_sql = excluded.work_sql, note = excluded.note,
       base_interval_s = excluded.base_interval_s,
       max_interval_s = excluded.max_interval_s,
       night_only = excluded.night_only;

select public.test_coverage_refresh();

-- ─────────────────────────────────────────────────────────────────────────
-- 14. THE STORE MUST NOT GROW FOREVER
-- ─────────────────────────────────────────────────────────────────────────
-- A nightly pass photographs every screen at every width. Kept forever that is
-- a gigabyte a month of pictures nobody will open — and a full disk on the
-- build VM breaks far more than this lane. So the backend NAMES what may go:
-- everything from a run older than the last `p_keep`, minus anything an
-- approved baseline still points at. The VM deletes exactly that list and
-- decides nothing.
create or replace function public.visual_prune(p_keep int default 5)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_keep int := greatest(coalesce(p_keep, 5), 1); v_paths jsonb; v_ids bigint[];
begin
  perform public._dev_guard();

  with keep as (
    select id from public.test_runs where kind = 'visual'
     order by started_at desc limit v_keep
  ), old as (
    select s.* from public.visual_shot s
     where s.run_id not in (select id from keep)
  ), doomed as (
    select o.id, p.path
      from old o
      cross join lateral (values (o.path), (o.diff_path)) as p(path)
     where coalesce(p.path,'') <> ''
       -- An approved baseline's picture is the one thing that outlives its run.
       and not exists (select 1 from public.visual_baseline b
                        where b.path = p.path and b.bucket = o.bucket)
  )
  select coalesce(jsonb_agg(distinct to_jsonb(d.path)), '[]'::jsonb),
         coalesce(array_agg(distinct d.id), array[]::bigint[])
    into v_paths, v_ids from doomed d;

  delete from public.visual_shot where id = any(v_ids);

  return jsonb_build_object('ok', true, 'bucket', 'test-artifacts',
                            'paths', v_paths,
                            'shots_removed', coalesce(array_length(v_ids,1), 0),
                            'keep_runs', v_keep);
end $$;
grant execute on function public.visual_prune(int) to authenticated, service_role;

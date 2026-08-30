-- ============================================================================
-- CHANGE #312 — the feature_gaps register: table + backend labels + admin RPCs.
--
-- Foundation ONLY. Five per-role journey audits follow and will WRITE into this
-- register through feature_gap_add(); this command audits nothing and fixes
-- nothing. Everything an admin reads on the screen — the title, every filter
-- option, every enum's word and colour tone, the counts, the button captions,
-- the empty state, the toast — is a row in feature_gap_label, so re-wording the
-- screen is an UPDATE, never a deploy.
--
-- Idempotent by construction (#233): re-running this file on a database that
-- already has it is a silent no-op.
-- ============================================================================

-- ── The register ────────────────────────────────────────────────────────────
create table if not exists public.feature_gaps (
  id              bigserial primary key,
  surface         text not null,
  journey_step    text,
  title           text not null,
  type            text not null,
  severity        text not null,
  evidence        text,
  suggestion      text,
  effort_guess    text,
  status          text not null default 'open',
  dev_command_id  bigint,
  found_at        timestamptz not null default now(),
  notes           text,
  updated_at      timestamptz not null default now()
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'feature_gaps_surface_ck') then
    alter table public.feature_gaps add constraint feature_gaps_surface_ck
      check (surface in ('customer','admin','supplier','delivery','partner','platform'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'feature_gaps_type_ck') then
    alter table public.feature_gaps add constraint feature_gaps_type_ck
      check (type in ('broken','partial','missing','opportunity'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'feature_gaps_severity_ck') then
    alter table public.feature_gaps add constraint feature_gaps_severity_ck
      check (severity in ('critical','high','medium','low'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'feature_gaps_status_ck') then
    alter table public.feature_gaps add constraint feature_gaps_status_ck
      check (status in ('open','approved','queued','done','rejected'));
  end if;
end $$;

-- One finding per (surface, journey step, title) so a re-run of an audit
-- REFRESHES its evidence instead of growing a duplicate row.
create unique index if not exists feature_gaps_identity_uk
  on public.feature_gaps (surface, coalesce(journey_step,''), title);
create index if not exists feature_gaps_status_idx on public.feature_gaps (status);
create index if not exists feature_gaps_found_idx  on public.feature_gaps (found_at desc);

-- RLS: admin only. Every read path is a security-definer RPC, so this policy is
-- the belt to that braces — a direct PostgREST hit on the table by anon or by a
-- signed-in customer returns nothing.
alter table public.feature_gaps enable row level security;
drop policy if exists feature_gaps_admin_all on public.feature_gaps;
create policy feature_gaps_admin_all on public.feature_gaps
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on table public.feature_gaps from public, anon;
grant select on table public.feature_gaps to authenticated;
grant all on table public.feature_gaps to service_role;
grant usage, select on sequence public.feature_gaps_id_seq to service_role;

-- ── Backend-owned copy ──────────────────────────────────────────────────────
-- key           : 'ui.<slot>' | '<dimension>.<value>'
-- label         : the word rendered verbatim
-- tone          : a DESIGN TOKEN NAME (brand/success/warning/danger/info/
--                 neutral) — never a hex. Flutter maps tone -> Ds.c.*, so a
--                 recolour via ui_design_set() carries this screen with it.
-- sort_order    : render order inside its dimension.
create table if not exists public.feature_gap_label (
  key         text primary key,
  label       text not null,
  tone        text,
  sort_order  int not null default 0
);
alter table public.feature_gap_label enable row level security;
drop policy if exists feature_gap_label_read on public.feature_gap_label;
create policy feature_gap_label_read on public.feature_gap_label
  for select to authenticated using (public.is_admin());
revoke all on table public.feature_gap_label from public, anon;
grant select on table public.feature_gap_label to authenticated;
grant all on table public.feature_gap_label to service_role;

insert into public.feature_gap_label (key, label, tone, sort_order) values
  ('ui.title',            'Feature gaps',                                   null, 0),
  ('ui.subtitle',         'Everything a journey audit found, ranked worst first. Approve what should be built; reject what should not.', null, 0),
  ('ui.counts_title',     'In this view',                                   null, 0),
  ('ui.total_label',      'findings',                                       null, 0),
  ('ui.register_label',   'in the register',                                null, 0),
  ('ui.by_surface',       'By surface',                                     null, 1),
  ('ui.by_type',          'By type',                                        null, 2),
  ('ui.by_severity',      'By severity',                                    null, 3),
  ('ui.filter_surface',   'Surface',                                        null, 1),
  ('ui.filter_type',      'Type',                                           null, 2),
  ('ui.filter_severity',  'Severity',                                       null, 3),
  ('ui.filter_status',    'Status',                                         null, 4),
  ('ui.filter_sort',      'Sort',                                           null, 5),
  ('ui.all',              'All',                                            null, 0),
  ('ui.sort_severity',    'Worst first',                                    null, 1),
  ('ui.sort_recent',      'Newest first',                                   null, 2),
  ('ui.field_journey',    'Journey step',                                   null, 1),
  ('ui.field_evidence',   'Evidence',                                       null, 2),
  ('ui.field_suggestion', 'Suggestion',                                     null, 3),
  ('ui.field_effort',     'Effort',                                         null, 4),
  ('ui.field_notes',      'Notes',                                          null, 5),
  ('ui.field_command',    'Dev command',                                    null, 6),
  ('ui.field_found',      'Found',                                          null, 7),
  ('ui.approve',          'Approve',                                        'brand',   1),
  ('ui.reject',           'Reject',                                         'danger',  2),
  ('ui.refresh',          'Refresh',                                        null, 0),
  ('ui.empty_title',      'No gaps recorded yet',                           null, 0),
  ('ui.empty_body',       'The per-role journey audits write their findings here. Nothing has been filed for this view.', null, 0),
  ('ui.not_authorized',   'Admins only.',                                   'danger',  0),
  ('ui.not_found',        'That finding no longer exists.',                 'danger',  0),
  ('ui.bad_status',       'That is not a status this register accepts.',    'danger',  0),
  ('ui.saved_approved',   'Approved.',                                      'success', 0),
  ('ui.saved_rejected',   'Rejected.',                                      'danger',  0),

  ('surface.customer',    'Customer',    null, 1),
  ('surface.admin',       'Admin',       null, 2),
  ('surface.supplier',    'Supplier',    null, 3),
  ('surface.delivery',    'Delivery',    null, 4),
  ('surface.partner',     'Partner',     null, 5),
  ('surface.platform',    'Platform',    null, 6),

  ('type.broken',         'Broken',      'danger',  1),
  ('type.partial',        'Partial',     'warning', 2),
  ('type.missing',        'Missing',     'info',    3),
  ('type.opportunity',    'Opportunity', 'neutral', 4),

  ('severity.critical',   'Critical',    'danger',  1),
  ('severity.high',       'High',        'warning', 2),
  ('severity.medium',     'Medium',      'info',    3),
  ('severity.low',        'Low',         'neutral', 4),

  ('status.open',         'Open',        'warning', 1),
  ('status.approved',     'Approved',    'success', 2),
  ('status.queued',       'Queued',      'info',    3),
  ('status.done',         'Done',        'brand',   4),
  ('status.rejected',     'Rejected',    'neutral', 5)
on conflict (key) do nothing;

-- ── Helpers ─────────────────────────────────────────────────────────────────
create or replace function public.fg_label(p_key text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select label from public.feature_gap_label where key = p_key), '');
$$;

create or replace function public.fg_tone(p_key text)
returns text language sql stable security definer set search_path = public as $$
  select (select tone from public.feature_gap_label where key = p_key);
$$;

-- Every value of one dimension, in its own render order, as
-- [{value,label,tone}] — the single place the screen's chips come from.
create or replace function public.fg_dimension(p_dim text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'value', split_part(key, '.', 2), 'label', label, 'tone', tone)
           order by sort_order), '[]'::jsonb)
  from public.feature_gap_label
  where key like p_dim || '.%';
$$;

create or replace function public.fg_severity_rank(p_severity text)
returns int language sql immutable as $$
  select case p_severity
           when 'critical' then 1 when 'high' then 2
           when 'medium'   then 3 when 'low'  then 4 else 9 end;
$$;

-- IST, spelled by the backend (rule: all timestamps IST for display).
create or replace function public.fg_when(p_ts timestamptz)
returns text language sql stable as $$
  select to_char(p_ts at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM');
$$;

-- ── The screen's one read ───────────────────────────────────────────────────
create or replace function public.feature_gaps_list(
  p_surface  text default 'all',
  p_type     text default 'all',
  p_severity text default 'all',
  p_status   text default 'all',
  p_sort     text default 'severity',
  p_limit    int  default 300,
  p_offset   int  default 0
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
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

  with scoped as (
    select g.*
      from public.feature_gaps g
     where (p_surface  = 'all' or g.surface  = p_surface)
       and (p_type     = 'all' or g.type     = p_type)
       and (p_severity = 'all' or g.severity = p_severity)
       and (p_status   = 'all' or g.status   = p_status)
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
           'actions',         public.fg_actions(p.status)
         ) order by case when _sort = 'severity' then public.fg_severity_rank(p.severity) end asc nulls last,
                    p.found_at desc), '[]'::jsonb),
         count(*)::int
    into _rows, _total
    from page p;

  select count(*)::int into _all from public.feature_gaps;

  return jsonb_build_object(
    'ok', true,
    'title',       public.fg_label('ui.title'),
    'subtitle',    public.fg_label('ui.subtitle'),
    'refresh',     public.fg_label('ui.refresh'),
    'rows',        _rows,
    'has_rows',    _total > 0,
    'empty_title', public.fg_label('ui.empty_title'),
    'empty_body',  public.fg_label('ui.empty_body'),
    'field_labels', jsonb_build_object(
      'journey_step', public.fg_label('ui.field_journey'),
      'evidence',     public.fg_label('ui.field_evidence'),
      'suggestion',   public.fg_label('ui.field_suggestion'),
      'effort',       public.fg_label('ui.field_effort'),
      'notes',        public.fg_label('ui.field_notes'),
      'dev_command',  public.fg_label('ui.field_command'),
      'found',        public.fg_label('ui.field_found')
    ),
    'filters',     public.fg_filters(p_surface, p_type, p_severity, p_status, _sort),
    'counts',      public.fg_counts(p_surface, p_type, p_severity, p_status, _total, _all)
  );
end $$;

-- The transitions this register allows, worded and toned by the label table.
create or replace function public.fg_actions(p_status text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(a order by ord), '[]'::jsonb) from (
    select jsonb_build_object('action', 'approve',
             'label', public.fg_label('ui.approve'), 'tone', public.fg_tone('ui.approve')) as a, 1 as ord
     where p_status in ('open','rejected')
    union all
    select jsonb_build_object('action', 'reject',
             'label', public.fg_label('ui.reject'), 'tone', public.fg_tone('ui.reject')), 2
     where p_status in ('open','approved')
  ) t;
$$;

-- One filter block per dimension: the label, the chosen value, and every chip.
create or replace function public.fg_filters(
  p_surface text, p_type text, p_severity text, p_status text, p_sort text
) returns jsonb
language sql stable security definer set search_path = public as $$
  with a(all_opt) as (
    select jsonb_build_array(jsonb_build_object(
      'value', 'all', 'label', public.fg_label('ui.all'), 'tone', null))
  )
  select jsonb_build_array(
    jsonb_build_object('key','surface','label',public.fg_label('ui.filter_surface'),
      'value',p_surface,'options', a.all_opt || public.fg_dimension('surface')),
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

-- Counts across the CURRENT view (so the header can never disagree with the
-- list under it), plus the size of the whole register for context. A value
-- nobody has filed against is OMITTED rather than sent as a zero — the screen
-- renders what arrives, so an absence stays the backend's decision.
create or replace function public.fg_counts(
  p_surface text, p_type text, p_severity text, p_status text,
  p_total int, p_all int
) returns jsonb
language sql stable security definer set search_path = public as $$
  with scoped as (
    select g.* from public.feature_gaps g
     where (p_surface  = 'all' or g.surface  = p_surface)
       and (p_type     = 'all' or g.type     = p_type)
       and (p_severity = 'all' or g.severity = p_severity)
       and (p_status   = 'all' or g.status   = p_status)
  ), grp as (
    select d.dim, d.value, d.label, d.tone, d.ord,
           coalesce(count(s.id), 0)::int as n
      from (
        select 'surface' as dim, o->>'value' as value, o->>'label' as label, o->>'tone' as tone, ord
          from jsonb_array_elements(public.fg_dimension('surface')) with ordinality x(o, ord)
        union all
        select 'type', o->>'value', o->>'label', o->>'tone', ord
          from jsonb_array_elements(public.fg_dimension('type')) with ordinality x(o, ord)
        union all
        select 'severity', o->>'value', o->>'label', o->>'tone', ord
          from jsonb_array_elements(public.fg_dimension('severity')) with ordinality x(o, ord)
      ) d
      left join scoped s
        on (d.dim = 'surface'  and s.surface  = d.value)
        or (d.dim = 'type'     and s.type     = d.value)
        or (d.dim = 'severity' and s.severity = d.value)
     group by d.dim, d.value, d.label, d.tone, d.ord
    having coalesce(count(s.id), 0) > 0
  )
  select jsonb_build_object(
    'title', public.fg_label('ui.counts_title'),
    'total', p_total,
    'total_label', p_total || ' ' || public.fg_label('ui.total_label'),
    'register_label', p_all || ' ' || public.fg_label('ui.register_label'),
    'groups', jsonb_build_array(
      jsonb_build_object('key','surface','label',public.fg_label('ui.by_surface'),
        'items', (select coalesce(jsonb_agg(jsonb_build_object('key',value,'label',label,'tone',tone,'count',n) order by ord),'[]'::jsonb) from grp where dim='surface')),
      jsonb_build_object('key','type','label',public.fg_label('ui.by_type'),
        'items', (select coalesce(jsonb_agg(jsonb_build_object('key',value,'label',label,'tone',tone,'count',n) order by ord),'[]'::jsonb) from grp where dim='type')),
      jsonb_build_object('key','severity','label',public.fg_label('ui.by_severity'),
        'items', (select coalesce(jsonb_agg(jsonb_build_object('key',value,'label',label,'tone',tone,'count',n) order by ord),'[]'::jsonb) from grp where dim='severity'))
    )
  );
$$;

-- ── Om's one write ──────────────────────────────────────────────────────────
create or replace function public.feature_gap_set_status(
  p_id bigint, p_status text, p_note text default null
) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare _row public.feature_gaps;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'message', public.fg_label('ui.not_authorized'));
  end if;
  if p_status not in ('open','approved','queued','done','rejected') then
    return jsonb_build_object('ok', false, 'error', 'bad_status',
                              'message', public.fg_label('ui.bad_status'));
  end if;

  update public.feature_gaps
     set status     = p_status,
         notes      = coalesce(nullif(btrim(coalesce(p_note, '')), ''), notes),
         updated_at = now()
   where id = p_id
   returning * into _row;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
                              'message', public.fg_label('ui.not_found'));
  end if;

  return jsonb_build_object(
    'ok', true,
    'id', _row.id,
    'status', _row.status,
    'status_label', public.fg_label('status.' || _row.status),
    'status_tone',  public.fg_tone('status.' || _row.status),
    'actions', public.fg_actions(_row.status),
    'message', case when p_status = 'rejected'
                    then public.fg_label('ui.saved_rejected')
                    else public.fg_label('ui.saved_approved') end
  );
end $$;

-- ── The door the audits that follow write through ───────────────────────────
-- service_role only. Re-filing the same finding REFRESHES its evidence and
-- never resets a decision Om already made.
create or replace function public.feature_gap_add(
  p_surface        text,
  p_title          text,
  p_type           text,
  p_severity       text,
  p_journey_step   text default null,
  p_evidence       text default null,
  p_suggestion     text default null,
  p_effort_guess   text default null,
  p_notes          text default null,
  p_dev_command_id bigint default null
) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare _id bigint;
begin
  insert into public.feature_gaps
    (surface, journey_step, title, type, severity, evidence, suggestion,
     effort_guess, notes, dev_command_id)
  values
    (p_surface, p_journey_step, p_title, p_type, p_severity, p_evidence,
     p_suggestion, p_effort_guess, p_notes, p_dev_command_id)
  on conflict (surface, coalesce(journey_step,''), title) do update
     set type         = excluded.type,
         severity     = excluded.severity,
         evidence     = coalesce(excluded.evidence, feature_gaps.evidence),
         suggestion   = coalesce(excluded.suggestion, feature_gaps.suggestion),
         effort_guess = coalesce(excluded.effort_guess, feature_gaps.effort_guess),
         notes        = coalesce(excluded.notes, feature_gaps.notes),
         dev_command_id = coalesce(excluded.dev_command_id, feature_gaps.dev_command_id),
         updated_at   = now()
  returning id into _id;
  return jsonb_build_object('ok', true, 'id', _id);
end $$;

-- ── Grants (lesson from #305/#306: the grant to revoke is the one to PUBLIC) ─
do $$
declare
  fn text;
  admin_facing constant text[] := array[
    'feature_gaps_list(text,text,text,text,text,integer,integer)',
    'feature_gap_set_status(bigint,text,text)'
  ];
  internal constant text[] := array[
    'feature_gap_add(text,text,text,text,text,text,text,text,text,bigint)',
    'fg_label(text)', 'fg_tone(text)', 'fg_dimension(text)',
    'fg_severity_rank(text)', 'fg_when(timestamp with time zone)',
    'fg_actions(text)', 'fg_filters(text,text,text,text,text)',
    'fg_counts(text,text,text,text,integer,integer)'
  ];
begin
  foreach fn in array admin_facing || internal loop
    if to_regprocedure('public.' || fn) is not null then
      execute format('revoke all on function public.%s from public', fn);
      execute format('revoke all on function public.%s from anon', fn);
      execute format('revoke all on function public.%s from authenticated', fn);
      execute format('grant execute on function public.%s to service_role', fn);
    end if;
  end loop;
  foreach fn in array admin_facing loop
    if to_regprocedure('public.' || fn) is not null then
      execute format('grant execute on function public.%s to authenticated', fn);
    end if;
  end loop;
end $$;

-- ── The nav label (kAdminOverflowNav reads it through c()) ──────────────────
-- A key with no row renders an EMPTY label — a perfectly drawn, invisible menu
-- entry. Seeded here so the "More" popup and the mobile profile sheet, which
-- generate from the same list, both name it.
insert into public.ui_copy (key, value)
values ('admin_nav.overflow_feature_gaps', to_jsonb('Feature gaps'::text))
on conflict (key) do nothing;

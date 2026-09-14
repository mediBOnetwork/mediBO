-- CMD #1985 — The partner agreement becomes a LIVING document.
--
-- Until now partner_agreement_version.body was one frozen block of prose that
-- named "Jai Mahakal" as the operator. The Raipur partner changed to UNIVERSAL
-- PHARMA and the whole agreement went stale: signature 5 had to be deleted by
-- hand on 14 Sep because there was no way to re-render or re-ask.
--
-- Four structural changes end that class of problem:
--   1. Clauses, not prose. agreement_clause rows carry {{tokens}}; NO entity
--      name is ever typed into clause text. They resolve at RENDER time from
--      platform_identity, region_partners and zone_fulfilment_mode.
--   2. Commercial terms are STRUCTURED and have ONE home — zone_fulfilment_mode
--      already drives settlement, so split_pct / cadence / exit_notice_days are
--      read from there and printed from there. Never a second copy.
--   3. Versions have validity (effective_from / effective_to / renew_before_days)
--      and a status lifecycle draft -> published -> retired.
--   4. Signing snapshots the RESOLVED text plus its sha256; a change to the
--      partner's identity VOIDS that signature and asks for a fresh one.
--
-- Every string this file needs lives in ui_copy. Idempotent throughout.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. VERSION LIFECYCLE + VALIDITY
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.partner_agreement_version
  add column if not exists status             text not null default 'draft',
  add column if not exists effective_to       date,
  add column if not exists renew_before_days  int  not null default 30,
  add column if not exists retired_at         timestamptz,
  add column if not exists updated_at         timestamptz not null default now(),
  add column if not exists updated_by         text not null default '';

do $$ begin
  -- status is derived from the legacy flag ONCE, on first run.
  update public.partner_agreement_version
     set status = case when is_published then 'published' else 'draft' end
   where status is null or status = '' or (is_published and status = 'draft' and published_at is not null);
end $$;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'partner_agreement_version_status_chk') then
    alter table public.partner_agreement_version
      add constraint partner_agreement_version_status_chk
      check (status in ('draft','published','retired'));
  end if;
end $$;

-- is_published stays TRUE for exactly the published rows, so every reader that
-- predates this change keeps answering correctly. One truth, mirrored.
create or replace function public._c1985_version_sync() returns trigger
language plpgsql as $$
begin
  new.is_published := (new.status = 'published');
  if new.status = 'published' and new.published_at is null then
    new.published_at := now();
  end if;
  if new.status = 'retired' and new.retired_at is null then
    new.retired_at := now();
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists _c1985_version_sync_trg on public.partner_agreement_version;
create trigger _c1985_version_sync_trg
  before insert or update on public.partner_agreement_version
  for each row execute function public._c1985_version_sync();

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. COMMERCIAL TERMS — ONE SOURCE. zone_fulfilment_mode already drives
--    settlement; the agreement now PRINTS from the same row.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.zone_fulfilment_mode
  add column if not exists exit_notice_days int not null default 30;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. CLAUSES
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.agreement_clause (
  id                  bigserial primary key,
  version_id          bigint not null references public.partner_agreement_version(id) on delete cascade,
  n                   int not null,
  heading             text not null default '',
  body                text not null default '',
  owner               text not null default 'admin',
  editable_by_partner boolean not null default false,
  required            boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname='agreement_clause_version_n_key') then
    alter table public.agreement_clause add constraint agreement_clause_version_n_key unique (version_id, n);
  end if;
  if not exists (select 1 from pg_constraint where conname='agreement_clause_owner_chk') then
    alter table public.agreement_clause add constraint agreement_clause_owner_chk check (owner in ('admin','partner'));
  end if;
end $$;
create index if not exists agreement_clause_version_idx on public.agreement_clause(version_id, n);

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. PARTNER PROPOSALS — nothing a partner types is live until mediBO approves.
--    An approved proposal becomes a PARTNER-SPECIFIC override, never an edit of
--    the shared version: one partner's negotiated clause must not silently
--    rewrite everybody else's signed text.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.agreement_clause_proposal (
  id              bigserial primary key,
  clause_id       bigint not null references public.agreement_clause(id) on delete cascade,
  version_id      bigint not null references public.partner_agreement_version(id) on delete cascade,
  partner_id      bigint not null references public.region_partners(id) on delete cascade,
  current_body    text not null default '',
  proposed_body   text not null default '',
  note            text not null default '',
  status          text not null default 'pending',
  decided_at      timestamptz,
  decided_by      text not null default '',
  decision_reason text not null default '',
  created_at      timestamptz not null default now(),
  created_by      text not null default ''
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname='agreement_clause_proposal_status_chk') then
    alter table public.agreement_clause_proposal add constraint agreement_clause_proposal_status_chk
      check (status in ('pending','approved','rejected','withdrawn'));
  end if;
end $$;
create index if not exists agreement_clause_proposal_partner_idx
  on public.agreement_clause_proposal(partner_id, status, id desc);
create unique index if not exists agreement_clause_proposal_one_open
  on public.agreement_clause_proposal(clause_id, partner_id) where status = 'pending';

create table if not exists public.agreement_clause_override (
  id          bigserial primary key,
  version_id  bigint not null references public.partner_agreement_version(id) on delete cascade,
  clause_id   bigint not null references public.agreement_clause(id) on delete cascade,
  partner_id  bigint not null references public.region_partners(id) on delete cascade,
  body        text not null default '',
  proposal_id bigint references public.agreement_clause_proposal(id) on delete set null,
  created_at  timestamptz not null default now()
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname='agreement_clause_override_key') then
    alter table public.agreement_clause_override add constraint agreement_clause_override_key
      unique (clause_id, partner_id);
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. SIGNATURE SNAPSHOT + VOID
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.partner_agreement_signature
  add column if not exists body_sha256  text,
  add column if not exists snapshot     jsonb not null default '[]'::jsonb,
  add column if not exists terms        jsonb not null default '{}'::jsonb,
  add column if not exists voided_at    timestamptz,
  add column if not exists void_reason  text not null default '';

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. TOKEN RESOLUTION — the heart of the change. No entity name in clause text.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.agreement_terms(p_partner_id bigint)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  -- The ONE row that already drives settlement. Reading it here is what makes
  -- "printed in the agreement" and "paid out" the same number by construction.
  select jsonb_build_object(
    'split_pct',        coalesce(z.split_pct, 0),
    'cadence',          coalesce(nullif(z.cadence,''), 'same_day'),
    'exit_notice_days', coalesce(z.exit_notice_days, 30),
    'zone_id',          rp.zone_id)
  from public.region_partners rp
  left join public.zone_fulfilment_mode z on z.partner_id = rp.id
  where rp.id = p_partner_id
  limit 1
$$;

create or replace function public.agreement_tokens(p_partner_id bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  rp public.region_partners%rowtype;
  pi public.platform_identity%rowtype;
  t  jsonb := coalesce(public.agreement_terms(p_partner_id), '{}'::jsonb);
  v_zone text;
begin
  select * into rp from public.region_partners where id = p_partner_id;
  select * into pi from public.platform_identity order by id limit 1;
  select coalesce(nullif(z.name,''), '') into v_zone from public.zones z where z.id = rp.zone_id;

  return jsonb_build_object(
    'operator',         coalesce(nullif(pi.operator_legal_name,''), nullif(pi.business_name,''),
                                 coalesce(pi.platform_name,'mediBO')),
    'operator_udyam',   coalesce(nullif(pi.udyam_no,''), '—'),
    'operator_gstin',   coalesce(nullif(pi.gstin,''), '—'),
    'partner',          coalesce(nullif(rp.partner_name,''), '—'),
    'partner_gstin',    coalesce(nullif(rp.gstin,''), '—'),
    'partner_dl20b',    coalesce(nullif(rp.dl_20b,''), '—'),
    'partner_dl21b',    coalesce(nullif(rp.dl_21b,''), '—'),
    'partner_address',  coalesce(nullif(rp.address,''), coalesce(rp.district,'') ), 
    'zone',             coalesce(nullif(v_zone,''), coalesce(rp.district,'—')),
    'split_pct',        trim(to_char(coalesce((t->>'split_pct')::numeric,0),'FM999990.00')),
    'cadence',          coalesce(public._c('partner_agree.cadence_' || coalesce(t->>'cadence','same_day')),
                                 coalesce(t->>'cadence','')),
    'exit_notice_days', coalesce(t->>'exit_notice_days','30'));
end $$;

-- {{key}} -> value. An unknown token is left VISIBLE rather than blanked, so a
-- typo in a clause shows up in review instead of printing an empty obligation.
create or replace function public.agreement_resolve(p_text text, p_tokens jsonb)
returns text language plpgsql immutable as $$
declare k text; v text; out_text text := coalesce(p_text,'');
begin
  for k, v in select key, value #>> '{}' from jsonb_each(coalesce(p_tokens,'{}'::jsonb)) loop
    out_text := replace(out_text, '{{' || k || '}}', coalesce(v,''));
  end loop;
  return out_text;
end $$;

-- pgcrypto lives in the `extensions` schema on this project, so the hash gets
-- its own tiny door rather than every caller carrying a second search_path.
create or replace function public._c1985_sha256(p_text text)
returns text language sql immutable security definer
set search_path to 'public','extensions' as $$
  select encode(digest(convert_to(coalesce(p_text,''),'UTF8'), 'sha256'), 'hex')
$$;

-- The resolved document for ONE partner and ONE version: clause list, the flat
-- text a signature snapshots, and the sha256 that proves it did not drift.
create or replace function public.agreement_render(p_version_id bigint, p_partner_id bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v public.partner_agreement_version%rowtype;
  tok jsonb := public.agreement_tokens(p_partner_id);
  v_rows jsonb := '[]'::jsonb; v_text text := ''; r record;
begin
  select * into v from public.partner_agreement_version where id = p_version_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_version',
      'message', public._c('partner_agree.none_published'));
  end if;

  for r in
    select c.id, c.n, c.heading, c.body, c.owner, c.editable_by_partner, c.required,
           o.body as override_body, o.id as override_id
      from public.agreement_clause c
      left join public.agreement_clause_override o
             on o.clause_id = c.id and o.partner_id = p_partner_id
     where c.version_id = p_version_id
     order by c.n
  loop
    declare
      v_head text := public.agreement_resolve(r.heading, tok);
      v_body text := public.agreement_resolve(coalesce(nullif(r.override_body,''), r.body), tok);
    begin
      v_rows := v_rows || jsonb_build_object(
        'clause_id', r.id, 'n', r.n, 'heading', v_head, 'body', v_body,
        'owner', r.owner, 'editable_by_partner', r.editable_by_partner,
        'required', r.required, 'is_negotiated', r.override_id is not null,
        'raw_body', coalesce(nullif(r.override_body,''), r.body));
      v_text := v_text || r.n::text || '. ' || v_head || E'\n' || v_body || E'\n\n';
    end;
  end loop;

  -- A version with no clause rows still renders — its legacy prose body is one
  -- unnumbered clause, so nothing that was signed before this change is lost.
  if jsonb_array_length(v_rows) = 0 and coalesce(v.body,'') <> '' then
    v_text := public.agreement_resolve(v.body, tok);
    v_rows := jsonb_build_array(jsonb_build_object(
      'clause_id', null, 'n', 1, 'heading', coalesce(v.title,''), 'body', v_text,
      'owner','admin','editable_by_partner', false, 'required', true,
      'is_negotiated', false, 'raw_body', coalesce(v.body,'')));
  end if;

  v_text := btrim(v_text);
  return jsonb_build_object('ok', true,
    'version_id', v.id, 'version', v.version,
    'title', public.agreement_resolve(coalesce(v.title,''), tok),
    'status', v.status,
    'effective_from', v.effective_from,
    'effective_to', v.effective_to,
    'renew_before_days', v.renew_before_days,
    'clauses', v_rows,
    'tokens', tok,
    'terms', public.agreement_terms(p_partner_id),
    'full_text', v_text,
    'sha256', public._c1985_sha256(v_text));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. WHICH VERSION IS CURRENT — now a VALIDITY WINDOW, not just a flag.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._c692_current_version()
returns public.partner_agreement_version
language sql stable security definer set search_path to 'public' as $$
  select * from public.partner_agreement_version
   where status = 'published'
     and effective_from <= current_date
     and (effective_to is null or effective_to >= current_date)
   order by version desc limit 1
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. ADMIN: the version list, clause-by-clause editing, publish, retire.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.agreement_admin_versions(p_version_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_rows jsonb; v_total int; v_sel bigint := p_version_id; v_clauses jsonb;
  v_props jsonb; v_zone smallint := public.admin_active_zone();
begin
  if public.role_for_medibo_only() <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('partner_agree.err_not_authorized'));
  end if;

  -- Zone-scoped like every other admin list: a zone-pinned super admin counts
  -- the partners of THAT zone, an unpinned one counts them all.
  select count(*) into v_total from public.region_partners rp
   where coalesce(rp.is_active,false)
     and (v_zone is null or rp.zone_id = v_zone);

  select coalesce(jsonb_agg(x order by (x->>'version')::int desc), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
        'id', v.id, 'version', v.version,
        'title', coalesce(v.title,''),
        'status', v.status,
        'status_label', public._c('partner_agree.st_' || v.status),
        'status_tone', case v.status when 'published' then 'success'
                                     when 'retired' then 'neutral' else 'warning' end,
        'effective_from', v.effective_from,
        'effective_to', v.effective_to,
        'renew_before_days', v.renew_before_days,
        'version_label', public._cf('partner_agree.version_label', jsonb_build_object(
            'v', v.version::text, 'd', to_char(v.effective_from,'DD/MM/YYYY'))),
        'validity_label', case when v.effective_to is null
            then public._c('partner_agree.valid_open')
            else public._cf('partner_agree.valid_to', jsonb_build_object(
                   'd', to_char(v.effective_to,'DD/MM/YYYY'))) end,
        'clause_count', (select count(*) from public.agreement_clause c where c.version_id = v.id),
        'signed_count', (select count(*) from public.partner_agreement_signature s
                          where s.version_id = v.id and s.status = 'signed'),
        'signed_label', public._cf('partner_agree.signed_count', jsonb_build_object(
            'n', (select count(*) from public.partner_agreement_signature s
                   where s.version_id = v.id and s.status='signed')::text,
            't', v_total::text))
      ) as x
      from public.partner_agreement_version v
    ) z;

  v_sel := coalesce(v_sel, (public._c692_current_version()).id,
                    (select id from public.partner_agreement_version order by version desc limit 1));

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'n', c.n, 'heading', c.heading, 'body', c.body,
           'owner', c.owner,
           'owner_label', public._c('partner_agree.owner_' || c.owner),
           'editable_by_partner', c.editable_by_partner,
           'required', c.required,
           'flags_label', concat_ws(' · ',
              case when c.editable_by_partner then public._c('partner_agree.flag_editable') end,
              case when c.required then public._c('partner_agree.flag_required')
                   else public._c('partner_agree.flag_optional') end)
         ) order by c.n), '[]'::jsonb)
    into v_clauses from public.agreement_clause c where c.version_id = v_sel;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'clause_id', p.clause_id, 'partner_id', p.partner_id,
           'partner_name', coalesce(rp.partner_name,''),
           'clause_n', c.n, 'clause_heading', c.heading,
           'current_body', p.current_body, 'proposed_body', p.proposed_body,
           'note', p.note, 'status', p.status,
           'status_label', public._c('partner_agree.prop_' || p.status),
           'status_tone', case p.status when 'approved' then 'success'
                                        when 'rejected' then 'danger'
                                        when 'pending' then 'warning' else 'neutral' end,
           'decision_reason', p.decision_reason,
           'raised_label', public._cf('partner_agree.prop_raised', jsonb_build_object(
              'who', coalesce(rp.partner_name,''), 'd', public.ist_fmt(p.created_at,'dmy_hm')))
         ) order by p.id desc), '[]'::jsonb)
    into v_props
    from public.agreement_clause_proposal p
    join public.agreement_clause c on c.id = p.clause_id
    join public.region_partners rp on rp.id = p.partner_id
   where (v_zone is null or rp.zone_id = v_zone)
     and p.status = 'pending';

  return jsonb_build_object('ok', true,
    'heading', public._c('partner_agree.admin_heading'),
    'sub', public._c('partner_agree.admin_sub'),
    'new_label', public._c('partner_agree.admin_new'),
    'publish_label', public._c('partner_agree.admin_publish'),
    'retire_label', public._c('partner_agree.admin_retire'),
    'clause_heading', public._c('partner_agree.clause_heading'),
    'clause_new_label', public._c('partner_agree.clause_new'),
    'clause_empty', public._c('partner_agree.clause_empty'),
    'save_label', public._c('partner_agree.save'),
    'valid_from_hint', public._c('partner_agree.valid_from_hint'),
    'valid_to_hint', public._c('partner_agree.valid_to_hint'),
    'renew_hint', public._c('partner_agree.renew_hint'),
    'title_hint', public._c('partner_agree.title_hint'),
    'clause_n_hint', public._c('partner_agree.clause_n_hint'),
    'clause_head_hint', public._c('partner_agree.clause_head_hint'),
    'clause_body_hint', public._c('partner_agree.clause_body_hint'),
    'clause_save_label', public._c('partner_agree.clause_save'),
    'clause_delete_label', public._c('partner_agree.clause_delete'),
    'flag_editable_label', public._c('partner_agree.flag_editable'),
    'flag_required_label', public._c('partner_agree.flag_required'),
    'token_help', public._c('partner_agree.token_help'),
    'tokens', jsonb_build_array('operator','operator_udyam','operator_gstin','partner',
       'partner_gstin','partner_dl20b','partner_dl21b','partner_address','zone',
       'split_pct','cadence','exit_notice_days'),
    'proposals_heading', public._c('partner_agree.prop_heading'),
    'proposals_empty', public._c('partner_agree.prop_empty'),
    'approve_label', public._c('partner_agree.prop_approve'),
    'reject_label', public._c('partner_agree.prop_reject'),
    'reason_hint', public._c('partner_agree.prop_reason_hint'),
    'rows', v_rows,
    'selected_id', v_sel,
    'clauses', v_clauses,
    'proposals', v_props,
    'partner_total', v_total,
    'zone_id', v_zone,
    'current_version', (public._c692_current_version()).version);
end $$;

create or replace function public.agreement_version_save(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_id bigint := nullif(p->>'id','')::bigint;
  v_title text := btrim(coalesce(p->>'title',''));
  v_from date := coalesce(nullif(p->>'effective_from','')::date, current_date);
  v_to   date := nullif(p->>'effective_to','')::date;
  v_renew int := coalesce(nullif(p->>'renew_before_days','')::int, 30);
  v_ver int; row public.partner_agreement_version%rowtype;
begin
  if public.role_for_medibo_only() <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('partner_agree.err_not_authorized'));
  end if;
  if v_to is not null and v_to < v_from then
    return jsonb_build_object('ok', false, 'error','bad_dates', 'tone','danger',
      'message', public._c('partner_agree.err_dates'));
  end if;

  if v_id is not null then
    select * into row from public.partner_agreement_version where id = v_id;
    -- Published text is frozen. Editing one forks a DRAFT rather than rewriting
    -- prose a partner has already signed.
    if not found or row.status <> 'draft' then v_id := null; end if;
  end if;

  if v_id is null then
    select coalesce(max(version),0) + 1 into v_ver from public.partner_agreement_version;
    insert into public.partner_agreement_version(version, title, body, effective_from,
             effective_to, renew_before_days, status, created_by, updated_by)
    values (v_ver, v_title, '', v_from, v_to, v_renew, 'draft',
            coalesce(public.my_login_email(),'admin'), coalesce(public.my_login_email(),'admin'))
    returning * into row;

    -- A new draft starts as a COPY of the newest version's clauses, so the
    -- office edits a document rather than retyping one.
    insert into public.agreement_clause(version_id, n, heading, body, owner, editable_by_partner, required)
    select row.id, c.n, c.heading, c.body, c.owner, c.editable_by_partner, c.required
      from public.agreement_clause c
     where c.version_id = (select id from public.partner_agreement_version
                            where id <> row.id order by version desc limit 1);
  else
    update public.partner_agreement_version
       set title = v_title, effective_from = v_from, effective_to = v_to,
           renew_before_days = v_renew, updated_by = coalesce(public.my_login_email(),'admin')
     where id = v_id returning * into row;
  end if;

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('partner_agree.admin_saved'),
    'version_id', row.id,
    'state', public.agreement_admin_versions(row.id));
end $$;

create or replace function public.agreement_clause_save(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_id bigint := nullif(p->>'id','')::bigint;
  v_ver bigint := nullif(p->>'version_id','')::bigint;
  v_n int := nullif(p->>'n','')::int;
  v_status text;
begin
  if public.role_for_medibo_only() <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('partner_agree.err_not_authorized'));
  end if;
  if v_id is not null then
    select c.version_id into v_ver from public.agreement_clause c where c.id = v_id;
  end if;
  select status into v_status from public.partner_agreement_version where id = v_ver;
  if v_status is null then
    return jsonb_build_object('ok', false, 'error','no_version', 'tone','danger',
      'message', public._c('partner_agree.none_published'));
  end if;
  if v_status <> 'draft' then
    return jsonb_build_object('ok', false, 'error','not_draft', 'tone','danger',
      'message', public._c('partner_agree.err_not_draft'));
  end if;

  if coalesce(p->>'delete','') = 'true' and v_id is not null then
    delete from public.agreement_clause where id = v_id;
  elsif v_id is null then
    select coalesce(max(n),0) + 1 into v_n from public.agreement_clause where version_id = v_ver;
    insert into public.agreement_clause(version_id, n, heading, body, owner,
             editable_by_partner, required)
    values (v_ver, coalesce(nullif(p->>'n','')::int, v_n),
            btrim(coalesce(p->>'heading','')), coalesce(p->>'body',''),
            coalesce(nullif(p->>'owner',''),'admin'),
            coalesce((p->>'editable_by_partner')::boolean, false),
            coalesce((p->>'required')::boolean, true));
  else
    update public.agreement_clause
       set heading = btrim(coalesce(p->>'heading', heading)),
           body = coalesce(p->>'body', body),
           owner = coalesce(nullif(p->>'owner',''), owner),
           editable_by_partner = coalesce((p->>'editable_by_partner')::boolean, editable_by_partner),
           required = coalesce((p->>'required')::boolean, required),
           n = coalesce(nullif(p->>'n','')::int, n),
           updated_at = now()
     where id = v_id;
  end if;

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('partner_agree.clause_saved'),
    'state', public.agreement_admin_versions(v_ver));
end $$;

-- Publishing asks EVERY active partner to sign: the old signature stays as
-- history, and the card's status flips to 're-sign' by itself because the
-- current version moved.
create or replace function public.agreement_version_publish(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_id bigint := nullif(p->>'id','')::bigint;
  row public.partner_agreement_version%rowtype;
begin
  if public.role_for_medibo_only() <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('partner_agree.err_not_authorized'));
  end if;
  select * into row from public.partner_agreement_version where id = v_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_version', 'tone','danger',
      'message', public._c('partner_agree.none_published'));
  end if;
  if not exists (select 1 from public.agreement_clause where version_id = row.id)
     and coalesce(row.body,'') = '' then
    return jsonb_build_object('ok', false, 'error','no_clauses', 'tone','danger',
      'message', public._c('partner_agree.err_no_clauses'));
  end if;

  -- The version that was current stops being current the moment this one is.
  update public.partner_agreement_version
     set status = 'retired', effective_to = least(coalesce(effective_to, row.effective_from - 1),
                                                  row.effective_from - 1)
   where status = 'published' and id <> row.id;

  update public.partner_agreement_version set status = 'published' where id = row.id
    returning * into row;

  perform public.agreement_resign_ask(rp.id, public._cf('partner_agree.ask_published',
            jsonb_build_object('v', row.version::text)))
     from public.region_partners rp where coalesce(rp.is_active,false);

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._cf('partner_agree.admin_published',
                 jsonb_build_object('v', row.version::text)),
    'state', public.agreement_admin_versions(row.id));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. THE ASK — one place that records "this partner owes us a signature", so
--    the reminder cron, the auto-void trigger and publishing all speak once.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.agreement_resign_ask(p_partner_id bigint, p_why text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare rp public.region_partners%rowtype;
begin
  select * into rp from public.region_partners where id = p_partner_id;
  if not found then return; end if;

  insert into public.partner_audit_log(partner_id, user_id, feature_key, action, detail)
  values (p_partner_id, auth.uid(), 'partner.documents', 'agreement_resign_asked',
          jsonb_build_object('why', p_why, 'summary', p_why));

  -- A missing notification route must never stall the caller that asked.
  begin
    perform public.notify_partner('partner_agreement_resign', jsonb_build_object(
      'partner_id', p_partner_id::text,
      'partner', coalesce(rp.partner_name,''),
      'why', p_why,
      'title', public._c('partner_agree.resign_title'),
      'body', p_why));
  exception when others then null;
  end;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. AUTO-VOID — the whole reason signature 5 had to be deleted by hand.
--     A change to the entity on the agreement makes every signature that names
--     the OLD entity untrue, so it is voided and a fresh one is asked for.
--
--     Lesson 195: this trigger is region_partners' OWN, it shares its body with
--     nothing, and it never reads a column region_partners does not have.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._c1985_partner_identity_void() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare
  v_changed text[] := '{}';
  v_n int := 0;
  v_why text;
begin
  if coalesce(new.partner_name,'') is distinct from coalesce(old.partner_name,'') then
    v_changed := v_changed || public._c('partner_agree.f_partner_name');
  end if;
  if coalesce(new.gstin,'') is distinct from coalesce(old.gstin,'') then
    v_changed := v_changed || public._c('partner_agree.f_gstin');
  end if;
  if coalesce(new.dl_20b,'') is distinct from coalesce(old.dl_20b,'') then
    v_changed := v_changed || public._c('partner_agree.f_dl20b');
  end if;
  if coalesce(new.dl_21b,'') is distinct from coalesce(old.dl_21b,'') then
    v_changed := v_changed || public._c('partner_agree.f_dl21b');
  end if;
  if array_length(v_changed, 1) is null then return new; end if;

  v_why := public._cf('partner_agree.void_reason', jsonb_build_object(
             'what', array_to_string(v_changed, ', ')));

  update public.partner_agreement_signature
     set status = 'void', voided_at = now(), void_reason = v_why, updated_at = now()
   where partner_id = new.id and status = 'signed';
  get diagnostics v_n = row_count;

  if v_n > 0 then
    update public.region_partners
       set agreement_doc_path = '', agreement_expiry = null
     where id = new.id;
    update public.partner_onboarding_state
       set done = false, value = '', updated_at = now()
     where partner_id = new.id and step_key = 'agreement';
    perform public.agreement_resign_ask(new.id, v_why);
  end if;
  return new;
end $$;

drop trigger if exists _c1985_partner_identity_void_trg on public.region_partners;
create trigger _c1985_partner_identity_void_trg
  after update of partner_name, gstin, dl_20b, dl_21b on public.region_partners
  for each row execute function public._c1985_partner_identity_void();

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. SIGNING — the snapshot is the RESOLVED text plus its hash.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.partner_agreement_sign_start(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public','net' as $$
declare
  v_admin boolean := public._c692_admin();
  v_pid bigint := public._c692_pid(nullif(p->>'partner_id','')::bigint);
  cur public.partner_agreement_version%rowtype;
  sig public.partner_agreement_signature%rowtype;
  v_name text := nullif(btrim(coalesce(p->>'signer_name','')),'');
  v_phone text; v_code text; v_doc jsonb;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_agree.err_no_partner'));
  end if;
  if not (v_admin or public.partner_can('partner.documents','write')) then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('partner_agree.err_not_authorized'));
  end if;
  cur := public._c692_current_version();
  if cur.id is null then
    return jsonb_build_object('ok', false, 'error','no_version', 'tone','danger',
      'message', public._c('partner_agree.none_published'));
  end if;
  if v_name is null then
    return jsonb_build_object('ok', false, 'error','no_name', 'tone','danger',
      'message', public._c('partner_agree.err_no_name'));
  end if;
  v_phone := public.identity_norm(coalesce(p->>'phone',''));
  if v_phone is null then
    return jsonb_build_object('ok', false, 'error','bad_phone', 'tone','danger',
      'message', public._c('partner_agree.err_bad_phone'));
  end if;

  select * into sig from public.partner_agreement_signature
   where partner_id = v_pid and version_id = cur.id;
  if sig.id is not null and sig.status = 'signed' then
    return jsonb_build_object('ok', false, 'error','already_signed', 'tone','info',
      'message', public._c('partner_agree.already_signed'),
      'card', public.partner_agreement_card(v_pid));
  end if;
  if sig.locked_until is not null and sig.locked_until > now() then
    return jsonb_build_object('ok', false, 'error','locked', 'tone','danger',
      'message', public._c('partner_agree.err_locked'));
  end if;
  if sig.sent_at is not null and sig.sent_at > now() - interval '30 seconds' then
    return jsonb_build_object('ok', false, 'error','too_soon', 'tone','warning',
      'message', public._c('partner_agree.err_too_soon'));
  end if;

  -- The text this partner is agreeing to, resolved for THIS partner, hashed now.
  v_doc := public.agreement_render(cur.id, v_pid);
  v_code := lpad((floor(random() * 1000000))::int::text, 6, '0');

  insert into public.partner_agreement_signature as t
    (partner_id, version_id, version, status, signer_name, signer_phone,
     body_snapshot, body_sha256, snapshot, terms,
     code_hash, sent_at, expires_at, attempts, locked_until, voided_at, void_reason, updated_at)
  values (v_pid, cur.id, cur.version, 'pending', v_name, v_phone,
          coalesce(v_doc->>'full_text',''), coalesce(v_doc->>'sha256',''),
          coalesce(v_doc->'clauses','[]'::jsonb), coalesce(v_doc->'terms','{}'::jsonb),
          md5(v_phone || ':' || v_code), now(), now() + interval '10 minutes',
          0, null, null, '', now())
  on conflict (partner_id, version_id) do update
    set signer_name = excluded.signer_name, signer_phone = excluded.signer_phone,
        body_snapshot = excluded.body_snapshot, body_sha256 = excluded.body_sha256,
        snapshot = excluded.snapshot, terms = excluded.terms,
        status = 'pending', voided_at = null, void_reason = '',
        code_hash = excluded.code_hash, sent_at = excluded.sent_at,
        expires_at = excluded.expires_at, attempts = 0, locked_until = null,
        updated_at = now();

  perform net.http_post(
    url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/login-otp',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-login-secret','medibo_login_otp_2027'),
    body := jsonb_build_object('mode','send','phone', v_phone, 'code', v_code));

  insert into public.partner_audit_log(partner_id, user_id, feature_key, action, detail)
  values (v_pid, auth.uid(), 'partner.documents', 'agreement_otp_sent',
          jsonb_build_object('version', cur.version, 'signer', v_name,
            'sha256', coalesce(v_doc->>'sha256',''),
            'summary', 'Agreement e-sign code sent to ' || v_name));

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('partner_agree.otp_sent'),
    'card', public.partner_agreement_card(v_pid));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 12. PROPOSALS — a partner edits only what the clause allows, and nothing is
--     live until mediBO says so, with a reason, both logged.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.agreement_proposal_raise(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_pid bigint := public._c692_pid(nullif(p->>'partner_id','')::bigint);
  v_clause bigint := nullif(p->>'clause_id','')::bigint;
  c public.agreement_clause%rowtype;
  v_body text := btrim(coalesce(p->>'proposed_body',''));
  tok jsonb; v_cur text; v_id bigint;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_agree.err_no_partner'));
  end if;
  if not (public._c692_admin() or public.partner_can('partner.documents','write')) then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('partner_agree.err_not_authorized'));
  end if;
  select * into c from public.agreement_clause where id = v_clause;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_clause', 'tone','danger',
      'message', public._c('partner_agree.err_no_clause'));
  end if;
  if not c.editable_by_partner then
    return jsonb_build_object('ok', false, 'error','locked_clause', 'tone','danger',
      'message', public._c('partner_agree.err_clause_locked'));
  end if;
  if v_body = '' then
    return jsonb_build_object('ok', false, 'error','no_body', 'tone','danger',
      'message', public._c('partner_agree.err_body'));
  end if;

  tok := public.agreement_tokens(v_pid);
  select coalesce(nullif(o.body,''), c.body) into v_cur
    from public.agreement_clause cc
    left join public.agreement_clause_override o
           on o.clause_id = cc.id and o.partner_id = v_pid
   where cc.id = c.id;

  insert into public.agreement_clause_proposal(clause_id, version_id, partner_id,
           current_body, proposed_body, note, status, created_by)
  values (c.id, c.version_id, v_pid, coalesce(v_cur, c.body), v_body,
          btrim(coalesce(p->>'note','')), 'pending',
          coalesce(public.my_login_email(),'partner'))
  on conflict (clause_id, partner_id) where status = 'pending'
  do update set proposed_body = excluded.proposed_body, note = excluded.note,
                current_body = excluded.current_body, created_at = now()
  returning id into v_id;

  insert into public.partner_audit_log(partner_id, user_id, feature_key, action, detail)
  values (v_pid, auth.uid(), 'partner.documents', 'agreement_clause_proposed',
          jsonb_build_object('clause_id', c.id, 'clause_n', c.n, 'proposal_id', v_id,
            'summary', public._cf('partner_agree.prop_logged',
                          jsonb_build_object('n', c.n::text))));

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('partner_agree.prop_sent'),
    'proposal_id', v_id,
    'card', public.partner_agreement_card(v_pid));
end $$;

create or replace function public.agreement_proposal_decide(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_id bigint := nullif(p->>'id','')::bigint;
  v_ok boolean := coalesce((p->>'approve')::boolean, false);
  v_reason text := btrim(coalesce(p->>'reason',''));
  pr public.agreement_clause_proposal%rowtype;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('partner_agree.err_not_authorized'));
  end if;
  select * into pr from public.agreement_clause_proposal where id = v_id;
  if not found or pr.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error','not_pending', 'tone','warning',
      'message', public._c('partner_agree.err_not_pending'));
  end if;
  if not v_ok and v_reason = '' then
    return jsonb_build_object('ok', false, 'error','no_reason', 'tone','danger',
      'message', public._c('partner_agree.err_reason'));
  end if;

  update public.agreement_clause_proposal
     set status = case when v_ok then 'approved' else 'rejected' end,
         decided_at = now(), decided_by = coalesce(public.my_login_email(),'admin'),
         decision_reason = v_reason
   where id = pr.id;

  if v_ok then
    insert into public.agreement_clause_override(version_id, clause_id, partner_id, body, proposal_id)
    values (pr.version_id, pr.clause_id, pr.partner_id, pr.proposed_body, pr.id)
    on conflict (clause_id, partner_id)
    do update set body = excluded.body, proposal_id = excluded.proposal_id, created_at = now();

    -- The text changed, so the signature on the OLD text is no longer the deal.
    update public.partner_agreement_signature
       set status = 'void', voided_at = now(), updated_at = now(),
           void_reason = public._c('partner_agree.void_clause')
     where partner_id = pr.partner_id and status = 'signed';
    perform public.agreement_resign_ask(pr.partner_id,
              public._c('partner_agree.void_clause'));
  end if;

  insert into public.partner_audit_log(partner_id, user_id, feature_key, action, detail)
  values (pr.partner_id, auth.uid(), 'partner.documents',
          case when v_ok then 'agreement_clause_approved' else 'agreement_clause_rejected' end,
          jsonb_build_object('proposal_id', pr.id, 'clause_id', pr.clause_id,
            'reason', v_reason,
            'summary', case when v_ok then public._c('partner_agree.prop_approved_log')
                            else public._cf('partner_agree.prop_rejected_log',
                                   jsonb_build_object('why', v_reason)) end));

  return jsonb_build_object('ok', true, 'tone','success',
    'message', case when v_ok then public._c('partner_agree.prop_approved')
                    else public._c('partner_agree.prop_rejected') end,
    'state', public.agreement_admin_versions(pr.version_id));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 13. HEALTH + DIFF — the one line the partner card shows, and what changed
--     since this partner last signed.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.agreement_health(p_partner_id bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  rp public.region_partners%rowtype;
  cur public.partner_agreement_version%rowtype;
  sig public.partner_agreement_signature%rowtype;
  last_sig public.partner_agreement_signature%rowtype;
  v_state text; v_tone text; v_valid date; v_days int;
  v_pending int; v_grace int; v_blocked boolean := false; v_void text := '';
begin
  select * into rp from public.region_partners where id = p_partner_id;
  if not found then return jsonb_build_object('ok', false); end if;
  cur := public._c692_current_version();
  v_grace := coalesce((select (value #>> '{}')::int from public.app_settings
                        where key = 'agreement_grace_days'), 7);

  if cur.id is not null then
    select * into sig from public.partner_agreement_signature
     where partner_id = p_partner_id and version_id = cur.id;
  end if;
  -- "Have they ever signed?" must survive a VOID, or a partner whose name just
  -- changed reads as a brand-new partner who never agreed to anything — and the
  -- re-sign screen would have no previous version to diff against.
  select * into last_sig from public.partner_agreement_signature
   where partner_id = p_partner_id and status in ('signed','void')
     and signed_at is not null
   order by version desc, id desc limit 1;

  select count(*) into v_pending from public.agreement_clause_proposal
   where partner_id = p_partner_id and status = 'pending';

  v_valid := cur.effective_to;
  v_days  := case when v_valid is null then null else v_valid - current_date end;

  if cur.id is null then
    v_state := 'none'; v_tone := 'neutral';
  elsif sig.id is not null and sig.status = 'signed' then
    if v_days is not null and v_days <= coalesce(cur.renew_before_days,30) then
      v_state := 'renew'; v_tone := 'warning';
    else
      v_state := 'signed'; v_tone := 'success';
    end if;
  elsif last_sig.id is not null then
    v_state := 'resign'; v_tone := 'warning';
  else
    v_state := 'unsigned'; v_tone := 'danger';
  end if;
  if v_state = 'resign' and coalesce(last_sig.void_reason,'') <> '' then
    v_void := last_sig.void_reason;
  end if;

  -- Unsigned PAST GRACE is what stops the zone taking orders. Inside grace the
  -- partner is warned, never cut off — the same shape the KYC gate uses.
  if v_state in ('unsigned','resign') then
    v_blocked := coalesce(cur.effective_from, current_date) + v_grace < current_date;
  end if;

  return jsonb_build_object('ok', true,
    'partner_id', p_partner_id,
    'state', v_state, 'tone', v_tone,
    'blocked', v_blocked,
    'signed_version', coalesce(last_sig.version, 0),
    'current_version', coalesce(cur.version, 0),
    'valid_to', v_valid,
    'days_left', v_days,
    'pending_proposals', v_pending,
    'void_reason', v_void,
    'health_label', public._c('partner_agree.h_' || v_state),
    'health_line', public._cf('partner_agree.health_line', jsonb_build_object(
        'signed', case when last_sig.id is null then public._c('partner_agree.h_never')
                       else 'v' || last_sig.version::text end,
        'valid',  case when v_valid is null then public._c('partner_agree.valid_open')
                       else to_char(v_valid,'DD/MM/YYYY') end,
        'pending', case when v_void <> '' then public._c('partner_agree.h_resign')
                     when v_pending > 0
                     then public._cf('partner_agree.h_pending', jsonb_build_object('n', v_pending::text))
                     when v_state in ('unsigned','resign')
                     then public._c('partner_agree.h_' || v_state)
                     when v_state = 'renew'
                     then public._cf('partner_agree.h_renew_in',
                            jsonb_build_object('n', coalesce(v_days,0)::text))
                     else public._c('partner_agree.h_nothing') end)));
end $$;

-- What changed since this partner last signed: clause by clause, backend-worded.
create or replace function public.agreement_diff(p_partner_id bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  cur public.partner_agreement_version%rowtype;
  last_sig public.partner_agreement_signature%rowtype;
  v_new jsonb; v_rows jsonb := '[]'::jsonb; r jsonb; v_old text; v_n int;
  v_added int := 0; v_changed int := 0; v_removed int := 0; v_old_arr jsonb;
begin
  cur := public._c692_current_version();
  if cur.id is null then return jsonb_build_object('ok', false); end if;
  select * into last_sig from public.partner_agreement_signature
   where partner_id = p_partner_id and status in ('signed','void')
   order by version desc, id desc limit 1;

  v_new := coalesce(public.agreement_render(cur.id, p_partner_id)->'clauses','[]'::jsonb);
  v_old_arr := coalesce(last_sig.snapshot, '[]'::jsonb);

  for r in select * from jsonb_array_elements(v_new) loop
    v_n := (r->>'n')::int;
    select e->>'body' into v_old from jsonb_array_elements(v_old_arr) e
      where (e->>'n')::int = v_n limit 1;
    if v_old is null then
      v_added := v_added + 1;
      v_rows := v_rows || jsonb_build_object('n', v_n, 'heading', r->>'heading',
        'kind','added', 'kind_label', public._c('partner_agree.d_added'),
        'tone','success', 'old','', 'new', r->>'body');
    elsif v_old is distinct from (r->>'body') then
      v_changed := v_changed + 1;
      v_rows := v_rows || jsonb_build_object('n', v_n, 'heading', r->>'heading',
        'kind','changed', 'kind_label', public._c('partner_agree.d_changed'),
        'tone','warning', 'old', v_old, 'new', r->>'body');
    end if;
  end loop;

  for r in select * from jsonb_array_elements(v_old_arr) loop
    if not exists (select 1 from jsonb_array_elements(v_new) e
                    where (e->>'n')::int = (r->>'n')::int) then
      v_removed := v_removed + 1;
      v_rows := v_rows || jsonb_build_object('n', (r->>'n')::int, 'heading', r->>'heading',
        'kind','removed', 'kind_label', public._c('partner_agree.d_removed'),
        'tone','danger', 'old', r->>'body', 'new','');
    end if;
  end loop;

  return jsonb_build_object('ok', true,
    'heading', public._c('partner_agree.diff_heading'),
    'from_version', coalesce(last_sig.version, 0),
    'to_version', cur.version,
    'has_previous', last_sig.id is not null,
    'empty_label', public._c('partner_agree.diff_empty'),
    'summary_label', public._cf('partner_agree.diff_summary', jsonb_build_object(
        'a', v_added::text, 'c', v_changed::text, 'r', v_removed::text)),
    'rows', (select coalesce(jsonb_agg(x order by (x->>'n')::int), '[]'::jsonb)
               from jsonb_array_elements(v_rows) x));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 14. VERIFY — records the hash, and stamps the partner's agreement_expiry from
--     the version's own validity so the existing licence sweep can see it.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.partner_agreement_sign_verify(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public','net' as $$
declare
  v_admin boolean := public._c692_admin();
  v_pid bigint := public._c692_pid(nullif(p->>'partner_id','')::bigint);
  cur public.partner_agreement_version%rowtype;
  sig public.partner_agreement_signature%rowtype;
  v_code text := btrim(coalesce(p->>'code',''));
  v_ip text := left(btrim(coalesce(p->>'ip','')), 64);
  v_agent text := left(btrim(coalesce(p->>'user_agent','')), 240);
  v_doc jsonb; v_fresh jsonb;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_agree.err_no_partner'));
  end if;
  if not (v_admin or public.partner_can('partner.documents','write')) then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('partner_agree.err_not_authorized'));
  end if;
  cur := public._c692_current_version();
  if cur.id is null then
    return jsonb_build_object('ok', false, 'error','no_version', 'tone','danger',
      'message', public._c('partner_agree.none_published'));
  end if;
  select * into sig from public.partner_agreement_signature
   where partner_id = v_pid and version_id = cur.id;
  if sig.id is null then
    return jsonb_build_object('ok', false, 'error','no_request', 'tone','danger',
      'message', public._c('partner_agree.err_expired'));
  end if;
  if sig.status = 'signed' then
    return jsonb_build_object('ok', false, 'error','already_signed', 'tone','info',
      'message', public._c('partner_agree.already_signed'),
      'card', public.partner_agreement_card(v_pid));
  end if;
  if sig.locked_until is not null and sig.locked_until > now() then
    return jsonb_build_object('ok', false, 'error','locked', 'tone','danger',
      'message', public._c('partner_agree.err_locked'));
  end if;
  if coalesce(sig.expires_at, now()) <= now() then
    return jsonb_build_object('ok', false, 'error','expired', 'tone','danger',
      'message', public._c('partner_agree.err_expired'));
  end if;
  if sig.code_hash is null
     or sig.code_hash <> md5(coalesce(sig.signer_phone,'') || ':' || v_code) then
    update public.partner_agreement_signature
       set attempts = attempts + 1,
           locked_until = case when attempts + 1 >= 5
                               then now() + interval '15 minutes' else locked_until end,
           updated_at = now()
     where id = sig.id;
    return jsonb_build_object('ok', false, 'error','bad_code', 'tone','danger',
      'message', public._c('partner_agree.err_bad_code'),
      'card', public.partner_agreement_card(v_pid));
  end if;

  -- Re-resolve at the instant of signing: the snapshot must be the text as it
  -- stands NOW, not as it stood when the code was sent ten minutes ago.
  v_fresh := public.agreement_render(cur.id, v_pid);

  update public.partner_agreement_signature
     set status = 'signed', signed_at = now(), signed_by = auth.uid(),
         signed_ip = v_ip, signed_agent = v_agent,
         body_snapshot = coalesce(v_fresh->>'full_text',''),
         body_sha256 = coalesce(v_fresh->>'sha256',''),
         snapshot = coalesce(v_fresh->'clauses','[]'::jsonb),
         terms = coalesce(v_fresh->'terms','{}'::jsonb),
         voided_at = null, void_reason = '',
         code_hash = null, attempts = 0, locked_until = null, updated_at = now()
   where id = sig.id
   returning * into sig;

  update public.region_partners
     set agreement_doc_path = coalesce(nullif(agreement_doc_path,''),
                                       'signature:' || sig.id::text),
         agreement_expiry = cur.effective_to,
         updated_at = now()
   where id = v_pid;

  insert into public.partner_onboarding_state(partner_id, step_key, done, value, updated_by)
  values (v_pid, 'agreement', true, 'v' || cur.version::text,
          coalesce(public.my_login_email(),'partner'))
  on conflict (partner_id, step_key) do update
    set done = true, value = excluded.value, updated_at = now(),
        updated_by = excluded.updated_by;

  insert into public.partner_audit_log(partner_id, user_id, feature_key, action, detail)
  values (v_pid, auth.uid(), 'partner.documents', 'agreement_signed',
          jsonb_build_object('version', cur.version, 'signer', sig.signer_name,
            'ip', v_ip, 'sha256', coalesce(sig.body_sha256,''),
            'summary', 'Agreement v' || cur.version::text || ' signed by ' || sig.signer_name));

  begin
    v_doc := public.partner_doc_request('agreement', sig.id::text);
  exception when others then v_doc := null;
  end;

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('partner_agree.signed_toast'),
    'doc', v_doc,
    'card', public.partner_agreement_card(v_pid),
    'golive', public.partner_golive_state(v_pid));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 15. THE CARD — now a living document: resolved clauses, a health line, the
--     diff since the partner last signed, and their own proposals.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.partner_agreement_card(p_partner_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_admin boolean := public._c692_admin();
  v_pid bigint := public._c692_pid(p_partner_id);
  rp public.region_partners%rowtype;
  cur public.partner_agreement_version%rowtype;
  sig public.partner_agreement_signature%rowtype;
  last_sig public.partner_agreement_signature%rowtype;
  v_can_sign boolean; v_doc jsonb; v_health jsonb; v_status text; v_props jsonb;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_agree.err_no_partner'));
  end if;
  select * into rp from public.region_partners where id = v_pid;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_agree.err_no_partner'));
  end if;

  cur := public._c692_current_version();
  select * into last_sig from public.partner_agreement_signature
   where partner_id = v_pid and status = 'signed' order by version desc limit 1;
  if cur.id is not null then
    select * into sig from public.partner_agreement_signature
     where partner_id = v_pid and version_id = cur.id;
    v_doc := public.agreement_render(cur.id, v_pid);
  end if;

  v_health := public.agreement_health(v_pid);
  v_status := coalesce(v_health->>'state','none');
  v_can_sign := v_admin or public.partner_can('partner.documents','write');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'clause_id', p.clause_id, 'clause_n', c.n,
           'heading', c.heading, 'proposed_body', p.proposed_body,
           'status', p.status,
           'status_label', public._c('partner_agree.prop_' || p.status),
           'status_tone', case p.status when 'approved' then 'success'
                                        when 'rejected' then 'danger'
                                        when 'pending' then 'warning' else 'neutral' end,
           'decision_reason', p.decision_reason
         ) order by p.id desc), '[]'::jsonb)
    into v_props
    from public.agreement_clause_proposal p
    join public.agreement_clause c on c.id = p.clause_id
   where p.partner_id = v_pid and p.status in ('pending','rejected');

  return jsonb_build_object('ok', true,
    'partner_id', v_pid,
    'partner_name', coalesce(rp.partner_name,''),
    'heading', public._c('partner_agree.heading'),
    'sub',     public._c('partner_agree.sub'),
    'has_version', cur.id is not null,
    'version', cur.version,
    'version_label', case when cur.id is null then ''
      else public._cf('partner_agree.version_label', jsonb_build_object(
             'v', cur.version::text, 'd', to_char(cur.effective_from,'DD/MM/YYYY'))) end,
    'validity_label', case when cur.id is null then ''
      when cur.effective_to is null then public._c('partner_agree.valid_open')
      else public._cf('partner_agree.valid_to', jsonb_build_object(
             'd', to_char(cur.effective_to,'DD/MM/YYYY'))) end,
    'title', coalesce(v_doc->>'title',''),
    'body',  coalesce(v_doc->>'full_text',''),
    'clauses', coalesce(v_doc->'clauses','[]'::jsonb),
    'terms_heading', public._c('partner_agree.terms_heading'),
    'terms_rows', case when v_doc is null then '[]'::jsonb else jsonb_build_array(
        jsonb_build_object('label', public._c('partner_agree.t_split'),
                           'value', (v_doc->'tokens'->>'split_pct') || '%'),
        jsonb_build_object('label', public._c('partner_agree.t_cadence'),
                           'value', v_doc->'tokens'->>'cadence'),
        jsonb_build_object('label', public._c('partner_agree.t_exit'),
                           'value', public._cf('partner_agree.t_exit_value', jsonb_build_object(
                              'n', v_doc->'tokens'->>'exit_notice_days')))) end,
    'health', v_health,
    'health_line', coalesce(v_health->>'health_line',''),
    'health_tone', coalesce(v_health->>'tone','neutral'),
    'status', v_status,
    'status_label', coalesce(v_health->>'health_label',''),
    'status_tone', coalesce(v_health->>'tone','neutral'),
    'is_signed', v_status in ('signed','renew'),
    'needs_signature', v_status in ('unsigned','resign'),
    'can_sign', v_can_sign and v_status in ('unsigned','resign','renew'),
    'sign_label', case when v_status in ('resign','renew')
                       then public._c('partner_agree.resign_cta')
                       else public._c('partner_agree.sign_label') end,
    'diff', case when v_status in ('resign','renew') then public.agreement_diff(v_pid)
                 else jsonb_build_object('ok', false) end,
    'proposals', v_props,
    'proposals_heading', public._c('partner_agree.prop_mine_heading'),
    'propose_label', public._c('partner_agree.prop_cta'),
    'propose_hint', public._c('partner_agree.prop_hint'),
    'propose_note_hint', public._c('partner_agree.prop_note_hint'),
    'void_reason', coalesce((select s.void_reason from public.partner_agreement_signature s
                              where s.partner_id = v_pid and s.status = 'void'
                              order by s.updated_at desc limit 1), ''),
    'name_hint',   public._c('partner_agree.name_hint'),
    'phone_hint',  public._c('partner_agree.phone_hint'),
    'code_hint',   public._c('partner_agree.code_hint'),
    'send_label',  public._c('partner_agree.send_label'),
    'verify_label',public._c('partner_agree.verify_label'),
    'awaiting_code', sig.id is not null and sig.status = 'pending'
                     and sig.code_hash is not null and coalesce(sig.expires_at, now()) > now(),
    'signed_line', case when sig.id is null or sig.status <> 'signed' then ''
      else public._cf('partner_agree.signed_by', jsonb_build_object(
             'name', sig.signer_name, 'd', public.ist_fmt(sig.signed_at,'dmy_hm'))) end,
    'signed_ip_line', case when sig.id is null or sig.status <> 'signed'
                                or coalesce(sig.signed_ip,'') = '' then ''
      else public._cf('partner_agree.signed_ip', jsonb_build_object('ip', sig.signed_ip)) end,
    'hash_line', case when sig.id is null or coalesce(sig.body_sha256,'') = '' then ''
      else public._cf('partner_agree.hash_line',
             jsonb_build_object('h', left(sig.body_sha256, 16))) end,
    'doc_label', public._c('partner_agree.doc_label'),
    'has_doc', sig.id is not null and sig.status = 'signed' and coalesce(sig.doc_path,'') <> '',
    'doc_bucket', coalesce(sig.doc_bucket,''),
    'doc_path',   coalesce(sig.doc_path,''),
    'doc_id',     sig.doc_id,
    'doc_building', sig.id is not null and sig.status = 'signed'
                    and coalesce(sig.doc_path,'') = '',
    'doc_building_label', public._c('partner_agree.doc_building'),
    'prev_signed_version', last_sig.version);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 16. THE SWEEP — expiry and renew_before_days drive the WhatsApp reminder and
--     the re-sign ask, on the cron dispatcher that already runs every day.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.agreement_renewal_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  cur public.partner_agreement_version%rowtype;
  r record; v_sent int := 0; v_asked int := 0; v_blocked int := 0; h jsonb;
begin
  if public.test_clock_session() is not null then
    return jsonb_build_object('ok', true, 'skipped','test_clock');
  end if;
  cur := public._c692_current_version();

  for r in select rp.id, rp.partner_name from public.region_partners rp
            where coalesce(rp.is_active,false) loop
    h := public.agreement_health(r.id);
    if coalesce((h->>'ok')::boolean,false) = false then continue; end if;

    if h->>'state' = 'renew' then
      -- One reminder per (partner, expiry) — the same ledger the licence sweep
      -- uses, so a daily tick never becomes a daily nag.
      if not exists (select 1 from public.partner_licence_reminder m
                      where m.partner_id = r.id and m.kind = 'agreement_renew'
                        and m.expiry = (h->>'valid_to')::date) then
        begin
          perform public.notify_partner('partner_agreement_renew', jsonb_build_object(
            'partner_id', r.id::text, 'partner', coalesce(r.partner_name,''),
            'd', to_char((h->>'valid_to')::date,'DD/MM/YYYY'),
            'title', public._c('partner_agree.renew_title'),
            'body', public._cf('partner_agree.renew_body', jsonb_build_object(
                      'partner', coalesce(r.partner_name,''),
                      'd', to_char((h->>'valid_to')::date,'DD/MM/YYYY'),
                      'n', coalesce(h->>'days_left','0')))));
        exception when others then null;
        end;
        insert into public.partner_licence_reminder(partner_id, kind, expiry)
        values (r.id, 'agreement_renew', (h->>'valid_to')::date) on conflict do nothing;
        v_sent := v_sent + 1;
      end if;
    elsif h->>'state' in ('unsigned','resign') and cur.id is not null then
      if not exists (select 1 from public.partner_licence_reminder m
                      where m.partner_id = r.id and m.kind = 'agreement_sign'
                        and m.expiry = cur.effective_from) then
        perform public.agreement_resign_ask(r.id,
          public._cf('partner_agree.ask_unsigned',
            jsonb_build_object('v', cur.version::text)));
        insert into public.partner_licence_reminder(partner_id, kind, expiry)
        values (r.id, 'agreement_sign', cur.effective_from) on conflict do nothing;
        v_asked := v_asked + 1;
      end if;
    end if;

    if coalesce((h->>'blocked')::boolean,false) then v_blocked := v_blocked + 1; end if;
  end loop;

  return jsonb_build_object('ok', true, 'reminded', v_sent,
    'asked', v_asked, 'blocked_zones', v_blocked);
end $$;

insert into public.cron_task(name, ord, mode, work_sql, enabled, run_at_ist, dml, note)
values ('agreement-renewal-sweep', 538, 'poll',
        'select public.agreement_renewal_sweep();', true, '07:00:00', true,
        'CMD #1985 — agreement expiry + renew_before_days reminders and re-sign asks')
on conflict (name) do update
  set work_sql = excluded.work_sql, enabled = true, run_at_ist = excluded.run_at_ist,
      mode = excluded.mode, dml = excluded.dml, note = excluded.note;

-- ─────────────────────────────────────────────────────────────────────────────
-- 17. THE ZONE GATE — unsigned past grace stops that zone taking orders.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.agreement_zone_block(p_zone bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare rp public.region_partners%rowtype; h jsonb;
begin
  if p_zone is null then return jsonb_build_object('blocked', false); end if;
  select * into rp from public.region_partners
   where coalesce(is_active,false) and zone_id = p_zone order by id limit 1;
  if not found then return jsonb_build_object('blocked', false); end if;
  h := public.agreement_health(rp.id);
  return jsonb_build_object(
    'blocked', coalesce((h->>'blocked')::boolean, false),
    'partner_id', rp.id, 'state', h->>'state');
exception when others then
  return jsonb_build_object('blocked', false);
end $$;

-- The copy the session gate prints. One UPDATE changes the wording, never a deploy.
insert into public.app_settings(key, value)
values ('order_gate_copy', jsonb_build_object('zone_agreement', jsonb_build_object(
   'title','Ordering is paused in this area',
   'message','Our fulfilment partner for this area has not signed the current mediBO partner agreement. Ordering opens again as soon as it is signed.',
   'action_label','', 'action_route','',
   'short_label','Ordering paused')))
on conflict (key) do update
  set value = public.app_settings.value
      || jsonb_build_object('zone_agreement',
           coalesce(public.app_settings.value->'zone_agreement', excluded.value->'zone_agreement'));

insert into public.app_settings(key, value) values ('agreement_grace_days', to_jsonb(7))
on conflict (key) do nothing;

-- my_session_core() is the ONE place that decides can_place_order, and it is a
-- 250-line function half a dozen other commands are also editing. Copying it
-- into this migration would silently revert whichever of them lands first, so
-- the gate is SPLICED into whatever is live, idempotently, at exactly the point
-- the licence gate already occupies. If the anchor is ever gone the splice is a
-- no-op and the partner card still shows the block — it never half-applies.
do $$
declare v_src text; v_new text; v_anchor text; v_ins text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'my_session_core';
  if v_src is null or position('zone_agreement' in v_src) > 0 then return; end if;

  v_anchor := '  if v_reason = ''none'' then
    v_gate := jsonb_build_object(''has_blocker'', false, ''reason'',''none'',';
  if position(v_anchor in v_src) = 0 then return; end if;

  v_ins := '  -- CMD #1985 — a zone whose fulfilment partner has not signed the current
  -- agreement past the grace window stops taking orders, with the backend''s
  -- own sentence. The partner card names the same block.
  if v_reason = ''none'' then
    declare v_zb jsonb;
    begin
      v_zb := public.agreement_zone_block(public.my_zone_id()::bigint);
      if coalesce((v_zb->>''blocked'')::boolean, false) then
        v_can_order := false;
        v_reason := ''zone_agreement'';
      end if;
    exception when others then null;
    end;
  end if;

' || v_anchor;

  v_new := replace(v_src, v_anchor, v_ins);
  execute v_new;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 18. THE PDF — renders from the SNAPSHOT, and its footer reads the operator
--     from platform_identity instead of naming one firm forever.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._c692_agreement_doc_payload(p_sig_id bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  s public.partner_agreement_signature%rowtype;
  rp public.region_partners%rowtype;
  v public.partner_agreement_version%rowtype;
  pi public.platform_identity%rowtype;
  v_lines text[]; v_rows jsonb;
begin
  select * into s from public.partner_agreement_signature where id = p_sig_id;
  if not found or s.status <> 'signed' then
    return jsonb_build_object('ok', false, 'error','not_signed');
  end if;
  select * into rp from public.region_partners where id = s.partner_id;
  select * into v  from public.partner_agreement_version where id = s.version_id;
  select * into pi from public.platform_identity order by id limit 1;

  v_lines := public._c692_wrap(s.body_snapshot, 108);
  select coalesce(jsonb_agg(jsonb_build_object('t', l) order by i), '[]'::jsonb)
    into v_rows from unnest(v_lines) with ordinality as u(l, i);

  return jsonb_build_object('ok', true, 'doc', jsonb_build_object(
    'title', coalesce(nullif(v.title,''), public._c('partner_agree.heading')),
    'brand', coalesce(nullif(pi.platform_name,''), 'mediBO'),
    'subtitle', public._cf('partner_agree.version_label', jsonb_build_object(
        'v', s.version::text, 'd', to_char(v.effective_from,'DD/MM/YYYY'))),
    'header', jsonb_build_array(
      jsonb_build_object('label','Partner',  'value', coalesce(rp.partner_name,'')),
      jsonb_build_object('label','District', 'value', coalesce(rp.district,'')),
      jsonb_build_object('label','GSTIN',    'value', coalesce(rp.gstin,'')),
      jsonb_build_object('label','Signed by','value', s.signer_name),
      jsonb_build_object('label','Signed on','value', public.ist_fmt(s.signed_at,'dmy_hm')),
      jsonb_build_object('label','Mobile',   'value', coalesce(s.signer_phone,''))),
    'sections', jsonb_build_array(jsonb_build_object(
      'heading', '',
      'columns', jsonb_build_array(jsonb_build_object('key','t','label','','width', 523)),
      'rows', v_rows,
      'empty_label', '')),
    'totals', '[]'::jsonb,
    'notes', jsonb_build_array(
      public._cf('partner_agree.signed_by', jsonb_build_object(
        'name', s.signer_name, 'd', public.ist_fmt(s.signed_at,'dmy_hm'))),
      case when coalesce(s.signed_ip,'') = '' then null
           else public._cf('partner_agree.signed_ip', jsonb_build_object('ip', s.signed_ip)) end,
      case when coalesce(s.body_sha256,'') = '' then null
           else public._cf('partner_agree.hash_line',
                  jsonb_build_object('h', s.body_sha256)) end,
      'Accepted electronically with a one-time code sent to '
        || coalesce(s.signer_phone,'') || ' on WhatsApp.'),
    'footer', coalesce(nullif(pi.platform_name,''),'mediBO') || ' · '
              || coalesce(nullif(pi.operator_legal_name,''), nullif(pi.business_name,''), '')));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 19. COPY — every word this change puts on a screen. Changing wording is an
--     UPDATE here, never a deploy.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
 ('partner_agree.admin_sub',        '"Clauses carry tokens. Names, licences and commercial terms fill in from the partner''s own record when the agreement is rendered."'::jsonb),
 ('partner_agree.admin_retire',     '"Retire"'::jsonb),
 ('partner_agree.st_draft',         '"Draft"'::jsonb),
 ('partner_agree.st_published',     '"Published"'::jsonb),
 ('partner_agree.st_retired',       '"Retired"'::jsonb),
 ('partner_agree.valid_open',       '"No end date"'::jsonb),
 ('partner_agree.valid_to',         '"Valid to {d}"'::jsonb),
 ('partner_agree.clause_heading',   '"Clauses"'::jsonb),
 ('partner_agree.clause_new',       '"Add clause"'::jsonb),
 ('partner_agree.clause_empty',     '"No clauses yet. Add the first one."'::jsonb),
 ('partner_agree.clause_saved',     '"Clause saved."'::jsonb),
 ('partner_agree.token_help',       '"Type {{partner}} or {{split_pct}} instead of a name or a number — never the entity itself."'::jsonb),
 ('partner_agree.owner_admin',      '"mediBO"'::jsonb),
 ('partner_agree.owner_partner',    '"Partner"'::jsonb),
 ('partner_agree.flag_editable',    '"Partner may propose"'::jsonb),
 ('partner_agree.flag_required',    '"Required"'::jsonb),
 ('partner_agree.flag_optional',    '"Optional"'::jsonb),
 ('partner_agree.err_dates',        '"The end date cannot be before the start date."'::jsonb),
 ('partner_agree.err_not_draft',    '"This version is published. Make a new draft to change its clauses."'::jsonb),
 ('partner_agree.err_no_clauses',   '"Add at least one clause before publishing."'::jsonb),
 ('partner_agree.err_no_clause',    '"That clause is no longer part of the agreement."'::jsonb),
 ('partner_agree.err_clause_locked','"This clause is not open to changes."'::jsonb),
 ('partner_agree.err_not_pending',  '"That request has already been decided."'::jsonb),
 ('partner_agree.err_reason',       '"Give a reason so the partner knows why."'::jsonb),
 ('partner_agree.prop_heading',     '"Clause change requests"'::jsonb),
 ('partner_agree.prop_empty',       '"No partner has asked for a change."'::jsonb),
 ('partner_agree.prop_mine_heading','"My change requests"'::jsonb),
 ('partner_agree.prop_cta',         '"Propose a change"'::jsonb),
 ('partner_agree.prop_hint',        '"Your wording for this clause"'::jsonb),
 ('partner_agree.prop_note_hint',   '"Why you are asking (optional)"'::jsonb),
 ('partner_agree.prop_approve',     '"Approve"'::jsonb),
 ('partner_agree.prop_reject',      '"Reject"'::jsonb),
 ('partner_agree.prop_reason_hint', '"Reason"'::jsonb),
 ('partner_agree.prop_pending',     '"Waiting on mediBO"'::jsonb),
 ('partner_agree.prop_approved',    '"Approved. The partner has been asked to sign the updated agreement."'::jsonb),
 ('partner_agree.prop_rejected',    '"Rejected. The partner has been told why."'::jsonb),
 ('partner_agree.prop_withdrawn',   '"Withdrawn"'::jsonb),
 ('partner_agree.prop_sent',        '"Sent to mediBO. Nothing changes until it is approved."'::jsonb),
 ('partner_agree.prop_raised',      '"{who} · {d}"'::jsonb),
 ('partner_agree.prop_logged',      '"Asked for a change to clause {n}"'::jsonb),
 ('partner_agree.prop_approved_log','"Clause change approved"'::jsonb),
 ('partner_agree.prop_rejected_log','"Clause change rejected — {why}"'::jsonb),
 ('partner_agree.terms_heading',    '"Commercial terms"'::jsonb),
 ('partner_agree.t_split',          '"Partner share"'::jsonb),
 ('partner_agree.t_cadence',        '"Settlement"'::jsonb),
 ('partner_agree.t_exit',           '"Exit notice"'::jsonb),
 ('partner_agree.t_exit_value',     '"{n} days"'::jsonb),
 ('partner_agree.cadence_same_day', '"Same day"'::jsonb),
 ('partner_agree.cadence_weekly',   '"Weekly"'::jsonb),
 ('partner_agree.cadence_fortnightly','"Fortnightly"'::jsonb),
 ('partner_agree.cadence_monthly',  '"Monthly"'::jsonb),
 ('partner_agree.h_signed',         '"Signed"'::jsonb),
 ('partner_agree.h_renew',          '"Renewal due"'::jsonb),
 ('partner_agree.h_resign',         '"Needs a fresh signature"'::jsonb),
 ('partner_agree.h_unsigned',       '"Not signed"'::jsonb),
 ('partner_agree.h_none',           '"Nothing published"'::jsonb),
 ('partner_agree.h_never',          '"never"'::jsonb),
 ('partner_agree.h_nothing',        '"nothing pending"'::jsonb),
 ('partner_agree.h_pending',        '"{n} change request(s) with mediBO"'::jsonb),
 ('partner_agree.h_renew_in',       '"renewal due in {n} days"'::jsonb),
 ('partner_agree.health_line',      '"Signed {signed} · valid {valid} · {pending}"'::jsonb),
 ('partner_agree.hash_line',        '"Document fingerprint {h}"'::jsonb),
 ('partner_agree.diff_heading',     '"What changed since you signed"'::jsonb),
 ('partner_agree.diff_empty',       '"Nothing in the wording has changed."'::jsonb),
 ('partner_agree.diff_summary',     '"{a} added · {c} changed · {r} removed"'::jsonb),
 ('partner_agree.d_added',          '"New"'::jsonb),
 ('partner_agree.d_changed',        '"Changed"'::jsonb),
 ('partner_agree.d_removed',        '"Removed"'::jsonb),
 ('partner_agree.f_partner_name',   '"business name"'::jsonb),
 ('partner_agree.f_gstin',          '"GSTIN"'::jsonb),
 ('partner_agree.f_dl20b',          '"drug licence 20B"'::jsonb),
 ('partner_agree.f_dl21b',          '"drug licence 21B"'::jsonb),
 ('partner_agree.void_reason',      '"The {what} on this partner changed, so the earlier signature no longer describes the same firm. A fresh signature is needed."'::jsonb),
 ('partner_agree.void_clause',      '"A clause was changed for this partner, so the earlier signature no longer matches the agreement."'::jsonb),
 ('partner_agree.resign_title',     '"Please re-sign the mediBO partner agreement"'::jsonb),
 ('partner_agree.ask_published',    '"mediBO has published version {v} of the partner agreement. Please sign it in the app."'::jsonb),
 ('partner_agree.ask_unsigned',     '"Version {v} of the mediBO partner agreement is still unsigned. Ordering in your area pauses if it stays unsigned."'::jsonb),
 ('partner_agree.renew_title',      '"Your mediBO partner agreement is due for renewal"'::jsonb),
 ('partner_agree.renew_body',       '"{partner}: the partner agreement is valid to {d} — {n} days left. Please renew it in the app."'::jsonb),
 ('partner_agree.void_banner',      '"This agreement was voided"'::jsonb),
 ('partner_agree.save',             '"Save"'::jsonb),
 ('partner_agree.title_hint',       '"Document title"'::jsonb),
 ('partner_agree.valid_from_hint',  '"Valid from (YYYY-MM-DD)"'::jsonb),
 ('partner_agree.valid_to_hint',    '"Valid to (YYYY-MM-DD, blank for none)"'::jsonb),
 ('partner_agree.renew_hint',       '"Remind this many days before it expires"'::jsonb),
 ('partner_agree.clause_n_hint',    '"Clause number"'::jsonb),
 ('partner_agree.clause_head_hint', '"Clause heading"'::jsonb),
 ('partner_agree.clause_body_hint', '"Clause text — use {{partner}}, {{split_pct}} and the other tokens"'::jsonb),
 ('partner_agree.clause_save',      '"Save clause"'::jsonb),
 ('partner_agree.clause_delete',    '"Remove this clause"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ─────────────────────────────────────────────────────────────────────────────
-- 20. SEED — the current agreement becomes clauses, tokenised. Every entity
--     name that was TYPED into the old prose becomes a token, which is the
--     whole point: change the partner and the document follows.
-- ─────────────────────────────────────────────────────────────────────────────
do $$
declare v_id bigint; v_ver int;
begin
  select id into v_id from public.partner_agreement_version
   where status = 'published' order by version desc limit 1;

  if v_id is null then
    select coalesce(max(version),0) + 1 into v_ver from public.partner_agreement_version;
    insert into public.partner_agreement_version(version, title, body, effective_from,
             renew_before_days, status, created_by, updated_by)
    values (v_ver, 'mediBO Fulfilment Partner Agreement', '', current_date, 30,
            'published', 'cmd-1985', 'cmd-1985')
    returning id into v_id;
  end if;

  if not exists (select 1 from public.agreement_clause where version_id = v_id) then
    insert into public.agreement_clause(version_id, n, heading, body, owner, editable_by_partner, required) values
     (v_id, 1, 'Parties',
      'This agreement is made between {{operator}} (Udyam {{operator_udyam}}, GSTIN {{operator_gstin}}), which operates the mediBO platform, and {{partner}} (GSTIN {{partner_gstin}}), the fulfilment partner for {{zone}}.',
      'admin', false, true),
     (v_id, 2, 'Licences',
      '{{partner}} holds drug licence {{partner_dl20b}} (Form 20B) and {{partner_dl21b}} (Form 21B) and will keep both current for the whole term of this agreement. Every medicine ordered through mediBO in {{zone}} is sold, invoiced and supplied by {{partner}} under those licences.',
      'admin', false, true),
     (v_id, 3, 'What mediBO does',
      '{{operator}} provides the ordering platform, the catalogue, the customer relationship and the technology. {{operator}} does not buy, hold, sell or supply medicines.',
      'admin', false, true),
     (v_id, 4, 'What the partner does',
      '{{partner}} accepts orders placed in {{zone}}, picks and packs them, raises the tax invoice in its own name and delivers to the ordering pharmacy.',
      'admin', false, true),
     (v_id, 5, 'Commercial terms',
      'The partner''s share is {{split_pct}}% of the order value. Settlement runs {{cadence}}. These are the same figures mediBO settles on — the agreement and the payout read one record.',
      'admin', false, true),
     (v_id, 6, 'Service standards',
      '{{partner}} will accept or decline each order within the time shown in the app, and will keep the fill rate and on-time delivery agreed for {{zone}}.',
      'admin', true, true),
     (v_id, 7, 'Working hours',
      '{{partner}} will take and fulfil orders during the hours published for {{zone}} in the app.',
      'partner', true, false),
     (v_id, 8, 'Ending this agreement',
      'Either side may end this agreement by giving {{exit_notice_days}} days'' written notice. Orders already accepted by {{partner}} are fulfilled and settled in the normal way.',
      'admin', false, true),
     (v_id, 9, 'Governing law',
      'This agreement is governed by the laws of India. All amounts are in Indian Rupees.',
      'admin', false, true);
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 21. GRANTS + RLS. Reads are SECURITY DEFINER RPCs; the tables themselves stay
--     shut to anon and authenticated.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.agreement_clause           enable row level security;
alter table public.agreement_clause_proposal  enable row level security;
alter table public.agreement_clause_override  enable row level security;

grant execute on function public.agreement_admin_versions(bigint)   to authenticated;
grant execute on function public.agreement_version_save(jsonb)      to authenticated;
grant execute on function public.agreement_version_publish(jsonb)   to authenticated;
grant execute on function public.agreement_clause_save(jsonb)       to authenticated;
grant execute on function public.agreement_proposal_raise(jsonb)    to authenticated;
grant execute on function public.agreement_proposal_decide(jsonb)   to authenticated;
-- These four take a bare partner id and do NOT clamp it — they are the INSIDE
-- of partner_agreement_card()/agreement_admin_versions(), which clamp first.
-- Handing them to `authenticated` would let one partner read another partner's
-- negotiated clause text, so the door stays shut and the wrappers are the door.
revoke all on function public.agreement_health(bigint)         from authenticated, anon;
revoke all on function public.agreement_diff(bigint)           from authenticated, anon;
revoke all on function public.agreement_render(bigint, bigint) from authenticated, anon;
revoke all on function public.agreement_tokens(bigint)         from authenticated, anon;
revoke all on function public.agreement_terms(bigint)          from authenticated, anon;
revoke all on function public.agreement_resolve(text, jsonb)   from authenticated, anon;
revoke all on function public._c1985_sha256(text)              from authenticated, anon;
revoke all on function public.agreement_zone_block(bigint)     from authenticated, anon;
revoke all on function public.agreement_resign_ask(bigint, text) from authenticated, anon;
revoke all on function public.agreement_renewal_sweep()        from authenticated, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- 22. THE DOOR. Lesson 203: a route wired only in partnerDestination() is a
--     dead tile. handled_by reads 'home_shell' and the case lives in
--     shellExtraRouteScreen(), so the tap lands on the screen.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.feature_registry(
  feature_key, label, group_label, icon_key, route_key, sort_order, owner,
  partner_eligible, default_access, is_active, category, surface, roles_allowed,
  deep_link, description, canonical_key, test_entry, test_roles, test_steps,
  test_expect, test_automatable)
values (
  'admin.agreement_versions', 'Partner agreement', 'Partners', 'rule',
  'agreement_versions', 62, 'medibo', false, 'none', true,
  'home_partners', 'dashboard', array['super_admin'],
  '/admin/go/agreement_versions',
  'CMD #1985 — the partner agreement as a living document: clauses carrying {{tokens}}, versions with validity, and the clause changes partners have asked for.',
  'admin.agreement_versions', '/admin/go/agreement_versions',
  array['super_admin'],
  '[{"kind":"auth","role":"{role}"},{"kind":"goto","path":"/admin/go/agreement_versions"},{"ms":6000,"kind":"settle"}]'::jsonb,
  '{"key":"boot_status","kind":"visible","equals":"painted","source":"render_log"}'::jsonb,
  true)
on conflict (feature_key) do update
  set is_active = true, route_key = excluded.route_key, label = excluded.label,
      deep_link = excluded.deep_link, category = excluded.category,
      surface = excluded.surface, roles_allowed = excluded.roles_allowed;

update public.surface_route
   set feature_key = 'admin.agreement_versions', handled_by = 'home_shell', is_active = true
 where route_key = 'agreement_versions';
insert into public.surface_route(route_key, feature_key, kind, handled_by, note, is_active)
select 'agreement_versions', 'admin.agreement_versions', 'feature', 'home_shell',
       'CMD #1985 — Admin › Partner agreement, opened from shell/shell_extra_routes.dart',
       true
 where not exists (select 1 from public.surface_route where route_key = 'agreement_versions');

-- The partner's own door already exists (`partner_documents`); this only makes
-- sure the row still names the shared shell rather than the dead resolver.
update public.surface_route
   set handled_by = 'home_shell', is_active = true
 where route_key = 'partner_documents' and handled_by <> 'home_shell';

-- The ONE new RPC a partner calls directly. It resolves the partner from the
-- CALLER via _c692_pid(), so the row guard's clamp check is satisfied by the
-- same helper every other partner.documents RPC already uses.
do $$ begin
  if to_regclass('public.partner_rpc_allow') is not null then
    insert into public.partner_rpc_allow(proname, source, note)
    values ('agreement_proposal_raise', 'cmd-1985',
            'Partner proposes a change to a clause flagged editable_by_partner')
    on conflict (proname) do nothing;
  end if;
  begin perform public.partner_rpc_allow_refresh(); exception when others then null; end;
end $$;

-- CMD #1986 (Om, mid-build): "all fields in agreement should be editable no
-- hardcoded at all".
--
-- The first half of this change moved the agreement's WORDING out of Dart. This
-- half gives a super-admin the door to change every one of those words from the
-- app, and turns the last two structural things the migration still decided —
-- which schedules exist, and what the recitals and definitions say — into rows
-- that can be added, reworded, reordered and removed.
--
-- After this migration NOTHING the contract prints is fixed by code:
--   • recitals + definitions  -> agreement_front rows, CRUD from the app
--   • the schedules themselves -> agreement_schedule rows (a fourth schedule is
--     an INSERT from the screen, not a deploy); each names which structured
--     table fills its rows
--   • every heading, label, intro, note, status line and column caption
--     -> ui_copy, listed field by field with a human label by
--        agreement_text_field and edited through agreement_text_save()
-- The only thing still computed is the DATA: the split %, the licence numbers,
-- the zone — which must come from the records the platform settles on.
--
-- idempotent: safe to replay on live.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. SCHEDULES BECOME ROWS
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.agreement_schedule (
  id         bigserial primary key,
  version_id bigint not null references public.partner_agreement_version(id) on delete cascade,
  code       text   not null default '',
  heading    text   not null default '',
  intro      text   not null default '',
  note       text   not null default '',
  source     text   not null default 'none',
  sort       int    not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'agreement_schedule_source_chk') then
    alter table public.agreement_schedule add constraint agreement_schedule_source_chk
      check (source in ('terms','licences','zone','none'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'agreement_schedule_sort_key') then
    alter table public.agreement_schedule add constraint agreement_schedule_sort_key
      unique (version_id, sort);
  end if;
end $$;
create index if not exists agreement_schedule_version_idx
  on public.agreement_schedule(version_id, sort);

create or replace function public._c1986_seed_schedules(p_version_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if exists (select 1 from public.agreement_schedule where version_id = p_version_id) then
    return;
  end if;
  insert into public.agreement_schedule(version_id, code, heading, intro, note, source, sort)
  values
   (p_version_id, 'Schedule A', 'Commercial terms',
    'These are the terms the Platform settles on. They are read from the Zone''s own settlement record, so what is printed here and what is paid out are the same number.',
    'A change to any figure in this Schedule takes effect only through a new version of this Agreement, signed by both Parties.',
    'terms', 1),
   (p_version_id, 'Schedule B', 'Licences and expiry',
    'The Licences the Partner holds, as recorded on the Platform on the date this copy was produced.',
    'The Partner re-uploads each Licence before it expires. A lapsed Licence suspends the Partner until it is renewed.',
    'licences', 2),
   (p_version_id, 'Schedule C', 'Zone coverage',
    'The Zone assigned to the Partner, and the delivery terms the Platform applies inside it.',
    'The Operator may vary the Zone on notice to the Partner; a variation is recorded in a new version of this Schedule.',
    'zone', 3);
end $$;

do $$ declare r record; begin
  for r in select id from public.partner_agreement_version loop
    perform public._c1986_seed_schedules(r.id);
  end loop;
end $$;

create or replace function public._c1986_front_seed_trg() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public._c1986_seed_front(new.id);
  perform public._c1986_seed_schedules(new.id);
  return new;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE FIELD REGISTER — which ui_copy keys the contract prints, and what to
--    call each one on the editing screen. Seeded once, then editable like
--    anything else: a label that reads badly is an UPDATE here.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.agreement_text_field (
  key         text primary key,
  group_label text not null default '',
  label       text not null default '',
  hint        text not null default '',
  multiline   boolean not null default false,
  sort        int not null default 0,
  is_active   boolean not null default true
);

insert into public.agreement_text_field(key, group_label, label, hint, multiline, sort) values
 ('agree_pdf.cover_kicker',   'Cover page','Kicker above the title','Small line above the agreement title.', false, 10),
 ('agree_pdf.cover_between',  'Cover page','"made between" line','Introduces the two parties.', false, 20),
 ('agree_pdf.cover_and',      'Cover page','Word between the parties','Usually "and".', false, 30),
 ('agree_pdf.cover_note',     'Cover page','Footnote under the status line','', true, 40),
 ('agree_pdf.status_signed',  'Cover page','Signed status line','{d} is the date and time it was signed.', false, 50),
 ('agree_pdf.status_draft',   'Cover page','Draft status line','Printed on the unsigned preview.', false, 60),
 ('agree_pdf.m_id',           'Cover page','Label: agreement number','', false, 70),
 ('agree_pdf.m_version',      'Cover page','Label: version','', false, 80),
 ('agree_pdf.m_from',         'Cover page','Label: effective from','', false, 90),
 ('agree_pdf.m_to',           'Cover page','Label: effective to','', false, 100),
 ('agree_pdf.m_zone',         'Cover page','Label: zone','', false, 110),
 ('agree_pdf.p_gstin',        'Cover page','Party line: GSTIN','{v} is the number.', false, 120),
 ('agree_pdf.p_udyam',        'Cover page','Party line: Udyam','{v} is the number.', false, 130),
 ('agree_pdf.p_dl',           'Cover page','Party line: drug licences','{a} is Form 20B, {b} is Form 21B.', false, 140),
 ('agree_pdf.lh_udyam',       'Every page','Letterhead, right side','{u} is the Udyam number.', false, 150),
 ('agree_pdf.page_fmt',       'Every page','Page counter','{p} is this page, {n} is the total.', false, 160),
 ('agree_pdf.init_operator',  'Every page','Initials label: operator','', false, 170),
 ('agree_pdf.init_partner',   'Every page','Initials label: partner','', false, 180),
 ('agree_pdf.h_contents',     'Section headings','Contents','', false, 190),
 ('agree_pdf.h_page',         'Section headings','Contents: page column','', false, 200),
 ('agree_pdf.h_recitals',     'Section headings','Recitals','', false, 210),
 ('agree_pdf.h_definitions',  'Section headings','Definitions','', false, 220),
 ('agree_pdf.h_terms',        'Section headings','Numbered clauses','', false, 230),
 ('agree_pdf.h_schedules',    'Section headings','Schedules','', false, 240),
 ('agree_pdf.h_signatures',   'Section headings','Execution','', false, 250),
 ('agree_pdf.h_verify',       'Section headings','Verification','', false, 260),
 ('agree_pdf.def_lead',       'Definitions','Opening paragraph','Printed above the defined terms.', true, 270),
 ('agree_pdf.def_note',       'Definitions','Interpretation note','Printed under the defined terms.', true, 280),
 ('agree_pdf.badge_negotiated','Numbered clauses','Badge on a negotiated clause','Printed beside a clause this partner negotiated.', false, 290),
 ('agree_pdf.col_item',       'Schedule columns','Column: item','', false, 300),
 ('agree_pdf.col_detail',     'Schedule columns','Column: detail','', false, 310),
 ('agree_pdf.col_licence',    'Schedule columns','Column: licence','', false, 320),
 ('agree_pdf.col_number',     'Schedule columns','Column: number','', false, 330),
 ('agree_pdf.col_expiry',     'Schedule columns','Column: expires','', false, 340),
 ('agree_pdf.col_state',      'Schedule columns','Column: status','', false, 350),
 ('agree_pdf.sch_a_currency', 'Schedule A rows','Row label: currency','', false, 360),
 ('agree_pdf.sch_a_inr',      'Schedule A rows','Row value: currency','', false, 370),
 ('agree_pdf.sch_b_empty',    'Schedule B rows','Empty state','Printed when no licence is on file.', false, 380),
 ('agree_pdf.lic_gst',        'Schedule B rows','Licence name: GST','', false, 390),
 ('agree_pdf.lic_20b',        'Schedule B rows','Licence name: Form 20B','', false, 400),
 ('agree_pdf.lic_21b',        'Schedule B rows','Licence name: Form 21B','', false, 410),
 ('agree_pdf.lic_none',       'Schedule B rows','Value: not on file','', false, 420),
 ('agree_pdf.lic_no_expiry',  'Schedule B rows','Value: no expiry recorded','', false, 430),
 ('agree_pdf.lic_missing',    'Schedule B rows','Status: missing','', false, 440),
 ('agree_pdf.lic_on_file',    'Schedule B rows','Status: on file','', false, 450),
 ('agree_pdf.lic_expired',    'Schedule B rows','Status: expired','', false, 460),
 ('agree_pdf.lic_expiring',   'Schedule B rows','Status: expiring','', false, 470),
 ('agree_pdf.lic_valid',      'Schedule B rows','Status: valid','', false, 480),
 ('agree_pdf.sch_c_empty',    'Schedule C rows','Empty state','', false, 490),
 ('agree_pdf.zc_zone',        'Schedule C rows','Row label: zone','', false, 500),
 ('agree_pdf.zc_code',        'Schedule C rows','Row label: zone code','', false, 510),
 ('agree_pdf.zc_district',    'Schedule C rows','Row label: place of business','', false, 520),
 ('agree_pdf.zc_serviceable', 'Schedule C rows','Row label: open for delivery','', false, 530),
 ('agree_pdf.zc_promise',     'Schedule C rows','Row label: delivery promise','', false, 540),
 ('agree_pdf.zc_area',        'Schedule C rows','Row label: area covered','', false, 550),
 ('agree_pdf.zc_minutes',     'Schedule C rows','Value: minutes','{n} is the number of minutes.', false, 560),
 ('agree_pdf.zc_yes',         'Schedule C rows','Value: yes','', false, 570),
 ('agree_pdf.zc_no',          'Schedule C rows','Value: no','', false, 580),
 ('agree_pdf.for_operator',   'Execution','Column title: operator','', false, 590),
 ('agree_pdf.for_partner',    'Execution','Column title: partner','', false, 600),
 ('agree_pdf.role_operator',  'Execution','Designation: operator','', false, 610),
 ('agree_pdf.role_partner',   'Execution','Designation: partner','', false, 620),
 ('agree_pdf.f_name',         'Execution','Field: name','', false, 630),
 ('agree_pdf.f_role',         'Execution','Field: designation','', false, 640),
 ('agree_pdf.f_for',          'Execution','Field: on behalf of','', false, 650),
 ('agree_pdf.f_gstin',        'Execution','Field: GSTIN','', false, 660),
 ('agree_pdf.f_udyam',        'Execution','Field: Udyam','', false, 670),
 ('agree_pdf.f_date',         'Execution','Field: date','', false, 680),
 ('agree_pdf.f_method',       'Execution','Field: method','', false, 690),
 ('agree_pdf.f_phone',        'Execution','Field: mobile','', false, 700),
 ('agree_pdf.f_ip',           'Execution','Field: IP address','', false, 710),
 ('agree_pdf.blank',          'Execution','Placeholder for an unsigned field','', false, 720),
 ('agree_pdf.method_otp',     'Execution','Method: partner','', false, 730),
 ('agree_pdf.method_platform','Execution','Method: operator','', false, 740),
 ('agree_pdf.sig_lead_signed','Execution','Lead sentence, signed copy','', true, 750),
 ('agree_pdf.sig_lead_preview','Execution','Lead sentence, preview','', true, 760),
 ('agree_pdf.sig_note_signed','Execution','Note, signed copy','{phone} and {d} fill in from the signature.', true, 770),
 ('agree_pdf.sig_note_preview','Execution','Note, preview','', true, 780),
 ('agree_pdf.verify_line',    'Verification','Sentence beside the QR','', true, 790),
 ('agree_pdf.verify_caption', 'Verification','Hash caption','{h} is the first 16 characters.', false, 800),
 ('agree_pdf.verify_base',    'Verification','Verify link prefix','The code is appended to this.', false, 810),
 ('agree_pdf.preview_label',  'In the app','Preview button','Shown to the partner on My documents.', false, 820),
 ('agree_pdf.preview_hint',   'In the app','Preview hint','', true, 830),
 ('agree_pdf.preview_building','In the app','Preview button while building','', false, 840),
 ('agree_pdf.verify_hint',    'In the app','QR explanation on My documents','', true, 850),
 ('agree_verify.heading',     'Verify page','Heading','', false, 860),
 ('agree_verify.st_valid',    'Verify page','Verdict: verified','', false, 870),
 ('agree_verify.valid_body',  'Verify page','Explanation: verified','', true, 880),
 ('agree_verify.st_drifted',  'Verify page','Verdict: wording changed','', false, 890),
 ('agree_verify.drifted_body','Verify page','Explanation: wording changed','', true, 900),
 ('agree_verify.st_mismatch', 'Verify page','Verdict: does not match','', false, 910),
 ('agree_verify.mismatch_body','Verify page','Explanation: does not match','', true, 920),
 ('agree_verify.st_void',     'Verify page','Verdict: withdrawn','', false, 930),
 ('agree_verify.void_body',   'Verify page','Explanation: withdrawn','', true, 940),
 ('agree_verify.st_unknown',  'Verify page','Verdict: not found','', false, 950),
 ('agree_verify.unknown_body','Verify page','Explanation: not found','', true, 960),
 ('agree_verify.st_preview',  'Verify page','Verdict: unsigned preview','', false, 970),
 ('agree_verify.preview_body','Verify page','Explanation: unsigned preview','', true, 980),
 ('agree_verify.f_code',      'Verify page','Field: code','', false, 990),
 ('agree_verify.f_operator',  'Verify page','Field: operator','', false, 1000),
 ('agree_verify.f_partner',   'Verify page','Field: partner','', false, 1010),
 ('agree_verify.f_version',   'Verify page','Field: version','', false, 1020),
 ('agree_verify.f_signed',    'Verify page','Field: signed at','', false, 1030),
 ('agree_verify.f_signer',    'Verify page','Field: signed by','', false, 1040),
 ('agree_verify.f_hash',      'Verify page','Field: hash','', false, 1050),
 ('agree_verify.note',        'Verify page','Closing note','', true, 1060)
on conflict (key) do update
  set group_label = excluded.group_label, label = excluded.label,
      hint = excluded.hint, multiline = excluded.multiline,
      sort = excluded.sort, is_active = true;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE SCHEDULES ARE NOW READ FROM THEIR ROWS
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._c1986_schedule_rows(
  p_source text, p_partner_id bigint, p_tokens jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  rp public.region_partners%rowtype;
  z  public.zones%rowtype;
  zc public.zone_delivery_config%rowtype;
begin
  select * into rp from public.region_partners where id = p_partner_id;
  select * into z  from public.zones where id = rp.zone_id;
  select * into zc from public.zone_delivery_config where zone_id = rp.zone_id;

  if p_source = 'terms' then
    return jsonb_build_array(
      jsonb_build_object('item', public._c('partner_agree.t_split'),
                         'detail', (p_tokens->>'split_pct') || '%'),
      jsonb_build_object('item', public._c('partner_agree.t_cadence'),
                         'detail', p_tokens->>'cadence'),
      jsonb_build_object('item', public._c('partner_agree.t_exit'),
                         'detail', public._cf('partner_agree.t_exit_value',
                                     jsonb_build_object('n', p_tokens->>'exit_notice_days'))),
      jsonb_build_object('item', public._c('agree_pdf.sch_a_currency'),
                         'detail', public._c('agree_pdf.sch_a_inr')));
  elsif p_source = 'licences' then
    return jsonb_build_array(
      jsonb_build_object('licence', public._c('agree_pdf.lic_gst'),
        'number', coalesce(nullif(rp.gstin,''), public._c('agree_pdf.lic_none')),
        'expiry', case when rp.gstin_expiry is null then public._c('agree_pdf.lic_no_expiry')
                       else to_char(rp.gstin_expiry,'DD/MM/YYYY') end,
        'state', public._c1986_lic_state(rp.gstin, rp.gstin_expiry)),
      jsonb_build_object('licence', public._c('agree_pdf.lic_20b'),
        'number', coalesce(nullif(rp.dl_20b,''), public._c('agree_pdf.lic_none')),
        'expiry', case when rp.dl_20b_expiry is null then public._c('agree_pdf.lic_no_expiry')
                       else to_char(rp.dl_20b_expiry,'DD/MM/YYYY') end,
        'state', public._c1986_lic_state(rp.dl_20b, rp.dl_20b_expiry)),
      jsonb_build_object('licence', public._c('agree_pdf.lic_21b'),
        'number', coalesce(nullif(rp.dl_21b,''), public._c('agree_pdf.lic_none')),
        'expiry', case when rp.dl_21b_expiry is null then public._c('agree_pdf.lic_no_expiry')
                       else to_char(rp.dl_21b_expiry,'DD/MM/YYYY') end,
        'state', public._c1986_lic_state(rp.dl_21b, rp.dl_21b_expiry)));
  elsif p_source = 'zone' then
    return jsonb_build_array(
      jsonb_build_object('item', public._c('agree_pdf.zc_zone'),
        'detail', coalesce(nullif(z.name,''), p_tokens->>'zone')),
      jsonb_build_object('item', public._c('agree_pdf.zc_code'),
        'detail', coalesce(nullif(z.code,''), '—')),
      jsonb_build_object('item', public._c('agree_pdf.zc_district'),
        'detail', coalesce(nullif(rp.district,''), '—')
                  || case when coalesce(nullif(rp.state,''),'') = '' then ''
                          else ', ' || rp.state end),
      jsonb_build_object('item', public._c('agree_pdf.zc_serviceable'),
        'detail', case when coalesce(zc.is_serviceable, true)
                       then public._c('agree_pdf.zc_yes') else public._c('agree_pdf.zc_no') end),
      jsonb_build_object('item', public._c('agree_pdf.zc_promise'),
        'detail', case when zc.promise_window_min is null then '—'
                       else public._cf('agree_pdf.zc_minutes',
                              jsonb_build_object('n', zc.promise_window_min::text)) end))
      || coalesce((select jsonb_agg(jsonb_build_object(
                            'item', public._c('agree_pdf.zc_area'), 'detail', d.district))
                     from public.zone_districts d where d.zone_id = rp.zone_id), '[]'::jsonb);
  end if;
  return '[]'::jsonb;
end $$;

-- The columns a source needs. A schedule with source 'none' is free text: its
-- intro and note print, and it carries no table.
create or replace function public._c1986_schedule_cols(p_source text)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select case p_source
    when 'licences' then jsonb_build_array(
      jsonb_build_object('key','licence','label', public._c('agree_pdf.col_licence'),'align','left','width',150),
      jsonb_build_object('key','number','label', public._c('agree_pdf.col_number'),'align','left','width',0),
      jsonb_build_object('key','expiry','label', public._c('agree_pdf.col_expiry'),'align','right','width',112),
      jsonb_build_object('key','state','label', public._c('agree_pdf.col_state'),'align','right','width',90))
    when 'none' then '[]'::jsonb
    else jsonb_build_array(
      jsonb_build_object('key','item','label', public._c('agree_pdf.col_item'),'align','left','width',190),
      jsonb_build_object('key','detail','label', public._c('agree_pdf.col_detail'),'align','left','width',0))
  end
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE CONTRACT PAYLOAD, NOW READING ITS SCHEDULES FROM ROWS
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._c1986_schedules(
  p_version_id bigint, p_partner_id bigint, p_tokens jsonb)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', s.code,
           'heading', public.agreement_resolve(s.heading, p_tokens),
           'intro', public.agreement_resolve(s.intro, p_tokens),
           'columns', public._c1986_schedule_cols(s.source),
           'rows', public._c1986_schedule_rows(s.source, p_partner_id, p_tokens),
           'empty_label', case s.source
                            when 'licences' then public._c('agree_pdf.sch_b_empty')
                            when 'zone' then public._c('agree_pdf.sch_c_empty')
                            else '' end,
           'notes', case when coalesce(s.note,'') = '' then '[]'::jsonb
                         else jsonb_build_array(public.agreement_resolve(s.note, p_tokens)) end
         ) order by s.sort, s.id), '[]'::jsonb)
    from public.agreement_schedule s
   where s.version_id = p_version_id and s.is_active
$$;

create or replace function public.agreement_contract_doc(
  p_partner_id bigint default null,
  p_version_id bigint default null,
  p_sig_id     bigint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  s   public.partner_agreement_signature%rowtype;
  rp  public.region_partners%rowtype;
  v   public.partner_agreement_version%rowtype;
  pi  public.platform_identity%rowtype;
  z   public.zones%rowtype;
  zc  public.zone_delivery_config%rowtype;
  doc jsonb; tok jsonb; terms jsonb;
  v_pid bigint; v_mode text; v_sha text; v_code text;
  v_recitals jsonb; v_defs jsonb; v_clauses jsonb; v_toc jsonb;
  v_sched jsonb; v_sig_block jsonb; v_agr_id text; v_status_line text;
  v_status_tone text;
begin
  if p_sig_id is not null then
    select * into s from public.partner_agreement_signature where id = p_sig_id;
    if not found or s.status <> 'signed' then
      return jsonb_build_object('ok', false, 'error','not_signed',
        'message', public._c('agree_pdf.err_not_signed'));
    end if;
    v_pid := s.partner_id; v_mode := 'signed';
    select * into v from public.partner_agreement_version where id = s.version_id;
  else
    v_pid := p_partner_id; v_mode := 'preview';
    if p_version_id is not null then
      select * into v from public.partner_agreement_version where id = p_version_id;
    else
      v := public._c692_current_version();
    end if;
  end if;

  if v_pid is null or v.id is null then
    return jsonb_build_object('ok', false, 'error','no_version',
      'message', public._c('agree_pdf.err_no_version'));
  end if;

  select * into rp from public.region_partners where id = v_pid;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('agree_pdf.err_no_partner'));
  end if;
  select * into pi from public.platform_identity order by id limit 1;
  select * into z  from public.zones where id = rp.zone_id;
  select * into zc from public.zone_delivery_config where zone_id = rp.zone_id;

  doc := public.agreement_render(v.id, v_pid);
  if coalesce(doc->>'ok','false') <> 'true' then return doc; end if;
  tok   := coalesce(doc->'tokens', '{}'::jsonb);
  terms := coalesce(doc->'terms',  '{}'::jsonb);

  -- The signed copy quotes the hash that was SNAPSHOTTED, never today's
  -- re-render: that is exactly what makes the verify page able to say
  -- "this text has changed since it was signed".
  v_sha := case when v_mode = 'signed' then coalesce(nullif(s.body_sha256,''), doc->>'sha256')
                else doc->>'sha256' end;
  v_code := public._c1986_code(v_mode,
              case when v_mode = 'signed' then s.id else v.version end,
              v_pid, v_sha);

  v_agr_id := 'MB-AGR-' || lpad(v_pid::text, 4, '0') || '-V' || v.version::text
              || case when v_mode = 'signed' then '' else '-PREVIEW' end;

  if v_mode = 'signed' then
    v_status_line := public._cf('agree_pdf.status_signed', jsonb_build_object(
                       'd', public.ist_fmt(s.signed_at, 'dmy_hm')));
    v_status_tone := 'success';
  else
    v_status_line := public._c('agree_pdf.status_draft');
    v_status_tone := 'warning';
  end if;

  -- ── recitals ──────────────────────────────────────────────────────────────
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', case when f.n >= (select max(n) from public.agreement_front
                                       where version_id = v.id and kind='recital')
                         then '' else chr(64 + f.n) || '.' end,
           'text',  public.agreement_resolve(f.body, tok),
           'is_lead_out', f.n >= (select max(n) from public.agreement_front
                                   where version_id = v.id and kind='recital')
         ) order by f.n), '[]'::jsonb)
    into v_recitals
    from public.agreement_front f where f.version_id = v.id and f.kind = 'recital';

  -- ── definitions ───────────────────────────────────────────────────────────
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', '(' || chr(96 + f.n) || ')',
           'term',  public.agreement_resolve(f.term, tok),
           'text',  public.agreement_resolve(f.body, tok)
         ) order by f.n), '[]'::jsonb)
    into v_defs
    from public.agreement_front f where f.version_id = v.id and f.kind = 'definition';

  -- ── numbered clauses, already resolved by agreement_render() ──────────────
  select coalesce(jsonb_agg(jsonb_build_object(
           'n', (c->>'n')::int,
           'number', (c->>'n') || '.',
           'heading', upper(c->>'heading'),
           'heading_toc', c->>'heading',
           'paras', (select coalesce(jsonb_agg(p order by o), '[]'::jsonb)
                       from unnest(regexp_split_to_array(coalesce(c->>'body',''), E'\n+'))
                            with ordinality as u(p, o)
                      where btrim(p) <> ''),
           'badge', case when (c->>'is_negotiated')::boolean
                         then public._c('agree_pdf.badge_negotiated') else '' end
         ) order by (c->>'n')::int), '[]'::jsonb)
    into v_clauses
    from jsonb_array_elements(coalesce(doc->'clauses','[]'::jsonb)) as c;

  -- The schedules are ROWS now (CMD #1986, Om): which schedules exist, what
  -- each is called and what it says are edited from the app, never here.
  v_sched := public._c1986_schedules(v.id, v_pid, tok);

  -- ── the contents list. Page numbers are the RENDERER's to fill: they are a
  --    fact about the layout, not a sentence. Every LABEL is written here.
  v_toc := jsonb_build_array(
      jsonb_build_object('key','recitals','label', public._c('agree_pdf.h_recitals')),
      jsonb_build_object('key','definitions','label', public._c('agree_pdf.h_definitions')))
    || coalesce((select jsonb_agg(jsonb_build_object(
                   'key','clause:' || (c->>'n'),
                   'label', (c->>'n') || '. ' || (c->>'heading_toc'))
                 order by (c->>'n')::int)
                 from jsonb_array_elements(v_clauses) c), '[]'::jsonb)
    || coalesce((select jsonb_agg(jsonb_build_object(
                   'key','schedule:' || (sc->>'code'),
                   'label', (sc->>'code') || ' — ' || (sc->>'heading')))
                 from jsonb_array_elements(v_sched) sc), '[]'::jsonb)
    || jsonb_build_array(jsonb_build_object('key','signatures',
                          'label', public._c('agree_pdf.h_signatures')));

  -- ── the signature block: both parties, side by side ───────────────────────
  v_sig_block := jsonb_build_object(
    'heading', public._c('agree_pdf.h_signatures'),
    'lead', case when v_mode = 'signed' then public._c('agree_pdf.sig_lead_signed')
                 else public._c('agree_pdf.sig_lead_preview') end,
    'parties', jsonb_build_array(
      jsonb_build_object('title', public._c('agree_pdf.for_operator'),
        'rows', jsonb_build_array(
          jsonb_build_object('label', public._c('agree_pdf.f_name'),   'value', tok->>'operator'),
          jsonb_build_object('label', public._c('agree_pdf.f_role'),   'value', public._c('agree_pdf.role_operator')),
          jsonb_build_object('label', public._c('agree_pdf.f_gstin'),  'value', tok->>'operator_gstin'),
          jsonb_build_object('label', public._c('agree_pdf.f_udyam'),  'value', tok->>'operator_udyam'),
          jsonb_build_object('label', public._c('agree_pdf.f_date'),
            'value', case when v_mode='signed' then public.ist_fmt(s.signed_at,'dmy')
                          else public._c('agree_pdf.blank') end),
          jsonb_build_object('label', public._c('agree_pdf.f_method'),
            'value', case when v_mode='signed' then public._c('agree_pdf.method_platform')
                          else public._c('agree_pdf.blank') end))),
      jsonb_build_object('title', public._c('agree_pdf.for_partner'),
        'rows', jsonb_build_array(
          jsonb_build_object('label', public._c('agree_pdf.f_name'),
            'value', case when v_mode='signed' then coalesce(nullif(s.signer_name,''), tok->>'partner')
                          else public._c('agree_pdf.blank') end),
          jsonb_build_object('label', public._c('agree_pdf.f_role'),
            'value', case when v_mode='signed' then public._c('agree_pdf.role_partner')
                          else public._c('agree_pdf.blank') end),
          jsonb_build_object('label', public._c('agree_pdf.f_for'),   'value', tok->>'partner'),
          jsonb_build_object('label', public._c('agree_pdf.f_phone'),
            'value', case when v_mode='signed' then coalesce(nullif(s.signer_phone,''), public._c('agree_pdf.blank'))
                          else public._c('agree_pdf.blank') end),
          jsonb_build_object('label', public._c('agree_pdf.f_date'),
            'value', case when v_mode='signed' then public.ist_fmt(s.signed_at,'dmy')
                          else public._c('agree_pdf.blank') end),
          jsonb_build_object('label', public._c('agree_pdf.f_method'),
            'value', case when v_mode='signed' then public._c('agree_pdf.method_otp')
                          else public._c('agree_pdf.blank') end),
          jsonb_build_object('label', public._c('agree_pdf.f_ip'),
            'value', case when v_mode='signed' then coalesce(nullif(s.signed_ip,''), public._c('agree_pdf.blank'))
                          else public._c('agree_pdf.blank') end)))),
    'note', case when v_mode = 'signed'
                 then public._cf('agree_pdf.sig_note_signed', jsonb_build_object(
                        'phone', coalesce(s.signer_phone,''),
                        'd', public.ist_fmt(s.signed_at,'dmy_hm')))
                 else public._c('agree_pdf.sig_note_preview') end);

  return jsonb_build_object('ok', true, 'kind','contract', 'mode', v_mode,
    'partner_id', v_pid, 'version_id', v.id, 'version', v.version,
    'page', jsonb_build_object('width', 595, 'height', 842, 'margin', 57,
                               'body_size', 10.5, 'line_gap', 1.4),
    'letterhead', jsonb_build_object(
      'left',  tok->>'operator',
      'right', public._cf('agree_pdf.lh_udyam', jsonb_build_object('u', tok->>'operator_udyam'))),
    'footer', jsonb_build_object(
      'left',  v_agr_id || ' · ' || public._cf('partner_agree.version_label',
                 jsonb_build_object('v', v.version::text,
                                    'd', to_char(v.effective_from,'DD/MM/YYYY'))),
      'page_fmt', public._c('agree_pdf.page_fmt'),
      'initials_operator', public._c('agree_pdf.init_operator'),
      'initials_partner',  public._c('agree_pdf.init_partner')),
    'cover', jsonb_build_object(
      'mark', coalesce(nullif(pi.platform_name,''), 'mediBO'),
      'tagline', coalesce(nullif(pi.tagline,''), ''),
      'title', upper(coalesce(nullif(doc->>'title',''), public._c('partner_agree.heading'))),
      'kicker', public._c('agree_pdf.cover_kicker'),
      'meta', jsonb_build_array(
        jsonb_build_object('label', public._c('agree_pdf.m_id'),      'value', v_agr_id),
        jsonb_build_object('label', public._c('agree_pdf.m_version'), 'value', v.version::text),
        jsonb_build_object('label', public._c('agree_pdf.m_from'),
                           'value', to_char(v.effective_from,'DD/MM/YYYY')),
        jsonb_build_object('label', public._c('agree_pdf.m_to'),
                           'value', case when v.effective_to is null
                                         then public._c('partner_agree.valid_open')
                                         else to_char(v.effective_to,'DD/MM/YYYY') end),
        jsonb_build_object('label', public._c('agree_pdf.m_zone'),    'value', tok->>'zone')),
      'between', public._c('agree_pdf.cover_between'),
      'parties', jsonb_build_array(
        jsonb_build_object('role', public._c('agree_pdf.role_operator'),
          'name', tok->>'operator',
          'lines', jsonb_build_array(
            public._cf('agree_pdf.p_gstin', jsonb_build_object('v', tok->>'operator_gstin')),
            public._cf('agree_pdf.p_udyam', jsonb_build_object('v', tok->>'operator_udyam')),
            coalesce(nullif(pi.address,''), ''))),
        jsonb_build_object('role', public._c('agree_pdf.role_partner'),
          'name', tok->>'partner',
          'lines', jsonb_build_array(
            public._cf('agree_pdf.p_gstin', jsonb_build_object('v', tok->>'partner_gstin')),
            public._cf('agree_pdf.p_dl', jsonb_build_object(
              'a', tok->>'partner_dl20b', 'b', tok->>'partner_dl21b')),
            coalesce(nullif(tok->>'partner_address',''), '')))),
      'and_label', public._c('agree_pdf.cover_and'),
      'status_line', v_status_line,
      'status_tone', v_status_tone,
      'note', public._c('agree_pdf.cover_note')),
    'toc', jsonb_build_object('heading', public._c('agree_pdf.h_contents'),
                              'col_page', public._c('agree_pdf.h_page'),
                              'entries', v_toc),
    'recitals', jsonb_build_object('heading', public._c('agree_pdf.h_recitals'),
                                   'items', v_recitals),
    'definitions', jsonb_build_object('heading', public._c('agree_pdf.h_definitions'),
                                      'lead', public._c('agree_pdf.def_lead'),
                                      'items', v_defs,
                                      'note', public._c('agree_pdf.def_note')),
    'clauses', v_clauses,
    'clauses_heading', public._c('agree_pdf.h_terms'),
    'schedules', v_sched,
    'schedules_heading', public._c('agree_pdf.h_schedules'),
    'signature', v_sig_block,
    'verify', jsonb_build_object(
      'heading', public._c('agree_pdf.h_verify'),
      'line', public._c('agree_pdf.verify_line'),
      'code', v_code,
      'sha256', v_sha,
      'url', public._c1986_verify_url(v_code),
      'caption', public._cf('agree_pdf.verify_caption',
                   jsonb_build_object('h', left(coalesce(v_sha,''), 16)))),
    'file_name', 'mediBO-agreement-v' || v.version::text
                 || case when v_mode = 'signed' then '-signed' else '-preview' end || '.pdf',
    'title', coalesce(doc->>'title',''));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. THE EDITOR — one payload for the screen, three writes.
--    Only a super-admin may change the words a contract prints.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._c1986_can_edit()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select public.role_for_medibo_only() = 'super_admin'
$$;

create or replace function public.agreement_doc_editor(p_version_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v public.partner_agreement_version%rowtype;
  v_can boolean := public._c1986_can_edit();
  v_rec jsonb; v_def jsonb; v_sch jsonb; v_txt jsonb;
begin
  if not (public.role_for_medibo_only() in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public._c('agree_edit.err_not_authorized'));
  end if;
  if p_version_id is not null then
    select * into v from public.partner_agreement_version where id = p_version_id;
  else
    v := public._c692_current_version();
    if v.id is null then
      select * into v from public.partner_agreement_version order by version desc limit 1;
    end if;
  end if;
  if v.id is null then
    return jsonb_build_object('ok', false, 'error','no_version',
      'message', public._c('agree_pdf.err_no_version'));
  end if;

  -- Every seeded row exists for every version, so an old version opened for the
  -- first time is editable rather than empty.
  perform public._c1986_seed_front(v.id);
  perform public._c1986_seed_schedules(v.id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', f.id, 'n', f.n, 'body', f.body,
           'preview', public.agreement_resolve(f.body, '{}'::jsonb)) order by f.n), '[]'::jsonb)
    into v_rec from public.agreement_front f
   where f.version_id = v.id and f.kind = 'recital';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', f.id, 'n', f.n, 'term', f.term, 'body', f.body) order by f.n), '[]'::jsonb)
    into v_def from public.agreement_front f
   where f.version_id = v.id and f.kind = 'definition';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'sort', s.sort, 'code', s.code, 'heading', s.heading,
           'intro', s.intro, 'note', s.note, 'source', s.source,
           'source_label', public._c('agree_edit.src_' || s.source),
           'is_active', s.is_active) order by s.sort, s.id), '[]'::jsonb)
    into v_sch from public.agreement_schedule s where s.version_id = v.id;

  select coalesce(jsonb_agg(g order by (g->>'sort')::int), '[]'::jsonb) into v_txt
    from (
      select jsonb_build_object(
               'group_label', t.group_label,
               'sort', min(t.sort)::text,
               'fields', jsonb_agg(jsonb_build_object(
                  'key', t.key, 'label', t.label, 'hint', t.hint,
                  'multiline', t.multiline,
                  'value', coalesce(public._c(t.key), '')) order by t.sort)) as g
        from public.agreement_text_field t
       where t.is_active
       group by t.group_label
    ) q;

  return jsonb_build_object('ok', true,
    'version_id', v.id, 'version', v.version,
    'title', public._c('agree_edit.heading'),
    'sub', public._c('agree_edit.sub'),
    'can_edit', v_can,
    'readonly_note', case when v_can then '' else public._c('agree_edit.readonly') end,
    'recitals', jsonb_build_object(
      'heading', public._c('agree_edit.recitals_heading'),
      'hint', public._c('agree_edit.recitals_hint'),
      'add_label', public._c('agree_edit.add_recital'),
      'body_hint', public._c('agree_edit.body_hint'),
      'items', v_rec,
      'empty', public._c('agree_edit.recitals_empty')),
    'definitions', jsonb_build_object(
      'heading', public._c('agree_edit.def_heading'),
      'hint', public._c('agree_edit.def_hint'),
      'add_label', public._c('agree_edit.add_definition'),
      'term_hint', public._c('agree_edit.term_hint'),
      'body_hint', public._c('agree_edit.body_hint'),
      'items', v_def,
      'empty', public._c('agree_edit.def_empty')),
    'schedules', jsonb_build_object(
      'heading', public._c('agree_edit.sch_heading'),
      'hint', public._c('agree_edit.sch_hint'),
      'add_label', public._c('agree_edit.add_schedule'),
      'code_hint', public._c('agree_edit.code_hint'),
      'heading_hint', public._c('agree_edit.heading_hint'),
      'intro_hint', public._c('agree_edit.intro_hint'),
      'note_hint', public._c('agree_edit.note_hint'),
      'source_label', public._c('agree_edit.source_label'),
      'sources', jsonb_build_array(
        jsonb_build_object('key','terms',   'label', public._c('agree_edit.src_terms')),
        jsonb_build_object('key','licences','label', public._c('agree_edit.src_licences')),
        jsonb_build_object('key','zone',    'label', public._c('agree_edit.src_zone')),
        jsonb_build_object('key','none',    'label', public._c('agree_edit.src_none'))),
      'items', v_sch,
      'empty', public._c('agree_edit.sch_empty')),
    'wording', jsonb_build_object(
      'heading', public._c('agree_edit.text_heading'),
      'hint', public._c('agree_edit.text_hint'),
      'groups', v_txt,
      'empty', public._c('agree_edit.text_empty')),
    'save_label', public._c('agree_edit.save'),
    'delete_label', public._c('agree_edit.delete'),
    'token_help', public._c('partner_agree.token_help'));
end $$;

-- A recital or a definition. `p_delete` removes it; `p_n` reorders it. The
-- numbering is re-packed so a deletion never leaves a hole in the letters.
create or replace function public.agreement_front_save(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_id bigint := nullif(p->>'id','')::bigint;
  v_ver bigint := nullif(p->>'version_id','')::bigint;
  v_kind text := coalesce(nullif(p->>'kind',''), 'recital');
  v_n int; f public.agreement_front%rowtype; i int := 0; r record;
begin
  if not public._c1986_can_edit() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public._c('agree_edit.err_not_authorized'));
  end if;
  if v_kind not in ('recital','definition') then
    return jsonb_build_object('ok', false, 'error','bad_kind',
      'message', public._c('agree_edit.err_bad_kind'));
  end if;

  if coalesce((p->>'delete')::boolean, false) then
    delete from public.agreement_front where id = v_id returning * into f;
    if not found then
      return jsonb_build_object('ok', false, 'error','not_found',
        'message', public._c('agree_edit.err_not_found'));
    end if;
    v_ver := f.version_id; v_kind := f.kind;
  else
    if v_id is not null then
      update public.agreement_front
         set term = coalesce(p->>'term', term),
             body = coalesce(p->>'body', body),
             updated_at = now()
       where id = v_id returning * into f;
      if not found then
        return jsonb_build_object('ok', false, 'error','not_found',
          'message', public._c('agree_edit.err_not_found'));
      end if;
      v_ver := f.version_id;
    else
      if v_ver is null then
        return jsonb_build_object('ok', false, 'error','no_version',
          'message', public._c('agree_pdf.err_no_version'));
      end if;
      select coalesce(max(n),0) + 1 into v_n from public.agreement_front
       where version_id = v_ver and kind = v_kind;
      insert into public.agreement_front(version_id, kind, n, term, body)
      values (v_ver, v_kind, v_n, coalesce(p->>'term',''), coalesce(p->>'body',''));
    end if;
  end if;

  -- re-pack, so the printed letters stay A, B, C with no gap
  for r in select id from public.agreement_front
            where version_id = v_ver and kind = v_kind order by n, id loop
    i := i + 1;
    update public.agreement_front set n = i where id = r.id and n is distinct from i;
  end loop;

  return jsonb_build_object('ok', true,
    'message', public._c('agree_edit.saved'),
    'editor', public.agreement_doc_editor(v_ver));
end $$;

create or replace function public.agreement_schedule_save(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_id bigint := nullif(p->>'id','')::bigint;
  v_ver bigint := nullif(p->>'version_id','')::bigint;
  v_src text := coalesce(nullif(p->>'source',''), 'none');
  s public.agreement_schedule%rowtype; v_sort int; i int := 0; r record;
begin
  if not public._c1986_can_edit() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public._c('agree_edit.err_not_authorized'));
  end if;
  if v_src not in ('terms','licences','zone','none') then
    return jsonb_build_object('ok', false, 'error','bad_source',
      'message', public._c('agree_edit.err_bad_source'));
  end if;

  if coalesce((p->>'delete')::boolean, false) then
    delete from public.agreement_schedule where id = v_id returning * into s;
    if not found then
      return jsonb_build_object('ok', false, 'error','not_found',
        'message', public._c('agree_edit.err_not_found'));
    end if;
    v_ver := s.version_id;
  elsif v_id is not null then
    update public.agreement_schedule
       set code = coalesce(p->>'code', code),
           heading = coalesce(p->>'heading', heading),
           intro = coalesce(p->>'intro', intro),
           note = coalesce(p->>'note', note),
           source = v_src,
           is_active = coalesce((p->>'is_active')::boolean, is_active),
           updated_at = now()
     where id = v_id returning * into s;
    if not found then
      return jsonb_build_object('ok', false, 'error','not_found',
        'message', public._c('agree_edit.err_not_found'));
    end if;
    v_ver := s.version_id;
  else
    if v_ver is null then
      return jsonb_build_object('ok', false, 'error','no_version',
        'message', public._c('agree_pdf.err_no_version'));
    end if;
    select coalesce(max(sort),0) + 1 into v_sort
      from public.agreement_schedule where version_id = v_ver;
    insert into public.agreement_schedule(version_id, code, heading, intro, note, source, sort)
    values (v_ver, coalesce(p->>'code',''), coalesce(p->>'heading',''),
            coalesce(p->>'intro',''), coalesce(p->>'note',''), v_src, v_sort);
  end if;

  for r in select id from public.agreement_schedule
            where version_id = v_ver order by sort, id loop
    i := i + 1;
    update public.agreement_schedule set sort = i where id = r.id and sort is distinct from i;
  end loop;

  return jsonb_build_object('ok', true,
    'message', public._c('agree_edit.saved'),
    'editor', public.agreement_doc_editor(v_ver));
end $$;

-- One printed word. Only keys the register lists may be written, so this door
-- cannot be used to rewrite the rest of the app's copy.
create or replace function public.agreement_text_save(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_key text := coalesce(p->>'key',''); v_val text := coalesce(p->>'value','');
begin
  if not public._c1986_can_edit() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public._c('agree_edit.err_not_authorized'));
  end if;
  if not exists (select 1 from public.agreement_text_field where key = v_key and is_active) then
    return jsonb_build_object('ok', false, 'error','unknown_key',
      'message', public._c('agree_edit.err_unknown_key'));
  end if;
  if btrim(v_val) = '' then
    return jsonb_build_object('ok', false, 'error','empty',
      'message', public._c('agree_edit.err_empty'));
  end if;
  insert into public.ui_copy(key, value) values (v_key, to_jsonb(v_val))
  on conflict (key) do update set value = excluded.value;
  return jsonb_build_object('ok', true,
    'message', public._c('agree_edit.saved'),
    'editor', public.agreement_doc_editor(nullif(p->>'version_id','')::bigint));
end $$;

grant execute on function public.agreement_doc_editor(bigint)  to authenticated;
grant execute on function public.agreement_front_save(jsonb)    to authenticated;
grant execute on function public.agreement_schedule_save(jsonb) to authenticated;
grant execute on function public.agreement_text_save(jsonb)     to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. THE DOOR ON THE AGREEMENT SCREEN + its copy
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
 ('agree_edit.heading',        '"Printed document"'::jsonb),
 ('agree_edit.sub',            '"Everything the partner agreement PDF prints — the recitals, the definitions, the schedules and every heading, label and note — is edited here. Nothing on that page is fixed in the app."'::jsonb),
 ('agree_edit.open_label',     '"Edit the printed document"'::jsonb),
 ('agree_edit.readonly',       '"You can read this. Only a super-admin can change what the agreement prints."'::jsonb),
 ('agree_edit.recitals_heading','"Recitals"'::jsonb),
 ('agree_edit.recitals_hint',  '"The WHEREAS paragraphs printed before clause 1. They are lettered A, B, C in the order below."'::jsonb),
 ('agree_edit.recitals_empty', '"No recitals yet. Add the first one."'::jsonb),
 ('agree_edit.add_recital',    '"Add a recital"'::jsonb),
 ('agree_edit.def_heading',    '"Defined terms"'::jsonb),
 ('agree_edit.def_hint',       '"Each term is printed in bold, lettered (a), (b), (c), and used with the same meaning everywhere in the contract."'::jsonb),
 ('agree_edit.def_empty',      '"No defined terms yet. Add the first one."'::jsonb),
 ('agree_edit.add_definition', '"Add a defined term"'::jsonb),
 ('agree_edit.term_hint',      '"The term, in quotes — e.g. \"Partner Share\""'::jsonb),
 ('agree_edit.body_hint',      '"The wording. Use {{partner}} or {{split_pct}} instead of a name or a number."'::jsonb),
 ('agree_edit.sch_heading',    '"Schedules"'::jsonb),
 ('agree_edit.sch_hint',       '"The schedules printed at the back, in this order. Each one names which record fills its table — the figures themselves always come from the platform, never typed here."'::jsonb),
 ('agree_edit.sch_empty',      '"No schedules yet. Add the first one."'::jsonb),
 ('agree_edit.add_schedule',   '"Add a schedule"'::jsonb),
 ('agree_edit.code_hint',      '"Schedule code — e.g. Schedule D"'::jsonb),
 ('agree_edit.heading_hint',   '"Schedule title"'::jsonb),
 ('agree_edit.intro_hint',     '"Opening sentence, printed under the title"'::jsonb),
 ('agree_edit.note_hint',      '"Closing note, printed under the table"'::jsonb),
 ('agree_edit.source_label',   '"Table filled from"'::jsonb),
 ('agree_edit.src_terms',      '"Commercial terms (split, cadence, exit notice)"'::jsonb),
 ('agree_edit.src_licences',   '"Licences and expiry"'::jsonb),
 ('agree_edit.src_zone',       '"Zone coverage"'::jsonb),
 ('agree_edit.src_none',       '"No table — words only"'::jsonb),
 ('agree_edit.text_heading',   '"Every printed word"'::jsonb),
 ('agree_edit.text_hint',      '"Each field below is one piece of text on the printed contract or the public verification page. Change it and the next PDF prints the new wording — no release needed."'::jsonb),
 ('agree_edit.text_empty',     '"No fields registered."'::jsonb),
 ('agree_edit.save',           '"Save"'::jsonb),
 ('agree_edit.delete',         '"Delete"'::jsonb),
 ('agree_edit.saved',          '"Saved. The next PDF prints it."'::jsonb),
 ('agree_edit.err_not_authorized','"Only a super-admin can change what the agreement prints."'::jsonb),
 ('agree_edit.err_not_found',  '"That entry is no longer there."'::jsonb),
 ('agree_edit.err_bad_kind',   '"That is not a recital or a defined term."'::jsonb),
 ('agree_edit.err_bad_source', '"That table source is not one this app knows."'::jsonb),
 ('agree_edit.err_unknown_key','"That field is not part of the printed document."'::jsonb),
 ('agree_edit.err_empty',      '"This field cannot be blank — the contract would print a gap."'::jsonb)
on conflict (key) do update set value = excluded.value;

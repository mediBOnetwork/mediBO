-- CMD #1986 — the partner agreement stops being a text dump and becomes a
-- CONTRACT: cover page, table of contents, recitals, a definitions article,
-- numbered clauses with hanging indents, schedules at the back, an initials
-- line on every page, a signature block for both parties, and a footer QR that
-- resolves to a public page confirming the sha256 of the signed text.
--
-- WHAT THIS MIGRATION DOES AND DOES NOT DO
--   • It does NOT touch agreement_render()'s full_text or its sha256. That
--     string is what every existing signature snapshotted; adding front matter
--     to it would make every signed agreement read as "drifted" and ask real
--     partners to re-sign for a typesetting change. Recitals and definitions
--     are FRONT MATTER — printed, listed in the contents, never hashed.
--   • Every word on the page is composed here. The renderer
--     (supabase/functions/agreement-pdf) decides where ink goes and what page
--     a heading landed on; it never writes a sentence.
--   • The same payload prints the unsigned preview and the signed copy. The
--     only difference is the mode, and the mode is decided here.
--
-- idempotent: safe to replay on live.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. FRONT MATTER — recitals and definitions, per version, token-resolved like
--    every clause. Its own table so clause numbering, the #1985 proposal
--    machinery and the signed hash are all left exactly as they were.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.agreement_front (
  id         bigserial primary key,
  version_id bigint not null references public.partner_agreement_version(id) on delete cascade,
  kind       text   not null default 'recital',
  n          int    not null,
  term       text   not null default '',
  body       text   not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'agreement_front_key') then
    alter table public.agreement_front add constraint agreement_front_key unique (version_id, kind, n);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'agreement_front_kind_chk') then
    alter table public.agreement_front add constraint agreement_front_kind_chk
      check (kind in ('recital','definition'));
  end if;
end $$;
create index if not exists agreement_front_version_idx on public.agreement_front(version_id, kind, n);

-- Seed front matter for every version that has none. Tokens only — never a
-- name, never a number: {{operator}} and {{split_pct}} fill in per partner at
-- render time, which is the whole point of #1985's token model.
create or replace function public._c1986_seed_front(p_version_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if exists (select 1 from public.agreement_front where version_id = p_version_id) then
    return;
  end if;

  insert into public.agreement_front(version_id, kind, n, term, body) values
   (p_version_id,'recital',1,'',
    'WHEREAS the Operator, {{operator}}, holding GSTIN {{operator_gstin}} and Udyam registration {{operator_udyam}}, owns and operates the mediBO platform, on which pharmacies and clinics place orders for pharmaceutical goods;'),
   (p_version_id,'recital',2,'',
    'WHEREAS the Partner, {{partner}}, holding GSTIN {{partner_gstin}} and wholesale drug licences in Forms 20B ({{partner_dl20b}}) and 21B ({{partner_dl21b}}), carries on the business of wholesale distribution of pharmaceutical goods at {{partner_address}};'),
   (p_version_id,'recital',3,'',
    'WHEREAS the Operator wishes to appoint the Partner as its fulfilment partner for the Zone known as {{zone}}, and the Partner wishes to accept that appointment on the terms recorded below;'),
   (p_version_id,'recital',4,'',
    'NOW THEREFORE, in consideration of the mutual covenants below, the Parties agree as follows.');

  insert into public.agreement_front(version_id, kind, n, term, body) values
   (p_version_id,'definition',1,'"Agreement"',
    'means this agreement, together with its Recitals and Schedules A, B and C, as varied from time to time in accordance with its terms.'),
   (p_version_id,'definition',2,'"Operator"',
    'means {{operator}}, which operates the Platform, and includes its successors and permitted assigns.'),
   (p_version_id,'definition',3,'"Partner"',
    'means {{partner}}, the fulfilment partner appointed under this Agreement for the Zone.'),
   (p_version_id,'definition',4,'"Parties"',
    'means the Operator and the Partner together, and "Party" means either of them.'),
   (p_version_id,'definition',5,'"Platform"',
    'means the mediBO ordering, fulfilment and settlement software operated by the Operator, including its web and mobile applications.'),
   (p_version_id,'definition',6,'"Zone"',
    'means the delivery area {{zone}} assigned to the Partner on the Platform, as recorded in Schedule C.'),
   (p_version_id,'definition',7,'"Order"',
    'means an order for pharmaceutical goods placed by a customer on the Platform and routed to the Partner for fulfilment.'),
   (p_version_id,'definition',8,'"Licences"',
    'means the wholesale drug licences in Forms 20B and 21B, the GST registration and every other approval the Partner must hold to trade in pharmaceutical goods, as recorded in Schedule B.'),
   (p_version_id,'definition',9,'"Partner Share"',
    'means {{split_pct}}% of the settleable value of an Order, calculated by the Platform and recorded in Schedule A.'),
   (p_version_id,'definition',10,'"Settlement Cycle"',
    'means {{cadence}}, being the cadence on which the Operator settles the Partner Share, as recorded in Schedule A.'),
   (p_version_id,'definition',11,'"Exit Notice"',
    'means written notice of {{exit_notice_days}} days given by either Party to end this Agreement, as recorded in Schedule A.'),
   (p_version_id,'definition',12,'"Schedules"',
    'means Schedule A (commercial terms), Schedule B (licences and expiry) and Schedule C (zone coverage), each of which forms part of this Agreement.');
end $$;

do $$ declare r record; begin
  for r in select id from public.partner_agreement_version loop
    perform public._c1986_seed_front(r.id);
  end loop;
end $$;

-- A new version drafted from now on gets the same front matter automatically.
create or replace function public._c1986_front_seed_trg() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public._c1986_seed_front(new.id);
  return new;
end $$;
drop trigger if exists c1986_front_seed on public.partner_agreement_version;
create trigger c1986_front_seed after insert on public.partner_agreement_version
  for each row execute function public._c1986_front_seed_trg();

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE VERIFICATION CODE — what the footer QR resolves to.
--    Shape: A<sig-id>-<first 12 of the signed sha256>  (a signed copy)
--           P<version>-<partner>-<first 12 of the resolved sha256>  (a preview)
--    The hash is IN the code, so the page can say plainly whether the code and
--    the stored signature agree without trusting anything the reader typed.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._c1986_code(p_kind text, p_a bigint, p_b bigint, p_sha text)
returns text language sql immutable as $$
  select case when p_kind = 'signed'
              then 'A' || p_a::text || '-' || upper(left(coalesce(p_sha,''), 12))
              else 'P' || p_a::text || '-' || p_b::text || '-' || upper(left(coalesce(p_sha,''), 12))
         end
$$;

create or replace function public._c1986_verify_url(p_code text)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce(nullif(public._c('agree_pdf.verify_base'), ''), 'https://medibo.in/verify-agreement/')
         || coalesce(p_code, '')
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE CONTRACT PAYLOAD — one RPC, every word finished.
-- ─────────────────────────────────────────────────────────────────────────────
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
  v_status_tone text; v_lic jsonb; v_zone_rows jsonb;
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

  -- ── schedule B: the licences, with the backend's own expiry words ─────────
  v_lic := (
    select coalesce(jsonb_agg(x order by x->>'ord'), '[]'::jsonb) from (
      select jsonb_build_object('ord','1','licence', public._c('agree_pdf.lic_gst'),
               'number', coalesce(nullif(rp.gstin,''), public._c('agree_pdf.lic_none')),
               'expiry', case when rp.gstin_expiry is null then public._c('agree_pdf.lic_no_expiry')
                              else to_char(rp.gstin_expiry,'DD/MM/YYYY') end,
               'state', public._c1986_lic_state(rp.gstin, rp.gstin_expiry)) as x
      union all
      select jsonb_build_object('ord','2','licence', public._c('agree_pdf.lic_20b'),
               'number', coalesce(nullif(rp.dl_20b,''), public._c('agree_pdf.lic_none')),
               'expiry', case when rp.dl_20b_expiry is null then public._c('agree_pdf.lic_no_expiry')
                              else to_char(rp.dl_20b_expiry,'DD/MM/YYYY') end,
               'state', public._c1986_lic_state(rp.dl_20b, rp.dl_20b_expiry))
      union all
      select jsonb_build_object('ord','3','licence', public._c('agree_pdf.lic_21b'),
               'number', coalesce(nullif(rp.dl_21b,''), public._c('agree_pdf.lic_none')),
               'expiry', case when rp.dl_21b_expiry is null then public._c('agree_pdf.lic_no_expiry')
                              else to_char(rp.dl_21b_expiry,'DD/MM/YYYY') end,
               'state', public._c1986_lic_state(rp.dl_21b, rp.dl_21b_expiry))
    ) q);

  -- ── schedule C: what the Zone actually is, from the zone's own rows ───────
  v_zone_rows := jsonb_build_array(
    jsonb_build_object('item', public._c('agree_pdf.zc_zone'),
      'detail', coalesce(nullif(z.name,''), tok->>'zone')),
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

  v_sched := jsonb_build_array(
    jsonb_build_object(
      'code', public._c('agree_pdf.sch_a_code'),
      'heading', public._c('agree_pdf.sch_a_heading'),
      'intro', public._c('agree_pdf.sch_a_intro'),
      'columns', jsonb_build_array(
        jsonb_build_object('key','item','label', public._c('agree_pdf.col_item'),'align','left','width',190),
        jsonb_build_object('key','detail','label', public._c('agree_pdf.col_detail'),'align','left','width',0)),
      'rows', jsonb_build_array(
        jsonb_build_object('item', public._c('partner_agree.t_split'),
                           'detail', (tok->>'split_pct') || '%'),
        jsonb_build_object('item', public._c('partner_agree.t_cadence'),
                           'detail', tok->>'cadence'),
        jsonb_build_object('item', public._c('partner_agree.t_exit'),
                           'detail', public._cf('partner_agree.t_exit_value',
                                       jsonb_build_object('n', tok->>'exit_notice_days'))),
        jsonb_build_object('item', public._c('agree_pdf.sch_a_currency'),
                           'detail', public._c('agree_pdf.sch_a_inr'))),
      'empty_label', '',
      'notes', jsonb_build_array(public._c('agree_pdf.sch_a_note'))),
    jsonb_build_object(
      'code', public._c('agree_pdf.sch_b_code'),
      'heading', public._c('agree_pdf.sch_b_heading'),
      'intro', public._c('agree_pdf.sch_b_intro'),
      'columns', jsonb_build_array(
        jsonb_build_object('key','licence','label', public._c('agree_pdf.col_licence'),'align','left','width',150),
        jsonb_build_object('key','number','label', public._c('agree_pdf.col_number'),'align','left','width',0),
        jsonb_build_object('key','expiry','label', public._c('agree_pdf.col_expiry'),'align','right','width',90),
        jsonb_build_object('key','state','label', public._c('agree_pdf.col_state'),'align','right','width',90)),
      'rows', v_lic, 'empty_label', public._c('agree_pdf.sch_b_empty'),
      'notes', jsonb_build_array(public._c('agree_pdf.sch_b_note'))),
    jsonb_build_object(
      'code', public._c('agree_pdf.sch_c_code'),
      'heading', public._c('agree_pdf.sch_c_heading'),
      'intro', public._c('agree_pdf.sch_c_intro'),
      'columns', jsonb_build_array(
        jsonb_build_object('key','item','label', public._c('agree_pdf.col_item'),'align','left','width',190),
        jsonb_build_object('key','detail','label', public._c('agree_pdf.col_detail'),'align','left','width',0)),
      'rows', v_zone_rows, 'empty_label', public._c('agree_pdf.sch_c_empty'),
      'notes', jsonb_build_array(public._c('agree_pdf.sch_c_note'))));

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

-- "valid / expiring / expired / missing", in the backend's words, once.
create or replace function public._c1986_lic_state(p_number text, p_expiry date)
returns text language sql stable security definer set search_path to 'public' as $$
  select case
    when coalesce(p_number,'') = ''                       then public._c('agree_pdf.lic_missing')
    when p_expiry is null                                 then public._c('agree_pdf.lic_on_file')
    when p_expiry < current_date                          then public._c('agree_pdf.lic_expired')
    when p_expiry <= current_date + 30                    then public._c('agree_pdf.lic_expiring')
    else public._c('agree_pdf.lic_valid') end
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE PUBLIC VERIFY PAGE — what the footer QR opens. Anonymous on purpose:
--    a printed contract is read by people with no mediBO login. It discloses
--    nothing but what is already printed on the page in the reader's hand.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.agreement_verify(p_code text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_code text := upper(btrim(coalesce(p_code,'')));
  v_sig_id bigint; v_hash text; s public.partner_agreement_signature%rowtype;
  rp public.region_partners%rowtype; v public.partner_agreement_version%rowtype;
  pi public.platform_identity%rowtype; v_live jsonb; v_rows jsonb; v_state text;
begin
  if v_code = '' then
    return jsonb_build_object('ok', false, 'state','unknown',
      'heading', public._c('agree_verify.heading'),
      'status_label', public._c('agree_verify.st_unknown'),
      'status_tone','danger',
      'message', public._c('agree_verify.unknown_body'),
      'rows', '[]'::jsonb, 'note', public._c('agree_verify.note'));
  end if;

  -- A preview code is a real answer, not an error: it says plainly that this
  -- page was a draft and nobody signed it.
  if left(v_code,1) = 'P' then
    return jsonb_build_object('ok', true, 'state','preview',
      'heading', public._c('agree_verify.heading'),
      'status_label', public._c('agree_verify.st_preview'),
      'status_tone','warning',
      'message', public._c('agree_verify.preview_body'),
      'rows', jsonb_build_array(jsonb_build_object(
        'label', public._c('agree_verify.f_code'), 'value', v_code)),
      'note', public._c('agree_verify.note'));
  end if;

  v_sig_id := nullif(regexp_replace(split_part(v_code,'-',1), '\D', '', 'g'), '')::bigint;
  v_hash   := lower(split_part(v_code,'-',2));
  select * into s from public.partner_agreement_signature where id = v_sig_id;
  if not found or s.status <> 'signed' then
    return jsonb_build_object('ok', false, 'state','unknown',
      'heading', public._c('agree_verify.heading'),
      'status_label', public._c('agree_verify.st_unknown'),
      'status_tone','danger',
      'message', public._c('agree_verify.unknown_body'),
      'rows', jsonb_build_array(jsonb_build_object(
        'label', public._c('agree_verify.f_code'), 'value', v_code)),
      'note', public._c('agree_verify.note'));
  end if;

  select * into rp from public.region_partners where id = s.partner_id;
  select * into v  from public.partner_agreement_version where id = s.version_id;
  select * into pi from public.platform_identity order by id limit 1;

  if lower(left(coalesce(s.body_sha256,''), 12)) <> v_hash then
    v_state := 'mismatch';
  elsif s.voided_at is not null then
    v_state := 'void';
  else
    v_live := public.agreement_render(s.version_id, s.partner_id);
    v_state := case when coalesce(v_live->>'sha256','') = coalesce(s.body_sha256,'')
                    then 'valid' else 'drifted' end;
  end if;

  v_rows := jsonb_build_array(
    jsonb_build_object('label', public._c('agree_verify.f_code'),    'value', v_code),
    jsonb_build_object('label', public._c('agree_verify.f_operator'),
      'value', coalesce(nullif(pi.operator_legal_name,''), nullif(pi.business_name,''), 'mediBO')),
    jsonb_build_object('label', public._c('agree_verify.f_partner'), 'value', coalesce(rp.partner_name,'')),
    jsonb_build_object('label', public._c('agree_verify.f_version'), 'value', s.version::text),
    jsonb_build_object('label', public._c('agree_verify.f_signed'),
      'value', public.ist_fmt(s.signed_at,'dmy_hm')),
    jsonb_build_object('label', public._c('agree_verify.f_signer'),  'value', coalesce(s.signer_name,'')),
    jsonb_build_object('label', public._c('agree_verify.f_hash'),    'value', coalesce(s.body_sha256,'')));

  return jsonb_build_object('ok', v_state = 'valid', 'state', v_state,
    'heading', public._c('agree_verify.heading'),
    'status_label', public._c('agree_verify.st_' || v_state),
    'status_tone', case v_state when 'valid' then 'success'
                                when 'drifted' then 'warning'
                                when 'void' then 'danger' else 'danger' end,
    'message', public._c('agree_verify.' || v_state || '_body'),
    'rows', v_rows,
    'note', public._c('agree_verify.note'));
end $$;

revoke all on function public.agreement_verify(text) from public;
grant execute on function public.agreement_verify(text) to anon, authenticated;
grant execute on function public.agreement_contract_doc(bigint, bigint, bigint) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. THE PIPELINE — the same renderer prints the preview and the signed copy.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.partner_doc_request(p_kind text, p_ref text)
returns jsonb language plpgsql security definer set search_path to 'public','net' as $$
declare
  v_pid bigint := public.my_partner_id();
  v_admin boolean := public.role_for_medibo_only() in ('admin','super_admin');
  v_period bigint; v_sig bigint; v_ver bigint; pay jsonb;
  d public.partner_document%rowtype; v_id uuid;
  s public.partner_agreement_signature%rowtype;
begin
  -- ── the UNSIGNED preview (CMD #1986) ─────────────────────────────────────
  if coalesce(p_kind,'') = 'agreement_preview' then
    if v_pid is null and v_admin then
      v_pid := nullif(regexp_replace(coalesce(p_ref,''), '\D', '', 'g'),'')::bigint;
    end if;
    if v_pid is null then
      return jsonb_build_object('ok', false, 'error','not_partner',
        'message', public._c('partner_doc.err_not_partner'));
    end if;
    pay := public.agreement_contract_doc(v_pid, null, null);
    if coalesce(pay->>'ok','false') <> 'true' then
      return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','not_found'),
        'message', coalesce(nullif(pay->>'message',''), public._c('partner_doc.err_not_found')));
    end if;
    v_ver := (pay->>'version_id')::bigint;

    insert into public.partner_document(
        partner_id, kind, ref_key, title, file_name, status, attempts,
        source_stamp, requested_by, requested_at, started_at, last_error)
    values (v_pid, 'agreement_preview', v_ver::text, pay->>'title',
            pay->>'file_name', 'queued', 0,
            'prev' || v_ver::text || ':' || left(coalesce(pay#>>'{verify,sha256}',''), 12),
            auth.uid(), now(), null, null)
    on conflict (partner_id, kind, ref_key) do update
      set title = excluded.title, file_name = excluded.file_name,
          status = 'queued', attempts = 0, source_stamp = excluded.source_stamp,
          requested_by = excluded.requested_by, requested_at = now(),
          started_at = null, last_error = null
    returning id into v_id;

    perform net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/agreement-pdf',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027',
                                    'Authorization','Bearer ' || public._service_key()),
      body    := jsonb_build_object('partner_doc_id', v_id),
      timeout_milliseconds := 25000);

    return jsonb_build_object('ok', true, 'status','building', 'doc_id', v_id,
      'poll_ms', 1500, 'message', public._c('partner_doc.building_message'));
  end if;

  if coalesce(p_kind,'') = 'agreement' then
    v_sig := nullif(regexp_replace(coalesce(p_ref,''), '\D', '', 'g'),'')::bigint;
    select * into s from public.partner_agreement_signature where id = v_sig;
    if not found then
      return jsonb_build_object('ok', false, 'error','not_found',
        'message', public._c('partner_doc.err_not_found'));
    end if;
    if v_pid is null and v_admin then v_pid := s.partner_id; end if;
    if v_pid is distinct from s.partner_id and not v_admin then
      return jsonb_build_object('ok', false, 'error','not_partner',
        'message', public._c('partner_doc.err_not_partner'));
    end if;
    v_pid := s.partner_id;

    pay := public.agreement_contract_doc(null, null, v_sig);
    if coalesce(pay->>'ok','false') <> 'true' then
      return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','not_found'),
        'message', coalesce(nullif(pay->>'message',''), public._c('partner_doc.err_not_found')));
    end if;

    -- A typeset copy supersedes a flat one: the stamp carries the renderer
    -- generation, so the first request after this change re-renders rather
    -- than handing back the old plain-text file.
    select * into d from public.partner_document
     where partner_id = v_pid and kind = 'agreement' and ref_key = v_sig::text;
    if found and d.status = 'ready' and coalesce(d.path,'') <> ''
       and d.source_stamp = 'c1986:sig' || v_sig::text then
      return jsonb_build_object('ok', true, 'status','ready', 'doc_id', d.id,
        'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name,
        'expires_s', 300, 'message', public._c('partner_doc.ready_message'));
    end if;

    insert into public.partner_document(
        partner_id, kind, ref_key, title, file_name, status, attempts,
        source_stamp, requested_by, requested_at, started_at, last_error)
    values (v_pid, 'agreement', v_sig::text, pay->>'title', pay->>'file_name',
            'queued', 0, 'c1986:sig' || v_sig::text, auth.uid(), now(), null, null)
    on conflict (partner_id, kind, ref_key) do update
      set title = excluded.title, file_name = excluded.file_name,
          status = 'queued', attempts = 0, source_stamp = excluded.source_stamp,
          requested_by = excluded.requested_by, requested_at = now(),
          started_at = null, last_error = null
    returning id into v_id;

    update public.partner_agreement_signature set doc_id = v_id, updated_at = now()
     where id = v_sig;

    perform net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/agreement-pdf',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027',
                                    'Authorization','Bearer ' || public._service_key()),
      body    := jsonb_build_object('partner_doc_id', v_id),
      timeout_milliseconds := 25000);

    return jsonb_build_object('ok', true, 'status','building', 'doc_id', v_id,
      'poll_ms', 1500, 'message', public._c('partner_doc.building_message'));
  end if;

  if v_pid is null and v_admin then
    select p.partner_id into v_pid from partner_settlement_periods p
     where p.id = nullif(regexp_replace(coalesce(p_ref,''), '\D', '', 'g'),'')::bigint;
  end if;
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','not_partner',
      'message', public._c('partner_doc.err_not_partner'));
  end if;
  if coalesce(p_kind,'') <> 'statement' then
    return jsonb_build_object('ok', false, 'error','unknown_kind',
      'message', public._c('partner_doc.err_unknown_kind'));
  end if;

  v_period := nullif(regexp_replace(coalesce(p_ref,''), '\D', '', 'g'),'')::bigint;
  if v_period is null then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public._c('partner_doc.err_not_found'));
  end if;

  pay := public._c466_statement_payload(v_pid, v_period);
  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','not_found'),
      'message', public._c('partner_doc.err_not_found'));
  end if;

  select * into d from public.partner_document
   where partner_id = v_pid and kind = p_kind and ref_key = v_period::text;

  if found and d.status = 'ready' and coalesce(d.path,'') <> ''
     and d.source_stamp is not distinct from (pay->>'stamp') then
    return jsonb_build_object('ok', true, 'status','ready', 'doc_id', d.id,
      'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name,
      'expires_s', 300, 'message', public._c('partner_doc.ready_message'),
      'gst', pay->'gst');
  end if;

  insert into public.partner_document(
      partner_id, kind, ref_key, title, file_name, status, attempts,
      source_stamp, requested_by, requested_at, started_at, last_error)
  values (v_pid, p_kind, v_period::text, pay->>'title', pay->>'file_name',
          'queued', 0, pay->>'stamp', auth.uid(), now(), null, null)
  on conflict (partner_id, kind, ref_key) do update
    set title = excluded.title, file_name = excluded.file_name,
        status = 'queued', attempts = 0, source_stamp = excluded.source_stamp,
        requested_by = excluded.requested_by, requested_at = now(),
        started_at = null, last_error = null
  returning id into v_id;

  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-render',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027',
                                  'Authorization','Bearer ' || public._service_key()),
    body    := jsonb_build_object('supplier_doc_id', v_id),
    timeout_milliseconds := 20000);

  return jsonb_build_object('ok', true, 'status','building', 'doc_id', v_id,
    'poll_ms', 1500, 'message', public._c('partner_doc.building_message'),
    'gst', pay->'gst');
end $$;

-- The render input the new function asks for: the contract payload, the bucket
-- and the path. Both agreement kinds land in the partner's own folder.
create or replace function public.agreement_pdf_input(p_doc_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare d public.partner_document%rowtype; pay jsonb;
begin
  select * into d from public.partner_document where id = p_doc_id;
  if not found then return jsonb_build_object('ok', false, 'error','doc_not_found'); end if;

  update public.partner_document
     set status = 'running', attempts = attempts + 1, started_at = now()
   where id = p_doc_id;

  if d.kind = 'agreement' then
    pay := public.agreement_contract_doc(null, null, nullif(regexp_replace(d.ref_key,'\D','','g'),'')::bigint);
  elsif d.kind = 'agreement_preview' then
    pay := public.agreement_contract_doc(d.partner_id,
             nullif(regexp_replace(d.ref_key,'\D','','g'),'')::bigint, null);
  else
    return jsonb_build_object('ok', false, 'error','wrong_kind');
  end if;

  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','no_payload'));
  end if;

  return jsonb_build_object('ok', true,
    'doc_id', d.id,
    'bucket', 'partner-receipts',
    'path', 'p' || d.partner_id::text || '/' || d.kind || '/'
            || regexp_replace(d.ref_key, '[^0-9A-Za-z_-]', '', 'g') || '.pdf',
    'file_name', coalesce(nullif(d.file_name,''), 'agreement.pdf'),
    'contract', pay);
end $$;

revoke all on function public.agreement_pdf_input(uuid) from public, anon;
grant execute on function public.agreement_pdf_input(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. THE DOOR — the partner (and the office) can ask for the preview before
--    signing, and open the typeset copy after. Added to the card as extra keys
--    so #1985's partner_agreement_card() is left exactly as it is.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._c1986_doc_actions(p_partner_id bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare cur public.partner_agreement_version%rowtype;
begin
  cur := public._c692_current_version();
  return jsonb_build_object(
    'preview_label', public._c('agree_pdf.preview_label'),
    'preview_hint',  public._c('agree_pdf.preview_hint'),
    'can_preview',   cur.id is not null,
    'preview_ref',   coalesce(p_partner_id::text,''),
    'preview_building_label', public._c('agree_pdf.preview_building'),
    'verify_hint',   public._c('agree_pdf.verify_hint'));
end $$;

create or replace function public.partner_documents_screen(p_partner_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_pid bigint := public._c692_pid(p_partner_id); v_kyc jsonb;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_agree.err_no_partner'));
  end if;
  v_kyc := public.partner_kyc_card(v_pid);
  if coalesce((v_kyc->>'ok')::boolean,false) = false then return v_kyc; end if;
  return jsonb_build_object('ok', true,
    'partner_id', v_pid,
    'partner_name', v_kyc->>'partner_name',
    'title', public._c('partner_kyc.heading'),
    'golive',    public.partner_golive_state(v_pid),
    'agreement', public.partner_agreement_card(v_pid) || public._c1986_doc_actions(v_pid),
    'kyc',       v_kyc,
    'licence',   public.partner_licence_card(v_pid));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. COPY — every word the contract and the verify page print.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
 ('agree_pdf.verify_base',     '"https://medibo.in/verify-agreement/"'::jsonb),
 ('agree_pdf.cover_kicker',    '"Fulfilment partner agreement"'::jsonb),
 ('agree_pdf.cover_between',   '"This Agreement is made between"'::jsonb),
 ('agree_pdf.cover_and',       '"and"'::jsonb),
 ('agree_pdf.cover_note',      '"Executed electronically. Each page carries the agreement number, the version and an initials line for both Parties."'::jsonb),
 ('agree_pdf.status_signed',   '"Signed on {d} IST"'::jsonb),
 ('agree_pdf.status_draft',    '"Draft — not signed. For review only."'::jsonb),
 ('agree_pdf.m_id',            '"Agreement no."'::jsonb),
 ('agree_pdf.m_version',       '"Version"'::jsonb),
 ('agree_pdf.m_from',          '"Effective from"'::jsonb),
 ('agree_pdf.m_to',            '"Effective to"'::jsonb),
 ('agree_pdf.m_zone',          '"Zone"'::jsonb),
 ('agree_pdf.p_gstin',         '"GSTIN {v}"'::jsonb),
 ('agree_pdf.p_udyam',         '"Udyam {v}"'::jsonb),
 ('agree_pdf.p_dl',            '"Drug licences 20B {a} · 21B {b}"'::jsonb),
 ('agree_pdf.lh_udyam',        '"Udyam {u}"'::jsonb),
 ('agree_pdf.page_fmt',        '"Page {p} of {n}"'::jsonb),
 ('agree_pdf.init_operator',   '"Operator"'::jsonb),
 ('agree_pdf.init_partner',    '"Partner"'::jsonb),
 ('agree_pdf.h_contents',      '"Contents"'::jsonb),
 ('agree_pdf.h_page',          '"Page"'::jsonb),
 ('agree_pdf.h_recitals',      '"Recitals"'::jsonb),
 ('agree_pdf.h_definitions',   '"Definitions and interpretation"'::jsonb),
 ('agree_pdf.h_terms',         '"Terms agreed"'::jsonb),
 ('agree_pdf.h_schedules',     '"Schedules"'::jsonb),
 ('agree_pdf.h_signatures',    '"Execution"'::jsonb),
 ('agree_pdf.h_verify',        '"Verification"'::jsonb),
 ('agree_pdf.def_lead',        '"In this Agreement, the following capitalised terms have the meanings given to them below. They carry the same meaning wherever they appear, including in the Recitals and the Schedules."'::jsonb),
 ('agree_pdf.def_note',        '"A reference to a Schedule is a reference to a schedule to this Agreement. Headings are for convenience only and do not affect interpretation."'::jsonb),
 ('agree_pdf.badge_negotiated','"Negotiated"'::jsonb),
 ('agree_pdf.sch_a_code',      '"Schedule A"'::jsonb),
 ('agree_pdf.sch_a_heading',   '"Commercial terms"'::jsonb),
 ('agree_pdf.sch_a_intro',     '"These are the terms the Platform settles on. They are read from the Zone''s own settlement record, so what is printed here and what is paid out are the same number."'::jsonb),
 ('agree_pdf.sch_a_currency',  '"Currency"'::jsonb),
 ('agree_pdf.sch_a_inr',       '"Indian Rupees (INR)"'::jsonb),
 ('agree_pdf.sch_a_note',      '"A change to any figure in this Schedule takes effect only through a new version of this Agreement, signed by both Parties."'::jsonb),
 ('agree_pdf.sch_b_code',      '"Schedule B"'::jsonb),
 ('agree_pdf.sch_b_heading',   '"Licences and expiry"'::jsonb),
 ('agree_pdf.sch_b_intro',     '"The Licences the Partner holds, as recorded on the Platform on the date this copy was produced."'::jsonb),
 ('agree_pdf.sch_b_empty',     '"No licence is on file."'::jsonb),
 ('agree_pdf.sch_b_note',      '"The Partner re-uploads each Licence before it expires. A lapsed Licence suspends the Partner until it is renewed."'::jsonb),
 ('agree_pdf.sch_c_code',      '"Schedule C"'::jsonb),
 ('agree_pdf.sch_c_heading',   '"Zone coverage"'::jsonb),
 ('agree_pdf.sch_c_intro',     '"The Zone assigned to the Partner, and the delivery terms the Platform applies inside it."'::jsonb),
 ('agree_pdf.sch_c_empty',     '"No zone is assigned yet."'::jsonb),
 ('agree_pdf.sch_c_note',      '"The Operator may vary the Zone on notice to the Partner; a variation is recorded in a new version of this Schedule."'::jsonb),
 ('agree_pdf.col_item',        '"Item"'::jsonb),
 ('agree_pdf.col_detail',      '"Detail"'::jsonb),
 ('agree_pdf.col_licence',     '"Licence"'::jsonb),
 ('agree_pdf.col_number',      '"Number"'::jsonb),
 ('agree_pdf.col_expiry',      '"Expires"'::jsonb),
 ('agree_pdf.col_state',       '"Status"'::jsonb),
 ('agree_pdf.lic_gst',         '"GST registration"'::jsonb),
 ('agree_pdf.lic_20b',         '"Drug licence Form 20B"'::jsonb),
 ('agree_pdf.lic_21b',         '"Drug licence Form 21B"'::jsonb),
 ('agree_pdf.lic_none',        '"Not on file"'::jsonb),
 ('agree_pdf.lic_no_expiry',   '"No expiry recorded"'::jsonb),
 ('agree_pdf.lic_missing',     '"Missing"'::jsonb),
 ('agree_pdf.lic_on_file',     '"On file"'::jsonb),
 ('agree_pdf.lic_expired',     '"Expired"'::jsonb),
 ('agree_pdf.lic_expiring',    '"Expiring"'::jsonb),
 ('agree_pdf.lic_valid',       '"Valid"'::jsonb),
 ('agree_pdf.zc_zone',         '"Zone"'::jsonb),
 ('agree_pdf.zc_code',         '"Zone code"'::jsonb),
 ('agree_pdf.zc_district',     '"Principal place of business"'::jsonb),
 ('agree_pdf.zc_serviceable',  '"Open for delivery"'::jsonb),
 ('agree_pdf.zc_promise',      '"Delivery promise"'::jsonb),
 ('agree_pdf.zc_area',         '"Area covered"'::jsonb),
 ('agree_pdf.zc_minutes',      '"{n} minutes"'::jsonb),
 ('agree_pdf.zc_yes',          '"Yes"'::jsonb),
 ('agree_pdf.zc_no',           '"No"'::jsonb),
 ('agree_pdf.for_operator',    '"For and on behalf of the Operator"'::jsonb),
 ('agree_pdf.for_partner',     '"For and on behalf of the Partner"'::jsonb),
 ('agree_pdf.role_operator',   '"Operator"'::jsonb),
 ('agree_pdf.role_partner',    '"Partner"'::jsonb),
 ('agree_pdf.f_name',          '"Name"'::jsonb),
 ('agree_pdf.f_role',          '"Designation"'::jsonb),
 ('agree_pdf.f_for',           '"On behalf of"'::jsonb),
 ('agree_pdf.f_gstin',         '"GSTIN"'::jsonb),
 ('agree_pdf.f_udyam',         '"Udyam"'::jsonb),
 ('agree_pdf.f_date',          '"Date"'::jsonb),
 ('agree_pdf.f_method',        '"Method"'::jsonb),
 ('agree_pdf.f_phone',         '"Mobile"'::jsonb),
 ('agree_pdf.f_ip',            '"IP address"'::jsonb),
 ('agree_pdf.blank',           '"—"'::jsonb),
 ('agree_pdf.method_otp',      '"WhatsApp one-time code"'::jsonb),
 ('agree_pdf.method_platform', '"Accepted on the mediBO platform"'::jsonb),
 ('agree_pdf.sig_lead_signed', '"The Parties have executed this Agreement on the dates shown below."'::jsonb),
 ('agree_pdf.sig_lead_preview','"This is an unsigned preview. Nothing below binds either Party until the Partner signs on the mediBO platform."'::jsonb),
 ('agree_pdf.sig_note_signed', '"Accepted electronically with a one-time code sent to {phone} on WhatsApp at {d} IST. The signature is recorded against this agreement number."'::jsonb),
 ('agree_pdf.sig_note_preview','"Sign this agreement from My documents on the mediBO app. The signed copy carries the signer''s name, the time, the method and the IP address."'::jsonb),
 ('agree_pdf.verify_line',     '"Scan to confirm this copy against the signature mediBO holds."'::jsonb),
 ('agree_pdf.verify_caption',  '"SHA-256 {h}…"'::jsonb),
 ('agree_pdf.preview_label',   '"Preview the agreement (PDF)"'::jsonb),
 ('agree_pdf.preview_hint',    '"An unsigned copy, laid out exactly as the signed one will be."'::jsonb),
 ('agree_pdf.preview_building','"Preparing the preview…"'::jsonb),
 ('agree_pdf.verify_hint',     '"Every page carries a QR code. Scanning it opens a public page that confirms the copy against the signature mediBO holds."'::jsonb),
 ('agree_pdf.err_not_signed',  '"That agreement has not been signed."'::jsonb),
 ('agree_pdf.err_no_version',  '"There is no published agreement to print yet."'::jsonb),
 ('agree_pdf.err_no_partner',  '"That partner is not on file."'::jsonb),
 ('agree_verify.heading',      '"Agreement verification"'::jsonb),
 ('agree_verify.st_valid',     '"Verified"'::jsonb),
 ('agree_verify.st_drifted',   '"Signed — wording has since changed"'::jsonb),
 ('agree_verify.st_mismatch',  '"Does not match"'::jsonb),
 ('agree_verify.st_void',      '"Withdrawn"'::jsonb),
 ('agree_verify.st_unknown',   '"Not found"'::jsonb),
 ('agree_verify.st_preview',   '"Unsigned preview"'::jsonb),
 ('agree_verify.valid_body',   '"This copy matches the agreement mediBO holds, word for word. The signature details below are the ones recorded when it was signed."'::jsonb),
 ('agree_verify.drifted_body', '"The signature below is genuine, but the agreement has been re-worded since it was signed. The copy in your hand is the text that was signed."'::jsonb),
 ('agree_verify.mismatch_body','"The code is for an agreement mediBO holds, but the fingerprint printed on this copy does not match it. Do not rely on this copy."'::jsonb),
 ('agree_verify.void_body',    '"This signature has been withdrawn. The agreement it covered is no longer in force."'::jsonb),
 ('agree_verify.unknown_body', '"No signed agreement carries this code. Check the code printed under the QR on the last page."'::jsonb),
 ('agree_verify.preview_body', '"This code belongs to an unsigned preview. Nobody has signed it, and it binds no one."'::jsonb),
 ('agree_verify.f_code',       '"Code"'::jsonb),
 ('agree_verify.f_operator',   '"Operator"'::jsonb),
 ('agree_verify.f_partner',    '"Partner"'::jsonb),
 ('agree_verify.f_version',    '"Version"'::jsonb),
 ('agree_verify.f_signed',     '"Signed at"'::jsonb),
 ('agree_verify.f_signer',     '"Signed by"'::jsonb),
 ('agree_verify.f_hash',       '"SHA-256 of the signed text"'::jsonb),
 ('agree_verify.note',         '"This page is public on purpose: a printed contract is read by people with no mediBO login. It shows only what is already printed on the copy in your hand."'::jsonb)
on conflict (key) do update set value = excluded.value;

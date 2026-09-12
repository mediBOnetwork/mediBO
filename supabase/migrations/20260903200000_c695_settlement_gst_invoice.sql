-- CHANGE #695 — a GST tax invoice on every partner settlement.
--
-- settlement_settle() closed a period and produced a STATEMENT: a working
-- document that tells a partner what they earned. It is not a tax document.
-- The fee/commission leg of every settlement is a supply of services between
-- two GST-registered persons, and neither side could file it: no invoice
-- number, no HSN/SAC, no place of supply, no CGST/SGST split, nothing for the
-- CA to put in a GSTR-1. This change issues the invoice the settlement always
-- implied, in whichever direction the money actually moved.
--
-- Everything here is DATA the backend decides. The rate and the SAC live in
-- settlement_config so the CA changes them with an UPDATE; the issuer identity
-- is billing_config (mediBO) or region_partners (the partner); the split is
-- CGST/SGST when both parties sit in one state and IGST when they do not; and
-- every rupee, label and number is formatted here so Flutter prints it.

-- ── 1. Config: the rate and the SAC are not written into a function ─────────
alter table public.settlement_config
  add column if not exists fee_gst_rate numeric not null default 18,
  add column if not exists fee_sac_code text not null default '9971',
  add column if not exists fee_description text not null default
    'Platform commission on settled orders',
  add column if not exists invoice_prefix_medibo text not null default 'MBS',
  add column if not exists invoice_prefix_partner text not null default 'PRS';

insert into public.settlement_config (id) values (1) on conflict (id) do nothing;

-- ── 2. The number series — per ISSUER, per financial year ───────────────────
-- Same shape as the debit-note series (#710): the row is created on first use
-- and the counter is bumped under the row lock, so two settlements closed in
-- the same second cannot draw the same number.
create table if not exists public.settlement_invoice_series (
  issuer_key text     not null,
  fy         text     not null,
  prefix     text     not null,
  next_no    integer  not null default 1,
  updated_at timestamptz not null default now(),
  primary key (issuer_key, fy)
);

create table if not exists public.settlement_invoice (
  id                uuid primary key default gen_random_uuid(),
  period_id         bigint      not null references public.partner_settlement_periods(id) on delete cascade,
  partner_id        bigint      not null,
  zone_id           smallint,
  doc_kind          text        not null default 'tax_invoice',   -- tax_invoice | credit_note
  parent_invoice_id uuid        references public.settlement_invoice(id) on delete set null,
  direction         text        not null,   -- medibo_to_partner | partner_to_medibo
  issuer_key        text        not null,   -- medibo | partner
  issuer_name       text        not null default '',
  issuer_gstin      text        not null default '',
  issuer_address    text        not null default '',
  issuer_state      text        not null default '',
  recipient_name    text        not null default '',
  recipient_gstin   text        not null default '',
  recipient_address text        not null default '',
  recipient_state   text        not null default '',
  place_of_supply   text        not null default '',
  pos_code          text        not null default '',
  sac_code          text        not null default '',
  description       text        not null default '',
  invoice_no        text        not null,
  invoice_date      date        not null default (now() at time zone 'Asia/Kolkata')::date,
  taxable           numeric     not null default 0,
  gst_rate          numeric     not null default 0,
  cgst              numeric     not null default 0,
  sgst              numeric     not null default 0,
  igst              numeric     not null default 0,
  total             numeric     not null default 0,
  is_interstate     boolean     not null default false,
  status            text        not null default 'issued',        -- issued | cancelled
  reason            text        not null default '',
  pdf_bucket        text,
  pdf_path          text,
  pdf_name          text,
  pdf_status        text        not null default 'idle',          -- idle|queued|ready|error
  pdf_error         text,
  pdf_bytes         integer,
  wa_sent_at        timestamptz,
  is_synthetic      boolean     not null default false,
  created_at        timestamptz not null default now(),
  created_by        text        not null default ''
);

create unique index if not exists settlement_invoice_no_key
  on public.settlement_invoice (invoice_no);
-- One TAX INVOICE per period. A credit note is a second row against the same
-- period, so the partial index is what blocks a regenerate rather than a flag
-- somebody has to remember to check.
create unique index if not exists settlement_invoice_one_per_period
  on public.settlement_invoice (period_id)
  where doc_kind = 'tax_invoice' and status = 'issued';
create index if not exists settlement_invoice_partner_idx
  on public.settlement_invoice (partner_id, invoice_date desc);
create index if not exists settlement_invoice_month_idx
  on public.settlement_invoice (invoice_date);

alter table public.settlement_invoice        enable row level security;
alter table public.settlement_invoice_series enable row level security;

-- ── 3. Copy — every string the screens print ────────────────────────────────
insert into public.settlement_label (key, label) values
  ('inv.tab',              'Tax invoices'),
  ('inv.heading',          'GST tax invoices'),
  ('inv.empty',            'No tax invoice has been issued yet. Settle a period and its invoice is raised automatically.'),
  ('inv.tax_invoice',      'Tax invoice'),
  ('inv.credit_note',      'Credit note'),
  ('inv.issued',           'Issued'),
  ('inv.cancelled',        'Cancelled'),
  ('inv.dir_medibo',       'mediBO to partner'),
  ('inv.dir_partner',      'Partner to mediBO'),
  ('inv.download',         'Download PDF'),
  ('inv.building',         'Preparing the invoice…'),
  ('inv.ready',            'Invoice ready'),
  ('inv.wa_sent',          'Sent on WhatsApp'),
  ('inv.wa_send',          'Send on WhatsApp'),
  ('inv.credit_note_make', 'Raise credit note'),
  ('inv.taxable_label',    'Taxable value'),
  ('inv.cgst_label',       'CGST'),
  ('inv.sgst_label',       'SGST'),
  ('inv.igst_label',       'IGST'),
  ('inv.net_label',        'Invoice total'),
  ('inv.no_label',         'Invoice no.'),
  ('inv.date_label',       'Invoice date'),
  ('inv.pos_label',        'Place of supply'),
  ('inv.sac_label',        'SAC'),
  ('inv.issuer_heading',   'Supplier'),
  ('inv.recipient_heading','Recipient'),
  ('inv.col_desc',         'Description'),
  ('inv.col_sac',          'SAC'),
  ('inv.col_taxable',      'Taxable'),
  ('inv.col_rate',         'Rate'),
  ('inv.col_amount',       'Amount'),
  ('inv.register_heading', 'GSTR-1 register'),
  ('inv.register_empty',   'No invoice was issued in this month.'),
  ('inv.register_download','Download register'),
  ('inv.err_not_settled',  'This period is not settled yet, so there is nothing to invoice.'),
  ('inv.err_already',      'A tax invoice has already been issued for this period.'),
  ('inv.err_no_gstin',     'This partner has no GSTIN on record, so a tax invoice cannot be raised.'),
  ('inv.err_zero',         'The fee leg of this settlement is zero, so no tax invoice is due.'),
  ('inv.err_not_found',    'That invoice no longer exists.'),
  ('inv.err_cn_exists',    'A credit note has already been raised against this invoice.'),
  ('inv.cn_reason',        'Adjustment after settlement recalculation'),
  ('inv.footer',           'This is a computer-generated tax invoice.')
on conflict (key) do nothing;

-- ── 4. The tax engine ───────────────────────────────────────────────────────
-- India's state codes, so place-of-supply is the GSTIN's own first two digits
-- rather than a guess made from a free-text state name. A GSTIN we cannot read
-- falls back to the written state, and an unknown state is honestly blank —
-- never silently "22", which would make an interstate supply look local.
create or replace function public._c695_state_code(p_gstin text, p_state text)
returns text language sql immutable as $$
  select coalesce(
    nullif(substring(btrim(coalesce(p_gstin,'')) from '^[0-9]{2}'), ''),
    case lower(btrim(coalesce(p_state,'')))
      when 'chhattisgarh'   then '22'
      when 'madhya pradesh' then '23'
      when 'maharashtra'    then '27'
      when 'odisha'         then '21'
      when 'jharkhand'      then '20'
      when 'gujarat'        then '24'
      when 'karnataka'      then '29'
      when 'telangana'      then '36'
      when 'andhra pradesh' then '37'
      when 'uttar pradesh'  then '09'
      when 'delhi'          then '07'
      when 'west bengal'    then '19'
      when 'rajasthan'      then '08'
      when 'bihar'          then '10'
      when 'tamil nadu'     then '33'
      when 'kerala'         then '32'
      when 'punjab'         then '03'
      when 'haryana'        then '06'
      else '' end)
$$;

-- The split. Interstate is decided by the two state CODES, never by comparing
-- state NAMES: "Chhattisgarh" and "CHHATTISGARH " are the same state and a
-- string compare would have charged IGST between two Raipur entities.
create or replace function public._c695_tax_split(
  p_taxable numeric, p_rate numeric, p_interstate boolean)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'taxable', round(coalesce(p_taxable,0), 2),
    'rate',    coalesce(p_rate,0),
    'cgst',    case when p_interstate then 0 else round(coalesce(p_taxable,0) * coalesce(p_rate,0) / 200.0, 2) end,
    'sgst',    case when p_interstate then 0 else round(coalesce(p_taxable,0) * coalesce(p_rate,0) / 200.0, 2) end,
    'igst',    case when p_interstate then round(coalesce(p_taxable,0) * coalesce(p_rate,0) / 100.0, 2) else 0 end,
    'total',   round(coalesce(p_taxable,0), 2)
               + case when p_interstate
                      then round(coalesce(p_taxable,0) * coalesce(p_rate,0) / 100.0, 2)
                      else 2 * round(coalesce(p_taxable,0) * coalesce(p_rate,0) / 200.0, 2) end)
$$;

create or replace function public._c695_next_invoice_no(
  p_issuer_key text, p_prefix text, p_synthetic boolean default false)
returns text language plpgsql security definer set search_path to 'public' as $$
declare v_fy text := public._fy_ist(); v_prefix text := coalesce(nullif(p_prefix,''),'INV'); v_no int;
begin
  if p_synthetic then v_fy := 'TEST-' || v_fy; v_prefix := 'TEST'; end if;
  insert into public.settlement_invoice_series (issuer_key, fy, prefix, next_no)
  values (p_issuer_key, v_fy, v_prefix, 1)
  on conflict (issuer_key, fy) do nothing;
  update public.settlement_invoice_series
     set next_no = next_no + 1, updated_at = now()
   where issuer_key = p_issuer_key and fy = v_fy
  returning next_no - 1 into v_no;
  return v_prefix || '/' || v_fy || '/' || to_char(v_no, 'FM0000');
end $$;

-- ── 5. Issue — the direction decides who invoices whom ──────────────────────
-- A settlement is one supply of services, and which way it points is the sign
-- of the fee leg, not a setting. medibo_share > 0 is mediBO's commission on the
-- partner's orders: mediBO is the supplier and raises the invoice. When the
-- share is negative the service ran the other way and the PARTNER invoices
-- mediBO. Zero is not an invoice at all — an invoice for nil is a filing error,
-- not a courtesy, so it is refused with its own sentence.
create or replace function public._c695_issue(p_period_id bigint, p_actor text default '')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  p public.partner_settlement_periods%rowtype;
  rp public.region_partners%rowtype;
  bc public.billing_config%rowtype;
  cfg public.settlement_config%rowtype;
  v_fee numeric; v_dir text; v_issuer text; v_prefix text;
  v_i_name text; v_i_gstin text; v_i_addr text; v_i_state text;
  v_r_name text; v_r_gstin text; v_r_addr text; v_r_state text;
  v_i_code text; v_r_code text; v_inter boolean; v_split jsonb;
  v_no text; v_id uuid;
begin
  select * into p from public.partner_settlement_periods where id = p_period_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public._stl_c('inv.err_not_found'));
  end if;
  if p.status <> 'settled' then
    return jsonb_build_object('ok', false, 'error','not_settled',
      'message', public._stl_c('inv.err_not_settled'));
  end if;
  if exists (select 1 from public.settlement_invoice
              where period_id = p_period_id and doc_kind='tax_invoice' and status='issued') then
    return jsonb_build_object('ok', false, 'error','already_issued',
      'message', public._stl_c('inv.err_already'));
  end if;

  select * into rp  from public.region_partners  where id = p.partner_id;
  select * into bc  from public.billing_config   where id = 1;
  select * into cfg from public.settlement_config where id = 1;

  v_fee := round(coalesce(p.medibo_share,0), 2);
  if v_fee = 0 then
    return jsonb_build_object('ok', false, 'error','zero_fee',
      'message', public._stl_c('inv.err_zero'));
  end if;
  if coalesce(btrim(rp.gstin),'') = '' then
    return jsonb_build_object('ok', false, 'error','no_gstin',
      'message', public._stl_c('inv.err_no_gstin'));
  end if;

  if v_fee > 0 then
    v_dir := 'medibo_to_partner'; v_issuer := 'medibo';
    v_prefix  := coalesce(nullif(cfg.invoice_prefix_medibo,''),'MBS');
    v_i_name  := coalesce(bc.seller_name,'');   v_i_gstin := coalesce(bc.seller_gstin,'');
    v_i_addr  := coalesce(bc.seller_address,''); v_i_state := coalesce(bc.seller_state,'');
    v_r_name  := coalesce(rp.partner_name,'');  v_r_gstin := coalesce(rp.gstin,'');
    v_r_addr  := coalesce(rp.address,'');       v_r_state := coalesce(rp.state,'');
  else
    v_dir := 'partner_to_medibo'; v_issuer := 'partner';
    v_prefix  := coalesce(nullif(cfg.invoice_prefix_partner,''),'PRS');
    v_i_name  := coalesce(rp.partner_name,'');  v_i_gstin := coalesce(rp.gstin,'');
    v_i_addr  := coalesce(rp.address,'');       v_i_state := coalesce(rp.state,'');
    v_r_name  := coalesce(bc.seller_name,'');   v_r_gstin := coalesce(bc.seller_gstin,'');
    v_r_addr  := coalesce(bc.seller_address,''); v_r_state := coalesce(bc.seller_state,'');
    v_fee := abs(v_fee);
  end if;

  v_i_code := public._c695_state_code(v_i_gstin, v_i_state);
  v_r_code := public._c695_state_code(v_r_gstin, v_r_state);
  -- Unknown on either side is treated as INTRA-state, matching the operator's
  -- own registration: guessing IGST on missing data would misfile the return.
  v_inter  := (v_i_code <> '' and v_r_code <> '' and v_i_code <> v_r_code);
  v_split  := public._c695_tax_split(v_fee, coalesce(cfg.fee_gst_rate,18), v_inter);
  v_no     := public._c695_next_invoice_no(v_issuer, v_prefix, false);

  insert into public.settlement_invoice
    (period_id, partner_id, zone_id, doc_kind, direction, issuer_key,
     issuer_name, issuer_gstin, issuer_address, issuer_state,
     recipient_name, recipient_gstin, recipient_address, recipient_state,
     place_of_supply, pos_code, sac_code, description, invoice_no,
     taxable, gst_rate, cgst, sgst, igst, total, is_interstate, created_by)
  values
    (p.id, p.partner_id, p.zone_id, 'tax_invoice', v_dir, v_issuer,
     v_i_name, v_i_gstin, v_i_addr, v_i_state,
     v_r_name, v_r_gstin, v_r_addr, v_r_state,
     coalesce(nullif(v_r_state,''), v_r_code), v_r_code,
     coalesce(cfg.fee_sac_code,'9971'), coalesce(cfg.fee_description,''), v_no,
     (v_split->>'taxable')::numeric, coalesce(cfg.fee_gst_rate,18),
     (v_split->>'cgst')::numeric, (v_split->>'sgst')::numeric,
     (v_split->>'igst')::numeric, (v_split->>'total')::numeric,
     v_inter, coalesce(nullif(p_actor,''), 'system'))
  returning id into v_id;

  return jsonb_build_object('ok', true, 'invoice_id', v_id, 'invoice_no', v_no,
    'direction', v_dir, 'total', public.inr_money((v_split->>'total')::numeric));
end $$;

-- ── 6. The hook — settling a period raises its invoice ──────────────────────
-- Re-declared in full (create or replace) rather than patched by a trigger, so
-- the settle path stays one readable function. The invoice is raised AFTER the
-- status flip and its failure never rolls the settlement back: a settled period
-- with no invoice is a fixable row, an invoice against an unsettled period is
-- a filing error. The reason is carried out in `invoice` so the console can say
-- why nothing was raised instead of silently showing no document.
create or replace function public.settlement_settle(p_period_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_mode text; v_frozen boolean; v_inv jsonb;
begin
  if not public.is_admin() then return public._stl_denied(); end if;
  if not exists (select 1 from public.partner_settlement_periods where id = p_period_id) then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.no_period'));
  end if;

  select coalesce(route_mode,'manual') into v_mode from public.settlement_config where id = 1;
  select (state = 'disputed' and resolved_at is null) into v_frozen
    from public.partner_settlement_ack where period_id = p_period_id;

  if coalesce(v_frozen,false) and coalesce(v_mode,'manual') = 'automatic' then
    return jsonb_build_object('ok', false, 'error','disputed_frozen','tone','danger',
      'message', public._pop_c('ack.err_frozen_settle'),
      'statement', public.settlement_statement(p_period_id));
  end if;

  update public.partner_settlement_periods
     set status = 'settled', settled_at = now(),
         settled_by = coalesce(auth.jwt() ->> 'email','admin')
   where id = p_period_id;

  -- CHANGE #695 — the tax document the settlement always implied.
  begin
    v_inv := public._c695_issue(p_period_id, coalesce(auth.jwt() ->> 'email','admin'));
  exception when others then
    v_inv := jsonb_build_object('ok', false, 'error','issue_failed', 'message', sqlerrm);
  end;
  if coalesce((v_inv->>'ok')::boolean,false) then
    perform public.settlement_invoice_request((v_inv->>'invoice_id')::uuid);
  end if;

  return jsonb_build_object('ok', true, 'message', public._stl_c('period.settled_msg'),
                            'invoice', v_inv,
                            'statement', public.settlement_statement(p_period_id));
end $$;

-- ── 7. Credit note — the adjustment, not a second invoice ───────────────────
-- settlement_recalculate() can move a settled period's numbers. GST does not
-- allow the issued invoice to be edited, so the correction is a credit note
-- carrying the DIFFERENCE, issued by whoever issued the original and pointing
-- at it by number. One per invoice: a second correction credits the credit
-- note, which is a different document and a different command.
create or replace function public.settlement_invoice_credit_note(
  p_invoice_id uuid, p_amount numeric default null, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  i public.settlement_invoice%rowtype; cfg public.settlement_config%rowtype;
  v_amt numeric; v_split jsonb; v_no text; v_id uuid; v_prefix text;
begin
  if not public.is_admin() then return public._stl_denied(); end if;
  select * into i from public.settlement_invoice where id = p_invoice_id;
  if not found or i.doc_kind <> 'tax_invoice' then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public._stl_c('inv.err_not_found'));
  end if;
  if exists (select 1 from public.settlement_invoice
              where parent_invoice_id = i.id and doc_kind='credit_note' and status='issued') then
    return jsonb_build_object('ok', false, 'error','credit_note_exists',
      'message', public._stl_c('inv.err_cn_exists'));
  end if;

  select * into cfg from public.settlement_config where id = 1;
  -- No amount given = credit the whole invoice. A given amount is clamped to
  -- the invoice: a credit note larger than the document it corrects is not a
  -- correction, it is a new supply the other way.
  v_amt := least(abs(coalesce(p_amount, i.taxable)), i.taxable);
  if v_amt <= 0 then
    return jsonb_build_object('ok', false, 'error','zero_fee',
      'message', public._stl_c('inv.err_zero'));
  end if;
  v_split := public._c695_tax_split(v_amt, i.gst_rate, i.is_interstate);
  v_prefix := case when i.issuer_key = 'medibo'
                   then coalesce(nullif(cfg.invoice_prefix_medibo,''),'MBS')
                   else coalesce(nullif(cfg.invoice_prefix_partner,''),'PRS') end || '-CN';
  v_no := public._c695_next_invoice_no(i.issuer_key || '_cn', v_prefix, i.is_synthetic);

  insert into public.settlement_invoice
    (period_id, partner_id, zone_id, doc_kind, parent_invoice_id, direction, issuer_key,
     issuer_name, issuer_gstin, issuer_address, issuer_state,
     recipient_name, recipient_gstin, recipient_address, recipient_state,
     place_of_supply, pos_code, sac_code, description, invoice_no,
     taxable, gst_rate, cgst, sgst, igst, total, is_interstate, reason,
     is_synthetic, created_by)
  values
    (i.period_id, i.partner_id, i.zone_id, 'credit_note', i.id, i.direction, i.issuer_key,
     i.issuer_name, i.issuer_gstin, i.issuer_address, i.issuer_state,
     i.recipient_name, i.recipient_gstin, i.recipient_address, i.recipient_state,
     i.place_of_supply, i.pos_code, i.sac_code, i.description, v_no,
     (v_split->>'taxable')::numeric, i.gst_rate,
     (v_split->>'cgst')::numeric, (v_split->>'sgst')::numeric,
     (v_split->>'igst')::numeric, (v_split->>'total')::numeric,
     i.is_interstate, coalesce(nullif(p_reason,''), public._stl_c('inv.cn_reason')),
     i.is_synthetic, coalesce(auth.jwt() ->> 'email','admin'))
  returning id into v_id;

  perform public.settlement_invoice_request(v_id);
  return jsonb_build_object('ok', true, 'invoice_id', v_id, 'invoice_no', v_no,
    'total', public.inr_money((v_split->>'total')::numeric));
end $$;

-- ── 8. The document — the SAME payload shape the px invoice renderer draws ──
-- #420's px-invoice edge function prints a GST tax invoice and computes
-- nothing: parties, meta rows, columns, lines, totals and net all arrive
-- finished. Producing that shape here means the settlement invoice reuses that
-- renderer instead of a second copy of the drawing code, which is the whole
-- point of "via the existing bill generator". If a rupee on the PDF is wrong,
-- the bug is in this function.
create or replace function public.settlement_invoice_render_input(p_invoice_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare i public.settlement_invoice%rowtype; p public.partner_settlement_periods%rowtype;
        v_tot jsonb;
begin
  select * into i from public.settlement_invoice where id = p_invoice_id;
  if not found then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  select * into p from public.partner_settlement_periods where id = i.period_id;

  v_tot := jsonb_build_array(
    jsonb_build_object('label', public._stl_c('inv.taxable_label'), 'value', public.inr_money(i.taxable)));
  if i.is_interstate then
    v_tot := v_tot || jsonb_build_array(jsonb_build_object(
      'label', public._stl_c('inv.igst_label') || ' @ ' || to_char(i.gst_rate,'FM990.##') || '%',
      'value', public.inr_money(i.igst)));
  else
    v_tot := v_tot || jsonb_build_array(
      jsonb_build_object('label', public._stl_c('inv.cgst_label') || ' @ ' || to_char(i.gst_rate/2,'FM990.##') || '%',
                         'value', public.inr_money(i.cgst)),
      jsonb_build_object('label', public._stl_c('inv.sgst_label') || ' @ ' || to_char(i.gst_rate/2,'FM990.##') || '%',
                         'value', public.inr_money(i.sgst)));
  end if;

  return jsonb_build_object(
    'ok', true,
    'bucket', 'customer-bills',
    'path', 'settlement/' || i.partner_id::text || '/' || i.id::text || '.pdf',
    'file_name', replace(i.invoice_no, '/', '-') || '.pdf',
    'invoice', jsonb_build_object(
      'title', case when i.doc_kind = 'credit_note'
                    then public._stl_c('inv.credit_note') else public._stl_c('inv.tax_invoice') end,
      'seller', jsonb_build_object(
        'heading', public._stl_c('inv.issuer_heading'),
        'name', i.issuer_name,
        'address', nullif(btrim(i.issuer_address),''),
        'phone', null,
        'gstin_label', case when btrim(i.issuer_gstin) = '' then null
                            else 'GSTIN: ' || i.issuer_gstin end,
        'dl_label', null),
      'buyer', jsonb_build_object(
        'heading', public._stl_c('inv.recipient_heading'),
        'name', i.recipient_name,
        'address', nullif(btrim(i.recipient_address),''),
        'phone', null,
        'gstin_label', case when btrim(i.recipient_gstin) = '' then null
                            else 'GSTIN: ' || i.recipient_gstin end,
        'dl_label', null),
      'meta', jsonb_build_array(
        jsonb_build_object('label', public._stl_c('inv.no_label'),   'value', i.invoice_no),
        jsonb_build_object('label', public._stl_c('inv.date_label'),
          'value', to_char(i.invoice_date,'DD Mon YYYY')),
        jsonb_build_object('label', public._stl_c('inv.pos_label'),
          'value', btrim(coalesce(i.pos_code,'') || ' ' || coalesce(i.place_of_supply,''))))
        || case when i.parent_invoice_id is null then '[]'::jsonb else jsonb_build_array(
             jsonb_build_object('label', public._stl_c('inv.tax_invoice'),
               'value', coalesce((select invoice_no from public.settlement_invoice
                                   where id = i.parent_invoice_id),''))) end,
      'columns', jsonb_build_array(
        jsonb_build_object('key','desc',   'label', public._stl_c('inv.col_desc')),
        jsonb_build_object('key','sac',    'label', public._stl_c('inv.col_sac')),
        jsonb_build_object('key','rate',   'label', public._stl_c('inv.col_rate'),'align','right'),
        jsonb_build_object('key','taxable','label', public._stl_c('inv.col_taxable'),'align','right'),
        jsonb_build_object('key','amount', 'label', public._stl_c('inv.col_amount'),'align','right')),
      'lines', jsonb_build_array(jsonb_build_object(
        'desc',    i.description || case when p.id is null then ''
                     else ' (' || to_char(p.period_start,'DD Mon') || ' – '
                          || to_char(p.period_end,'DD Mon YYYY') || ')' end,
        'sac',     i.sac_code,
        'rate',    to_char(i.gst_rate,'FM990.##') || '%',
        'taxable', public.inr_money(i.taxable),
        'amount',  public.inr_money(i.total))),
      'totals', v_tot,
      'net', jsonb_build_object(
        'label', public._stl_c('inv.net_label'), 'value', public.inr_money(i.total)),
      'disclosure', '',
      'footer', jsonb_build_object(
        'note',  public._stl_c('inv.footer'),
        'items', coalesce((select invoice_terms from public.billing_config where id = 1), ''))));
end $$;

create or replace function public.settlement_invoice_report(
  p_invoice_id uuid, p_ok boolean, p_bucket text default null, p_path text default null,
  p_name text default null, p_bytes integer default null, p_error text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  update public.settlement_invoice
     set pdf_status = case when p_ok then 'ready' else 'error' end,
         pdf_bucket = coalesce(p_bucket, pdf_bucket),
         pdf_path   = coalesce(p_path,   pdf_path),
         pdf_name   = coalesce(p_name,   pdf_name),
         pdf_bytes  = coalesce(p_bytes,  pdf_bytes),
         pdf_error  = case when p_ok then null else p_error end
   where id = p_invoice_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.settlement_invoice_request(p_invoice_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare i public.settlement_invoice%rowtype;
begin
  select * into i from public.settlement_invoice where id = p_invoice_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public._stl_c('inv.err_not_found'));
  end if;
  if i.pdf_status = 'ready' and coalesce(i.pdf_path,'') <> '' then
    return jsonb_build_object('ok', true, 'status','ready', 'invoice_id', i.id,
      'bucket', i.pdf_bucket, 'path', i.pdf_path, 'file_name', i.pdf_name,
      'expires_s', 300, 'message', public._stl_c('inv.ready'));
  end if;

  update public.settlement_invoice set pdf_status='queued', pdf_error=null where id = i.id;

  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/px-invoice',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027',
                                  'Authorization','Bearer ' || public._service_key()),
    body    := jsonb_build_object('source','settlement_invoice','invoice_id', i.id),
    timeout_milliseconds := 20000);

  return jsonb_build_object('ok', true, 'status','building', 'invoice_id', i.id,
    'poll_ms', 1500, 'message', public._stl_c('inv.building'));
end $$;

-- ── 9. WhatsApp — the route is DATA, the send is one call ───────────────────
insert into public.wa_event_routes
  (event_key, label, description, language, variable_map, enabled, auto_manage,
   auto_template_name, bypass_send_window, audience, wa_category, marketing_guard,
   dedupe_minutes, push_enabled, email_enabled, email_mode,
   push_title, push_body, email_subject, email_body)
values
  ('settlement_tax_invoice',
   'GST tax invoice for a settled period',
   'CHANGE #695 — the settlement fee leg as a filed tax document, sent to the party it is raised on.',
   'en',
   '["{{party_name}}", "{{invoice_no}}", "{{invoice_total}}", "{{invoice_period}}", "{{invoice_link}}"]'::jsonb,
   true, true, 'settlement_tax_invoice', true, 'partner', 'utility', true, 0,
   true, true, 'fallback',
   'Tax invoice {{invoice_no}}',
   '{{invoice_total}} for {{invoice_period}}.',
   'Tax invoice {{invoice_no}} — {{invoice_total}}',
   'Dear {{party_name}},' || chr(10) || chr(10) ||
   'Tax invoice {{invoice_no}} for {{invoice_total}} covering {{invoice_period}} has been issued.' || chr(10) || chr(10) ||
   'Download it here: {{invoice_link}}')
on conflict (event_key) do update
  set label = excluded.label, description = excluded.description,
      variable_map = excluded.variable_map, audience = excluded.audience,
      auto_manage = true, auto_template_name = excluded.auto_template_name,
      push_enabled = true, email_enabled = true, email_mode = excluded.email_mode,
      push_title = excluded.push_title, push_body = excluded.push_body,
      email_subject = excluded.email_subject, email_body = excluded.email_body,
      updated_at = now();

create or replace function public.settlement_invoice_wa(p_invoice_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare i public.settlement_invoice%rowtype; p public.partner_settlement_periods%rowtype;
        v_link text; v_party text; v_res jsonb;
begin
  if not public.is_admin() then return public._stl_denied(); end if;
  select * into i from public.settlement_invoice where id = p_invoice_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public._stl_c('inv.err_not_found'));
  end if;
  if i.pdf_status <> 'ready' or coalesce(i.pdf_path,'') = '' then
    -- Never send a link to a document that is not drawn yet. Ask for it and
    -- say so; the console polls and the send is offered again when it is ready.
    perform public.settlement_invoice_request(i.id);
    return jsonb_build_object('ok', false, 'error','not_ready', 'status','building',
      'poll_ms', 1500, 'message', public._stl_c('inv.building'));
  end if;

  -- The document is always ABOUT the partner, whichever way it points: they are
  -- the counterparty on a mediBO invoice and the issuer on their own, and either
  -- way they are the party who needs the copy. notify_partner() already knows
  -- how to reach them - every active partner user, phone where there is one and
  -- a push where there is not - so the recipient is not resolved again here.
  select * into p from public.partner_settlement_periods where id = i.period_id;
  select coalesce(rp.partner_name,'') into v_party
    from public.region_partners rp where rp.id = i.partner_id;

  v_link := 'https://medibo.in/settlement-invoice/' || i.id::text;
  v_res := public.notify_partner('settlement_tax_invoice', jsonb_build_object(
    'partner_id',     i.partner_id::text,
    'party_name',     v_party,
    'invoice_no',     i.invoice_no,
    'invoice_total',  public.inr_money(i.total),
    'invoice_period', case when p.id is null then to_char(i.invoice_date,'Mon YYYY')
                           else to_char(p.period_start,'DD Mon') || ' – ' || to_char(p.period_end,'DD Mon YYYY') end,
    'invoice_link',   v_link));
  update public.settlement_invoice set wa_sent_at = now() where id = i.id;
  return jsonb_build_object('ok', true, 'message', public._stl_c('inv.wa_sent'), 'delivery', v_res);
end $$;

-- ── 10. The console — ONE list, scoped by who is asking ─────────────────────
-- An admin sees every partner's invoices; a partner sees their own and no more.
-- The scope is decided HERE, so the screen is the same widget for both and a
-- partner cannot widen it by passing somebody else's id.
create or replace function public.settlement_invoices(
  p_partner_id bigint default null, p_month date default null,
  p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_admin boolean := public.is_admin(); v_mine bigint := public.my_partner_id();
        v_scope bigint; v_rows jsonb; v_total int; v_lim int := least(greatest(coalesce(p_limit,50),1), 200);
begin
  if not v_admin and v_mine is null then return public._stl_denied(); end if;
  -- A partner is CLAMPED to their own id; the parameter is a filter for the
  -- office, never a way in.
  v_scope := case when v_admin then p_partner_id else v_mine end;

  select count(*) into v_total from public.settlement_invoice i
   where (v_scope is null or i.partner_id = v_scope)
     and (p_month is null or (i.invoice_date >= date_trunc('month', p_month)::date
                          and i.invoice_date <  (date_trunc('month', p_month) + interval '1 month')::date));

  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.ord), '[]'::jsonb) into v_rows from (
    select
      i.id::text                                   as invoice_id,
      i.invoice_no                                 as invoice_no,
      to_char(i.invoice_date,'DD Mon YYYY')        as date_label,
      case when i.doc_kind='credit_note' then public._stl_c('inv.credit_note')
           else public._stl_c('inv.tax_invoice') end as kind_label,
      i.doc_kind                                   as doc_kind,
      case when i.direction='medibo_to_partner' then public._stl_c('inv.dir_medibo')
           else public._stl_c('inv.dir_partner') end as direction_label,
      coalesce(rp.partner_name,'')                 as partner_name,
      i.issuer_name                                as issuer_name,
      i.recipient_name                             as recipient_name,
      public.inr_money(i.taxable)                  as taxable_value,
      public.inr_money(i.total)                    as total_value,
      case when i.is_interstate
           then public._stl_c('inv.igst_label') || ' ' || public.inr_money(i.igst)
           else public._stl_c('inv.cgst_label') || ' ' || public.inr_money(i.cgst) || '  ·  ' ||
                public._stl_c('inv.sgst_label') || ' ' || public.inr_money(i.sgst) end as tax_label,
      case when i.status='cancelled' then public._stl_c('inv.cancelled')
           else public._stl_c('inv.issued') end   as status_label,
      case when i.status='cancelled' then 'danger'
           when i.doc_kind='credit_note' then 'warning' else 'success' end as status_tone,
      i.pdf_status                                 as pdf_status,
      (i.pdf_status = 'ready')                     as can_download,
      public._stl_c('inv.download')                as download_label,
      (v_admin and i.wa_sent_at is null)           as can_wa,
      case when i.wa_sent_at is null then public._stl_c('inv.wa_send')
           else public._stl_c('inv.wa_sent') end   as wa_label,
      (v_admin and i.doc_kind='tax_invoice' and i.status='issued'
        and not exists (select 1 from public.settlement_invoice c
                         where c.parent_invoice_id = i.id and c.doc_kind='credit_note'
                           and c.status='issued'))  as can_credit_note,
      public._stl_c('inv.credit_note_make')        as credit_note_label,
      i.period_id                                  as period_id,
      row_number() over (order by i.invoice_date desc, i.created_at desc) as ord
    from public.settlement_invoice i
    left join public.region_partners rp on rp.id = i.partner_id
    where (v_scope is null or i.partner_id = v_scope)
      and (p_month is null or (i.invoice_date >= date_trunc('month', p_month)::date
                           and i.invoice_date <  (date_trunc('month', p_month) + interval '1 month')::date))
    order by i.invoice_date desc, i.created_at desc
    limit v_lim offset greatest(coalesce(p_offset,0),0)) t;

  return jsonb_build_object(
    'ok', true,
    'heading',    public._stl_c('inv.heading'),
    'empty_text', public._stl_c('inv.empty'),
    'is_admin',   v_admin,
    'count',      v_total,
    'has_more',   (greatest(coalesce(p_offset,0),0) + v_lim) < v_total,
    'register_label', public._stl_c('inv.register_download'),
    'rows', v_rows);
end $$;

-- ── 11. The GSTR-1 register — the month, in the shape the CA files ──────────
-- B2B, one row per invoice, with the recipient GSTIN, place of supply, taxable
-- value and each tax head in its own column. The CSV is built HERE so the file
-- the office downloads and the table it sees on screen can never disagree, and
-- so a spreadsheet cannot re-type a rupee.
create or replace function public.settlement_invoice_register(p_month date default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_from date; v_to date; v_rows jsonb; v_csv text; v_n int;
begin
  if not public.is_admin() then return public._stl_denied(); end if;
  v_from := date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Kolkata')::date))::date;
  v_to   := (v_from + interval '1 month')::date;

  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.invoice_date, t.invoice_number), '[]'::jsonb),
         count(*)
    into v_rows, v_n
  from (
    select
      i.recipient_gstin                       as gstin_of_recipient,
      i.recipient_name                        as receiver_name,
      i.invoice_no                            as invoice_number,
      to_char(i.invoice_date,'DD-MM-YYYY')    as invoice_date_ddmmyyyy,
      round(i.total,2)                        as invoice_value,
      i.pos_code                              as place_of_supply,
      'N'                                     as reverse_charge,
      case when i.doc_kind='credit_note' then 'C' else 'R' end as invoice_type,
      i.sac_code                              as hsn_sac,
      round(i.gst_rate,2)                     as rate,
      round(i.taxable,2)                      as taxable_value,
      round(i.cgst,2)                         as cgst_amount,
      round(i.sgst,2)                         as sgst_amount,
      round(i.igst,2)                         as igst_amount,
      i.issuer_gstin                          as gstin_of_supplier,
      i.issuer_name                           as supplier_name,
      i.invoice_date                          as invoice_date
    from public.settlement_invoice i
    where i.status = 'issued' and i.invoice_date >= v_from and i.invoice_date < v_to) t;

  -- The header is the GSTR-1 B2B column order; every value is quoted so a
  -- partner name with a comma cannot shift a column.
  v_csv := 'GSTIN/UIN of Recipient,Receiver Name,Invoice Number,Invoice date,Invoice Value,'
        || 'Place Of Supply,Reverse Charge,Invoice Type,HSN/SAC,Rate,Taxable Value,'
        || 'Cess Amount,CGST,SGST,IGST' || chr(10);
  select v_csv || coalesce(string_agg(line, chr(10) order by ord), '') into v_csv from (
    select row_number() over (order by (r->>'invoice_date'), (r->>'invoice_number')) as ord,
      '"' || replace(coalesce(r->>'gstin_of_recipient',''),'"','""') || '",' ||
      '"' || replace(coalesce(r->>'receiver_name',''),'"','""')      || '",' ||
      '"' || replace(coalesce(r->>'invoice_number',''),'"','""')     || '",' ||
      '"' || coalesce(r->>'invoice_date_ddmmyyyy','')                || '",' ||
      coalesce(r->>'invoice_value','0')     || ',' ||
      '"' || coalesce(r->>'place_of_supply','') || '",' ||
      '"N","' || coalesce(r->>'invoice_type','R') || '",' ||
      '"' || coalesce(r->>'hsn_sac','') || '",' ||
      coalesce(r->>'rate','0')          || ',' ||
      coalesce(r->>'taxable_value','0') || ',0,' ||
      coalesce(r->>'cgst_amount','0')   || ',' ||
      coalesce(r->>'sgst_amount','0')   || ',' ||
      coalesce(r->>'igst_amount','0')   as line
    from jsonb_array_elements(v_rows) r) x;

  return jsonb_build_object(
    'ok', true,
    'heading',    public._stl_c('inv.register_heading'),
    'empty_text', public._stl_c('inv.register_empty'),
    'month_label', to_char(v_from,'Mon YYYY'),
    'month',      to_char(v_from,'YYYY-MM-DD'),
    'count',      v_n,
    'file_name',  'gstr1-settlement-' || to_char(v_from,'YYYY-MM') || '.csv',
    'csv',        v_csv,
    'rows',       v_rows);
end $$;

-- ── 12. Grants ──────────────────────────────────────────────────────────────
-- Every one of these gates itself (is_admin, or my_partner_id clamping). The
-- tables carry RLS with no policy, so nothing reads them except through these.
grant execute on function public.settlement_invoices(bigint,date,integer,integer) to authenticated;
grant execute on function public.settlement_invoice_register(date)                to authenticated;
grant execute on function public.settlement_invoice_request(uuid)                 to authenticated;
grant execute on function public.settlement_invoice_credit_note(uuid,numeric,text) to authenticated;
grant execute on function public.settlement_invoice_wa(uuid)                      to authenticated;
grant execute on function public.settlement_invoice_render_input(uuid)            to service_role;
grant execute on function public.settlement_invoice_report(uuid,boolean,text,text,text,integer,text) to service_role;

-- ── 13. Where it lives — and the DOOR, not just the tile ────────────────────
-- #710 shipped a registry tile whose route the shell could not open, because a
-- partner route wired only into partnerDestination() has had no caller since
-- #653 merged the partner surface into the shared shell. So the feature row,
-- the role grants, the surface_route DOOR and the shard arm are declared
-- together here and in shell_extra_routes.dart - the route mirror the nav gate
-- reads is generated from surface_route, so a feature with no row is a feature
-- the gate never checks.
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface, roles_allowed,
   search_terms, description)
values
  ('partner.settlement_invoices', 'Tax invoices', 'Money', 'receipt',
   'settlement_invoices', 40, 'partner', true, 'read', true, 'money', 'dashboard',
   array['admin','super_admin']::text[],
   'gst tax invoice settlement credit note gstr1 register sac cgst sgst igst',
   'CHANGE #695 — the GST tax invoice raised on every settled period, its credit notes, and the monthly GSTR-1 register.')
on conflict (feature_key) do update
  set label = excluded.label, route_key = excluded.route_key,
      group_label = excluded.group_label, icon_key = excluded.icon_key,
      sort_order = excluded.sort_order, is_active = true,
      partner_eligible = true, category = excluded.category,
      surface = excluded.surface, description = excluded.description;

insert into public.access_role_default (role, feature_key, can_view, can_write) values
  ('super_admin','partner.settlement_invoices', true,  true),
  ('admin',      'partner.settlement_invoices', true,  true),
  ('partner',    'partner.settlement_invoices', true,  false)
on conflict (role, feature_key) do update
  set can_view = excluded.can_view, can_write = excluded.can_write;

insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values
  ('settlement_invoices', 'partner.settlement_invoices', 'feature', 'home_shell',
   'CHANGE #695 — the GST tax invoice on every settled period, plus credit notes '
   'and the monthly GSTR-1 register. Opened by shellExtraRouteScreen() in '
   'lib/screens/shell/shell_extra_routes.dart, which home_shell reaches through '
   'its one `case _ when shellExtraRouteScreen(route) != null` lookup. '
   'Authorisation is not the door: settlement_invoices() clamps a partner to '
   'their own id and refuses anyone who is neither office nor partner.',
   true)
on conflict (route_key, feature_key) do update
  set kind = excluded.kind, handled_by = excluded.handled_by,
      note = excluded.note, is_active = true, updated_at = now();

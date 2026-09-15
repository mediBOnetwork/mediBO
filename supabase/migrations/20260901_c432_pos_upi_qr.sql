-- CMD #432 — POS UPI QR: a per-bill dynamic QR that pays the PHARMACY's own VPA.
--
-- The money never touches mediBO. There is no gateway, no fee, no settlement
-- account and no webhook: the patient scans, their UPI app moves the rupees
-- straight from their bank to the pharmacy's, and mediBO learns about it only
-- because a human at the counter says so. Everything below is built around that
-- one honest fact.
--
--   * ONE VPA, ONE PLACE. #415 already put upi_vpa/upi_vpa_name on
--     pharmacy_profiles for the khata reminders. This command does NOT add a
--     second copy for the counter — it makes that column the single store, adds
--     the change history the spec asks for, gates the edit to the OWNER login,
--     and turns khata_upi_save/khata_upi_confirm into thin delegates so there
--     is exactly one write path.
--   * THE QR STRING IS BACKEND PROPERTY. upi_qr_string() is the only place in
--     the system that concatenates a upi:// URI. The screen and the PDF render
--     the string they are handed; neither builds one, and neither knows the
--     parameter order.
--   * CONFIRMATION IS A TAP, AND IT SAYS SO. pos_payment_confirm() stamps who
--     tapped and when. Nothing marks a bill paid on its own, no state is ever
--     called "verified", and the day-close split names UPI money as
--     staff-confirmed rather than pretending a gateway checked it.
--
-- Idempotent throughout: a resumed worker re-applies this as a no-op.

-- ─────────────── 1. THE ONE UPI STORE, AND ITS HISTORY ──────────────────────

alter table public.pharmacy_profiles
  add column if not exists upi_updated_at timestamptz,
  add column if not exists upi_updated_by uuid;

-- Every change to the number money lands in, kept forever. A pharmacy that
-- finds a week of takings in the wrong account needs to be able to see when the
-- VPA changed and who changed it — so this is append-only and nothing deletes.
create table if not exists public.pharmacy_upi_history (
  id            bigserial primary key,
  pharmacy_id   uuid not null references public.pharmacy_profiles(id) on delete cascade,
  action        text not null check (action in ('save','confirm')),
  old_vpa       text,
  old_name      text,
  new_vpa       text,
  new_name      text,
  changed_by    uuid,
  changed_label text,
  source        text,                       -- 'pos' | 'khata' | null
  changed_at    timestamptz not null default now()
);
create index if not exists pharmacy_upi_history_shop_ix
  on public.pharmacy_upi_history (pharmacy_id, changed_at desc);

alter table public.pharmacy_upi_history enable row level security;
-- No policies, by design: the RPCs below are SECURITY DEFINER and each one
-- filters to the caller's own pharmacy. A direct PostgREST select returns
-- nothing, for anyone.

-- ─────────────────────────── 2. COPY ────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('upi.setup_title',        to_jsonb('UPI for the counter'::text)),
  ('upi.setup_hint',         to_jsonb('Patients pay this UPI ID directly. mediBO never holds the money and takes nothing from it.'::text)),
  ('upi.vpa_label',          to_jsonb('UPI ID (VPA)'::text)),
  ('upi.name_label',         to_jsonb('Name shown to the payer'::text)),
  ('upi.save_label',         to_jsonb('Save UPI ID'::text)),
  ('upi.confirm_label',      to_jsonb('I sent myself ₹1 and it arrived'::text)),
  ('upi.confirm_prompt',     to_jsonb('Pay ₹1 to {{vpa}} from your own phone. If it lands, confirm below — the QR then goes live on every bill.'::text)),
  ('upi.saved',              to_jsonb('UPI ID saved. Confirm it before the counter uses it.'::text)),
  ('upi.confirmed',          to_jsonb('UPI ID confirmed. Bills now show a QR.'::text)),
  ('upi.err_bad_vpa',        to_jsonb('That does not look like a UPI ID. It reads like name@bank.'::text)),
  ('upi.err_mismatch',       to_jsonb('That is not the UPI ID currently saved. Save it first, then confirm.'::text)),
  ('upi.err_not_owner',      to_jsonb('Only the shop owner login can change the UPI ID.'::text)),
  ('upi.owner_only_hint',    to_jsonb('Only the owner login can change this.'::text)),
  ('upi.not_set',            to_jsonb('No UPI ID saved yet'::text)),
  ('upi.not_confirmed',      to_jsonb('Saved, not confirmed yet'::text)),
  ('upi.history_title',      to_jsonb('Change history'::text)),
  ('upi.history_empty',      to_jsonb('No changes yet.'::text)),
  ('upi.history_save',       to_jsonb('Changed to {{vpa}}'::text)),
  ('upi.history_confirm',    to_jsonb('Confirmed {{vpa}}'::text)),
  ('pos.upi_setup_tile',     to_jsonb('UPI QR for bills'::text)),
  ('pos.upi_qr_title',       to_jsonb('Scan to pay'::text)),
  ('pos.upi_qr_sub',         to_jsonb('Any UPI app. The money goes straight to your bank.'::text)),
  ('pos.upi_qr_amount',      to_jsonb('Amount'::text)),
  ('pos.upi_qr_invoice',     to_jsonb('Invoice'::text)),
  ('pos.upi_qr_payee',       to_jsonb('Paying'::text)),
  ('pos.upi_ask_patient',    to_jsonb('Ask the patient to show you the success screen before you tap below.'::text)),
  ('pos.upi_confirm_button', to_jsonb('Payment received'::text)),
  ('pos.upi_confirm_busy',   to_jsonb('Recording…'::text)),
  ('pos.upi_confirmed_toast',to_jsonb('Marked received. It counts as staff-confirmed UPI.'::text)),
  ('pos.upi_confirmed_by',   to_jsonb('Received — marked by {{who}} at {{at}}'::text)),
  ('pos.upi_pending_note',   to_jsonb('Not marked received yet'::text)),
  ('pos.upi_no_vpa_title',   to_jsonb('Add your UPI ID to show a QR'::text)),
  ('pos.upi_no_vpa_hint',    to_jsonb('Save and confirm the shop UPI ID once — every UPI bill then prints a QR for its exact amount.'::text)),
  ('pos.upi_no_vpa_cta',     to_jsonb('Set up UPI'::text)),
  ('pos.upi_shop_qr_title',  to_jsonb('Counter QR — pay this shop'::text)),
  ('pos.upi_shop_qr_sub',    to_jsonb('No amount. Print it and stick it on the counter; the payer types the amount.'::text)),
  ('pos.upi_shop_qr_open',   to_jsonb('Counter QR to print'::text)),
  ('pos.upi_split_note',     to_jsonb('{{n}} UPI bill(s) not marked received'::text)),
  ('pos.upi_split_confirmed',to_jsonb('{{amt}} staff-confirmed'::text)),
  ('khata.upi_qr_caption',   to_jsonb('Scan to settle'::text))
on conflict (key) do update set value = excluded.value;

-- ──────────── 3. THE ONLY PLACE A upi:// STRING IS BUILT ────────────────────
-- Reserved characters are stripped rather than escaped: a UPI app that meets a
-- raw & or # in pn/tn truncates the URI and the payee silently becomes wrong.
-- p_amount null => a STATIC shop QR (the payer types the amount).
create or replace function public.upi_qr_string(
  p_vpa text, p_payee text, p_amount numeric default null, p_note text default null)
returns text language sql immutable
set search_path to 'public' as $function$
  select case when coalesce(btrim(p_vpa),'') = '' then null else
    'upi://pay?pa=' || btrim(p_vpa)
    || '&pn=' || regexp_replace(coalesce(p_payee,''), '[&#?=%]', ' ', 'g')
    || case when p_amount is null then ''
            else '&am=' || to_char(round(greatest(p_amount,0),2), 'FM9999999990.00') end
    || '&cu=INR'
    || case when coalesce(btrim(p_note),'') = '' then ''
            else '&tn=' || regexp_replace(btrim(p_note), '[&#?=%]', ' ', 'g') end
  end
$function$;

-- The shop's UPI identity, resolved once. Every QR on every surface reads this.
create or replace function public._upi_payee(p_shop uuid)
returns jsonb language plpgsql stable
set search_path to 'public' as $function$
declare pp public.pharmacy_profiles%rowtype; v_pa text; v_pn text;
begin
  select * into pp from public.pharmacy_profiles where id = p_shop;
  if not found then return jsonb_build_object('has', false, 'reason', 'no_shop'); end if;
  v_pa := nullif(btrim(coalesce(pp.upi_vpa,'')), '');
  v_pn := coalesce(nullif(btrim(coalesce(pp.upi_vpa_name,'')),''),
                   nullif(btrim(coalesce(pp.pharmacy_name,'')),''),
                   coalesce(pp.customer_name,''));
  if v_pa is null then
    return jsonb_build_object('has', false, 'reason', 'no_vpa', 'payee', v_pn);
  end if;
  if pp.upi_verified_at is null then
    return jsonb_build_object('has', false, 'reason', 'not_confirmed',
                              'vpa', v_pa, 'payee', v_pn);
  end if;
  return jsonb_build_object('has', true, 'vpa', v_pa, 'payee', v_pn);
end $function$;

-- One QR block, whatever asks for it. Dart draws `qr_string` and prints the
-- rows; it never re-derives the amount from a number and never builds a URI.
create or replace function public._upi_qr_block(
  p_shop uuid, p_amount numeric, p_note text, p_title text, p_sub text)
returns jsonb language plpgsql stable
set search_path to 'public' as $function$
declare v_p jsonb := public._upi_payee(p_shop); v_rows jsonb := '[]'::jsonb;
begin
  if coalesce((v_p->>'has')::boolean, false) is not true then
    return jsonb_build_object(
      'has', false,
      'reason', v_p->>'reason',
      'title', public.ui_text('pos.upi_no_vpa_title'),
      'hint',  public.ui_text('pos.upi_no_vpa_hint'),
      'cta',   public.ui_text('pos.upi_no_vpa_cta'));
  end if;

  if p_amount is not null then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'label', public.ui_text('pos.upi_qr_amount'),
      'value', public.inr_money(p_amount), 'strong', true));
  end if;
  if coalesce(btrim(coalesce(p_note,'')),'') <> '' then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'label', public.ui_text('pos.upi_qr_invoice'), 'value', p_note, 'strong', false));
  end if;
  v_rows := v_rows || jsonb_build_array(jsonb_build_object(
    'label', public.ui_text('pos.upi_qr_payee'),
    'value', (v_p->>'payee') || ' · ' || (v_p->>'vpa'), 'strong', false));

  return jsonb_build_object(
    'has', true,
    'title', p_title,
    'sub',   p_sub,
    'qr_string', public.upi_qr_string(v_p->>'vpa', v_p->>'payee', p_amount, p_note),
    'vpa',   v_p->>'vpa',
    'payee', v_p->>'payee',
    'rows',  v_rows);
end $function$;

-- ─────────────── 4. THE VPA: READ, SAVE, CONFIRM, HISTORY ───────────────────

-- Only the OWNER login may change where the money lands. Staff sub-logins
-- resolve to the same shop through login_identities but carry their own uid, so
-- this is the one test that separates them.
create or replace function public.pharmacy_upi_can_edit(p_shop uuid)
returns boolean language sql stable
set search_path to 'public' as $function$
  select exists (select 1 from public.pharmacy_profiles pp
                  where pp.id = p_shop and pp.user_id = auth.uid())
$function$;

create or replace function public._upi_actor_label()
returns text language sql stable
set search_path to 'public' as $function$
  select coalesce(
    nullif(btrim(coalesce(pp.owner_name, pp.customer_name, '')), ''),
    nullif(btrim(coalesce(pp.pharmacy_name,'')), ''),
    (select u.email from auth.users u where u.id = auth.uid()),
    '—')
  from public.pharmacy_profiles pp
  where pp.user_id = auth.uid()
  limit 1
$function$;

-- The setup card, whole. Both the counter and the khata screen render this.
create or replace function public._upi_setup_block(p_shop uuid)
returns jsonb language plpgsql stable
set search_path to 'public' as $function$
declare pp public.pharmacy_profiles%rowtype; v_edit boolean;
begin
  select * into pp from public.pharmacy_profiles where id = p_shop;
  v_edit := public.pharmacy_upi_can_edit(p_shop);
  return jsonb_build_object(
    'title',         public.ui_text('upi.setup_title'),
    'hint',          public.ui_text('upi.setup_hint'),
    'vpa_label',     public.ui_text('upi.vpa_label'),
    'name_label',    public.ui_text('upi.name_label'),
    'save_label',    public.ui_text('upi.save_label'),
    'confirm_label', public.ui_text('upi.confirm_label'),
    'vpa',           nullif(btrim(coalesce(pp.upi_vpa,'')),''),
    'name',          nullif(btrim(coalesce(pp.upi_vpa_name,'')),''),
    'has_vpa',       coalesce(nullif(btrim(coalesce(pp.upi_vpa,'')),''),'') <> '',
    'confirmed',     pp.upi_verified_at is not null,
    'state_label',   case when coalesce(nullif(btrim(coalesce(pp.upi_vpa,'')),''),'') = ''
                            then public.ui_text('upi.not_set')
                          when pp.upi_verified_at is null
                            then public.ui_text('upi.not_confirmed')
                          else public.ui_text('upi.confirmed') end,
    'state_tone',    case when coalesce(nullif(btrim(coalesce(pp.upi_vpa,'')),''),'') = ''
                            then 'neutral'
                          when pp.upi_verified_at is null then 'warning'
                          else 'success' end,
    'can_edit',      v_edit,
    'locked_hint',   case when v_edit then null
                          else public.ui_text('upi.owner_only_hint') end,
    'history_title', public.ui_text('upi.history_title'),
    'history_empty', public.ui_text('upi.history_empty'));
end $function$;

create or replace function public.pharmacy_upi_get()
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := public.pos_shop();
begin
  if v_shop is null then return public._pos_denied(); end if;
  return jsonb_build_object('ok', true,
    'setup', public._upi_setup_block(v_shop),
    'shop_qr', public._upi_qr_block(v_shop, null, null,
                 public.ui_text('pos.upi_shop_qr_title'),
                 public.ui_text('pos.upi_shop_qr_sub')),
    'history', public.pharmacy_upi_history_rows(v_shop, 20));
end $function$;

create or replace function public.pharmacy_upi_history_rows(p_shop uuid, p_limit integer default 20)
returns jsonb language sql stable
set search_path to 'public' as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'action', h.action,
           'label',  public.ui_fmt(
                       case when h.action = 'confirm' then 'upi.history_confirm'
                            else 'upi.history_save' end,
                       jsonb_build_object('vpa', coalesce(h.new_vpa,'—'))),
           'who',    coalesce(h.changed_label,'—'),
           'at',     to_char(h.changed_at at time zone 'Asia/Kolkata',
                             'DD Mon YYYY, hh12:mi AM'))
         order by h.changed_at desc), '[]'::jsonb)
  from (select * from public.pharmacy_upi_history
         where pharmacy_id = p_shop
         order by changed_at desc limit greatest(coalesce(p_limit,20),1)) h
$function$;

create or replace function public.pharmacy_upi_save(
  p_vpa text, p_name text default null, p_source text default 'pos')
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := public.pos_shop();
  pp public.pharmacy_profiles%rowtype;
  v_vpa text; v_name text;
begin
  if v_shop is null then return public._pos_denied(); end if;
  if not public.pharmacy_upi_can_edit(v_shop) then
    return jsonb_build_object('ok', false, 'error', 'not_owner',
      'message', public.ui_text('upi.err_not_owner'));
  end if;
  v_vpa := lower(btrim(coalesce(p_vpa,'')));
  if v_vpa !~ '^[a-z0-9._-]{2,64}@[a-z][a-z0-9.-]{1,32}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_vpa',
      'message', public.ui_text('upi.err_bad_vpa'));
  end if;
  v_name := nullif(btrim(coalesce(p_name,'')),'');

  select * into pp from public.pharmacy_profiles where id = v_shop;

  -- A changed VPA always drops back to unconfirmed: the ₹1 test proved the OLD
  -- number, and money is not something to take on trust twice.
  update public.pharmacy_profiles
     set upi_vpa         = v_vpa,
         upi_vpa_name    = v_name,
         upi_verified_at = case when pp.upi_vpa = v_vpa then pp.upi_verified_at end,
         upi_verified_by = case when pp.upi_vpa = v_vpa then pp.upi_verified_by end,
         upi_updated_at  = now(),
         upi_updated_by  = auth.uid()
   where id = v_shop;

  insert into public.pharmacy_upi_history(
      pharmacy_id, action, old_vpa, old_name, new_vpa, new_name,
      changed_by, changed_label, source)
  values (v_shop, 'save', pp.upi_vpa, pp.upi_vpa_name, v_vpa, v_name,
          auth.uid(), public._upi_actor_label(), coalesce(p_source,'pos'));

  return jsonb_build_object('ok', true, 'vpa', v_vpa,
    'confirmed', pp.upi_vpa = v_vpa and pp.upi_verified_at is not null,
    'confirm_prompt', public.ui_fmt('upi.confirm_prompt',
                        jsonb_build_object('vpa', v_vpa)),
    'setup', public._upi_setup_block(v_shop),
    'message', public.ui_text('upi.saved'));
end $function$;

create or replace function public.pharmacy_upi_confirm(
  p_vpa text, p_source text default 'pos')
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare v_shop uuid := public.pos_shop(); pp public.pharmacy_profiles%rowtype;
begin
  if v_shop is null then return public._pos_denied(); end if;
  if not public.pharmacy_upi_can_edit(v_shop) then
    return jsonb_build_object('ok', false, 'error', 'not_owner',
      'message', public.ui_text('upi.err_not_owner'));
  end if;
  select * into pp from public.pharmacy_profiles where id = v_shop;
  if coalesce(pp.upi_vpa,'') = '' or lower(btrim(coalesce(p_vpa,''))) <> pp.upi_vpa then
    return jsonb_build_object('ok', false, 'error', 'vpa_mismatch',
      'message', public.ui_text('upi.err_mismatch'));
  end if;

  update public.pharmacy_profiles
     set upi_verified_at = now(), upi_verified_by = auth.uid()
   where id = v_shop;

  insert into public.pharmacy_upi_history(
      pharmacy_id, action, old_vpa, old_name, new_vpa, new_name,
      changed_by, changed_label, source)
  values (v_shop, 'confirm', pp.upi_vpa, pp.upi_vpa_name, pp.upi_vpa, pp.upi_vpa_name,
          auth.uid(), public._upi_actor_label(), coalesce(p_source,'pos'));

  return jsonb_build_object('ok', true, 'confirmed', true,
    'setup', public._upi_setup_block(v_shop),
    'shop_qr', public._upi_qr_block(v_shop, null, null,
                 public.ui_text('pos.upi_shop_qr_title'),
                 public.ui_text('pos.upi_shop_qr_sub')),
    'message', public.ui_text('upi.confirmed'));
end $function$;

-- ───────────── 5. THE BILL: ITS QR, AND THE HUMAN WHO CONFIRMS IT ───────────

-- Direct-to-VPA has no webhook and never will. So a UPI bill carries exactly
-- one truth about its money: a named person at the counter tapped "Payment
-- received" at a known moment. These three columns hold that and nothing more —
-- there is deliberately no `verified` flag to mistake for a bank's word.
alter table public.pos_sales
  add column if not exists upi_paid_at    timestamptz,
  add column if not exists upi_paid_by    uuid,
  add column if not exists upi_paid_label text;

create index if not exists pos_sales_upi_pending_ix
  on public.pos_sales (pharmacy_id, sold_on)
  where payment_mode = 'upi' and upi_paid_at is null;

-- The QR for ONE bill: this shop's VPA, this bill's exact rupees, this bill's
-- invoice number in the note so the pharmacy can match it in their bank app.
create or replace function public.pos_upi_qr(p_sale_id uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := public.pos_shop(); s public.pos_sales%rowtype;
begin
  if v_shop is null then return public._pos_denied(); end if;
  select * into s from public.pos_sales where id = p_sale_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('pos.err_not_found'));
  end if;
  -- Same key and same shape as pos_sale_detail's, so a caller that already
  -- renders one panel cannot be handed a differently-named other.
  return jsonb_build_object('ok', true, 'sale_id', s.id,
                            'upi', public._pos_sale_upi(s));
end $function$;

-- The whole UPI panel for a sale — QR, the honesty prompt, and the state of the
-- one tap that can mark it received. Shared by pos_sale_detail and pos_upi_qr
-- so the receipt sheet and a re-open can never disagree.
create or replace function public._pos_sale_upi(s public.pos_sales)
returns jsonb language plpgsql stable
set search_path to 'public' as $function$
declare v_qr jsonb;
begin
  if s.payment_mode <> 'upi' then
    return jsonb_build_object('show', false);
  end if;
  v_qr := public._upi_qr_block(s.pharmacy_id, s.net_amount, s.invoice_no,
            public.ui_text('pos.upi_qr_title'), public.ui_text('pos.upi_qr_sub'));
  return jsonb_build_object(
    'show',           true,
    'qr',             v_qr,
    'ask_patient',    public.ui_text('pos.upi_ask_patient'),
    'confirm_label',  public.ui_text('pos.upi_confirm_button'),
    'confirm_busy',   public.ui_text('pos.upi_confirm_busy'),
    'is_confirmed',   s.upi_paid_at is not null,
    'can_confirm',    s.upi_paid_at is null and s.status = 'completed',
    'confirmed_label', case when s.upi_paid_at is null then null else
        public.ui_fmt('pos.upi_confirmed_by', jsonb_build_object(
          'who', coalesce(s.upi_paid_label,'—'),
          'at',  to_char(s.upi_paid_at at time zone 'Asia/Kolkata',
                         'DD Mon YYYY, hh12:mi AM'))) end,
    'pending_label',  case when s.upi_paid_at is null
                           then public.ui_text('pos.upi_pending_note') end,
    'tone',           case when s.upi_paid_at is null then 'warning' else 'success' end);
end $function$;

-- The tap. It records a HUMAN's claim, attributed, and it is never automatic:
-- nothing else in this system writes upi_paid_at.
create or replace function public.pos_payment_confirm(p_sale_id uuid)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare v_shop uuid := public.pos_shop(); s public.pos_sales%rowtype; v_who text;
begin
  if v_shop is null then return public._pos_denied(); end if;
  select * into s from public.pos_sales where id = p_sale_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('pos.err_not_found'));
  end if;

  -- Already marked: answer with the row as it stands. Two taps must not move
  -- the attribution off the person who actually took the money.
  if s.upi_paid_at is null and s.status = 'completed' then
    select coalesce(nullif(btrim(coalesce(pp.owner_name, pp.customer_name,'')),''),
                    pp.pharmacy_name)
      into v_who from public.pharmacy_profiles pp where pp.id = v_shop;
    update public.pos_sales
       set upi_paid_at = now(), upi_paid_by = auth.uid(),
           upi_paid_label = coalesce(public._upi_actor_label(), v_who)
     where id = s.id
    returning * into s;
  end if;

  return jsonb_build_object('ok', true, 'sale_id', s.id,
    'upi', public._pos_sale_upi(s),
    'message', public.ui_text('pos.upi_confirmed_toast'));
end $function$;

-- The counter's own static QR: no amount, no invoice. Printed once and taped to
-- the counter for the patient who would rather type the figure themselves.
create or replace function public.pos_upi_shop_qr()
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := public.pos_shop();
begin
  if v_shop is null then return public._pos_denied(); end if;
  return jsonb_build_object('ok', true,
    'header', public._pos_header(v_shop),
    'qr', public._upi_qr_block(v_shop, null, null,
            public.ui_text('pos.upi_shop_qr_title'),
            public.ui_text('pos.upi_shop_qr_sub')));
end $function$;

-- ─────── 6. THE EXISTING SURFACES, RE-CUT AROUND THE QR ─────────────────────
-- pos_sale_detail and pos_invoice_render_input are re-declared whole (there is
-- no way to append a key to a function) — the bodies below are #411's, with the
-- UPI panel and the printed QRs added and nothing else touched.

create or replace function public.pos_sale_detail(p_sale_id uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := public.pos_shop();
  s public.pos_sales%rowtype;
  v_lines jsonb; v_slabs jsonb;
begin
  if v_shop is null then return public._pos_denied(); end if;
  select * into s from public.pos_sales where id = p_sale_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('pos.err_not_found'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'line_no', l.line_no, 'medicine_id', l.medicine_id,
           'product_name', l.product_name, 'pack_label', l.pack_label,
           'batch_no', l.batch_no, 'expiry', l.expiry,
           'qty', l.qty, 'qty_label', public._pos_dec(l.qty),
           'mrp', l.mrp, 'mrp_display', public.inr_money(l.mrp),
           'disc_pct', l.disc_pct,
           'disc_display', case when l.disc_pct > 0
                                then public._pos_dec(l.disc_pct) || '%' else null end,
           'gst_percent', l.gst_percent,
           'gst_label', public._pos_dec(l.gst_percent) || '%',
           'taxable', l.taxable, 'cgst', l.cgst, 'sgst', l.sgst,
           'amount', l.amount, 'amount_display', public.inr_money(l.amount))
         order by l.line_no), '[]'::jsonb)
    into v_lines from public.pos_sale_lines l where l.sale_id = s.id;

  -- One row per distinct GST rate — the ladder a tax invoice must print.
  select coalesce(jsonb_agg(q.js order by q.rate), '[]'::jsonb)
    into v_slabs
    from (select l.gst_percent as rate,
                 jsonb_build_object(
                   'rate_label',      public._pos_dec(l.gst_percent) || '%',
                   'taxable_display', public.inr_money(sum(l.taxable)),
                   'cgst_display',    public.inr_money(sum(l.cgst)),
                   'sgst_display',    public.inr_money(sum(l.sgst))) as js
            from public.pos_sale_lines l
           where l.sale_id = s.id
           group by l.gst_percent) q;

  return jsonb_build_object(
    'ok', true,
    'sale_id', s.id,
    'header', public._pos_header(v_shop),
    'invoice', jsonb_build_object(
      'number',      s.invoice_no,
      'number_label', public.ui_text('pos.invoice_label') || ' ' || s.invoice_no,
      'date_label',  to_char(s.sold_at at time zone 'Asia/Kolkata', 'DD Mon YYYY, hh12:mi AM'),
      'staff_label', case when s.staff_label is not null
                         then public.ui_text('pos.staff_label') || ': ' || s.staff_label else null end,
      'patient_name', s.patient_name,
      'patient_phone', s.patient_phone,
      'has_patient', s.patient_name is not null or s.patient_phone is not null,
      'payment_label', public.ui_text('pos.pay_' || s.payment_mode),
      'payment_mode', s.payment_mode),
    'lines', v_lines,
    'tax_slabs', coalesce(v_slabs,'[]'::jsonb),
    'totals', jsonb_build_object(
      'gross_display',         public.inr_money(s.gross_amount),
      'line_discount_display', public.inr_money(s.line_discount),
      'has_line_discount',     s.line_discount > 0,
      'bill_discount_display', public.inr_money(s.bill_discount),
      'has_bill_discount',     s.bill_discount > 0,
      'taxable_display',       public.inr_money(s.taxable),
      'cgst_display',          public.inr_money(s.cgst),
      'sgst_display',          public.inr_money(s.sgst),
      'round_off_display',     public.inr_money(s.round_off),
      'has_round_off',         s.round_off <> 0,
      'net_display',           public.inr_money(s.net_amount),
      'net_words',             public.inr_words(s.net_amount),
      'mrp_note',              public.ui_text('pos.mrp_note')),
    'upi', public._pos_sale_upi(s),
    'receipt', jsonb_build_object(
      'status',      s.pdf_status,
      'is_ready',    s.pdf_status = 'ready',
      'is_building', s.pdf_status in ('queued','none'),
      'failed',      s.pdf_status = 'failed',
      'bucket',      s.pdf_bucket,
      'path',        s.pdf_path,
      'file_name',   s.pdf_name,
      'expires_s',   300,
      'poll_ms',     1500,
      'message',     case s.pdf_status
                       when 'ready'  then public.ui_text('pos.ready_message')
                       when 'failed' then public.ui_text('pos.pdf_failed')
                       else public.ui_text('pos.building_message') end,
      'print_label',    public.ui_text('pos.print_button'),
      'whatsapp_label', public.ui_text('pos.whatsapp_button')));
end $function$;

create or replace function public.pos_invoice_render_input(p_sale_id uuid)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare
  s public.pos_sales%rowtype; v jsonb; v_lines jsonb; v_slabs jsonb;
begin
  select * into s from public.pos_sales where id = p_sale_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'sn',      l.line_no,
           'product', l.product_name,
           'pack',    coalesce(l.pack_label,''),
           'batch_no', coalesce(l.batch_no,''),
           'expiry',  coalesce(l.expiry,''),
           'qty',     public._pos_dec(l.qty),
           'mrp',     public.inr_money(l.mrp),
           'disc',    case when l.disc_pct > 0
                           then public._pos_dec(l.disc_pct) || '%' else '' end,
           'taxable', public.inr_money(l.taxable),
           'gst_pct', public._pos_dec(l.gst_percent) || '%',
           'gst_amt', public.inr_money(l.cgst + l.sgst + l.igst),
           'amount',  public.inr_money(l.amount))
         order by l.line_no), '[]'::jsonb)
    into v_lines from public.pos_sale_lines l where l.sale_id = s.id;

  select coalesce(jsonb_agg(q.js order by q.rate), '[]'::jsonb)
    into v_slabs
    from (select l.gst_percent as rate,
                 jsonb_build_object(
                   'rate',    public._pos_dec(l.gst_percent) || '%',
                   'taxable', public.inr_money(sum(l.taxable)),
                   'cgst',    public.inr_money(sum(l.cgst)),
                   'sgst',    public.inr_money(sum(l.sgst)),
                   'total',   public.inr_money(sum(l.cgst + l.sgst))) as js
            from public.pos_sale_lines l where l.sale_id = s.id
           group by l.gst_percent) q;

  v := jsonb_build_object(
    'title',  'TAX INVOICE',
    'seller', public._pos_header(s.pharmacy_id),
    'invoice', jsonb_build_object(
      'number',     s.invoice_no,
      'date',       to_char(s.sold_at at time zone 'Asia/Kolkata', 'DD Mon YYYY'),
      'time',       to_char(s.sold_at at time zone 'Asia/Kolkata', 'hh12:mi AM'),
      'payment',    public.ui_text('pos.pay_' || s.payment_mode),
      'staff',      coalesce(s.staff_label,''),
      'patient',    coalesce(s.patient_name,''),
      'patient_phone', coalesce(s.patient_phone,'')),
    'columns', jsonb_build_array(
      jsonb_build_object('key','sn','label','#'),
      jsonb_build_object('key','product','label','Item'),
      jsonb_build_object('key','pack','label','Pack'),
      jsonb_build_object('key','batch_no','label','Batch'),
      jsonb_build_object('key','expiry','label','Exp'),
      jsonb_build_object('key','qty','label','Qty','align','right'),
      jsonb_build_object('key','mrp','label','MRP','align','right'),
      jsonb_build_object('key','disc','label','Disc','align','right'),
      jsonb_build_object('key','taxable','label','Taxable','align','right'),
      jsonb_build_object('key','gst_pct','label','GST','align','right'),
      jsonb_build_object('key','gst_amt','label','Tax','align','right'),
      jsonb_build_object('key','amount','label','Amount','align','right')),
    'lines', v_lines,
    'tax_summary', v_slabs,
    'totals', jsonb_build_array(
      jsonb_build_object('label', public.ui_text('pos.gross_label'),
                         'value', public.inr_money(s.gross_amount)),
      jsonb_build_object('label', public.ui_text('pos.line_disc_label'),
                         'value', public.inr_money(s.line_discount),
                         'hide', s.line_discount = 0),
      jsonb_build_object('label', public.ui_text('pos.bill_disc_total_label'),
                         'value', public.inr_money(s.bill_discount),
                         'hide', s.bill_discount = 0),
      jsonb_build_object('label', public.ui_text('pos.taxable_label'),
                         'value', public.inr_money(s.taxable)),
      jsonb_build_object('label', public.ui_text('pos.cgst_label'),
                         'value', public.inr_money(s.cgst)),
      jsonb_build_object('label', public.ui_text('pos.sgst_label'),
                         'value', public.inr_money(s.sgst)),
      jsonb_build_object('label', public.ui_text('pos.round_label'),
                         'value', public.inr_money(s.round_off),
                         'hide', s.round_off = 0)),
    'net', jsonb_build_object('label', public.ui_text('pos.net_label'),
                              'value', public.inr_money(s.net_amount),
                              'words', public.inr_words(s.net_amount)),
    'footer', jsonb_build_object(
      'note',  public.ui_text('pos.mrp_note'),
      'items', (select count(*)::text from public.pos_sale_lines where sale_id = s.id) || ' item(s)'));

  -- The receipt carries BOTH: the QR for this exact bill, and the shop's own
  -- standing QR. A patient who walks away with the paper can still pay from it.
  -- The bill QR is drawn only for a UPI bill. Printing "Scan to pay ₹11,297"
  -- on a cash receipt the patient has already settled is a way to be paid
  -- twice, and it is the same rule the on-screen panel follows (show:false).
  v := v || jsonb_build_object('qr', jsonb_build_object(
    'bill', case when s.payment_mode = 'upi'
                 then public._upi_qr_block(s.pharmacy_id, s.net_amount, s.invoice_no,
                        public.ui_text('pos.upi_qr_title'),
                        public.ui_text('pos.upi_qr_sub'))
                 else jsonb_build_object('has', false) end,
    'shop', public._upi_qr_block(s.pharmacy_id, null, null,
              public.ui_text('pos.upi_shop_qr_title'),
              public.ui_text('pos.upi_shop_qr_sub'))));

  return jsonb_build_object('ok', true,
    'invoice', v,
    'bucket', 'customer-bills',
    'path',   'pos/' || s.pharmacy_id::text || '/' || s.id::text || '.pdf',
    'file_name', 'Invoice-' || regexp_replace(s.invoice_no,'[^A-Za-z0-9-]','-','g') || '.pdf');
end $function$;

-- ── pos_day_close: UPI money is named for what it is ────────────────────────
-- The cash line is cash in the drawer. The UPI line is not a bank statement —
-- it is what staff SAID arrived. So the UPI row carries its own confirmed vs
-- not-yet-marked breakdown, and the day-close will not let an unmarked bill
-- disappear into a total that looks reconciled.
create or replace function public.pos_day_close(p_date date default null)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := public.pos_shop();
  v_on   date;
  v_bills int; v_net numeric; v_qty numeric;
  v_splits jsonb; v_recent jsonb; v_staff jsonb;
  v_upi_pend int; v_upi_conf numeric;
begin
  if v_shop is null then return public._pos_denied(); end if;
  v_on := coalesce(p_date, public._pos_today());

  select count(*), coalesce(sum(net_amount),0) into v_bills, v_net
    from public.pos_sales
   where pharmacy_id = v_shop and sold_on = v_on and status = 'completed';

  select coalesce(sum(l.qty),0) into v_qty
    from public.pos_sale_lines l join public.pos_sales s on s.id = l.sale_id
   where s.pharmacy_id = v_shop and s.sold_on = v_on and s.status = 'completed';

  select count(*) filter (where upi_paid_at is null),
         coalesce(sum(net_amount) filter (where upi_paid_at is not null), 0)
    into v_upi_pend, v_upi_conf
    from public.pos_sales
   where pharmacy_id = v_shop and sold_on = v_on and status = 'completed'
     and payment_mode = 'upi';

  -- Every mode always appears, zero included: a day-close that hides "UPI ₹0.00"
  -- makes the pharmacist wonder whether it is missing or zero.
  select coalesce(jsonb_agg(jsonb_build_object(
           'key',   m.key,
           'label', public.ui_text('pos.pay_' || m.key),
           'bills', coalesce(t.bills,0),
           'bills_label', coalesce(t.bills,0)::text
                          || case when coalesce(t.bills,0) = 1 then ' bill' else ' bills' end,
           'amount', coalesce(t.amt,0),
           'amount_display', public.inr_money(coalesce(t.amt,0)),
           'sub_label', case
             when m.key <> 'upi' or coalesce(t.bills,0) = 0 then null
             else public.ui_fmt('pos.upi_split_confirmed',
                    jsonb_build_object('amt', public.inr_money(v_upi_conf))) end,
           'warn_label', case
             when m.key <> 'upi' or v_upi_pend = 0 then null
             else public.ui_fmt('pos.upi_split_note',
                    jsonb_build_object('n', v_upi_pend::text)) end,
           'warn_tone', case when m.key = 'upi' and v_upi_pend > 0
                             then 'warning' end)
         order by m.ord), '[]'::jsonb)
    into v_splits
    from (values ('cash',1),('upi',2),('card',3),('credit',4)) as m(key, ord)
    left join (
      select payment_mode, count(*) as bills, sum(net_amount) as amt
        from public.pos_sales
       where pharmacy_id = v_shop and sold_on = v_on and status = 'completed'
       group by payment_mode) t on t.payment_mode = m.key;

  select coalesce(jsonb_agg(jsonb_build_object(
           'sale_id', s.id, 'invoice_no', s.invoice_no,
           'time_label', to_char(s.sold_at at time zone 'Asia/Kolkata','hh12:mi AM'),
           'patient', coalesce(s.patient_name,''),
           'payment_label', public.ui_text('pos.pay_' || s.payment_mode),
           'upi_pending', s.payment_mode = 'upi' and s.upi_paid_at is null,
           'upi_pending_label', case when s.payment_mode = 'upi' and s.upi_paid_at is null
                                     then public.ui_text('pos.upi_pending_note') end,
           'net_display', public.inr_money(s.net_amount))
         order by s.sold_at desc), '[]'::jsonb)
    into v_recent
    from (select * from public.pos_sales
           where pharmacy_id = v_shop and sold_on = v_on and status = 'completed'
           order by sold_at desc limit 25) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'staff_label', coalesce(q.staff_label,'—'),
           'bills', q.bills,
           'amount_display', public.inr_money(q.amt)) order by q.amt desc), '[]'::jsonb)
    into v_staff
    from (select staff_label, count(*) as bills, sum(net_amount) as amt
            from public.pos_sales
           where pharmacy_id = v_shop and sold_on = v_on and status = 'completed'
           group by staff_label) q;

  return jsonb_build_object(
    'ok', true,
    'date', v_on,
    'date_label', to_char(v_on, 'DD Mon YYYY'),
    'title', public.ui_text('pos.day_close_title'),
    'has_any', v_bills > 0,
    'empty_message', public.ui_text('pos.day_close_empty'),
    'empty_hint', public.ui_text('pos.day_close_empty_hint'),
    'tiles', jsonb_build_array(
      jsonb_build_object('key','bills', 'label', public.ui_text('pos.day_close_bills'),
                         'value', v_bills::text),
      jsonb_build_object('key','sales', 'label', public.ui_text('pos.day_close_sales'),
                         'value', public.inr_money(v_net)),
      jsonb_build_object('key','items', 'label', 'Items',
                         'value', public._pos_dec(v_qty))),
    'splits', v_splits,
    'upi_unconfirmed', v_upi_pend,
    'by_staff', v_staff,
    'recent', v_recent);
end $function$;

-- #411's pos_home body, lifted verbatim into a base so the counter payload
-- keeps ONE definition and this command only adds a key on top of it.
create or replace function public._pos_home_base()
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := public.pos_shop();
  v_today date := public._pos_today();
  v_bills int; v_net numeric;
begin
  if v_shop is null then return public._pos_denied(); end if;

  select count(*), coalesce(sum(net_amount),0) into v_bills, v_net
    from public.pos_sales
   where pharmacy_id = v_shop and sold_on = v_today and status = 'completed';

  return jsonb_build_object(
    'ok', true,
    'header', public._pos_header(v_shop),
    'labels', jsonb_build_object(
      'title',            public.ui_text('pos.title'),
      'subtitle',         public.ui_text('pos.subtitle'),
      'search_hint',      public.ui_text('pos.search_hint'),
      'search_empty',     public.ui_text('pos.search_empty'),
      'search_min',       public.ui_text('pos.search_hint_short'),
      'cart_empty',       public.ui_text('pos.cart_empty'),
      'cart_empty_hint',  public.ui_text('pos.cart_empty_hint'),
      'qty',              public.ui_text('pos.qty_label'),
      'disc',             public.ui_text('pos.disc_label'),
      'bill_disc',        public.ui_text('pos.bill_disc_label'),
      'patient_name',     public.ui_text('pos.patient_name_label'),
      'patient_phone',    public.ui_text('pos.patient_phone_label'),
      'pay',              public.ui_text('pos.pay_label'),
      'save',             public.ui_text('pos.save_button'),
      'saving',           public.ui_text('pos.saving'),
      'remove',           public.ui_text('pos.remove'),
      'gross',            public.ui_text('pos.gross_label'),
      'line_discount',    public.ui_text('pos.line_disc_label'),
      'bill_discount',    public.ui_text('pos.bill_disc_total_label'),
      'taxable',          public.ui_text('pos.taxable_label'),
      'cgst',             public.ui_text('pos.cgst_label'),
      'sgst',             public.ui_text('pos.sgst_label'),
      'round_off',        public.ui_text('pos.round_label'),
      'net',              public.ui_text('pos.net_label'),
      'mrp_note',         public.ui_text('pos.mrp_note'),
      'new_bill',         public.ui_text('pos.new_bill'),
      'day_close',        public.ui_text('pos.day_close_title'),
      'today',            public.ui_text('pos.today_label'),
      'retry',            public.ui_text('pos.retry')),
    'payment_modes', jsonb_build_array(
      jsonb_build_object('key','cash',  'label', public.ui_text('pos.pay_cash')),
      jsonb_build_object('key','upi',   'label', public.ui_text('pos.pay_upi')),
      jsonb_build_object('key','card',  'label', public.ui_text('pos.pay_card')),
      jsonb_build_object('key','credit','label', public.ui_text('pos.pay_credit'))),
    'default_payment', public._pos_settings(v_shop)->>'default_payment',
    'search_min_chars', 2,
    'today_strip', jsonb_build_object(
      'bills',        v_bills,
      'bills_label',  v_bills::text || case when v_bills = 1 then ' bill' else ' bills' end,
      'net',          v_net,
      'net_display',  public.inr_money(v_net),
      'has_any',      v_bills > 0,
      'date_label',   to_char(v_today, 'DD Mon YYYY')));
end $function$;

-- ── pos_home: the counter learns whether it can draw a QR at all ────────────
create or replace function public.pos_home()
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := public.pos_shop(); v_base jsonb;
begin
  if v_shop is null then return public._pos_denied(); end if;
  v_base := public._pos_home_base();
  return v_base || jsonb_build_object(
    'upi', public._upi_setup_block(v_shop) || jsonb_build_object(
             'tile_label',  public.ui_text('pos.upi_setup_tile'),
             'shop_qr_label', public.ui_text('pos.upi_shop_qr_open')));
end $function$;

-- ───────────────── 7. KHATA SETTLEMENT USES THE SAME QR ─────────────────────
-- #415 already deeplinks the reminder to this VPA. A settlement at the counter
-- is the same payment, so it gets the same picture — built by the same
-- upi_qr_string(), from the same column. `url` is kept for the WhatsApp
-- reminder, which needs a tappable link rather than a QR.
create or replace function public._khata_upi_link(p_shop uuid, p_amount numeric, p_note text)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_p jsonb := public._upi_payee(p_shop); v_url text;
begin
  if coalesce((v_p->>'has')::boolean, false) is not true then
    return jsonb_build_object('has', false,
      'reason', case when (v_p->>'reason') = 'not_confirmed'
                     then 'not_verified' else 'no_vpa' end);
  end if;
  v_url := public.upi_qr_string(v_p->>'vpa', v_p->>'payee',
             greatest(coalesce(p_amount,0), 0), p_note);
  return jsonb_build_object(
    'has', true,
    'vpa', v_p->>'vpa',
    'payee', v_p->>'payee',
    'amount_display', public.inr_money(greatest(coalesce(p_amount,0),0)),
    'label', public.ui_text('khata.pay_now'),
    'qr_caption', public.ui_text('khata.upi_qr_caption'),
    'qr_string', v_url,
    'url', v_url);
end $function$;

-- One write path for the VPA. #415's two RPCs stay on the wire (the khata
-- screen still calls them) but they no longer own the column: they delegate, so
-- the owner gate and the change history apply wherever the edit is made.
create or replace function public.khata_upi_save(p_vpa text, p_name text default null)
returns jsonb language sql security definer
set search_path to 'public' as $function$
  select public.pharmacy_upi_save(p_vpa, p_name, 'khata')
$function$;

create or replace function public.khata_upi_confirm(p_vpa text)
returns jsonb language sql security definer
set search_path to 'public' as $function$
  select public.pharmacy_upi_confirm(p_vpa, 'khata')
$function$;

-- ─────────────────────────── 8. GRANTS ──────────────────────────────────────
grant execute on function public.pharmacy_upi_get()                       to authenticated;
grant execute on function public.pharmacy_upi_save(text, text, text)      to authenticated;
grant execute on function public.pharmacy_upi_confirm(text, text)         to authenticated;
grant execute on function public.pos_upi_qr(uuid)                         to authenticated;
grant execute on function public.pos_upi_shop_qr()                        to authenticated;
grant execute on function public.pos_payment_confirm(uuid)                to authenticated;

revoke execute on function public.upi_qr_string(text, text, numeric, text) from anon;
revoke execute on function public._upi_payee(uuid)                        from anon, authenticated;
revoke execute on function public._upi_qr_block(uuid, numeric, text, text, text) from anon, authenticated;
revoke execute on function public._upi_setup_block(uuid)                  from anon, authenticated;
revoke execute on function public._pos_home_base()                        from anon, authenticated;
revoke execute on function public._pos_sale_upi(public.pos_sales)         from anon, authenticated;
revoke execute on function public.pharmacy_upi_history_rows(uuid, integer) from anon, authenticated;
revoke execute on function public._upi_actor_label()                      from anon, authenticated;

-- ───────────────── 9. THE PROOF THE SPEC ASKS FOR ───────────────────────────
-- VPA saved -> bill -> the QR encodes THIS amount and THIS invoice -> the tap
-- is attributed -> the day-close split counts it as staff-confirmed. Runs on a
-- real pharmacy row, rolls back everything it touched, and returns what it saw.
create or replace function public.pos_upi_qa_report()
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare
  v_shop uuid; v_owner uuid; v_act uuid := gen_random_uuid();
  o_vpa text; o_name text; o_ver timestamptz;
  s public.pos_sales%rowtype;
  v_sale jsonb; v_qr jsonb; v_expect text;
  v_conf jsonb; v_close jsonb; v_split jsonb; v_med bigint;
begin
  select pp.id, pp.user_id into v_shop, v_owner
    from public.pharmacy_profiles pp
   where pp.user_id is not null
     and pp.id in (select pharmacy_id from public.pos_sales)
   limit 1;
  if v_shop is null then
    return jsonb_build_object('ok', true, 'skipped', 'no_pos_shop');
  end if;

  -- Run as the shop's OWNER for the rest of this transaction. Every RPC below
  -- is the one the counter calls, gated exactly as the counter is gated — a
  -- proof that bypassed pos_shop() would prove nothing.
  perform set_config('request.jwt.claims',
            json_build_object('sub', v_owner::text, 'role', 'authenticated')::text, true);

  select upi_vpa, upi_vpa_name, upi_verified_at into o_vpa, o_name, o_ver
    from public.pharmacy_profiles where id = v_shop;

  -- 1. the owner saves and confirms the VPA (both through the real RPCs)
  perform public.pharmacy_upi_save('c432proof@upi', 'C432 Proof Pharmacy', 'pos');
  perform public.pharmacy_upi_confirm('c432proof@upi', 'pos');

  -- 2. a UPI bill
  select l.medicine_id into v_med from public.pos_sale_lines l
    join public.pos_sales ps on ps.id = l.sale_id
   where ps.pharmacy_id = v_shop and l.medicine_id is not null limit 1;

  v_sale := public.pos_commit_sale(v_act,
    jsonb_build_array(jsonb_build_object(
      'medicine_id', v_med, 'product_name', 'C432 PROOF ITEM',
      'qty', 1, 'mrp', 123.45)),
    0, 'upi', jsonb_build_object('name','C432 Proof'));

  select * into s from public.pos_sales where client_action_id = v_act;

  -- 3. the QR encodes THIS bill's exact rupees and THIS bill's invoice number
  v_qr := (public.pos_sale_detail(s.id))->'upi'->'qr';
  v_expect := 'upi://pay?pa=c432proof@upi&pn=C432 Proof Pharmacy&am='
              || to_char(round(s.net_amount,2),'FM9999999990.00')
              || '&cu=INR&tn=' || s.invoice_no;

  -- 4. the tap, attributed
  v_conf := public.pos_payment_confirm(s.id);
  select * into s from public.pos_sales where id = s.id;

  -- 5. the day-close counts it as staff-confirmed UPI
  v_close := public.pos_day_close(s.sold_on);
  select j into v_split from jsonb_array_elements(v_close->'splits') j
   where j->>'key' = 'upi';

  -- put the shop back exactly as it was
  delete from public.pos_sale_event where sale_id = s.id;
  delete from public.pos_sale_lines  where sale_id = s.id;
  delete from public.pos_sales       where id = s.id;
  delete from public.pharmacy_upi_history
   where pharmacy_id = v_shop and new_vpa = 'c432proof@upi';
  update public.pharmacy_profiles
     set upi_vpa = o_vpa, upi_vpa_name = o_name, upi_verified_at = o_ver
   where id = v_shop;

  return jsonb_build_object(
    'ok', (v_qr->>'qr_string') = v_expect
          and coalesce((v_qr->>'has')::boolean,false)
          and (v_conf->'upi'->>'is_confirmed')::boolean
          and coalesce(v_conf->'upi'->>'confirmed_label','') <> ''
          and (v_split->>'bills')::int >= 1
          and coalesce(v_split->>'sub_label','') <> '',
    'qr_string',       v_qr->>'qr_string',
    'expected',        v_expect,
    'encodes_amount',  (v_qr->>'qr_string') like ('%am=' || to_char(round(s.net_amount,2),'FM9999999990.00') || '%'),
    'encodes_invoice', (v_qr->>'qr_string') like ('%tn=' || s.invoice_no || '%'),
    'invoice_no',      s.invoice_no,
    'net_display',     public.inr_money(s.net_amount),
    'confirmed',       v_conf->'upi'->>'is_confirmed',
    'attributed',      v_conf->'upi'->>'confirmed_label',
    'upi_split',       v_split);
end $function$;

revoke execute on function public.pos_upi_qa_report() from anon, authenticated;

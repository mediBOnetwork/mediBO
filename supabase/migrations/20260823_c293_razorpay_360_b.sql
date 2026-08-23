-- CHANGE #293 — 360 audit of #291 (Razorpay). Part B: the RPCs.
--
-- Every display string below comes out of razorpay_copy / ui_copy or is built
-- here with inr_money(); Flutter renders what it is handed and computes none
-- of it. Idempotent — all CREATE OR REPLACE.

-- ── the collection mode, as a two-option selector ─────────────────────────
create or replace function public.payment_mode_get()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_mode text;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    raise exception 'not_authorized';
  end if;
  v_mode := public.payment_collection_mode();

  return jsonb_build_object(
    'ok', true,
    'title',    public._rzp_copy('admin_title'),
    'helper',   public._rzp_copy('admin_helper'),
    'selected', v_mode,
    -- kept so any older client still reading a boolean stays correct
    'enabled',  (v_mode = 'gateway'),
    'options', jsonb_build_array(
      jsonb_build_object(
        'key','manual_upi',
        'label',   public._rzp_copy('mode_manual_label'),
        'helper',  public._rzp_copy('mode_manual_helper'),
        'selected',(v_mode = 'manual_upi')),
      jsonb_build_object(
        'key','gateway',
        'label',   public._rzp_copy('mode_gateway_label'),
        'helper',  public._rzp_copy('mode_gateway_helper'),
        'selected',(v_mode = 'gateway'))),
    'mode_label', case when v_mode = 'gateway'
                       then public._rzp_copy('mode_gateway_label')
                       else public._rzp_copy('mode_manual_label') end,
    'mode_tone',  case when v_mode = 'gateway' then 'ok' else 'pending' end,
    'saved_label', public._rzp_copy('admin_saved_label'),
    'can_edit',   (public.get_my_role() = 'super_admin'),
    'money_lands', public.payment_money_lands(),
    'collection',  public.payment_collection_summary());
end $function$;

create or replace function public.payment_mode_set(p_mode text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_mode text;
begin
  if public.get_my_role() <> 'super_admin' then
    raise exception 'Only a super admin can change the payment collection mode';
  end if;
  v_mode := case when lower(coalesce(p_mode,'')) in ('gateway','razorpay','razorpay_qr')
                 then 'gateway' else 'manual_upi' end;
  update payment_config set collection_mode = v_mode, updated_at = now() where id = 1;
  return public.payment_mode_get();
end $function$;

-- the old boolean entry point keeps working and moves the SAME switch
create or replace function public.payment_mode_set(p_enabled boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  return public.payment_mode_set(
    (case when coalesce(p_enabled,false) then 'gateway' else 'manual_upi' end)::text);
end $function$;

-- ── where the money actually lands ────────────────────────────────────────
create or replace function public.payment_money_lands()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_mode text := public.payment_collection_mode();
  v_pa text; v_pn text; cfg payment_config%rowtype;
  v_miss text := public._rzp_copy('lands_missing');
  v_rows jsonb := '[]'::jsonb; v_note text := '';
begin
  select * into cfg from payment_config where id = 1;

  if v_mode = 'gateway' then
    v_rows := jsonb_build_array(
      jsonb_build_object('label', public._rzp_copy('lands_account_label'),
                         'value', coalesce(nullif(btrim(coalesce(cfg.rzp_account_name,'')),''),
                                           nullif(btrim(coalesce(cfg.rzp_key_id,'')),''), v_miss)),
      jsonb_build_object('label', public._rzp_copy('lands_bank_label'),
                         'value', case
                           when nullif(btrim(coalesce(cfg.rzp_settlement_bank,'')),'') is null
                            and nullif(btrim(coalesce(cfg.rzp_settlement_last4,'')),'') is null
                           then v_miss
                           else btrim(coalesce(cfg.rzp_settlement_bank,'')
                                      || case when nullif(btrim(coalesce(cfg.rzp_settlement_last4,'')),'') is not null
                                              then ' ••••' || btrim(cfg.rzp_settlement_last4) else '' end) end),
      jsonb_build_object('label', public._rzp_copy('lands_cycle_label'),
                         'value', coalesce(nullif(btrim(coalesce(cfg.rzp_settlement_cycle,'')),''), v_miss)));
    return jsonb_build_object(
      'ok', true, 'mode', v_mode,
      'title',   public._rzp_copy('lands_title'),
      'caption', public._rzp_copy('lands_gateway_caption'),
      'rows',    v_rows,
      'note',    '',
      'edit_label',  public._rzp_copy('lands_edit_label'),
      'edit_title',  public._rzp_copy('lands_edit_title'),
      'save_label',  public._rzp_copy('lands_save_label'),
      'cancel_label',public._rzp_copy('lands_cancel_label'),
      'cycle_hint',  public._rzp_copy('lands_cycle_hint'),
      'account_label', public._rzp_copy('lands_account_label'),
      'bank_label',    public._rzp_copy('lands_bank_label'),
      'cycle_label',   public._rzp_copy('lands_cycle_label'),
      'account_value', coalesce(cfg.rzp_account_name,''),
      'bank_value',    coalesce(cfg.rzp_settlement_bank,''),
      'last4_value',   coalesce(cfg.rzp_settlement_last4,''),
      'cycle_value',   coalesce(cfg.rzp_settlement_cycle,''),
      'can_edit', (public.get_my_role() = 'super_admin'));
  end if;

  select pa, pn into v_pa, v_pn
    from payment_upi_accounts where is_active order by created_at desc limit 1;

  if v_pa is null then
    v_note := public._rzp_copy('lands_no_vpa');
  else
    v_rows := jsonb_build_array(
      jsonb_build_object('label', public._rzp_copy('lands_vpa_label'),   'value', v_pa),
      jsonb_build_object('label', public._rzp_copy('lands_payee_label'), 'value', coalesce(v_pn, v_miss)));
  end if;

  return jsonb_build_object(
    'ok', true, 'mode', v_mode,
    'title',   public._rzp_copy('lands_title'),
    'caption', public._rzp_copy('lands_manual_caption'),
    'rows',    v_rows,
    'note',    v_note,
    'edit_label','',
    'can_edit', false);
end $function$;

create or replace function public.payment_gateway_details_set(
  p_account_name text, p_bank text, p_last4 text, p_cycle text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if public.get_my_role() <> 'super_admin' then
    raise exception 'Only a super admin can change the gateway settlement details';
  end if;
  update payment_config
     set rzp_account_name     = nullif(btrim(coalesce(p_account_name,'')),''),
         rzp_settlement_bank  = nullif(btrim(coalesce(p_bank,'')),''),
         rzp_settlement_last4 = nullif(regexp_replace(coalesce(p_last4,''),'\D','','g'),''),
         rzp_settlement_cycle = nullif(btrim(coalesce(p_cycle,'')),''),
         updated_at = now()
   where id = 1;
  return public.payment_money_lands();
end $function$;

-- called by the razorpay-account edge function, service side only
create or replace function public.payment_gateway_sync(p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  update payment_config
     set rzp_key_id            = coalesce(nullif(btrim(coalesce(p_patch->>'key_id','')),''), rzp_key_id),
         rzp_account_name      = coalesce(rzp_account_name,
                                   nullif(btrim(coalesce(p_patch->>'account_name','')),'')),
         rzp_settlement_bank   = coalesce(rzp_settlement_bank,
                                   nullif(btrim(coalesce(p_patch->>'bank','')),'')),
         rzp_settlement_last4  = coalesce(rzp_settlement_last4,
                                   nullif(btrim(coalesce(p_patch->>'last4','')),'')),
         rzp_last_settlement   = coalesce(p_patch->'last_settlement', rzp_last_settlement),
         rzp_account_synced_at = now(),
         updated_at            = now()
   where id = 1;
  return jsonb_build_object('ok', true);
end $function$;

-- ── zone-wise + date-wise collection summary ──────────────────────────────
-- Scope comes from the SAME central admin scopes every other admin screen
-- uses: admin_active_zone() (NULL = all zones) and admin_active_date().
create or replace function public.payment_collection_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_zone smallint := public.admin_active_zone();
  v_date date     := public.admin_active_date();
  v_total numeric := 0; v_ver numeric := 0; v_pend numeric := 0;
  v_orders int := 0; v_modes jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    raise exception 'not_authorized';
  end if;

  with rows as (
    select pc.*,
           case pc.payment_method
             when 'razorpay_qr' then 'gateway'
             when 'cash'        then 'cash'
             else 'manual' end as bucket,
           (pc.status in ('verified','received')) as is_verified
      from payment_claims pc
     where pc.business_date = v_date
       and (v_zone is null or pc.zone_id = v_zone)
       and pc.status not in ('rejected','duplicate')
  )
  select coalesce(sum(amount),0),
         coalesce(sum(amount) filter (where is_verified),0),
         coalesce(sum(amount) filter (where not is_verified),0),
         count(distinct order_id)
    into v_total, v_ver, v_pend, v_orders
    from rows;

  with rows as (
    select case pc.payment_method
             when 'razorpay_qr' then 'gateway'
             when 'cash'        then 'cash'
             else 'manual' end as bucket,
           pc.amount
      from payment_claims pc
     where pc.business_date = v_date
       and (v_zone is null or pc.zone_id = v_zone)
       and pc.status not in ('rejected','duplicate')
  ), agg as (
    select bucket, coalesce(sum(amount),0) amt, count(*) n from rows group by bucket
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'key',   k.bucket,
           'label', case k.bucket
                      when 'gateway' then public._rzp_copy('collection_mode_gateway')
                      when 'cash'    then public._rzp_copy('collection_mode_cash')
                      else                public._rzp_copy('collection_mode_manual') end,
           'amount_display', public.inr_money(coalesce(a.amt,0)),
           'count', coalesce(a.n,0)) order by k.ord), '[]'::jsonb)
    into v_modes
    from (values ('gateway',1),('manual',2),('cash',3)) as k(bucket, ord)
    left join agg a on a.bucket = k.bucket;

  return jsonb_build_object(
    'ok', true,
    'title',        public._rzp_copy('collection_title'),
    'zone_id',      v_zone,
    'zone_label',   coalesce((select z.name from zones z where z.id = v_zone),
                             (select coalesce(value->>'all_label','')
                                from app_settings where key = 'zone_picker_copy')),
    'date',         to_char(v_date,'YYYY-MM-DD'),
    'date_label',   coalesce((select s->>'label'
                                from (select public.admin_date_scope_state() s) q),
                             to_char(v_date,'DD Mon YYYY')),
    'total_label',    public._rzp_copy('collection_total_label'),
    'total_display',  public.inr_money(v_total),
    'orders_label',   public._rzp_copy('collection_orders_label'),
    'orders_count',   v_orders,
    'verified_label', public._rzp_copy('collection_verified_label'),
    'verified_display', public.inr_money(v_ver),
    'pending_label',  public._rzp_copy('collection_pending_label'),
    'pending_display', public.inr_money(v_pend),
    'modes',        v_modes,
    'is_empty',     (v_total = 0 and v_orders = 0),
    'empty_label',  public._rzp_copy('collection_empty'));
end $function$;

-- ── the collection mode now drives the QR path ────────────────────────────
create or replace function public.rzp_panel_block()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_on boolean := (public.payment_collection_mode() = 'gateway');
begin
  return jsonb_build_object(
    'provider', case when v_on then 'razorpay_qr' else 'upi_manual' end,
    'collection_mode', public.payment_collection_mode(),
    'razorpay', jsonb_build_object(
      'enabled',          v_on,
      'loading_label',    public._rzp_copy('loading_label'),
      'error_label',      public._rzp_copy('error_label'),
      'retry_label',      public._rzp_copy('retry_label'),
      'note_label',       public._rzp_copy('sheet_note'),
      'amount_row_label', public._rzp_copy('amount_row_label'),
      'expired_label',    public._rzp_copy('expired_label'),
      'closed_label',     public._rzp_copy('closed_label'),
      'paid_toast',       public._rzp_copy('checkout_paid_toast')));
end $function$;

-- ── checkout: the button, and who is allowed to pay for this order ────────
create or replace function public.checkout_action()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_mode text  := public.payment_collection_mode();
  v_act  uuid  := public.my_acting_as();
  v_role text  := coalesce(public.get_my_role(),'none');
  v_staff boolean := v_role in ('admin','super_admin','worker');
  v_pay  boolean;
begin
  -- A real customer paying for their own order is the ONLY case that pays at
  -- checkout. An admin acting as a customer cannot pay on their behalf, so the
  -- button stays "Place Order" and the QR goes to the customer on WhatsApp.
  v_pay := (v_mode = 'gateway') and v_act is null and not v_staff;

  return jsonb_build_object(
    'ok', true,
    'collection_mode', v_mode,
    'provider',        case when v_mode = 'gateway' then 'razorpay_qr' else 'upi_manual' end,
    'acting_as',       (v_act is not null),
    'placed_by_admin', (v_act is not null),
    'pay_now',         v_pay,
    'button_label',    case when v_pay then public._rzp_copy('checkout_btn_pay')
                            else public._rzp_copy('checkout_btn_place') end,
    'pay_title',       public._rzp_copy('checkout_pay_title'),
    'actingas_note',   case when v_act is not null and v_mode = 'gateway'
                            then public._rzp_copy('checkout_actingas_note') else '' end,
    'paid_toast',      public._rzp_copy('checkout_paid_toast'),
    'done_label',      public._rzp_copy('checkout_done_label'));
end $function$;

-- The customer sheet polls this: "has the webhook confirmed my order yet?".
create or replace function public.rzp_order_paid(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare q public.razorpay_qr%rowtype; v_ok boolean;
begin
  select (o.user_id = any (public.my_owner_user_ids())
          or o.customer_id is not distinct from public.my_customer_id()
          or public.get_my_role() in ('admin','super_admin'))
    into v_ok from orders o where o.id = p_order_id;
  if not coalesce(v_ok,false) then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;

  select * into q from public.razorpay_qr
   where order_id = p_order_id order by created_at desc limit 1;
  if not found then return jsonb_build_object('ok', true, 'paid', false, 'has_qr', false); end if;

  return jsonb_build_object(
    'ok', true, 'has_qr', true,
    'paid', (q.status = 'paid'),
    'status', q.status,
    'view', public.rzp_qr_view(q.id),
    'paid_toast', public._rzp_copy('checkout_paid_toast'));
end $function$;

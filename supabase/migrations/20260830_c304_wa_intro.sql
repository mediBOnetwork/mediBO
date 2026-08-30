-- CHANGE #304 (f) — the chat send's intro sentence belongs to the backend too.
-- send-payment-qr joins the view's own strings; it composes no sentence of its
-- own, so the wording changes with an UPDATE, never a deploy.
create or replace function public._rzp_attempt_view(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare a public.rzp_payment_attempt%rowtype;
begin
  select * into a from public.rzp_payment_attempt where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error','attempt_not_found'); end if;
  return jsonb_build_object(
    'ok', true,
    'provider',      'razorpay_checkout',
    'attempt_id',    a.id,
    'mode',          a.mode,
    'kind',          a.kind,
    'status',        a.status,
    'status_label',  public._rzp_copy('attempt_status_' || a.status),
    'paid',          (a.status = 'paid'),
    'resumable',     (a.status in ('pending','attempted')
                      and coalesce(a.expires_at, now() + interval '1 day') > now()),
    'pay_url',       a.short_url,
    'rzp_link_id',   a.rzp_link_id,
    'rzp_order_id',  a.rzp_order_id,
    'amount',        a.amount,
    'amount_label',  '₹' || to_char(a.amount, 'FM99,99,99,990.00'),
    'amount_row_label', public._rzp_copy('amount_row_label'),
    'title',         case when a.status = 'paid' then public._rzp_copy('paid_label')
                          else public._rzp_copy('sdk_sheet_title') end,
    'subtitle',      case when a.status = 'paid' then ''
                          else public._rzp_copy('sdk_sheet_subtitle') end,
    'link_row_label',public._rzp_copy('sdk_link_row_label'),
    'link_wa_intro', public._rzp_copy('link_wa_intro'),
    'button_label',  case
                       when a.status = 'paid' then ''
                       when a.status = 'attempted' then public._rzp_copy('sdk_resume_label')
                       else public._rzp_copy('sdk_button_label') end,
    'failure_label', case when a.status = 'failed' then public._rzp_copy('sdk_failed_label')
                          when a.status = 'expired' then public._rzp_copy('sdk_expired_label')
                          else '' end,
    'paid_at_label', case when a.paid_at is not null
      then to_char(a.paid_at at time zone 'Asia/Kolkata', 'FMHH12:MI am "on" DD Mon') end);
end $$;

-- CMD #2181 (debug pass on #2131, QA finding 569)
--
-- The Android phone-number hint can answer with a number this login cannot use
-- (a short number, a non-Indian number). Before this, login_view just returned:
-- the box stayed empty, nothing was said, and the one picker attempt per visit
-- was already spent, so the user had a dead box and no explanation.
--
-- The screen now says something and gives the attempt back. The sentence is the
-- BACKEND's, like every other string on the login screen: one row in
-- storefront_ui_label, editable with an UPDATE and no deploy.
--
-- Idempotent: the label insert is on-conflict-do-nothing (so an edited sentence
-- is never overwritten by a replay) and the function is CREATE OR REPLACE.

insert into public.storefront_ui_label (key, value, note)
values (
  'login_number_hint_unusable',
  'That number can''t be used here. Pick another or type your 10-digit WhatsApp number.',
  'CMD #2181 — shown when Android''s phone-number hint returns a number that is not a usable 10-digit Indian number.'
)
on conflict (key) do nothing;

create or replace function public.login_screen_config()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'brand','mediBO',
    'tagline',coalesce((select value from public.storefront_ui_label where key='login_tagline'),'B2B pharma fulfilment'),
    'google_label','Continue with Google',
    'google_sheet_title','Choose an account',
    'google_sheet_subtitle','to continue to mediBO',
    'google_other_account','Use another account',
    'google_unavailable_note','Google did not show the account sheet this time.',
    'google_browser_label','Choose a Google account in your browser',
    'whatsapp_label','Continue on WhatsApp',
    'number_section_label','WhatsApp number',
    'number_hint','00000 00000',
    'number_prefix','+91',
    'number_hint_unusable',coalesce(
      (select value from public.storefront_ui_label where key='login_number_hint_unusable'),
      'That number can''t be used here. Pick another or type your 10-digit WhatsApp number.'),
    'send_label','Send code',
    'sending_label','Sending on WhatsApp',
    'code_section_label','Enter login code',
    'code_sent_note','Code sent on WhatsApp',
    'code_digits',6,
    'otp_hint','6-digit code',
    'code_idle_note','Enter the code to continue',
    'verify_label','Validate',
    'resend_label','Resend',
    'resend_seconds',30,
    'sent_to_prefix','to',
    'footer_note','No password — we only send a login code',
    'show_password', false,
    'show_forgot_password', false
  )
$function$;

-- The login screen is reached signed-out: anon must keep EXECUTE, and only that.
grant execute on function public.login_screen_config() to anon, authenticated, service_role;

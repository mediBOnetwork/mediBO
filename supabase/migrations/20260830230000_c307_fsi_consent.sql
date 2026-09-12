-- CHANGE #307 (step 9) — the full-screen-intent consent seam.
--
-- Om answered Play Console → App content → Full-screen intent with OTHER (the
-- honest answer: mediBO is neither an alarm clock nor a calling app). Per
-- Google, from 22 Jan 2025 apps targeting Android 14+ that answer anything but
-- calling/alarm do NOT get USE_FULL_SCREEN_INTENT granted by default — the user
-- must grant it at runtime. So the app has to ask, and must stay useful when
-- the answer is no.
--
-- Every word the app shows about that lives HERE, never in Dart. The device
-- fact (granted / not granted / not applicable) comes from Android; the
-- sentence wrapped around that fact comes from this table.
--
-- Idempotent: existing keys WIN (`new || labels`), so re-applying never
-- overwrites a label Om has since edited.

update public.order_alert_config
   set labels = jsonb_build_object(
     'fsi_section',            'Lock-screen alerts on this device',
     'fsi_checking',           'Checking this device…',
     'fsi_granted_title',      'Full-screen alerts are ON',
     'fsi_granted_body',       'A new order takes over the lock screen on this device, with Accept and Reject on the alert itself.',
     'fsi_denied_title',       'Full-screen alerts are OFF',
     'fsi_denied_body',        'New orders still ring with sound and still show Accept and Reject — but as a banner, not over the lock screen. Android 14 asks for this one permission separately.',
     'fsi_unsupported_title',  'Nothing to turn on here',
     'fsi_unsupported_body',   'This Android version gives mediBO lock-screen alerts without asking. Alerts ring with Accept and Reject as normal.',
     'fsi_web_title',          'Lock-screen alerts are an app feature',
     'fsi_web_body',           'Install the mediBO Android app to get a ringing lock-screen alert for a new order. The browser shows the in-app alert instead.',
     'fsi_action',             'Open Android settings',
     'fsi_recheck',            'Check again',
     'fsi_prompt_title',       'Let new orders ring over the lock screen',
     'fsi_prompt_body',        'Android 14 keeps this permission switched off until you allow it. Allow it and a new order wakes the screen the moment it lands. Skip it and the alert still rings with Accept and Reject, just as a banner.',
     'fsi_prompt_cta',         'Allow on this device',
     'fsi_prompt_skip',        'Not now',
     'fsi_degraded_note',      'Alerts are never silent: without this permission mediBO still rings and still shows Accept and Reject.'
   ) || labels
 where id = 'singleton';

-- One home for the block, so every surface reads the same words.
create or replace function public.order_alert_fsi()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'section',           public.oa_label('fsi_section'),
    'checking',          public.oa_label('fsi_checking'),
    'granted_title',     public.oa_label('fsi_granted_title'),
    'granted_body',      public.oa_label('fsi_granted_body'),
    'denied_title',      public.oa_label('fsi_denied_title'),
    'denied_body',       public.oa_label('fsi_denied_body'),
    'unsupported_title', public.oa_label('fsi_unsupported_title'),
    'unsupported_body',  public.oa_label('fsi_unsupported_body'),
    'web_title',         public.oa_label('fsi_web_title'),
    'web_body',          public.oa_label('fsi_web_body'),
    'action',            public.oa_label('fsi_action'),
    'recheck',           public.oa_label('fsi_recheck'),
    'prompt_title',      public.oa_label('fsi_prompt_title'),
    'prompt_body',       public.oa_label('fsi_prompt_body'),
    'prompt_cta',        public.oa_label('fsi_prompt_cta'),
    'prompt_skip',       public.oa_label('fsi_prompt_skip'),
    'degraded_note',     public.oa_label('fsi_degraded_note'))
$function$;

revoke execute on function public.order_alert_fsi() from public, anon;
grant execute on function public.order_alert_fsi() to authenticated, service_role;

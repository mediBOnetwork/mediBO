-- CMD #2016 — the new-order alert in the app is a CENTRE POPUP, and nothing else.
--
-- #1988 replaced the centre dialog with a slim strip above the header. #1989
-- added a bottom sheet next to it. Om's call on 16 Sep: the strip goes away
-- entirely, and the one in-app surface is a centre modal that can be dismissed
-- with "Later" — the order stays in Awaiting action and the nav badge keeps
-- counting it. Background/closed is unchanged: the system notification only.
--
-- What this migration does:
--   1. popup_* labels merged into order_alert_config; the strip_* and the
--      now-unused sheet_* keys removed, so a label nothing renders cannot be
--      edited into a surface that no longer exists.
--   2. order_alert_popup_dismiss — "Later", per DEVICE. It suppresses the
--      POPUP for that device and nothing else: the alert stays ringing, the
--      feed still lists it, the badge still counts it.
--   3. order_alert_popup(p_device_id) — the popup's whole payload, rendered.
--      Newest alert first (the spec's "shows the newest"), "+N more" written
--      here, show:false the moment no live alert is left for this device.
--   4. order_alert_popup_later(p_order_id, p_device_id) — records the dismissal
--      and hands back the NEXT popup payload in the same round trip.
--   5. order_alert_strip() and order_alert_sheet() are dropped: the surfaces
--      they fed no longer exist, and a live RPC with no screen is an orphan.
--
-- Idempotent: labels are merged, the table is `if not exists`, every function
-- is create-or-replace, and the drops are `if exists`.

-- ── 1. LABELS ───────────────────────────────────────────────────────────────

insert into public.order_alert_config (id) values ('singleton')
on conflict (id) do nothing;

update public.order_alert_config
   set labels = coalesce(labels, '{}'::jsonb) || jsonb_build_object(
     -- the centre popup
     'popup_title',          'New order',
     'popup_title_many',     'New orders',
     'popup_amount_caption', 'Order value',
     'popup_items',          '{{items}}',
     'popup_age_prefix',     '{{age}} ago',
     'popup_status_paid',    'Paid',
     'popup_status_unpaid',  'Unpaid',
     'popup_primary',        'Open order',
     'popup_secondary',      'Later',
     'popup_more',           '+{{count}} more waiting',
     'popup_no_name',        'Customer',
     -- Repaired in passing: _oa_age_label() has asked for these three keys
     -- since #306 and order_alert_config has never held them, so every age on
     -- every alert surface rendered as an empty string. The popup shows the
     -- age, so the words it needs are seeded here.
     'age_seconds',          '{{n}}s',
     'age_minutes',          '{{n}} min',
     'age_hours',            '{{n}} hr')
 where id = 'singleton';

-- The strip is gone from the app, so its words go from the editor too. The
-- sheet keys follow it: #1989's bottom sheet is what the popup replaces.
-- sheet_status_paid / sheet_status_unpaid stay — order_alert_notif() still
-- renders the lock-screen card's status word from them.
update public.order_alert_config
   set labels = coalesce(labels, '{}'::jsonb)
                  - 'strip_title_one'  - 'strip_title_many'
                  - 'strip_subtitle'   - 'strip_action'
                  - 'strip_more'       - 'strip_prepaid'
                  - 'strip_unpaid'
                  - 'sheet_primary'    - 'sheet_age_prefix'
                  - 'sheet_more_waiting'
                  - 'sheet_preview_more' - 'sheet_preview_none'
 where id = 'singleton';

-- ── 2. "LATER", PER DEVICE ──────────────────────────────────────────────────
-- One row = "this device has seen this alert's popup and put it aside". It
-- never touches order_alert: the state stays 'ringing', order_alert_feed()
-- still lists it, and the nav badge still counts it. That separation is the
-- whole of spec item 3.

create table if not exists public.order_alert_popup_dismiss (
  alert_id     bigint      not null references public.order_alert(id) on delete cascade,
  device_id    text        not null,
  user_id      uuid,
  dismissed_at timestamptz not null default now(),
  primary key (alert_id, device_id)
);

create index if not exists order_alert_popup_dismiss_device_idx
  on public.order_alert_popup_dismiss (device_id, alert_id);

alter table public.order_alert_popup_dismiss enable row level security;

-- No policy: every read and write goes through the SECURITY DEFINER RPCs
-- below, which is the same shape the rest of the alert tables use.

-- ── 3. THE POPUP ────────────────────────────────────────────────────────────
-- One RPC, one screen. Every string on the popup is built here.

create or replace function public.order_alert_popup(p_device_id text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  a public.order_alert%rowtype;
  v_dev text; v_count int; v_paid boolean; v_age text; v_tone text; v_ring boolean;
  v_name text;
begin
  if public.get_my_role() not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', false, 'show', false, 'count', 0,
                              'autoshow', false);
  end if;

  v_dev := coalesce(nullif(btrim(p_device_id), ''), '-');

  -- The badge's number: every live alert this caller may see, dismissed or
  -- not. "Later" must never change a count.
  select count(*)::int into v_count
    from public.order_alert al
   where al.state = 'ringing' and public._oa_visible(al.zone_id);

  -- The NEWEST alert this DEVICE has not put aside.
  select * into a
    from public.order_alert al
   where al.state = 'ringing'
     and public._oa_visible(al.zone_id)
     and not exists (select 1 from public.order_alert_popup_dismiss d
                      where d.alert_id = al.id and d.device_id = v_dev)
   order by al.created_at desc, al.id desc
   limit 1;

  if a.id is null then
    -- Spec item 4: no live server alert for this device means no popup, and
    -- the one on screen closes itself on the next read.
    return jsonb_build_object('ok', true, 'show', false, 'count', v_count,
                              'ring', false, 'order_id', null, 'alert_id', null,
                              'autoshow', false, 'poll_s', 20, 'refresh_s', 30);
  end if;

  v_paid := public.order_is_paid(a.order_id);
  v_age  := public._oa_age_label(a.created_at);
  v_tone := case when v_paid then 'success' else 'warning' end;
  v_ring := a.ring and a.state = 'ringing'
              and not public._oa_open_quiet(a)
              and not public._oa_silent_for(auth.uid(), null);
  v_name := coalesce(nullif(btrim(a.customer_name), ''),
                     nullif(coalesce(a.order_code, ''), ''),
                     public.oa_label('popup_no_name'));

  return jsonb_build_object(
    'ok',              true,
    'show',            true,
    'count',           v_count,
    'alert_id',        a.id,
    'order_id',        a.order_id,
    'order_code',      coalesce(a.order_code, ''),
    'title',           case when v_count > 1 then public.oa_label('popup_title_many')
                            else public.oa_label('popup_title') end,
    'customer_name',   v_name,
    'amount_display',  public.inr_money(a.amount),
    'amount_caption',  public.oa_label('popup_amount_caption'),
    'items_label',     public.oa_label('popup_items', jsonb_build_object(
                         'items', public._oa_items_label(a.order_id))),
    'item_count',      public._oa_item_count(a.order_id),
    -- An age we cannot say is an ABSENCE, never the word "ago" on its own.
    'age_label',       case when btrim(coalesce(v_age, '')) = '' then ''
                            else public.oa_label('popup_age_prefix',
                                   jsonb_build_object('age', v_age)) end,
    'status_label',    public.oa_label(case when v_paid then 'popup_status_paid'
                                            else 'popup_status_unpaid' end),
    'status_tone',     v_tone,
    'paid',            v_paid,
    'primary_label',   public.oa_label('popup_primary'),
    'secondary_label', public.oa_label('popup_secondary'),
    -- "+N more" counts every OTHER live alert, dismissed on this device or not:
    -- it is the same number the Awaiting action list shows.
    'more_label',      case when v_count > 1
                            then public.oa_label('popup_more',
                                   jsonb_build_object('count', (v_count - 1)::text))
                            else '' end,
    'ring',            v_ring,
    'opened',          a.opened_at is not null,
    -- Whether the popup INTERRUPTS is the backend's call, never the client's.
    -- An order somebody has already opened (here or on another device) is no
    -- longer waiting for a decision, so it stops popping up — the alert stays
    -- live, the badge keeps counting it, and the list still shows it.
    'autoshow',        (a.opened_at is null and a.state = 'ringing'),
    'refresh_s',       30,
    'poll_s',          20);
end $function$;

-- ── 4. "LATER" ──────────────────────────────────────────────────────────────
-- Dismiss for THIS device, then answer with the next popup in the same trip.

create or replace function public.order_alert_popup_later(p_order_id uuid,
                                                          p_device_id text default null)
returns jsonb language plpgsql volatile security definer set search_path to 'public'
as $function$
declare v_dev text; v_alert bigint;
begin
  if public.get_my_role() not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', false, 'show', false, 'count', 0);
  end if;
  v_dev := coalesce(nullif(btrim(p_device_id), ''), '-');

  select al.id into v_alert
    from public.order_alert al
   where al.order_id = p_order_id and public._oa_visible(al.zone_id)
   order by al.created_at desc limit 1;

  if v_alert is not null then
    insert into public.order_alert_popup_dismiss (alert_id, device_id, user_id)
    values (v_alert, v_dev, auth.uid())
    on conflict (alert_id, device_id) do update set dismissed_at = now();
  end if;

  return public.order_alert_popup(p_device_id);
end $function$;

-- ── 5. THE SURFACES THAT NO LONGER EXIST ────────────────────────────────────
-- The strip is deleted from the app in the same command, and the bottom sheet
-- is what the centre popup replaces. Neither RPC has a screen any more.

drop function if exists public.order_alert_strip();
drop function if exists public.order_alert_sheet(uuid);
drop function if exists public._oa_items_preview(uuid, integer);

-- ── 5b. STOP ON OPEN, WITHOUT THE STRIP ─────────────────────────────────────
-- order_alert_seen() returned the strip payload inline, so dropping the strip
-- would have left it raising at call time (plpgsql resolves the call at run
-- time, so the DROP above succeeds and the break only shows on a real open).
-- It returns the POPUP now, for the DEVICE that opened the order. The old
-- two-argument signature is dropped first: adding a defaulted third argument
-- beside it would leave two candidates and PostgREST would refuse the call.

drop function if exists public.order_alert_seen(uuid, text);

create or replace function public.order_alert_seen(p_order_id uuid,
                                                   p_source text default 'app',
                                                   p_device_id text default null)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare a public.order_alert%rowtype;
begin
  if public.get_my_role() not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select * into a from public.order_alert where order_id = p_order_id;
  if a.id is null or not public._oa_visible(a.zone_id) then
    return jsonb_build_object('ok', true, 'cleared', false, 'popup',
                              public.order_alert_popup(p_device_id));
  end if;
  if a.opened_at is null then
    update public.order_alert
       set opened_at = now(), opened_by = auth.uid(),
           opened_source = coalesce(nullif(btrim(p_source),''),'app')
     where id = a.id;
  end if;
  return jsonb_build_object(
    'ok', true, 'cleared', true, 'alert_id', a.id,
    'message', public.oa_label('seen_toast'),
    'popup',   public.order_alert_popup(p_device_id));
end $function$;

-- ── 5c. THE POPUP'S WORDS, EDITABLE IN THE APP ──────────────────────────────
-- Spec item 5: every string on the popup comes from order_alert_config.labels
-- "so everything stays editable without a redeploy". order_alert_settings()
-- has never returned `labels`, so until now those words existed but had no
-- door — editable in principle, unreachable in practice. This is the door, and
-- like every other field list in this feature the ROWS come from here: the
-- screen renders key/label/value and sends back what was typed.

create or replace function public.order_alert_popup_labels()
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_labels jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_admin');
  end if;
  select coalesce(labels, '{}'::jsonb) into v_labels
    from public.order_alert_config where id = 'singleton';

  return jsonb_build_object(
    'ok',           true,
    'title',        public.oa_label('popup_labels_title'),
    'subtitle',     public.oa_label('popup_labels_subtitle'),
    'save_label',   public.oa_label('popup_labels_save'),
    'saved_label',  public.oa_label('saved'),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                      'key',   r.key,
                      'label', public.oa_label('popup_labels_' || r.key),
                      'value', coalesce(v_labels->>r.key, ''),
                      'hint',  r.hint) order by r.ord), '[]'::jsonb)
               from (values
                 ('popup_title',          '',            1),
                 ('popup_title_many',     '',            2),
                 ('popup_amount_caption', '',            3),
                 ('popup_items',          '{{items}}',   4),
                 ('popup_age_prefix',     '{{age}}',     5),
                 ('popup_status_paid',    '',            6),
                 ('popup_status_unpaid',  '',            7),
                 ('popup_primary',        '',            8),
                 ('popup_secondary',      '',            9),
                 ('popup_more',           '{{count}}',  10),
                 ('popup_no_name',        '',           11)
               ) as r(key, hint, ord)
               where r.hint is not null));
end $function$;

create or replace function public.order_alert_popup_labels_set(p_patch jsonb)
returns jsonb language plpgsql volatile security definer set search_path to 'public'
as $function$
declare v_by text; v_clean jsonb := '{}'::jsonb; k text;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_admin');
  end if;
  select lower(btrim(u.email)) into v_by from auth.users u where u.id = auth.uid();

  -- Only this popup's own keys may be written here: the editor cannot reach
  -- the push, the tray or another feature's copy by sending a different key.
  for k in select jsonb_object_keys(coalesce(p_patch, '{}'::jsonb)) loop
    if k like 'popup\_%' then
      v_clean := v_clean || jsonb_build_object(k, coalesce(p_patch->>k, ''));
    end if;
  end loop;

  if v_clean <> '{}'::jsonb then
    update public.order_alert_config
       set labels = coalesce(labels, '{}'::jsonb) || v_clean,
           updated_at = now(), updated_by = coalesce(v_by, 'admin')
     where id = 'singleton';
    perform public.audit_write('order_alert_popup_labels_set',
              'order_alert_config', 'singleton', null,
              v_clean || jsonb_build_object('by', coalesce(v_by, 'admin')));
  end if;

  return public.order_alert_popup_labels() || jsonb_build_object('saved', true);
end $function$;

-- The editor's own chrome is copy too.
update public.order_alert_config
   set labels = coalesce(labels, '{}'::jsonb) || jsonb_build_object(
     'popup_labels_title',    'New-order popup wording',
     'popup_labels_subtitle', 'Every word on the popup an admin sees when a new order arrives. Saved instantly — no app update.',
     'popup_labels_save',     'Save wording',
     'popup_labels_popup_title',          'Heading (one order)',
     'popup_labels_popup_title_many',     'Heading (several orders)',
     'popup_labels_popup_amount_caption', 'Amount caption',
     'popup_labels_popup_items',          'Item count line',
     'popup_labels_popup_age_prefix',     'Age line',
     'popup_labels_popup_status_paid',    'Paid chip',
     'popup_labels_popup_status_unpaid',  'Unpaid chip',
     'popup_labels_popup_primary',        'Primary button',
     'popup_labels_popup_secondary',      'Dismiss button',
     'popup_labels_popup_more',           'More-waiting line',
     'popup_labels_popup_no_name',        'Fallback customer name')
 where id = 'singleton';

-- ── 6. GRANTS ───────────────────────────────────────────────────────────────
-- A new SECURITY DEFINER function inherits PUBLIC EXECUTE (standing lesson
-- #122): revoke by pattern, then grant only the role that may call it.

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig, p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('order_alert_popup','order_alert_popup_later',
                         'order_alert_seen','order_alert_popup_labels',
                         'order_alert_popup_labels_set')
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end $$;

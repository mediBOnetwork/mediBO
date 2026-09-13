-- CMD #1947 — the staff header date·zone chip.
--
-- The Dashboard's second row (AdminDatePicker + AdminZonePicker) moves into the
-- header row itself as ONE chip: "12 Sep · Raipur". Everything the chip and its
-- sheet render is produced here — the date text, the zone text, the compact
-- (<900px) form, the sheet headings and the calendar/zone payloads. Flutter
-- renders the strings verbatim and writes back through the SAME two RPCs
-- (admin_set_date_scope / admin_set_zone_scope), so every tab follows exactly
-- as it does today.
--
-- Idempotent: copy/config rows are seeded ON CONFLICT DO NOTHING so production
-- keeps whatever wording it already has.

-- ── copy (wording lives in ui_copy, never in Dart) ──────────────────────────
insert into public.ui_copy(key, value) values
  ('scope_chip.sheet_title', '"Date & zone"'::jsonb),
  ('scope_chip.date_title',  '"Date"'::jsonb),
  ('scope_chip.zone_title',  '"Zone"'::jsonb),
  ('scope_chip.done',        '"Done"'::jsonb),
  ('scope_chip.separator',   '" · "'::jsonb),
  ('scope_chip.tooltip',     '"Change date or zone"'::jsonb),
  ('scope_chip.all_label',   '"All zones"'::jsonb),
  ('scope_chip.all_code',    '"ALL"'::jsonb),
  ('scope_chip.empty',       '"—"'::jsonb),
  ('session.header_short_fallback', '"Account"'::jsonb)
on conflict (key) do nothing;

insert into public.app_settings(key, value) values
  ('scope_chip_cfg', jsonb_build_object('date_format','FMDD Mon','short_name_max',12))
on conflict (key) do nothing;

-- The short staff name shown in the web user menu. An explicit override map
-- wins (one row, no deploy); otherwise the first word of the profile name;
-- otherwise the email's local part, truncated by the backend.
insert into public.app_settings(key, value) values
  ('staff_short_names', jsonb_build_object('masteromprakashsahu@gmail.com','Om'))
on conflict (key) do nothing;

-- ── the short name, decided in one place ────────────────────────────────────
create or replace function public.staff_short_name(p_title text, p_email text)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_map jsonb := coalesce((select value from app_settings where key='staff_short_names'),'{}'::jsonb);
  v_max int := coalesce((select (value->>'short_name_max')::int from app_settings where key='scope_chip_cfg'), 12);
  v_email text := lower(btrim(coalesce(p_email,'')));
  v_title text := btrim(coalesce(p_title,''));
  v_out text;
begin
  v_out := nullif(coalesce(v_map->>v_email,''),'');
  if v_out is not null then return v_out; end if;

  -- A title that is really an email is not a name: fall through to the local
  -- part rather than printing the whole address in the header.
  if v_title <> '' and position('@' in v_title) = 0 then
    v_out := split_part(v_title,' ',1);
  elsif v_email <> '' then
    v_out := split_part(v_email,'@',1);
  elsif v_title <> '' then
    v_out := split_part(v_title,'@',1);
  end if;

  v_out := nullif(btrim(coalesce(v_out,'')),'');
  if v_out is null then
    return coalesce(nullif(public._c('session.header_short_fallback'),''),'Account');
  end if;
  if v_max > 1 and length(v_out) > v_max then
    v_out := left(v_out, v_max - 1) || '…';
  end if;
  return v_out;
end $$;

grant execute on function public.staff_short_name(text, text) to authenticated, anon;

-- ── my_session() gains header_short / header_email ──────────────────────────
-- Added as an overlay so my_session_core() (large, shared) is untouched.
create or replace function public._session_header_short(v jsonb)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    when coalesce(v->>'signed_in','false')::boolean then
      v || jsonb_build_object(
        'header_short', public.staff_short_name(v->>'header_title', v->>'login_email'),
        'header_email', coalesce(v->>'login_email',''))
    else v end
$$;

create or replace function public.my_session()
returns jsonb
language sql
security definer
set search_path to 'public'
as $$
  select public._session_header_short(
           public._session_partner_overlay(public.my_session_core()));
$$;

-- ── the chip itself ─────────────────────────────────────────────────────────
create or replace function public.admin_scope_chip()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_cfg   jsonb := coalesce((select value from app_settings where key='scope_chip_cfg'),'{}'::jsonb);
  v_zcopy jsonb := coalesce((select value from app_settings where key='zone_picker_copy'),'{}'::jsonb);
  v_fmt   text  := coalesce(nullif(v_cfg->>'date_format',''),'FMDD Mon');
  v_sep   text  := coalesce(nullif(public._c('scope_chip.separator'),''),' · ');
  v_role  text  := coalesce(public.get_my_role(),'');
  v_partner boolean := public.is_partner();
  v_zone  smallint;
  v_date  date;
  v_today date;
  v_zone_label text;
  v_zone_code  text;
  v_date_label text;
begin
  -- Staff only. Everyone else gets show:false and the header renders nothing.
  if not (v_partner or v_role in ('admin','super_admin')) then
    return jsonb_build_object('show', false);
  end if;

  v_zone  := public.admin_active_zone();
  v_date  := public.admin_active_date();
  v_today := (now() at time zone 'Asia/Kolkata')::date;
  v_date_label := to_char(v_date, v_fmt);

  if v_zone is null then
    v_zone_label := coalesce(nullif(v_zcopy->>'all_label',''),
                             nullif(public._c('scope_chip.all_label'),''), 'All zones');
    v_zone_code  := coalesce(nullif(public._c('scope_chip.all_code'),''),'ALL');
  else
    select z.name, upper(coalesce(z.code,''))
      into v_zone_label, v_zone_code
      from zones z where z.id = v_zone;
    v_zone_label := coalesce(nullif(v_zone_label,''), '');
    v_zone_code  := coalesce(nullif(v_zone_code,''), upper(left(v_zone_label,3)));
  end if;

  return jsonb_build_object(
    'show', true,
    -- The whole chip, already assembled: "12 Sep · Raipur".
    'label', case when v_zone_label = '' then v_date_label
                  else v_date_label || v_sep || v_zone_label end,
    'date_label', v_date_label,
    'zone_label', v_zone_label,
    'zone_code',  v_zone_code,
    -- Web below ~900px: the calendar icon plus this, and nothing else.
    'compact_label', v_zone_code,
    'is_today', (v_date = v_today),
    'tooltip', public._c('scope_chip.tooltip'),
    'sheet', jsonb_build_object(
      'title',      public._c('scope_chip.sheet_title'),
      'date_title', public._c('scope_chip.date_title'),
      'zone_title', public._c('scope_chip.zone_title'),
      'done_label', public._c('scope_chip.done')),
    -- The sheet's two controls, each the payload their existing widget already
    -- renders, so nothing about the pickers themselves changes.
    'date', case when v_role in ('admin','super_admin')
                 then public.admin_date_scope_state_impl()
                 else jsonb_build_object('date', v_date, 'today', v_today, 'calendar','[]'::jsonb) end,
    'zone', public.zone_picker());
end $$;

grant execute on function public.admin_scope_chip() to authenticated;

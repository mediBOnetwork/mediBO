-- CHANGE #397 — part 3: exports.
--
-- Nothing downloaded for the CA. This adds a GENERIC export service: a report
-- is a row in `export_report` (a SELECT, its column order and its filter spec),
-- so a new downloadable list is an INSERT, never a deploy. The file is built
-- BACKEND-SIDE — Dart receives bytes and a filename and saves them, it never
-- formats a cell.
--
-- Formats: CSV, and Excel as SpreadsheetML 2003 (.xls) — a real spreadsheet
-- Excel and LibreOffice open natively, with a header row and typed number
-- cells. A true .xlsx is a ZIP container, which plpgsql cannot write.
--
-- Large exports do not block the caller: over `admin.export_sync_max_rows` the
-- run becomes a queued job that the cron dispatcher finishes, and the screen
-- shows it as Ready with its own download.

create table if not exists public.export_report (
  key         text primary key,
  label       text not null,
  hint        text not null default '',
  feature_key text not null,
  source_sql  text not null,                       -- SELECT; $1 = the filters jsonb
  columns     jsonb not null default '[]'::jsonb,  -- [{key,label,kind}] in render order
  filters     jsonb not null default '[]'::jsonb,  -- [{key,label,kind,options,default}]
  formats     jsonb not null default '["csv","excel"]'::jsonb,
  sort_order  int not null default 100,
  is_active   boolean not null default true
);

create table if not exists public.export_job (
  id            bigserial primary key,
  at            timestamptz not null default now(),
  actor_user_id uuid,
  actor_email   text,
  report_key    text not null,
  format        text not null default 'csv',
  filters       jsonb not null default '{}'::jsonb,
  status        text not null default 'queued',   -- queued | running | ready | failed
  row_count     int,
  filename      text,
  mime          text,
  content       text,
  error         text,
  finished_at   timestamptz
);
create index if not exists export_job_at_idx on public.export_job(at desc);
create index if not exists export_job_status_idx on public.export_job(status) where status in ('queued','running');

alter table public.export_report enable row level security;
alter table public.export_job    enable row level security;
-- No policies: reads and writes go through the SECURITY DEFINER RPCs below.

insert into public.app_settings(key, value) values
  ('admin.export_sync_max_rows', to_jsonb(2000)),
  ('admin.export_max_rows',      to_jsonb(100000)),
  ('admin.export_keep_days',     to_jsonb(7))
on conflict (key) do nothing;

-- ── file builders ───────────────────────────────────────────────────────────
create or replace function public._csv_cell(p text)
returns text language sql immutable as $$
  select case
    when p is null then ''
    when p ~ '[",\n\r]' then '"' || replace(p, '"', '""') || '"'
    else p end;
$$;

create or replace function public._export_csv(p_cols jsonb, p_rows jsonb)
returns text language sql stable set search_path to 'public' as $$
  select
    (select string_agg(public._csv_cell(c->>'label'), ',' order by c.ord)
       from jsonb_array_elements(p_cols) with ordinality c(c, ord))
    || E'\n'
    || coalesce((select string_agg(line, E'\n' order by r.ord) from
        jsonb_array_elements(p_rows) with ordinality r(r, ord),
        lateral (select string_agg(public._csv_cell(r.r ->> (c->>'key')), ',' order by c.ord)
                   from jsonb_array_elements(p_cols) with ordinality c(c, ord)) l(line)), '')
    || E'\n';
$$;

-- SpreadsheetML 2003: one worksheet, a bold header row, numbers as Number
-- cells so a CA can total a column without re-typing it.
create or replace function public._xml_cell(p text)
returns text language sql immutable as $$
  select replace(replace(replace(replace(coalesce(p,''),
    '&','&amp;'), '<','&lt;'), '>','&gt;'), '"','&quot;');
$$;

create or replace function public._export_xml(p_cols jsonb, p_rows jsonb, p_title text)
returns text language sql stable set search_path to 'public' as $$
  select
'<?xml version="1.0"?>' || E'\n' ||
'<?mso-application progid="Excel.Sheet"?>' || E'\n' ||
'<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">' || E'\n' ||
' <Styles><Style ss:ID="h"><Font ss:Bold="1"/></Style></Styles>' || E'\n' ||
' <Worksheet ss:Name="' || left(public._xml_cell(p_title), 31) || '"><Table>' || E'\n' ||
'  <Row>' ||
   coalesce((select string_agg('<Cell ss:StyleID="h"><Data ss:Type="String">' ||
                               public._xml_cell(c->>'label') || '</Data></Cell>', '' order by c.ord)
      from jsonb_array_elements(p_cols) with ordinality c(c, ord)), '') ||
  '</Row>' || E'\n' ||
   coalesce((select string_agg('  <Row>' || cells || '</Row>', E'\n' order by r.ord)
      from jsonb_array_elements(p_rows) with ordinality r(r, ord),
      lateral (select string_agg(
          case when coalesce(r.r ->> (c->>'key'), '') ~ '^-?[0-9]+(\.[0-9]+)?$'
               then '<Cell><Data ss:Type="Number">' || (r.r ->> (c->>'key')) || '</Data></Cell>'
               else '<Cell><Data ss:Type="String">' ||
                    public._xml_cell(r.r ->> (c->>'key')) || '</Data></Cell>' end,
          '' order by c.ord)
        from jsonb_array_elements(p_cols) with ordinality c(c, ord)) x(cells)), '') || E'\n' ||
' </Table></Worksheet>' || E'\n' || '</Workbook>' || E'\n';
$$;

create or replace function public._export_format(p_format text)
returns jsonb language sql immutable as $$
  select case lower(coalesce(p_format,'csv'))
    when 'excel' then jsonb_build_object('key','excel','ext','xls','label','Excel',
                                         'mime','application/vnd.ms-excel')
    else              jsonb_build_object('key','csv','ext','csv','label','CSV',
                                         'mime','text/csv') end;
$$;

-- Runs one report and returns {row_count, filename, mime, content}. The single
-- place a report's SQL is executed — both the sync path and the worker use it.
create or replace function public._export_build(p_report text, p_format text, p_filters jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  r        public.export_report;
  v_fmt    jsonb := public._export_format(p_format);
  v_rows   jsonb;
  v_max    int := public._bulk_setting('admin.export_max_rows', 100000);
  v_body   text;
  v_name   text;
begin
  select * into r from public.export_report where key = p_report and is_active;
  if r.key is null then raise exception 'unknown_report:%', p_report; end if;

  execute format('select coalesce(jsonb_agg(to_jsonb(q)), ''[]''::jsonb) from (%s) q limit 1',
                 format('select * from (%s) s limit %s', r.source_sql, v_max))
    into v_rows using coalesce(p_filters, '{}'::jsonb);

  v_name := r.key || '_' ||
            to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM-DD_HH24MI') ||
            '.' || (v_fmt->>'ext');

  if v_fmt->>'key' = 'excel' then
    v_body := public._export_xml(r.columns, v_rows, r.label);
  else
    v_body := public._export_csv(r.columns, v_rows);
  end if;

  return jsonb_build_object(
    'row_count', jsonb_array_length(v_rows),
    'filename',  v_name,
    'mime',      v_fmt->>'mime',
    'content',   v_body);
end $$;

-- How many rows a report would return, so the caller knows whether to stream it
-- back now or hand it to the worker.
create or replace function public._export_count(p_report text, p_filters jsonb)
returns bigint language plpgsql stable security definer set search_path to 'public' as $$
declare r public.export_report; v_n bigint;
begin
  select * into r from public.export_report where key = p_report and is_active;
  if r.key is null then raise exception 'unknown_report:%', p_report; end if;
  execute format('select count(*) from (%s) s', r.source_sql)
    into v_n using coalesce(p_filters, '{}'::jsonb);
  return v_n;
end $$;

-- ── the screen payload ──────────────────────────────────────────────────────
create or replace function public.admin_export_screen(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_reports jsonb; v_jobs jsonb;
begin
  if not public.admin_can('admin.exports','read') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', 'You do not have access to exports. Ask a super admin to grant you the Exports permission.');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', x.key, 'label', x.label, 'hint', x.hint,
           'filters', x.filters,
           'formats', (select coalesce(jsonb_agg(public._export_format(fmt #>> '{}')), '[]'::jsonb)
                         from jsonb_array_elements(x.formats) fmt))
           order by x.sort_order, x.label), '[]'::jsonb)
    into v_reports
    from public.export_report x
   where x.is_active and public.admin_can(x.feature_key, 'read');

  select coalesce(jsonb_agg(s.x order by s.sid desc), '[]'::jsonb) into v_jobs from (
    select j.id as sid, jsonb_build_object(
      'id',          j.id,
      'title',       coalesce(rp.label, j.report_key),
      'when_label',  public._audit_when(j.at),
      'format_label',(public._export_format(j.format) ->> 'label'),
      'status',      j.status,
      'tone',        case j.status when 'ready' then 'success'
                                   when 'failed' then 'danger' else 'info' end,
      'state_label', case j.status
                       when 'queued'  then 'Preparing…'
                       when 'running' then 'Building the file…'
                       when 'ready'   then 'Ready · ' || coalesce(j.row_count,0)::text || ' rows'
                       else 'Failed' end,
      'can_download', j.status = 'ready',
      'download_label', 'Download',
      'filename',    coalesce(j.filename,''),
      'error',       coalesce(j.error,'')) as x
      from public.export_job j
      left join public.export_report rp on rp.key = j.report_key
     order by j.id desc limit 20) s;

  return jsonb_build_object(
    'ok', true,
    'title',        'Exports',
    'subtitle',     'Download any list with the filters you have applied. Big ones are prepared in the background.',
    'can_write',    public.admin_can('admin.exports','write'),
    'reports',      v_reports,
    'jobs',         v_jobs,
    'jobs_title',   'Recent exports',
    'jobs_empty',   'Nothing exported yet.',
    'download_label','Download',
    'preparing_label','Preparing…',
    'empty_title',  'No reports available',
    'empty_hint',   'You do not have read access to any report yet.',
    'filter_all_label', 'All');
end $$;

-- ── run one ─────────────────────────────────────────────────────────────────
-- Small: the file comes straight back. Large: a job is queued and the caller is
-- told so — no request ever sits there building a 90,000-row workbook.
create or replace function public.admin_export_run(
  p_report text, p_format text default 'csv', p_filters jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  r      public.export_report;
  v_sync int := public._bulk_setting('admin.export_sync_max_rows', 2000);
  v_n    bigint;
  v_out  jsonb;
  v_job  bigint;
begin
  select * into r from public.export_report where key = p_report and is_active;
  if r.key is null then
    return jsonb_build_object('ok', false, 'message', 'That report does not exist.');
  end if;
  if not public.admin_can('admin.exports','read') or not public.admin_can(r.feature_key,'read') then
    return jsonb_build_object('ok', false,
      'message', 'You do not have access to ' || r.label || '.');
  end if;

  begin
    v_n := public._export_count(r.key, p_filters);
  exception when others then
    return jsonb_build_object('ok', false,
      'message', 'That report could not be built: ' || sqlerrm);
  end;

  if v_n = 0 then
    return jsonb_build_object('ok', false,
      'message', 'Nothing to export — no rows match those filters.');
  end if;

  if v_n <= v_sync then
    v_out := public._export_build(r.key, p_format, p_filters);
    insert into public.export_job(actor_user_id, actor_email, report_key, format, filters,
                                  status, row_count, filename, mime, finished_at)
    values ((public.audit_actor()->>'user_id')::uuid, public.audit_actor()->>'email',
            r.key, lower(coalesce(p_format,'csv')), coalesce(p_filters,'{}'::jsonb),
            'ready', (v_out->>'row_count')::int, v_out->>'filename', v_out->>'mime', now())
    returning id into v_job;

    perform public.audit_write_ex('export.' || r.key, 'export', v_job::text, null,
      jsonb_build_object('report', r.key, 'format', p_format, 'filters', p_filters,
                         'row_count', v_out->>'row_count'), null, null);

    return jsonb_build_object('ok', true, 'ready', true, 'job_id', v_job)
           || v_out
           || jsonb_build_object('message',
                (v_out->>'row_count') || ' rows exported.');
  end if;

  insert into public.export_job(actor_user_id, actor_email, report_key, format, filters, status)
  values ((public.audit_actor()->>'user_id')::uuid, public.audit_actor()->>'email',
          r.key, lower(coalesce(p_format,'csv')), coalesce(p_filters,'{}'::jsonb), 'queued')
  returning id into v_job;

  return jsonb_build_object('ok', true, 'ready', false, 'job_id', v_job,
    'message', v_n::text || ' rows is too big to build while you wait — it is being prepared now. '
               || 'It appears under Recent exports as soon as it is ready.');
end $$;

-- ── fetch a finished job ────────────────────────────────────────────────────
create or replace function public.admin_export_job(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare j public.export_job; r public.export_report;
begin
  select * into j from public.export_job where id = p_id;
  if j.id is null then
    return jsonb_build_object('ok', false, 'message', 'That export no longer exists.');
  end if;
  select * into r from public.export_report where key = j.report_key;
  if not public.admin_can('admin.exports','read')
     or not public.admin_can(coalesce(r.feature_key,'admin.exports'),'read') then
    return jsonb_build_object('ok', false, 'message', 'You do not have access to that export.');
  end if;

  return jsonb_build_object(
    'ok', true, 'id', j.id, 'status', j.status,
    'ready', j.status = 'ready',
    'row_count', coalesce(j.row_count, 0),
    'filename', coalesce(j.filename,''),
    'mime',     coalesce(j.mime,'text/csv'),
    'content',  case when j.status = 'ready' then coalesce(j.content,'') else '' end,
    'message',  case j.status
                  when 'ready'  then coalesce(j.row_count,0)::text || ' rows ready.'
                  when 'failed' then coalesce(nullif(j.error,''), 'That export failed.')
                  else 'Still preparing — check back in a moment.' end);
end $$;

-- ── the worker ──────────────────────────────────────────────────────────────
-- Rides the one cron dispatcher (never its own bare */N schedule).
create or replace function public.export_worker_tick()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare j public.export_job; v_out jsonb; v_done int := 0; v_keep int;
begin
  for j in select * from public.export_job
            where status = 'queued' order by id limit 3 loop
    update public.export_job set status = 'running' where id = j.id and status = 'queued';
    if not found then continue; end if;
    begin
      v_out := public._export_build(j.report_key, j.format, j.filters);
      update public.export_job
         set status = 'ready', row_count = (v_out->>'row_count')::int,
             filename = v_out->>'filename', mime = v_out->>'mime',
             content = v_out->>'content', finished_at = now(), error = null
       where id = j.id;
      v_done := v_done + 1;
    exception when others then
      update public.export_job
         set status = 'failed', error = sqlerrm, finished_at = now()
       where id = j.id;
    end;
  end loop;

  -- A finished file is a copy of data that already lives elsewhere; it does not
  -- get to sit in the database forever.
  v_keep := public._bulk_setting('admin.export_keep_days', 7);
  update public.export_job set content = null
   where content is not null and finished_at < now() - make_interval(days => v_keep);

  return jsonb_build_object('ok', true, 'built', v_done);
end $$;

-- The ONE dispatcher runs this; it is gated so a quiet queue costs nothing.
insert into public.cron_task(name, ord, mode, gate_sql, work_sql,
                             base_interval_s, max_interval_s, enabled, dml, note)
values ('export_worker', 60, 'poll',
        'select exists (select 1 from public.export_job where status = ''queued'')',
        'select public.export_worker_tick()',
        60, 900, true, true,
        'Builds queued admin exports (CHANGE #397).')
on conflict (name) do update
   set gate_sql = excluded.gate_sql, work_sql = excluded.work_sql,
       mode = excluded.mode, enabled = true, note = excluded.note;

grant execute on function public.admin_export_screen(jsonb) to authenticated;
grant execute on function public.admin_export_run(text, text, jsonb) to authenticated;
grant execute on function public.admin_export_job(bigint) to authenticated;

-- CHANGE #573 (Om's scope change) — TEST MODE IS INCOGNITO FOR THE WHOLE PLATFORM.
--
-- Part 1 of #573 built the synthetic LANE: a flag, inheritance, suppression at
-- the edges, books exclusion, sim hooks and an admin screen. It answered
-- "the heartbeat needs a safe order". It did NOT answer Om's real need.
--
-- Om walks the real order flow by hand, again and again, from his own admin /
-- customer / supplier / partner logins, and then wants every trace gone. He
-- must never pick a special account and never remember to tick anything. So
-- test mode becomes a SESSION: he taps it on, and from that moment every row
-- created anywhere on the platform is stamped to the CURRENT SESSION and is
-- purgeable as one unit.
--
-- Everything here is idempotent — a resumed worker may re-apply it whole.

------------------------------------------------------------------ the session
create table if not exists public.test_sessions (
  id               bigserial primary key,
  label            text not null,
  scope            text not null default 'global',
  status           text not null default 'live',   -- live | ended | purged
  started_by       uuid,
  started_by_label text,
  started_at       timestamptz not null default now(),
  ended_at         timestamptz,
  expires_at       timestamptz not null default now() + interval '12 hours',
  auto_expired     boolean not null default false,
  purge_started_at timestamptz,
  purged_at        timestamptz,
  purge_state      jsonb not null default '{}'::jsonb,
  before_fp        jsonb,
  after_fp         jsonb,
  proof            jsonb,
  note             text
);

comment on table public.test_sessions is
  'CHANGE #573 — one manual incognito run. Every row created platform-wide '
  'while a session is live carries its id, so the whole run is one purgeable '
  'unit. scope=global is Om walking the flow from any login without thinking '
  'about it; scope=actors restricts stamping to test_session_actor.';

-- Exactly one live session at a time — the banner and the stamp must never be
-- ambiguous about which run a row belongs to.
create unique index if not exists test_sessions_one_live
  on public.test_sessions ((true)) where status = 'live';
create index if not exists test_sessions_started_idx
  on public.test_sessions (started_at desc);

create table if not exists public.test_session_actor (
  session_id bigint not null references public.test_sessions(id) on delete cascade,
  user_id    uuid   not null,
  label      text,
  primary key (session_id, user_id)
);

-- A real user id that must keep writing LIVE rows even while a global session
-- is on. The escape hatch, deliberately empty by default.
create table if not exists public.test_session_exempt (
  user_id uuid primary key,
  reason  text,
  added_at timestamptz not null default now()
);

------------------------------------------------------------------ more tables get the flag
-- Om named these explicitly: POS sales, khata entries, voice clips, pharmacy
-- bills. They were outside part 1's list and would have survived a purge.
do $$
declare t text;
  tables text[] := array[
    'pos_sales','pos_sale_lines','pharmacy_purchase_bill',
    'khata_account','khata_entry','khata_statement','khata_reminder_log',
    'voice_clip_log','voice_clip_mentions','voice_live_clip','pack_clip_mentions',
    'bags','whatsapp_messages','incentive_earnings'
  ];
begin
  foreach t in array tables loop
    if exists (select 1 from information_schema.tables
                where table_schema='public' and table_name=t and table_type='BASE TABLE') then
      execute format(
        'alter table public.%I add column if not exists is_synthetic boolean not null default false', t);
    end if;
  end loop;
end $$;

------------------------------------------------------------------ the session stamp, everywhere the flag is
-- One nullable bigint next to every is_synthetic column. No FK: the purge
-- deletes the session row last and must never be blocked by a straggler.
do $$
declare t text;
begin
  for t in
    select c.table_name from information_schema.columns c
      join information_schema.tables tb
        on tb.table_schema=c.table_schema and tb.table_name=c.table_name and tb.table_type='BASE TABLE'
     where c.table_schema='public' and c.column_name='is_synthetic'
  loop
    execute format(
      'alter table public.%I add column if not exists test_session_id bigint', t);
  end loop;
end $$;

------------------------------------------------------------------ is a session live right now?
create or replace function public.test_session_live_id()
returns bigint language sql stable security definer set search_path to 'public' as $fn$
  select id from public.test_sessions
   where status = 'live' and ended_at is null and now() < expires_at
   limit 1;
$fn$;

-- The ambient answer the trigger asks on every insert. Transaction-cached so a
-- multi-row statement pays for it once, and it costs nothing at all when no
-- session has ever been started (the partial unique index makes the lookup a
-- single index probe).
create or replace function public._test_session_ambient()
returns bigint language plpgsql volatile security definer set search_path to 'public' as $fn$
declare v_cached text; v_id bigint; v_scope text; v_uid uuid;
begin
  v_cached := coalesce(current_setting('medibo.test_session', true), '');
  if v_cached <> '' then
    return case when v_cached = '-' then null else v_cached::bigint end;
  end if;

  select id, scope into v_id, v_scope
    from public.test_sessions
   where status = 'live' and ended_at is null and now() < expires_at
   limit 1;

  if v_id is not null then
    begin v_uid := auth.uid(); exception when others then v_uid := null; end;
    if v_uid is not null and exists (select 1 from public.test_session_exempt e where e.user_id = v_uid) then
      v_id := null;                       -- the escape hatch wins over the session
    elsif v_scope = 'actors' then
      if v_uid is null or not exists (
           select 1 from public.test_session_actor a
            where a.session_id = v_id and a.user_id = v_uid) then
        v_id := null;
      end if;
    end if;
  end if;

  perform set_config('medibo.test_session', coalesce(v_id::text, '-'), true);
  return v_id;
end $fn$;

------------------------------------------------------------------ the generic trigger learns the session
create or replace function public._synthetic_inherit()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare r record; v_key text; v_hit boolean; v_sess bigint; v_j jsonb; v_parent bigint;
begin
  -- Once synthetic, always synthetic: only the purge removes these rows.
  if tg_op = 'UPDATE' and coalesce(old.is_synthetic,false) then
    new.is_synthetic := true;
    return new;
  end if;

  -- An ambient TEST SESSION stamps everything CREATED while it is live. This
  -- is the whole point of Om's scope change: he never picks an account and
  -- never ticks a box, he just switches the platform to incognito.
  --
  -- INSERT ONLY, and that is a safety rule, not a shortcut. On UPDATE the
  -- ambient stamp would convert a REAL row that merely got touched during the
  -- session into a synthetic one — and the session purge would then delete it.
  -- c573b_proof check 7 (business data byte-identical before vs after) caught
  -- exactly that. A session may create test data; it may never adopt live data.
  v_sess := case when tg_op = 'INSERT' then public._test_session_ambient() else null end;
  if v_sess is not null then
    new.is_synthetic := true;
    v_j := to_jsonb(new);
    if v_j ? 'test_session_id' and v_j->>'test_session_id' is null then
      new := jsonb_populate_record(new, v_j || jsonb_build_object('test_session_id', v_sess));
    end if;
    return new;
  end if;

  if coalesce(new.is_synthetic,false) then return new; end if;

  -- A legacy explicit run context (part 1) still stamps.
  if coalesce(current_setting('medibo.synthetic', true),'') = 'on' then
    new.is_synthetic := true;
    return new;
  end if;

  for r in select * from public.synthetic_inherit_rule
            where child_table = tg_table_name loop
    v_key := to_jsonb(new) ->> r.child_col;
    continue when v_key is null;
    execute format(
      'select p.is_synthetic, p.test_session_id from public.%I p where p.%I = $1::%s limit 1',
      r.parent_table, r.parent_col, r.parent_type)
      into v_hit, v_parent using v_key;
    if coalesce(v_hit,false) then
      new.is_synthetic := true;
      -- A child of a synthetic parent joins the parent's session, so a purge
      -- of that session takes it too.
      if v_parent is not null then
        v_j := to_jsonb(new);
        if v_j ? 'test_session_id' and v_j->>'test_session_id' is null then
          new := jsonb_populate_record(new, v_j || jsonb_build_object('test_session_id', v_parent));
        end if;
      end if;
      return new;
    end if;
  end loop;
  return new;
end $fn$;

------------------------------------------------------------------ attach the trigger to EVERY flagged table
-- Ambient stamping only works where the trigger is. Part 1 attached it to the
-- tables that had an inheritance rule; a session must stamp all of them.
create or replace function public.synthetic_trigger_attach_all()
returns int language plpgsql security definer set search_path to 'public' as $fn$
declare t text; n int := 0;
begin
  for t in
    select c.table_name from information_schema.columns c
     join information_schema.tables tb
       on tb.table_schema=c.table_schema and tb.table_name=c.table_name and tb.table_type='BASE TABLE'
     where c.table_schema='public' and c.column_name='is_synthetic'
  loop
    if not exists (
      select 1 from pg_trigger g join pg_class k on k.oid = g.tgrelid
       where g.tgname = 'a0_synthetic_inherit' and k.relname = t) then
      execute format(
        'create trigger a0_synthetic_inherit before insert or update on public.%I
           for each row execute function public._synthetic_inherit()', t);
      n := n + 1;
    end if;
  end loop;
  return n;
end $fn$;
select public.synthetic_trigger_attach_all();
-- (re-run at the end too: tables flagged later in this file need the trigger)

------------------------------------------------------------------ inheritance rules for the newly flagged tables
do $$
begin
  perform public.synthetic_rule_add('pos_sales','pharmacy_id','pharmacy_profiles','id');
  perform public.synthetic_rule_add('pos_sale_lines','sale_id','pos_sales','id');
  perform public.synthetic_rule_add('pharmacy_purchase_bill','pharmacy_id','pharmacy_profiles','id');
  perform public.synthetic_rule_add('pharmacy_purchase_bill','order_id','orders','id');
  perform public.synthetic_rule_add('khata_account','pharmacy_id','pharmacy_profiles','id');
  perform public.synthetic_rule_add('khata_entry','pharmacy_id','pharmacy_profiles','id');
  perform public.synthetic_rule_add('khata_entry','account_id','khata_account','id');
  perform public.synthetic_rule_add('khata_statement','account_id','khata_account','id');
  perform public.synthetic_rule_add('khata_reminder_log','account_id','khata_account','id');
  perform public.synthetic_rule_add('pack_clip_mentions','order_id','orders','id');
  perform public.synthetic_rule_add('voice_clip_log','supplier_name','supplier_profiles','supplier_name');
  perform public.synthetic_rule_add('voice_clip_mentions','supplier_name','supplier_profiles','supplier_name');
exception when others then
  raise notice 'c573 rule seed: %', sqlerrm;
end $$;

------------------------------------------------------------------ storage: where a synthetic file can hide
-- Om's purge must take the photos, the bill PDFs, the voice clips and the QR
-- images too. Which column points at which bucket is DATA, so a new artifact
-- table is one INSERT and never a new purge branch.
create table if not exists public.test_storage_rule (
  src_table  text not null,
  path_col   text not null,
  bucket     text,
  bucket_col text,
  primary key (src_table, path_col)
);

comment on table public.test_storage_rule is
  'CHANGE #573 — every column that holds a storage path on a table that can be '
  'synthetic. test_session_purge() reads this to delete the objects themselves, '
  'not just the rows that pointed at them.';

insert into public.test_storage_rule (src_table, path_col, bucket, bucket_col) values
  ('deliveries','proof_photo_path','delivery-proofs',null),
  ('deliveries','signature_path','delivery-proofs',null),
  ('delivery_claims','photo_path','delivery-proofs',null),
  ('delivery_partner_registrations','id_doc_path','partner-docs',null),
  ('delivery_partner_registrations','selfie_path','rider-selfies',null),
  ('order_costs','receipt_path','payment-proofs',null),
  ('orders','cust_bill_path','customer-bills',null),
  ('payment_claims','file_path','payment-proofs',null),
  ('pending_bills','file_path','supplier-bills',null),
  ('pending_orders','file_path','order-uploads',null),
  ('supplier_payments','screenshot_path','payment-proofs',null),
  ('pharmacy_count_session','pdf_path',null,'pdf_bucket'),
  ('pos_sales','pdf_path',null,'pdf_bucket'),
  ('pharmacy_purchase_bill','path',null,'bucket'),
  ('khata_statement','path',null,'bucket'),
  ('whatsapp_messages','file_path',null,'media_bucket'),
  ('voice_clip_log','clip_path','voice-clips',null),
  ('voice_clip_mentions','clip_path','voice-clips',null),
  ('voice_live_clip','clip_path','voice-clips',null),
  ('pack_clip_mentions','clip_path','voice-clips',null)
on conflict (src_table, path_col) do update
  set bucket = excluded.bucket, bucket_col = excluded.bucket_col;

------------------------------------------------------------------ the tables a session owns, in delete order
create or replace function public._test_session_tables()
returns text[] language sql immutable set search_path to 'public' as $fn$
  select array[
    'delivery_events','delivery_claims','delivery_payout_lines','deliveries','delivery_runs',
    'bag_allocations','bags','receiving_log','stock_movement',
    'pos_sale_lines','pos_sales','khata_reminder_log','khata_statement','khata_entry','khata_account',
    'pack_clip_mentions','voice_clip_mentions','voice_live_clip','voice_clip_log',
    'bill_lines','pending_bills','pharmacy_purchase_bill',
    'supplier_payments','supplier_disputes',
    'payment_claims','rzp_payment_attempt','razorpay_qr','refunds','order_costs',
    'order_alert','order_fulfilment_snapshot','order_pnl_slab',
    'notification_log','notification_retry_queue','wa_campaign_recipients','whatsapp_messages',
    'loyalty_ledger','pharmacy_stock_move','pharmacy_stock','pharmacy_gst_ledger',
    'pharmacy_count_session','gst_ledger','partner_settlements','incentive_earnings',
    'order_items','inquiry','supplier_orders','orders','pending_orders',
    'supplier_count_sessions','bag_sessions','customer_invoice_series'
  ];
$fn$;

------------------------------------------------------------------ the proof: a fingerprint of the BUSINESS data
-- Om asked for byte-identical business data before vs after. A count alone
-- would miss a swap, so each table also carries an md5 over its ordered
-- primary keys. Synthetic rows are excluded on purpose: the fingerprint is
-- what must NOT change, and the synthetic rows are exactly what does.
create or replace function public.test_fingerprint()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare t text; v_out jsonb := '{}'::jsonb; v_n bigint; v_h text; v_pk text;
begin
  foreach t in array public._test_session_tables() loop
    if not exists (select 1 from information_schema.tables
                    where table_schema='public' and table_name=t and table_type='BASE TABLE') then continue; end if;
    select c.column_name into v_pk from information_schema.columns c
      where c.table_schema='public' and c.table_name=t and c.column_name in ('id','session_key','pharmacy_id')
      order by case c.column_name when 'id' then 1 when 'session_key' then 2 else 3 end limit 1;
    if v_pk is null then continue; end if;
    execute format(
      'select count(*), coalesce(md5(string_agg(%I::text, '','' order by %I::text)),''-'')
         from public.%I where not coalesce(is_synthetic,false)', v_pk, v_pk, t)
      into v_n, v_h;
    v_out := v_out || jsonb_build_object(t, jsonb_build_object('n', v_n, 'h', v_h));
  end loop;
  return v_out;
end $fn$;

------------------------------------------------------------------ what a session is holding right now
create or replace function public.test_session_residue(p_session bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare t text; v_out jsonb := '{}'::jsonb; n bigint; v_total bigint := 0; v_files bigint := 0;
        r record; v_bucket text; v_paths text[];
begin
  foreach t in array public._test_session_tables() loop
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name=t and column_name='test_session_id')
      then continue; end if;
    execute format('select count(*) from public.%I where test_session_id = $1', t)
      into n using p_session;
    if n > 0 then v_out := v_out || jsonb_build_object(t, n); v_total := v_total + n; end if;
  end loop;

  for r in select * from public.test_storage_rule loop
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name=r.src_table and column_name='test_session_id')
      then continue; end if;
    begin
      execute format(
        'select coalesce(array_agg(%I), ''{}'') from public.%I where test_session_id = $1 and %I is not null',
        r.path_col, r.src_table, r.path_col) into v_paths using p_session;
    exception when others then v_paths := '{}'; end;
    v_files := v_files + coalesce(array_length(v_paths,1),0);
  end loop;

  return jsonb_build_object('rows', v_out, 'total', v_total, 'files', v_files);
end $fn$;

------------------------------------------------------------------ the switch grows two knobs
alter table public.test_mode_config add column if not exists session_hours numeric not null default 12;
alter table public.test_mode_config add column if not exists banner_poll_ms int not null default 20000;

------------------------------------------------------------------ runs belong to a session too
alter table public.test_run add column if not exists test_session_id bigint;
alter table public.test_run add column if not exists is_synthetic boolean not null default true;

------------------------------------------------------------------ start / end
create or replace function public.test_session_start(p_label text default null, p_hours numeric default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_id bigint; v_live bigint; v_hours numeric; v_uid uuid; v_label text;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not (select enabled from public.test_mode_config where id=1) then
    return jsonb_build_object('ok',false,'error','test_mode_off',
      'message', public.uic('test_mode.off','Test mode is switched off.'));
  end if;

  v_live := public.test_session_live_id();
  if v_live is not null then
    return jsonb_build_object('ok',true,'already',true,'session_id',v_live,
      'message', public.uic('test_session.already_on','Test mode is already on.'));
  end if;

  -- A session that was left open past its expiry is closed before a new one
  -- starts, so the partial unique index can never refuse a legitimate start.
  update public.test_sessions
     set status='ended', ended_at=coalesce(ended_at, expires_at), auto_expired=true
   where status='live' and (ended_at is not null or now() >= expires_at);

  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  v_hours := coalesce(nullif(p_hours,0),
                      (select session_hours from public.test_mode_config where id=1), 12);
  v_label := coalesce(nullif(btrim(p_label),''),
                      to_char(now() at time zone 'Asia/Kolkata','DD Mon HH24:MI') || ' run');

  insert into public.test_sessions (label, scope, started_by, started_by_label, expires_at, before_fp)
  values (v_label, 'global', v_uid,
          coalesce((select email from auth.users where id = v_uid), 'admin'),
          now() + make_interval(mins => (v_hours*60)::int),
          public.test_fingerprint())
  returning id into v_id;

  return jsonb_build_object('ok',true,'session_id',v_id,
    'message', public.uic('test_session.started','Test mode is ON. Everything you do now is a test.'));
end $fn$;

create or replace function public.test_session_end(p_session bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_id bigint;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  v_id := coalesce(p_session, public.test_session_live_id());
  if v_id is null then
    return jsonb_build_object('ok',true,'already',true,
      'message', public.uic('test_session.already_off','Test mode is already off.'));
  end if;
  update public.test_sessions
     set status = case when status='live' then 'ended' else status end,
         ended_at = coalesce(ended_at, now())
   where id = v_id;
  return jsonb_build_object('ok',true,'session_id',v_id,
    'residue', public.test_session_residue(v_id),
    'message', public.uic('test_session.ended','Test mode is OFF.'));
end $fn$;

------------------------------------------------------------------ the wipe — bounded, resumable, idempotent
create or replace function public.test_session_purge(p_session bigint default null, p_budget_ms int default 20000)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_id bigint; s public.test_sessions%rowtype;
        v_tables text[]; v_i int; v_done boolean := true;
        t text; n bigint; v_deleted jsonb; v_files bigint;
        r record; v_paths text[]; v_bucket text; v_started timestamptz := clock_timestamp();
        v_after jsonb; v_res jsonb; v_clean boolean;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  v_id := coalesce(p_session, public.test_session_live_id());
  if v_id is null then
    return jsonb_build_object('ok',false,'error','no_session',
      'message', public.uic('test_session.no_session','There is no test session to purge.'));
  end if;
  select * into s from public.test_sessions where id = v_id;
  if not found then return jsonb_build_object('ok',false,'error','no_session'); end if;

  -- Ending is implicit: you cannot purge a run you are still inside.
  update public.test_sessions
     set status = case when status='live' then 'ended' else status end,
         ended_at = coalesce(ended_at, now()),
         purge_started_at = coalesce(purge_started_at, now())
   where id = v_id;

  v_tables  := public._test_session_tables();
  v_i       := coalesce((s.purge_state->>'i')::int, 0);
  v_deleted := coalesce(s.purge_state->'deleted', '{}'::jsonb);
  v_files   := coalesce((s.purge_state->>'files')::bigint, 0);

  -- Step 0 — the storage objects, BEFORE the rows that point at them.
  if v_i = 0 then
    for r in select * from public.test_storage_rule loop
      if not exists (select 1 from information_schema.columns
                      where table_schema='public' and table_name=r.src_table and column_name='test_session_id')
        then continue; end if;
      begin
        execute format(
          'select coalesce(array_agg(distinct %I), ''{}'') from public.%I
             where test_session_id = $1 and %I is not null and %I <> ''''',
          r.path_col, r.src_table, r.path_col, r.path_col)
          into v_paths using v_id;
      exception when others then v_paths := '{}'; end;
      if coalesce(array_length(v_paths,1),0) = 0 then continue; end if;

      if r.bucket is not null then
        delete from storage.objects o where o.bucket_id = r.bucket and o.name = any(v_paths);
        get diagnostics n = row_count; v_files := v_files + n;
      else
        for v_bucket in
          execute format('select distinct %I from public.%I where test_session_id = $1 and %I is not null',
                         r.bucket_col, r.src_table, r.bucket_col) using v_id
        loop
          delete from storage.objects o where o.bucket_id = v_bucket and o.name = any(v_paths);
          get diagnostics n = row_count; v_files := v_files + n;
        end loop;
      end if;
    end loop;
    v_i := 1;
  end if;

  -- Steps 1..N — the rows, in dependency order, one table per step so an
  -- interrupted purge resumes at the table it stopped on.
  while v_i <= array_length(v_tables,1) loop
    t := v_tables[v_i];
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name=t and column_name='test_session_id') then
      execute format('delete from public.%I where test_session_id = $1', t) using v_id;
      get diagnostics n = row_count;
      if n > 0 then
        v_deleted := v_deleted || jsonb_build_object(t, coalesce((v_deleted->>t)::bigint,0) + n);
      end if;
    end if;
    v_i := v_i + 1;
    if extract(epoch from (clock_timestamp() - v_started)) * 1000 > p_budget_ms
       and v_i <= array_length(v_tables,1) then
      v_done := false;
      exit;
    end if;
  end loop;

  update public.test_sessions
     set purge_state = jsonb_build_object('i', v_i, 'deleted', v_deleted, 'files', v_files)
   where id = v_id;

  if not v_done then
    return jsonb_build_object('ok',true,'done',false,'session_id',v_id,
      'deleted',v_deleted,'files',v_files,
      'message', public.uic('test_session.purge_more','Still purging — tap again to continue.'));
  end if;

  -- Finished: the run ledger, then the proof.
  delete from public.test_event  where run_id in (select id from public.test_run where test_session_id = v_id);
  delete from public.test_run    where test_session_id = v_id;
  delete from public.synthetic_blocked_write
   where created_at >= s.started_at
     and created_at <= coalesce(s.ended_at, now());

  v_after := public.test_fingerprint();
  v_res   := public.test_session_residue(v_id);
  v_clean := (coalesce((v_res->>'total')::bigint,0) = 0)
             and (coalesce((v_res->>'files')::bigint,0) = 0)
             and (s.before_fp is null or s.before_fp = v_after);

  update public.test_sessions
     set status='purged', purged_at=now(), after_fp=v_after,
         proof = jsonb_build_object(
           'clean', v_clean,
           'rows_deleted', v_deleted,
           'files_deleted', v_files,
           'residue', v_res,
           'business_unchanged', (s.before_fp is not null and s.before_fp = v_after),
           'tables_compared', (select count(*) from jsonb_object_keys(v_after)))
   where id = v_id;

  return jsonb_build_object('ok',true,'done',true,'session_id',v_id,
    'deleted',v_deleted,'files',v_files,'clean',v_clean,'residue',v_res,
    'business_unchanged',(s.before_fp is not null and s.before_fp = v_after),
    'message', case when v_clean
      then public.uic('test_session.purged_clean','Purged. Nothing of that session is left and no business row moved.')
      else public.uic('test_session.purged_dirty','Purged, but something is still left — open the session to see what.') end);
end $fn$;

------------------------------------------------------------------ the words (all of them, in the backend)
insert into public.ui_copy (key, value) values
  ('test_session.title',          to_jsonb('Test sessions'::text)),
  ('test_session.subtitle',       to_jsonb('Switch the whole platform to incognito, walk the flow by hand, then wipe every trace.'::text)),
  ('test_session.banner',         to_jsonb('TEST MODE — nothing here is real'::text)),
  ('test_session.banner_hint',    to_jsonb('Everything you create is being recorded to this test session and can be wiped in one tap.'::text)),
  ('test_session.started',        to_jsonb('Test mode is ON. Everything you do now is a test.'::text)),
  ('test_session.ended',          to_jsonb('Test mode is OFF.'::text)),
  ('test_session.already_on',     to_jsonb('Test mode is already on.'::text)),
  ('test_session.already_off',    to_jsonb('Test mode is already off.'::text)),
  ('test_session.no_session',     to_jsonb('There is no test session to purge.'::text)),
  ('test_session.purge_more',     to_jsonb('Still purging — tap again to continue.'::text)),
  ('test_session.purged_clean',   to_jsonb('Purged. Nothing of that session is left and no business row moved.'::text)),
  ('test_session.purged_dirty',   to_jsonb('Purged, but something is still left — open the session to see what.'::text)),
  ('test_session.start_action',   to_jsonb('Test mode ON'::text)),
  ('test_session.end_action',     to_jsonb('Test mode OFF'::text)),
  ('test_session.purge_action',   to_jsonb('Purge this session'::text)),
  ('test_session.confirm_purge',  to_jsonb('Delete every row, file and message this session created? Real business data is untouched.'::text)),
  ('test_session.confirm_end',    to_jsonb('End the session? You can purge it afterwards.'::text)),
  ('test_session.list_title',     to_jsonb('Sessions'::text)),
  ('test_session.empty',          to_jsonb('No test sessions yet. Tap "Test mode ON" and walk the flow — everything you touch is recorded here.'::text)),
  ('test_session.live',           to_jsonb('LIVE'::text)),
  ('test_session.ended_chip',     to_jsonb('Ended'::text)),
  ('test_session.purged_chip',    to_jsonb('Purged'::text)),
  ('test_session.expired_chip',   to_jsonb('Auto-expired'::text)),
  ('test_session.residue_label',  to_jsonb('Rows still held'::text)),
  ('test_session.files_label',    to_jsonb('Files still held'::text)),
  ('test_session.proof_clean',    to_jsonb('Clean — zero residue, business data identical'::text)),
  ('test_session.proof_dirty',    to_jsonb('Residue left — purge again'::text)),
  ('test_session.expiry_label',   to_jsonb('Auto-ends'::text)),
  ('test_session.started_label',  to_jsonb('Started'::text)),
  ('test_session.label_hint',     to_jsonb('Name this run'::text))
on conflict (key) do update set value = excluded.value;

------------------------------------------------------------------ the banner every screen draws
-- Deliberately callable by anon and authenticated: while a global session is
-- live, a customer, a supplier, a rider and a partner must all SEE that the
-- platform is in test mode. It leaks nothing but that fact and the run label.
create or replace function public.test_session_banner()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare s public.test_sessions%rowtype; c public.test_mode_config%rowtype;
begin
  select * into c from public.test_mode_config where id = 1;
  select * into s from public.test_sessions
   where status='live' and ended_at is null and now() < expires_at limit 1;
  if not found then
    return jsonb_build_object('on', false, 'poll_ms', coalesce(c.banner_poll_ms, 20000));
  end if;
  return jsonb_build_object(
    'on', true,
    'poll_ms', coalesce(c.banner_poll_ms, 20000),
    'session_id', s.id,
    'text',  public.uic('test_session.banner','TEST MODE — nothing here is real'),
    'label', s.label,
    'hint',  public.uic('test_session.banner_hint',''),
    'ends_label', public.uic('test_session.expiry_label','Auto-ends') || ' ' ||
                  to_char(s.expires_at at time zone 'Asia/Kolkata','DD Mon HH24:MI'),
    'badge', public.uic('test_mode.badge','TEST'),
    'tone', 'danger');
end $fn$;

------------------------------------------------------------------ auto-expiry — he WILL forget
create or replace function public.test_session_expire_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare n int;
begin
  update public.test_sessions
     set status='ended', ended_at=coalesce(ended_at, expires_at), auto_expired=true
   where status='live' and now() >= expires_at;
  get diagnostics n = row_count;
  return jsonb_build_object('ok',true,'expired',n);
end $fn$;

insert into public.cron_task (name, ord, mode, work_sql, base_interval_s, max_interval_s, enabled, dml, note)
select 'test_session_expire', 320, 'poll',
       'select public.test_session_expire_sweep()', 900, 3600, true, true,
       'CHANGE #573 - ends a forgotten test session at its expiry so the platform never stays incognito.'
where exists (select 1 from information_schema.tables where table_schema='public' and table_name='cron_task')
  and not exists (select 1 from public.cron_task where name='test_session_expire');

------------------------------------------------------------------ the list the admin screen draws
create or replace function public.test_session_list(p_limit int default 20)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_rows jsonb;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  select coalesce(jsonb_agg(x order by (x->>'id')::bigint desc), '[]'::jsonb) into v_rows from (
    select jsonb_build_object(
      'id', s.id,
      'label', s.label,
      'status', s.status,
      'status_label', case
        when s.status='live'   then public.uic('test_session.live','LIVE')
        when s.status='purged' then public.uic('test_session.purged_chip','Purged')
        when s.auto_expired    then public.uic('test_session.expired_chip','Auto-expired')
        else public.uic('test_session.ended_chip','Ended') end,
      'status_tone', case when s.status='live' then 'danger'
                          when s.status='purged' then 'success' else 'neutral' end,
      'started_label', public.uic('test_session.started_label','Started') || ' ' ||
                       to_char(s.started_at at time zone 'Asia/Kolkata','DD Mon HH24:MI'),
      'by', coalesce(s.started_by_label,''),
      'residue', public.test_session_residue(s.id),
      'proof', coalesce(s.proof, '{}'::jsonb),
      'can_purge', (s.status <> 'purged'),
      'can_end', (s.status = 'live')
    ) as x
    from public.test_sessions s
    order by s.id desc
    limit greatest(1, coalesce(p_limit,20))
  ) q;
  return jsonb_build_object('ok', true,
    'title', public.uic('test_session.list_title','Sessions'),
    'empty', public.uic('test_session.empty',''),
    'rows', v_rows);
end $fn$;

------------------------------------------------------------------ grants
grant execute on function public.test_session_banner() to anon, authenticated;
grant execute on function public.test_session_live_id() to anon, authenticated;
grant execute on function public.test_session_start(text, numeric) to authenticated;
grant execute on function public.test_session_end(bigint) to authenticated;
grant execute on function public.test_session_purge(bigint, int) to authenticated;
grant execute on function public.test_session_list(int) to authenticated;
grant execute on function public.test_session_residue(bigint) to authenticated;
grant execute on function public.test_fingerprint() to authenticated;
grant execute on function public.test_session_expire_sweep() to authenticated, service_role;

------------------------------------------------------------------ the admin screen grows a session block
-- The part-1 screen body is kept verbatim as the base, so this migration adds
-- to it instead of forking a 100-line function that would drift.
do $$
declare src text;
begin
  if to_regprocedure('public._test_mode_screen_base()') is null then
    select pg_get_functiondef(p.oid) into src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname='test_mode_screen' and p.pronargs = 0;
    if src is null then return; end if;
    src := replace(src, 'public.test_mode_screen()', 'public._test_mode_screen_base()');
    execute src;
  end if;
end $$;

create or replace function public.test_mode_screen()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v jsonb; v_live bigint; v_sessions jsonb; v_actions jsonb;
begin
  v := public._test_mode_screen_base();
  if not coalesce((v->>'ok')::boolean, false) then return v; end if;

  v_live     := public.test_session_live_id();
  v_sessions := public.test_session_list(20);

  v_actions := case when v_live is null then
      jsonb_build_array(jsonb_build_object(
        'key','session_start','label', public.uic('test_session.start_action','Test mode ON'),
        'tone','danger','confirm', null))
    else
      jsonb_build_array(
        jsonb_build_object('key','session_end','label', public.uic('test_session.end_action','Test mode OFF'),
                           'tone','brand','confirm', public.uic('test_session.confirm_end','')),
        jsonb_build_object('key','session_purge','label', public.uic('test_session.purge_action','Purge this session'),
                           'tone','danger','confirm', public.uic('test_session.confirm_purge','')))
    end;

  return v
    || jsonb_build_object('sessions', v_sessions || jsonb_build_object(
         'subtitle', public.uic('test_session.subtitle',''),
         'live_id',  v_live,
         'residue_label', public.uic('test_session.residue_label','Rows still held'),
         'files_label',   public.uic('test_session.files_label','Files still held'),
         'proof_clean',   public.uic('test_session.proof_clean',''),
         'proof_dirty',   public.uic('test_session.proof_dirty',''),
         'purge_row_label', public.uic('test_session.purge_action','Purge this session'),
         'confirm_purge',   public.uic('test_session.confirm_purge','')))
    || jsonb_build_object('banner', public.test_session_banner())
    || jsonb_build_object('actions', v_actions || coalesce(v->'actions','[]'::jsonb));
end $fn$;

------------------------------------------------------------------ one door for every button on that screen
-- The screen renders the actions the payload sent and posts the key back. No
-- Dart switch decides what a button does.
create or replace function public.test_mode_action(p_key text, p_arg jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v jsonb;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  case p_key
    when 'session_start' then v := public.test_session_start(nullif(btrim(coalesce(p_arg->>'label','')),''));
    when 'session_end'   then v := public.test_session_end(nullif(p_arg->>'session_id','')::bigint);
    when 'session_purge' then v := public.test_session_purge(nullif(p_arg->>'session_id','')::bigint);
    when 'run_full'      then v := public.test_run_full(nullif(btrim(coalesce(p_arg->>'label','')),''));
    when 'purge'         then v := public.test_purge(false);
    when 'purge_all'     then v := public.test_purge(true);
    else v := jsonb_build_object('ok',false,'error','unknown_action');
  end case;
  return jsonb_build_object('result', v, 'screen', public.test_mode_screen());
end $fn$;

grant execute on function public.test_mode_action(text, jsonb) to authenticated;

------------------------------------------------------------------ the heartbeat uses the SAME machinery
-- Spec item 6: #468 opens a session, runs, purges it. One implementation.
create or replace function public.test_run_session(p_label text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_start jsonb; v_run jsonb; v_purge jsonb; v_sess bigint;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  v_start := public.test_session_start(coalesce(nullif(btrim(p_label),''),'heartbeat'), 1);
  v_sess  := coalesce((v_start->>'session_id')::bigint, public.test_session_live_id());
  v_run   := public.test_run_full(coalesce(nullif(btrim(p_label),''),'heartbeat'), 'heartbeat');
  if v_sess is not null then
    update public.test_run set test_session_id = v_sess
     where test_session_id is null and started_at >= (select started_at from public.test_sessions where id = v_sess);
  end if;
  v_purge := public.test_session_purge(v_sess);
  -- The purge is bounded; the heartbeat keeps calling until the backend says done.
  while coalesce((v_purge->>'ok')::boolean,false) and not coalesce((v_purge->>'done')::boolean,true) loop
    v_purge := public.test_session_purge(v_sess);
  end loop;
  return jsonb_build_object('ok', coalesce((v_run->>'ok')::boolean,false) and coalesce((v_purge->>'clean')::boolean,false),
                            'session_id', v_sess, 'run', v_run, 'purge', v_purge);
end $fn$;

grant execute on function public.test_run_session(text) to authenticated, service_role;

-- CHANGE #573 (session layer) — the proof Om asked for, as one callable RPC:
-- open a session, walk a full order inside it, then purge and show that the
-- business data is byte-identical and nothing of the session is left.
create or replace function public.c573b_proof()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_checks jsonb := '[]'::jsonb; v_ok boolean := true;
        v_sess bigint; v_start jsonb; v_run jsonb; v_purge jsonb;
        v_fp_before jsonb; v_fp_after jsonb;
        n bigint; m bigint; v_res jsonb; v_files bigint;
        v_wa bigint; v_books bigint; v_unstamped bigint; v_fixtures bigint;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;

  perform public.test_fixtures_ensure();
  update public.test_sessions set status='ended', ended_at=coalesce(ended_at,now()) where status='live';

  v_fp_before := public.test_fingerprint();

  -- 1 — the switch opens a session
  v_start := public.test_session_start('c573b proof', 1);
  v_sess  := (v_start->>'session_id')::bigint;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'n',1,'name','session opens and is live',
    'ok', (v_sess is not null and public.test_session_live_id() = v_sess),
    'detail', v_start));
  if v_sess is null then
    return jsonb_build_object('ok',false,'checks',v_checks);
  end if;

  -- 2 — a full order walked inside the session
  v_run := public.test_run_full('c573b proof order','manual');
  update public.test_run set test_session_id = v_sess where test_session_id is null;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'n',2,'name','full order runs inside the session',
    'ok', coalesce((v_run->>'ok')::boolean,false),
    'detail', coalesce(v_run->'stage', to_jsonb(coalesce(v_run->>'order_code','')))));

  -- 3 — EVERY row the run created carries the session id (ambient stamping)
  select count(*) into v_unstamped from public.orders
   where is_synthetic and test_session_id is distinct from v_sess
     and created_at >= (select started_at from public.test_sessions where id = v_sess);
  select count(*) into n from public.orders where test_session_id = v_sess;
  select count(*) into m from public.order_items where test_session_id = v_sess;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'n',3,'name','ambient stamp reaches orders and their children',
    'ok', (n > 0 and m > 0 and v_unstamped = 0),
    'detail', jsonb_build_object('orders',n,'order_items',m,'unstamped',v_unstamped)));

  -- 4 — nothing left the building
  select count(*) into v_wa from public.wa_campaign_recipients
   where test_session_id = v_sess and coalesce(status,'') not in ('skipped','synthetic_suppressed');
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'n',4,'name','zero outbound messages escaped the session',
    'ok', (v_wa = 0), 'detail', jsonb_build_object('escaped', v_wa)));

  -- 5 — nothing reached the books
  select (select count(*) from public.gst_ledger where is_synthetic)
       + (select count(*) from public.partner_settlements where is_synthetic)
       + (select count(*) from public.loyalty_ledger where is_synthetic)
    into v_books;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'n',5,'name','zero synthetic rows in the books',
    'ok', (v_books = 0), 'detail', jsonb_build_object('book_rows', v_books)));

  -- 6 — the purge, run to completion the way the app runs it
  v_purge := public.test_session_purge(v_sess);
  while coalesce((v_purge->>'ok')::boolean,false) and not coalesce((v_purge->>'done')::boolean,true) loop
    v_purge := public.test_session_purge(v_sess);
  end loop;
  v_res := public.test_session_residue(v_sess);
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'n',6,'name','purge leaves zero residue (rows and files)',
    'ok', (coalesce((v_res->>'total')::bigint,1) = 0 and coalesce((v_res->>'files')::bigint,1) = 0),
    'detail', v_res));

  -- 7 — the business data is byte-identical
  v_fp_after := public.test_fingerprint();
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'n',7,'name','business data byte-identical before vs after',
    'ok', (v_fp_before = v_fp_after),
    'detail', jsonb_build_object(
      'tables', (select count(*) from jsonb_object_keys(v_fp_after)),
      'differs', coalesce((select jsonb_agg(k) from jsonb_object_keys(v_fp_after) k
                            where v_fp_before->k is distinct from v_fp_after->k), '[]'::jsonb))));

  -- 8 — the purge is idempotent: running it again changes nothing
  v_purge := public.test_session_purge(v_sess);
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'n',8,'name','purge is idempotent (second run is a no-op)',
    'ok', coalesce((v_purge->>'ok')::boolean,false) and public.test_fingerprint() = v_fp_after,
    'detail', jsonb_build_object('done', v_purge->'done')));

  -- 9 — the permanent cast survives a session purge
  select count(*) into v_fixtures from public.test_fixture;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'n',9,'name','the permanent test cast survives the purge',
    'ok', (v_fixtures >= 4), 'detail', jsonb_build_object('fixtures', v_fixtures)));

  -- 10 — the platform is out of incognito and the banner says so
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'n',10,'name','session closed — banner is off again',
    'ok', (public.test_session_live_id() is null
           and not coalesce((public.test_session_banner()->>'on')::boolean, true)),
    'detail', public.test_session_banner()));

  select bool_and(coalesce((x->>'ok')::boolean,false)) into v_ok
    from jsonb_array_elements(v_checks) x;

  return jsonb_build_object('ok', v_ok, 'session_id', v_sess,
    'passed', (select count(*) from jsonb_array_elements(v_checks) x where (x->>'ok')::boolean),
    'total', jsonb_array_length(v_checks), 'checks', v_checks);
end $fn$;

grant execute on function public.c573b_proof() to authenticated, service_role;

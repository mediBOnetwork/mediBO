-- CMD #2182 — the six dead customer_imported attempts leave the list for good.
--
-- #2180 hid four of them; this deletes the rows outright, which is what the
-- template list should have shown all along. Deleting a row is only safe once
-- it cannot come back: `sync` reads every template Meta holds and INSERTS the
-- ones it has no row for, and this token may not delete a template at Meta
-- ((#100) Need permission on either WhatsApp Business Account or owner/shared
-- business), so all six still exist there and every sync would re-create them
-- visible at the top of the screen.
--
-- wa_template_retired is that answer: a name on this list is not wanted back.
-- The trigger drops any re-insert that carries a meta_id — that is `sync`
-- copying Meta's list in — so a retired template is deleted for good rather
-- than deleted until the next sync. A human starting a fresh draft under the
-- same name un-retires it. Nothing at Meta is touched: those templates stay
-- exactly as they are, unused.
--
-- Idempotent: create-if-absent, insert-on-conflict-nothing, delete-where-exists.

create table if not exists public.wa_template_retired (
  name        text not null,
  language    text not null default 'en',
  reason      text,
  retired_at  timestamptz not null default now(),
  primary key (name, language)
);

alter table public.wa_template_retired enable row level security;

comment on table public.wa_template_retired is
  'CMD #2182 — template names that must never come back. A sync re-insert is dropped by _wa_template_retired_hide; a fresh local draft under the same name un-retires it.';

insert into public.wa_template_retired (name, language, reason) values
  ('customer_imported',    'en', 'CMD #2182 — dead import attempt, superseded by customer_account_notice_v2'),
  ('customer_imported_v2', 'en', 'CMD #2182 — rejected INCORRECT_CATEGORY'),
  ('customer_imported_v3', 'en', 'CMD #2182 — rejected INCORRECT_CATEGORY'),
  ('customer_imported_v4', 'en', 'CMD #2182 — rejected INCORRECT_CATEGORY'),
  ('customer_imported_v5', 'en', 'CMD #2182 — MARKETING, never to be routed to'),
  ('customer_imported_v6', 'en', 'CMD #2182 — MARKETING, never to be routed to'),
  ('zz_cat_probe_2180',    'en', 'CMD #2182 — category probe, its job is done')
on conflict (name, language) do nothing;

create or replace function public._wa_template_retired_hide()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not exists (select 1 from public.wa_template_retired r
                  where r.name = new.name and r.language = coalesce(new.language,'en')) then
    return new;
  end if;

  -- A row arriving WITH a meta_id is `sync` copying Meta's list back in. That
  -- is the resurrection this table exists to stop, so the insert is dropped
  -- silently: retired means deleted, not deleted-until-the-next-sync.
  if new.meta_id is not null then
    return null;
  end if;

  -- A row arriving WITHOUT a meta_id is a human starting a fresh draft under
  -- that name. That un-retires it — refusing an admin's own new template would
  -- be this table deciding something it was never given.
  delete from public.wa_template_retired r
   where r.name = new.name and r.language = coalesce(new.language,'en');
  return new;
end $$;

-- The rows themselves. A retired template may never be the one a route or a
-- campaign points at, so the delete refuses to run while anything is bound to
-- it — that guard is what keeps this migration safe to replay on live.
delete from public.wa_templates t
 using public.wa_template_retired r
 where t.name = r.name
   and coalesce(t.language,'en') = r.language
   and not exists (select 1 from public.wa_event_routes er where er.template_id = t.id)
   and not exists (select 1 from public.wa_campaigns c  where c.template_id  = t.id);

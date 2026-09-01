-- CHANGE #349 — two visible defects from #325, and the same root cause under
-- both: a registry that named an icon nobody had to prove existed, and a
-- toolbar that grew past the right edge of a phone because nothing owned it.
--
-- 1. `ui_icon` is the catalogue of every icon_key the app can actually draw.
--    Until now `icon_key` was free text: the registry could name `handshake`
--    and the app would silently fall back to a neutral glyph, which on a tile
--    reads as an empty pale square. A key that is not in this table is a BUG,
--    and `nav_icon_audit()` + the `nav_icons_resolve` regression-guard
--    behaviour make it a build-blocking one.
-- 2. `surface='dev_tools'` — the Dev Queue's nine appbar icons become registry
--    rows with labels and groups, so they render in ONE scrollable sheet and
--    an unregistered tool cannot render at all.

create table if not exists public.ui_icon (
  icon_key   text primary key,
  label      text not null,
  created_at timestamptz not null default now()
);

comment on table public.ui_icon is
  'CHANGE #349 — every icon_key the Flutter app can resolve to a real glyph. '
  'Mirrors kNavIcons in lib/screens/admin/nav_registry_view.dart; the protected '
  'test nav_icon_resolve_test.dart fails if the two drift apart.';

insert into public.ui_icon (icon_key, label) values
  ('truck','Lorry'), ('alert','Alert bell'), ('task','Task tick'),
  ('qr','QR code'), ('autorenew','Auto renew'), ('people','People'),
  ('inventory','Inventory box'), ('person_add','Add person'),
  ('add_business','Add business'), ('badge','Badge'), ('business','Business'),
  ('link_off','Broken link'), ('person_remove','Remove person'),
  ('medication','Medication'), ('rupee','Rupee'), ('percent','Percent'),
  ('stars','Stars'), ('moped','Moped'), ('route','Route'), ('forum','Forum'),
  ('description','Document'), ('campaign','Campaign'), ('filter','Filter'),
  ('timeline','Timeline'), ('settings_suggest','Settings suggest'),
  ('fact_check','Fact check'), ('notifications','Bell'),
  ('phonelink_ring','Phone ring'), ('payments','Payments'),
  ('receipt','Receipt'), ('account_balance','Bank'),
  ('trending_up','Trending up'), ('handshake','Handshake'),
  ('admin_panel','Admin panel'), ('terminal','Terminal'), ('rule','Rule'),
  ('rule_folder','Rule folder'), ('schedule','Clock'), ('person','Person'),
  ('logout','Logout'), ('book','Book'), ('settings','Settings'),
  ('search','Search'), ('wallet','Wallet'), ('store','Shop front'),
  ('bag','Shopping bag'), ('package','Parcel'),
  -- CHANGE #349 — the Dev Queue tools
  ('bug','Bug'), ('map','Map'), ('key','Key'), ('cloud','Cloud'),
  ('memory','Memory chip'), ('shop','Play store bag'), ('drafts','Drafts'),
  ('build','Spanner'), ('science','Lab flask'), ('history','History'),
  ('dashboard','Dashboard grid'), ('tools','Toolbox'),
  -- CMD #452 — the customer support inbox (feature_gaps #132).
  ('support_agent','Support agent'),
  -- CHANGE #460 — Catalogue health (feature_gaps 161).
  ('image','Picture')
on conflict (icon_key) do update set label = excluded.label;

-- ── the dev_tools surface ───────────────────────────────────────────────────
-- The CHECK is rewritten, not dropped: 'profile' stays pinned to the two
-- identity rows exactly as #325 left it, and 'dev_tools' joins 'dashboard' as
-- a surface any registered feature may sit on.
alter table public.feature_registry
  drop constraint if exists feature_registry_surface_ck;
alter table public.feature_registry
  add constraint feature_registry_surface_ck check (
    surface = any (array['dashboard','profile','both','dev_tools'])
    and (surface <> 'profile'
         or (category = 'identity'
             and feature_key = any (array['identity.view_profile','identity.logout'])))
  );

-- Every icon_key the registry names must be one the app can draw. NOT VALID is
-- deliberate: it guards every future write without failing on a row that
-- predates the catalogue — and `nav_icon_audit()` below reports those instead
-- of hiding them.
alter table public.feature_registry
  drop constraint if exists feature_registry_icon_fk;
alter table public.feature_registry
  add constraint feature_registry_icon_fk
  foreign key (icon_key) references public.ui_icon(icon_key)
  on update cascade not valid;

alter table public.nav_category
  drop constraint if exists nav_category_icon_fk;
alter table public.nav_category
  add constraint nav_category_icon_fk
  foreign key (icon_key) references public.ui_icon(icon_key)
  on update cascade not valid;

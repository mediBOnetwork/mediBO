-- CHANGE #1890 — the open Supplier Shop map is capped at a share of the
-- VIEWPORT, and that share is the backend's number like every other one on
-- this card (#754 already sends map_mini_height / map_full_height).
--
-- Why a patch and not a full CREATE OR REPLACE: map_supplier_groups() is a
-- ~120-line function that several changes have edited since #754. Re-pasting
-- a copy of it here would silently revert whichever of those edits this file
-- happened not to contain. So the definition is read from the live catalogue,
-- the one key is inserted beside the two heights it belongs with, and the
-- result is re-executed. The signature is untouched, so rg_check() sees no
-- surface change.
--
-- The key is added to map_supplier_groups_CORE, which is where the two heights
-- are built; the zone-scoped map_supplier_groups() wrapper returns
-- `core_payload || overrides`, so the new key rides through it untouched and a
-- caller with no zone (which returns the core payload verbatim) gets it too.
--
-- Idempotent twice over: it returns early if the key is already there, and it
-- refuses to re-execute if the anchor it needs was not found.

do $do$
declare
  def text;
  patched text;
begin
  select pg_get_functiondef(p.oid) into def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'map_supplier_groups_core'
  limit 1;

  if def is null then
    raise notice 'c1890: map_supplier_groups_core() not present — nothing to patch';
    return;
  end if;

  if position('map_full_max_ratio' in def) > 0 then
    return;  -- already carries the cap
  end if;

  patched := replace(
    def,
    '''map_mini_height'', 120,',
    '''map_mini_height'', 120, ''map_full_max_ratio'', 0.6,'
  );

  if patched = def then
    raise exception 'c1890: map_supplier_groups_core() no longer carries the map_mini_height anchor — patch by hand';
  end if;

  execute patched;
end
$do$;

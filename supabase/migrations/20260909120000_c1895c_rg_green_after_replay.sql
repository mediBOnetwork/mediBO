-- CMD #1895c — the two guard failures CHANGE #1290's migration replay left on live.
--
-- Neither is this command's code. #1895's deploy merged onto the live base and
-- replayed every migration FILE the base carried, which is how CMD #1913's
-- customer Profile & KYC work reached production — #1913 completed with no
-- deploy of its own. The replay is the mechanism working; these two are what it
-- exposed, and the command that landed them owns them.
--
--  1. anon can EXECUTE admin_customer_tab_profile(uuid). #1913 wrote the
--     grant to authenticated+service_role but not the revoke, and every
--     function inherits Postgres's default GRANT TO PUBLIC — so the anon key
--     that ships inside the web bundle and the APK could read any shop's
--     licence numbers, KYC verdict and uploaded documents by id. That is the
--     real one. Revoked below, the same shape as #25/#353/#395/#422/#436.
--
--  2. admin_customer_page is 'changed_still_unscoped' to the #1094 zone gate.
--     It is NOT unscoped: the zone binds one call deeper, in _cus810_row(),
--     which reads admin_active_zone() and filters `zone_id = v_zone`, so a
--     partner opening a customer outside their zone gets _cus810_deny(false) —
--     #1913's own comment says exactly this, and the body proves it. The gate
--     regexes each function's OWN source and cannot see through a helper, so
--     it grandfathered the function in zone_scope_baseline and re-raised the
--     moment #1913 rewrote the body.
--
--     The fix is to re-baseline THAT ONE FUNCTION against its examined body,
--     not to add a zone_scope_allow row: an allow row would blind the gate to
--     every future edit, while a refreshed md5 keeps the ratchet — the day
--     someone drops the _cus810_row() call, the body changes and this goes red
--     again, which is the whole point of #1094.
--
-- Idempotent: a revoke that has already run is a no-op, and the md5 is
-- recomputed from the live definition rather than pinned to a literal.

-- ── 1. the anon grant ──────────────────────────────────────────────────────
do $$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'admin_customer_tab_profile') then
    revoke execute on function public.admin_customer_tab_profile(uuid) from public, anon;
  end if;
end $$;

-- ── 2. the examined body ───────────────────────────────────────────────────
-- Computed the same way zone_scope_audit() computes it (comments stripped), so
-- the two agree by construction instead of by a hand-copied hash.
do $$
declare v_md5 text; v_sig text;
begin
  select md5(regexp_replace(pg_get_functiondef(p.oid), '--[^' || chr(10) || ']*', '', 'g')),
         p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
    into v_md5, v_sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_customer_page'
   limit 1;

  if v_md5 is null then return; end if;   -- not installed here: nothing to bless

  insert into public.zone_scope_baseline (fn_name, sig, body_md5, note)
  values ('admin_customer_page', v_sig, v_md5,
          'CMD #1895c — examined after #1913 rewrote the body: the zone still binds through _cus810_row() -> admin_active_zone(), which the gate cannot see because it regexes the function''s own source. Re-baselined, NOT allow-listed, so the next body change raises again.')
  on conflict (fn_name) do update
    set sig = excluded.sig, body_md5 = excluded.body_md5, note = excluded.note;
end $$;

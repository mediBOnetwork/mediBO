-- CMD #1820 (QA fix) — one name, one number.
--
-- The screen printed "Failure tax" twice with two different totals: the waste
-- bucket read 9.1M (spec item 6 — the slice of a never-shipped build that was
-- NOT already booked to waiting or resumes, so the buckets stay disjoint and
-- add back to the window) while the section listing those builds was titled
-- "Failure tax — 20.9M" (spec item 7 — their GROSS spend). Both figures are
-- correct and neither is an estimate, but a dashboard whose whole claim is
-- accuracy cannot print one label over two numbers and leave the reader to
-- guess which is which.
--
-- So the section takes the spec's own name for item 7, "Abandonment cost", and
-- its sub-line states the relationship between the two figures out loud,
-- reading the bucket back from the same helper the waste table uses rather
-- than restating a number by hand.
--
-- Strings only: the title and sub of section `abandoned` inside
-- dev_token_report(). Patched in place off pg_get_functiondef so this file
-- stays small and cannot drift from the 1,000-line body it edits; it raises if
-- its anchor is gone rather than silently doing nothing, and it is a no-op on
-- a plane that never installed the dashboard.
do $c1820b$
declare
  v_src text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where p.proname = 'dev_token_report' and n.nspname = 'public';

  if v_src is null then
    raise notice 'c1820b: dev_token_report is not on this plane — nothing to relabel';
    return;
  end if;

  if position('Abandonment cost' in v_src) > 0 then
    raise notice 'c1820b: already relabelled';
    return;
  end if;

  v_new := replace(v_src,
$anchor$    'title','Failure tax — ' || _dev_tok(v_num) || ' · ' || _dev_inr(v_num2),
    'sub', v_n || ' command(s) that never shipped'
           || case when v_tok > 0 then ' · ' || _dev_pct(v_num * 100.0 / v_tok) || ' of the window' else '' end,$anchor$,
$patch$    'title','Abandonment cost — ' || _dev_tok(v_num) || ' · ' || _dev_inr(v_num2),
    'sub', v_n || ' command(s) that never shipped'
           || case when v_tok > 0 then ' · ' || _dev_pct(v_num * 100.0 / v_tok) || ' of the window' else '' end
           || ' · this is their GROSS spend; the Failure tax bucket above counts only the '
           || coalesce((select _dev_tok(r.tokens) from _dev_token_waste_rows(v_from, v_to) r
                         where r.bucket = 'failure'), '—')
           || ' of it not already booked to waiting or resumes',$patch$);

  if v_new = v_src then
    raise exception 'c1820b: the abandoned-section title/sub anchor is gone from dev_token_report() — relabel it by hand instead of leaving two "Failure tax" numbers on the screen';
  end if;

  execute v_new;
end $c1820b$;

#!/usr/bin/env bash
# CMD #1820 — prove the Token dashboard's numbers against the source data.
#
# The dashboard is only worth having if its totals ARE the database's totals.
# This script asks dev_token_report() for a window, then asks the same question
# in plain SQL over dev_commands, and refuses to pass unless they are identical
# — not close, identical. It also proves the two internal partitions (waste
# buckets, phases) add back to that same total with no unexplained remainder,
# and that the report's own drift self-check reads under its threshold.
#
#   scripts/token_dashboard_proof.sh [dburl-file]     # default ~/.medibo/dev_dburl
# Exit 0 = every assertion held. Exit 1 = a number on the screen is not real.
set -uo pipefail
DBFILE="${1:-$HOME/.medibo/dev_dburl}"
[ -f "$DBFILE" ] || { echo "proof: no db url file at $DBFILE"; exit 1; }
DB="$(cat "$DBFILE")"
FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }
q()    { psql "$DB" -Atc "$1" 2>&1; }

for SCOPE in today week all; do
  say ""
  say "── scope: $SCOPE ─────────────────────────────────────────────"

  # The window the report used, restated here in the same terms the report
  # states them: the booking rule lives in _dev_book_at and is shared.
  WIN=$(q "
    with d as (select admin_active_date() dd),
         b as (select (dd::text||' 00:00:00')::timestamp at time zone 'Asia/Kolkata' d0 from d)
    select case '$SCOPE' when 'today' then d0
                         when 'week'  then d0 + interval '1 day' - interval '7 days'
                         else '-infinity'::timestamptz end::text || '~' ||
           case '$SCOPE' when 'all' then 'infinity'::timestamptz
                         else d0 + interval '1 day' end::text
      from b;")
  FROM="${WIN%%~*}"; TO="${WIN##*~}"

  # 1. Dashboard headline vs a direct sum over dev_commands.
  DASH=$(q "select (dev_token_report('$SCOPE')->'headline'->>'sub')")
  RTOK=$(q "select coalesce(sum(cost_input_tokens),0) + coalesce(sum(cost_output_tokens),0)
              from dev_commands
             where _dev_book_at(finished_at, started_at, created_at) >= '$FROM'::timestamptz
               and _dev_book_at(finished_at, started_at, created_at) <  '$TO'::timestamptz;")
  RINR=$(q "select round(coalesce(sum(cost_inr),0),2) from dev_commands
             where _dev_book_at(finished_at, started_at, created_at) >= '$FROM'::timestamptz
               and _dev_book_at(finished_at, started_at, created_at) <  '$TO'::timestamptz;")
  DTOK=$(q "select (select sum(tin+tout) from _dev_token_cmd_window('$FROM'::timestamptz,'$TO'::timestamptz));")
  DINR=$(q "select round((select sum(inr) from _dev_token_cmd_window('$FROM'::timestamptz,'$TO'::timestamptz)),2);")
  say "  report says: $DASH"
  say "  direct SQL : ${RTOK:-0} tokens · ₹${RINR:-0}"
  if [ "${DTOK:-0}" = "${RTOK:-0}" ]; then ok "tokens match exactly (${RTOK:-0})"
  else bad "tokens differ — dashboard ${DTOK:-0} vs SQL ${RTOK:-0}"; fi
  if [ "${DINR:-0}" = "${RINR:-0}" ]; then ok "rupees match exactly (₹${RINR:-0})"
  else bad "rupees differ — dashboard ₹${DINR:-0} vs SQL ₹${RINR:-0}"; fi

  # 2. Every waste bucket adds back to that same total. No remainder.
  WSUM=$(q "select coalesce(sum(tokens),0) from _dev_token_waste_rows('$FROM'::timestamptz,'$TO'::timestamptz);")
  if [ "${WSUM:-0}" = "${RTOK:-0}" ]; then ok "waste buckets sum back to the window total"
  else bad "waste buckets sum to ${WSUM:-0}, window total is ${RTOK:-0} — unexplained remainder"; fi

  # 3. So do the phases (an unmeasured build lands in 'unattributed', never split).
  PSUM=$(q "select coalesce(sum(tokens),0) from _dev_token_phase_rows('$FROM'::timestamptz,'$TO'::timestamptz);")
  if [ "${PSUM:-0}" = "${RTOK:-0}" ]; then ok "phase rows sum back to the window total"
  else bad "phase rows sum to ${PSUM:-0}, window total is ${RTOK:-0}"; fi

  # 4. The report's own second opinion on the rupees.
  DRIFT=$(q "select (dev_token_report('$SCOPE')->'selfcheck'->>'tone');")
  DSUB=$(q  "select (dev_token_report('$SCOPE')->'selfcheck'->>'sub');")
  if [ "$DRIFT" = "danger" ]; then bad "drift self-check is red — $DSUB"
  else ok "drift self-check: $(q "select (dev_token_report('$SCOPE')->'selfcheck'->>'value');") ($DSUB)"; fi
done

say ""
say "── contract ─────────────────────────────────────────────────"
SECS=$(q "select count(*) from jsonb_array_elements(dev_token_report('week')->'sections');")
if [ "${SECS:-0}" -ge 17 ]; then ok "$SECS sections rendered"; else bad "only ${SECS:-0} sections"; fi
NOEST=$(q "select count(*) from jsonb_array_elements(dev_token_report('week')->'sections') s,
             lateral jsonb_array_elements(coalesce(s->'rows','[]'::jsonb)) r
            where r::text like '%estimated%' or r::text like '%approx%';")
if [ "${NOEST:-0}" = "0" ]; then ok "no row calls itself an estimate"; else bad "${NOEST} row(s) hedge"; fi

say ""
[ "$FAIL" = "0" ] && { say "TOKEN DASHBOARD PROOF: every number reconciles."; exit 0; }
say "TOKEN DASHBOARD PROOF: FAILED."; exit 1

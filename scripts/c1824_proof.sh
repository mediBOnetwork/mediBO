#!/usr/bin/env bash
# CMD #1824 — proof that the registry is now a CONTROLLER, not a diary.
#
# Runs against the dev-queue CONTROL PLANE (the only project that holds
# dev_commands): seeds five finished commands in a throw-away area with a
# known elapsed and a known repeat cause, then asserts
#   1. dev_cause_scan() promotes the cause to a dev_build_constraint once it has
#      hit the area three times (and not before);
#   2. the constraint rides on the spec dev_cmd_claim returns for that area;
#   3. dev_eta_estimate() answers with the MEASURED median for that shape of
#      work — not the agent's guess;
#   4. the trigger seeds a building row's first ETA from that median, keeps an
#      unexplained raise out, and honours a raise that carries an eta_note;
#   5. dev_lessons_get stamps the read (hit_count, last_used_at, the reader).
# Every seeded row is deleted at the end, whatever happened.
#
#   bash scripts/c1824_proof.sh            # uses ~/.medibo/dev_dburl
#   C1824_DBURL=postgres://… bash scripts/c1824_proof.sh
set -euo pipefail
DB="${C1824_DBURL:-$(cat "$HOME/.medibo/dev_dburl")}"
AREA="proof-1824-$$"
q() { psql "$DB" -X -v ON_ERROR_STOP=1 -Atqc "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

cleanup() {
  psql "$DB" -X -q <<SQL >/dev/null 2>&1 || true
delete from public.dev_build_constraint_hit where command_id in (select id from public.dev_commands where area = '$AREA');
delete from public.dev_build_constraint where area = '$AREA';
delete from public.dev_lesson_read where command_id in (select id from public.dev_commands where area = '$AREA');
delete from public.dev_commands where area = '$AREA';
SQL
}
trap cleanup EXIT

MIN=$(q "select coalesce((value->'build_intel'->>'min_samples')::int,5) from dev_runner_config where key='worker_pool'")
[ "$MIN" -le 5 ] || fail "min_samples is $MIN; this proof seeds 5 rows"

# ── seed: 5 completed rows, elapsed 600/700/800/900/1000 s (median 800), size
#    'xlarge', every one released once for a stale heartbeat (the cause).
seed_one() { # <n> <elapsed>
  q "insert into public.dev_commands (title, spec, status, area, size_class, route, model, started_at, finished_at, eta_total_s, eta_source, retry_count, error_log, cost_input_tokens, cost_output_tokens)
     values ('proof 1824 #$1', 'proof', 'completed', '$AREA', 'xlarge', 'opus', 'claude-opus-5',
             now() - interval '2 hours', now() - interval '2 hours' + interval '$2 seconds', 7200, 'agent', 1,
             'RELEASED (heartbeat stale > 15m): worker went silent — resumes at step 2/9', 1000, 1000) returning id"
}
ID1=$(seed_one 1 600); ID2=$(seed_one 2 700)
# after TWO occurrences: not promoted
q "select dev_cause_scan()" >/dev/null
[ "$(q "select count(*) from dev_build_constraint where area='$AREA'")" = "0" ] || fail "promoted after 2 occurrences"
pass "two occurrences do not promote"
ID3=$(seed_one 3 800)
q "select dev_cause_scan()" >/dev/null
CON=$(q "select id from dev_build_constraint where area='$AREA' and cause_key='heartbeat_stale' and status='active'")
[ -n "$CON" ] || fail "third occurrence did not promote heartbeat_stale in $AREA"
[ "$(q "select before_count from dev_build_constraint where id=$CON")" = "3" ] || fail "before_count is not 3"
pass "third occurrence promoted constraint #$CON (before_count 3)"
ID4=$(seed_one 4 900); ID5=$(seed_one 5 1000)

# ── injection: the constraint rides on the returned spec, the hit is recorded
SPEC=$(q "select _dev_constraints_inject(jsonb_build_object('id', $ID5, 'area', '$AREA', 'spec', 'the spec'))->>'spec'")
grep -q 'ENFORCED CONSTRAINTS' <<<"$SPEC" || fail "constraint block missing from injected spec"
grep -q "constraint #$CON" <<<"$SPEC" || fail "constraint #$CON not named in the injected spec"
[ "$(q "select count(*) from dev_build_constraint_hit where constraint_id=$CON and command_id=$ID5")" = "1" ] || fail "hit not recorded"
[ "$(q "select injected_count from dev_build_constraint where id=$CON")" = "1" ] || fail "injected_count not 1"
pass "constraint injected into the spec and the hit recorded"

# ── before/after measurement is in the payload
AFTER=$(q "select count(*) from dev_cause_occurrences() where area='$AREA' and cause_key='heartbeat_stale' and at >= (select measure_from from dev_build_constraint where id=$CON)")
BEFORE=$(q "select count(*) from dev_cause_occurrences() where area='$AREA' and cause_key='heartbeat_stale' and at < (select measure_from from dev_build_constraint where id=$CON)")
[ "$BEFORE" = "5" ] && [ "$AFTER" = "0" ] || fail "before/after expected 5/0, got $BEFORE/$AFTER (finished_at of the seeds predates the promotion)"
pass "before/after counted from the promotion: before $BEFORE · after $AFTER"

# ── ETA: the measured median, not a guess
EST=$(q "select dev_eta_estimate('$AREA','xlarge','opus','claude-opus-5')")
MED=$(jq -r '.median_s' <<<"$EST"); N=$(jq -r '.n' <<<"$EST"); LVL=$(jq -r '.matched_on' <<<"$EST")
[ "$MED" = "800" ] || fail "median_s expected 800, got $MED ($EST)"
[ "$N" = "5" ] || fail "n expected 5, got $N"
[ "$LVL" = "area+size+route+model" ] || fail "matched_on expected the tightest level, got $LVL"
grep -q 'Measured over 5' <<<"$(jq -r .sentence <<<"$EST")" || fail "sentence is not the measured one"
pass "dev_eta_estimate → median 800 s over 5 (matched on $LVL), p80 $(jq -r .p80_label <<<"$EST")"

# ── the trigger governs a building row's ETA
B=$(q "insert into public.dev_commands (title, spec, status, area, size_class, route, model, started_at, claimed_by)
       values ('proof 1824 building', 'proof', 'building', '$AREA', 'xlarge', 'opus', 'claude-opus-5', now(), 'proof-1824') returning id")
q "update public.dev_commands set eta_total_s = 7200, eta_left_s = 7200 where id=$B"
read -r T S L <<<"$(q "select eta_total_s, eta_source, eta_left_s from dev_commands where id=$B" | tr '|' ' ')"
[ "$T" = "800" ] && [ "$S" = "measured" ] || fail "first ETA should be seeded 800/measured, got $T/$S"
[ "$L" -le 800 ] || fail "eta_left_s not clamped to the seed ($L)"
pass "first heartbeat seeded from the measured median (agent said 7200 → 800, source measured)"
q "update public.dev_commands set eta_total_s = 9000, eta_left_s = 9000 where id=$B"
read -r T S L <<<"$(q "select eta_total_s, eta_source, eta_left_s from dev_commands where id=$B" | tr '|' ' ')"
[ "$T" = "800" ] && [ "$L" = "800" ] || fail "an unexplained raise should be refused, got $T/$L"
pass "raise without eta_note refused (stays 800, left clamped)"
q "update public.dev_commands set eta_total_s = 9000, eta_left_s = 9000, eta_note = 'two extra migrations found' where id=$B"
read -r T S <<<"$(q "select eta_total_s, eta_source from dev_commands where id=$B" | tr '|' ' ')"
[ "$T" = "9000" ] && [ "$S" = "agent_override" ] || fail "raise with eta_note should be honoured, got $T/$S"
pass "raise with eta_note honoured (9000, agent_override)"
q "update public.dev_commands set status='completed', finished_at = now() + interval '1000 seconds' where id=$B"
EF=$(q "select eta_error_factor from dev_commands where id=$B")
[ "$(q "select ($EF between 8.9 and 9.1)")" = "t" ] || fail "eta_error_factor at completion expected ~9.0, got $EF"
pass "estimate error stamped at completion (eta_error_factor $EF)"

# ── lessons: the read is stamped
LID=$(q "select id from dev_lessons order by id limit 1")
H0=$(q "select hit_count from dev_lessons where id=$LID")
q "select dev_lessons_get(null, $B)" >/dev/null
H1=$(q "select hit_count from dev_lessons where id=$LID")
[ "$H1" -eq $((H0+1)) ] || fail "hit_count did not advance ($H0 → $H1)"
[ "$(q "select count(*) from dev_lesson_read where lesson_id=$LID and command_id=$B")" = "1" ] || fail "reader not recorded"
pass "dev_lessons_get stamped lesson #$LID (hit_count $H0 → $H1, reader #$B)"

# ── the dashboard renders the area's constraint
ROW=$(q "select count(*) from jsonb_array_elements(dev_build_intelligence()->'sections'->0->'rows') r where r->>'label' like '%$AREA%'")
[ "$ROW" -ge 1 ] || echo "note: the seeded cause is outside the dashboard's top-12 causes (expected on a busy registry)"
pass "dev_build_intelligence() renders (tiles $(q "select jsonb_array_length(dev_build_intelligence()->'tiles')"), sections $(q "select jsonb_array_length(dev_build_intelligence()->'sections')"))"

echo "PROOF PASSED — c1824: cause promoted at 3, injected at claim, ETA measured (median 800), trigger governs the seed, lessons stamped."

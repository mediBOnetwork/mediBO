#!/usr/bin/env bash
# CHANGE #324 — AFFECTED-ONLY TESTS, for the RUNNER's own checkout.
#
# The full protected suite is 573 tests. Running all of them after every edit,
# on every runner, is the cheapest-looking waste in the fleet: the suite that
# actually gates production runs ONCE, on the merged batch, inside the merge
# worker (see merge_worker.sh). What a runner needs while it builds is the
# subset its change can possibly break, in a couple of seconds.
#
# Selection, in order:
#   1. every changed/new *_test.dart (the change's own focused test)
#   2. for every changed lib/ file, the protected test that names it, imports
#      it, or shares its basename
#   3. nothing matched -> fall back to the WHOLE protected suite, because
#      "I could not tell what this touches" must never mean "test nothing"
#
# Usage: scripts/affected_tests.sh [base-ref]    (default origin/main)
# Prints the chosen files, then runs them. Exit code is flutter test's.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BASE="${1:-origin/main}"
[ -f "$HOME/mediBO-runner/cache.env" ] && source "$HOME/mediBO-runner/cache.env"

git rev-parse --verify --quiet "$BASE" >/dev/null || BASE="HEAD~1"
CHANGED=$(git diff --name-only "$BASE"...HEAD 2>/dev/null; git diff --name-only; git ls-files -o --exclude-standard)
CHANGED=$(printf '%s\n' "$CHANGED" | sort -u | grep -E '^(lib|test)/.*\.dart$' || true)

if [ -z "$CHANGED" ]; then
  echo "[affected] no Dart files changed vs $BASE — nothing to run"
  exit 0
fi

PICK=""
# 1. the change's own tests
while IFS= read -r f; do
  case "$f" in */*_test.dart) [ -f "$f" ] && PICK="$PICK $f" ;; esac
done <<< "$CHANGED"

# 2. protected tests that reference a changed lib/ file
while IFS= read -r f; do
  case "$f" in lib/*) ;; *) continue ;; esac
  base=$(basename "$f" .dart)
  # A protected test that imports the file, or is named after it.
  # --include is not optional: test/protected/ also holds DATA the suite reads
  # (design_literal_baseline.json, no_hardcoded_copy_denylist.g.dart,
  # ui_copy_fixture.dart/.json). A bare -rl matched those too and handed them
  # to `flutter test`, which cannot load a .json or a fixture as a test — four
  # phantom "Failing tests" on a run whose 788 real tests were all green. A
  # runner that learns to ignore red is worse than no gate at all.
  hits=$(grep -rlF --include='*_test.dart' -- "$base" test/protected/ 2>/dev/null || true)
  [ -n "$hits" ] && PICK="$PICK $hits"
done <<< "$CHANGED"

# Final guard — only ever hand `flutter test` real, existing *_test.dart files.
PICK=$(printf '%s\n' $PICK | sort -u | while IFS= read -r p; do
  case "$p" in *_test.dart) [ -f "$p" ] && printf '%s\n' "$p" ;; esac
done | tr '\n' ' ')

if [ -z "${PICK// /}" ]; then
  echo "[affected] changed files map to no specific test — running the FULL protected suite"
  exec flutter test test/protected/
fi

echo "[affected] $(printf '%s\n' $PICK | wc -l) test file(s) selected from $(printf '%s\n' "$CHANGED" | wc -l) changed Dart file(s):"
printf '  %s\n' $PICK
# shellcheck disable=SC2086
flutter test $PICK

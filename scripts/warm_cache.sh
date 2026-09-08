#!/usr/bin/env bash
# CHANGE #324 — PERSISTENT BUILD CACHE.
#
# `flutter clean` is mandatory before every production build (skipping it
# produces corrupt dart2js bundles — proven 2026-07-03), and clean deletes
# .dart_tool and build/. What it must NOT delete is everything that lives
# OUTSIDE the repo: the pub package cache, the Gradle cache and the Flutter
# web/engine artifacts. Those are what make a build minutes instead of tens of
# minutes, and after a VM restart they are the first thing to go cold.
#
# This script pins them to persistent paths and warms them. It is idempotent,
# safe to run before every build, and never fatal — a cold cache is slow, not
# broken.
#
# Sourced form: `source scripts/warm_cache.sh --env-only` just exports the
# paths (that is what ~/mediBO-runner/cache.env does for the merge worker).
set -uo pipefail

export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
export FLUTTER_ROOT="${FLUTTER_ROOT:-$HOME/flutter}"
# Dart's own incremental/analysis cache — outside the repo, so `flutter clean`
# cannot reach it.
export DART_TOOL_CACHE="${DART_TOOL_CACHE:-$HOME/.cache/dart}"
mkdir -p "$PUB_CACHE" "$GRADLE_USER_HOME" "$DART_TOOL_CACHE" 2>/dev/null || true

case "${1:-}" in --env-only) return 0 2>/dev/null || exit 0 ;; esac

cd "$(dirname "$0")/.." || exit 0

# Web engine artifacts (dart2js, canvaskit). No-op when already present.
timeout 600 flutter precache --web --no-android --no-ios >/dev/null 2>&1 \
  && echo "[warm-cache] flutter web artifacts warm" \
  || echo "[warm-cache] precache skipped (offline or already warm)"

# Resolve packages from the warm pub cache. After a clean this is the one step
# that would otherwise hit the network for every dependency.
timeout 600 flutter pub get >/dev/null 2>&1 \
  && echo "[warm-cache] pub packages resolved from $PUB_CACHE" \
  || echo "[warm-cache] pub get skipped"

echo "[warm-cache] PUB_CACHE=$(du -sh "$PUB_CACHE" 2>/dev/null | cut -f1) GRADLE_USER_HOME=$(du -sh "$GRADLE_USER_HOME" 2>/dev/null | cut -f1)"

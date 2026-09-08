// CMD #1845 — A MIGRATION THAT CANNOT REACH LIVE MUST FAIL THE BUILD THAT WROTE IT.
//
// scripts/migration_replay.sh is the ONE place a migration file reaches
// production. It keys every file in the ledger by its version prefix — the
// characters before the first underscore — and a prefix that is not purely
// numeric cannot be keyed, so the file is skipped. Skipped, the SQL never runs
// on live while the Dart that calls it deploys anyway: the feature ships
// half-built and the screen prints its fallback string.
//
// This has now happened twice. #1821's whole backend was missing from live for
// days behind `20260906T160000_c1821_…`. #1845 shipped CHANGE #1217 with
// `20260906T160000_cmd1845_stage_deadlines.sql` — the ops board button still
// read "SLA settings" because ops_board() on live had never heard of the
// rename, and sla_config had neither `mode` nor `due_time`. Same T, same
// silence, same class of bug.
//
// #1821 made the skip LOUD (a log line and an rg_alert at replay time). Loud is
// not early enough: replay runs inside the merge worker, after the branch is
// merged and while the deploy is already going out, and nobody reads a warn
// alert during a green batch. This gate moves the catch to the one moment it
// costs nothing — the protected suite, before the branch is ever pushed.
//
// The 16 legacy files below (#698, #713, #962) are frozen exactly as they stand
// on main. They are already skipped and already unreachable; renaming them
// would make 16 old migrations pending at once, which migration_replay.sh
// rightly refuses. So the list is an ALLOWLIST, not a target: it may shrink,
// never grow. Adding a name to it is how the next #1821 is written.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The exact rule migration_replay.sh applies:
///
///   b=$(basename "$f" .sql); v="${b%%_*}"
///   if [[ ! "$v" =~ ^[0-9]{8,}$ ]]; then unversioned+=("$b"); continue; fi
bool _replayCanSeeIt(String basename) {
  final version = basename.split('_').first;
  return RegExp(r'^[0-9]{8,}$').hasMatch(version);
}

/// Files that are ALREADY unreachable on main. Frozen; this list may shrink,
/// never grow.
const _frozenUnreachable = <String>{
  '20260903T140000_c698_substitute_ask',
  '20260903T160000_c698_substitute_journey',
  '20260903T170000_c698_substitute_templates',
  '20260903T173000_c962_rg_extension_qualified',
  '20260903T180000_c698_candidate_dedupe',
  '20260903T220000_c713_order_thread_schema',
  '20260903T220100_c713_thread_core',
  '20260903T220200_c713_thread_copy',
  '20260903T220300_c713_thread_sla',
  '20260903T220400_c713_exception_feed',
  '20260903T220500_c713_thread_inbox',
  '20260903T220600_c713_ticket_is_thread',
  '20260903T220700_c713_read_and_calls',
  '20260903T220800_c713_wa_inbound_thread',
  '20260903T220900_c713_doors',
  '20260903T221000_c713_access_defaults',
};

void main() {
  final dir = Directory('supabase/migrations');

  test('every migration file can be keyed by migration_replay.sh', () {
    expect(dir.existsSync(), isTrue,
        reason: 'supabase/migrations must exist — run this from the package root');

    final unreachable = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.sql'))
        .map((n) => n.substring(0, n.length - 4))
        .where((b) => !_replayCanSeeIt(b))
        .toSet();

    final added = unreachable.difference(_frozenUnreachable).toList()..sort();

    expect(
      added,
      isEmpty,
      reason: 'These migration files can NEVER reach live: their version prefix '
          '(everything before the first underscore) is not 8+ digits, so '
          'scripts/migration_replay.sh cannot key them in the ledger and skips '
          'them in silence. The SQL stays on the build branch while the Dart '
          'that calls it deploys — exactly how #1821 and #1845 shipped a '
          'half-built feature. Rename to YYYYMMDDHHMMSS_name.sql (no "T"). '
          'Do NOT add the name to the frozen allowlist.\n  ${added.join('\n  ')}',
    );
  });

  test('the frozen allowlist only ever shrinks', () {
    final present = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.sql'))
        .map((n) => n.substring(0, n.length - 4))
        .toSet();

    // A name may leave the repo (renamed or deleted) — that is the shrink this
    // gate wants. What it must never do is stay in the list while reachable,
    // because a stale entry would silently forgive a future regression that
    // reuses the same name.
    for (final legacy in _frozenUnreachable) {
      if (present.contains(legacy)) {
        expect(_replayCanSeeIt(legacy), isFalse,
            reason: '$legacy is reachable now — drop it from '
                '_frozenUnreachable instead of leaving a stale exemption.');
      }
    }
  });

  test("this command's own migration is one replay can see", () {
    final mine = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.contains('cmd1845_stage_deadlines'))
        .toList();

    expect(mine, hasLength(1),
        reason: 'the stage-deadlines migration must exist exactly once');
    expect(_replayCanSeeIt(mine.single.substring(0, mine.single.length - 4)),
        isTrue,
        reason: 'CHANGE #1217 deployed the Dart for stage deadlines while this '
            'file was named with a T, so live never got mode/due_time or '
            'ops_stage_deadline() and the board button still read "SLA '
            'settings". It must stay numerically versioned.');
  });
}

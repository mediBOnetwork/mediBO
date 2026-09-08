// PROTECTED — CMD #1863.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour, never to make an unrelated change go
// green.
//
// What this holds down — the three controls #1863's audit found with a backend
// and no button, and the rule that put them there:
//
//   1. THEY GO TO THE CONTROL PLANE. #1761 moved the dev-queue backend onto
//      medibo-dev; production carries none of these functions (a single stale
//      `dev_cmd_pause` is all that is left there). A new control wired against
//      `Supabase.instance` answers PGRST202 forever, and the Dev Queue cards
//      swallow their own errors — which is exactly how #1862's three switches
//      vanished in silence. So none of the three may be a production RPC.
//
//   2. THEY ARE WIRED ONCE. The audit's whole point was to add nothing that
//      already had a surface: 27 of the 40 RPCs were already called by name and
//      five more (health / disk / blocked / build_branch / context) ride inside
//      `dev_ctl_get()`. A second caller for any of them is a duplicated card.
//
//   3. THE LABELS ARE THE BACKEND'S. "Stop after #N" is ui_copy's own
//      `dev_queue.v3_drain` template — the SAME row the backend uses to build
//      `strip_v3_card().drain_label` ("Draining: will stop after #N"). If a
//      future edit spells either sentence in Dart the two drift apart, and the
//      button and the card start disagreeing about which command the fleet is
//      stopping after.
//
//   4. `dev_ctl_get()` STAYS THE ONE READ for the five cards it carries. The
//      audit found them WIRED — through the aggregate, not by name. Adding a
//      by-name call for one of them would fetch the same payload twice on a
//      card that already polls.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_service.dart';

/// The three RPCs this change wired. Each existed, worked, and had no caller.
const _wired = <String>[
  'strip_v3_drain_set',
  'build_branch_log',
  'dev_lessons_get',
];

/// Read verbatim from `dev_ctl_get()` and therefore never called by name.
const _viaAggregate = <String>[
  'runner_health_card',
  'runner_disk_state',
  'runner_blocked_badge',
  'build_branch_card',
  'dev_context_metrics',
];

/// Comments are not rendering. The copy sweep in
/// `no_hardcoded_copy_test.dart` strips them for the same reason: a phrase
/// QUOTED in a doc comment (this file's own explanation of what must not be
/// spelled in Dart) is not a string the app can ever print.
String _stripComments(String src) {
  src = src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final out = StringBuffer();
  for (final line in src.split('\n')) {
    final i = line.indexOf('//');
    out.writeln(i >= 0 ? line.substring(0, i) : line);
  }
  return out.toString();
}

String _read(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    throw StateError('run from the package root — $path not found');
  }
  return _stripComments(f.readAsStringSync());
}

void main() {
  final service =
      _read('lib/screens/admin/dev_queue/dev_queue_service.dart');
  final detail = _read('lib/screens/admin/dev_queue/dev_queue_detail.dart');
  final control = _read('lib/screens/admin/dev_queue/dev_queue_control.dart');

  group('CMD #1863 — the newly wired controls talk to the control plane', () {
    // A real client object, never used to make a request: pinning it is what
    // proves the router chose the control-plane side without a network.
    final pinned = SupabaseClient('https://control-plane.example', 'anon-key');

    test('none of them is a production RPC', () {
      for (final fn in _wired) {
        expect(DevQueueService.productionRpcs.contains(fn), isFalse,
            reason: '$fn lives on medibo-dev, not production');
      }
      // The control group: an RPC that really does describe production.
      expect(DevQueueService.productionRpcs.contains('cron_health'), isTrue);
    });

    test('the router hands each of them the control-plane client', () async {
      final svc = DevQueueService(client: pinned);
      for (final fn in _wired) {
        expect(identical(await svc.clientFor(fn), pinned), isTrue,
            reason: '$fn must not go to Supabase.instance');
      }
    });
  });

  group('CMD #1863 — wired exactly once, and nothing is fetched twice', () {
    test('each new RPC has one caller in the service', () {
      for (final fn in _wired) {
        expect("'$fn'".allMatches(service).length, 1,
            reason: '$fn must be called from exactly one place');
      }
    });

    test('the aggregate-fed cards are still never called by name', () {
      for (final fn in _viaAggregate) {
        expect(service.contains("'$fn'"), isFalse,
            reason:
                '$fn arrives inside dev_ctl_get(); a by-name call reads it twice');
      }
    });
  });

  group('CMD #1863 — every label is the backend\'s', () {
    test('the drain button uses the ui_copy template, not a Dart sentence', () {
      expect(detail.contains("cf('dev_queue.v3_drain'"), isTrue,
          reason: 'the button label must come from ui_copy');
      // Neither half of the pair may be spelled here: the card prints the
      // backend's `drain_label` and the button prints the same row's template.
      expect(detail.contains('Stop after'), isFalse);
      expect(detail.contains('Draining'), isFalse);
    });

    test('the drain action sends this row id and prints what came back', () {
      expect(detail.contains('_svc.drainAfter(widget.id)'), isTrue,
          reason: 'no parsing of a display string for the id');
      expect(detail.contains("['drain_label']"), isTrue,
          reason: 'the toast is the payload, never a Dart confirmation');
    });

    test('the lessons card is ui_copy headings over payload rows', () {
      expect(detail.contains("c('dev_queue.gcp_lessons')"), isTrue);
      expect(detail.contains("_svc.lessons("), isTrue);
    });

    test('the branch-log sheet words nothing itself', () {
      expect(control.contains("c('dev_queue.branch_title')"), isTrue);
      expect(control.contains("c('dev_queue.branch_attempts_none')"), isTrue);
      expect(control.contains("cf('dev_queue.branch_ref'"), isTrue);
      expect(control.contains('widget.service.buildBranchLog()'), isTrue);
    });
  });

  group('CMD #1863 — the lessons read is not on a poll', () {
    test('_loadLessons is called from initState only', () {
      // dev_lessons_get() stamps last_used_at and writes a dev_lesson_read row
      // on every call. A screen that re-read it on its 5s refresh would forge
      // the ledger the runner's own lesson stats are built from.
      // The declaration is `Future<void> _loadLessons() async`; a CALL ends in
      // a semicolon. Exactly one of those, and it is the one in initState.
      expect('_loadLessons();'.allMatches(detail).length, 1,
          reason: 'one call site: initState');
    });
  });
}

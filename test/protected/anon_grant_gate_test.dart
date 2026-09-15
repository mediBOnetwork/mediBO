// CHANGE #436 — the anon-grant gate, pinned in the repo.
//
// The bug this file exists to retire: every SECURITY DEFINER function inherits
// Postgres's default `GRANT EXECUTE TO PUBLIC`, and on Supabase EXECUTE is also
// granted directly to `anon` — so a new RPC is a PUBLIC endpoint the day it is
// written. 146 of the 164 public.admin_* / public.pack_* functions were
// reachable with nothing but the anon key that ships in lib/supabase_config.dart,
// and two of them answered with live customer data (pack_nav, and
// pack_count_source_audit, which returned product_id, product_name,
// order_item_id and counted quantity for every line of any order id).
// The same shape had already shipped four times: feature_gaps #25, CHANGE #353,
// CHANGE #395, audit_write() in #422.
//
// The RUNTIME guard is `privileged_rpcs_are_not_anon` inside rg_check(), and a
// red rg_check blocks every dev_cmd_complete on the box. A test on the Dart VM
// cannot reach Postgres, so it cannot re-assert a GRANT — what it CAN do is
// make the guard undeletable: the migration that installs it, the pattern that
// keeps it from degrading into a list of names, and the escape hatch that must
// stay explicit. Delete any of those and this suite turns red, which blocks the
// very deploy that removed the guard.
//
// Deliberately file-based, and deliberately NOT a string-match on live SQL
// output: the live answer belongs to rg_check and scripts/anon_grant_audit.sh.

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

File _repoFile(String relative) {
  // The suite runs from the repo root under `flutter test`.
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    final f = File('${dir.path}/$relative');
    if (f.existsSync()) return f;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('CHANGE #436: $relative is missing — the anon-grant guard was deleted.');
}

void main() {
  group('CHANGE #436 — the anon EXECUTE grant guard cannot be quietly removed', () {
    late String migration;

    setUpAll(() {
      migration = _repoFile(
        'supabase/migrations/20260901_c436_anon_grant_lockdown.sql',
      ).readAsStringSync();
    });

    test('the rg behaviour test is still installed by the migration', () {
      expect(
        migration.contains('privileged_rpcs_are_not_anon'),
        isTrue,
        reason: 'the runtime guard rides rg_check(); without this seed a '
            'reopened door ships silently again (#436)',
      );
      expect(
        migration.contains('rg_behavior_tests'),
        isTrue,
        reason: 'the guard must live in rg_behavior_tests so rg_check runs it, '
            'and a red rg_check blocks every dev_cmd_complete',
      );
      expect(
        migration.contains('enabled = true'),
        isTrue,
        reason: 'a re-run of the migration must re-enable the guard, never '
            'leave a disabled row behind',
      );
    });

    test('the guard is a PATTERN, not a list of the ten names in the report',
        () {
      // A guard written as a list only ever catches the bug it was written for
      // — the lesson audit_write left behind in #422. The rule lives in a table
      // so the next hot surface is one INSERT, not a deploy.
      expect(migration.contains('rpc_anon_rule'), isTrue);
      expect(migration.contains(r"'admin\_%'"), isTrue);
      expect(migration.contains(r"'pack\_%'"), isTrue);
      expect(
        migration.contains('p.proname like r.prefix'),
        isTrue,
        reason: 'the revoke and the guard must both be driven by the rule '
            'table, or they drift apart',
      );
    });

    test('a tokenless caller must be recorded, never assumed', () {
      expect(
        migration.contains('rpc_anon_allow'),
        isTrue,
        reason: 'the escape hatch has to be explicit and reviewable — #353 had '
            'exactly one genuine tokenless RPC (inquiry_rate_capture), and the '
            'way to keep that legible is a row, not a silently skipped name',
      );
    });

    test('the guard refuses to pass vacuously', () {
      expect(
        migration.contains('would have passed without checking anything'),
        isTrue,
        reason: 'if the rule matches no function the guard must fail loudly; a '
            'security check that silently asserts nothing is worse than none',
      );
    });

    test('the revoke re-grants the signed-in role, so it cannot overshoot', () {
      expect(
        migration.contains('grant execute on function %s to authenticated, service_role'),
        isTrue,
        reason: 'revoking PUBLIC without re-granting authenticated locks the '
            'admin and warehouse screens out of their own backend',
      );
      expect(
        migration.contains('authenticated cannot EXECUTE'),
        isTrue,
        reason: 'and the guard has to assert that too, in both directions',
      );
    });

    test('the five pack RPCs keep their body-level guard as the inner lock',
        () {
      for (final fn in const [
        'pack_nav',
        'pack_count_source_audit',
        'pack_item_bags',
        'pack_mention_product_totals',
        'pack_get_queue',
      ]) {
        expect(
          migration.contains(fn),
          isTrue,
          reason: '$fn had no body guard at all — the GRANT is the outer lock, '
              'get_my_role() is the inner one, and #436 happened because these '
              'only ever had the outer',
        );
      }
      expect(
        migration.contains("lost its body-level role guard"),
        isTrue,
        reason: 'the guard must also fail if a later edit drops get_my_role() '
            'from one of them',
      );
    });

    test('the linked journey bug-436 is implemented, not left as a TODO', () {
      expect(migration.contains('_journey_bug436'), isTrue);
      expect(migration.contains("where name = 'bug-436'"), isTrue);
      expect(
        migration.contains('TODO: implement'),
        isFalse,
        reason: 'the auto-created placeholder must be replaced by real steps '
            'and assertions before the fix can complete',
      );
    });

    test('the live tokenless proof script ships with it', () {
      final audit = _repoFile('scripts/anon_grant_audit.sh').readAsStringSync();
      expect(
        audit.contains('42501'),
        isTrue,
        reason: 'a closed door answers 42501 at the GRANT, before a row is '
            'read; a body guard answering not_authorized is the inner lock and '
            'is one edit away from being lost',
      );
      expect(
        audit.contains('pack_count_source_audit'),
        isTrue,
        reason: 'the RPC that actually leaked order lines must stay in the '
            'probe set',
      );
      expect(
        audit.contains('admin_supplier_screen_data'),
        isTrue,
        reason: 'and the admin session has to be proven still working, so the '
            'revoke cannot overshoot unnoticed',
      );
    });
  });
}

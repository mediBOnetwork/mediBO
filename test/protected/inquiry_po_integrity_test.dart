// PROTECTED — CHANGE #240. inquiry → PO date integrity.
//
// THE BUG THIS RETIRES
//   83 of 101 linked inquiry rows pointed at a supplier_orders row from a
//   DIFFERENT date than the line's own batch_date (a 2026-08-17 line pointing
//   at a 2026-07-26 PO). commit_supplier_order() reused the OLDEST still-open
//   PO for the supplier with no order_date filter, so one three-week-old
//   pending PO kept adopting every new day's lines. Every reader treated a
//   bare `supplier_order_id IS NOT NULL` as "already ordered", so those lines
//   vanished from the supplier form and were skipped by the engine on days
//   they had never actually been ordered for. 45 of them were linked to a PO
//   whose items[] did not even list the product.
//
// The backend half is pinned by two rg behaviour tests (`inquiry_po_date_
// integrity`, `inquiry_po_reader_predicate`) which turn rg_check red — and
// rg_check red blocks every dev_cmd_complete. This file holds the halves a
// migration cannot:
//   * the migration itself still carries the guard, the predicate and the
//     deliberate reader split (so deleting them fails the suite locally, not
//     only on the server);
//   * the admin-facing integrity block renders the backend payload verbatim
//     and computes nothing;
//   * the block is ABSENT rather than broken when an older backend omits it.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/admin_scope_audit_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

String _read(String path) {
  final f = File(path);
  if (!f.existsSync()) throw StateError('$path is missing — did it move?');
  return f.readAsStringSync();
}

/// Strips comments so a phrase quoted in a comment cannot satisfy a scan.
String _code(String src) {
  src = src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final out = StringBuffer();
  for (final line in src.split('\n')) {
    final i = line.indexOf('//');
    out.writeln(i >= 0 ? line.substring(0, i) : line);
  }
  return out.toString();
}

const _migration =
    'supabase/migrations/20260818200000_inquiry_po_date_integrity.sql';

/// A payload shaped exactly like admin_scope_audit().integrity. The strings are
/// deliberately NOT the real copy: if the widget ever hardcodes the production
/// wording instead of printing what it was handed, these fail.
Map<String, dynamic> _payload({
  String banner = 'BANNER-FROM-BACKEND',
  String tone = 'success',
}) =>
    {
      'title': 'TITLE-FROM-BACKEND',
      'subtitle': 'SUBTITLE-FROM-BACKEND',
      'banner_tone': tone,
      'banner_label': banner,
      'rows': [
        {
          'label': 'ROW1-LABEL',
          'value': '7',
          'tone': 'danger',
          'detail': 'ROW1-DETAIL',
        },
        {
          'label': 'ROW2-LABEL',
          'value': 'ROW2-VALUE-IS-A-WORD',
          'tone': 'success',
          'detail': 'ROW2-DETAIL',
        },
      ],
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> d) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: ScopeIntegrityBlock(d: d)),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the migration still carries the invariant', () {
    final sql = _read(_migration);

    test('the write guard trigger is installed on inquiry', () {
      expect(sql.contains('CREATE TRIGGER trg_inquiry_po_date_guard'), isTrue,
          reason: 'without the BEFORE trigger a cross-date pointer can be '
              'written again and the 83-row bug returns silently');
      expect(sql.contains('BEFORE INSERT OR UPDATE OF supplier_order_id'),
          isTrue,
          reason: 'the guard must fire on the column that carries the bug');
    });

    test('"already ordered" has exactly one date-aware definition', () {
      expect(
          sql.contains('FUNCTION public.inq_is_ordered(p_so uuid, p_batch date)'),
          isTrue,
          reason: 'inq_is_ordered is the one predicate; a bare NOT NULL test '
              'is what hid the lines');
      expect(sql.contains('so.order_date IS NOT DISTINCT FROM p_batch'), isTrue,
          reason: 'the predicate stopped comparing the PO date to the batch '
              'date — it now accepts a stale pointer again');
    });

    test('both linkers find their PO through the one date-keyed door', () {
      expect(sql.contains('FUNCTION public._supplier_po_for_date'), isTrue);
      for (final linker in <String>[
        'FUNCTION public.commit_supplier_order',
        'FUNCTION public._heal_inquiry_link',
      ]) {
        expect(sql.contains(linker), isTrue,
            reason: '$linker is no longer re-defined here — it may have gone '
                'back to picking a PO with no order_date filter');
      }
      expect(sql.contains('so.order_date    = r.batch_date'), isTrue,
          reason: '_heal_inquiry_link lost its date scope — it would heal a '
              "line onto whichever PO happened to be newest");
    });

    test('the backfill re-points and never clears the pointer', () {
      // Clearing would make inquiry_engine_sync (every minute, not date
      // scoped) stamp asked_at and WhatsApp real suppliers about days-old
      // lines — the exact hazard #238 refused to trigger.
      expect(sql.contains('_supplier_po_for_date(r.supplier, r.d, v_order_id, true)'),
          isTrue,
          reason: 'back-filled POs must be stamped auto_order_sent_at so the '
              'autosend sweep cannot pick them up');
      expect(sql.contains('UPDATE inquiry SET supplier_order_id = v_oid'), isTrue,
          reason: 'the backfill no longer re-points rows onto the right PO');
    });

    test('the reader split is exactly as decided', () {
      // Display readers get the date-aware predicate; the two engine functions
      // deliberately do NOT, so a stale pointer can never promote itself into
      // an unsolicited supplier WhatsApp.
      for (final reader in <String>[
        '_get_inquiry_form_core',
        'supplier_pending_inquiry_count',
        'supplier_inquiry_buckets',
        'get_supplier_inquiry_overview',
        'get_supplier_inquiry_items',
      ]) {
        expect(sql.contains("'$reader'"), isTrue,
            reason: '$reader dropped out of the §10 reader swap — a stale '
                'pointer could hide a line from the supplier form again');
      }
      expect(
          sql.contains(
              "and p.proname in ('inquiry_engine_ranked_suppliers','inquiry_engine_sync')"),
          isTrue,
          reason: 'the rg test no longer pins the engine OUT of the predicate '
              '— the re-ask policy is unguarded');
    });

    test('both regression guards are registered', () {
      for (final t in <String>[
        "'inquiry_po_date_integrity'",
        "'inquiry_po_reader_predicate'",
      ]) {
        expect(sql.contains(t), isTrue,
            reason: '$t is not inserted into rg_behavior_tests — rg_check '
                'would go green with the bug present');
      }
    });
  });

  group('the admin integrity block renders the payload and decides nothing',
      () {
    testWidgets('every string on screen came from the payload', (tester) async {
      await _pump(tester, _payload());

      for (final s in <String>[
        'TITLE-FROM-BACKEND',
        'SUBTITLE-FROM-BACKEND',
        'BANNER-FROM-BACKEND',
        'ROW1-LABEL',
        'ROW1-DETAIL',
        'ROW2-LABEL',
        'ROW2-DETAIL',
      ]) {
        expect(find.text(s), findsOneWidget,
            reason: '$s is in the payload but never reached the screen');
      }
    });

    testWidgets('the value is printed verbatim, never re-computed',
        (tester) async {
      await _pump(tester, _payload());

      // '7' is a backend string. A screen that counted, pluralised or
      // formatted would not print it back unchanged...
      expect(find.text('7'), findsOneWidget);
      // ...and a value that is not a number at all must still render, which a
      // Dart-side int.parse would have thrown on.
      expect(find.text('ROW2-VALUE-IS-A-WORD'), findsOneWidget);
    });

    testWidgets('rows render in payload order', (tester) async {
      await _pump(tester, _payload());
      final first = tester.getTopLeft(find.text('ROW1-LABEL')).dy;
      final second = tester.getTopLeft(find.text('ROW2-LABEL')).dy;
      expect(first, lessThan(second),
          reason: 'the block re-ordered the backend rows — ordering is the '
              "backend's job");
    });

    testWidgets('the red state is the backend flag, not a Dart threshold',
        (tester) async {
      // Same numbers, opposite tone: only the payload decides.
      await _pump(tester, _payload(banner: 'ALL-CLEAR', tone: 'success'));
      expect(find.text('ALL-CLEAR'), findsOneWidget);

      await _pump(tester, _payload(banner: 'LINES-ARE-HIDDEN', tone: 'danger'));
      expect(find.text('LINES-ARE-HIDDEN'), findsOneWidget);
    });

    testWidgets('an empty rows list renders the banner, not a crash',
        (tester) async {
      await _pump(tester, {
        'title': 'T',
        'subtitle': 'S',
        'banner_tone': 'success',
        'banner_label': 'STILL-SHOWN',
        'rows': const [],
      });
      expect(find.text('STILL-SHOWN'), findsOneWidget);
    });

    testWidgets('a payload with no rows key at all does not throw',
        (tester) async {
      await _pump(tester, {'title': 'T', 'banner_label': 'B'});
      expect(tester.takeException(), isNull);
    });
  });

  group('the screen wiring is forward and backward compatible', () {
    final screen = _read('lib/screens/admin/admin_scope_audit_screen.dart');
    final screenCode = _code(screen);

    test('the block is skipped entirely when the backend omits it', () {
      expect(screenCode.contains("d?['integrity'] is Map"), isTrue,
          reason: 'the screen must treat a missing integrity block as absent, '
              'so an older backend still renders the rest of the audit');
      expect(screenCode.contains('if (integrity != null)'), isTrue,
          reason: 'an absent block must not render an empty card');
    });

    test('it still reads exactly one RPC', () {
      final rpcs = RegExp(r"\.rpc\(\s*'([a-z0-9_]+)'")
          .allMatches(screenCode)
          .map((m) => m.group(1)!)
          .toSet();
      expect(rpcs, <String>{'admin_scope_audit'},
          reason: 'the integrity block travels in the EXISTING payload; a '
              'second RPC would break the one-source-of-truth contract');
    });

    test('the screen has a URL, so a deploy can actually open it', () {
      // Without this route nothing can reach the screen headlessly (Flutter
      // canvas taps are banned), so c240_inq_po_block would sit at 0 forever
      // and "it rendered" could never be proven again.
      final main = _code(_read('lib/main.dart'));
      expect(main.contains("name == '/admin/scope-audit'"), isTrue,
          reason: 'the /admin/scope-audit route is gone — the integrity block '
              'can no longer be opened or proven by the post-deploy verifier');
      expect(main.contains('AdminScopeAuditScreen()'), isTrue,
          reason: 'the route no longer builds the Scope Audit screen');
    });

    test('it proves it painted, so a live deploy can be verified', () {
      // Whitespace-tolerant: the formatter is free to wrap the call.
      for (final key in <String>['c240_inq_po_block', 'c240_inq_po_rows']) {
        expect(RegExp("RenderLog\\.write\\(\\s*'$key'").hasMatch(screen),
            isTrue,
            reason: '$key is not written to the render log — the live deploy '
                'of this block could not be proven');
      }
    });

    test('the block writes no display string of its own', () {
      // Every word the admin reads is ui_copy, fetched by the RPC.
      for (final banned in <String>[
        "'Cross-date pointers'",
        "'Write guard'",
        "'Linked lines'",
        "'Active'",
        "'Missing'",
      ]) {
        expect(screenCode.contains(banned), isFalse,
            reason: '$banned is a display string written in Dart — it belongs '
                'in ui_copy and must arrive in the payload');
      }
    });

    test('it styles from tokens only', () {
      expect(RegExp(r'Color\(0x').hasMatch(screenCode), isFalse,
          reason: 'a hardcoded colour literal — use Ds.c.* (DESIGN.md)');
      expect(screenCode.contains('fontSize:'), isFalse,
          reason: 'a raw font size — use Ds.t.* (DESIGN.md)');
    });
  });
}

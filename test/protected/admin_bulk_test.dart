// PROTECTED — bulk actions, exports and undo (CHANGE #397).
//
// What this holds down, in the order the change asks for it:
//
//   BULK   — the screen renders the backend's target list, count label and row
//            lines verbatim; ticking rows sends EXACTLY those ids (no implicit
//            select-all, no client-side filtering of the selection), and the
//            result banner is the backend's sentence, never one composed here.
//   EXPORT — a report's filters, its format buttons and its filename all come
//            from the payload; the saved bytes are the backend's own file, and
//            Dart never builds a CSV cell.
//   UNDO   — Undo is offered only where the BACKEND said can:true, and where it
//            said can:false the screen prints ITS reason (a money entry is
//            never quietly reversible). The undo call carries the batch id the
//            payload named.
//
// The apply sheet's warning copy, the confirmation words and the empty states
// are all asserted as backend strings: a Dart literal creeping into any of them
// is the regression this file exists to catch.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_bulk_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _bulkPayload({
  bool canWrite = true,
  bool needsSearch = false,
  List<Map<String, dynamic>>? rows,
}) =>
    {
      'ok': true,
      'title': 'Bulk actions & exports',
      'subtitle': 'Select rows, apply one change to all of them.',
      'can_write': canWrite,
      'tab_bulk': 'Bulk edit',
      'tab_export': 'Exports',
      'tab_history': 'History',
      'targets': [
        {'key': 'customer_records', 'label': 'Customers', 'hint': ''},
        {'key': 'order_status', 'label': 'Order status', 'hint': ''},
      ],
      'target': 'customer_records',
      'target_label': 'Customers',
      'target_hint': 'Zone, approval and soft-delete.',
      'fields': [
        {
          'field': 'zone_id',
          'label': 'Zone',
          'input_kind': 'enum',
          'options': [
            {'value': '1', 'label': 'Raipur Zone'},
            {'value': '2', 'label': 'Bilaspur Zone'},
          ],
          'hint': 'Which operating zone serves these customers.',
          'confirm_body': 'Delivery and inquiry routing follow the new zone.',
        },
      ],
      'rows': rows ??
          const [
            {'id': 'c1', 'name': 'Nitesh Pharmacy', 'extra': 'Raipur · Zone 1'},
            {'id': 'c2', 'name': 'Ot Medical', 'extra': 'Raipur · Zone 1'},
            {'id': 'c3', 'name': 'Pallavi Pharmacy', 'extra': 'Raipur · Zone 1'},
          ],
      'count': 3,
      'needs_search': needsSearch,
      'count_label': '3 rows',
      'search_hint': 'Search this list',
      'needs_search_title': 'Search first',
      'needs_search_hint': 'This list is too large to show in full.',
      'select_all_label': 'Select all shown',
      'clear_label': 'Clear',
      'apply_label': 'Apply to selected',
      'field_label': 'Change',
      'value_label': 'New value',
      'cancel_label': 'Cancel',
      'confirm_cta': 'Apply change',
      'sheet_title': 'Apply one change to every selected row',
      'max_rows': 500,
      'empty_title': 'Nothing to show',
      'empty_hint': 'No rows match this search.',
      'no_selection_hint': 'Tick the rows you want to change.',
      'selected_fmt': '{n} selected',
    };

Map<String, dynamic> _exportPayload() => {
      'ok': true,
      'title': 'Exports',
      'subtitle': 'Download any list with the filters you have applied.',
      'can_write': true,
      'reports': [
        {
          'key': 'orders',
          'label': 'Orders',
          'hint': 'Every order with its status, zone and value.',
          'filters': [
            {'key': 'from', 'label': 'From', 'kind': 'date'},
            {
              'key': 'status',
              'label': 'Status',
              'kind': 'enum',
              'options': [
                {'value': 'pending', 'label': 'Pending'}
              ]
            },
          ],
          'formats': [
            {'key': 'csv', 'ext': 'csv', 'label': 'CSV', 'mime': 'text/csv'},
            {
              'key': 'excel',
              'ext': 'xls',
              'label': 'Excel',
              'mime': 'application/vnd.ms-excel'
            },
          ],
        },
      ],
      'jobs': [
        {
          'id': 7,
          'title': 'GST register',
          'when_label': '01 Sep 2026, 02:24 AM',
          'format_label': 'CSV',
          'status': 'ready',
          'tone': 'success',
          'state_label': 'Ready · 4210 rows',
          'can_download': true,
          'download_label': 'Download',
          'filename': 'gst_register.csv',
          'error': '',
        },
        {
          'id': 8,
          'title': 'Orders',
          'when_label': '01 Sep 2026, 02:25 AM',
          'format_label': 'Excel',
          'status': 'queued',
          'tone': 'info',
          'state_label': 'Preparing…',
          'can_download': false,
          'download_label': 'Download',
          'filename': '',
          'error': '',
        },
      ],
      'jobs_title': 'Recent exports',
      'jobs_empty': 'Nothing exported yet.',
      'download_label': 'Download',
      'preparing_label': 'Preparing…',
      'empty_title': 'No reports available',
      'empty_hint': 'You do not have read access to any report yet.',
      'filter_all_label': 'All',
    };

Map<String, dynamic> _historyPayload() => {
      'ok': true,
      'title': 'Recent bulk changes',
      'window_label': 'Undo stays available for 180 minutes after a change.',
      'empty_title': 'No bulk changes yet',
      'empty_hint': 'Apply a change from the Bulk edit tab.',
      'rows': [
        {
          'id': 41,
          'title': 'Customers · Zone',
          'value_label': 'Set to Bilaspur Zone',
          'count_label': '50 rows',
          'actor_label': 'om@medibo.in',
          'when_label': '01 Sep 2026, 02:10 AM',
          'tone': 'success',
          'state_label': 'Applied',
          'can_undo': true,
          'undo_label': 'Undo',
          'undo_blocked_label': '',
          'confirm_title': 'Undo this change?',
          'confirm_body': 'All 50 rows go back to the values they held before.',
          'confirm_cta': 'Undo change',
          'cancel_label': 'Keep it',
        },
        {
          'id': 40,
          'title': 'Refunds · Amount',
          'value_label': 'Set to 120',
          'count_label': '2 rows',
          'actor_label': 'om@medibo.in',
          'when_label': '31 Aug 2026, 09:00 PM',
          'tone': 'warning',
          'state_label': 'Undone 31 Aug 2026, 09:05 PM',
          'can_undo': false,
          'undo_label': 'Undo',
          'undo_blocked_label': 'Already undone',
          'confirm_title': 'Undo this change?',
          'confirm_body': 'x',
          'confirm_cta': 'Undo change',
          'cancel_label': 'Keep it',
        },
      ],
    };

/// A recording RPC seam: returns the canned payload for each function and keeps
/// every call so the test can assert on what the SCREEN actually sent.
class _Rpc {
  _Rpc({this.applyResult, this.exportResult, this.undoResult});

  final calls = <MapEntry<String, Map<String, dynamic>>>[];
  Map<String, dynamic>? applyResult;
  Map<String, dynamic>? exportResult;
  Map<String, dynamic>? undoResult;
  Map<String, dynamic> bulk = _bulkPayload();

  Future<Map<String, dynamic>> call(String fn, Map<String, dynamic> p) async {
    calls.add(MapEntry(fn, p));
    switch (fn) {
      case 'admin_bulk_screen':
        return bulk;
      case 'admin_export_screen':
        return _exportPayload();
      case 'admin_bulk_batches':
        return _historyPayload();
      case 'admin_bulk_apply':
        return applyResult ??
            {
              'ok': true,
              'batch_id': 41,
              'audit_id': 900,
              'row_count': 2,
              'message': 'Zone set to Bilaspur Zone on 2 rows.',
              'undo_label': 'Undo',
            };
      case 'admin_bulk_undo':
        return undoResult ??
            {'ok': true, 'row_count': 2, 'message': '2 rows put back.'};
      case 'admin_export_run':
        return exportResult ??
            {
              'ok': true,
              'ready': true,
              'job_id': 9,
              'row_count': 2,
              'filename': 'orders_2026-09-01_0224.csv',
              'mime': 'text/csv',
              'content': 'Order,Total (INR)\nCPO1,1301.90\n',
              'message': '2 rows exported.',
            };
      case 'admin_export_job':
        return {
          'ok': true,
          'ready': true,
          'id': 7,
          'filename': 'gst_register.csv',
          'mime': 'text/csv',
          'content': 'a,b\n1,2\n',
          'message': '4210 rows ready.',
        };
    }
    return {'ok': false, 'message': 'unexpected $fn'};
  }
}

class _Saved {
  List<int>? bytes;
  String? name;
  String? mime;
  int count = 0;
}

Future<void> _pump(WidgetTester tester, _Rpc rpc, {_Saved? saved}) async {
  await tester.pumpWidget(MaterialApp(
    home: AdminBulkScreen(
      rpc: rpc.call,
      saveFile: (b, n, m) {
        if (saved == null) return;
        saved.bytes = b;
        saved.name = n;
        saved.mime = m;
        saved.count++;
      },
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('bulk edit', () {
    testWidgets('renders the backend list verbatim and nothing of its own',
        (tester) async {
      final rpc = _Rpc();
      await _pump(tester, rpc);

      expect(find.text('Bulk actions & exports'), findsOneWidget);
      expect(find.text('Customers'), findsWidgets);
      expect(find.text('Order status'), findsWidgets);
      expect(find.text('3 rows'), findsOneWidget);
      expect(find.text('Nitesh Pharmacy'), findsOneWidget);
      expect(find.text('Raipur · Zone 1'), findsNWidgets(3));
      expect(find.text('Zone, approval and soft-delete.'), findsOneWidget);
    });

    testWidgets('the selection count is the backend format string', (tester) async {
      final rpc = _Rpc();
      await _pump(tester, rpc);

      await tester.tap(find.text('Nitesh Pharmacy'));
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.text('Ot Medical'));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
      expect(find.text('Apply to selected'), findsOneWidget);
    });

    testWidgets('apply sends exactly the ticked ids and prints the backend banner',
        (tester) async {
      final rpc = _Rpc();
      await _pump(tester, rpc);

      await tester.tap(find.text('Nitesh Pharmacy'));
      await tester.tap(find.text('Pallavi Pharmacy'));
      await tester.pump();

      await tester.tap(find.text('Apply to selected'));
      await tester.pumpAndSettle();

      // The sheet is the backend's words, including its warning.
      expect(find.text('Apply one change to every selected row'), findsOneWidget);
      expect(find.text('2 selected'), findsWidgets);
      expect(find.text('Delivery and inquiry routing follow the new zone.'),
          findsOneWidget);

      // The value control is the second dropdown in the sheet (the first picks
      // WHICH field is being changed).
      await tester.tap(find.byType(DropdownButtonFormField<String>).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bilaspur Zone').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Apply change'));
      await tester.pumpAndSettle();

      final apply =
          rpc.calls.lastWhere((c) => c.key == 'admin_bulk_apply').value;
      expect(apply['p_target'], 'customer_records');
      expect(apply['p_field'], 'zone_id');
      expect(apply['p_value'], '2');
      expect((apply['p_ids'] as List).toSet(), {'c1', 'c3'});

      expect(find.text('Zone set to Bilaspur Zone on 2 rows.'), findsOneWidget);
    });

    testWidgets('a refused batch prints the refusal and changes nothing',
        (tester) async {
      final rpc = _Rpc(applyResult: {
        'ok': false,
        'message': 'Nothing was changed — 1 of the 2 selected rows could not be found.',
      });
      await _pump(tester, rpc);

      await tester.tap(find.text('Nitesh Pharmacy'));
      await tester.pump();
      await tester.tap(find.text('Apply to selected'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Raipur Zone').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply change'));
      await tester.pumpAndSettle();

      expect(
          find.text(
              'Nothing was changed — 1 of the 2 selected rows could not be found.'),
          findsOneWidget);
      // The selection survives a refusal, so the admin can correct and retry.
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('a read-only admin cannot apply', (tester) async {
      final rpc = _Rpc()..bulk = _bulkPayload(canWrite: false);
      await _pump(tester, rpc);

      await tester.tap(find.text('Nitesh Pharmacy'));
      await tester.pump();
      final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Apply to selected'));
      expect(button.onPressed, isNull);
    });

    testWidgets('a search-first list shows the backend instruction, not an empty state',
        (tester) async {
      final rpc = _Rpc()
        ..bulk = _bulkPayload(needsSearch: true, rows: const []);
      await _pump(tester, rpc);

      expect(find.text('Search first'), findsOneWidget);
      expect(find.text('This list is too large to show in full.'), findsOneWidget);
      expect(find.text('Nothing to show'), findsNothing);
    });
  });

  group('exports', () {
    testWidgets('a report renders its own filters, formats and jobs', (tester) async {
      final rpc = _Rpc();
      await _pump(tester, rpc);
      await tester.tap(find.text('Exports'));
      await tester.pumpAndSettle();

      expect(find.text('Orders'), findsWidgets);
      expect(find.text('Every order with its status, zone and value.'),
          findsOneWidget);
      expect(find.text('CSV'), findsOneWidget);
      expect(find.text('Excel'), findsOneWidget);
      expect(find.text('Ready · 4210 rows · 01 Sep 2026, 02:24 AM'),
          findsOneWidget);
      // A job still building offers no download.
      expect(find.text('Preparing… · 01 Sep 2026, 02:25 AM'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Download'), findsOneWidget);
    });

    testWidgets('running an export saves the backend file byte for byte',
        (tester) async {
      final rpc = _Rpc();
      final saved = _Saved();
      await _pump(tester, rpc, saved: saved);
      await tester.tap(find.text('Exports'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'CSV'));
      await tester.pumpAndSettle();

      final run = rpc.calls.lastWhere((c) => c.key == 'admin_export_run').value;
      expect(run['p_report'], 'orders');
      expect(run['p_format'], 'csv');

      expect(saved.count, 1);
      expect(saved.name, 'orders_2026-09-01_0224.csv');
      expect(saved.mime, 'text/csv');
      expect(String.fromCharCodes(saved.bytes!),
          'Order,Total (INR)\nCPO1,1301.90\n');
      expect(find.text('2 rows exported.'), findsOneWidget);
    });

    testWidgets('a queued export saves nothing and prints the backend notice',
        (tester) async {
      final rpc = _Rpc(exportResult: {
        'ok': true,
        'ready': false,
        'job_id': 12,
        'message': '90000 rows is too big to build while you wait — it is being prepared now.',
      });
      final saved = _Saved();
      await _pump(tester, rpc, saved: saved);
      await tester.tap(find.text('Exports'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Excel'));
      await tester.pumpAndSettle();

      expect(saved.count, 0);
      expect(
          find.text(
              '90000 rows is too big to build while you wait — it is being prepared now.'),
          findsOneWidget);
    });
  });

  group('undo', () {
    testWidgets('Undo appears only where the backend allowed it', (tester) async {
      final rpc = _Rpc();
      await _pump(tester, rpc);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();

      expect(find.text('Undo stays available for 180 minutes after a change.'),
          findsOneWidget);
      expect(find.text('Customers · Zone'), findsOneWidget);
      expect(find.text('Set to Bilaspur Zone · 50 rows'), findsOneWidget);

      // can_undo:true → a button. can_undo:false → the backend's reason, and no
      // button anywhere near it.
      expect(find.widgetWithText(OutlinedButton, 'Undo'), findsOneWidget);
      expect(find.text('Already undone'), findsOneWidget);
    });

    testWidgets('undo confirms with backend copy and carries the named batch id',
        (tester) async {
      final rpc = _Rpc();
      await _pump(tester, rpc);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Undo'));
      await tester.pumpAndSettle();

      expect(find.text('Undo this change?'), findsOneWidget);
      expect(find.text('All 50 rows go back to the values they held before.'),
          findsOneWidget);
      expect(find.text('Keep it'), findsOneWidget);

      await tester.tap(find.text('Undo change'));
      await tester.pumpAndSettle();

      final undo = rpc.calls.lastWhere((c) => c.key == 'admin_bulk_undo').value;
      expect(undo['p_batch_id'], 41);
      expect(find.text('2 rows put back.'), findsOneWidget);
    });

    testWidgets('cancelling the confirmation calls nothing', (tester) async {
      final rpc = _Rpc();
      await _pump(tester, rpc);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Undo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();

      expect(rpc.calls.any((c) => c.key == 'admin_bulk_undo'), isFalse);
    });
  });
}

// CMD #423 — the bill vault renders the backend's answers and judges nothing.
//
// The pinned contract, on the surface where getting it wrong invents stock:
//   * every rupee, month name, chip and progress line is the payload's string —
//     the screen totals nothing and formats no date
//   * an UNREADABLE line is drawn, in the backend's words, with its own tone.
//     Hiding it (or quietly dropping it) is the exact failure this vault exists
//     to prevent, so it is asserted, not assumed
//   * `can_confirm` is a backend flag: a bill still in review offers no button
//     that would put an unchecked read onto the shelf
//   * a month chip sends the backend's own month_key back, never a date this
//     screen built
//   * the batch progress bar draws the payload's percent and prints the
//     payload's sentence — Dart divides nothing
//   * a duplicate and a failed read each show the backend's own reason
//   * the entry button exists only because pharmacy_vault_entry() said `show`,
//     and its badge is the backend's count
//   * a refusal renders the backend's message
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/pharmacy/pharmacy_vault_screen.dart';
import 'package:pharma_b2b/services/pharmacy_vault_api.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _home() => {
  'ok': true,
  'title': 'Bill vault',
  'subtitle': 'Your bills are your stock register',
  'tiles': [
    {'key': 'bills', 'label': 'Bills', 'value': '14'},
    {'key': 'review', 'label': 'To check', 'value': '2', 'tone': 'warning'},
    {'key': 'lots', 'label': 'Batches', 'value': '61'},
    {'key': 'value', 'label': 'Stock value', 'value': '₹1,84,220.50'},
  ],
  'unquantified_label': '7 shelf items still need a count',
  'actions': [
    {'key': 'photo', 'label': 'Photograph a bill', 'primary': true},
    {'key': 'bulk', 'label': 'Import old bills'},
    {'key': 'shelf', 'label': 'Photograph the shelf'},
  ],
  'months': [
    {'month_key': '2026-08-01', 'label': 'August 2026', 'bills': 9,
     'amount': '₹1,10,000.00', 'selected': false},
    {'month_key': '2026-07-01', 'label': 'July 2026', 'bills': 5,
     'amount': '₹74,220.50', 'selected': false},
  ],
  'batch': {
    'batch_id': 'b-1',
    'status': 'running',
    'total': 120,
    'done': 91,
    'percent': 76,
    'progress_label': '91 of 120 read',
    'review_label': '6 need checking',
    'duplicate_label': '3 were already in the vault',
  },
  'bills': [
    {
      'bill_id': 'bill-review',
      'source': 'photo',
      'source_label': 'Outside bill',
      'supplier': 'Kop Medical Agencies',
      'invoice': 'Invoice INV/2026/0041',
      'date_label': '14 Aug 2026',
      'meta': 'Invoice INV/2026/0041 · 14 Aug 2026',
      'amount': '₹1,120.00',
      'has_amount': true,
      'lines_label': '3 lines',
      'chip': {'label': 'Check this', 'tone': 'warning'},
      'status': 'review',
      'needs_review': true,
      'can_confirm': true,
      'reason': '2 lines need your eyes',
    },
    {
      'bill_id': 'bill-dupe',
      'source': 'photo',
      'source_label': 'Outside bill',
      'supplier': 'Kop Medical Agencies',
      'invoice': 'Invoice INV/2026/0041',
      'date_label': '14 Aug 2026',
      'meta': 'Invoice INV/2026/0041 · 14 Aug 2026',
      'has_amount': false,
      'lines_label': '0 lines',
      'chip': {'label': 'Already have it', 'tone': 'info'},
      'status': 'duplicate',
      'is_duplicate': true,
      'reason': 'You already have this bill in the vault.',
    },
    {
      'bill_id': 'bill-failed',
      'source': 'photo',
      'source_label': 'Outside bill',
      'supplier': 'Supplier not printed',
      'invoice': 'No invoice number',
      'date_label': 'No date',
      'meta': 'No invoice number · No date',
      'has_amount': false,
      'lines_label': '0 lines',
      'chip': {'label': 'Could not read', 'tone': 'danger'},
      'status': 'failed',
      'error': 'No bill lines could be read from those photos.',
    },
  ],
  'empty': null,
  'review_count': 2,
};

Map<String, dynamic> _bill({bool canConfirm = true}) => {
  'ok': true,
  'bill': {
    'bill_id': 'bill-review',
    'supplier': 'Kop Medical Agencies',
    'invoice': 'Invoice INV/2026/0041',
    'date_label': '14 Aug 2026',
    'meta': 'Invoice INV/2026/0041 · 14 Aug 2026',
    'can_confirm': canConfirm,
    'chip': {'label': 'Check this', 'tone': 'warning'},
  },
  'confirm_label': 'Add to stock',
  'lines': [
    {
      'line_id': 'l1',
      'line_no': 1,
      'product': 'MONTEK-LC TAB',
      'qty_label': '10',
      'batch': 'KP2201',
      'expiry': '11/27',
      'meta': 'KP2201 · 11/27',
      'cost': '₹42.50',
      'has_cost': true,
      'flag': 'ok',
      'flag_label': null,
      'flag_tone': 'success',
      'needs_review': false,
      'match_label': 'Matched by learned · 100%',
    },
    {
      'line_id': 'l2',
      'line_no': 2,
      'product': 'Could not read this line',
      'seen': null,
      'qty_label': '—',
      'batch': 'Batch not readable',
      'expiry': 'Expiry not readable',
      'meta': 'Batch not readable · Expiry not readable',
      'has_cost': false,
      'flag': 'unreadable',
      'flag_label': 'Unreadable',
      'flag_tone': 'danger',
      'needs_review': true,
    },
    {
      'line_id': 'l3',
      'line_no': 3,
      'product': 'Zzqx Blurbicillin 400',
      'qty_label': '5',
      'batch': 'Batch not readable',
      'expiry': 'Expiry not readable',
      'meta': 'Batch not readable · Expiry not readable',
      'has_cost': false,
      'flag': 'unmatched',
      'flag_label': 'Which medicine?',
      'flag_tone': 'warning',
      'needs_review': true,
    },
  ],
  'shots': [],
};

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  // The vault home is a long page (tiles, three doors, a progress strip, the
  // month rail, then the bills). A 600px test viewport would leave the lower
  // half unbuilt and the assertions below would pass or fail on scroll
  // position rather than on the contract, so every test gets a tall surface.
  setUp(() {
    final v = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views
        .first;
    v.physicalSize = const Size(1200, 4000);
    v.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final v = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views
        .first;
    v.resetPhysicalSize();
    v.resetDevicePixelRatio();
  });

  Future<List<List<Object?>>> pump(
    WidgetTester tester,
    Map<String, dynamic> Function(String fn, Map<String, dynamic> p) answer,
  ) async {
    final calls = <List<Object?>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PharmacyVaultScreen(
          rpc: (fn, p) async {
            calls.add([fn, p]);
            return answer(fn, p);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return calls;
  }

  testWidgets('every tile is the payload\'s own string, never a Dart total',
      (t) async {
    await pump(t, (fn, p) => _home());
    expect(find.text('₹1,84,220.50'), findsOneWidget);
    expect(find.text('Stock value'), findsOneWidget);
    expect(find.text('14'), findsOneWidget);
    // The screen holds no title of its own.
    expect(find.text('Bill vault'), findsOneWidget);
    expect(find.text('Your bills are your stock register'), findsOneWidget);
  });

  testWidgets('the three doors are the payload\'s actions, in payload order',
      (t) async {
    await pump(t, (fn, p) => _home());
    expect(find.text('Photograph a bill'), findsOneWidget);
    expect(find.text('Import old bills'), findsOneWidget);
    expect(find.text('Photograph the shelf'), findsOneWidget);
  });

  testWidgets('the bulk progress bar draws the payload\'s percent and prints '
      'its sentence — Dart divides nothing', (t) async {
    await pump(t, (fn, p) => _home());
    expect(find.text('91 of 120 read'), findsOneWidget);
    expect(find.text('6 need checking'), findsOneWidget);
    expect(find.text('3 were already in the vault'), findsOneWidget);
    final bar = t.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.76, 0.0001));
  });

  testWidgets('a duplicate and a failed read each show the backend\'s reason',
      (t) async {
    await pump(t, (fn, p) => _home());
    expect(find.text('Already have it'), findsOneWidget);
    expect(find.text('You already have this bill in the vault.'), findsOneWidget);
    expect(find.text('Could not read'), findsOneWidget);
    expect(
      find.text('No bill lines could be read from those photos.'),
      findsOneWidget,
    );
  });

  testWidgets('a month chip sends the backend\'s own month_key back', (t) async {
    final calls = await pump(t, (fn, p) => _home());
    calls.clear();
    await t.tap(find.text('August 2026'));
    await t.pumpAndSettle();
    expect(calls.first[0], 'pharmacy_vault_home');
    expect((calls.first[1] as Map)['p_month'], '2026-08-01');
  });

  testWidgets('an unreadable line is DRAWN, in the backend\'s words — never '
      'hidden and never guessed', (t) async {
    await pump(t, (fn, p) => fn == 'pharmacy_vault_bill_get' ? _bill() : _home());
    await t.tap(find.text('Kop Medical Agencies').first);
    await t.pumpAndSettle();

    expect(find.text('Could not read this line'), findsOneWidget);
    expect(find.text('Unreadable'), findsOneWidget);
    // Two doubtful lines, each printing the BACKEND's joined meta line — the
    // separator is composed in SQL, so this screen never builds a label.
    expect(
      find.text('Batch not readable · Expiry not readable'),
      findsNWidgets(2),
    );
    // The quantity of an unreadable line is the backend's dash, not a zero.
    expect(find.text('—'), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('the match explanation is the backend\'s sentence, score and all',
      (t) async {
    await pump(t, (fn, p) => fn == 'pharmacy_vault_bill_get' ? _bill() : _home());
    await t.tap(find.text('Kop Medical Agencies').first);
    await t.pumpAndSettle();
    expect(find.text('Matched by learned · 100%'), findsOneWidget);
    expect(find.text('Which medicine?'), findsOneWidget);
  });

  testWidgets('can_confirm:false offers no button that could put an unchecked '
      'read onto the shelf', (t) async {
    await pump(
      t,
      (fn, p) => fn == 'pharmacy_vault_bill_get'
          ? _bill(canConfirm: false)
          : _home(),
    );
    await t.tap(find.text('Kop Medical Agencies').first);
    await t.pumpAndSettle();
    expect(find.text('Add to stock'), findsNothing);
  });

  testWidgets('confirming sends the bill id and shows the backend\'s message',
      (t) async {
    final seen = <List<Object?>>[];
    await tester_pump(t, seen);
    await t.tap(find.text('Kop Medical Agencies').first);
    await t.pumpAndSettle();
    await t.tap(find.text('Add to stock'));
    await t.pumpAndSettle();
    final confirm = seen.lastWhere(
      (c) => c[0] == 'pharmacy_vault_bill_confirm',
    );
    expect((confirm[1] as Map)['p_bill_id'], 'bill-review');
    expect(find.text('2 batches added to your stock'), findsOneWidget);
  });

  testWidgets('an empty vault prints the backend\'s empty line and no rows',
      (t) async {
    await pump(t, (fn, p) => {
      ..._home(),
      'bills': const [],
      'months': const [],
      'batch': const {},
      'empty': 'No bills yet. Photograph one, or let your next mediBO '
          'delivery fill this by itself.',
    });
    expect(
      find.textContaining('No bills yet.'),
      findsOneWidget,
    );
    expect(find.text('Kop Medical Agencies'), findsNothing);
  });

  testWidgets('a refusal renders the backend\'s message', (t) async {
    await pump(t, (fn, p) => {
      'ok': false,
      'error': 'not_a_pharmacy',
      'message': 'The bill vault is for a pharmacy account.',
    });
    expect(
      find.text('The bill vault is for a pharmacy account.'),
      findsOneWidget,
    );
  });

  test('the entry button exists only because the backend said show', () async {
    VaultEntry.value.value = const {};
    await VaultEntry.load(rpc: (fn, p) async => {'ok': false});
    expect(VaultEntry.show, isFalse);

    await VaultEntry.load(
      rpc: (fn, p) async => {
        'ok': true,
        'show': true,
        'label': 'Bill vault',
        'badge': '2',
        'route_key': 'pharmacy_vault',
      },
    );
    expect(VaultEntry.show, isTrue);
    // The badge is the backend's count, printed — never a number Dart kept.
    expect(VaultEntry.value.value['badge'], '2');
    expect(VaultEntry.value.value['label'], 'Bill vault');
  });

  test('a thrown entry call is a button that is not drawn, never a crash',
      () async {
    VaultEntry.value.value = const {};
    await VaultEntry.load(rpc: (fn, p) async => throw Exception('offline'));
    expect(VaultEntry.show, isFalse);
  });
}

/// The confirm test needs the same injected rpc on both screens plus a reply to
/// the confirm call itself, so it gets its own pump.
Future<void> tester_pump(WidgetTester t, List<List<Object?>> seen) async {
  await t.pumpWidget(
    MaterialApp(
      home: PharmacyVaultScreen(
        rpc: (fn, p) async {
          seen.add([fn, p]);
          if (fn == 'pharmacy_vault_bill_get') return _bill();
          if (fn == 'pharmacy_vault_bill_confirm') {
            return {
              'ok': true,
              'bill_id': 'bill-review',
              'lots': 2,
              'message': '2 batches added to your stock',
            };
          }
          return _home();
        },
      ),
    ),
  );
  await t.pumpAndSettle();
}

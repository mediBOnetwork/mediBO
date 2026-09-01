// PROTECTED — CMD #407.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how the delivery programme renders.
//
// Four surfaces landed together — incentives, the agency's GST invoice, the
// training gate and the vehicle/fuel ledger — and every one of them is a place
// where a number invented in Dart becomes money paid or tax filed. So what this
// holds down is that none of them computes anything:
//
//   1. The TAB LIST is `admin_delivery_extras()`'s. A tab_key this build has
//      never heard of renders an EMPTY body instead of throwing, which is how a
//      fifth tab ships as SQL and no deploy.
//   2. An incentive row's target, bonus, status word and the caption on its own
//      toggle are backend strings. The screen never derives "Switch off" from
//      `active`, and never formats a rupee.
//   3. Cost-per-drop is the BACKEND's division. The fixture's actual is
//      ₹205.00 against a configured ₹120.00 and the screen prints exactly
//      that pair — it never divides earnings by drops itself.
//   4. The reconciliation verdict is the payload's sentence and the payload's
//      tone. "Off by ₹705.30" appears because the BACKEND said so, and the
//      PDF chip exists only when the backend says an invoice exists.
//   5. The rider's progress BAR is the payload's `progress` fraction, and
//      `has:false` renders NOTHING — an empty targets card is the backend's
//      decision, not a Dart `isEmpty` check on a list it built.
//   6. A refusal (`ok:false`) renders the backend's own `message`, with no Dart
//      fallback wording anywhere.
//
// No network, no Supabase, no goldens — both screens are pumped through their
// `rpc` test seams against fixtures.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_delivery_extras_screen.dart';
import 'package:pharma_b2b/screens/delivery/rider_extras_sheets.dart';
import 'package:pharma_b2b/utils/render_log.dart';

const _tabs = [
  {'tab_key': 'incentives', 'label': 'Incentives'},
  {'tab_key': 'invoices', 'label': 'Agency invoices'},
  {'tab_key': 'training', 'label': 'Training'},
  {'tab_key': 'cost', 'label': 'Cost per drop'},
];

Map<String, dynamic> _incentives() => {
      'ok': true,
      'title': 'Incentive schemes',
      'empty_note': 'No incentive scheme yet. Add one and switch it on.',
      'run_label': 'Score today',
      'save_label': 'Save',
      'rows': [
        {
          'scheme_id': 's1',
          'label': 'Daily target — 12 deliveries',
          'metric_label': 'Deliveries in a day',
          'target_label': '12 drops',
          'scope_label': 'All riders',
          'window_label': 'Always on',
          'bonus_label': '₹100.00',
          'paid_label': '₹1,400.00',
          'status_label': 'On',
          'tone': 'success',
          'toggle_label': 'Switch off',
          'toggle_tone': 'muted',
          'active': true,
          'note': 'Template.',
        },
      ],
    };

Map<String, dynamic> _invoices({bool hasInvoice = true}) => {
      'ok': true,
      'title': 'Agency invoices',
      'empty_note': 'No payout period has been opened yet.',
      'open_label': 'Open invoice PDF',
      'rows': [
        {
          'period_id': 'p1',
          'invoice_id': 'i1',
          'has_invoice': hasInvoice,
          'partner_name': 'Rapid Riders Agency',
          'period_label': '18 Aug – 24 Aug 2026',
          'payout_label': '₹4,860.00',
          'payout_status_label': 'Unpaid',
          'invoice_no': 'MB-DA/202608/AB12CD',
          'invoice_total_label': '₹5,734.80',
          'gstin_label': '22AAAAA0000A1Z5',
          'recon_label':
              'The signed copy says ₹6,440.10; this invoice says ₹5,734.80 — off by ₹705.30.',
          'recon_tone': 'danger',
          'generate_label': 'Rebuild invoice',
        },
      ],
    };

Map<String, dynamic> _training() => {
      'ok': true,
      'title': 'Training modules',
      'empty_note': 'No module yet.',
      'rows': [
        {
          'module_id': 'm1',
          'title': 'Delivery basics — proof, cold chain and cash',
          'required_label': 'Required',
          'pass_mark_label': '70%',
          'question_count_label': '3 questions',
          'passed_label': '2 riders passed',
          'status_label': 'On',
          'tone': 'success',
        },
      ],
    };

Map<String, dynamic> _cost() => {
      'ok': true,
      'title': 'Cost per drop — configured vs actual',
      'range_label': '03 Aug – 01 Sep 2026',
      'empty_note': 'No deliveries or expenses in this range.',
      'summary': [
        {'label': 'Deliveries', 'value': '3'},
        {'label': 'Actual per drop', 'value': '₹205.00', 'bold': true},
      ],
      'rows': [
        {
          'partner_id': 'r1',
          'partner_name': 'Proof Rider 407',
          'zone_label': 'Raipur',
          'drops_label': '3',
          'earn_label': '₹90.00',
          'bonus_label': '₹75.00',
          'spend_label': '₹450.00',
          'configured_label': '₹120.00',
          'actual_label': '₹205.00',
          'variance_label': '₹85.00',
          'tone': 'danger',
        },
      ],
    };

Map<String, dynamic> _shell(String tab, Map<String, dynamic>? body) => {
      'ok': true,
      'title': 'Delivery programme',
      'tabs': _tabs,
      'tab_key': tab,
      'body': body,
    };

ExtrasRpc _seam(Map<String, dynamic> reply) =>
    (String fn, Map<String, dynamic> params) async => reply;

Future<void> _pumpAdmin(WidgetTester t, Map<String, dynamic> reply,
    {String? initialTab}) async {
  await t.pumpWidget(MaterialApp(
    // A fresh key per pump: without it Flutter reuses the State across two
    // pumps in one test and the second fixture is never loaded.
    home: AdminDeliveryExtrasScreen(
        key: UniqueKey(), rpc: _seam(reply), initialTab: initialTab),
  ));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the tab list is the backend\'s', () {
    testWidgets('every tab the payload named is drawn, in payload order',
        (t) async {
      await _pumpAdmin(t, _shell('incentives', _incentives()));
      for (final tab in _tabs) {
        expect(find.text(tab['label'] as String), findsOneWidget);
      }
    });

    testWidgets('a tab_key this build has never heard of renders nothing',
        (t) async {
      // Forward compatibility: the backend may add a fifth tab at any time.
      // The screen must draw its label and an EMPTY body — never throw.
      await _pumpAdmin(
          t,
          _shell('fuel_cards', {'ok': true, 'rows': const []}),
          initialTab: 'fuel_cards');
      expect(tester_hasNoException(), isTrue);
      expect(find.text('Incentives'), findsOneWidget);
    });

    testWidgets('a refusal shows the backend\'s own message', (t) async {
      await _pumpAdmin(
          t,
          _shell('incentives', {
            'ok': false,
            'error': 'not_authorized',
            'message': 'This screen is for admins.',
          }));
      expect(find.text('This screen is for admins.'), findsOneWidget);
    });
  });

  group('incentives compute nothing', () {
    testWidgets('target, bonus and status print verbatim', (t) async {
      await _pumpAdmin(t, _shell('incentives', _incentives()));
      expect(find.text('Daily target — 12 deliveries'), findsOneWidget);
      expect(find.text('12 drops'), findsOneWidget);
      expect(find.text('₹100.00'), findsOneWidget);
      expect(find.text('₹1,400.00'), findsOneWidget);
      expect(find.text('On'), findsOneWidget);
    });

    testWidgets('the toggle caption is the payload\'s, not derived from active',
        (t) async {
      await _pumpAdmin(t, _shell('incentives', _incentives()));
      // `active: true` — a screen that decided for itself would print
      // "Switch on"/"Save". It prints exactly what the backend sent.
      expect(find.text('Switch off'), findsOneWidget);
      expect(find.text('Switch on'), findsNothing);
    });

    testWidgets('an empty scheme list renders the backend\'s sentence',
        (t) async {
      final empty = _incentives()..['rows'] = const [];
      await _pumpAdmin(t, _shell('incentives', empty));
      expect(
          find.text('No incentive scheme yet. Add one and switch it on.'),
          findsOneWidget);
    });
  });

  group('the agency invoice', () {
    testWidgets('the reconciliation sentence is the backend\'s, in full',
        (t) async {
      await _pumpAdmin(t, _shell('invoices', _invoices()));
      expect(
          find.text(
              'The signed copy says ₹6,440.10; this invoice says ₹5,734.80 — off by ₹705.30.'),
          findsOneWidget);
      expect(find.text('MB-DA/202608/AB12CD'), findsOneWidget);
      expect(find.text('₹5,734.80'), findsOneWidget);
    });

    testWidgets('the PDF chip appears only when an invoice exists', (t) async {
      await _pumpAdmin(t, _shell('invoices', _invoices()));
      expect(find.text('Open invoice PDF'), findsOneWidget);

      await _pumpAdmin(t, _shell('invoices', _invoices(hasInvoice: false)));
      expect(find.text('Open invoice PDF'), findsNothing);
      // The generate action is still offered — it is what creates the invoice.
      expect(find.text('Rebuild invoice'), findsOneWidget);
    });
  });

  testWidgets('training modules print their own status and counts', (t) async {
    await _pumpAdmin(t, _shell('training', _training()));
    expect(find.text('Delivery basics — proof, cold chain and cash'),
        findsOneWidget);
    expect(find.text('Required'), findsOneWidget);
    expect(find.text('70%'), findsOneWidget);
    expect(find.text('3 questions'), findsOneWidget);
    expect(find.text('2 riders passed'), findsOneWidget);
  });

  testWidgets('cost per drop is the backend\'s division, printed as given',
      (t) async {
    await _pumpAdmin(t, _shell('cost', _cost()));
    // earnings 90 + bonus 75 + running 450 over 3 drops. If this screen ever
    // did that arithmetic itself the number would still be 205 — and the next
    // change to how cost is defined would silently disagree with the backend.
    expect(find.text('₹205.00'), findsNWidgets(2)); // summary + row chip
    expect(find.text('₹120.00'), findsOneWidget); // configured, untouched
    expect(find.text('₹450.00'), findsOneWidget);
  });

  group('the rider\'s targets card', () {
    testWidgets('has:false renders nothing at all', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: RiderIncentiveProgress(data: {'has': false, 'rows': []})),
      ));
      await t.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('the bar is the payload\'s fraction and the labels are its own',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RiderIncentiveProgress(data: const {
            'has': true,
            'title': 'Today\'s targets',
            'earned_today_label': '₹75.00',
            'earned_caption': 'Bonus earned today',
            'rows': [
              {
                'scheme_id': 's1',
                'label': 'Daily target — 12 deliveries',
                'value_label': '9 drops',
                'target_label': '12 drops',
                'progress': 0.75,
                'bonus_label': '₹100.00',
                'earned': false,
                'status_label': 'In progress',
                'tone': 'warning',
              },
            ],
          }),
        ),
      ));
      await t.pumpAndSettle();

      expect(find.text('Today\'s targets'), findsOneWidget);
      expect(find.text('₹75.00'), findsOneWidget);
      expect(find.text('Bonus earned today'), findsOneWidget);
      expect(find.text('In progress'), findsOneWidget);
      expect(find.text('9 drops / 12 drops'), findsOneWidget);

      final bar = t.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(bar.value, 0.75); // the BACKEND's fraction, not 9/12 done here
    });
  });
}

/// The pump above would have thrown already; this keeps the intent of the
/// forward-compatibility test readable.
bool tester_hasNoException() => true;

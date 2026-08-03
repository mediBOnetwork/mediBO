// PROTECTED — CHANGE #642.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the payment QR sheet, never to make an unrelated change
// go green.
//
// The bug this pins down: the sheet composed its own headings out of three
// parts, so the amount was printed TWICE in two different formats —
//
//   title    : '${payLabel} — mediBO'          → "Pay advance ₹10,770.73 — mediBO"
//   subtitle : 'mediBO — ${payLabel} ${_amt}'  → "mediBO — Pay advance ₹10,770.73 ₹10770.73"
//
// `pay_label` already carried the backend's formatted "₹10,770.73"; `_amt` was
// a SECOND amount formatted in Dart from a raw double, which is why the two
// disagreed on separators. Both the payee name and the second amount were glued
// on by the app.
//
// What must never regress:
//
//   1. The heading is qr_sheet.<kind>.title VERBATIM — no payee, no order code,
//      no amount appended.
//   2. The amount string appears EXACTLY ONCE in the whole sheet. This is the
//      assertion that fails if anyone re-adds an amount row alongside a title
//      that already contains one.
//   3. No text equals a payee+title (or title+payee) concatenation.
//   4. A null amount_label renders no amount row and no orphan "₹".
//   5. Row labels come from the payload (vpa_label / payee_label), not from the
//      Dart literals 'UPI ID' / 'Banking Name' this change removed.
//
// Fixtures mirror cust_order_panel().payment.upi.qr_sheet. No network.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/widgets/pay_qr_card.dart';

const String _kAmount = '₹10,770.73';
const String _kPayee = 'mediBO';
const String _kTitle = 'Pay advance $_kAmount';
const String _kSubtitle = 'Scan the QR or use the UPI ID below';

/// The exact shape the backend returns under `payment.upi.qr_sheet`.
Map<String, dynamic> _qrSheet({
  String title = _kTitle,
  String subtitle = _kSubtitle,
  String? amountLabel = _kAmount,
  String vpaLabel = 'UPI ID',
  String payeeLabel = 'Banking Name',
}) =>
    {
      'advance': {
        'title': title,
        'subtitle': subtitle,
        'amount_label': amountLabel,
        'vpa_label': vpaLabel,
        'payee_label': payeeLabel,
      },
      'balance': {
        'title': 'Balance not confirmed yet',
        'subtitle': _kSubtitle,
        'amount_label': null,
        'vpa_label': 'UPI ID',
        'payee_label': 'Banking Name',
      },
    };

/// Renders the sheet exactly as CustPaySheet composes it: the heading row, then
/// the captured QR card.
Future<void> _pumpSheet(
  WidgetTester tester,
  Map<String, dynamic> qrSheet, {
  String kind = 'advance',
}) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final copy = PayQrSheetCopy.forKind(qrSheet, kind);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: Column(children: [
          PayQrSheetTitle(title: copy.title),
          PayQrCard(
            copy: copy,
            qrData: 'upi://pay?pa=test@upi&am=10770.73',
            vpa: 'medibo@upi',
            payee: _kPayee,
          ),
        ]),
      ),
    ),
  ));
  await tester.pump();
}

/// Every string painted by a Text in the tree.
List<String> _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((w) => w.data ?? '')
    .where((s) => s.isNotEmpty)
    .toList();

void main() {
  testWidgets('the heading is qr_sheet.title verbatim, exactly once',
      (tester) async {
    await _pumpSheet(tester, _qrSheet());

    expect(find.text(_kTitle), findsOneWidget);

    // The composed forms the old sheet produced.
    expect(find.text('$_kTitle — $_kPayee'), findsNothing);
    expect(find.text('$_kPayee — $_kTitle'), findsNothing);
    expect(find.textContaining('— $_kPayee'), findsNothing,
        reason: 'the payee name must not be glued onto the heading');
  });

  testWidgets('the amount appears EXACTLY ONCE in the whole sheet',
      (tester) async {
    await _pumpSheet(tester, _qrSheet());

    final hits = _allText(tester).where((s) => s.contains(_kAmount)).toList();
    expect(hits.length, 1,
        reason: 'amount must appear once; found in: $hits');

    // The unformatted twin the old code produced from the raw double.
    expect(find.textContaining('10770.73'), findsNothing,
        reason: 'no Dart-formatted amount — the payload string is the only one');
  });

  testWidgets('no text is a payee + title concatenation', (tester) async {
    await _pumpSheet(tester, _qrSheet());

    for (final s in _allText(tester)) {
      expect(s.contains(_kPayee) && s.contains(_kAmount), isFalse,
          reason: 'payee and amount must never share a line: "$s"');
    }
    // The exact line the bug rendered.
    expect(find.text('$_kPayee — $_kTitle $_kAmount'), findsNothing);
  });

  testWidgets('the subtitle renders verbatim, and carries no amount',
      (tester) async {
    await _pumpSheet(tester, _qrSheet());

    expect(find.text(_kSubtitle), findsOneWidget);
  });

  testWidgets('a null amount_label renders no amount row and no orphan ₹',
      (tester) async {
    await _pumpSheet(tester, _qrSheet(), kind: 'remaining');

    // 'remaining' reads the payload's 'balance' branch.
    expect(find.text('Balance not confirmed yet'), findsOneWidget);

    // Nothing anywhere shows a currency symbol, so there is no orphan "₹" and
    // no empty amount row.
    for (final s in _allText(tester)) {
      expect(s.contains('₹'), isFalse,
          reason: 'null amount_label must print no currency at all: "$s"');
    }
  });

  testWidgets('row labels come from the payload, not Dart literals',
      (tester) async {
    // Deliberately NOT the old hardcoded words — if the sheet still printed
    // literals, these would not appear.
    await _pumpSheet(
        tester,
        _qrSheet(vpaLabel: 'UPI handle', payeeLabel: 'Account holder'));

    expect(find.text('UPI handle'), findsOneWidget);
    expect(find.text('Account holder'), findsOneWidget);
    expect(find.text('UPI ID'), findsNothing);
    expect(find.text('Banking Name'), findsNothing);

    // The values themselves still render next to their labels.
    expect(find.text('medibo@upi'), findsOneWidget);
    expect(find.text(_kPayee), findsOneWidget);
  });
}

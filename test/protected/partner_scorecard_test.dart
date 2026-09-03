// PROTECTED — CHANGE #693, the fulfilment partner's scorecard (feature_gaps 156).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes scorecard behaviour, never to make an unrelated change
// go green.
//
// What this holds down:
//
//   1. NOTHING ON THE CARD IS COMPUTED IN DART. The fixture's numbers are
//      deliberately inconsistent — a metric whose value is 30 against a target
//      of 24 arrives with progress 0.80 and tone 'danger', and the overall
//      score is NOT the average of the rows. If the widget ever starts doing
//      the arithmetic it will disagree with the payload and this fails.
//
//   2. ABSENCE IS `has_value:false`, NOT A ZERO. A metric with no data prints
//      the backend's own sentence; it never renders '0' or an empty gap, which
//      on a scorecard would read as a failed month rather than a quiet one.
//
//   3. THE PROGRESS BAR IS THE PAYLOAD'S FRACTION. Not value/target worked out
//      in the widget — the backend owns direction (lower_better vs
//      higher_better) and a widget that guessed it would invert half the card.
//
//   4. ROWS RENDER IN PAYLOAD ORDER, both the metrics and the incentives. No
//      client-side sort, so the office can reorder the card from SQL.
//
//   5. THE INCENTIVE BLOCK IS FLAGS, NOT INFERENCE. `has_bonus` decides whether
//      the section exists at all, and each scheme's status word and tone come
//      only from the payload — an unearned scheme is never styled as earned
//      because its rupees are non-zero.
//
//   6. ok:false PRINTS THE BACKEND'S REFUSAL. A login with no partner sees the
//      backend's sentence, never a Dart fallback and never a throw.
//
// No network, no Supabase, no timers.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/partner/partner_scorecard_card.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// partner_scorecard(): the shape the RPC actually returns. The numbers are
/// deliberately NOT self-consistent — see note 1.
Map<String, dynamic> _card({bool withBonus = true}) => {
      'ok': true,
      'partner_id': 1,
      'partner_label': 'Jai Mahakal Medical And Surgical',
      'zone_label': 'Raipur Zone',
      'month': '2026-08-01',
      'month_label': 'August 2026',
      'heading': 'Your scorecard',
      'subtitle': 'Measured from your own fulfilment data.',
      'metrics_heading': 'This month',
      'bonus_heading': 'Incentives',
      'has_score': true,
      // NOT the average of the rows below. The backend decided it.
      'score': 61.5,
      'score_label': '62',
      'score_caption': 'Overall score against target',
      'score_tone': 'warning',
      'metrics': [
        {
          'slug': 'inquiry_to_pack_h',
          'label': 'Inquiry to pack',
          'hint': 'Average hours from order to bag ready.',
          'direction': 'lower_better',
          'has_value': true,
          'value': 30,
          'value_label': '30.0 h',
          'no_value_label': 'No data yet',
          'sample_label': '18 measured',
          'has_target': true,
          'target': 24,
          'target_label': '24.0 h',
          'target_caption': 'Target',
          // 30 h against a 24 h ceiling: the backend says 0.80, and a widget
          // computing value/target would say 1.25.
          'progress': 0.80,
          'progress_label': '80%',
          'met': false,
          'status_label': 'Close',
          'tone': 'warning',
        },
        {
          'slug': 'delivery_sla_pct',
          'label': 'Delivery SLA',
          'hint': 'Share handed over inside the promised window.',
          'direction': 'higher_better',
          'has_value': false,
          'value': null,
          'value_label': '',
          'no_value_label': 'No data yet',
          'sample_label': '0 measured',
          'has_target': false,
          'target': null,
          'target_label': '',
          'target_caption': 'Target',
          'progress': 0,
          'progress_label': 'No data yet',
          'met': false,
          'status_label': 'No data yet',
          'tone': 'muted',
        },
      ],
      'has_bonus': withBonus,
      'bonuses': withBonus
          ? [
              {
                'scheme_id': 'aaaa',
                'label': 'Zone 1 dispatch bonus',
                'metric_label': 'On-time dispatch',
                'threshold_label': '92.0%',
                'bonus_label': '₹5,000.00',
                'achieved': false,
                'status_label': 'Not earned yet',
                'tone': 'muted',
                'active': true,
              },
              {
                'scheme_id': 'bbbb',
                'label': 'Clean count bonus',
                'metric_label': 'Count disputes',
                'threshold_label': '2.0%',
                'bonus_label': '₹2,500.00',
                'achieved': true,
                'status_label': 'Earned',
                'tone': 'success',
                'active': true,
              },
            ]
          : const [],
      'bonus_total_label': '₹2,500.00',
      'bonus_total_caption': 'Earned this month',
      'settlement_note': 'An earned bonus is added to your next open statement.',
      'empty_label': 'Nothing to score for this month yet.',
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('every number and word on the card is the backend\'s', (t) async {
    await t.pumpWidget(_host(PartnerScorecardCard(payload: _card())));

    // The score is the payload's, not the average of the two rows.
    expect(find.text('62'), findsOneWidget);
    expect(find.text('Overall score against target'), findsOneWidget);
    expect(find.text('30.0 h'), findsOneWidget);
    expect(find.text('Target 24.0 h'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('a metric with no data prints the sentence, never a zero',
      (t) async {
    await t.pumpWidget(_host(PartnerScorecardCard(payload: _card())));

    // The value slot and the status slot both say it — two places, no zero.
    expect(find.text('No data yet'), findsNWidgets(2));
    // It has no target, so the caption slot falls back to the sample count.
    expect(find.text('0 measured'), findsOneWidget);
    // And it never renders a bare zero in the value slot.
    expect(find.text('0'), findsNothing);
    expect(find.text('0.0'), findsNothing);
  });

  testWidgets('the progress bar is the payload fraction, not value/target',
      (t) async {
    await t.pumpWidget(_host(PartnerScorecardCard(payload: _card())));

    final bars = t
        .widgetList<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
        .toList();
    expect(bars.length, 2);
    // 30 h against a 24 h target: the BACKEND says 0.80. value/target is 1.25.
    expect(bars.first.value, closeTo(0.80, 0.0001));
    expect(bars.last.value, 0.0);
  });

  testWidgets('metrics and incentives render in payload order', (t) async {
    await t.pumpWidget(_host(PartnerScorecardCard(payload: _card())));

    final labels = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .toList();
    expect(labels.indexOf('Inquiry to pack'),
        lessThan(labels.indexOf('Delivery SLA')));
    expect(labels.indexOf('Zone 1 dispatch bonus'),
        lessThan(labels.indexOf('Clean count bonus')));
  });

  testWidgets('an unearned scheme is never styled as earned', (t) async {
    await t.pumpWidget(_host(PartnerScorecardCard(payload: _card())));

    expect(find.text('Not earned yet'), findsOneWidget);
    expect(find.text('Earned'), findsOneWidget);
    // Rupees are printed exactly as sent, for BOTH, earned or not.
    expect(find.text('₹5,000.00'), findsOneWidget);
    expect(find.text('₹2,500.00'), findsNWidgets(2)); // the row and the total
  });

  testWidgets('has_bonus:false removes the whole incentive block', (t) async {
    await t.pumpWidget(
        _host(PartnerScorecardCard(payload: _card(withBonus: false))));

    expect(find.text('Incentives'), findsNothing);
    expect(find.text('Earned this month'), findsNothing);
    expect(find.text('₹2,500.00'), findsNothing);
  });

  testWidgets('ok:false prints the backend refusal instead of throwing',
      (t) async {
    await t.pumpWidget(_host(const PartnerScorecardCard(payload: {
      'ok': false,
      'error': 'no_partner',
      'message': 'This login is not linked to a fulfilment partner.',
    })));

    expect(find.text('This login is not linked to a fulfilment partner.'),
        findsOneWidget);
  });

  testWidgets('the dense (admin) card leads with the partner, not the heading',
      (t) async {
    await t.pumpWidget(_host(PartnerScorecardCard(payload: _card(), dense: true)));

    expect(find.text('Jai Mahakal Medical And Surgical'), findsOneWidget);
    expect(find.text('Your scorecard'), findsNothing);
    // The metrics are still the payload's, in the payload's order.
    expect(find.text('30.0 h'), findsOneWidget);
  });
}

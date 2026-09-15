// CHANGE #228 — the Template pipeline section of WhatsApp Ops.
//
// What this pins is that the section DECIDES NOTHING. Every word on screen
// arrives from wa_template_pipeline(): the status wording, the Live/Off wording,
// the Yes/No, the header wording, the explanation sentence and Meta's rejection
// reason. If any of those ever moves into Dart, one of these fails.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/wa_ops_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _row({
  required String message,
  required String template,
  required String statusLabel,
  required String statusTone,
  required String routeLabel,
  required String approvedLabel,
  String headerLabel = 'Text only',
  bool mediaReady = true,
  String note = '',
  String reason = '',
}) =>
    {
      'message': message,
      'template_name': template,
      'status_label': statusLabel,
      'status_tone': statusTone,
      'route_label': routeLabel,
      'route_tone': routeLabel == 'Live' ? 'good' : 'muted',
      'approved_label': approvedLabel,
      'approved_tone': approvedLabel == 'Yes' ? 'good' : 'muted',
      'header_label': headerLabel,
      'media_ready': mediaReady,
      'note': note,
      'reason': reason,
    };

Widget _screen(Map<String, dynamic> payload) => MaterialApp(
      home: WaOpsScreen(
        pipelineRpc: () async => payload,
        routesRpc: () async => <String, dynamic>{'rows': <dynamic>[]},
        wabaStatusRpc: () async => <String, dynamic>{'error': 'skip'},
        ledgerRpc: (_, __) async => <String, dynamic>{'error': 'skip'},
        zonesRpc: () async => <String, dynamic>{'error': 'skip'},
        refreshDelay: Duration.zero,
      ),
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('every column is the backend string, printed verbatim',
      (tester) async {
    await tester.pumpWidget(_screen({
      'ok': true,
      'summary_label': '18 approved · 25 with Meta · 1 rejected · 3 queued',
      'summary_tone': 'warn',
      'note': 'mediBO submits every one of these to Meta on its own.',
      'rows': [
        _row(
          message: 'Supplier bill still pending',
          template: 'supplier_bill_pending',
          statusLabel: 'With Meta',
          statusTone: 'warn',
          routeLabel: 'Off',
          approvedLabel: 'No',
          note: 'Submitted to Meta — the verdict lands by itself',
        ),
      ],
    }));
    await tester.pumpAndSettle();

    expect(find.text('Template pipeline'), findsOneWidget);
    expect(find.text('18 approved · 25 with Meta · 1 rejected · 3 queued'),
        findsOneWidget);
    expect(find.text('mediBO submits every one of these to Meta on its own.'),
        findsOneWidget);
    expect(find.text('Supplier bill still pending'), findsOneWidget);
    expect(find.text('supplier_bill_pending'), findsOneWidget);
    expect(find.text('With Meta'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('No'), findsOneWidget);
    expect(find.text('Submitted to Meta — the verdict lands by itself'),
        findsOneWidget);
  });

  testWidgets('an approved row prints the backend Live/Yes, never a Dart guess',
      (tester) async {
    await tester.pumpWidget(_screen({
      'ok': true,
      'summary_label': '1 approved',
      'summary_tone': 'good',
      'rows': [
        _row(
          message: 'Order placed',
          template: 'order_placed',
          statusLabel: 'Approved',
          statusTone: 'good',
          routeLabel: 'Live',
          approvedLabel: 'Yes',
          headerLabel: 'Picture header',
        ),
      ],
    }));
    await tester.pumpAndSettle();

    expect(find.text('Approved'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Yes'), findsOneWidget);
    expect(find.text('Picture header'), findsOneWidget);
  });

  testWidgets("Meta's rejection reason is shown, not swallowed", (tester) async {
    await tester.pumpWidget(_screen({
      'ok': true,
      'summary_label': '1 rejected',
      'summary_tone': 'warn',
      'rows': [
        _row(
          message: 'Delivery OTP',
          template: 'delivery_otp',
          statusLabel: 'Rejected',
          statusTone: 'bad',
          routeLabel: 'Off',
          approvedLabel: 'No',
          note: 'The wording is being reworked and mediBO resubmits it by itself.',
          reason: 'INVALID_FORMAT',
        ),
      ],
    }));
    await tester.pumpAndSettle();

    expect(find.text('Rejected'), findsOneWidget);
    expect(find.text('INVALID_FORMAT'), findsOneWidget);
    expect(
        find.text(
            'The wording is being reworked and mediBO resubmits it by itself.'),
        findsOneWidget);
  });

  testWidgets('no rows renders the backend empty line, not a Dart one',
      (tester) async {
    await tester.pumpWidget(_screen({
      'ok': true,
      'rows': <dynamic>[],
      'empty_label': 'No automatic messages are configured yet',
    }));
    await tester.pumpAndSettle();

    expect(find.text('No automatic messages are configured yet'), findsOneWidget);
  });

  testWidgets('a refused read prints the backend message', (tester) async {
    await tester.pumpWidget(_screen({
      'error': 'not_authorized',
      'message': 'Only an admin can see the template pipeline',
    }));
    await tester.pumpAndSettle();

    expect(find.text('Only an admin can see the template pipeline'),
        findsOneWidget);
  });
}

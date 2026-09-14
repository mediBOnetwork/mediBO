// PROTECTED — CMD #1986. The partner agreement is a CONTRACT, and the two
// surfaces that make that true in the app are held down here.
//
// What this file refuses to let regress:
//   • The public verify page (/verify-agreement/<code>) prints the backend's
//     verdict VERBATIM — heading, status word, explanation, every field label
//     and the full sha256 — for all six payloads agreement_verify() can
//     return. A verdict word invented in Dart, or a truncated hash, is the
//     bug: the whole point of the page is that the reader can compare what is
//     on the paper with what mediBO holds.
//   • ok:false is a PAGE the backend wrote (not found / mismatch), never an
//     exception and never a Dart-authored apology.
//   • The preview door exists, is labelled by the backend, and asks for
//     'agreement_preview' with the backend's own ref. can_preview:false draws
//     no door at all — a partner with no published version is not offered a
//     preview of nothing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/public/agreement_verify_screen.dart';
import 'package:pharma_b2b/screens/partner/partner_documents_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _verified() => {
      'ok': true,
      'state': 'valid',
      'heading': 'Agreement verification',
      'status_label': 'Verified',
      'status_tone': 'success',
      'message': 'This copy matches the agreement mediBO holds, word for word.',
      'rows': [
        {'label': 'Code', 'value': 'A2-7178F634E4A9'},
        {'label': 'Operator', 'value': 'Jai Mahakal Medical And Surgical'},
        {'label': 'Partner', 'value': 'RAIPUR MEDICOS PVT LTD'},
        {
          'label': 'SHA-256 of the signed text',
          'value':
              '7178f634e4a9181ba34319557a4579a6d46c8c9a243180946a909462f4b7a452'
        },
      ],
      'note': 'This page is public on purpose.',
    };

Future<void> _pumpVerify(WidgetTester tester, Map<String, dynamic> payload,
    {String code = 'A2-7178F634E4A9'}) async {
  AgreementVerifyScreen.rpcTransport = (fn, params) async {
    expect(fn, 'agreement_verify');
    expect(params?['p_code'], code);
    return payload;
  };
  await tester.pumpWidget(MaterialApp(home: AgreementVerifyScreen(code: code)));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => AgreementVerifyScreen.rpcTransport = null);

  group('public verify page prints the backend verdict verbatim', () {
    testWidgets('a verified copy shows the words and the FULL hash',
        (tester) async {
      final p = _verified();
      await _pumpVerify(tester, p);

      expect(find.text('Agreement verification'), findsOneWidget);
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text(p['message'] as String), findsOneWidget);
      expect(find.text('This page is public on purpose.'), findsOneWidget);

      // Every row, label and value, exactly as sent. The hash is 64 characters
      // and must be printed whole — a truncated hash cannot be compared.
      for (final r in (p['rows'] as List).cast<Map<String, dynamic>>()) {
        expect(find.text(r['label'] as String), findsOneWidget,
            reason: 'label ${r['label']} must be printed verbatim');
        expect(find.text(r['value'] as String), findsOneWidget,
            reason: 'value ${r['value']} must be printed in full');
      }
    });

    testWidgets('not found is the backend\'s page, not an exception',
        (tester) async {
      await _pumpVerify(tester, {
        'ok': false,
        'state': 'unknown',
        'heading': 'Agreement verification',
        'status_label': 'Not found',
        'status_tone': 'danger',
        'message': 'No signed agreement carries this code.',
        'rows': [
          {'label': 'Code', 'value': 'ZZZ'}
        ],
        'note': 'This page is public on purpose.',
      }, code: 'ZZZ');

      expect(tester.takeException(), isNull);
      expect(find.text('Not found'), findsOneWidget);
      expect(find.text('No signed agreement carries this code.'), findsOneWidget);
    });

    testWidgets('drifted is its own word, and no rows means no invented card',
        (tester) async {
      await _pumpVerify(tester, {
        'ok': true,
        'state': 'drifted',
        'heading': 'Agreement verification',
        'status_label': 'Signed — wording has since changed',
        'status_tone': 'warning',
        'message': 'The signature below is genuine, but the agreement has been '
            're-worded since it was signed.',
        'rows': const [],
        'note': '',
      });
      expect(find.text('Signed — wording has since changed'), findsOneWidget);
      expect(find.byType(Divider), findsNothing);
    });

    testWidgets('mismatch is a different word again, and it is the backend\'s',
        (tester) async {
      await _pumpVerify(tester, {
        'ok': false,
        'state': 'mismatch',
        'heading': 'Agreement verification',
        'status_label': 'Does not match',
        'status_tone': 'danger',
        'message': 'Do not rely on this copy.',
        'rows': const [],
        'note': '',
      });
      expect(find.text('Does not match'), findsOneWidget);
      expect(find.text('Signed — wording has since changed'), findsNothing);
    });

    testWidgets('an unsigned preview code is an answer, not an error',
        (tester) async {
      await _pumpVerify(tester, {
        'ok': true,
        'state': 'preview',
        'heading': 'Agreement verification',
        'status_label': 'Unsigned preview',
        'status_tone': 'warning',
        'message': 'This code belongs to an unsigned preview.',
        'rows': [
          {'label': 'Code', 'value': 'P2-1-7178F634E4A9'}
        ],
        'note': '',
      }, code: 'P2-1-7178F634E4A9');
      expect(tester.takeException(), isNull);
      expect(find.text('Unsigned preview'), findsOneWidget);
    });
  });

  group('the preview door on My documents', () {
    Map<String, dynamic> screenPayload({required bool canPreview}) => {
          'ok': true,
          'partner_id': 1,
          'partner_name': 'RAIPUR MEDICOS PVT LTD',
          'title': 'My documents',
          'golive': {'ok': true},
          'kyc': {'ok': true, 'rows': const []},
          'licence': {'ok': true},
          'agreement': {
            'ok': true,
            'heading': 'Partner agreement',
            'sub': '',
            'has_version': true,
            'status': 'signed',
            'can_sign': false,
            'has_doc': false,
            'clauses': const [],
            'terms_rows': const [],
            'proposals': const [],
            'can_preview': canPreview,
            'preview_ref': '1',
            'preview_label': 'Preview the agreement (PDF)',
            'preview_hint': 'An unsigned copy, laid out exactly as the signed '
                'one will be.',
            'preview_building_label': 'Preparing the preview…',
            'verify_hint': 'Every page carries a QR code.',
          },
        };

    testWidgets('the door is drawn with the BACKEND\'s label and asks for '
        'agreement_preview with the backend\'s ref', (tester) async {
      final calls = <List<Object?>>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PartnerDocumentsScreen(
            partnerId: 1,
            api: (fn, params) async {
              calls.add([fn, params]);
              if (fn == 'partner_documents_screen') {
                return screenPayload(canPreview: true);
              }
              // The request is refused by the backend; the screen prints the
              // backend's sentence and stops. Nothing is authored here.
              return {'ok': false, 'message': 'Not ready yet.'};
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Preview the agreement (PDF)'), findsOneWidget);
      expect(find.text('Every page carries a QR code.'), findsOneWidget);

      await tester.tap(find.text('Preview the agreement (PDF)'));
      await tester.pump();
      await tester.pumpAndSettle();

      final req = calls.firstWhere((c) => c[0] == 'partner_doc_request',
          orElse: () => const []);
      expect(req, isNotEmpty,
          reason: 'tapping the door must call partner_doc_request');
      final params = req[1] as Map<String, dynamic>;
      expect(params['p_kind'], 'agreement_preview');
      expect(params['p_ref'], '1',
          reason: 'the ref is the backend\'s preview_ref, never a guess');
      expect(find.text('Not ready yet.'), findsOneWidget,
          reason: 'the refusal is the backend\'s sentence');

      // The toast owns a real 4s timer; let it retire inside the test rather
      // than outliving the tree (the protected-suite rule about stray Timers).
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('can_preview:false draws no door', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PartnerDocumentsScreen(
            partnerId: 1,
            api: (fn, params) async => screenPayload(canPreview: false),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Preview the agreement (PDF)'), findsNothing);
    });
  });
}

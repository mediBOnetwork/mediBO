// Holds down: the Privacy Policy and Delete Account & Data screens are ONE RPC
// (legal_get_page) printed verbatim — heading + items per section, in payload
// order. No policy wording is written in Dart, so this test injects a payload
// of stand-in strings and asserts the renderer shows exactly those, and that
// the old hardcoded May-2025 privacy text is nowhere in the tree.
//
// No network, no Supabase — the loader seam replaces the RPC.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/legal_pages.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _payload() => {
      'ok': true,
      'slug': 'data-deletion',
      'title': 'STANDIN_TITLE',
      'updated_label': 'STANDIN_UPDATED',
      'sections': [
        {
          'heading': 'STANDIN_HEADING_A',
          'items': ['STANDIN_ITEM_A1', 'STANDIN_ITEM_A2'],
        },
        {
          'heading': 'STANDIN_HEADING_B',
          'list': 'numbered',
          'items': ['STANDIN_ITEM_B1'],
        },
      ],
    };

Future<void> _pump(WidgetTester tester, String slug,
    Map<String, dynamic> payload) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    home: LegalPageScreen(slug: slug, loader: (_) async => payload),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('renders title, updated label and every section verbatim',
      (tester) async {
    await _pump(tester, 'data-deletion', _payload());

    expect(find.text('STANDIN_TITLE'), findsOneWidget);
    expect(find.text('STANDIN_UPDATED'), findsOneWidget);
    expect(find.text('STANDIN_HEADING_A'), findsOneWidget);
    expect(find.text('STANDIN_HEADING_B'), findsOneWidget);
    expect(find.text('STANDIN_ITEM_A1'), findsOneWidget);
    expect(find.text('STANDIN_ITEM_A2'), findsOneWidget);
    // numbered list prefixes the item, so match on a substring.
    expect(find.textContaining('STANDIN_ITEM_B1'), findsOneWidget);
  });

  testWidgets('privacy slug renders its payload — no hardcoded policy text',
      (tester) async {
    await _pump(tester, 'privacy', {
      ..._payload(),
      'title': 'Privacy Policy',
      'slug': 'privacy',
    });

    expect(find.text('STANDIN_HEADING_A'), findsOneWidget);
    // The deleted May-2025 six-point text must not resurface anywhere.
    expect(find.textContaining('PCI-DSS'), findsNothing);
    expect(find.textContaining('business KYC details'), findsNothing);
  });

  testWidgets('ok:false renders the backend message, does not throw',
      (tester) async {
    await _pump(tester, 'missing', {
      'ok': false,
      'error': 'not_found',
      'message': 'STANDIN_NOT_AVAILABLE',
    });
    expect(find.text('STANDIN_NOT_AVAILABLE'), findsOneWidget);
  });
}

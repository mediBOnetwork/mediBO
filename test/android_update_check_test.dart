// Android APK update-check dialog behaviour.
//
// Drives the real checkAndroidUpdate() with an inline-mocked RPC — no network,
// no Supabase, no home_shell import. The properties that must hold:
//   1. update_available:false  → no dialog
//   2. update_available:true   → dialog shows title, message, action_label
//   3. mandatory:true          → NO dismiss control rendered
//   4. an error/thrown RPC      → nothing shown
//   5. on web (not Android)     → RPC is never called, nothing shown
//   6. tapping the action opens apk_url

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/android_update_check.dart';

/// Pumps a screen with a single button that invokes checkAndroidUpdate against
/// the given mock. Returns after the tap settles.
Future<void> _run(
  WidgetTester tester, {
  required bool isAndroid,
  Future<Map<String, dynamic>?> Function()? rpc,
  Future<void> Function(String url)? opener,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          key: const Key('go'),
          onPressed: () => checkAndroidUpdate(
            context,
            isAndroidOverride: isAndroid,
            rpcOverride: rpc,
            openUrlOverride: opener,
          ),
          child: const Icon(Icons.system_update),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('go')));
  await tester.pumpAndSettle();
}

void main() {
  const payloadBase = {
    'update_available': true,
    'version_name': '1.1.0',
    'version_code': 2,
    'apk_url': 'https://medibo.in/app.apk',
    'title': 'Update available',
    'message': 'A newer mediBO is ready to install.',
    'action_label': 'Download',
    'dismiss_label': 'Later',
    'mandatory': false,
  };

  testWidgets('update_available:false → no dialog', (tester) async {
    await _run(tester,
        isAndroid: true,
        rpc: () async => {...payloadBase, 'update_available': false});
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Update available'), findsNothing);
  });

  testWidgets('update_available:true → shows title, message, action_label',
      (tester) async {
    await _run(tester, isAndroid: true, rpc: () async => payloadBase);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Update available'), findsOneWidget);
    expect(find.text('A newer mediBO is ready to install.'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    // Not mandatory + dismiss_label present → dismiss IS shown here.
    expect(find.text('Later'), findsOneWidget);
  });

  testWidgets('mandatory:true → no dismiss control', (tester) async {
    await _run(tester,
        isAndroid: true,
        rpc: () async => {...payloadBase, 'mandatory': true});
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Download'), findsOneWidget); // action still present
    expect(find.text('Later'), findsNothing); // dismiss suppressed
  });

  testWidgets('dismiss_label:null → no dismiss control even when not mandatory',
      (tester) async {
    await _run(tester,
        isAndroid: true,
        rpc: () async => {...payloadBase, 'dismiss_label': null});
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Later'), findsNothing);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('RPC error → nothing shown', (tester) async {
    await _run(tester,
        isAndroid: true, rpc: () async => throw Exception('boom'));
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('null response → nothing shown', (tester) async {
    await _run(tester, isAndroid: true, rpc: () async => null);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('on web (not Android) → RPC never called, nothing shown',
      (tester) async {
    var called = false;
    await _run(tester, isAndroid: false, rpc: () async {
      called = true;
      return payloadBase;
    });
    expect(called, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('tapping the action opens apk_url', (tester) async {
    String? opened;
    await _run(tester,
        isAndroid: true,
        rpc: () async => payloadBase,
        opener: (url) async => opened = url);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(opened, 'https://medibo.in/app.apk');
  });
}

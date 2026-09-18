// CMD #2076 — the Firebase Test Lab gate's ONE instrumentation test.
//
// This runs on a Test Lab virtual device, never on the Dart VM: it is the only
// place the Kotlin plugins (PlayUpdate, PaymentListener, OrderAlert,
// DocScanReadiness, SignInDiag, the run_location channel) and Firebase
// Messaging are ever exercised before a Play upload. The web build compiles
// none of them.
//
// NOTHING IS DECIDED HERE. The plan — which checks run — arrives from
// android_testlab_begin() through --dart-define=TESTLAB_PLAN (spec-derived,
// config-driven); the labels people read come from the backend when the
// verdict is rendered. Each check answers ok/fail with a one-line detail; the
// list is written to TESTLAB_OUT/checks.json, which the runner pulls off the
// device and stores next to the video and the logcat. A screenshot of the
// booted app lands beside it.
//
// One testWidgets, deliberately: the app boots once, every channel is asked on
// that same engine, and the verdict is the sum. A failing check does not stop
// the others — the JSON names every one that failed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:pharma_b2b/main.dart' as app;

const String _planCsv =
    String.fromEnvironment('TESTLAB_PLAN', defaultValue: 'boot_first_frame');
const String _runId = String.fromEnvironment('TESTLAB_RUN_ID', defaultValue: '0');
const String _outDir = String.fromEnvironment('TESTLAB_OUT',
    defaultValue: '/sdcard/Download/medibo_testlab');

class _Check {
  final String key;
  final bool ok;
  final String detail;
  const _Check(this.key, this.ok, this.detail);
  Map<String, Object> toJson() => {'key': key, 'ok': ok, 'detail': detail};
}

/// A channel answers when it returns anything at all without a
/// MissingPluginException — the VALUE is the plugin's business, its PRESENCE
/// on this Android runtime is what the gate proves.
Future<_Check> _channel(String key, String channel, String method) async {
  try {
    final res = await MethodChannel(channel)
        .invokeMethod<Object?>(method)
        .timeout(const Duration(seconds: 20));
    return _Check(key, true, '$channel.$method → ${_short(res)}');
  } on MissingPluginException catch (e) {
    return _Check(key, false, 'no handler for $channel.$method — ${e.message}');
  } on PlatformException catch (e) {
    // The Kotlin side is THERE and answered with its own error: the plugin is
    // wired. Report the code so a real regression stays visible in the JSON.
    return _Check(key, true, '$channel.$method answered ${e.code}: ${e.message}');
  } on TimeoutException {
    return _Check(key, false, '$channel.$method did not answer within 20 s');
  } catch (e) {
    return _Check(key, false, '$channel.$method threw $e');
  }
}

String _short(Object? v) {
  final s = v.toString();
  return s.length > 120 ? '${s.substring(0, 120)}…' : s;
}

Future<void> _writeFile(String name, List<int> bytes) async {
  final targets = <String>[_outDir];
  try {
    final ext = await getExternalStorageDirectory();
    if (ext != null) targets.add('${ext.path}/testlab');
  } catch (_) {}
  for (final dir in targets) {
    try {
      final f = File('$dir/$name');
      await f.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
    } catch (_) {
      // one of the two locations is enough; the runner pulls both
    }
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('android gate (run $_runId)', (tester) async {
    final plan = _planCsv.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    final results = <_Check>[];

    // ── boot_first_frame ────────────────────────────────────────────────────
    Object? bootError;
    try {
      await binding.convertFlutterSurfaceToImage();
    } catch (_) {}
    try {
      app.main();
      var painted = false;
      for (var i = 0; i < 60 && !painted; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        painted = find.byType(Scaffold).evaluate().isNotEmpty;
      }
      final err = tester.takeException();
      if (err != null) bootError = err;
      results.add(_Check(
          'boot_first_frame',
          painted && bootError == null,
          painted
              ? (bootError == null ? 'Scaffold painted' : 'painted, but threw: $bootError')
              : 'no Scaffold painted within 30 s${bootError == null ? '' : ' — $bootError'}'));
    } catch (e) {
      results.add(_Check('boot_first_frame', false, 'main() threw $e'));
    }
    try {
      final png = await binding.takeScreenshot('boot');
      await _writeFile('boot.png', png);
    } catch (_) {}

    // ── the Android-only seams, as the spec named them ───────────────────────
    for (final key in plan) {
      switch (key) {
        case 'boot_first_frame':
          break; // already done, first
        case 'channel_play_update':
          results.add(await _channel(key, 'in.medibo.app/play_update', 'available'));
        case 'channel_signin_diag':
          results.add(await _channel(key, 'in.medibo.app/signin_diag', 'deviceFacts'));
        case 'channel_pay_listen':
          results.add(await _channel(key, 'medibo/pay_listen', 'state'));
        case 'channel_order_alert':
          results.add(await _channel(key, 'medibo/order_alert', 'fullScreenState'));
        case 'channel_doc_scan':
          results.add(await _channel(key, 'in.medibo.app/doc_scan', 'status'));
        case 'channel_run_location':
          results.add(await _channel(key, 'in.medibo.app/run_location', 'available'));
        case 'fcm_token':
          try {
            final token = await FirebaseMessaging.instance
                .getToken()
                .timeout(const Duration(seconds: 30));
            results.add(_Check(key, (token ?? '').isNotEmpty,
                (token ?? '').isEmpty ? 'getToken() returned nothing' : 'token issued (${token!.length} chars)'));
          } catch (e) {
            results.add(_Check(key, false, 'getToken() threw $e'));
          }
        default:
          results.add(_Check(key, false, 'unknown check "$key" — not in this build\'s catalogue'));
      }
    }

    // ── the record the runner pulls off the device ───────────────────────────
    final report = {
      'run_id': _runId,
      'plan': plan,
      'checks': results.map((c) => c.toJson()).toList(),
      'at': DateTime.now().toUtc().toIso8601String(),
    };
    await _writeFile('checks.json', utf8.encode(const JsonEncoder.withIndent('  ').convert(report)));
    try {
      final png = await binding.takeScreenshot('after-checks');
      await _writeFile('after-checks.png', png);
    } catch (_) {}
    binding.reportData = report;

    final failed = results.where((c) => !c.ok).map((c) => '${c.key}: ${c.detail}').toList();
    expect(failed, isEmpty, reason: 'failed checks — ${failed.join('; ')}');
  });
}

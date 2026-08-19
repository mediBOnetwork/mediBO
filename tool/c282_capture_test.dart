// CHANGE #282 — proof capture (not a gate).
//
// Renders the SHIPPED widgets with the payloads the LIVE backend returns, at a
// real phone size with real Roboto glyphs, and writes PNGs. This is pixel
// evidence of the thing a pharmacy sees; it is not a golden and asserts no
// image bytes, so it can never fail a deploy for a font nudge.
//
//   flutter test tool/c282_capture_test.dart
//
// Output: /tmp/c282/*.png
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/widgets/app_update_prompt.dart';
import 'package:pharma_b2b/widgets/update_bar.dart';

const _fontDir = '/home/ubuntu/flutter/bin/cache/artifacts/material_fonts';
const _outDir = '/tmp/c282';

// Verbatim from the live RPC (see build log): android + version_code 1.
const Map<String, dynamic> kLivePlay = {
  'update_available': true,
  'current': '1.3.11',
  'version_name': '1.3.11',
  'version_code': 24,
  'version_label': 'Version 1.3.11',
  'channel': 'play',
  'store_name': 'Google Play',
  'install_source': 'play',
  'action_url': 'https://play.google.com/store/apps/details?id=in.medibo.app',
  'apk_url': null,
  'mandatory': false,
  'eyebrow': 'App update available',
  'title': 'A new version of mediBO is ready',
  'message':
      'Google sign-in now works reliably, plus speed and stability fixes.',
  'action_label': 'Update on Google Play',
  'dismiss_label': 'Not now',
  'dismiss_key': 'app_update:android:24',
};

final Map<String, dynamic> kLiveSideload = {
  ...kLivePlay,
  'channel': 'direct',
  'install_source': 'sideload',
  'action_url':
      'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public/app-releases/medibo-1.3.11.apk',
  'apk_url':
      'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public/app-releases/medibo-1.3.11.apk',
  'action_label': 'Download update',
};

Future<void> _loadFonts() async {
  for (final entry in const [
    ['Roboto', 'Roboto-Regular.ttf'],
    ['Roboto', 'Roboto-Medium.ttf'],
    ['Roboto', 'Roboto-Bold.ttf'],
    ['MaterialIcons', 'MaterialIcons-Regular.otf'],
  ]) {
    final f = File('$_fontDir/${entry[1]}');
    if (!f.existsSync()) continue;
    final loader = FontLoader(entry[0])
      ..addFont(Future.value(f.readAsBytesSync().buffer.asByteData()));
    await loader.load();
  }
}

/// PNG-encoding a RepaintBoundary needs the REAL event loop: `toImage` and
/// `toByteData` complete off the raster thread, and inside a widget test the
/// clock is fake, so awaiting them directly writes the file and then never
/// hands control back — the run hangs until the timeout kills it and every
/// later capture in the file is skipped. `tester.runAsync` lends the body the
/// real loop, which is the documented way to await raster work from a test.
Future<void> _shootBoundary(
    WidgetTester tester, RenderRepaintBoundary boundary, String name) async {
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 3.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose(); // native handle; frees the isolate to shut down
    final out = File('$_outDir/$name.png')..createSync(recursive: true);
    out.writeAsBytesSync(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('WROTE ${out.path} (${out.lengthSync()} b)');
  });
}

Future<void> _shoot(WidgetTester tester, String name) => _shootBoundary(
      tester,
      tester.renderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary).first),
      name,
    );

Widget _phone(Widget child) => MediaQuery(
      data: const MediaQueryData(size: Size(390, 844), devicePixelRatio: 3.0),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: ThemeData(fontFamily: 'Roboto'),
          child: Material(
            color: Ds.c.bg,
            child: Align(alignment: Alignment.bottomCenter, child: RepaintBoundary(child: child)),
          ),
        ),
      ),
    );

void main() {
  setUpAll(() async {
    RenderLog.flushEnabled = false;
    await _loadFonts();
  });

  testWidgets('play-install sheet', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_phone(AppUpdateSheet(
      payload: kLivePlay,
      onAction: () {},
      onDismiss: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.text('Update on Google Play'), findsOneWidget);
    expect(find.textContaining('signing'), findsNothing);
    await _shoot(tester, 'play_sheet');
  });

  testWidgets('sideload sheet', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_phone(AppUpdateSheet(
      payload: kLiveSideload,
      onAction: () {},
      onDismiss: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.text('Download update'), findsOneWidget);
    await _shoot(tester, 'sideload_sheet');
  });

  testWidgets('mandatory sheet has no dismiss', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_phone(AppUpdateSheet(
      payload: {...kLivePlay, 'mandatory': true},
      onAction: () {},
      onDismiss: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.text('Not now'), findsNothing);
    await _shoot(tester, 'mandatory_sheet');
  });

  // The WEB half of the redesign — CHANGE #286 replaced the top MaterialBanner
  // with the slim Plazza-style bar pinned above the bottom nav. The frame is
  // sized to the bar plus a strip of page above it, so the shot shows what the
  // bar covers (nothing) as well as the bar itself. Copy is the live ui_copy
  // text, seeded verbatim.
  testWidgets('web update bar', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 120 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    UiCopy.debugSet(const {
      'update_bar.title': 'App update available',
      'update_bar.action': 'Update Now',
      'update_bar.updating': 'Updating\u2026',
    });
    await tester.pumpWidget(_phone(SizedBox(
      width: 390,
      child: UpdateBar(
        title: c('update_bar.title'),
        actionLabel: c('update_bar.action'),
        updatingLabel: c('update_bar.updating'),
        updating: false,
        onUpdate: () {},
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('App update available'), findsOneWidget);
    expect(find.text('Update Now'), findsOneWidget);
    expect(find.textContaining('newer version is loading'), findsNothing);
    await _shoot(tester, 'web_update_bar');
  });

  // Same bar mid-update: the pill carries the backend's updating label and
  // stops taking taps.
  testWidgets('web update bar — updating', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 120 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_phone(SizedBox(
      width: 390,
      child: UpdateBar(
        title: c('update_bar.title'),
        actionLabel: c('update_bar.action'),
        updatingLabel: c('update_bar.updating'),
        updating: true,
        onUpdate: () {},
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Updating\u2026'), findsOneWidget);
    await _shoot(tester, 'web_update_bar_updating');
  });
}

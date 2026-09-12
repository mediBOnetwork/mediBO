// CHANGE #281 — proof capture (not a gate).
//
// The Play Store screen lives inside the Dev Queue, which is super-admin only,
// so shot.sh cannot drive it (an authed Flutter canvas route is not reachable
// from a headless URL fetch). This renders the SHIPPED widget with the payload
// the LIVE play_state() returned — dumped to /tmp/c281_play_state.json by the
// build log's own curl — at a real phone size with real glyphs, and writes a
// PNG. It asserts no image bytes, so it can never fail a deploy for a font
// nudge.
//
//   ~/mediBO-runner/devcmd.sh rpc play_state '{}' > /tmp/c281_play_state.json
//   flutter test tool/c281_capture_test.dart
//
// Output: /tmp/c281/play_store.png
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_service.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/play_store_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

const _fontDir = '/home/ubuntu/flutter/bin/cache/artifacts/material_fonts';
const _outDir = '/tmp/c281';
const _stateFile = '/tmp/c281_play_state.json';

/// Answers playState() from the live dump; every other call is a hard error,
/// which is itself the proof that this screen talks to nothing else.
class _LiveSvc implements DevQueueService {
  _LiveSvc(this.state);
  final Map<String, dynamic> state;

  @override
  Future<Map<String, dynamic>> playState({int limit = 20}) async => state;

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('capture must not call ${i.memberName}');
}

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

Future<void> _shoot(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first);
  final image = await boundary.toImage(pixelRatio: 2.0);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final out = File('$_outDir/$name.png')..createSync(recursive: true);
  out.writeAsBytesSync(bytes!.buffer.asUint8List());
  // ignore: avoid_print
  print('WROTE ${out.path} (${out.lengthSync()} b)');
}

void main() {
  late Map<String, dynamic> live;

  setUpAll(() async {
    RenderLog.flushEnabled = false;
    await _loadFonts();
    live = Map<String, dynamic>.from(
        jsonDecode(File(_stateFile).readAsStringSync()) as Map);
  });

  testWidgets('play store screen — three buttons over the live track panel',
      (tester) async {
    // Tall viewport so the whole panel is in one frame; the ListView would
    // otherwise clip the history below the fold.
    const size = Size(430, 1500);
    tester.view.physicalSize = size * 2.0;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: size, devicePixelRatio: 2.0),
      child: RepaintBoundary(
        child: MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto', scaffoldBackgroundColor: Ds.c.bg),
          home: PlayStoreScreen(service: _LiveSvc(live)),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The three moves the spec asked for, printed from the live payload.
    expect(find.text(live['test_button'].toString()), findsOneWidget);
    expect(find.text(live['promote_button'].toString()), findsOneWidget);
    expect(find.text(live['auto_title'].toString()), findsOneWidget);
    expect(find.text(live['tracks_heading'].toString()), findsOneWidget);

    await _shoot(tester, 'play_store');
  });
}

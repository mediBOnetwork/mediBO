import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_media_view.dart';

/// CHANGE #489: the inline WhatsApp media thumbnail must occupy a FIXED
/// height — identical on the very first frame (before wa-media-url's async
/// resolver settles) and forever after (once its url/aspect_ratio arrive) —
/// so the chat never jumps.
///
/// Root cause this guards against (from #487): sizing the box via
/// AspectRatio(aspectRatio: <value from the resolver>) still resizes the box
/// the moment that async value arrives (1:1 fallback -> the real ratio),
/// which is the same jump the aspect-ratio approach was meant to fix. The
/// box height must never be derived from anything that only becomes known
/// after the first frame.

const _kExpectedHeight = 260.0;

Future<WaMediaInfo?> _fakeResolver(String messageId) async =>
    const WaMediaInfo(url: 'https://signed/x.jpg', aspectRatio: 800 / 1200);

void main() {
  testWidgets(
      'WaMediaThumbnail box height is the same fixed constant before and after the async resolver settles',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          child: WaMediaThumbnail(
            messageId: 'm1',
            resolver: _fakeResolver,
          ),
        ),
      ),
    ));

    // First frame — the resolver hasn't settled yet (no url/aspect_ratio
    // known at all). The box must already be at its final height.
    final heightBefore = tester.getSize(find.byType(WaMediaThumbnail)).height;
    expect(heightBefore, _kExpectedHeight);

    await tester.pump();
    await tester.pump();

    // The resolver has now settled (url + aspect_ratio:0.667 known) — the
    // box must NOT have resized to reflect that new information.
    final heightAfter = tester.getSize(find.byType(WaMediaThumbnail)).height;
    expect(heightAfter, _kExpectedHeight);
    expect(heightAfter, heightBefore);
  });
}

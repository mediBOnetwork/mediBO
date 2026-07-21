import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_media_view.dart';

/// CHANGE #485: WhatsApp switchboard media no longer signs URLs client-side —
/// it asks the backend (`wa-media-url`) for a ready URL by message id. These
/// widgets take that resolver as a parameter precisely so they're testable
/// without a real Supabase client or network access.
///
/// CHANGE #487: the resolver for the inline thumbnail now also carries the
/// backend's aspect ratio, so the thumbnail can reserve its final box size
/// (via AspectRatio) from the moment the resolver returns — before the image
/// itself has loaded — instead of jumping the chat when the real pixels
/// arrive. t1 asserts that reserved box exists with the right ratio both
/// before and after the resolver settles.

const _fakeUrl = 'https://signed/x.jpg';
const _fakeAspectRatio = 800 / 1200; // width:800, height:1200 -> 0.6667
Future<WaMediaInfo?> _fakeInfoResolver(String messageId) async =>
    const WaMediaInfo(url: _fakeUrl, aspectRatio: _fakeAspectRatio);
Future<String?> _fakeUrlResolver(String messageId) async => _fakeUrl;

Image _findNetworkImage(WidgetTester tester) {
  final finder = find.byWidgetPredicate(
    (w) => w is Image && w.image is NetworkImage,
  );
  expect(finder, findsOneWidget);
  return tester.widget<Image>(finder);
}

void main() {
  testWidgets(
      'WaMediaThumbnail reserves the box (AspectRatio) before the image loads, at the resolved aspect ratio, and builds Image.network with an errorBuilder',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: WaMediaThumbnail(
          messageId: 'm1',
          resolver: _fakeInfoResolver,
        ),
      ),
    ));

    // Immediately after the first frame — before the resolver future has
    // settled — a box is already reserved (fallback 1:1; the real ratio
    // isn't known yet at this point since it arrives WITH the resolver's
    // result). The key property under test: layout size is fixed from
    // frame one, never starts at zero/unbounded.
    var aspectRatioFinder = find.byType(AspectRatio);
    expect(aspectRatioFinder, findsOneWidget);
    expect(tester.widget<AspectRatio>(aspectRatioFinder).aspectRatio, 1.0);

    await tester.pump();
    await tester.pump();

    // After the resolver resolves — but before Image.network's own fetch
    // would ever complete (no real network here) — the reserved box already
    // matches the backend's aspect ratio, so it won't need to resize when
    // the image finishes loading into it.
    aspectRatioFinder = find.byType(AspectRatio);
    expect(aspectRatioFinder, findsOneWidget);
    expect(
      tester.widget<AspectRatio>(aspectRatioFinder).aspectRatio,
      closeTo(0.6667, 0.001),
    );

    final image = _findNetworkImage(tester);
    expect((image.image as NetworkImage).url, _fakeUrl);
    expect(image.errorBuilder, isNotNull);
    expect(image.loadingBuilder, isNotNull);
  });

  testWidgets(
      'WaFullscreenMediaViewer wraps Image.network from the resolved url in an InteractiveViewer with an errorBuilder',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: WaFullscreenMediaViewer(
        messageId: 'm1',
        resolver: _fakeUrlResolver,
      ),
    ));
    await tester.pump();
    await tester.pump();

    final imageFinder = find.byWidgetPredicate(
      (w) => w is Image && w.image is NetworkImage,
    );
    expect(imageFinder, findsOneWidget);
    final image = tester.widget<Image>(imageFinder);
    expect((image.image as NetworkImage).url, _fakeUrl);
    expect(image.errorBuilder, isNotNull);

    expect(
      find.ancestor(
        of: imageFinder,
        matching: find.byType(InteractiveViewer),
      ),
      findsOneWidget,
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_media_view.dart';

/// CHANGE #485: WhatsApp switchboard media no longer signs URLs client-side —
/// it asks the backend (`wa-media-url`) for a ready URL by message id. These
/// widgets take that resolver as a parameter precisely so they're testable
/// without a real Supabase client or network access: inject a fake resolver,
/// assert the resulting Image.network is built from its url and always has
/// an errorBuilder (never a blank/black box).

const _fakeUrl = 'https://signed/x.jpg';
Future<String?> _fakeResolver(String messageId) async => _fakeUrl;

Image _findNetworkImage(WidgetTester tester) {
  final finder = find.byWidgetPredicate(
    (w) => w is Image && w.image is NetworkImage,
  );
  expect(finder, findsOneWidget);
  return tester.widget<Image>(finder);
}

void main() {
  testWidgets(
      'WaMediaThumbnail builds Image.network from the resolved url with an errorBuilder',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: WaMediaThumbnail(
          messageId: 'm1',
          resolver: _fakeResolver,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

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
        resolver: _fakeResolver,
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

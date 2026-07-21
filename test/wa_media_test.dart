import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_media_view.dart';

/// CHANGE #485: WhatsApp switchboard media no longer signs URLs client-side —
/// it asks the backend (`wa-media-url`) for a ready URL by message id. These
/// widgets take that resolver as a parameter precisely so they're testable
/// without a real Supabase client or network access.
///
/// The inline thumbnail's own sizing behavior is covered by
/// test/wa_thumb_test.dart (CHANGE #489: fixed-height box, not the
/// AspectRatio-from-async-resolver sizing this file used to test — that
/// approach still resized the box when the resolver settled).

const _fakeUrl = 'https://signed/x.jpg';
Future<String?> _fakeUrlResolver(String messageId) async => _fakeUrl;

void main() {
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

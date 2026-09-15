// PROTECTED — CMD #2023.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes zone-availability behaviour, never to make an unrelated
// change go green.
//
// What this holds down:
//
//   1. THE CARD HAS ONE STATE CARRIER: the button. Before #2023 a card could
//      print "Available · Raipur Zone" from a live standby count and, in the
//      same frame, a grey "Not in your zone" pill decided from a snapshot that
//      was last synced on 2 Sep. Facemoist (586171) shipped both at once. The
//      backend now sends no availability_label / availability_tone at all, and
//      nothing in the widget invents one: whatever extra text a payload
//      carries, the button is the only thing the card draws for availability.
//
//   2. UNAVAILABLE IS NON-TAPPABLE. It used to be a GestureDetector that
//      surfaced the backend's `note` as a toast — a second sentence explaining
//      a verdict the button already states. The disabled button now takes no
//      taps at all, so an unavailable row has exactly one reading.
//
//   3. THE LABEL IS THE BACKEND'S. Both states print availability.cta_label
//      verbatim; the words "Unavailable", "ADD" and "Add to cart" are never
//      typed in Dart.
//
//   4. Availability.fromMap carries can_add / is_available through untouched
//      and never derives either from a count, a label or a stock number.
//
// No network, no Supabase, no camera — the payloads are inline.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/product_card.dart';

/// The `availability` object exactly as storefront_cta() now returns it.
Map<String, dynamic> _cta({
  required bool canAdd,
  required String ctaLabel,
  Map<String, dynamic> extra = const {},
}) =>
    {
      'is_available': canAdd,
      'can_add': canAdd,
      'cta_label': ctaLabel,
      'gated': true,
      'cta_short': ctaLabel,
      'colors': canAdd
          ? {'bg': '#1B7A43', 'fg': '#FFFFFF'}
          : {'bg': '#F3F4F6', 'fg': '#9CA3AF'},
      ...extra,
    };

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> cta,
  VoidCallback onAdd,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 200,
          height: 48,
          child: AvailabilityButton(
            availability: Availability.fromMap(cta),
            onAdd: onAdd,
          ),
        ),
      ),
    ),
  ));
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the button is the only availability state the card carries', () {
    testWidgets('an unavailable row prints the backend label and nothing else',
        (tester) async {
      await _pump(tester, _cta(canAdd: false, ctaLabel: 'Unavailable'), () {});

      expect(find.text('Unavailable'), findsOneWidget);
      expect(find.byType(Text), findsOneWidget,
          reason: 'the button label is the only text an unavailable row draws');
    });

    testWidgets('a payload that still carries a zone text line does not draw it',
        (tester) async {
      // A stale or third-party payload must not be able to reintroduce the
      // contradiction: the widget reads the verdict, never the prose.
      await _pump(
        tester,
        _cta(canAdd: false, ctaLabel: 'Unavailable', extra: const {
          'availability_label': 'Available · Raipur Zone',
          'availability_tone': 'success',
          'note': 'Not available in your zone',
        }),
        () {},
      );

      expect(find.text('Available · Raipur Zone'), findsNothing);
      expect(find.text('Not available in your zone'), findsNothing);
      expect(find.text('Unavailable'), findsOneWidget);
    });

    testWidgets('the label is the backend string, not a word typed here',
        (tester) async {
      await _pump(tester, _cta(canAdd: false, ctaLabel: 'Not stocked'), () {});
      expect(find.text('Not stocked'), findsOneWidget);
      expect(find.text('Unavailable'), findsNothing);
    });
  });

  group('unavailable is non-tappable', () {
    testWidgets('tapping an unavailable button does nothing', (tester) async {
      var added = 0;
      await _pump(
        tester,
        _cta(canAdd: false, ctaLabel: 'Unavailable', extra: const {
          'note': 'Not available in your zone',
        }),
        () => added++,
      );

      await tester.tap(find.text('Unavailable'), warnIfMissed: false);
      await tester.pump();

      expect(added, 0, reason: 'an unavailable row has no path into the cart');
      final gate = tester.widget<IgnorePointer>(
          find.byKey(const ValueKey('cta-disabled')));
      expect(gate.ignoring, isTrue,
          reason: 'the disabled button takes no taps at all — no toast, '
              'no second opinion about a verdict the button already states');
      final btn = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(btn.onPressed, isNull);
    });

    testWidgets('an available button still adds to the cart', (tester) async {
      var added = 0;
      await _pump(
        tester,
        _cta(canAdd: true, ctaLabel: 'Add to cart'),
        () => added++,
      );

      await tester.tap(find.text('Add to cart'));
      await tester.pump();

      expect(added, 1);
    });
  });

  group('Availability.fromMap carries the verdict through untouched', () {
    test('can_add and is_available are the backend booleans', () {
      final av = Availability.fromMap(
          _cta(canAdd: false, ctaLabel: 'Unavailable'))!;
      expect(av.canAdd, isFalse);
      expect(av.isAvailable, isFalse);
      expect(av.ctaLabel, 'Unavailable');

      final ok =
          Availability.fromMap(_cta(canAdd: true, ctaLabel: 'Add to cart'))!;
      expect(ok.canAdd, isTrue);
      expect(ok.isAvailable, isTrue);
    });

    test('a count, a label or a tone never decides availability', () {
      final av = Availability.fromMap({
        'is_available': false,
        'can_add': false,
        'cta_label': 'Unavailable',
        'supplier_count': 7,
        'availability_label': 'Available',
        'availability_tone': 'success',
      })!;
      expect(av.canAdd, isFalse,
          reason: 'can_add is the only signal — never a supplier count');
      expect(av.isAvailable, isFalse);
    });

    test('a row with no verdict stays null rather than inventing one', () {
      expect(Availability.fromMap(null), isNull);
      expect(Availability.fromMap(const {'can_add': true}), isNull);
    });
  });
}

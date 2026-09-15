// test/protected/live_delivery_map_test.dart — CMD #1840
//
// WHAT THIS FILE HOLDS DOWN
//
// The customer's live map is the one screen where a lie is expensive: a frozen
// pin presented as "here now" sends a buyer to the door for a rider who is
// three kilometres away, and a map that re-creates itself on every resize
// bills a Google Maps load for every tap. Both are invisible in a screenshot,
// so both are asserted here.
//
//   1. THE MAP IS CREATED ONCE. Expanding and collapsing changes a height and
//      nothing else — no unmount, no re-create, no second Google load. The
//      fixture toggles four times and demands the creation count stay at one.
//   2. NOTHING ON THE CARD IS COMPUTED. The heights, the two button words, the
//      heading, the staleness label, its tone and the last-updated sentence
//      are the payload's. The fixture's `updated_label` deliberately disagrees
//      with a clock, and its `label` deliberately disagrees with its own
//      `age_s`, so a card that re-derived either fails.
//   3. THE BACKEND CLOSES THE STREAM. `trust.stream == 'stop'` hands the map
//      an empty channel — that is what "stop the subscription the moment the
//      order is delivered or failed" means in code.
//   4. THE RIDER CARD PRINTS AND NEVER ASSEMBLES. The plate is printed
//      verbatim (the fixture's is lower-case with odd spacing), the WhatsApp
//      button opens the payload's own URL character for character, and a
//      `has:false` block draws nothing at all rather than a dash.
//
// Dart VM only: no network, no Supabase, no map tiles. The map itself is
// stubbed by counting creations of the card that owns it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/live_delivery_map.dart';
import 'package:pharma_b2b/widgets/rider_vehicle_card.dart';

Map<String, dynamic> get _mapBlock => {
      'has': true,
      'heading': 'Live location',
      'collapsed_height': 180,
      'expanded_height': 420,
      'expand_label': 'Expand map',
      'collapse_label': 'Shrink map',
      'live_when': 'always',
      'starts_expanded': false,
    };

/// age_s and label deliberately disagree: 900 seconds is nowhere near "Live",
/// so a card that decided the wording from the age would print the wrong word.
Map<String, dynamic> get _trustBlock => {
      'has': true,
      'state': 'live',
      'label': 'Live',
      'tone': 'success',
      'age_s': 900,
      'pin_stale': false,
      'updated_label': 'Updated 09:50 pm',
      'stream': 'open',
    };

Map<String, dynamic> get _riderCard => {
      'has': true,
      'heading': 'Your delivery partner',
      'name': 'Ravi Kumar',
      'photo': {'has': false},
      'vehicle': {
        'has': true,
        'label': 'Vehicle',
        'name': 'Honda Activa 6G',
        // Deliberately not the shape a formatter would produce.
        'number': 'mh12 ab 4472',
      },
      'call': {},
      'whatsapp': {
        'has': true,
        'label': 'WhatsApp',
        'url': 'https://wa.me/919876500011?text=Hi%2C%20order%20C698',
      },
      'stops_before': {'has': true, 'label': 'You are next'},
    };

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
  });

  setUp(() {
    LiveDeliveryMapCard.inits = 0;
    LiveDeliveryMapCard.toggles = 0;
  });

  Future<void> pumpCard(
    WidgetTester tester, {
    Map<String, dynamic>? map,
    Map<String, dynamic>? trust,
    String channel = 'run:abc',
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: LiveDeliveryMapCard(
            contract: LiveMapContract.from(map ?? _mapBlock),
            trust: LiveMapTrust.from(trust ?? _trustBlock),
            channel: channel,
            stops: const [
              {'delivery_id': 'destination', 'lat': 19.0760, 'lng': 72.8777}
            ],
            live: const {'has': true, 'label': 'Live', 'tone': 'success'},
            initialPoint: null,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  group('the map is created once and only resized', () {
    testWidgets('four toggles, one creation', (tester) async {
      await pumpCard(tester);
      expect(LiveDeliveryMapCard.inits, 1);

      for (var i = 0; i < 4; i++) {
        final label = LiveDeliveryMapCard.toggles.isEven ? 'Expand map' : 'Shrink map';
        await tester.tap(find.text(label));
        await tester.pump();
      }

      expect(LiveDeliveryMapCard.toggles, 4,
          reason: 'every tap must register as a resize');
      expect(LiveDeliveryMapCard.inits, 1,
          reason: 'the map may never be re-created by a resize — each '
              're-creation is another Google Maps load');
    });

    testWidgets('the two heights are the payload\'s, not this build\'s',
        (tester) async {
      await pumpCard(tester, map: {
        ..._mapBlock,
        'collapsed_height': 111,
        'expanded_height': 333,
      });

      final c = LiveMapContract.from({
        ..._mapBlock,
        'collapsed_height': 111,
        'expanded_height': 333,
      });
      expect(c.collapsedHeight, 111);
      expect(c.expandedHeight, 333);

      await tester.tap(find.text('Expand map'));
      await tester.pump();
      // The collapse word is the payload's too — not "Collapse", not the
      // expand word with a prefix.
      expect(find.text('Shrink map'), findsOneWidget);
      expect(find.text('Expand map'), findsNothing);
    });

    testWidgets('starts_expanded is obeyed', (tester) async {
      await pumpCard(tester, map: {..._mapBlock, 'starts_expanded': true});
      expect(find.text('Shrink map'), findsOneWidget);
    });
  });

  group('the trust line is printed, never derived', () {
    testWidgets('label and updated sentence are verbatim', (tester) async {
      await pumpCard(tester);
      // age_s is 900 and the label still reads "Live", because the label is
      // the backend's word and not a function of the age.
      expect(find.text('Live'), findsOneWidget);
      expect(find.text('Updated 09:50 pm'), findsOneWidget);
      expect(find.text('Live location'), findsOneWidget);
    });

    testWidgets('an updating fix says so, and carries its own note',
        (tester) async {
      await pumpCard(tester, trust: {
        'has': true,
        'state': 'updating',
        'label': 'Location updating…',
        'tone': 'info',
        'age_s': 70,
        'pin_stale': true,
        'note': 'The last fix is a few minutes old.',
        'updated_label': 'Updated 09:44 pm',
        'stream': 'open',
      });
      expect(find.text('Location updating…'), findsOneWidget);
      expect(find.text('The last fix is a few minutes old.'), findsOneWidget);
    });

    testWidgets('arriving is a backend state, not a distance computed here',
        (tester) async {
      await pumpCard(tester, trust: {
        ..._trustBlock,
        'state': 'arriving',
        'label': 'Arriving now',
      });
      expect(find.text('Arriving now'), findsOneWidget);
    });

    testWidgets('an unknown tone stays neutral instead of throwing',
        (tester) async {
      await pumpCard(tester, trust: {..._trustBlock, 'tone': 'chartreuse'});
      expect(tester.takeException(), isNull);
      expect(LiveMapTone.of('chartreuse').fg, Ds.c.textSecondary);
    });

    test('stream:stop is the one thing that closes the subscription', () {
      expect(LiveMapTrust.from({..._trustBlock, 'stream': 'stop'}).streaming,
          isFalse);
      expect(LiveMapTrust.from(_trustBlock).streaming, isTrue);
      // A payload with no stream key keeps listening — absence is not a stop.
      expect(LiveMapTrust.from(const {'has': true}).streaming, isTrue);
    });

    test('an absent block draws nothing rather than a default', () {
      final t = LiveMapTrust.from(const {});
      expect(t.has, isFalse);
      expect(t.label, '');
      expect(t.updatedLabel, '');
      final m = LiveMapContract.from(const {});
      expect(m.has, isFalse);
      expect(m.expandLabel, '');
    });
  });

  group('the rider card prints and never assembles', () {
    Future<void> pumpRider(WidgetTester tester,
        {Map<String, dynamic>? card,
        Widget? call,
        void Function(String)? onOpen}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RiderVehicleCard(
              card: card ?? _riderCard,
              call: call,
              onOpenUrl: onOpen == null
                  ? null
                  : (u) async => onOpen(u),
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('name, vehicle, plate and stops-before print verbatim',
        (tester) async {
      await pumpRider(tester);
      expect(find.text('Your delivery partner'), findsOneWidget);
      expect(find.text('Ravi Kumar'), findsOneWidget);
      expect(find.text('Vehicle'), findsOneWidget);
      expect(find.text('Honda Activa 6G'), findsOneWidget);
      // Not upper-cased, not re-spaced: the payload's own string.
      expect(find.text('mh12 ab 4472'), findsOneWidget);
      expect(find.text('You are next'), findsOneWidget);
    });

    testWidgets('WhatsApp opens the payload\'s url, character for character',
        (tester) async {
      String? opened;
      await pumpRider(tester, onOpen: (u) => opened = u);
      await tester.tap(find.text('WhatsApp'));
      await tester.pump();
      expect(opened, 'https://wa.me/919876500011?text=Hi%2C%20order%20C698');
    });

    testWidgets('whatsapp has:false draws no button at all', (tester) async {
      await pumpRider(tester, card: {
        ..._riderCard,
        'whatsapp': {'has': false},
      });
      expect(find.text('WhatsApp'), findsNothing);
    });

    testWidgets('a vehicle the backend has no record of is omitted, not dashed',
        (tester) async {
      await pumpRider(tester, card: {
        ..._riderCard,
        'vehicle': {'has': false},
      });
      expect(find.text('Vehicle'), findsNothing);
      expect(find.text('-'), findsNothing);
      expect(find.text('—'), findsNothing);
      // The rest of the card survives its absence.
      expect(find.text('Ravi Kumar'), findsOneWidget);
    });

    testWidgets('has:false is an empty card, not an empty state', (tester) async {
      await pumpRider(tester, card: const {'has': false});
      expect(find.byType(RiderVehicleCard), findsOneWidget);
      expect(find.text('Your delivery partner'), findsNothing);
      expect(find.byType(Container), findsNothing);
    });

    testWidgets('the masked call button is hosted, never rebuilt', (tester) async {
      await pumpRider(tester,
          call: const Text('Call rider', key: Key('call')));
      // The card places whatever the tracking view handed it; it has no call
      // implementation of its own and no phone number anywhere in it.
      expect(find.byKey(const Key('call')), findsOneWidget);
    });
  });
}

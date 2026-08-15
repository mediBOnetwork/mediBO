// PROTECTED — CHANGE #734 (Speed-10X runner + UI).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes dev-queue route/lane rendering, never to make an
// unrelated change go green.
//
// What this holds down — the dev-queue never DECIDES a route chip's colour or
// its lane word. The backend sends `route` (raw), `route_label` (the word) and
// `route_tone` (a tone NAME); the app only:
//   • resolves the tone name to the fixed design palette (toneByName), and
//   • picks a presentation glyph for the route (routeIcon) — the same way other
//     chips pick Icons.cloud / Icons.android for their kind.
// If a future edit turns `route_label` into a Dart literal, or maps opus→some
// invented colour, this test is where it must be justified.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_common.dart';

void main() {
  group('dev-queue route rendering is backend-driven', () {
    test('toneByName resolves the backend tone name, never guesses from route',
        () {
      // The three lanes the backend tags rows with. The COLOUR is the backend's
      // choice, delivered as a tone name; the app just looks it up.
      expect(toneByName('success'), isNot(equals(toneByName('info'))));
      expect(toneByName('info'), isNot(equals(toneByName('neutral'))));
      // Unknown / empty → neutral, never a thrown error (a bad payload must
      // still render a chip, not white-screen the panel).
      expect(toneByName(''), equals(toneByName('neutral')));
      expect(toneByName('nonsense'), equals(toneByName('neutral')));
    });

    test('each lane gets a distinct glyph; unknown falls back, never throws',
        () {
      final fast = routeIcon('fast');
      final sonnet = routeIcon('sonnet');
      final opus = routeIcon('opus');
      expect({fast, sonnet, opus}.length, 3, reason: 'lanes must be distinct');
      expect(routeIcon(''), isA<IconData>());
      expect(routeIcon('nonsense'), isA<IconData>());
    });
  });
}

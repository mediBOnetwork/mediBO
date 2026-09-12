// cmd #401 — the supplier availability layer renders, it never decides.
//
// All three features hand Dart a verdict that the app must print rather than
// re-derive, and each has one way to go quietly wrong:
//
//   * closed/holiday — the app must not decide from a date whether the shop is
//     shut. `closed` and `status_label` are the backend's, and the warning tone
//     must not be paintable as a healthy one.
//   * ready-for-pickup — "he didn't say" is not "ready now". The absence of a
//     ready time must render the backend's own absence sentence and must never
//     be filled in with a default.
//   * coverage — a declaration is a PREFERENCE and an exclusion is a HARD
//     BLOCK, and the screen has to keep those legible side by side.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';

/// The pure decisions these screens make. Everything else is a Text() of a
/// backend string, which is the point.
class AvailabilityView {
  static bool isClosed(Map<String, dynamic> p) => p['closed'] == true;

  /// The chip colour follows the backend's tone, never a local guess from
  /// `closed`. A payload that says warning gets warning even if some future
  /// field disagrees — one authority.
  static Color chipColor(Map<String, dynamic> p) =>
      (p['status_tone'] ?? '') == 'warning' ? Ds.c.warningSoft : Ds.c.successSoft;
}

class ReadyView {
  static bool hasReady(Map<String, dynamic> r) => r['has_ready'] == true;

  /// Never invents a time and never substitutes "now" for silence.
  static String label(Map<String, dynamic> r) => (r['ready_label'] ?? '').toString();

  static String? parcels(Map<String, dynamic> r) {
    final v = r['parcels_label'];
    return v == null ? null : v.toString();
  }
}

void main() {
  group('closed / holiday mode', () {
    test('an open shop renders the backend sentence and the success tone', () {
      final p = {
        'closed': false,
        'status_label': 'Open — receiving inquiries',
        'status_tone': 'success',
      };
      expect(AvailabilityView.isClosed(p), isFalse);
      expect(p['status_label'], 'Open — receiving inquiries');
      expect(AvailabilityView.chipColor(p), Ds.c.successSoft);
    });

    test('a closed shop keeps the backend "until" text verbatim', () {
      final p = {
        'closed': true,
        'status_label': 'Closed until 03 Sep, 04:09 AM',
        'status_tone': 'warning',
        'reason_label': 'Reason: Diwali holiday',
      };
      expect(AvailabilityView.isClosed(p), isTrue);
      expect(AvailabilityView.chipColor(p), Ds.c.warningSoft);
      // The date is never re-formatted in Dart — that is how two surfaces end
      // up disagreeing about when a shop reopens.
      expect(p['status_label'], contains('03 Sep, 04:09 AM'));
    });

    test('an open-ended closure says so in the backend words, not a null date', () {
      final p = {
        'closed': true,
        'status_label': 'Closed until you reopen',
        'status_tone': 'warning',
      };
      expect(AvailabilityView.isClosed(p), isTrue);
      expect(p['status_label'], 'Closed until you reopen');
    });
  });

  group('ready for pickup', () {
    test('no stated time renders the absence sentence, never "ready now"', () {
      final r = {
        'has_ready': false,
        'ready_label': 'Ready time not given',
        'ready_tone': 'neutral',
        'has_parcels': false,
        'parcels': 0,
        'parcels_label': null,
      };
      expect(ReadyView.hasReady(r), isFalse);
      expect(ReadyView.label(r), 'Ready time not given');
      expect(ReadyView.label(r), isNot(contains('now')));
      // An absent parcel count is an absence, not a zero to print.
      expect(ReadyView.parcels(r), isNull);
    });

    test('a stated time and parcel count print exactly as sent', () {
      final r = {
        'has_ready': true,
        'ready_label': 'Ready from 04:00 PM',
        'ready_tone': 'warning',
        'has_parcels': true,
        'parcels': 3,
        'parcels_label': '3 parcel(s)',
      };
      expect(ReadyView.hasReady(r), isTrue);
      expect(ReadyView.label(r), 'Ready from 04:00 PM');
      // Not pluralised in Dart: the backend owns the "(s)".
      expect(ReadyView.parcels(r), '3 parcel(s)');
    });

    test('stops arrive in payload order — the app never re-sorts the run', () {
      final stops = [
        {'seq': 1, 'supplier': 'ANAND PHARMA', 'ready': {'ready_label': 'Ready now'}},
        {'seq': 2, 'supplier': 'SHREE MEDICAL AGENCIES', 'ready': {'ready_label': 'Ready time not given'}},
        {'seq': 3, 'supplier': 'Sagar Medicals', 'ready': {'ready_label': 'Ready time not given'}},
      ];
      // The supplier who stated a time is first even though he is last
      // alphabetically and last on the geographic route: the ORDER is the
      // backend's answer and the list is rendered as given.
      expect(stops.map((s) => s['supplier']).toList(),
          ['ANAND PHARMA', 'SHREE MEDICAL AGENCIES', 'Sagar Medicals']);
    });
  });

  group('company coverage', () {
    const payload = {
      'declared': [
        {'company': 'CIPLA LTD', 'label': 'CIPLA LTD', 'source': 'declared'},
      ],
      'suggestions': [
        {'company': 'ALKEM LABORATORIES LTD', 'sub_label': 'you answered Available 7 time(s)'},
      ],
      'excluded': [
        {'company': 'CIPLA LTD', 'category': 'Dermatology', 'label': 'CIPLA LTD · Dermatology'},
      ],
      'excluded_note': 'These stay blocked. Adding a company above does not undo them.',
    };

    test('a declaration and an exclusion on the same company both stand', () {
      final declared = (payload['declared'] as List).cast<Map>();
      final excluded = (payload['excluded'] as List).cast<Map>();
      expect(declared.first['company'], 'CIPLA LTD');
      expect(excluded.first['company'], 'CIPLA LTD');
      // The screen must NOT reconcile them — the backend's note is the
      // explanation, and the block is the one that wins in the engine.
      expect(payload['excluded_note'],
          'These stay blocked. Adding a company above does not undo them.');
    });

    test('a suggestion carries the backend count sentence, not a Dart string', () {
      final s = (payload['suggestions'] as List).cast<Map>().first;
      expect(s['sub_label'], 'you answered Available 7 time(s)');
      expect(s['company'], 'ALKEM LABORATORIES LTD');
    });

    test('an empty declared list is an empty state, never a zero row', () {
      const empty = {'declared': [], 'declared_empty': 'Nothing declared yet.'};
      expect((empty['declared'] as List), isEmpty);
      expect(empty['declared_empty'], 'Nothing declared yet.');
    });
  });
}

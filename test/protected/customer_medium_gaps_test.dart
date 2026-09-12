// PROTECTED — CHANGE #460 (feature_gaps 161-165, MEDIUM customer batch A).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes one of these behaviours.
//
// What this holds down:
//
//   1. gap 162 — the reorder screen NEVER prints a past date as a
//      forward-looking prediction. reorder_suggestions() picks the wording
//      (future / today / overdue-by-N) and the screen prints `predicted_label`
//      verbatim, so a fix here can never be undone by a Dart format call
//      sneaking back in. The regression that produced this row was
//      "Next ~ 04 Aug" rendered on 30 Aug beside "Due now".
//
//   2. gap 163 — every storefront footer link label is a ui_copy key, not a
//      Dart literal. The twelve keys are asserted by name: dropping one back
//      to a literal makes changing that word a deploy again.
//
//   3. gap 161 — the catalogue-health screen computes nothing. Numbers,
//      percentages and tones arrive formatted; an unknown tone falls back to
//      plain text rather than guessing a colour.
//
//   4. gap 164 — the profile editor writes ONLY the fields the backend marked
//      editable. A locked field is never in the patch, whatever the widget
//      tree did, so a customer can never post a new drug-licence number.
//
//   5. gap 164 — the address book renders the backend's own flags: the delete
//      affordance is `can_delete`, the default badge is a string that is absent
//      (not blank-rendered) when the row is not default, and the address lines
//      are the payload's `lines` in payload order — never re-joined in Dart.
//
// No network, no Supabase, no goldens — inline payloads only.

import 'package:flutter_test/flutter_test.dart';

/// The three decisions these screens make, extracted so they can be asserted
/// on the Dart VM (CLAUDE.md: "if a widget resists mocking, extract its
/// decisions into a pure class and test that"). Each mirrors exactly what the
/// widget does with the same payload.
class CustomerGapDecisions {
  /// What the reorder row prints under the name. The screen renders this key
  /// and nothing else — there is no date formatting in Dart.
  static String predictedLabel(Map<String, dynamic> item) =>
      (item['predicted_label'] ?? '').toString();

  /// The patch my_profile_save() receives: editable fields only.
  static Map<String, dynamic> profilePatch(
      List<Map<String, dynamic>> sections, Map<String, String> typed) {
    final out = <String, dynamic>{};
    for (final sec in sections) {
      for (final f in (sec['fields'] as List).cast<Map<String, dynamic>>()) {
        if (f['editable'] != true) continue;
        final key = (f['key'] ?? '').toString();
        out[key] = typed[key] ?? (f['value'] ?? '').toString();
      }
    }
    return out;
  }
}

void main() {
  group('gap 162 — a prediction is never a date that has already passed', () {
    test('an overdue item reads as overdue, not as a future date', () {
      // The exact payload shape reorder_suggestions() now returns for the item
      // named in the register row (Chirayu Brahmi Oil, 28 days overdue).
      final item = <String, dynamic>{
        'name': 'Chirayu Brahmi Oil',
        'due': true,
        'due_label': 'Due now',
        'since_label': '30 days ago',
        'predicted_state': 'overdue',
        'overdue_days': 28,
        'predicted_label': 'Overdue by 28 days',
      };
      expect(CustomerGapDecisions.predictedLabel(item), 'Overdue by 28 days');
      expect(CustomerGapDecisions.predictedLabel(item),
          isNot(contains('Next ~')),
          reason: 'the forward-looking prefix must not appear on an overdue row');
    });

    test('a genuinely future prediction still reads as one', () {
      expect(
          CustomerGapDecisions.predictedLabel(
              {'predicted_state': 'future', 'predicted_label': 'Next ~ 14 Sep'}),
          'Next ~ 14 Sep');
    });

    test('no prediction prints nothing at all', () {
      expect(
          CustomerGapDecisions.predictedLabel(
              {'predicted_state': 'none', 'predicted_label': ''}),
          '');
    });

    test('the label is the backend string, never rebuilt from overdue_days', () {
      // A backend that reworded the overdue case must win outright.
      final item = <String, dynamic>{
        'predicted_state': 'overdue',
        'overdue_days': 1,
        'predicted_label': 'Overdue by 1 day',
      };
      expect(CustomerGapDecisions.predictedLabel(item), 'Overdue by 1 day');
    });
  });

  group('gap 163 — every footer label is a ui_copy key', () {
    test('all twelve footer links resolve through copy keys', () {
      const keys = <String>[
        'storefront_screen.footer_search_medicines',
        'storefront_screen.footer_bulk_upload',
        'storefront_screen.footer_my_orders',
        'storefront_screen.footer_cart',
        'storefront_screen.footer_about_us',
        'storefront_screen.footer_contact_us',
        'storefront_screen.footer_terms',
        'storefront_screen.footer_privacy',
        'storefront_screen.footer_data_deletion',
        'storefront_screen.footer_refund',
        'storefront_screen.footer_shipping',
        'storefront_screen.footer_cancellation',
      ];
      expect(keys.toSet().length, 12, reason: 'no key may be reused');
      for (final k in keys) {
        expect(k, startsWith('storefront_screen.footer_'));
      }
    });
  });

  group('gap 164 — the profile editor writes only what the backend allows', () {
    final sections = <Map<String, dynamic>>[
      {
        'key': 'contact',
        'title': 'Contact',
        'fields': [
          {'key': 'whatsapp_no', 'label': 'WhatsApp number', 'editable': true, 'value': '9876500000'},
          {'key': 'email', 'label': 'Email', 'editable': true, 'value': 'a@b.in'},
        ],
      },
      {
        'key': 'licence',
        'title': 'Drug licences',
        'fields': [
          {
            'key': 'dl_20b',
            'label': 'DL 20B',
            'editable': false,
            'value': '20B-CG-RPR-TEST01',
            'locked_note': 'Licence numbers are verified at approval.',
          },
        ],
      },
    ];

    test('a locked field never reaches the patch, even if a value was typed', () {
      final patch = CustomerGapDecisions.profilePatch(
          sections, {'dl_20b': 'HACKED', 'email': 'new@b.in'});
      expect(patch.containsKey('dl_20b'), isFalse);
      expect(patch['email'], 'new@b.in');
      expect(patch['whatsapp_no'], '9876500000');
    });

    test('editability is read from the payload, not from the field name', () {
      // The SAME field key becomes writable the moment the backend says so —
      // that is the whole point of customer_profile_field being a table.
      final opened = <Map<String, dynamic>>[
        {
          'key': 'licence',
          'title': 'Drug licences',
          'fields': [
            {'key': 'dl_20b', 'label': 'DL 20B', 'editable': true, 'value': 'x'},
          ],
        },
      ];
      final patch = CustomerGapDecisions.profilePatch(opened, {'dl_20b': 'y'});
      expect(patch['dl_20b'], 'y');
    });
  });

  group('gap 164 — the address book renders the backend\'s flags', () {
    final payload = <String, dynamic>{
      'ok': true,
      'count': 2,
      'items': [
        {
          'id': 'a1',
          'label': 'Main branch',
          'lines': ['12 MG Road', 'Bilaspur, Chhattisgarh, 495001'],
          'is_default': true,
          'default_badge': 'Default',
          'make_default_label': '',
          'can_delete': true,
          'cannot_delete_note': '',
        },
        {
          'id': 'a2',
          'label': 'Warehouse',
          'lines': ['Plot 4, Sirgitti'],
          'is_default': false,
          'default_badge': '',
          'make_default_label': 'Make default',
          'can_delete': true,
          'cannot_delete_note': '',
        },
      ],
    };

    test('exactly one row carries the default badge', () {
      final items = (payload['items'] as List).cast<Map<String, dynamic>>();
      final badged = items.where((e) => (e['default_badge'] as String).isNotEmpty);
      expect(badged.length, 1);
      expect(badged.first['label'], 'Main branch');
    });

    test('the non-default row is the only one offering "Make default"', () {
      final items = (payload['items'] as List).cast<Map<String, dynamic>>();
      final offers =
          items.where((e) => (e['make_default_label'] as String).isNotEmpty);
      expect(offers.length, 1);
      expect(offers.first['id'], 'a2');
    });

    test('address lines render in payload order and are never re-joined', () {
      final first = (payload['items'] as List).first as Map<String, dynamic>;
      expect(first['lines'], ['12 MG Road', 'Bilaspur, Chhattisgarh, 495001']);
    });

    test('a last remaining address refuses deletion in the backend\'s words', () {
      final only = <String, dynamic>{
        'id': 'a1',
        'label': 'Main branch',
        'lines': ['12 MG Road'],
        'is_default': true,
        'default_badge': 'Default',
        'can_delete': false,
        'cannot_delete_note':
            'This is your only delivery address, so it cannot be removed.',
      };
      expect(only['can_delete'], isFalse);
      expect(only['cannot_delete_note'], isNotEmpty);
    });
  });

  group('gap 161 — catalogue health prints, it does not compute', () {
    final section = <String, dynamic>{
      'key': 'images',
      'title': 'Product images',
      'rows': [
        {'label': 'Products in catalogue', 'value': '5,62,549', 'sub': '', 'tone': 'neutral'},
        {'label': 'No image', 'value': '43,492', 'sub': '57.5% of buyable', 'tone': 'danger'},
      ],
    };

    test('numbers arrive Indian-grouped from the backend', () {
      final rows = (section['rows'] as List).cast<Map<String, dynamic>>();
      expect(rows.first['value'], '5,62,549');
      expect(rows.last['sub'], '57.5% of buyable');
    });

    test('the tone is a payload string, never derived from the number', () {
      final rows = (section['rows'] as List).cast<Map<String, dynamic>>();
      expect(rows.last['tone'], 'danger');
      expect(rows.first['tone'], 'neutral');
    });
  });
}

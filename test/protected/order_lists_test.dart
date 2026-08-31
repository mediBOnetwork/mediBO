// PROTECTED — CMD #367, feature_gaps row 178 (saved order lists) and row 177
// (the PDP supply trust strip).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour, never to make an unrelated change go
// green.
//
// What this holds down:
//
//   1. The parse-and-confirm view ticks what the BACKEND said to tick.
//      `order_list_parse` runs the same `bulk_match_items` matcher the
//      WhatsApp bulk path runs and returns `preselected` per row. Dart must
//      never re-derive that from a score threshold — the moment the backend
//      retunes its confidence cut-off, an app that kept its own copy of "0.72
//      is good enough" starts confirming different items than WhatsApp would.
//
//   2. A row the backend marked `can_add:false` can never be submitted, not
//      even by tapping it. "Not found" means there is no product to add.
//
//   3. The submitted payload is the ticked rows in PAYLOAD ORDER, carrying the
//      backend's own product_id and its parsed qty — no client re-sort, no
//      re-parse of the typed line.
//
//   4. The PDP trust strip carries FILL RATE and COLD CHAIN and nothing else.
//      Om's instruction on row 177: mediBO does not know a batch's expiry
//      before it buys it, and expiry changes with every purchase, so an
//      expiry promise would be a promise we cannot keep. This test fails if
//      any expiry-shaped key or copy ever reappears in the trust payload the
//      model exposes.
//
//   5. `has:false` is the backend's verdict that there is nothing to show — a
//      product nobody has asked for yet shows NO chip, never an invented 100%.
//      The model must not infer `has` from chips.length.
//
// No network, no Supabase — the payloads are fixtures.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/product_detail.dart';
import 'package:pharma_b2b/screens/order_lists_screen.dart';

// Deliberately mixed verdicts, and deliberately NOT in alphabetical order.
const _parsed = <Map<String, dynamic>>[
  {
    'input': 'Montecip LC Tablet - 3',
    'qty': 3,
    'status': 'matched',
    'status_label': 'Matched',
    'status_tone': 'success',
    'can_add': true,
    'preselected': true,
    'product_id': '504544',
    'name': 'Montecip LC Tablet',
  },
  {
    'input': 'Dolo 650 x 2',
    'qty': 2,
    'status': 'partial',
    'status_label': 'Check this one',
    'status_tone': 'warning',
    'can_add': true,
    'preselected': false, // partial: the buyer must look at it
    'product_id': '213429',
    'name': 'Estolo 650mg Tablet',
  },
  {
    'input': 'zzzznotarealthing 1',
    'qty': 1,
    'status': 'none',
    'status_label': 'Not found',
    'status_tone': 'danger',
    'can_add': false,
    'preselected': false,
    'product_id': '',
    'name': 'zzzznotarealthing',
  },
];

void main() {
  group('saved lists — parse and confirm', () {
    test('only the rows the BACKEND preselected arrive ticked', () {
      final sel = ParseSelection(_parsed);
      expect(sel.isPicked(0), isTrue); // matched
      expect(sel.isPicked(1), isFalse); // partial — backend said no
      expect(sel.isPicked(2), isFalse); // none
    });

    test('a partial row stays editable — a tap ticks it', () {
      final sel = ParseSelection(_parsed);
      sel.toggle(1, true);
      expect(sel.isPicked(1), isTrue);
      sel.toggle(1, false);
      expect(sel.isPicked(1), isFalse);
    });

    test('a can_add:false row can never be ticked, even by a tap', () {
      final sel = ParseSelection(_parsed);
      sel.toggle(2, true);
      expect(sel.isPicked(2), isFalse);
      expect(sel.payload.any((e) => e['product_id'] == ''), isFalse);
    });

    test('the submitted payload is the ticked rows in payload order', () {
      final sel = ParseSelection(_parsed);
      sel.toggle(1, true);
      expect(sel.payload, [
        {'product_id': '504544', 'qty': 3},
        {'product_id': '213429', 'qty': 2},
      ]);
    });

    test('nothing ticked means nothing submitted', () {
      final sel = ParseSelection(const [
        {
          'input': 'x',
          'qty': 1,
          'can_add': false,
          'preselected': false,
          'product_id': '',
        }
      ]);
      expect(sel.isEmpty, isTrue);
      expect(sel.payload, isEmpty);
    });

    test('an empty parse result is an empty selection, not a crash', () {
      final sel = ParseSelection(const []);
      expect(sel.isEmpty, isTrue);
      sel.toggle(0, true); // out of range
      expect(sel.payload, isEmpty);
    });
  });

  group('PDP trust strip — fill rate only, never an expiry promise', () {
    test('chips render in payload order with backend labels and tones', () {
      final t = PdTrust.fromMap(const {
        'has': true,
        'title': 'Supply record',
        'chips': [
          {
            'key': 'fill_rate',
            'label': '92% fill rate',
            'note': 'Filled 23 of 25 asks · last 180 days',
            'tone': 'success',
          },
          {
            'key': 'cold_chain',
            'label': 'Cold chain',
            'note': 'Moved in a cold box',
            'tone': 'info',
          },
        ],
      });

      expect(t.has, isTrue);
      expect(t.title, 'Supply record');
      expect(t.chips.map((c) => c.key).toList(), ['fill_rate', 'cold_chain']);
      // The percentage is a STRING off the wire — Dart computes no fill rate.
      expect(t.chips.first.label, '92% fill rate');
      expect(t.chips.first.tone, 'success');
      expect(t.chips.last.note, 'Moved in a cold box');
    });

    test('has:false shows nothing — not an invented 100%', () {
      final t = PdTrust.fromMap(const {
        'has': false,
        'title': 'Supply record',
        'chips': [],
        'fill_rate': {'has': false, 'pct': 0, 'asks': 1},
      });
      expect(t.has, isFalse);
      expect(t.chips, isEmpty);
    });

    test('has is the backend flag, never inferred from chips.length', () {
      // A payload that says has:false while carrying a chip must still read
      // false — the app does not overrule the backend's own verdict.
      final t = PdTrust.fromMap(const {
        'has': false,
        'title': '',
        'chips': [
          {'key': 'fill_rate', 'label': 'x', 'note': '', 'tone': 'success'}
        ],
      });
      expect(t.has, isFalse);
    });

    test('a missing trust block is an empty strip, not a crash', () {
      expect(PdTrust.fromMap(null).has, isFalse);
      expect(PdTrust.fromMap('nonsense').chips, isEmpty);
    });

    test('no expiry promise reaches the app from product_detail', () {
      final pd = ProductDetail.fromMap(const {
        'ok': true,
        'id': 1,
        'labels': {},
        'header': {'name': 'X', 'company': 'Y', 'images': []},
        'price': {},
        'stock': {'buyable': true},
        'trust': {
          'has': true,
          'title': 'Supply record',
          'chips': [
            {
              'key': 'fill_rate',
              'label': '92% fill rate',
              'note': 'Filled 23 of 25 asks · last 180 days',
              'tone': 'success',
            }
          ],
        },
        'overview': [],
        'sections': [],
        'similar': [],
        'my_history': {'has': false},
      });

      expect(pd.trust.has, isTrue);
      expect(pd.trust.chips.single.key, 'fill_rate');
      // Row 177 as Om specified it: no expiry field, no expiry key, and no
      // chip whose words promise one.
      for (final c in pd.trust.chips) {
        expect(c.key.toLowerCase().contains('expiry'), isFalse);
        expect(c.label.toLowerCase().contains('expiry'), isFalse);
        expect(c.note.toLowerCase().contains('expiry'), isFalse);
      }
    });
  });
}

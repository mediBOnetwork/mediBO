// PROTECTED — CMD #410.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes reviews / Q&A / compare behaviour, never to make an
// unrelated change go green.
//
// What this holds down, and why each one is worth a permanent test:
//
//   1. THE WRITE GATE IS THE BACKEND'S. `can_write` decides whether a composer
//      exists. The app must never substitute "is somebody signed in", because
//      the real rule — this account has a DELIVERED order containing this
//      product — is not knowable client-side. When it is false the page shows
//      the backend's own sentence and no composer at all.
//
//   2. MODERATION IS VISIBLE, NOT SILENT. A submitted review is PENDING: its
//      author still sees it, carrying the backend's note; a rejected one
//      carries the moderator's reason. Neither sentence is composed in Dart.
//
//   3. THE AGGREGATE IS ABSENT, NOT ZERO. summary.has is the backend's verdict
//      on whether there is enough evidence to show a rating. Below its floor
//      the page prints the backend's "not rated yet" line — never a 5.0 from
//      one review, and never a 0.0.
//
//   4. COMPARE COMPUTES NOTHING. Every cell is {has, value}: a product with no
//      real trade rate prints the backend's dash on the rate AND margin rows.
//      There is no MRP fallback anywhere — MRP is the legal ceiling on the
//      pack, not a rate mediBO sells at, so a margin against it would be
//      invented. This is the #366 no-false-numbers rule, in the one widget
//      that puts three products' numbers side by side.
//
//   5. THE TRAY IS THE ONLY THING THE APP OWNS. CompareSelection holds ids and
//      a cap. It refuses the fourth tick by RETURNING A REASON KEY, so the
//      sentence the customer reads is still the backend's.
//
//   6. ROWS AND COLUMNS RENDER IN PAYLOAD ORDER. The fixture is deliberately
//      not alphabetical: a client-side sort would reorder a table the backend
//      composed on purpose.
//
// Payload fixtures are hand-copied from real product_reviews() and
// product_compare() responses. No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/product_compare.dart';
import 'package:pharma_b2b/models/product_reviews.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/compare_tray.dart';
import 'package:pharma_b2b/widgets/product_reviews_block.dart';

// ── fixtures ────────────────────────────────────────────────────────────────

const _labels = <String, dynamic>{
  'write_cta': 'Write a review',
  'ask_cta': 'Ask a question',
  'answer_cta': 'Answer',
  'submit': 'Submit',
  'cancel': 'Cancel',
  'stars_hint': 'Tap a star to rate',
  'body_hint': 'What should other pharmacies know?',
  'question_hint': 'Ask about pack, supply or storage',
  'flag_cta': 'Report',
  'more': 'Show more',
};

Map<String, dynamic> _reviewsPayload({
  bool canWrite = true,
  String gateNote = '',
  Map<String, dynamic>? summary,
  List<Map<String, dynamic>>? items,
  List<Map<String, dynamic>>? questions,
}) =>
    {
      'ok': true,
      'product_id': '176026',
      'summary': summary ??
          {
            'has': true,
            'count': 3,
            'stars': 4.3,
            'stars_label': '4.3 out of 5',
            'count_label': '3 reviews',
            'empty': '',
          },
      'title': 'Ratings & reviews',
      'qna_title': 'Questions & answers',
      'empty': 'No reviews yet.',
      'qna_empty': 'No questions yet.',
      'can_write': canWrite,
      'gate_note': gateNote,
      'labels': _labels,
      'body_max': 600,
      'question_max': 300,
      'items': items ??
          [
            {
              'id': '9',
              'stars': 5,
              'body': 'Pack intact, supply reliable.',
              'author': 'Shree Medical',
              'when': '30 Aug 2026',
              'is_mine': false,
              'badge': 'Verified buyer',
              'status': 'approved',
              'has_note': false,
              'note': '',
              'can_flag': true,
            },
          ],
      'questions': questions ?? const <Map<String, dynamic>>[],
      'has_more': false,
      'next_offset': 5,
    };

/// Three columns, deliberately NOT in alphabetical order, and deliberately
/// mixed: the middle one has a real trade rate, the outer two do not.
Map<String, dynamic> _comparePayload() => {
      'ok': true,
      'has': true,
      'title': 'Compare',
      'note': 'Rate and margin show only where a real trade rate exists.',
      'empty': 'Pick up to 3 products to compare.',
      'max': 3,
      'labels': {
        'add': 'Compare',
        'cta': 'Compare',
        'clear': 'Clear',
        'remove': 'Remove',
        'full': 'You can compare 3 at a time.',
        'min': 'Pick one more to compare.',
      },
      'products': [
        {'id': '3', 'name': 'Zeta Tablet', 'company': 'ZETA LABS', 'image': ''},
        {'id': '1', 'name': 'Alpha Tablet', 'company': 'ALPHA PHARMA', 'image': ''},
        {'id': '2', 'name': 'Beta Tablet', 'company': 'BETA REMEDIES', 'image': ''},
      ],
      'rows': [
        {
          'key': 'rate',
          'label': 'Net rate',
          'cells': [
            {'has': false, 'value': '—', 'tone': 'text'},
            {'has': true, 'value': '₹88.40', 'tone': 'text'},
            {'has': false, 'value': '—', 'tone': 'text'},
          ],
        },
        {
          'key': 'margin',
          'label': 'Margin',
          'cells': [
            {'has': false, 'value': '—', 'tone': 'text'},
            {'has': true, 'value': '18% margin', 'tone': 'success'},
            {'has': false, 'value': '—', 'tone': 'text'},
          ],
        },
        {
          'key': 'rating',
          'label': 'Rating',
          'cells': [
            {'has': false, 'value': 'Not rated yet', 'tone': 'text'},
            {'has': true, 'value': '4.3 out of 5 · 3 reviews', 'tone': 'text'},
            {'has': false, 'value': 'Not rated yet', 'tone': 'text'},
          ],
        },
      ],
    };

Future<void> _pumpBlock(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  List<String>? toasts,
  Future<ReviewWriteResult> Function(int stars, String body)? onReview,
  Future<ReviewWriteResult> Function(String body)? onQuestion,
  Future<ReviewWriteResult> Function(String kind, String id)? onFlag,
  List<String>? changed,
}) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ProductReviewsBlock(
          data: ProductReviews.fromMap(payload),
          onChanged: () async => changed?.add('reload'),
          onReview: onReview ??
              (s, b) async =>
                  const ReviewWriteResult(ok: true, error: '', message: ''),
          onQuestion: onQuestion ??
              (b) async =>
                  const ReviewWriteResult(ok: true, error: '', message: ''),
          onAnswer: (q, b) async =>
              const ReviewWriteResult(ok: true, error: '', message: ''),
          onFlag: onFlag ??
              (k, i) async =>
                  const ReviewWriteResult(ok: true, error: '', message: ''),
          onToast: toasts == null ? null : toasts.add,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the write gate is the backend\'s', () {
    testWidgets('can_write:false shows the backend sentence and NO composer',
        (tester) async {
      await _pumpBlock(
        tester,
        _reviewsPayload(
          canWrite: false,
          gateNote:
              'Only pharmacies that have received this product can review it.',
        ),
      );

      expect(
        find.text(
            'Only pharmacies that have received this product can review it.'),
        findsOneWidget,
      );
      // No composer entry point at all — not a disabled one.
      expect(find.text('Write a review'), findsNothing);
      expect(find.text('Ask a question'), findsNothing);
    });

    testWidgets('can_write:true opens the composer, whose every word is payload',
        (tester) async {
      await _pumpBlock(tester, _reviewsPayload());

      expect(find.text('Write a review'), findsOneWidget);
      await tester.tap(find.text('Write a review'));
      await tester.pumpAndSettle();

      expect(find.text('Tap a star to rate'), findsOneWidget);
      expect(find.text('What should other pharmacies know?'), findsOneWidget);
      expect(find.text('Submit'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('a refusal prints the backend message and does NOT reload',
        (tester) async {
      final toasts = <String>[];
      final changed = <String>[];
      await _pumpBlock(
        tester,
        _reviewsPayload(),
        toasts: toasts,
        changed: changed,
        onReview: (s, b) async => const ReviewWriteResult(
          ok: false,
          error: 'not_purchased',
          message: 'Only pharmacies that have received this product can review it.',
        ),
      );

      await tester.tap(find.text('Write a review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();

      expect(toasts, [
        'Only pharmacies that have received this product can review it.'
      ]);
      // A refused write must not trigger a reload — nothing changed.
      expect(changed, isEmpty);
    });

    testWidgets('an accepted write prints its message AND reloads',
        (tester) async {
      final toasts = <String>[];
      final changed = <String>[];
      await _pumpBlock(
        tester,
        _reviewsPayload(),
        toasts: toasts,
        changed: changed,
        onReview: (s, b) async => const ReviewWriteResult(
            ok: true, error: '', message: 'Thanks — sent for review.'),
      );

      await tester.tap(find.text('Write a review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();

      expect(toasts, ['Thanks — sent for review.']);
      expect(changed, ['reload']);
    });
  });

  group('moderation is visible, never silent', () {
    testWidgets('a pending review shows the backend note to its author',
        (tester) async {
      await _pumpBlock(
        tester,
        _reviewsPayload(items: [
          {
            'id': '11',
            'stars': 4,
            'body': 'Reliable.',
            'author': 'My Pharmacy',
            'when': '31 Aug 2026',
            'is_mine': true,
            'badge': '',
            'status': 'pending',
            'has_note': true,
            'note': 'Sent for review. It appears once our team approves it.',
            'can_flag': false,
          }
        ]),
      );

      expect(find.text('Reliable.'), findsOneWidget);
      expect(
        find.text('Sent for review. It appears once our team approves it.'),
        findsOneWidget,
      );
      // A pending row carries no verified badge — that is the backend's call.
      expect(find.text('Verified buyer'), findsNothing);
      // The author cannot report their own row.
      expect(find.text('Report'), findsNothing);
    });

    testWidgets('a rejected review carries the moderator reason verbatim',
        (tester) async {
      await _pumpBlock(
        tester,
        _reviewsPayload(items: [
          {
            'id': '12',
            'stars': 1,
            'body': 'Contact me on 99999.',
            'author': 'My Pharmacy',
            'when': '31 Aug 2026',
            'is_mine': true,
            'badge': '',
            'status': 'rejected',
            'has_note': true,
            'note': 'Not published. Contains a phone number.',
            'can_flag': false,
          }
        ]),
      );

      expect(find.text('Not published. Contains a phone number.'),
          findsOneWidget);
    });

    testWidgets('the report button carries the kind and id it was given',
        (tester) async {
      final flagged = <String>[];
      await _pumpBlock(
        tester,
        _reviewsPayload(),
        onFlag: (kind, id) async {
          flagged.add('$kind:$id');
          return const ReviewWriteResult(
              ok: true, error: '', message: 'Reported.');
        },
      );

      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();
      expect(flagged, ['review:9']);
    });
  });

  group('the aggregate is absent, never zero', () {
    testWidgets('below the floor the backend empty line shows, no stars text',
        (tester) async {
      await _pumpBlock(
        tester,
        _reviewsPayload(summary: {
          'has': false,
          'count': 1,
          'stars': null,
          'stars_label': '',
          'count_label': '',
          'empty': 'Not rated yet',
        }),
      );

      expect(find.text('Not rated yet'), findsOneWidget);
      // No fabricated rating text of any kind.
      expect(find.textContaining('out of 5'), findsNothing);
      expect(find.textContaining('0.0'), findsNothing);
    });

    testWidgets('above the floor both backend strings print verbatim',
        (tester) async {
      await _pumpBlock(tester, _reviewsPayload());
      expect(find.text('4.3 out of 5'), findsOneWidget);
      expect(find.text('3 reviews'), findsOneWidget);
    });

    testWidgets('the parser reads has from the payload, never from count',
        (tester) async {
      final s = RatingSummary.fromMap(const {
        'has': false,
        'count': 4,
        'stars': 4.9,
        'stars_label': '4.9 out of 5',
        'count_label': '4 reviews',
        'empty': 'Not rated yet',
      });
      // count is 4 and stars is 4.9, and it is STILL absent, because the
      // backend said so. Re-deriving has from count > 0 here is the bug.
      expect(s.has, isFalse);
      expect(s.count, 4);
    });
  });

  group('compare computes nothing', () {
    testWidgets('columns and rows render in PAYLOAD order, not sorted',
        (tester) async {
      final data = ProductCompare.fromMap(_comparePayload());
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: CompareSheet(data: data))));
      await tester.pumpAndSettle();

      // The fixture order is Zeta, Alpha, Beta — deliberately not alphabetical.
      final names = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();
      expect(names.indexOf('Zeta Tablet') < names.indexOf('Alpha Tablet'),
          isTrue);
      expect(names.indexOf('Alpha Tablet') < names.indexOf('Beta Tablet'),
          isTrue);
      // Rows too: rate, then margin, then rating.
      expect(names.indexOf('Net rate') < names.indexOf('Margin'), isTrue);
      expect(names.indexOf('Margin') < names.indexOf('Rating'), isTrue);
    });

    testWidgets('a column with no trade rate prints the backend dash on BOTH '
        'the rate and the margin row — never 0, never an MRP fallback',
        (tester) async {
      final data = ProductCompare.fromMap(_comparePayload());
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: CompareSheet(data: data))));
      await tester.pumpAndSettle();

      // Two absent rate cells + two absent margin cells = four dashes.
      expect(find.text('—'), findsNWidgets(4));
      // The one real rate and the one real margin, both the backend's strings.
      expect(find.text('₹88.40'), findsOneWidget);
      expect(find.text('18% margin'), findsOneWidget);
      expect(find.textContaining('₹0'), findsNothing);
    });

    testWidgets('an unknown tone falls back to body text instead of throwing',
        (tester) async {
      final payload = _comparePayload();
      (payload['rows'] as List)[0]['cells'][1]['tone'] = 'chartreuse';
      final data = ProductCompare.fromMap(payload);

      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: CompareSheet(data: data))));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('₹88.40'), findsOneWidget);
    });

    testWidgets('ok:false renders the backend empty state, never a crash',
        (tester) async {
      final data = ProductCompare.fromMap(const {'ok': false});
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: CompareSheet(data: data))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('the tray owns ids and nothing else', () {
    test('it refuses the fourth pick by RETURNING a reason, not a sentence', () {
      final sel = CompareSelection(max: 3);
      expect(sel.toggle('1'), isNull);
      expect(sel.toggle('2'), isNull);
      expect(sel.toggle('3'), isNull);
      // The cap is enforced here; the WORDS the customer reads are the
      // backend's `cmp_full`, looked up by the caller.
      expect(sel.toggle('4'), 'full');
      expect(sel.ids, ['1', '2', '3']);
    });

    test('a second tap removes, and never counts as a fourth pick', () {
      final sel = CompareSelection(max: 3);
      sel.toggle('1');
      sel.toggle('2');
      sel.toggle('3');
      expect(sel.toggle('2'), isNull);
      expect(sel.ids, ['1', '3']);
      expect(sel.toggle('4'), isNull);
      expect(sel.ids, ['1', '3', '4']);
    });

    test('canCompare needs two — one pick is not a comparison', () {
      final sel = CompareSelection(max: 3);
      expect(sel.canCompare, isFalse);
      sel.toggle('1');
      expect(sel.canCompare, isFalse);
      sel.toggle('2');
      expect(sel.canCompare, isTrue);
    });

    testWidgets('the checkbox draws nothing when the backend sent no label',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CompareCheckbox(label: '', selected: false, onTap: () {}),
        ),
      ));
      // A control whose caption the backend did not send must not appear with
      // a word this app chose instead.
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('the checkbox prints the backend caption verbatim',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CompareCheckbox(
              label: 'Compare', selected: true, onTap: () {}),
        ),
      ));
      expect(find.text('Compare'), findsOneWidget);
      expect(find.byIcon(Icons.check_box), findsOneWidget);
    });
  });

  group('Q&A renders in payload order and prints backend badges', () {
    testWidgets('answers keep their order and their badges', (tester) async {
      await _pumpBlock(
        tester,
        _reviewsPayload(questions: [
          {
            'id': '5',
            'body': 'Is the pack a strip of 10?',
            'author': 'Shree Medical',
            'when': '30 Aug 2026',
            'is_mine': false,
            'status': 'approved',
            'has_note': false,
            'note': '',
            'can_answer': true,
            'can_flag': true,
            'answers': [
              {
                'id': '7',
                'body': 'Yes, strip of 10.',
                'badge': 'mediBO',
                'when': '30 Aug 2026',
                'can_flag': false,
              },
              {
                'id': '8',
                'body': 'Confirmed on our last order.',
                'badge': 'Verified buyer',
                'when': '31 Aug 2026',
                'can_flag': true,
              },
            ],
          }
        ]),
      );

      expect(find.text('Is the pack a strip of 10?'), findsOneWidget);
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();
      expect(
        texts.indexOf('Yes, strip of 10.') <
            texts.indexOf('Confirmed on our last order.'),
        isTrue,
      );
      expect(find.text('mediBO'), findsOneWidget);
    });

    testWidgets('can_answer:false hides the Answer control', (tester) async {
      await _pumpBlock(
        tester,
        _reviewsPayload(questions: [
          {
            'id': '5',
            'body': 'Is the pack a strip of 10?',
            'author': '',
            'when': '30 Aug 2026',
            'is_mine': false,
            'status': 'approved',
            'has_note': false,
            'note': '',
            'can_answer': false,
            'can_flag': false,
            'answers': const [],
          }
        ]),
      );
      expect(find.text('Answer'), findsNothing);
    });
  });
}

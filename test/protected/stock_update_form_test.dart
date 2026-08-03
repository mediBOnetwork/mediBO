// PROTECTED — CHANGE #639.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes stock-update-form behaviour.
//
// What this holds down:
//
//   1. Items render in PAYLOAD ORDER. get_stock_update_form() already sorts
//      company A-Z -> category A-Z -> name; if this screen ever re-sorts, the
//      page and the WhatsApp image stop agreeing about what "the third item"
//      is. The fixture is deliberately NOT alphabetical so a client-side sort
//      would show up immediately.
//
//   2. The two buttons come from buttons[]: the still_oos one on the LEFT and
//      the back_in_stock one on the RIGHT, each with its own tone. Side and
//      label are read from the payload, never positioned by key here.
//
//   3. Mutual exclusivity — one answer per item. Choosing the second button
//      replaces the first rather than adding to it.
//
//   4. Submit sends [{product_id, back_in_stock}] for ANSWERED items only.
//      An untouched item is omitted entirely: silence is not an answer and
//      must never be turned into "still out of stock" here.
//
//   5. The expired link renders the backend's own title and note, and does not
//      throw.
//
// Fixture mirrors the real payload taken off the live database on 2026-08-03.
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/public/stock_update_form_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _item({
  required int productId,
  required String name,
  required String company,
  String category = 'ANTI INFECTIVES',
  String pack = '1 vial',
  String oosLabel = 'OOS since 01/08/26',
}) =>
    {
      'queue_id': productId,
      'product_id': productId,
      'product_name': name,
      'company': company,
      'category': category,
      'pack_label': pack,
      'image': '',
      'oos_since': '01/08/26',
      'oos_label': oosLabel,
    };

/// The order here is the ORDER THE BACKEND SENT. It is intentionally not
/// alphabetical by product name — "Zicoplanin" precedes "Megval" — so any
/// client-side sort would reverse them and fail test 1.
Map<String, dynamic> _form({List<Map<String, dynamic>>? items}) => {
      'kind': 'stock_update',
      'supplier_name': 'TEST_Supplier Two',
      'status': 'pending',
      'title': 'Stock update',
      'eyebrow': 'mediBO · Stock update',
      'intro': 'Please confirm which of these are back in stock.',
      'submit_label': 'Submit',
      'submitting_label': 'Submitting…',
      'success_title': 'Thank you — stock update received',
      'success_note': 'Your answers have been saved.',
      'empty_text': 'Nothing to confirm right now.',
      'submit_error': 'Submission failed. Please try again.',
      'answered_suffix': 'answered',
      'item_count': 2,
      'items': items ??
          [
            _item(
                productId: 176027,
                name: 'Zicoplanin 400mg Injection',
                company: 'MACLEODS PHARMACEUTICALS PVT LTD'),
            _item(
                productId: 176026,
                name: 'Megval 50mg Injection',
                company: 'EMCURE PHARMACEUTICALS LTD',
                category: 'ANTI NEOPLASTICS'),
          ],
      'buttons': [
        {
          'key': 'still_oos',
          'label': 'Still Out of Stock',
          'side': 'left',
          'tone': 'oos'
        },
        {
          'key': 'back_in_stock',
          'label': 'Back in Stock',
          'side': 'right',
          'tone': 'available'
        },
      ],
    };

const _kExpired = {
  'error': 'expired',
  'error_title': 'This stock update link has expired',
  'error_note': 'Please contact mediBO for a new link.',
};

/// Records every RPC the screen makes and replies with canned payloads.
class _Rpc {
  final List<({String fn, Map<String, dynamic>? params})> calls = [];
  final Map<String, dynamic> Function(String fn) reply;
  _Rpc(this.reply);

  Future<dynamic> call(String fn, Map<String, dynamic>? params) async {
    calls.add((fn: fn, params: params));
    return reply(fn);
  }
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: Size(390, 900)),
      child: StockUpdateFormScreen(token: 'tok_test_1234'),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  // No network from the protected suite: RenderLog's debounced Supabase flush
  // is a real Timer and would both outlive the test and try to reach Supabase.
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => StockUpdateFormScreen.rpcTransport = null);

  testWidgets('1. items render in payload order — no client sort',
      (tester) async {
    StockUpdateFormScreen.rpcTransport = _Rpc((_) => _form()).call;
    await _pump(tester);

    final zico = tester.getTopLeft(find.text('Zicoplanin 400mg Injection')).dy;
    final megval = tester.getTopLeft(find.text('Megval 50mg Injection')).dy;

    // Payload order: Zicoplanin first. Alphabetical would put Megval first.
    expect(zico, lessThan(megval),
        reason: 'items must render in payload order, not re-sorted');
  });

  testWidgets('2. both buttons render, still_oos LEFT of back_in_stock',
      (tester) async {
    StockUpdateFormScreen.rpcTransport = _Rpc((_) => _form()).call;
    await _pump(tester);

    expect(find.text('Still Out of Stock'), findsNWidgets(2));
    expect(find.text('Back in Stock'), findsNWidgets(2));

    final leftX = tester.getTopLeft(find.text('Still Out of Stock').first).dx;
    final rightX = tester.getTopLeft(find.text('Back in Stock').first).dx;
    expect(leftX, lessThan(rightX),
        reason: 'side:left must render left of side:right');
  });

  testWidgets('2b. tones — selected still_oos is the OOS swatch, '
      'selected back_in_stock is the Available swatch', (tester) async {
    StockUpdateFormScreen.rpcTransport = _Rpc((_) => _form()).call;
    await _pump(tester);

    // Nothing selected by default: both chips are plain white.
    expect(_bg(tester, 'Still Out of Stock'), Colors.white);
    expect(_bg(tester, 'Back in Stock'), Colors.white);

    await tester.tap(find.text('Still Out of Stock').first);
    await tester.pumpAndSettle();
    expect(_bg(tester, 'Still Out of Stock'), const Color(0xFFFAECE7));

    await tester.tap(find.text('Back in Stock').first);
    await tester.pumpAndSettle();
    expect(_bg(tester, 'Back in Stock'), const Color(0xFFE1F5EE));
  });

  testWidgets('3. mutual exclusivity — the second choice replaces the first',
      (tester) async {
    StockUpdateFormScreen.rpcTransport = _Rpc((_) => _form()).call;
    await _pump(tester);

    await tester.tap(find.text('Back in Stock').first);
    await tester.pumpAndSettle();
    expect(_bg(tester, 'Back in Stock'), const Color(0xFFE1F5EE));

    await tester.tap(find.text('Still Out of Stock').first);
    await tester.pumpAndSettle();

    expect(_bg(tester, 'Still Out of Stock'), const Color(0xFFFAECE7));
    expect(_bg(tester, 'Back in Stock'), Colors.white,
        reason: 'selecting one button must deselect the other');
  });

  testWidgets('4. submit sends only ANSWERED items, as {product_id, bool}',
      (tester) async {
    final rpc = _Rpc((fn) => fn == 'submit_stock_update_form'
        ? {'status': 'ok', 'saved': 1}
        : _form());
    StockUpdateFormScreen.rpcTransport = rpc.call;
    await _pump(tester);

    // Answer ONLY the first item (Zicoplanin, 176027). Leave the second alone.
    await tester.tap(find.text('Back in Stock').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();

    final submit =
        rpc.calls.where((c) => c.fn == 'submit_stock_update_form').single;
    expect(submit.params!['p_token'], 'tok_test_1234');

    final answers =
        (submit.params!['p_answers'] as List).cast<Map<String, dynamic>>();
    expect(answers, hasLength(1),
        reason: 'the untouched item must be omitted, not defaulted');
    expect(answers.single['product_id'], 176027);
    expect(answers.single['back_in_stock'], isTrue);

    // …and the success screen is the backend's wording.
    expect(find.text('Thank you — stock update received'), findsOneWidget);
  });

  testWidgets('4b. still_oos submits back_in_stock:false', (tester) async {
    final rpc = _Rpc((fn) => fn == 'submit_stock_update_form'
        ? {'status': 'ok', 'saved': 1}
        : _form());
    StockUpdateFormScreen.rpcTransport = rpc.call;
    await _pump(tester);

    await tester.tap(find.text('Still Out of Stock').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();

    final answers = ((rpc.calls
                .where((c) => c.fn == 'submit_stock_update_form')
                .single
                .params!['p_answers']) as List)
        .cast<Map<String, dynamic>>();
    expect(answers.single['back_in_stock'], isFalse);
  });

  testWidgets('5. expired renders the backend copy and does not throw',
      (tester) async {
    StockUpdateFormScreen.rpcTransport = _Rpc((_) => _kExpired).call;
    await _pump(tester);

    expect(find.text('This stock update link has expired'), findsOneWidget);
    expect(find.text('Please contact mediBO for a new link.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('5b. an empty item list renders the backend empty_text',
      (tester) async {
    StockUpdateFormScreen.rpcTransport =
        _Rpc((_) => _form(items: const [])).call;
    await _pump(tester);
    expect(find.text('Nothing to confirm right now.'), findsOneWidget);
  });
}

/// Background colour of the choice button carrying [label].
Color? _bg(WidgetTester tester, String label) {
  final c = tester.widget<AnimatedContainer>(
    find
        .ancestor(
            of: find.text(label).first, matching: find.byType(AnimatedContainer))
        .first,
  );
  return (c.decoration as BoxDecoration).color;
}

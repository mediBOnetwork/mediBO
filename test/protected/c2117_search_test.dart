// PROTECTED — CMD #2117. The search screen's three promises.
//
// What this file holds down:
//
//   1. **The placeholder's words are the BACKEND's, in the BACKEND's order.**
//      `search_bar.placeholder_prefix` never moves, `placeholder_words[]`
//      cycles behind it on `placeholder_rotate_ms`, and the app sorts,
//      shortens and invents nothing. A payload with fewer than two words
//      animates nothing — which is also what an old cache gets — and an
//      absent block leaves the plain hint exactly as it was.
//
//   2. **Scrolling the suggestions does NOT close the search.** The idle
//      overlay's scroll view is `ScrollViewKeyboardDismissBehavior.manual`.
//      `onDrag` read one gesture as two intentions: the drag dropped the
//      keyboard, dropping the keyboard unfocused the box, and unfocusing the
//      box closed the overlay — so the list vanished under the finger that
//      was reading it, with nothing left to scroll back up to.
//
//   3. **The bottom chrome stands down while the box has focus — if the
//      BACKEND says so.** [SearchChromeFocus] is a report, not a decision:
//      focus alone suppresses nothing, and a surface leaving the tree can
//      never leave the chrome hidden behind it.
//
//   4. **"Popular searches near you" is printed, never composed.** The block
//      title and every chip come from `search_idle()` verbatim, in payload
//      order, and a chip searches for `q` rather than for the label it prints.
//
// No network, no Supabase: fabricated payloads only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/data/medicine_repository.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/search_page.dart';
import 'package:pharma_b2b/services/search_chrome_focus.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/bottom_stack.dart';
import 'package:pharma_b2b/widgets/search_surface.dart';

/// `search_page().search_bar` as the backend sends it after CMD #2117.
Map<String, dynamic> _bar({
  String prefix = 'Search',
  List<String> words = const ['medicine', 'salt', 'composition'],
  int rotateMs = 5000,
  bool hide = true,
}) =>
    {
      'placeholder': 'Search medicines, salts, companies',
      'placeholder_prefix': prefix,
      'placeholder_words': words,
      'placeholder_rotate_ms': rotateMs,
      'hide_bottom_chrome_on_focus': hide,
      'min_chars': 2,
      'debounce_ms': 250,
      'actions': const [],
      'chip_row_on_results': false,
    };

Map<String, dynamic> _idle() => {
      'ok': true,
      'has': true,
      'empty_label': 'Type a medicine, salt or company name to search.',
      'blocks': [
        {
          'kind': 'suggest',
          'title': 'Popular searches near you',
          'action_label': '',
          'action_kind': '',
          'chips': [
            {'label': 'Dolo 650', 'sub_label': '', 'q': 'dolo 650'},
            {'label': 'Paracetamol', 'sub_label': '', 'q': 'paracetamol'},
            {'label': 'Azithral', 'sub_label': '', 'q': 'azithral'},
          ],
        },
      ],
    };

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// A repository that answers `search_idle()` from the fixture above and never
/// reaches a network. Nothing else in this file needs one.
MedicineRepository _fakeRepo() => MedicineRepository(null, (fn, {params}) async {
      if (fn == 'search_idle') return _idle();
      return <String, dynamic>{};
    });

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('CMD #2117 §4 — the placeholder is the backend\'s', () {
    test('the bar block parses prefix, words, interval and the chrome flag',
        () {
      final spec = SearchBarSpec.fromMap(_bar());
      expect(spec.placeholderPrefix, 'Search');
      // Payload ORDER, not alphabetical and not de-duplicated here.
      expect(spec.placeholderWords, ['medicine', 'salt', 'composition']);
      expect(spec.placeholderRotate, const Duration(milliseconds: 5000));
      expect(spec.hideBottomChromeOnFocus, isTrue);
      expect(spec.placeholderAnimates, isTrue);
    });

    test('an old payload with no CMD #2117 fields animates nothing', () {
      final spec = SearchBarSpec.fromMap({
        'min_chars': 2,
        'debounce_ms': 250,
        'actions': const [],
        'chip_row_on_results': true,
      });
      expect(spec.placeholderPrefix, '');
      expect(spec.placeholderWords, isEmpty);
      expect(spec.placeholderAnimates, isFalse);
      expect(spec.hideBottomChromeOnFocus, isFalse);
    });

    test('one word is a still hint — there is nothing to cycle', () {
      final spec = SearchBarSpec.fromMap(_bar(words: const ['medicine']));
      expect(spec.placeholderAnimates, isFalse);
    });

    testWidgets('the word after the prefix changes on the backend\'s interval',
        (tester) async {
      await tester.pumpWidget(_host(const AnimatedSearchPlaceholder(
        prefix: 'Search',
        words: ['medicine', 'salt', 'composition'],
        rotate: Duration(milliseconds: 5000),
      )));
      await tester.pump();

      // The fixed half is on screen once and stays there throughout.
      expect(find.text('Search'), findsOneWidget);
      expect(find.text('medicine'), findsOneWidget);
      expect(find.text('salt'), findsNothing);

      // One interval later the SECOND word — payload order — is the one in
      // the box, and the first has left.
      await tester.pump(const Duration(milliseconds: 5000));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(find.text('Search'), findsOneWidget);
      expect(find.text('salt'), findsOneWidget);
      expect(find.text('medicine'), findsNothing);

      // And it keeps going, still in the backend's order.
      await tester.pump(const Duration(milliseconds: 5000));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(find.text('composition'), findsOneWidget);

      // Unmount so the widget's own timer is cancelled with it.
      await tester.pumpWidget(_host(const SizedBox.shrink()));
    });

    testWidgets('mid-transition BOTH words are on screen — one movement',
        (tester) async {
      await tester.pumpWidget(_host(const AnimatedSearchPlaceholder(
        prefix: 'Search',
        words: ['medicine', 'salt'],
        rotate: Duration(milliseconds: 5000),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 5000));
      // Part-way through the slide: the old word is still travelling up while
      // the new one is on its way in. A swap would show only one.
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('medicine'), findsOneWidget);
      expect(find.text('salt'), findsOneWidget);
      await tester.pumpWidget(_host(const SizedBox.shrink()));
    });
  });

  group('CMD #2117 §2 — scrolling the suggestions keeps the keyboard', () {
    testWidgets('the idle overlay never dismisses the keyboard on a drag',
        (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(_host(
        SearchIdleOverlay(
          focusNode: node,
          hasQuery: false,
          onPickQuery: (_) {},
          repo: _fakeRepo(),
          // The node has to be ATTACHED for focus to be real, so it sits on a
          // field exactly as it does in the shell's header.
          child: TextField(focusNode: node),
        ),
      ));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.pumpAndSettle();

      final sv = tester.widget<SingleChildScrollView>(
          find.byKey(const Key('c2117_idle_scroll')));
      expect(sv.keyboardDismissBehavior,
          ScrollViewKeyboardDismissBehavior.manual);

      // The box still has focus after the panel is dragged, which is the whole
      // bug: focus was what kept this overlay open.
      await tester.drag(find.byKey(const Key('c2117_idle_scroll')),
          const Offset(0, -120));
      await tester.pump();
      expect(node.hasFocus, isTrue);
    });
  });

  group('CMD #2117 §3 — the bottom chrome stands down on the backend\'s word',
      () {
    setUp(SearchChromeFocus.release);

    test('focus alone suppresses nothing', () {
      SearchChromeFocus.report(focused: true, backendWantsHide: false);
      expect(SearchChromeFocus.suppressed.value, isFalse);
    });

    test('focus plus the backend flag suppresses, and losing focus restores',
        () {
      SearchChromeFocus.report(focused: true, backendWantsHide: true);
      expect(SearchChromeFocus.suppressed.value, isTrue);
      SearchChromeFocus.report(focused: false, backendWantsHide: true);
      expect(SearchChromeFocus.suppressed.value, isFalse);
    });

    test('a surface leaving the tree can never leave the chrome hidden', () {
      SearchChromeFocus.report(focused: true, backendWantsHide: true);
      SearchChromeFocus.release();
      expect(SearchChromeFocus.suppressed.value, isFalse);
    });

    testWidgets('the pill and the bar leave, and give their room back',
        (tester) async {
      // A cart with a pill in it, and no Supabase: `rpcTransport` is the
      // model's own test seam and `forTest` skips the auth wiring.
      CartModel.rpcTransport = (fn, params) async => {
            'ok': true,
            'items': const [],
            'pill': {'show': true, 'items_label': '3 items', 'cta': 'View cart'},
          };
      addTearDown(() => CartModel.rpcTransport = null);
      final cart = CartModel.forTest();
      addTearDown(cart.dispose);
      await cart.refresh();
      await tester.pumpWidget(MaterialApp(
        home: AppState(
          cart: cart,
          child: Scaffold(
            bottomNavigationBar: const SizedBox(height: 56),
            body: Stack(children: [
              const SizedBox.expand(),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: StorefrontBottomStack(onCartTap: () {}),
              ),
            ]),
          ),
        ),
      ));
      await tester.pump();

      // The one function the chrome AND every box holding room for it read.
      final ctx = tester.element(find.byType(StorefrontBottomStack));
      expect(bottomStackLiveOf(ctx, pill: true).pill, isTrue,
          reason: 'the cart payload says there is a pill, so there is one');

      SearchChromeFocus.report(focused: true, backendWantsHide: true);
      await tester.pump();
      final live = bottomStackLiveOf(ctx, pill: true);
      expect(live.pill, isFalse);
      expect(live.bar, isFalse);
      // And the room goes with it — the chrome and the box holding room for
      // it can never disagree, because they are the same answer.
      expect(live.height, 0);
    });
  });

  group('CMD #2117 §1 — "Popular searches near you" is printed verbatim', () {
    testWidgets('title and chips come from the payload, in payload order',
        (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(_host(SingleChildScrollView(
        child: SearchIdleView(
          payload: SearchIdlePayload.fromMap(_idle()),
          onPickQuery: picked.add,
          onOpenProduct: (_) {},
        ),
      )));
      await tester.pump();

      expect(find.text('Popular searches near you'), findsOneWidget);

      // Payload order, left to right — no client-side sort.
      final labels = tester
          .widgetList<Text>(find.descendant(
              of: find.byType(Wrap), matching: find.byType(Text)))
          .map((t) => t.data)
          .toList();
      expect(labels, ['Dolo 650', 'Paracetamol', 'Azithral']);

      // A chip searches for `q`, which is not the label it prints.
      await tester.tap(find.text('Dolo 650'));
      await tester.pump();
      expect(picked, ['dolo 650']);
    });
  });
}

// PROTECTED — CMD #2026. The search BOX: a phrase is one query, the buttons on
// the right are the backend's list for the state the box is in, and nothing
// sits between the box and the results grid.
//
// What this file holds down:
//
//   1. **A SPACE IS A CHARACTER, AND THE BOX BELONGS TO THE SHOPPER.**
//      `searchBoxSync` is the whole rule: a box whose text already SAYS the
//      query — and "telmed " says 'telmed', because the query is the trimmed
//      text — is left alone, caret included. That one comparison was the
//      multi-word bug: the write-back rewrote the box without the space the
//      shopper had just typed and `.text =` collapsed the caret to zero, so
//      the next letter landed in FRONT of the first word. When a sync really
//      is wanted (a URL, back/forward, a category, a scan, a voice result) the
//      caret goes AFTER the text, never to position zero.
//
//   2. **THE WHOLE PHRASE IS SENT, EVERY KEYSTROKE.** "telmed ah tablet" is
//      ONE query. The debounce carries the text as typed — spaces included,
//      nothing trimmed off the end of the wire — and no token in it is ever
//      selected, highlighted or committed on its own.
//
//   3. **THE RIGHT-HAND BUTTONS ARE A PAYLOAD, NOT A LAYOUT.** Empty box →
//      `state:'empty'` (scan + mic); any text at all → `state:'typing'` (one
//      × on the far right, and the scan and mic are gone). Drawn in PAYLOAD
//      ORDER — this file reverses the order and expects the drawing to flip —
//      and an `icon` name this build does not know is SKIPPED, never guessed
//      into a blank square. The × sits to the right of the field itself.
//
//   4. NOTE (CMD #2037): the inline CATEGORY row is deleted outright — it does
//      not draw on any surface, typed-in or not. What survives below is the
//      rule that nothing sits between the box and the grid.
//   4. **NO CHIP ROW ABOVE RESULTS.** `search_bar.chip_row_on_results` is the
//      rule and it is the backend's: with a query on screen the category row
//      and the filter chips are both gone and the grid starts directly under
//      the search bar, even for a surface that IS named in
//      `chip_row_surfaces`. Flip the payload's flag and the row comes back —
//      so it is one app_settings UPDATE, never a deploy.
//
//   5. **THE FLOOR AND THE WAIT COME FROM THE PAYLOAD.**
//      `search_bar.min_chars` / `debounce_ms`, not Dart constants: a payload
//      saying 3 asks nothing at two characters, and a payload saying 500 ms
//      has not fired at 300 ms.
//
// No network, no Supabase, no camera: fabricated payloads only.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/data/medicine_repository.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/search_page.dart';
import 'package:pharma_b2b/services/storefront_fast_order.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/search_surface.dart';

// ── payload builders ────────────────────────────────────────────────────────

/// One `search_bar.actions[]` row.
Map<String, dynamic> _action(String kind, String state, String icon,
        [String label = 'ZZ-LABEL-FROM-BACKEND']) =>
    {'kind': kind, 'state': state, 'icon': icon, 'label': label};

/// The `search_bar` block as `search_bar_block()` builds it.
Map<String, dynamic> _bar({
  int minChars = 2,
  int debounceMs = 250,
  bool chipRowOnResults = false,
  List<Map<String, dynamic>>? actions,
}) =>
    {
      'min_chars': minChars,
      'debounce_ms': debounceMs,
      'chip_row_on_results': chipRowOnResults,
      'actions': actions ??
          [
            _action('scan', 'empty', 'scan', 'Scan barcode'),
            _action('mic', 'empty', 'mic', 'Search by voice'),
            _action('clear', 'typing', 'close', 'Clear search'),
          ],
    };

/// The category row Home has always drawn, as the backend sends it.
Map<String, dynamic> _categoryGroup() => {
      'key': 'category',
      'label': 'Category',
      'mode': 'single',
      'chip_row': true,
      'options': [
        {'key': '', 'label': 'ZZ-ALL-FROM-BACKEND', 'selected': true},
        {'key': 'ANTI INFECTIVES', 'label': 'ZZ-ANTI-INFECTIVES', 'selected': false},
      ],
    };

/// A sheet group, so "nothing between the box and the grid" is provably about
/// BOTH rows and not just the category one.
Map<String, dynamic> _sheetGroup() => {
      'key': 'pack_type',
      'label': 'ZZ-PACK-TYPE-FROM-BACKEND',
      'mode': 'multi',
      'chip_row': false,
      'options': [
        {'key': 'strip', 'label': 'ZZ-STRIP', 'selected': false},
      ],
    };

/// A whole `search_page()` answer.
Map<String, dynamic> _payload({
  String q = '',
  Map<String, dynamic>? bar,
  List<String>? chipRowSurfaces = const ['test'],
  bool withFilters = true,
}) =>
    {
      'ok': true,
      'query': q,
      'has_query': q.isNotEmpty,
      'placeholder': 'ZZ-PLACEHOLDER-FROM-BACKEND',
      'header_label': q.isEmpty ? '' : 'ZZ-HEADER $q',
      'total': 0,
      'filters': withFilters
          ? {'groups': [_categoryGroup(), _sheetGroup()]}
          : {'groups': const []},
      'filters_active': false,
      'empty': {'label': 'ZZ-EMPTY-FROM-BACKEND', 'hint': '', 'buttons': const []},
      'empty_label': 'ZZ-EMPTY-FROM-BACKEND',
      'rail': {'has': false, 'kind': '', 'title': '', 'items': const []},
      'paging': {
        'page': 0,
        'page_size': 30,
        'returned': 0,
        'has_more': false,
        'next_page': 1,
        'more_label': 'Load more',
        'end_label': 'ZZ-END-FROM-BACKEND',
      },
      'items': const [],
      'chip_row_surfaces': ?chipRowSurfaces,
      'search_bar': bar ?? _bar(),
    };

// ── harness ─────────────────────────────────────────────────────────────────

class _Rpc {
  _Rpc(this.answer);

  final Map<String, dynamic> Function(String fn, Map<String, dynamic> args) answer;
  final List<(String, Map<String, dynamic>)> calls = [];

  Future<dynamic> call(String fn, {Map<String, dynamic>? params}) async {
    final args = params ?? const <String, dynamic>{};
    calls.add((fn, args));
    return answer(fn, args);
  }

  /// Every `p_q` the backend was actually asked, in order.
  List<String> queries() => calls
      .where((c) => c.$1 == 'search_page')
      .map((c) => (c.$2['p_q'] ?? '').toString())
      .toList();
}

/// One [SearchChrome] driven exactly as the real screens drive it: the host
/// owns the query and, on every submit, applies the SAME [searchBoxSync] rule
/// `home_shell` and `catalogue_screen` apply. If that rule regresses, the
/// trailing space disappears here too.
class _Host extends StatefulWidget {
  const _Host({super.key, required this.repo, required this.submits});

  final MedicineRepository repo;
  final List<String> submits;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  String _query = '';

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          SearchChrome(
            surface: 'test',
            controller: _ctrl,
            focusNode: _focus,
            repo: widget.repo,
            hasQuery: _query.isNotEmpty,
            payload: null,
            onSubmit: (q) {
              widget.submits.add(q);
              // The screen's own fetch, so the phrase on the WIRE is testable:
              // `p_q` is `state.query`, untrimmed, exactly as typed.
              unawaited(widget.repo.searchPage(SearchQueryState(query: q)));
              setState(() {
                _query = q.trim();
                final sync = searchBoxSync(_ctrl.value, _query);
                if (sync != null) _ctrl.value = sync;
              });
            },
            onFilterPick: (_, _) {},
            onClear: () => setState(() => _query = ''),
          ),
        ],
      );
}

Future<(_Rpc, List<String>, TextEditingController)> _pumpChrome(
  WidgetTester tester, {
  Map<String, dynamic>? bar,
  List<String>? chipRowSurfaces = const ['test'],
  bool withFilters = true,
}) async {
  tester.view.physicalSize = const Size(360, 780);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final rpc = _Rpc((fn, args) {
    if (fn == 'search_page') {
      return _payload(
        q: (args['p_q'] ?? '').toString(),
        bar: bar,
        chipRowSurfaces: chipRowSurfaces,
        withFilters: withFilters,
      );
    }
    return {'ok': false};
  });
  final submits = <String>[];
  final host = GlobalKey<_HostState>();
  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: Scaffold(
          body: _Host(
            key: host,
            repo: MedicineRepository(null, rpc.call),
            submits: submits,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (rpc, submits, host.currentState!._ctrl);
}

/// The bar on its own, with the payload's buttons — the icon swap without a
/// screen around it.
Future<TextEditingController> _pumpBar(
  WidgetTester tester, {
  required Map<String, dynamic> bar,
  String text = '',
}) async {
  tester.view.physicalSize = const Size(360, 780);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final ctrl = TextEditingController(text: text);
  final focus = FocusNode();
  addTearDown(ctrl.dispose);
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: Scaffold(
          body: SearchHeaderBar(
            controller: ctrl,
            focusNode: focus,
            placeholder: 'ZZ-PLACEHOLDER-FROM-BACKEND',
            bar: SearchBarSpec.fromMap(bar),
            scanResolver: (_) async => const ScanResult(ok: false),
            onChanged: (_) {},
            onSubmit: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ctrl;
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
}

const _scan = Key('c409_scan_button');
const _mic = Key('c409_mic_button');
const _clear = Key('c2026_clear_button');

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  // ── 1. the multi-word bug, as a pure rule ────────────────────────────────
  group('searchBoxSync — the box belongs to the shopper', () {
    test('a trailing space is NOT a different query: the box is left alone', () {
      // This is the exact state the bug fired in: the shopper has typed the
      // space after the first word, so the query is the trimmed 'telmed'.
      const typed = TextEditingValue(
        text: 'telmed ',
        selection: TextSelection.collapsed(offset: 7),
      );
      expect(searchBoxSync(typed, 'telmed'), isNull);
    });

    test('a box that already says the phrase is left alone, caret included', () {
      const typed = TextEditingValue(
        text: 'telmed ah tablet',
        selection: TextSelection.collapsed(offset: 10),
      );
      expect(searchBoxSync(typed, 'telmed ah tablet'), isNull);
    });

    test('a search from somewhere else syncs, with the caret AFTER the text', () {
      final v = searchBoxSync(TextEditingValue.empty, 'paracetamol');
      expect(v, isNotNull);
      expect(v!.text, 'paracetamol');
      // Never position zero — that is where the next letter used to land.
      expect(v.selection.baseOffset, 'paracetamol'.length);
      expect(v.selection.isCollapsed, isTrue);
    });

    test('clearing from elsewhere still syncs to empty', () {
      const typed = TextEditingValue(
        text: 'telmed',
        selection: TextSelection.collapsed(offset: 6),
      );
      final v = searchBoxSync(typed, '');
      expect(v, isNotNull);
      expect(v!.text, '');
      expect(v.selection.baseOffset, 0);
    });
  });

  // ── 2. typing a second word ──────────────────────────────────────────────
  group('a phrase is one query', () {
    testWidgets('the space survives the search it triggered', (t) async {
      final (rpc, submits, ctrl) = await _pumpChrome(t);

      await _type(t, 'telmed');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      expect(submits, ['telmed']);

      // The space after the first word. The search that comes back is for the
      // trimmed 'telmed' — and the box must still hold the space, or the next
      // letter starts a new word on top of the old one.
      await _type(t, 'telmed ');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      expect(ctrl.text, 'telmed ');
      expect(ctrl.selection.baseOffset, 'telmed '.length);

      // The second word lands after the first, not in front of it.
      await _type(t, 'telmed ah');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      expect(ctrl.text, 'telmed ah');
      expect(submits.last, 'telmed ah');
      expect(find.text('telmed ah'), findsOneWidget);

      // The FULL phrase reached the backend, spaces and all.
      expect(rpc.queries(), contains('telmed ah'));
    });

    testWidgets('three words are still one query and one box', (t) async {
      final (rpc, submits, ctrl) = await _pumpChrome(t);
      for (final s in ['tel', 'telmed', 'telmed a', 'telmed ah', 'telmed ah tab']) {
        await _type(t, s);
        await t.pump(const Duration(milliseconds: 300));
        await t.pumpAndSettle();
      }
      expect(ctrl.text, 'telmed ah tab');
      expect(submits.last, 'telmed ah tab');
      // No token was ever committed on its own: every query the backend saw is
      // a prefix of what was typed, and the last one is the whole phrase.
      expect(rpc.queries().last, 'telmed ah tab');
      // Nothing about the keystroke is recorded (CMD #2010's rule, still true).
      expect(rpc.calls.map((c) => c.$1),
          isNot(anyElement(anyOf('search_suggest', 'suggest_medicines'))));
    });
  });

  // ── 3. the buttons are a payload ─────────────────────────────────────────
  group('the right-hand buttons are the backend\'s list', () {
    testWidgets('empty box: scan + mic, no ×', (t) async {
      await _pumpBar(t, bar: _bar());
      expect(find.byKey(_scan), findsOneWidget);
      expect(find.byKey(_mic), findsOneWidget);
      expect(find.byKey(_clear), findsNothing);
    });

    testWidgets('any text: one × and the scan/mic are gone', (t) async {
      await _pumpBar(t, bar: _bar());
      await _type(t, 'te');
      expect(find.byKey(_clear), findsOneWidget);
      expect(find.byKey(_scan), findsNothing);
      expect(find.byKey(_mic), findsNothing);

      // Far right: to the right of the field it clears.
      expect(t.getCenter(find.byKey(_clear)).dx,
          greaterThan(t.getTopRight(find.byType(TextField)).dx));
      // And big enough to hit on a phone.
      final box = t.getSize(find.byKey(_clear));
      expect(box.width, greaterThanOrEqualTo(44));
      expect(box.height, greaterThanOrEqualTo(44));

      // A lone space is text too — the swap is on ANY character.
      await _type(t, ' ');
      expect(find.byKey(_clear), findsOneWidget);
      expect(find.byKey(_scan), findsNothing);
    });

    testWidgets('the × clears the box and brings the empty state back', (t) async {
      final ctrl = await _pumpBar(t, bar: _bar(), text: 'telmed ah');
      expect(find.byKey(_clear), findsOneWidget);
      await t.tap(find.byKey(_clear));
      await t.pumpAndSettle();
      expect(ctrl.text, '');
      expect(find.byKey(_scan), findsOneWidget);
      expect(find.byKey(_mic), findsOneWidget);
      expect(find.byKey(_clear), findsNothing);
    });

    testWidgets('payload ORDER decides the order, not this file', (t) async {
      // Mic first this time. Nothing in Dart may re-sort it.
      await _pumpBar(t, bar: _bar(actions: [
        _action('mic', 'empty', 'mic'),
        _action('scan', 'empty', 'scan'),
      ]));
      expect(t.getCenter(find.byKey(_mic)).dx,
          lessThan(t.getCenter(find.byKey(_scan)).dx));
    });

    testWidgets('an icon name this build does not know is skipped', (t) async {
      await _pumpBar(t, bar: _bar(actions: [
        _action('scan', 'empty', 'scan'),
        _action('teleport', 'empty', 'zz_not_a_real_icon'),
      ]));
      expect(t.takeException(), isNull);
      expect(find.byKey(_scan), findsOneWidget);
      // Two buttons declared, one drawn: no blank square for the unknown one.
      expect(find.byType(IconButton), findsOneWidget);
    });

    testWidgets('a payload with no actions draws no buttons at all', (t) async {
      await _pumpBar(t, bar: _bar(actions: const []));
      expect(find.byKey(_scan), findsNothing);
      expect(find.byKey(_mic), findsNothing);
      expect(find.byKey(_clear), findsNothing);
    });
  });

  // ── 4. nothing between the box and the grid ──────────────────────────────
  group('no chip row above results', () {
    test('the flag is the backend\'s, and it beats the surface list', () {
      final p = SearchPagePayload.fromMap(_payload(chipRowSurfaces: ['test']));
      // Empty box: the surface list still decides (CMD #2011).
      expect(p.drawsChipRow('test'), isTrue);
      expect(p.drawsChipRow('catalogue'), isFalse);
      // With results on screen: never, even for a named surface.
      expect(p.drawsChipRow('test', hasQuery: true), isFalse);

      // Flip the payload and the row comes back — one UPDATE, no deploy.
      final on = SearchPagePayload.fromMap(
          _payload(bar: _bar(chipRowOnResults: true), chipRowSurfaces: ['test']));
      expect(on.drawsChipRow('test', hasQuery: true), isTrue);
    });

    testWidgets('with a query, neither the category row nor the filter chips draw',
        (t) async {
      await _pumpChrome(t);
      // CMD #2037 — the category row is gone BEFORE anything is typed too,
      // named surface or not: it is not drawn on any surface any more.
      expect(find.text('ZZ-ANTI-INFECTIVES'), findsNothing);
      expect(t.getSize(find.byType(SearchFilterChips)).height, 0);

      await _type(t, 'telmed ah');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      // Results on screen: the grid starts directly under the search bar.
      expect(find.text('ZZ-ANTI-INFECTIVES'), findsNothing);
      expect(find.text('ZZ-ALL-FROM-BACKEND'), findsNothing);
      expect(find.text('ZZ-PACK-TYPE-FROM-BACKEND'), findsNothing);
      expect(find.byType(SearchFilterChips), findsOneWidget);
      expect(t.getSize(find.byType(SearchFilterChips)).height, 0);
    });
  });

  // ── 5. the floor and the wait are the payload's ──────────────────────────
  group('min_chars and debounce come from the payload', () {
    test('shouldSearch measures the text as typed against the backend floor', () {
      final three = SearchBarSpec.fromMap(_bar(minChars: 3));
      expect(three.shouldSearch('ab'), isFalse);
      expect(three.shouldSearch('abc'), isTrue);
      expect(three.shouldSearch('telmed ah'), isTrue);
      expect(three.minChars, 3);

      final one = SearchBarSpec.fromMap(_bar(minChars: 1));
      expect(one.shouldSearch('a'), isTrue);
    });

    test('the state is empty only when there is nothing at all', () {
      final b = SearchBarSpec.fromMap(_bar());
      expect(b.stateFor(''), 'empty');
      expect(b.stateFor(' '), 'typing');
      expect(b.stateFor('t'), 'typing');
      expect(b.actionsForText('').map((a) => a.kind), ['scan', 'mic']);
      expect(b.actionsForText('te').map((a) => a.kind), ['clear']);
      // Every label is the backend's.
      expect(b.actionsForText('te').single.label, 'Clear search');
    });

    test('an old cache with no bar block keeps what CMD #2010 shipped', () {
      final m = _payload();
      m.remove('search_bar');
      final p = SearchPagePayload.fromMap(m);
      expect(p.searchBar.minChars, 2);
      expect(p.searchBar.debounceMs, 250);
      expect(p.searchBar.actions, isEmpty);
      // And the pre-#2026 chip-row behaviour, not a silent removal.
      expect(p.drawsChipRow('test', hasQuery: true), isTrue);
    });

    testWidgets('a floor of 3 asks nothing at two characters', (t) async {
      final (rpc, submits, _) = await _pumpChrome(t, bar: _bar(minChars: 3));
      await _type(t, 'te');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(submits, isEmpty);

      await _type(t, 'tel');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(submits, ['tel']);
      expect(rpc.queries(), contains('tel'));
    });

    testWidgets('a wait of 500ms has not fired at 300ms', (t) async {
      final (_, submits, _) = await _pumpChrome(t, bar: _bar(debounceMs: 500));
      await _type(t, 'telmed');
      await t.pump(const Duration(milliseconds: 300));
      expect(submits, isEmpty);
      await t.pump(const Duration(milliseconds: 250));
      await t.pumpAndSettle();
      expect(submits, ['telmed']);
    });
  });
}

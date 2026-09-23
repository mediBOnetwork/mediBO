// PROTECTED — CMD #2175, one 56 dp shell.
//
// What this holds down, in the order Om wrote it:
//
//   1. The header row is logo · status pill · bell. There is no wordmark text
//      in it, and nothing in the row measures a word to decide.
//   2. The header row hides on scroll on EVERY tab, and the search row that
//      stays pinned under it is the same widget on every tab.
//   3. The pill's text and colours are `header_status_pill()`'s, printed
//      verbatim — never composed, never shrunk, one line, 32 dp.
//   4. The search bar's scope and placeholder are the backend's, per tab, and
//      the typed query reaches the surface the backend named.
//   5. ONE height: the header row, the search field, the banner, the nav rows
//      and the "View cart" pill are all `Ds.shell.height`, inset by
//      `Ds.shell.inset`, cornered at `Ds.shell.radius`, gapped by
//      `Ds.shell.gap` — one token, so `ui_design_set({'shell': …})` moves all
//      five together with no deploy.
//
// It runs on the Dart VM: no network, no Supabase, no canvas.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/home_shell.dart';
import 'package:pharma_b2b/shell_search_scope.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/cart_pill.dart';
import 'package:pharma_b2b/widgets/floating_dock.dart';
import 'package:pharma_b2b/widgets/order_hours_pill.dart';
import 'package:pharma_b2b/widgets/search_surface.dart';

String _src(String p) => File(p).readAsStringSync();

/// The source of ONE class, so a source assertion cannot accidentally read
/// the file's other classes and pass (or fail) on their account.
String _classSrc(String src, String decl) {
  final from = src.indexOf(decl);
  if (from < 0) return '';
  final next = src.indexOf('\nclass ', from + decl.length);
  return next < 0 ? src.substring(from) : src.substring(from, next);
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
  });

  group('1 — the header row is logo · pill · bell', () {
    final chrome = _src('lib/screens/shell/shell_mobile_chrome.dart');

    test('the customer row draws the MARK only — no wordmark text', () {
      final row = _classSrc(chrome, 'class _CustomerHeaderRow');
      expect(row.contains('BrandLockup(markOnly: true)'), isTrue,
          reason: 'the header lock-up must be the mark alone');
      expect(row.contains('BrandLockup.wordWidth'), isFalse,
          reason: 'nothing in the row measures a wordmark any more');
      expect(row.contains('wordWrapper'), isFalse);
      expect(row.contains('headerWordGap'), isFalse);
    });

    test('the row is the pill and the bell, and it decides no words', () {
      final row = _classSrc(chrome, 'class _CustomerHeaderRow');
      expect(row.contains('OrderHoursHeaderPill()'), isTrue);
      expect(row.contains("identifier: 'c2147_bell'"), isTrue);
      expect(RegExp(r"Text\('").hasMatch(row), isFalse,
          reason: 'a display string in the header row is a backend gap');
    });
  });

  group('2 — the band is every tab, and it is one driver', () {
    test('every customer tab collapses its header row', () {
      shellHeaderBandEveryTab.value = true;
      for (final i in [0, 1, 2, 12, 15]) {
        expect(shellHeaderBandTab(i), isTrue, reason: 'tab $i keeps its header');
      }
    });

    test('the backend can still name only the two #2052 tabs', () {
      shellHeaderBandEveryTab.value = false;
      expect(shellHeaderBandTab(0), isTrue);
      expect(shellHeaderBandTab(12), isTrue);
      expect(shellHeaderBandTab(1), isFalse);
      shellHeaderBandEveryTab.value = true;
    });

    test('the settle is the backend\'s 200 ms, and there is one of it', () {
      final chrome = _src('lib/screens/shell/shell_header_chrome.dart');
      expect(chrome.contains('const Duration _kStickyMotion ='), isTrue);
      expect(Ds.touch.headerSettleMs, greaterThan(0));
    });
  });

  group('3 — the pill prints the backend, verbatim', () {
    testWidgets('label and tone come from the payload and nothing else',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OrderHoursPill(
            pill: const {
              'state': 'open',
              'label': 'Open till 9:30 pm',
              'tone': {'bg': '#D1FAE5', 'fg': '#065F46', 'dot': '#065F46'},
              'pulse': false,
            },
            sheet: const {},
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('Open till 9:30 pm'), findsOneWidget,
          reason: 'the pill prints header_status_pill().text verbatim');
    });

    testWidgets('an empty label draws no pill at all', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: OrderHoursPill(pill: {'label': ''}, sheet: {})),
      ));
      await t.pumpAndSettle();
      expect(find.byType(Semantics), findsWidgets);
      expect(find.text(''), findsNothing);
    });

    test('the label is never scaled and never shrunk', () {
      final src = _src('lib/widgets/order_hours_pill.dart');
      expect(src.contains('textScaler: TextScaler.noScaling'), isTrue);
      expect(src.contains('FittedBox('), isFalse,
          reason: 'CMD #2164/#2175: one line, 14 sp, never shrinks');
      expect(Ds.touch.headerPillText, 14);
    });

    // Om, on #1523: "Pill is 40 dp radius 20 — same as the logo tile and the
    // search box." The three round things on the header's row are one size.
    test('the pill is the logo tile\'s size, at the search box\'s corner', () {
      expect(Ds.touch.headerPill, 40);
      expect(Ds.touch.headerPill, Ds.touch.headerTile,
          reason: 'the pill drifted off the logo tile again');
      expect(Ds.touch.headerPill, Ds.shell.boxHeight,
          reason: 'the pill drifted off the search box again');
      expect(Ds.header.pillRadius, 20);
      expect(Ds.header.pillRadius * 2, Ds.touch.headerPill,
          reason: 'the pill stopped being a full-radius pill');
      expect(Ds.header.pillRadius, Ds.shell.boxRadius);
      final src = _src('lib/widgets/order_hours_pill.dart');
      expect(src.contains('height: Ds.touch.headerPill'), isTrue);
      expect(src.contains('BorderRadius.circular(Ds.header.pillRadius)'), isTrue);
    });

    // Om, on #1521: "Flutter must not pick a zone itself and must not default
    // to Raipur." The backend resolves the zone AND says which scope it used
    // ('zone' / 'universal'); this side asks order_hours_state() for it with
    // no argument and prints what comes back.
    test('the app names no zone — the backend resolves it', () {
      final model = _src('lib/models/order_hours_model.dart');
      expect(model.contains("rpc('order_hours_state')"), isTrue,
          reason: 'the pill stopped asking the one door');
      expect(RegExp(r"rpc\('order_hours_state',\s*params").hasMatch(model), isFalse,
          reason: 'Dart started choosing the zone it is shown');
      for (final f in const [
        'lib/models/order_hours_model.dart',
        'lib/widgets/order_hours_pill.dart',
        'lib/screens/shell/shell_mobile_chrome.dart',
      ]) {
        expect(_src(f).contains('Raipur'), isFalse,
            reason: '$f names a zone of its own');
      }
    });
  });

  group('4 — search is per tab, and the tab key is the backend\'s', () {
    test('every customer tab maps to a backend row key', () {
      expect(shellTabKey(0), 'home');
      expect(shellTabKey(1), 'orders');
      expect(shellTabKey(2), 'bulk');
      expect(shellTabKey(12), 'catalogue');
      expect(shellTabKey(15), 'profile');
    });

    test('a scope notifier is shared, not rebuilt per listener', () {
      expect(identical(shellScopeQuery('orders'), shellScopeQuery('orders')),
          isTrue);
      expect(identical(shellScopeQuery('orders'), shellScopeQuery('profile')),
          isFalse);
    });

    test('the placeholder and the scope are read, never written', () {
      final bar = _classSrc(_src('lib/screens/shell/shell_tab_search.dart'),
          'class _ShellTabSearchBarState');
      expect(bar.contains("(row['placeholder'] ?? '').toString()"), isTrue);
      expect(bar.contains("(row['scope'] ?? 'catalog').toString()"), isTrue);
      expect(RegExp(r"placeholder:\s*'[A-Za-z]").hasMatch(bar), isFalse,
          reason: 'a placeholder written in Dart is a backend gap');
    });

    test('Orders and Profile answer the scope the backend named', () {
      expect(_src('lib/screens/orders_screen.dart')
          .contains("shellScopeQuery('orders')"), isTrue);
      expect(_src('lib/screens/customer/profile_tab_screen.dart')
          .contains("shellScopeQuery('profile')"), isTrue);
      expect(_src('lib/screens/customer/profile_tab_screen.dart')
          .contains("'customer_profile_search'"), isTrue);
    });

    test('the Orders tab has no second search box of its own', () {
      final src = _src('lib/screens/orders_screen.dart');
      final header = _classSrc(src, 'class _OrdersHeader');
      expect(header.contains('TextField('), isFalse,
          reason: 'the shell owns the Orders search box now');
    });
  });

  group('5 — ONE height, and it is the backend\'s', () {
    test('Om\'s redline: 56 · 14 · 28 · 10', () {
      expect(Ds.shell.height, 56);
      expect(Ds.shell.inset, 14);
      expect(Ds.shell.radius, 28);
      expect(Ds.shell.gap, 10);
    });

    // Om, on #1521: "56 dp is the TOTAL of each row, GAPS INCLUDED." The row
    // is pad + box + pad, and the box is the logo tile's own 40 so the two
    // read as one optical line.
    test('the search row is its gaps plus its box, and that IS 56', () {
      expect(Ds.shell.boxHeight, 40);
      expect(Ds.shell.padY, 8);
      expect(Ds.shell.boxRadius, 20);
      expect(Ds.shell.padY * 2 + Ds.shell.boxHeight, Ds.shell.height,
          reason: 'the gaps left the row again — the block is taller than 56');
      expect(Ds.shell.boxRadius * 2, Ds.shell.boxHeight,
          reason: 'the box stopped being a full-radius pill');
      expect(SearchHeaderBar.fieldHeight, Ds.shell.boxHeight);
    });

    test('the search row has no scrolled variant', () {
      final chrome = _src('lib/screens/shell/shell_header_chrome.dart');
      final surface = _src('lib/widgets/search_surface.dart');
      // Om: "There is no scrolled variant of the header row — it is either
      // fully shown or fully hidden", and the search row under it never
      // changes size, inset or contents.
      expect(chrome.contains('_StickyBell'), isFalse,
          reason: 'the bell came back onto the search row');
      expect(chrome.contains('_shellStuckFlag'), isFalse,
          reason: 'the search row grew a compact state again');
      expect(chrome.contains("key: const ValueKey('mark')"), isFalse,
          reason: 'the m mark came back onto the search row');
      expect(surface.contains('compactFieldHeight'), isFalse);
      expect(RegExp(r'final EdgeInsets pad = EdgeInsets\.fromLTRB\(\s*'
              r'Ds\.shell\.inset, Ds\.shell\.padY, Ds\.shell\.inset, Ds\.shell\.padY\)')
          .hasMatch(surface), isTrue,
          reason: 'the search row stopped being one inset in every state');
      expect(surface.contains('stuck ?'), isFalse,
          reason: 'the search row grew a scrolled variant again');
    });

    test('the five pieces of chrome are the one number', () {
      expect(Ds.touch.headerBand, Ds.shell.height,
          reason: 'the header row');
      expect(FloatingDock.dockHeight, Ds.shell.height, reason: 'the nav row');
      expect(FloatingDock.barHeight, Ds.shell.height, reason: 'the banner');
      expect(CartPill.kHeight, Ds.shell.height, reason: 'the View cart pill');
      // The search ROW is the shell height; its BOX is the 40 inside it.
      expect(Ds.shell.padY * 2 + SearchHeaderBar.fieldHeight, Ds.shell.height,
          reason: 'the search row');
    });

    test('the typed word is centred in the field, not padded into place', () {
      // Om, on the live build: the search text sat high in the pill. A fixed
      // vertical contentPadding is what decided that, and it went wrong the
      // moment the field's height moved. The input centres itself now, at any
      // height the backend sends.
      final src = _src('lib/widgets/search_surface.dart');
      // Om, on #1521: "Flutter reads them, nothing hardcoded." WHERE the text
      // sits is `shell_style().search.text_align_v`, so the field asks the
      // token rather than naming Flutter's constant itself.
      expect(src.contains('textAlignVertical: Ds.shell.textAlign'), isTrue);
      expect(src.contains('TextAlignVertical.center'), isFalse,
          reason: 'the field named the constant again instead of the token');
      expect(Ds.shell.textAlignV, 'center');
      expect(Ds.shell.textAlign, TextAlignVertical.center);
      expect(
          RegExp(r'contentPadding:\s*\n?\s*EdgeInsets\.symmetric\(vertical:')
              .hasMatch(src),
          isFalse,
          reason: 'the search field went back to padding its text into place');
    });

    test('the inset and the corner are shared too', () {
      expect(FloatingDock.edge, Ds.shell.inset);
      expect(FloatingDock.radius, Ds.shell.radius);
      // The dock card wears the ROW's 28; the search BOX wears its own 20.
      expect(_src('lib/widgets/search_surface.dart')
          .contains('BorderRadius.circular(Ds.shell.boxRadius)'), isTrue);
    });

    test('a backend patch moves all five, with no deploy', () {
      Ds.apply(const {
        'shell': {'height': 60, 'inset': 16, 'radius': 30, 'gap': 12}
      });
      expect(Ds.shell.height, 60);
      expect(Ds.touch.headerBand, 60);
      expect(FloatingDock.dockHeight, 60);
      expect(FloatingDock.edge, 16);
      expect(FloatingDock.radius, 30);
      expect(CartPill.kHeight, 60);
      // …and back, so the rest of the suite sees Om's redline.
      Ds.apply(const {
        'shell': {'height': 56, 'inset': 14, 'radius': 28, 'gap': 10}
      });
      expect(Ds.shell.height, 56);
    });
  });
}

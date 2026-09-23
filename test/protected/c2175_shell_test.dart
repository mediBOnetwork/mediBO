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
      expect(Ds.touch.headerPill, 32);
      expect(Ds.touch.headerPillText, 14);
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
      final chrome = _src('lib/screens/shell/shell_header_chrome.dart');
      final bar = _classSrc(chrome, 'class _ShellTabSearchBarState');
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

    test('the five pieces of chrome are the one number', () {
      expect(Ds.touch.headerBand, Ds.shell.height,
          reason: 'the header row');
      expect(FloatingDock.dockHeight, Ds.shell.height, reason: 'the nav row');
      expect(FloatingDock.barHeight, Ds.shell.height, reason: 'the banner');
      expect(CartPill.kHeight, Ds.shell.height, reason: 'the View cart pill');
      expect(_src('lib/widgets/search_surface.dart')
          .contains('final double field = Ds.shell.height;'), isTrue,
          reason: 'the search field');
    });

    test('the inset and the corner are shared too', () {
      expect(FloatingDock.edge, Ds.shell.inset);
      expect(FloatingDock.radius, Ds.shell.radius);
      expect(_src('lib/widgets/search_surface.dart')
          .contains('BorderRadius.circular(Ds.shell.radius)'), isTrue);
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

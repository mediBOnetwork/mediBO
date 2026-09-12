// CHANGE #1017 — the staff visual system computes nothing.
//
// Holds down: the header scope, every sentence and the view-as preview arrive
// in staff_nav() and are rendered VERBATIM (a preview is never cached); the one
// list row draws colour only for STATE and a badge only when work is waiting;
// the pulse badge and the offline banner are absent at zero; a zone-locked
// partner gets a label, never a picker; the dark palette is a token swap and
// nothing else changes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/services/staff_nav.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/offline_banner.dart';
import 'package:pharma_b2b/widgets/pulse_badge.dart';
import 'package:pharma_b2b/widgets/staff_row.dart';

const _nav = {
  'ok': true, 'role': 'super_admin', 'layout': 'v2', 'layout_note': '',
  'tabs': [
    {'key': 'dashboard', 'label': 'Dashboard', 'icon_key': 'dash', 'route_key': 'dashboard', 'badge_key': '', 'visible': true},
    {'key': 'fulfill', 'label': 'Fulfil', 'icon_key': 'box', 'route_key': 'fulfillment', 'badge_key': 'order_alerts', 'visible': true},
  ],
  'redirects': {},
  'scope': {'zone_id': 1, 'zone_label': 'Raipur Zone', 'zone_locked': false, 'zone_locked_label': 'Your zone',
            'can_pick_zone': true, 'can_pick_all': true, 'date': '2026-09-04', 'date_label': 'Today', 'can_pick_date': true},
  'copy': {'offline_banner': 'Offline — {n} action(s) queued', 'undo': 'Undo', 'empty_title': 'Nothing here yet',
           'empty_hint': 'When there is work waiting it shows here first.', 'dark_mode': 'Dark mode', 'dark_system': 'Follow device'},
  'view_as': {'active': true, 'role': 'partner', 'can_preview': true, 'title': 'View as',
              'options': [{'role': 'admin', 'label': 'Admin'}, {'role': 'partner', 'label': 'Partner'}],
              'banner': 'Viewing as Partner — this is what they see', 'exit_label': 'Exit preview'},
};

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('staff_nav() payload', () {
    test('scope, copy and view_as are carried verbatim', () {
      final p = StaffNavPayload.fromJson(Map<String, dynamic>.from(_nav));
      expect(p.ok, isTrue);
      expect(p.scope['zone_label'], 'Raipur Zone');
      expect(p.scope['date_label'], 'Today');
      expect(p.copyOf('undo'), 'Undo');
      expect(p.copyOf('offline_banner'), contains('{n}'));
      expect(p.isPreview, isTrue);
      expect(p.previewBanner, 'Viewing as Partner — this is what they see');
      expect(p.previewExitLabel, 'Exit preview');
      expect(p.previewOptions.map((o) => o['role']), ['admin', 'partner']);
    });

    test('a payload without the new blocks still parses (forward compat)', () {
      final p = StaffNavPayload.fromJson({'ok': true, 'tabs': [], 'redirects': {}});
      expect(p.ok, isTrue);
      expect(p.scope, isEmpty);
      expect(p.isPreview, isFalse);
      expect(p.previewOptions, isEmpty);
      expect(p.copyOf('undo'), '');
    });

    test('an unauthorised answer is the empty payload', () {
      expect(StaffNavPayload.fromJson({'ok': false, 'error': 'not_authorized'}).ok, isFalse);
    });
  });

  group('StaffRow — colour is state, a badge is work', () {
    test('tone words map to the state palette and nothing else', () {
      expect(StaffRow.toneColor('bad'), Ds.c.danger);
      expect(StaffRow.toneColor('overdue'), Ds.c.danger);
      expect(StaffRow.toneColor('warn'), Ds.c.warning);
      expect(StaffRow.toneColor('due'), Ds.c.warning);
      expect(StaffRow.toneColor('good'), Ds.c.success);
      expect(StaffRow.toneColor('done'), Ds.c.success);
      expect(StaffRow.toneColor(''), Ds.c.textSecondary);
      expect(StaffRow.toneColor('purple'), Ds.c.textSecondary, reason: 'an unknown tone is neutral, never invented');
    });

    testWidgets('title, number and chevron; no badge at zero', (t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(body: StaffRow(row: const {
        'title': 'ORD-2201', 'subtitle': 'Sharma Medicos', 'tone': 'warn', 'value_label': '₹4,200', 'badge_count': 0}))));
      expect(find.text('ORD-2201'), findsOneWidget);
      expect(find.text('Sharma Medicos'), findsOneWidget);
      expect(find.text('₹4,200'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(find.text('0'), findsNothing, reason: 'a zero is not work waiting');
    });

    testWidgets('a badge replaces the number when work is waiting', (t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(body: StaffRow(row: const {
        'title': 'Exceptions', 'value_label': 'ignored', 'badge_count': 3}))));
      expect(find.text('3'), findsOneWidget);
      expect(find.text('ignored'), findsNothing);
    });

    testWidgets('the empty state prints the backend copy and its action', (t) async {
      var tapped = false;
      await t.pumpWidget(MaterialApp(home: Scaffold(body: StaffEmptyState(
        empty: const {'title': 'Nothing here yet', 'hint': 'Work shows here first.', 'action_label': 'Open queue'},
        onAction: () => tapped = true))));
      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(find.text('Work shows here first.'), findsOneWidget);
      await t.tap(find.text('Open queue'));
      expect(tapped, isTrue);
    });
  });

  group('motion and offline — absent at zero', () {
    testWidgets('PulseBadge draws no badge at 0 and a badge above it', (t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: PulseBadge(count: 0, child: Icon(Icons.inbox)))));
      expect(find.byType(Badge), findsNothing);
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: PulseBadge(count: 2, child: Icon(Icons.inbox)))));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('OfflineBanner is nothing while nothing is queued', (t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: OfflineBanner(template: 'Offline — {n} queued'))));
      expect(find.textContaining('Offline'), findsNothing);
    });
  });

  group('dark mode is a token swap', () {
    test('setBrightness swaps Ds.c and bumps the revision; light restores', () {
      final light = Ds.c;
      final before = Ds.revision.value;
      Ds.setBrightness(Brightness.dark);
      expect(Ds.isDark, isTrue);
      expect(Ds.c.bg, Ds.dark.bg);
      // State colours keep their MEANING, not their hex: the dark palette
      // carries its own red (the token set's, not a Dart literal).
      expect(Ds.c.danger, Ds.dark.danger);
      expect(Ds.c.success, Ds.dark.success);
      expect(Ds.revision.value, greaterThan(before));
      Ds.setBrightness(Brightness.light);
      expect(Ds.isDark, isFalse);
      expect(Ds.c.bg, light.bg);
    });
  });
}

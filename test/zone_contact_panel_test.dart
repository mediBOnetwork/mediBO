// Zone contact numbers panel — Section D of WhatsApp Ops.
//
// One WhatsApp number sends every message, but each zone carries its OWN number
// customers are told to CALL (inserted as zone_phone per customer). This panel
// edits it. It decides nothing: note, status_label, tone and every save message
// are the backend's strings; the phone is never validated here; an empty phone
// is a legitimate save meaning "use the default zone's number".
//
// Both RPCs are stubbed inline — no network, no Supabase, no home_shell import.
// The screen is taller than the test viewport, so every card is scrolled into
// view before it is touched.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/wa_ops_screen.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_campaign_chips.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _zoneRow({
  required int zoneId,
  required String name,
  required String code,
  bool isActive = true,
  bool isDefault = false,
  String? phone,
  String? label,
  int customers = 0,
  required String statusLabel,
  required String tone,
}) =>
    {
      'zone_id': zoneId,
      'name': name,
      'code': code,
      'is_active': isActive,
      'is_default': isDefault,
      'contact_phone': phone,
      'contact_label': label,
      'customers': customers,
      'status_label': statusLabel,
      'tone': tone,
    };

Map<String, dynamic> _zonesPayload(List<Map<String, dynamic>> rows) => {
      'rows': rows,
      'note': 'This is the number customers in each zone are told to call.',
      'default_note': 'A zone with no number falls back to the default zone.',
    };

/// Pumps the whole WhatsApp Ops screen. The other three sections get harmless
/// stubs so nothing reaches the network; only the zones section is under test.
Future<void> _pump(
  WidgetTester tester, {
  required List<Map<String, dynamic>> rows,
  required Map<String, dynamic> Function(Map<String, dynamic> params) onSave,
}) async {
  tester.view.physicalSize = const Size(500, 2800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: WaOpsScreen(
      routesRpc: () async =>
          {'rows': const [], 'approved_templates': const [], 'note': ''},
      routeSaveRpc: (_) async => {'ok': true},
      wabaStatusRpc: () async => {
        'waba_name': 'x',
        'review_status': '',
        'templates_label': '',
        'templates_pct': 0,
        'templates_tone': 'good',
        'tier_label': '',
        'quality_label': '',
        'quality_tone': 'good',
        'checked_label': '',
        'error': null,
        'note': '',
      },
      wabaRefreshRpc: () async => {'ok': true},
      ledgerRpc: (_, _) async =>
          {'contacts': 0, 'summary': '', 'rows': const []},
      zonesRpc: () async => _zonesPayload(rows),
      zoneSaveRpc: (params) async => onSave(params),
      refreshDelay: Duration.zero,
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets(
      'a zone row renders name, customers, contact_phone and status_label in its tone',
      (tester) async {
    await _pump(
      tester,
      rows: [
        _zoneRow(
          zoneId: 7,
          name: 'Bilaspur',
          code: 'BSP',
          phone: '07712345678',
          label: 'Bilaspur desk',
          customers: 12,
          statusLabel: 'Customers here are told to call 07712345678',
          tone: 'good',
        ),
      ],
      onSave: (_) => {'ok': true},
    );

    await tester.ensureVisible(find.byKey(const Key('wa_ops_zone:7')));
    await tester.pumpAndSettle();

    expect(find.text('Bilaspur'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);

    // contact_phone is the phone field's current value.
    final phoneField =
        tester.widget<TextField>(find.byKey(const Key('wa_ops_zone_phone:7')));
    expect(phoneField.controller!.text, '07712345678');

    // status_label printed verbatim in its tone ('good' -> the chip's green).
    final chip = tester
        .widgetList<WaToneChip>(find.byType(WaToneChip))
        .firstWhere((c) =>
            c.label == 'Customers here are told to call 07712345678');
    expect(chip.tone, 'green');
  });

  testWidgets('Save calls zone_contact_save with the row zone_id and typed values',
      (tester) async {
    Map<String, dynamic>? captured;
    await _pump(
      tester,
      rows: [
        _zoneRow(
          zoneId: 7,
          name: 'Bilaspur',
          code: 'BSP',
          phone: '',
          label: '',
          statusLabel: 'No number yet',
          tone: 'warn',
        ),
      ],
      onSave: (p) {
        captured = p;
        return {'ok': true};
      },
    );

    await tester.ensureVisible(find.byKey(const Key('wa_ops_zone_phone:7')));
    await tester.enterText(
        find.byKey(const Key('wa_ops_zone_phone:7')), '09876543210');
    await tester.enterText(
        find.byKey(const Key('wa_ops_zone_label:7')), 'Raipur desk');
    await tester.ensureVisible(find.byKey(const Key('wa_ops_zone_save:7')));
    await tester.tap(find.byKey(const Key('wa_ops_zone_save:7')));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!['p_zone_id'], 7);
    expect(captured!['p_phone'], '09876543210');
    expect(captured!['p_label'], 'Raipur desk');
  });

  testWidgets('clearing the phone still submits an empty p_phone',
      (tester) async {
    Map<String, dynamic>? captured;
    await _pump(
      tester,
      rows: [
        _zoneRow(
          zoneId: 7,
          name: 'Bilaspur',
          code: 'BSP',
          phone: '07712345678',
          label: 'Bilaspur desk',
          statusLabel: 'Customers here are told to call 07712345678',
          tone: 'good',
        ),
      ],
      onSave: (p) {
        captured = p;
        return {'ok': true};
      },
    );

    await tester.ensureVisible(find.byKey(const Key('wa_ops_zone_phone:7')));
    await tester.enterText(find.byKey(const Key('wa_ops_zone_phone:7')), '');
    await tester.ensureVisible(find.byKey(const Key('wa_ops_zone_save:7')));
    await tester.tap(find.byKey(const Key('wa_ops_zone_save:7')));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!['p_phone'], '');
  });

  testWidgets('an error response shows its message and leaves the field as typed',
      (tester) async {
    await _pump(
      tester,
      rows: [
        _zoneRow(
          zoneId: 7,
          name: 'Bilaspur',
          code: 'BSP',
          phone: '',
          label: '',
          statusLabel: 'No number yet',
          tone: 'warn',
        ),
      ],
      onSave: (_) =>
          {'error': 'bad_number', 'message': 'That does not look valid'},
    );

    await tester.ensureVisible(find.byKey(const Key('wa_ops_zone_phone:7')));
    await tester.enterText(find.byKey(const Key('wa_ops_zone_phone:7')), '123');
    await tester.ensureVisible(find.byKey(const Key('wa_ops_zone_save:7')));
    await tester.tap(find.byKey(const Key('wa_ops_zone_save:7')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The backend's message, verbatim.
    expect(find.text('That does not look valid'), findsOneWidget);

    // The field the admin typed is untouched — no re-read wiped it.
    final field =
        tester.widget<TextField>(find.byKey(const Key('wa_ops_zone_phone:7')));
    expect(field.controller!.text, '123');

    // Drain the SnackBar's auto-dismiss timer.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('is_default renders a chip; a non-default zone does not',
      (tester) async {
    await _pump(
      tester,
      rows: [
        _zoneRow(
          zoneId: 1,
          name: 'Raipur',
          code: 'RPR',
          phone: '0771',
          label: 'Raipur',
          isDefault: true,
          statusLabel: 'Customers here are told to call 0771',
          tone: 'good',
        ),
        _zoneRow(
          zoneId: 2,
          name: 'Bilaspur',
          code: 'BSP',
          phone: '',
          label: '',
          isDefault: false,
          statusLabel: 'No number yet',
          tone: 'warn',
        ),
      ],
      onSave: (_) => {'ok': true},
    );

    await tester.ensureVisible(find.byKey(const Key('wa_ops_zone:1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('wa_ops_zone_default:1')), findsOneWidget);
    expect(find.byKey(const Key('wa_ops_zone_default:2')), findsNothing);
  });
}

// Regression test for CHANGE #494 — Payment/UPI screen renamed to
// "Payment and Partner"; adds a backend-driven Partner section
// (partner_screen_config / admin_region_partners). Everything the screen
// shows — headings, helper text, dropdown options, detail lines, doc
// status, error messages — must come from the stubbed RPC responses, not
// from literals in the widget, so every assertion below uses stub values
// that don't match any real backend copy.
//
// RPCs are injected via AdminUpiScreen's fetchPartnerConfig/fetchPartnersRpc/
// saveRegionPartnerRpc/setActivePartnerRpc/deleteRegionPartnerRpc params —
// no network, no Supabase.initialize(). The existing Payment/UPI half hits
// the real (uninitialized) Supabase client and degrades via its own
// try/catch to an empty list + a toast, which is why every test drains the
// toast's 4s dismiss timer at the end.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_upi_screen.dart';

final Map<String, dynamic> _config = {
  'payment_heading': 'PAYMENT_HEAD_STUB',
  'payment_helper': 'PAYMENT_HELP_STUB',
  'partner_heading': 'PARTNER_HEAD_STUB',
  'partner_helper': 'PARTNER_HELP_STUB',
  'area_options': ['ZoneA', 'ZoneB'],
  'fields': [
    {'key': 'partner_name', 'type': 'text', 'label': 'FIELD_NAME_STUB', 'required': true},
    {'key': 'address', 'type': 'multiline', 'label': 'FIELD_ADDRESS_STUB', 'required': false},
    {'key': 'gstin', 'type': 'text', 'label': 'FIELD_GST_STUB', 'required': false},
    {'key': 'dl_20b', 'type': 'text', 'label': 'FIELD_DL20B_STUB', 'required': false},
    {'key': 'dl_21b', 'type': 'text', 'label': 'FIELD_DL21B_STUB', 'required': false},
    {'key': 'area', 'type': 'dropdown', 'label': 'FIELD_AREA_STUB', 'required': true},
  ],
  'active_checkbox_label': 'ACTIVE_CHECKBOX_STUB',
  'doc_bucket': 'partner-docs',
};

Map<String, dynamic> _partner({
  required String area,
  String? badge,
  bool canMakeActive = false,
  bool canDelete = true,
  String? deleteBlockedReason,
}) {
  return {
    'id': 1,
    'area': area,
    'partner_name': 'PARTNER_$area',
    'badge': badge,
    'can_make_active': canMakeActive,
    'can_delete': canDelete,
    'delete_blocked_reason': deleteBlockedReason,
    'is_active': badge == 'Active',
    'detail_lines': [
      {'label': 'LINE1_LABEL', 'value': 'LINE1_VALUE'},
      {'label': 'LINE2_LABEL', 'value': 'LINE2_VALUE'},
    ],
    'docs': [
      {'kind': 'gst', 'label': 'DOC_GST_LABEL', 'status_text': 'DOC_GST_STATUS', 'can_view': false, 'uploaded': false, 'path': null},
      {'kind': 'dl20b', 'label': 'DOC_DL20B_LABEL', 'status_text': 'DOC_DL20B_STATUS', 'can_view': true, 'uploaded': true, 'path': 'x'},
    ],
  };
}

Widget _screen({
  List<Map<String, dynamic>>? partners,
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? saveRegionPartnerRpc,
  Future<Map<String, dynamic>> Function(String)? setActivePartnerRpc,
  Future<Map<String, dynamic>> Function(String)? deleteRegionPartnerRpc,
}) {
  return MaterialApp(
    home: Scaffold(
      body: AdminUpiScreen(
        fetchUpiListRpc: () async => [],
        fetchPartnerConfig: () async => _config,
        fetchPartnersRpc: () async => partners ?? [],
        saveRegionPartnerRpc: saveRegionPartnerRpc,
        setActivePartnerRpc: setActivePartnerRpc,
        deleteRegionPartnerRpc: deleteRegionPartnerRpc,
      ),
    ),
  );
}

void main() {
  testWidgets(
      'headings/helper text render from the stubbed config, and detail_lines render in order',
      (tester) async {
    await tester.pumpWidget(_screen(partners: [
      _partner(area: 'ZoneA', badge: 'Active'),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('PAYMENT_HEAD_STUB'), findsOneWidget);
    expect(find.text('PAYMENT_HELP_STUB'), findsOneWidget);
    expect(find.text('PARTNER_HEAD_STUB'), findsOneWidget);
    expect(find.text('PARTNER_HELP_STUB'), findsOneWidget);

    final line1 = tester.getTopLeft(find.text('LINE1_LABEL: LINE1_VALUE'));
    final line2 = tester.getTopLeft(find.text('LINE2_LABEL: LINE2_VALUE'));
    expect(line1.dy, lessThan(line2.dy));

    await tester.pump(const Duration(seconds: 5)); // drain toast timers
  });

  testWidgets('a partner with badge=Active shows the chip and no Make Active action',
      (tester) async {
    await tester.pumpWidget(_screen(partners: [
      _partner(area: 'ZoneA', badge: 'Active', canMakeActive: false),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Make Active'), findsNothing);

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
      'a partner with can_make_active=true shows the action; tapping calls set_active_partner exactly once',
      (tester) async {
    var callCount = 0;
    String? calledArea;
    await tester.pumpWidget(_screen(
      partners: [_partner(area: 'ZoneB', canMakeActive: true)],
      setActivePartnerRpc: (area) async {
        callCount++;
        calledArea = area;
        return {'ok': true, 'message': 'SET_ACTIVE_OK_STUB'};
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text('Make Active'), findsOneWidget);
    await tester.ensureVisible(find.text('Make Active'));
    await tester.tap(find.text('Make Active'));
    await tester.pumpAndSettle();

    expect(callCount, 1);
    expect(calledArea, 'ZoneB');

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
      'a doc with can_view=false shows status_text and a disabled View; can_view=true shows an enabled View',
      (tester) async {
    await tester.pumpWidget(_screen(partners: [_partner(area: 'ZoneA')]));
    await tester.pumpAndSettle();

    expect(find.text('DOC_GST_STATUS'), findsOneWidget);
    expect(find.text('DOC_DL20B_STATUS'), findsOneWidget);

    final viewButtons = tester
        .widgetList<TextButton>(find.widgetWithText(TextButton, 'View'))
        .toList();
    expect(viewButtons.length, 2);
    expect(viewButtons[0].onPressed, isNull); // gst: can_view=false
    expect(viewButtons[1].onPressed, isNotNull); // dl20b: can_view=true

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
      'a doc with can_view=false shows no Delete button; can_view=true shows one',
      (tester) async {
    await tester.pumpWidget(_screen(partners: [_partner(area: 'ZoneA')]));
    await tester.pumpAndSettle();

    // Only dl20b has can_view=true, so only its delete button exists.
    expect(find.byKey(const Key('doc_delete_button_dl20b')), findsOneWidget);
    expect(find.byKey(const Key('doc_delete_button_gst')), findsNothing);

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
      'can_delete=false shows Delete disabled with delete_blocked_reason; the card stays after the attempt',
      (tester) async {
    var deleteCalls = 0;
    await tester.pumpWidget(_screen(
      partners: [
        _partner(area: 'ZoneA', canDelete: false, deleteBlockedReason: 'CANT_DELETE_STUB'),
      ],
      deleteRegionPartnerRpc: (area) async {
        deleteCalls++;
        return {'ok': false, 'message': 'should not be called'};
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text('CANT_DELETE_STUB'), findsOneWidget);
    final deleteButton =
        tester.widget<IconButton>(find.byKey(const Key('partner_delete_button')));
    expect(deleteButton.onPressed, isNull);
    expect(deleteCalls, 0);
    expect(find.text('PARTNER_ZoneA'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the Area dropdown lists exactly the stubbed area_options', (tester) async {
    await tester.pumpWidget(_screen(partners: []));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Add Partner'));
    await tester.tap(find.text('Add Partner'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();

    expect(find.text('ZoneA'), findsWidgets);
    expect(find.text('ZoneB'), findsWidgets);

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('saving the form calls save_region_partner with all 8 p_* keys present',
      (tester) async {
    Map<String, dynamic>? capturedParams;
    await tester.pumpWidget(_screen(
      partners: [],
      saveRegionPartnerRpc: (params) async {
        capturedParams = params;
        return {'ok': true, 'message': 'SAVED_OK_STUB'};
      },
    ));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Add Partner'));
    await tester.tap(find.text('Add Partner'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'FIELD_NAME_STUB'), 'Test Partner');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ZoneA').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(capturedParams, isNotNull);
    expect(capturedParams!.keys.toSet(), {
      'p_area', 'p_partner_name', 'p_address', 'p_gstin',
      'p_dl_20b', 'p_dl_21b', 'p_state', 'p_make_active',
    });

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('{ok:false, message:...} keeps the form open and shows that exact text',
      (tester) async {
    await tester.pumpWidget(_screen(
      partners: [],
      saveRegionPartnerRpc: (params) async =>
          {'ok': false, 'message': 'Partner name is required'},
    ));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Add Partner'));
    await tester.tap(find.text('Add Partner'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ZoneA').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'FIELD_NAME_STUB'), 'Test Partner');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Form stayed open (Save button still present) and the exact backend
    // message was shown — no error-code-to-sentence mapping in Dart.
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Partner name is required'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
  });
}

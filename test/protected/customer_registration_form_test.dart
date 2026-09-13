// PROTECTED — CHANGE #1887.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes registration-form behaviour, never to make an unrelated
// change go green.
//
// What this holds down:
//
//   1. There is ONE registration form and its field list is a PAYLOAD.
//      customer_form_schema() decides which fields exist, what they are
//      called, in what order they appear, which are required and what each
//      dropdown offers. Self-signup, Import customer and Convert lead all
//      render this widget, so a re-worded label is an UPDATE on
//      customer_form_field — never a deploy, and never a Dart literal.
//
//   2. PAYLOAD ORDER. The fixture is deliberately NOT alphabetical and its
//      sort_order values are deliberately not 1..n: the form must print the
//      sections and fields exactly as the backend handed them over.
//
//   3. The required marker, the "check this" chip and the missing-fields
//      sentence are backend strings. Nothing about "*" or "required" is
//      composed here.
//
//   4. Forward compatibility. A field type this build has never heard of
//      still renders as a plain input instead of throwing, so the backend can
//      ship a new type to clients already in the field.
//
//   5. payload() sends only what the SCHEMA listed and only what was typed —
//      an untouched field is omitted so the backend applies its own default,
//      and a stray prefill key the schema does not carry is never sent.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/customer_registration_form.dart';
import 'package:pharma_b2b/widgets/import_customer_sheet.dart';

/// A schema shaped exactly like customer_form_schema(): sections out of
/// alphabetical order, fields whose sort_order is sparse, one select with the
/// backend's own options and one type this build does not know.
Map<String, dynamic> _schema() => {
      'ok': true,
      'context': 'admin',
      'title': 'PAYLOAD TITLE',
      'subtitle': 'PAYLOAD SUBTITLE',
      'required_suffix': ' ‹needed›',
      'loading_label': 'PAYLOAD LOADING',
      'flag_label': 'PAYLOAD FLAG',
      'missing_required_message': 'PAYLOAD MISSING:',
      'save_label': 'PAYLOAD SAVE',
      'cancel_label': 'PAYLOAD CANCEL',
      'sections': [
        {
          'key': 'zeta',
          'title': 'ZETA SECTION',
          'fields': [
            {
              'key': 'pharmacy_name',
              'section': 'zeta',
              'label': 'PAYLOAD Pharmacy name',
              'hint': 'PAYLOAD hint',
              'type': 'text',
              'required': true,
              'sort_order': 10,
              'half_width': false,
              'max_lines': 1,
              'default': null,
              'options': [],
            },
            {
              'key': 'store_type',
              'section': 'zeta',
              'label': 'PAYLOAD Store type',
              'hint': null,
              'type': 'select',
              'required': false,
              'sort_order': 30,
              'half_width': false,
              'max_lines': 1,
              'default': null,
              'options': ['PAYLOAD Retail', 'PAYLOAD Wholesale'],
            },
          ],
        },
        {
          'key': 'alpha',
          'title': 'ALPHA SECTION',
          'fields': [
            {
              'key': 'whatsapp_no',
              'section': 'alpha',
              'label': 'PAYLOAD WhatsApp',
              'hint': null,
              'type': 'phone',
              'required': true,
              'sort_order': 40,
              'half_width': false,
              'max_lines': 1,
              'default': null,
              'options': [],
            },
            {
              'key': 'dl_expiry',
              'section': 'alpha',
              'label': 'PAYLOAD Licence valid till',
              'hint': null,
              // a type this build has never heard of
              'type': 'someday_new_type',
              'required': false,
              'sort_order': 210,
              'half_width': false,
              'max_lines': 1,
              'default': 'PAYLOAD DEFAULT',
              'options': [],
            },
          ],
        },
      ],
      'fields': [
        {
          'key': 'pharmacy_name',
          'section': 'zeta',
          'label': 'PAYLOAD Pharmacy name',
          'hint': 'PAYLOAD hint',
          'type': 'text',
          'required': true,
          'sort_order': 10,
          'half_width': false,
          'max_lines': 1,
          'default': null,
          'options': [],
        },
        {
          'key': 'store_type',
          'section': 'zeta',
          'label': 'PAYLOAD Store type',
          'hint': null,
          'type': 'select',
          'required': false,
          'sort_order': 30,
          'half_width': false,
          'max_lines': 1,
          'default': null,
          'options': ['PAYLOAD Retail', 'PAYLOAD Wholesale'],
        },
        {
          'key': 'whatsapp_no',
          'section': 'alpha',
          'label': 'PAYLOAD WhatsApp',
          'hint': null,
          'type': 'phone',
          'required': true,
          'sort_order': 40,
          'half_width': false,
          'max_lines': 1,
          'default': null,
          'options': [],
        },
        {
          'key': 'dl_expiry',
          'section': 'alpha',
          'label': 'PAYLOAD Licence valid till',
          'hint': null,
          'type': 'someday_new_type',
          'required': false,
          'sort_order': 210,
          'half_width': false,
          'max_lines': 1,
          'default': 'PAYLOAD DEFAULT',
          'options': [],
        },
      ],
      'required_fields': ['pharmacy_name', 'whatsapp_no'],
    };

Future<void> _pump(WidgetTester tester, CustomerFormController ctrl) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: CustomerRegistrationForm(controller: ctrl),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  setUpAll(() {
    // RenderLog's 800 ms debounce is a real Timer that would outlive the test.
    RenderLog.flushEnabled = false;
  });

  testWidgets('sections and fields print in PAYLOAD order, never sorted',
      (tester) async {
    final ctrl = CustomerFormController()..seed(_schema());
    addTearDown(ctrl.dispose);
    await _pump(tester, ctrl);

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.startsWith('ZETA') || s.startsWith('ALPHA'))
        .toList();
    // ZETA came first in the payload even though ALPHA sorts first.
    expect(texts, ['ZETA SECTION', 'ALPHA SECTION']);

    final zeta = tester.getTopLeft(find.text('ZETA SECTION')).dy;
    final alpha = tester.getTopLeft(find.text('ALPHA SECTION')).dy;
    expect(zeta, lessThan(alpha));
  });

  testWidgets('labels, the required marker and the flag chip are backend copy',
      (tester) async {
    final ctrl = CustomerFormController()..seed(_schema());
    ctrl.flagged.add('whatsapp_no');
    addTearDown(ctrl.dispose);
    await _pump(tester, ctrl);

    // Required fields carry the backend's own suffix — no '*' written here.
    expect(find.text('PAYLOAD Pharmacy name ‹needed›'), findsOneWidget);
    expect(find.text('PAYLOAD WhatsApp ‹needed›'), findsOneWidget);
    // Optional ones carry no suffix at all.
    expect(find.text('PAYLOAD Store type'), findsOneWidget);
    // The chip's word is the payload's.
    expect(find.text('PAYLOAD FLAG'), findsOneWidget);
  });

  testWidgets('a dropdown offers exactly the options the payload sent',
      (tester) async {
    final ctrl = CustomerFormController()..seed(_schema());
    addTearDown(ctrl.dispose);
    await _pump(tester, ctrl);

    // Nothing is pre-selected, so opening the menu shows exactly the
    // backend's list — no "Select…" placeholder invented here, and no option
    // this file made up.
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('PAYLOAD Retail'), findsOneWidget);
    expect(find.text('PAYLOAD Wholesale'), findsOneWidget);

    await tester.tap(find.text('PAYLOAD Wholesale'));
    await tester.pumpAndSettle();
    expect(ctrl.controllerFor('store_type').text, 'PAYLOAD Wholesale');
  });

  testWidgets('an unknown field type still renders, it never throws',
      (tester) async {
    final ctrl = CustomerFormController()..seed(_schema());
    addTearDown(ctrl.dispose);
    await _pump(tester, ctrl);

    expect(find.text('PAYLOAD Licence valid till'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // …and its backend default was installed.
    expect(ctrl.controllerFor('dl_expiry').text, 'PAYLOAD DEFAULT');
  });

  test('payload() sends only schema fields that were actually filled', () {
    final ctrl = CustomerFormController()..seed(_schema());
    addTearDown(ctrl.dispose);

    // A prefill carrying a key the schema does not list (self-signup has no
    // latitude field) must never be sent.
    ctrl.applyMap({'pharmacy_name': 'MEDIBO TEST', 'latitude': '21.25'});

    final p = ctrl.payload();
    expect(p['pharmacy_name'], 'MEDIBO TEST');
    expect(p['dl_expiry'], 'PAYLOAD DEFAULT'); // a backend default IS sent
    expect(p.containsKey('latitude'), isFalse);
    expect(p.containsKey('whatsapp_no'), isFalse); // untouched → omitted
  });

  test('missingRequired() is the backend list, and labels come from it too',
      () {
    final ctrl = CustomerFormController()..seed(_schema());
    addTearDown(ctrl.dispose);

    expect(ctrl.missingRequired(), ['pharmacy_name', 'whatsapp_no']);
    ctrl.setValue('pharmacy_name', 'MEDIBO TEST');
    expect(ctrl.missingRequired(), ['whatsapp_no']);

    expect(ctrl.labelOf('whatsapp_no'), 'PAYLOAD WhatsApp');
    expect(ctrl.text('missing_required_message'), 'PAYLOAD MISSING:');
  });

  test('the three surfaces ask for their own schema, and Convert lead says so',
      () {
    // Import customer, opened empty or from a file, is the admin schema.
    expect(const ImportCustomerSheet().schemaContext, 'admin');
    expect(
        const ImportCustomerSheet(extracted: {'pharmacy_name': 'X'})
            .schemaContext,
        'admin');
    // A sheet opened with a LEAD prefill is the Convert-lead surface, so the
    // S Leads call sites get the right title and field list without naming it.
    expect(
        const ImportCustomerSheet(prefill: {'pharmacy_name': 'X'})
            .schemaContext,
        'lead_convert');
    // An explicit context always wins.
    expect(
        const ImportCustomerSheet(
                prefill: {'pharmacy_name': 'X'}, formContext: 'admin')
            .schemaContext,
        'admin');
    // Self-signup names its own.
    expect(CustomerFormController(formContext: 'signup').formContext, 'signup');
  });

  test('with no schema the form has nothing to render and no defaults', () {
    final ctrl = CustomerFormController();
    addTearDown(ctrl.dispose);
    expect(ctrl.ready, isFalse);
    expect(ctrl.fields, isEmpty);
    expect(ctrl.requiredKeys, isEmpty);
    expect(ctrl.payload(), isEmpty);
  });
}

// PROTECTED — CMD #2171.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes what the General step says about its mandatory set.
//
// The General step is ONE screen for two surfaces (customer registration and
// staff Add customer / Import). The fields, their order and their boxes are
// identical — the ONLY thing that tells the two apart is which labels carry
// the star and which say "optional". Until #2171 the payload carried no word
// for the second half, so a staff screen and a customer screen were
// indistinguishable on the one axis the approved design uses to tell them
// apart.
//
// What this holds down:
//
//   1. A box that is NOT required prints the backend's `optional_label`
//      VERBATIM beside its label. A required box never does — it carries the
//      schema's `required_suffix` instead.
//
//   2. The word is the payload's. A different string in the payload renders
//      as that string; nothing here is a Dart literal.
//
//   3. No `optional_label` in the payload → nothing is printed. An older
//      payload must not start decorating labels.
//
//   4. The map box (type 'geo') never takes the word: the pin is not a box
//      with a label to qualify, and its own block speaks for it.
//
//   5. One render proves both halves of the staff set: with staff's required
//      list (pharmacy_name + whatsapp_no) the other three boxes say
//      "optional" and those two are starred — the customer's list stars four
//      of them and leaves only Store type optional.
//
// No network, no Supabase, no goldens.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/customer_registration_form.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// The General step's five boxes, with the required set the caller names.
Map<String, dynamic> _schema(List<String> required) => {
      'required_suffix': ' *',
      'fields': [
        {'key': 'customer_name', 'label': 'Owner name', 'type': 'text', 'hint': 'Full name', 'required': required.contains('customer_name')},
        {'key': 'pharmacy_name', 'label': 'Pharmacy name', 'type': 'text', 'hint': 'Shop name', 'required': required.contains('pharmacy_name')},
        {'key': 'store_type', 'label': 'Store type', 'type': 'text', 'required': required.contains('store_type')},
        {'key': 'whatsapp_no', 'label': 'WhatsApp number', 'type': 'phone', 'required': required.contains('whatsapp_no')},
        {'key': 'email', 'label': 'Email', 'type': 'email', 'required': required.contains('email')},
      ],
      'required_fields': required,
    };

const _fields = [
  'customer_name',
  'pharmacy_name',
  'store_type',
  'whatsapp_no',
  'email',
];

Map<String, dynamic> _v4({Object? optional = 'PAYLOAD optional'}) => {
      'layout': 'v4',
      'required_label': 'PAYLOAD Required',
      'phone_prefix': '+91',
      if (optional != null) 'optional_label': optional,
    };

Future<void> _pump(
  WidgetTester t, {
  required List<String> required,
  Map<String, dynamic>? v4,
  List<String> fields = _fields,
}) async {
  final ctrl = CustomerFormController(formContext: 'signup')
    ..seed(_schema(required));
  await t.pumpWidget(_host(CustomerRegistrationForm(
    controller: ctrl,
    onlyFields: fields,
    v4: v4 ?? _v4(),
  )));
  await t.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('the customer set: four starred, only Store type says optional',
      (t) async {
    await _pump(t, required: const [
      'customer_name',
      'pharmacy_name',
      'whatsapp_no',
      'email',
    ]);
    expect(find.text('Owner name *'), findsOneWidget);
    expect(find.text('Pharmacy name *'), findsOneWidget);
    expect(find.text('WhatsApp number *'), findsOneWidget);
    expect(find.text('Email *'), findsOneWidget);
    expect(find.text('Store type'), findsOneWidget);
    expect(find.text('PAYLOAD optional'), findsOneWidget,
        reason: 'exactly the one box that is not required');
  });

  testWidgets('the staff set: Pharmacy + WhatsApp starred, the other three optional',
      (t) async {
    await _pump(t, required: const ['pharmacy_name', 'whatsapp_no']);
    expect(find.text('Pharmacy name *'), findsOneWidget);
    expect(find.text('WhatsApp number *'), findsOneWidget);
    expect(find.text('Owner name'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Store type'), findsOneWidget);
    expect(find.text('PAYLOAD optional'), findsNWidgets(3));
  });

  testWidgets('the word is the payload\'s, never a Dart literal', (t) async {
    await _pump(t,
        required: const ['pharmacy_name'],
        v4: _v4(optional: 'वैकल्पिक'),
        fields: const ['pharmacy_name', 'store_type']);
    expect(find.text('वैकल्पिक'), findsOneWidget);
    expect(find.text('optional'), findsNothing);
  });

  testWidgets('an older payload without optional_label prints nothing extra',
      (t) async {
    await _pump(t,
        required: const ['pharmacy_name'],
        v4: _v4(optional: null),
        fields: const ['pharmacy_name', 'store_type']);
    expect(find.text('Store type'), findsOneWidget);
    expect(find.text('PAYLOAD optional'), findsNothing);
    expect(find.text('optional'), findsNothing);
  });

  testWidgets('the map box never takes the word', (t) async {
    final ctrl = CustomerFormController(formContext: 'signup')
      ..seed({
        'required_suffix': ' *',
        'fields': [
          {'key': 'pharmacy_name', 'label': 'Pharmacy name', 'type': 'text', 'required': true},
          {'key': 'store_pin', 'label': 'Shop location', 'type': 'geo', 'required': false},
        ],
        'required_fields': ['pharmacy_name'],
      });
    await t.pumpWidget(_host(CustomerRegistrationForm(
      controller: ctrl,
      onlyFields: const ['pharmacy_name', 'store_pin'],
      v4: _v4(),
    )));
    await t.pump();
    expect(find.text('Shop location'), findsOneWidget);
    expect(find.text('PAYLOAD optional'), findsNothing);
  });
}

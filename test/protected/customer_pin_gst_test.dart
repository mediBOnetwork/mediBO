// PROTECTED — CHANGE #1888.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the shop's GPS pin, the "no GST" answer, or the payment
// term sheet.
//
// The hole this closed: latitude/longitude were two text boxes on the admin
// form and nothing at all on self-signup, so 10 of 12 shops had no
// coordinates, 11 had no maps link, 8 had no district and 9 had no GST answer
// — every one of them a field a human was meant to type and nobody did.
//
// What this file holds down:
//
//   1. A 'geo' field renders the MAP PICKER, not a text box. Latitude and
//      longitude are never typed again.
//
//   2. A geo field counts as MISSING until coordinates exist, and the
//      sentence that says so is the backend's — including the field's own
//      label. The pin is mandatory because the payload said so, not because
//      Dart has a rule about pins.
//
//   3. Once the picker reports a point, payload() carries latitude/longitude
//      under the keys the PAYLOAD named (geo.lat_key / geo.lng_key), and the
//      geo field itself is never sent as a value of its own.
//
//   4. A checkbox is an ANSWER, not a style: it is omitted entirely until it
//      has been touched, so the backend can tell "this shop says it has no
//      GST" from "nobody has asked this shop". Untouched-false and
//      touched-false are DIFFERENT payloads.
//
//   5. A payload with no geo block at all still renders and asks for no pin,
//      so an app running ahead of the backend degrades instead of blocking a
//      registration.
//
// (The payment-term sheet is deliberately NOT here: it holds no decision of
// its own — title, options, reason label, history and the out-of-zone refusal
// all arrive from customer_payment_term_panel() — so there is nothing to pin
// down that a Supabase mock would not simply be re-stating.)
//
// No network, no Supabase, no goldens.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/customer_registration_form.dart';
import 'package:pharma_b2b/widgets/store_pin_picker.dart';

Map<String, dynamic> _schema() => {
      'ok': true,
      'context': 'signup',
      'title': 'PAYLOAD TITLE',
      'subtitle': 'PAYLOAD SUBTITLE',
      'required_suffix': ' ‹needed›',
      'loading_label': 'PAYLOAD LOADING',
      'flag_label': 'PAYLOAD FLAG',
      'missing_required_message': 'PAYLOAD MISSING:',
      'save_label': 'PAYLOAD SAVE',
      'cancel_label': 'PAYLOAD CANCEL',
      'geo': {
        'lat_key': 'latitude',
        'lng_key': 'longitude',
        'use_device_label': 'PAYLOAD USE DEVICE',
        'locating_label': 'PAYLOAD LOCATING',
        'denied_label': 'PAYLOAD DENIED',
        'set_label': 'PAYLOAD PIN SET',
        'none_label': 'PAYLOAD NO PIN',
        'missing_message': 'PAYLOAD PIN REQUIRED',
        'default_center': {'lat': 21.25, 'lng': 81.63},
        'default_zoom': 16,
      },
      'gst': {
        'none_key': 'gst_none',
        'gstin_key': 'gstin',
        'invalid_message': 'PAYLOAD GST INVALID',
        'missing_message': 'PAYLOAD GST MISSING',
      },
      'sections': [
        {
          'key': 'address',
          'title': 'PAYLOAD ADDRESS',
          'fields': [_pinField(), _gstNoneField()],
        },
      ],
      'fields': [_pinField(), _gstNoneField()],
      'required_fields': ['store_pin'],
    };

Map<String, dynamic> _pinField() => {
      'key': 'store_pin',
      'section': 'address',
      'label': 'PAYLOAD Shop location',
      'hint': 'PAYLOAD drag the map',
      'type': 'geo',
      'required': true,
      'sort_order': 125,
      'half_width': false,
      'max_lines': 1,
      'default': null,
      'options': [],
    };

Map<String, dynamic> _gstNoneField() => {
      'key': 'gst_none',
      'section': 'address',
      'label': 'PAYLOAD I have no GST',
      'hint': null,
      'type': 'checkbox',
      'required': false,
      'sort_order': 175,
      'half_width': false,
      'max_lines': 1,
      'default': null,
      'options': [],
    };

Future<void> _pump(WidgetTester tester, CustomerFormController c) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: CustomerRegistrationForm(controller: c),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  setUpAll(() {
    // The render-log debounce is a real Timer that would outlive the test.
    RenderLog.flushEnabled = false;
  });

  testWidgets('a geo field renders the map picker, never a text box',
      (tester) async {
    final c = CustomerFormController(formContext: 'signup')..seed(_schema());
    await _pump(tester, c);

    expect(find.byType(StorePinPicker), findsOneWidget);
    expect(find.text('PAYLOAD USE DEVICE'), findsOneWidget);
    // Its label is still the payload's, and still carries the required marker.
    expect(find.text('PAYLOAD Shop location ‹needed›'), findsOneWidget);

    // The picker asks the device for a fix the moment it is shown. On a
    // machine with no browser Geolocation that request comes back empty, and
    // the picker says so in the BACKEND's sentence — it does not fail silently
    // and it does not write an apology of its own.
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('PAYLOAD DENIED'), findsOneWidget);
  });

  testWidgets('a pin already on file prints the payload\'s "set" line',
      (tester) async {
    final c = CustomerFormController(formContext: 'signup')..seed(_schema());
    c.setPin('21.251400', '81.629600');
    await _pump(tester, c);

    // Coordinates already there: no device request, and the line names them.
    expect(find.textContaining('PAYLOAD PIN SET'), findsOneWidget);
    expect(find.textContaining('21.25140'), findsOneWidget);
  });

  testWidgets('the pin is missing until it exists, in the backend\'s words',
      (tester) async {
    final c = CustomerFormController(formContext: 'signup')..seed(_schema());
    await _pump(tester, c);

    // Nothing picked: the backend's required list names the geo field.
    expect(c.missingRequired(), ['store_pin']);
    expect(c.labelOf('store_pin'), 'PAYLOAD Shop location');

    // The picker reports a point — the same call StorePinPicker makes.
    c.setPin('21.251400', '81.629600');
    expect(c.missingRequired(), isEmpty);
  });

  testWidgets('payload() carries the coordinates under the payload\'s own keys',
      (tester) async {
    final c = CustomerFormController(formContext: 'signup')..seed(_schema());
    await _pump(tester, c);

    // Before the pin: no coordinates at all, and never the geo field itself.
    expect(c.payload().containsKey('latitude'), isFalse);
    expect(c.payload().containsKey('store_pin'), isFalse);

    c.setPin('21.251400', '81.629600');
    final p = c.payload();
    expect(p['latitude'], '21.251400');
    expect(p['longitude'], '81.629600');
    // The geo field is a picker, not a value.
    expect(p.containsKey('store_pin'), isFalse);
  });

  testWidgets('an untouched tick is omitted; a touched one is sent',
      (tester) async {
    final c = CustomerFormController(formContext: 'signup')..seed(_schema());
    await _pump(tester, c);

    // Never asked — the backend must not read this as "has no GST".
    expect(c.payload().containsKey('gst_none'), isFalse);

    // Ticked, then un-ticked: still an ANSWER, and false is sent explicitly.
    c.setCheck('gst_none', true);
    expect(c.payload()['gst_none'], isTrue);
    c.setCheck('gst_none', false);
    expect(c.payload()['gst_none'], isFalse);
    expect(c.payload().containsKey('gst_none'), isTrue);
  });

  testWidgets('the tick prints the payload label once, beside the box',
      (tester) async {
    final c = CustomerFormController(formContext: 'signup')..seed(_schema());
    await _pump(tester, c);

    expect(find.byType(Checkbox), findsOneWidget);
    // Once — the field header must not repeat what the tick already says.
    expect(find.text('PAYLOAD I have no GST'), findsOneWidget);

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(c.checkValue('gst_none'), isTrue);
  });

  testWidgets('a payload with no geo block still renders, and asks for nothing',
      (tester) async {
    // Forward compatibility in the other direction: an older backend that has
    // not been migrated sends no geo field and no geo block. The form must
    // render and must not invent a pin requirement.
    final s = _schema();
    s.remove('geo');
    s['fields'] = [_gstNoneField()];
    s['sections'] = [
      {'key': 'address', 'title': 'PAYLOAD ADDRESS', 'fields': [_gstNoneField()]}
    ];
    s['required_fields'] = <String>[];

    final c = CustomerFormController(formContext: 'signup')..seed(s);
    await _pump(tester, c);

    expect(find.byType(StorePinPicker), findsNothing);
    expect(c.missingRequired(), isEmpty);
  });
}

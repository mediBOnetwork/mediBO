// CMD #2129 — ONE Add customer flow for every staff entry point, held down.
//
// What must never drift:
//  • the flow opens from addcust_open with the lead id it was given (the
//    backend pre-fills from the lead and links the save back to it);
//  • the step bar is the backend's list, Terms included, and the photo card
//    prints the backend's words;
//  • the WhatsApp number is judged by addcust_number_check and its label and
//    buttons print verbatim (an already-taken number shows Open / Use another);
//  • Save sends the form through addcust_save('save') and STAYS on the step,
//    printing the backend's own saved line — CMD #2171 (Om, APK 1.3.33): it
//    used to run addcust_finish too, so tapping Save on General threw the
//    staff onto the done screen with Location, Documents and Invite never
//    seen. Only the last step finishes;
//  • the Saved screen prints the backend's title, invite pill, checklist and
//    note verbatim, with Open customer / Add another — and the invite pill is
//    whatever addcust_finish says (sent / queued / not sent + reason). It
//    never claims sent;
//  • CMD #2171: ONE verdict on the number. addcust_number_check is this
//    screen's only judge, its `value` is what the box shows, and its `allow`
//    is the only thing that may disable Continue.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/add_customer_flow.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _field(String key, String label, String type,
        {bool required = false}) =>
    {
      'key': key,
      'section': 'shop',
      'label': label,
      'hint': null,
      'type': type,
      'required': required,
      'sort_order': 10,
      'half_width': false,
      'max_lines': 1,
      'default': null,
      'options': [],
    };

Map<String, dynamic> _open() => {
      'ok': true,
      'title': 'PAYLOAD Add customer',
      'close_label': 'PAYLOAD Close',
      'link': {'show': true, 'lead_id': 42, 'label': 'PAYLOAD From lead: Shraddha'},
      'note': '',
      'schema': {
        'ok': true,
        'required_suffix': ' *',
        'sections': [
          {
            'key': 'shop',
            'title': '',
            'fields': [
              _field('pharmacy_name', 'PAYLOAD Pharmacy name', 'text', required: true),
              _field('whatsapp_no', 'PAYLOAD WhatsApp number', 'phone', required: true),
            ],
          }
        ],
        'fields': [
          _field('pharmacy_name', 'PAYLOAD Pharmacy name', 'text', required: true),
          _field('whatsapp_no', 'PAYLOAD WhatsApp number', 'phone', required: true),
        ],
      },
      'prefill': {'pharmacy_name': 'Shraddha Medical Store'},
      'wizard': {
        'enabled': true,
        'continue_label': 'PAYLOAD Continue',
        'back_label': 'PAYLOAD Back',
        'saving_label': 'PAYLOAD Saving',
        'submit_label': 'PAYLOAD Save customer',
        'submitting_label': 'PAYLOAD Saving',
        'chips': {},
        'steps': [
          {'key': 'shop', 'label': 'PAYLOAD General', 'fields': ['pharmacy_name', 'whatsapp_no']},
          {'key': 'location', 'label': 'PAYLOAD Location', 'map': {'x': 1}},
          {'key': 'licences', 'label': 'PAYLOAD Documents', 'docs': true},
          {'key': 'terms', 'label': 'PAYLOAD Terms', 'terms': true},
        ],
      },
      'photo': {
        'title': 'PAYLOAD Photograph board or GST certificate',
        'line': 'PAYLOAD We fill name, GSTIN and address',
        'read_note': 'PAYLOAD Read from photo',
      },
      'save': {'label': 'PAYLOAD Save', 'hint': 'PAYLOAD Name, WhatsApp and pin are enough to save'},
      'number': {'key': 'whatsapp_no', 'debounce_ms': 10, 'checking_label': 'PAYLOAD Checking'},
      'terms': {
        'payment': {'label': 'Payment term', 'value': 'Advance Payment', 'options': []},
        'delivery': {'label': 'Delivery', 'value': 'next_day', 'options': []},
        'zone': {'label': 'Zone', 'value': 1, 'options': []},
        'slab': {'label': 'Advance slab', 'value_label': '1st order · 10%'},
        'invite': {'label': 'Send WhatsApp invite', 'on': true},
      },
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => AddCustomerFlow.rpcTransport = null);

  testWidgets('opens from the lead, checks the number, saves and prints Saved verbatim',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final calls = <String, Map<String, dynamic>?>{};
    AddCustomerFlow.rpcTransport = (fn, params) async {
      calls[fn] = params;
      switch (fn) {
        case 'addcust_open':
          return _open();
        case 'addcust_number_check':
          return params?['p_number'] == '9826100012'
              ? {
                  'ok': true,
                  'state': 'customer',
                  'allow': false,
                  'tone': 'warning',
                  'label': 'PAYLOAD Already a customer: Raj Pharmacy',
                  'actions': [
                    {'key': 'open', 'label': 'PAYLOAD Open', 'customer_id': 'c-1'},
                    {'key': 'use_another', 'label': 'PAYLOAD Use another'},
                  ],
                }
              : {
                  'ok': true,
                  'state': 'new',
                  'allow': true,
                  'tone': 'success',
                  'value': '9827144310',
                  'label': 'PAYLOAD New',
                  'actions': [],
                };
        case 'addcust_save':
          return {
            'ok': true,
            'customer_id': 'c-9',
            'licences': {},
            'terms': {},
            'saved': {'show': true, 'tone': 'success', 'label': 'PAYLOAD Saved, carry on'},
          };
        case 'addcust_finish':
          return {
            'ok': true,
            'customer_id': 'c-9',
            'title': 'PAYLOAD Customer added',
            'line': 'PAYLOAD Shraddha Medical Store · Raipur',
            'invite': {
              'show': true,
              'state': 'not_sent',
              'tone': 'warning',
              'label': 'PAYLOAD Invite not sent to 98271 44310 — the template is still draft with Meta',
            },
            'checklist': [
              {'label': 'PAYLOAD Shop details', 'value': 'PAYLOAD Done', 'tone': 'success'},
              {'label': 'PAYLOAD Drug licences', 'value': 'PAYLOAD Customer will add', 'tone': 'warning'},
            ],
            'note': 'PAYLOAD When they log in they land on the same form',
            'open_label': 'PAYLOAD Open customer',
            'another_label': 'PAYLOAD Add another',
          };
      }
      return null;
    };

    await tester.pumpWidget(const MaterialApp(home: AddCustomerFlow(leadId: 42)));
    await tester.pumpAndSettle();

    expect(calls['addcust_open']?['p_lead_id'], 42);
    expect(find.text('PAYLOAD Add customer'), findsOneWidget);
    expect(find.text('PAYLOAD From lead: Shraddha'), findsOneWidget);
    expect(find.text('PAYLOAD Photograph board or GST certificate'), findsOneWidget);
    for (final l in ['PAYLOAD General', 'PAYLOAD Location', 'PAYLOAD Documents', 'PAYLOAD Terms']) {
      expect(find.text(l), findsOneWidget);
    }
    expect(find.text('Shraddha Medical Store'), findsOneWidget);

    // A taken number: the backend's words and buttons, verbatim.
    await tester.enterText(find.byType(TextField).at(1), '9826100012');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.text('PAYLOAD Already a customer: Raj Pharmacy'), findsOneWidget);
    expect(find.text('PAYLOAD Open'), findsOneWidget);
    expect(find.text('PAYLOAD Use another'), findsOneWidget);

    // A new number.
    await tester.enterText(find.byType(TextField).at(1), '9827144310');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.text('PAYLOAD New'), findsOneWidget);
    expect(calls['addcust_number_check']?['p_number'], '9827144310');

    // CMD #2171 — Save saves and STAYS: addcust_save('save') runs, its own
    // line is printed where the staff are standing, addcust_finish is NOT
    // called and the General step is still on screen.
    await tester.tap(find.text('PAYLOAD Save'));
    await tester.pumpAndSettle();
    expect(calls['addcust_save']?['p_step'], 'save');
    expect(calls['addcust_save']?['p_lead_id'], 42);
    expect((calls['addcust_save']?['p_values'] as Map)['whatsapp_no'], '9827144310');
    expect(find.text('PAYLOAD Saved, carry on'), findsOneWidget);
    expect(calls.containsKey('addcust_finish'), isFalse);
    expect(find.text('PAYLOAD Photograph board or GST certificate'), findsOneWidget);
    expect(find.text('PAYLOAD Customer added'), findsNothing);

    // Only the last step finishes. Continue through Location and Documents,
    // then Save customer on Terms.
    // The Location step draws a live map, which never "settles" — pump it by
    // hand rather than waiting for a still frame.
    Future<void> beat() async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('PAYLOAD Continue'));
      await beat();
    }
    await tester.tap(find.text('PAYLOAD Save customer'));
    await beat();
    expect(calls['addcust_finish']?['p_customer_id'], 'c-9');
    expect((calls['addcust_finish']?['p_terms'] as Map)['payment_term'], 'Advance Payment');

    expect(find.text('PAYLOAD Customer added'), findsOneWidget);
    // The invite pill is the backend's verdict, whatever it is. It is NOT
    // "sent" here, and nothing in Dart turns it into that.
    expect(
        find.text(
            'PAYLOAD Invite not sent to 98271 44310 — the template is still draft with Meta'),
        findsOneWidget);
    expect(find.text('PAYLOAD Customer will add'), findsOneWidget);
    expect(find.text('PAYLOAD When they log in they land on the same form'), findsOneWidget);
    expect(find.text('PAYLOAD Open customer'), findsOneWidget);
    expect(find.text('PAYLOAD Add another'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CMD #2171 — one verdict: the box takes the checked number and '
      'only `allow` may stop Continue', (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final numbers = <String>[];
    AddCustomerFlow.rpcTransport = (fn, params) async {
      if (fn == 'addcust_open') return _open();
      if (fn == 'addcust_number_check') {
        final n = (params?['p_number'] ?? '').toString();
        numbers.add(n);
        // The backend judges the LAST ten digits and sends them back.
        final cleaned = n.replaceAll(RegExp(r'\D'), '');
        final ten = cleaned.length > 10
            ? cleaned.substring(cleaned.length - 10)
            : cleaned;
        return ten == '9826100012'
            ? {
                'ok': true,
                'state': 'customer',
                'allow': false,
                'tone': 'warning',
                'value': ten,
                'label': 'PAYLOAD Already a customer: Raj Pharmacy',
                'actions': [
                  {'key': 'open', 'label': 'PAYLOAD Open', 'customer_id': 'c-1'},
                ],
              }
            : {
                'ok': true,
                'state': 'new',
                'allow': true,
                'tone': 'success',
                'value': ten,
                'label': 'PAYLOAD New',
                'actions': [],
              };
      }
      return null;
    };

    await tester.pumpWidget(const MaterialApp(home: AddCustomerFlow()));
    await tester.pumpAndSettle();

    // A number the phone's own list offered in international form. The box
    // shows what the backend judged — nothing in Dart cleaned it first.
    await tester.enterText(find.byType(TextField).at(1), '+448357881873');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(numbers.first, '+448357881873', reason: 'the raw pick is judged');
    final box = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(box.controller?.text, '8357881873');
    expect(find.text('PAYLOAD New'), findsOneWidget);

    // Free number → Continue is live.
    var primary = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'PAYLOAD Continue'));
    expect(primary.onPressed, isNotNull);

    // Taken number → ONE amber verdict with its own button, and Continue is
    // visibly off rather than dead.
    await tester.enterText(find.byType(TextField).at(1), '9826100012');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.text('PAYLOAD Already a customer: Raj Pharmacy'), findsOneWidget);
    expect(find.text('PAYLOAD New'), findsNothing);
    expect(find.text('PAYLOAD Open'), findsOneWidget);
    primary = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'PAYLOAD Continue'));
    expect(primary.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a refused save prints the backend sentence and stays on the step',
      (tester) async {
    AddCustomerFlow.rpcTransport = (fn, params) async => switch (fn) {
          'addcust_open' => _open(),
          'addcust_number_check' => {'ok': true, 'state': 'new', 'allow': true, 'tone': 'success', 'label': 'PAYLOAD New', 'actions': []},
          'addcust_save' => {'ok': false, 'field': 'store_pin', 'message': 'PAYLOAD Place the pin on the shop to save.'},
          _ => null,
        };
    await tester.pumpWidget(const MaterialApp(home: AddCustomerFlow()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PAYLOAD Save'));
    await tester.pumpAndSettle();
    expect(find.text('PAYLOAD Place the pin on the shop to save.'), findsOneWidget);
    expect(find.text('PAYLOAD Photograph board or GST certificate'), findsOneWidget);
  });
}

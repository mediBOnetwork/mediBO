// CMD #2129 — ONE Add customer flow for every staff entry point, held down.
//
// What must never drift:
//  • the flow opens from addcust_open with the lead id it was given (the
//    backend pre-fills from the lead and links the save back to it);
//  • the step bar is the backend's list, Terms included, and the photo card
//    prints the backend's words;
//  • the WhatsApp number is judged by addcust_number_check and its label and
//    buttons print verbatim (an already-taken number shows Open / Use another);
//  • Save sends the form through addcust_save('save') then addcust_finish,
//    and the Saved screen prints the backend's title, invite pill, checklist
//    and note verbatim, with Open customer / Add another.
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
              : {'ok': true, 'state': 'new', 'allow': true, 'tone': 'success', 'label': 'PAYLOAD New', 'actions': []};
        case 'addcust_save':
          return {'ok': true, 'customer_id': 'c-9', 'licences': {}, 'terms': {}};
        case 'addcust_finish':
          return {
            'ok': true,
            'customer_id': 'c-9',
            'title': 'PAYLOAD Customer added',
            'line': 'PAYLOAD Shraddha Medical Store · Raipur',
            'invite': {'show': true, 'tone': 'success', 'label': 'PAYLOAD Invite sent to 98271 44310'},
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

    // Save → addcust_save('save') → addcust_finish → Saved screen verbatim.
    await tester.tap(find.text('PAYLOAD Save'));
    await tester.pumpAndSettle();
    expect(calls['addcust_save']?['p_step'], 'save');
    expect(calls['addcust_save']?['p_lead_id'], 42);
    expect((calls['addcust_save']?['p_values'] as Map)['whatsapp_no'], '9827144310');
    expect(calls['addcust_finish']?['p_customer_id'], 'c-9');
    expect((calls['addcust_finish']?['p_terms'] as Map)['payment_term'], 'Advance Payment');

    expect(find.text('PAYLOAD Customer added'), findsOneWidget);
    expect(find.text('PAYLOAD Invite sent to 98271 44310'), findsOneWidget);
    expect(find.text('PAYLOAD Customer will add'), findsOneWidget);
    expect(find.text('PAYLOAD When they log in they land on the same form'), findsOneWidget);
    expect(find.text('PAYLOAD Open customer'), findsOneWidget);
    expect(find.text('PAYLOAD Add another'), findsOneWidget);
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

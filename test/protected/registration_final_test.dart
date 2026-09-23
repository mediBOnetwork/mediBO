// CMD #2151 — Registration + Add customer / Import, final. Held down on the
// ONE General form both surfaces draw:
//  • the Mr / Ms box is exactly the owner-name box's height;
//  • a picked / pasted number is cleaned by the BACKEND: the box takes the
//    verdict's `value` and prints its `note` ("from → to · checked") verbatim,
//    and a typed 10-digit number is left alone;
//  • pickers: on the customer's form an EMPTY WhatsApp box asks the phone's
//    number list and an empty Email box the Google account list — whatever
//    comes back goes through the same check; staff forms never open them;
//  • the taken card's Login carries the backend's login_mode through.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/services/contact_pickers.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/customer_registration_form.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

final _schema = <String, dynamic>{
  'required_suffix': ' *',
  'fields': [
    {'key': 'owner_salutation', 'label': 'Title', 'type': 'select', 'required': false, 'default': 'Mr', 'sort_order': 5},
    {'key': 'customer_name', 'label': 'Owner name', 'type': 'text', 'required': true, 'hint': 'Full name', 'sort_order': 8},
    {'key': 'whatsapp_no', 'label': 'WhatsApp number', 'type': 'phone', 'required': true, 'hint': 'PHONE HINT', 'sort_order': 40},
    {'key': 'email', 'label': 'Email', 'type': 'email', 'required': true, 'hint': 'MAIL HINT', 'sort_order': 70},
  ],
  'required_fields': ['customer_name', 'whatsapp_no', 'email'],
};

final _v4 = <String, dynamic>{
  'layout': 'v4',
  'prefix': {
    'customer_name': {
      'key': 'owner_salutation',
      'default': 'Mr',
      // CMD #2188 — the backend asks for ONE box, Mr/Ms inside it.
      'inline': true,
      'options': [
        {'label': 'Mr', 'value': 'Mr'},
        {'label': 'Ms', 'value': 'Ms'},
      ],
    },
  },
  'checks': {'whatsapp_no': 'phone', 'email': 'email'},
  'check_debounce_ms': 10,
  'phone_prefix': '+91',
};

const _fields = ['customer_name', 'whatsapp_no', 'email'];

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  Future<(CustomerFormController, List<Map<String, dynamic>>)> pump(
      WidgetTester t,
      {bool pickers = false,
      Map<String, dynamic> Function(String f, String v)? verdict}) async {
    final calls = <Map<String, dynamic>>[];
    final ctrl = CustomerFormController(formContext: 'signup')..seed(_schema);
    await t.pumpWidget(_host(CustomerRegistrationForm(
      controller: ctrl,
      onlyFields: _fields,
      v4: _v4,
      pickers: pickers,
      checkRpc: (fn, p) async {
        calls.add({'fn': fn, ...p});
        return (verdict ?? (_, _) => {'ok': true, 'state': 'ok'})(
            p['p_field'].toString(), p['p_value'].toString());
      },
    )));
    await t.pump();
    return (ctrl, calls);
  }

  Future<void> settle(WidgetTester t) async {
    await t.pump(const Duration(milliseconds: 50));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    await t.pump();
  }

  // CMD #2188 — there is no separate Mr/Ms box any more: the picker sits
  // INSIDE the name box, and that one box is the height of every other field.
  testWidgets('the name box holds Mr/Ms and is a normal field height', (t) async {
    await pump(t);
    final box = t.getSize(find.bySemanticsIdentifier('reg_name_box_customer_name'));
    final other = t.getSize(find.widgetWithText(TextField, 'MAIL HINT'));
    expect(box.height, other.height);
    // The picker is inside that box, not beside it.
    final pfx = t.getTopLeft(find.bySemanticsIdentifier('reg_prefix_owner_salutation'));
    final boxLeft = t.getTopLeft(find.bySemanticsIdentifier('reg_name_box_customer_name'));
    final boxRight = t.getBottomRight(find.bySemanticsIdentifier('reg_name_box_customer_name'));
    expect(pfx.dx >= boxLeft.dx && pfx.dx < boxRight.dx, isTrue);
  });

  // CMD #2188 — ONE focus ring, around the whole box. Focusing the name used
  // to light a border that stopped at the divider, which is how the picker
  // read as a second field in the first place.
  testWidgets('the focus ring belongs to the whole box, not the input', (t) async {
    await pump(t);
    final box = find.bySemanticsIdentifier('reg_name_box_customer_name');
    Border ring() => (t.widget<Container>(find.descendant(
            of: box, matching: find.byType(Container)).first)
        .foregroundDecoration as BoxDecoration).border as Border;
    expect(ring().top.color, Ds.c.divider);
    await t.tap(find.widgetWithText(TextField, 'Full name'));
    await t.pump();
    expect(ring().top.color, Ds.c.brand);
    expect(ring().left.color, Ds.c.brand, reason: 'one ring, all four sides');
    // The input inside draws no border of its own — one box, one edge.
    final inner = t.widget<TextField>(find.descendant(
        of: box, matching: find.widgetWithText(TextField, 'Full name')));
    expect(inner.decoration?.enabledBorder, InputBorder.none);
    expect(inner.decoration?.focusedBorder, InputBorder.none);
  });

  testWidgets('a pasted +91 number takes the backend\'s cleaned value and note', (t) async {
    final (ctrl, calls) = await pump(t, verdict: (f, v) => {
          'ok': true, 'state': 'ok', 'blocks': false, 'suffix': '✓', 'tone': 'success',
          'value': '8357881873',
          'note': v == '8357881873' ? '' : 'NOTE $v → 8357881873'});
    await t.enterText(find.widgetWithText(TextField, 'PHONE HINT'), '918357881873');
    await settle(t);
    expect(calls.first['p_value'], '918357881873', reason: 'raw goes to the backend');
    expect(ctrl.controllerFor('whatsapp_no').text, '8357881873');
    expect(find.text('NOTE 918357881873 → 8357881873'), findsOneWidget,
        reason: 'the cleaning verdict stays — the box change is not re-judged');
    expect(calls.length, 1);
  });

  testWidgets('a typed 10-digit number is left exactly as typed', (t) async {
    final (ctrl, _) = await pump(t, verdict: (f, v) => {
          'ok': true, 'state': 'ok', 'blocks': false, 'suffix': '✓', 'tone': 'success',
          'value': v, 'note': ''});
    await t.enterText(find.widgetWithText(TextField, 'PHONE HINT'), '8357881873');
    await settle(t);
    expect(ctrl.controllerFor('whatsapp_no').text, '8357881873');
    expect(find.bySemanticsIdentifier('reg_cleaned_whatsapp_no'), findsNothing);
  });

  testWidgets('customer form: tapping empty boxes opens the pickers; values are checked', (t) async {
    var phoneAsks = 0, mailAsks = 0;
    ContactPickers.phone = () async {
      phoneAsks++;
      return '+91 83578 81873';
    };
    ContactPickers.email = () async {
      mailAsks++;
      return 'chandra@gmail.com';
    };
    final (ctrl, calls) = await pump(t, pickers: true);
    await t.tap(find.widgetWithText(TextField, 'PHONE HINT'));
    await settle(t);
    await t.tap(find.widgetWithText(TextField, 'MAIL HINT'));
    await settle(t);
    expect(phoneAsks, 1);
    expect(mailAsks, 1);
    expect(ctrl.controllerFor('email').text, 'chandra@gmail.com');
    expect(calls.map((c) => c['p_field']), containsAll(['whatsapp_no', 'email']));
    // A filled box is just edited — no second sheet.
    await t.tap(find.byType(TextField).at(2));
    await settle(t);
    expect(mailAsks, 1);
  });

  testWidgets('staff form: the pickers never open', (t) async {
    var asks = 0;
    ContactPickers.phone = () async {
      asks++;
      return '8357881873';
    };
    ContactPickers.email = () async {
      asks++;
      return 'x@y.co';
    };
    await pump(t);
    await t.tap(find.widgetWithText(TextField, 'PHONE HINT'));
    await t.tap(find.widgetWithText(TextField, 'MAIL HINT'));
    await settle(t);
    expect(asks, 0);
  });

  test('verdictNote prints the backend note verbatim, empty when absent', () {
    expect(verdictNote({'note': 'A → B · checked'}), 'A → B · checked');
    expect(verdictNote({'state': 'ok'}), '');
    expect(verdictNote(null), '');
  });

  test('the login intent key is one shared name', () {
    expect(kLoginIntentKey, 'medibo_login_intent');
  });
}

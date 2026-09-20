// PROTECTED — CMD #2126.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the registration flow.
//
// What this holds down:
//
//   1. THE FLOW IS THE PAYLOAD'S. customer_registration_payload().wizard
//      names the steps, their labels, which fields each asks and the Store
//      type chips. The screen renders exactly those fields on each step and
//      prints every caption verbatim — no Dart step list, no Dart labels.
//
//   2. RESUME. The screen opens on wizard.resume_step (the step the backend
//      saved with the draft), with everything filled from prefill + draft.
//
//   3. AUTO-SAVE AFTER EVERY STEP. Continue sends customer_registration_step_
//      save(p_step, p_values); ok:false keeps the person on the step and
//      prints the backend's sentence; ok:true moves to the backend's
//      step_index. Back and a tapped tick save with p_goto and never block.
//
//   4. BACK ON EVERY STEP AFTER THE FIRST, and none on the first.
//
//   5. WhatsApp and Email arrive pre-filled and EDITABLE — never locked.
//
//   6. DONE. The last Continue submits, then the Done screen prints the
//      backend's title, line, checklist (Done / Add later) and button.
//
//   7. No wizard block → the single form, unchanged (forward/back compat).
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/auth/one_registration_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _f(String key, String label, String type,
        {bool required = false, int order = 10, String section = 'business'}) =>
    {
      'key': key,
      'section': section,
      'label': label,
      'hint': '',
      'type': type,
      'required': required,
      'sort_order': order,
      'half_width': false,
      'max_lines': 1,
      'options': type == 'select' ? ['DROPDOWN A', 'DROPDOWN B'] : [],
    };

final _fields = [
  _f('pharmacy_name', 'PAYLOAD Pharmacy', 'text', required: true, order: 10),
  _f('customer_name', 'PAYLOAD Owner', 'text', order: 20),
  _f('store_type', 'PAYLOAD Store type', 'select', order: 30),
  _f('whatsapp_no', 'PAYLOAD WhatsApp', 'phone', required: true, order: 40),
  _f('email', 'PAYLOAD Email', 'email', order: 70),
  _f('address', 'PAYLOAD Address', 'text', required: true, order: 80, section: 'address'),
  _f('dl_20b', 'PAYLOAD DL 20B', 'text', order: 190, section: 'statutory'),
];

Map<String, dynamic> _schema() => {
      'ok': true,
      'context': 'signup',
      'required_suffix': ' *',
      'sections': [
        {'key': 'business', 'title': 'BUSINESS', 'fields': _fields.sublist(0, 5)},
        {'key': 'address', 'title': 'ADDRESS', 'fields': [_fields[5]]},
        {'key': 'statutory', 'title': 'STATUTORY', 'fields': [_fields[6]]},
      ],
      'fields': _fields,
      'required_fields': ['pharmacy_name', 'whatsapp_no', 'address'],
      'geo': {},
      'gst': {},
    };

Map<String, dynamic> _step(int n, String key, String label, List<String> fields,
        {bool complete = false, bool docs = false}) =>
    {
      'key': key,
      'n': n,
      'label': label,
      'title': 'TITLE $label',
      'step_of': 'STEP $n OF 3',
      'fields': fields,
      'docs': docs,
      'complete': complete,
      'missing': [],
    };

Map<String, dynamic> _wizard({int resume = 0, bool shopDone = false}) => {
      'enabled': true,
      'total': 3,
      'resume_step': resume,
      'steps': [
        _step(1, 'shop', 'SHOP', ['pharmacy_name', 'customer_name', 'store_type', 'whatsapp_no', 'email'],
            complete: shopDone),
        _step(2, 'location', 'LOCATION', ['address']),
        _step(3, 'licences', 'LICENCES', ['dl_20b'], docs: true),
      ],
      'continue_label': 'PAYLOAD CONTINUE',
      'back_label': 'PAYLOAD BACK',
      'saving_label': 'PAYLOAD SAVING',
      'submit_label': 'PAYLOAD SUBMIT',
      'submitting_label': 'PAYLOAD SUBMITTING',
      'chips': {
        'store_type': ['CHIP Retail', 'CHIP Hospital', 'CHIP Clinic', 'CHIP Wholesale'],
      },
      'done': {
        'title': 'PAYLOAD SUBMITTED',
        'line': 'PAYLOAD WE VERIFY',
        'checklist_title': 'PAYLOAD CHECKLIST',
        'checklist': [
          {'key': 'shop', 'label': 'PART SHOP', 'done': true},
          {'key': 'documents', 'label': 'PART DOCS', 'done': false},
        ],
        'done_label': 'PAYLOAD DONE',
        'later_label': 'PAYLOAD LATER',
        'cta_label': 'PAYLOAD BROWSE',
        'cta_route': '/',
      },
    };

Map<String, dynamic> _payload({Map<String, dynamic>? wizard, bool withWizard = true}) => {
      'signed_in': true,
      'needs': true,
      'stage': 'form',
      'title': 'Register',
      'subtitle': '',
      'submit_label': 'LEGACY SUBMIT',
      'submitting_label': 'LEGACY SUBMITTING',
      'error_label': 'ERR',
      'retry_label': 'RETRY',
      'close_label': 'CLOSE',
      'done_title': 'DONE',
      'done_line': 'LINE',
      'imported': {'is': false, 'note': ''},
      'schema': _schema(),
      'prefill': {'whatsapp_no': '9876543210', 'email': 'shop@example.com'},
      'draft': const {},
      'has_draft': false,
      'draft_note': '',
      'documents': {'show': false, 'rows': []},
      'docs_pending': {'show': false},
      'steps': const [],
      'step': const {'n': 1, 'total': 1},
      if (withWizard) 'wizard': wizard ?? _wizard(),
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => OneRegistrationScreen.rpcTransport = null);

  Future<List<Map<String, dynamic>>> pump(WidgetTester tester,
      {Map<String, dynamic>? payload,
      Map<String, dynamic> Function(Map<String, dynamic> p)? stepSave,
      Size size = const Size(360, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final calls = <Map<String, dynamic>>[];
    final p = payload ?? _payload();
    OneRegistrationScreen.rpcTransport = (fn, params) async {
      final prm = Map<String, dynamic>.from(params ?? const {});
      calls.add({'fn': fn, 'params': prm});
      if (fn == 'customer_registration_payload') return p;
      if (fn == 'customer_registration_step_save') {
        if (stepSave != null) return stepSave(prm);
        final i = ['shop', 'location', 'licences'].indexOf(prm['p_step']);
        final to = prm['p_goto'] ?? ['shop', 'location', 'licences'][(i + 1).clamp(0, 2)];
        return {'ok': true, 'step': to, 'step_index': ['shop', 'location', 'licences'].indexOf(to)};
      }
      if (fn == 'customer_registration_submit') {
        return {'ok': true, 'customer_id': '', 'message': 'SUBMITTED', 'payload': p};
      }
      return null;
    };
    await tester.pumpWidget(MaterialApp(key: UniqueKey(), home: const OneRegistrationScreen()));
    await tester.pumpAndSettle();
    return calls;
  }

  testWidgets('1 — step 1 renders the payload\'s labels, fields and chips; no Back',
      (tester) async {
    await pump(tester);
    for (final t in ['SHOP', 'LOCATION', 'LICENCES', 'STEP 1 OF 3', 'TITLE SHOP']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('PAYLOAD Pharmacy *'), findsOneWidget);
    expect(find.text('PAYLOAD Address *'), findsNothing,
        reason: 'a later step\'s field is not on step 1');
    for (final c in ['CHIP Retail', 'CHIP Hospital', 'CHIP Clinic', 'CHIP Wholesale']) {
      expect(find.text(c), findsOneWidget, reason: c);
    }
    expect(find.text('DROPDOWN A'), findsNothing, reason: 'chips replace the dropdown');
    expect(find.text('PAYLOAD CONTINUE'), findsOneWidget);
    expect(find.text('PAYLOAD BACK'), findsNothing);
  });

  testWidgets('2 — WhatsApp and Email are pre-filled and editable', (tester) async {
    await pump(tester);
    for (final v in ['9876543210', 'shop@example.com']) {
      final tf = tester.widget<TextField>(find.widgetWithText(TextField, v));
      expect(tf.enabled ?? true, isTrue, reason: v);
      expect(tf.readOnly, isFalse, reason: v);
    }
    await tester.enterText(find.widgetWithText(TextField, 'shop@example.com'), 'new@example.com');
    expect(find.text('new@example.com'), findsOneWidget);
  });

  testWidgets('3 — resume opens on the backend\'s step, with Back', (tester) async {
    await pump(tester, payload: _payload(wizard: _wizard(resume: 1, shopDone: true)));
    expect(find.text('TITLE LOCATION'), findsOneWidget);
    expect(find.text('PAYLOAD Address *'), findsOneWidget);
    expect(find.text('PAYLOAD BACK'), findsOneWidget);
  });

  testWidgets('4 — Continue auto-saves; a refusal prints the backend sentence and stays',
      (tester) async {
    final calls = await pump(tester,
        stepSave: (_) => {'ok': false, 'message': 'PAYLOAD FILL: Pharmacy'});
    await tester.tap(find.text('PAYLOAD CONTINUE'));
    await tester.pumpAndSettle();
    final save = calls.lastWhere((c) => c['fn'] == 'customer_registration_step_save');
    expect(save['params']['p_step'], 'shop');
    expect((save['params']['p_values'] as Map)['whatsapp_no'], '9876543210');
    expect(save['params'].containsKey('p_goto'), isFalse);
    expect(find.text('PAYLOAD FILL: Pharmacy'), findsOneWidget);
    expect(find.text('TITLE SHOP'), findsOneWidget);
  });

  testWidgets('5 — Continue moves on; Back saves with p_goto; a tick jumps back',
      (tester) async {
    final calls = await pump(tester);
    await tester.tap(find.text('PAYLOAD CONTINUE'));
    await tester.pumpAndSettle();
    expect(find.text('TITLE LOCATION'), findsOneWidget);

    await tester.tap(find.text('PAYLOAD BACK'));
    await tester.pumpAndSettle();
    expect(find.text('TITLE SHOP'), findsOneWidget);
    final back = calls.lastWhere((c) => c['fn'] == 'customer_registration_step_save');
    expect(back['params']['p_step'], 'location');
    expect(back['params']['p_goto'], 'shop');

    await tester.tap(find.text('PAYLOAD CONTINUE'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SHOP'));
    await tester.pumpAndSettle();
    expect(find.text('TITLE SHOP'), findsOneWidget, reason: 'completed step is tappable');
  });

  testWidgets('6 — the last Continue submits and the Done screen is the backend\'s',
      (tester) async {
    final calls = await pump(tester, payload: _payload(wizard: _wizard(resume: 2)));
    expect(find.text('PAYLOAD SUBMIT'), findsOneWidget);
    await tester.tap(find.text('PAYLOAD SUBMIT'));
    await tester.pumpAndSettle();
    final fns = calls.map((c) => c['fn']).toList();
    expect(fns.indexOf('customer_registration_step_save'),
        lessThan(fns.indexOf('customer_registration_submit')));
    for (final t in ['PAYLOAD SUBMITTED', 'PAYLOAD WE VERIFY', 'PAYLOAD CHECKLIST',
        'PART SHOP', 'PART DOCS', 'PAYLOAD DONE', 'PAYLOAD LATER', 'PAYLOAD BROWSE']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
  });

  testWidgets('7 — no wizard block renders the single form unchanged', (tester) async {
    await pump(tester, payload: _payload(withWizard: false));
    expect(find.text('LEGACY SUBMIT'), findsOneWidget);
    expect(find.text('PAYLOAD Address *'), findsOneWidget);
    expect(find.text('PAYLOAD CONTINUE'), findsNothing);
  });

  testWidgets('8 — at 320, 360 and 412px no step and no Done screen overflows',
      (tester) async {
    for (final w in [320.0, 360.0, 412.0]) {
      for (final r in [0, 1, 2]) {
        await pump(tester, payload: _payload(wizard: _wizard(resume: r)), size: Size(w, 900));
        expect(tester.takeException(), isNull, reason: '${w}px step $r');
      }
      await pump(tester,
          payload: {..._payload(), 'needs': false}, size: Size(w, 900));
      expect(find.text('PAYLOAD SUBMITTED'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '${w}px done');
    }
  });
}

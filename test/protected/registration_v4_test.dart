// CMD #2141 — Registration v4, held down on the widgets BOTH registration and
// staff Add customer draw (one step set, no fork).
//
// What must never drift:
//  • the top bar is green ONLY for a complete step — the current step stays
//    grey until its surface says it is done — and labels are the backend's;
//  • General: the backend's Mr/Ms box sits before the owner's name and writes
//    its own key; each checked box asks custreg_contact_check and prints the
//    verdict's suffix verbatim; "already registered" draws the verdict's card
//    with its Login label; a blocking verdict blocks Continue; an empty
//    required box shows the backend's "Required" after Continue;
//  • Screen: that same Continue still AUTO-SAVES what was typed (#2126) —
//    step_save with p_goto = the step it is on, so it saves in place and
//    never moves on while boxes are red;
//  • Documents: ONE progress card with the backend's words, one sub-line and
//    one circle per row, and the circle's `tap` decides edit / view / upload.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/auth/one_registration_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/customer_registration_form.dart';
import 'package:pharma_b2b/widgets/registration_licences_section.dart';
import 'package:pharma_b2b/widgets/registration_wizard.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

final _schema = <String, dynamic>{
  'required_suffix': ' *',
  'fields': [
    {'key': 'owner_salutation', 'label': 'Title', 'type': 'select', 'required': false, 'default': 'Mr', 'sort_order': 5},
    {'key': 'customer_name', 'label': 'Owner name', 'type': 'text', 'required': true, 'hint': 'Full name', 'sort_order': 8},
    {'key': 'pharmacy_name', 'label': 'Pharmacy name', 'type': 'text', 'required': true, 'hint': 'Shop name', 'sort_order': 10},
    {'key': 'whatsapp_no', 'label': 'WhatsApp number', 'type': 'phone', 'required': true, 'sort_order': 40},
    {'key': 'email', 'label': 'Email', 'type': 'email', 'required': true, 'sort_order': 70},
  ],
  'required_fields': ['customer_name', 'pharmacy_name', 'whatsapp_no', 'email'],
};

final _v4 = <String, dynamic>{
  'layout': 'v4',
  'prefix': {
    'customer_name': {
      'key': 'owner_salutation',
      'default': 'Mr',
      'options': [
        {'label': 'PFX Mr', 'value': 'Mr'},
        {'label': 'PFX Ms', 'value': 'Ms'},
      ],
    },
  },
  'checks': {'whatsapp_no': 'phone', 'email': 'email'},
  'check_debounce_ms': 10,
  'required_label': 'PAYLOAD Required',
  'checking_label': 'PAYLOAD Checking',
  'phone_prefix': '+91',
  'autofill': {'customer_name': 'name', 'email': 'email'},
};

const _fields = ['customer_name', 'pharmacy_name', 'whatsapp_no', 'email'];

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('Top bar', () {
    Color barColour(WidgetTester t, int i) {
      final seg = find.descendant(
          of: find.bySemanticsIdentifier('reg_step_$i'),
          matching: find.byType(Container));
      final box = t.widget<Container>(seg.first).decoration as BoxDecoration;
      return box.color!;
    }

    final steps = [
      {'key': 'shop', 'label': 'General', 'done_label': 'General', 'complete': true},
      {'key': 'location', 'label': 'Location', 'done_label': 'Location', 'complete': false},
      {'key': 'licences', 'label': 'Documents', 'done_label': 'Documents', 'complete': false},
    ];

    testWidgets('green only when complete; the current step stays grey', (t) async {
      await t.pumpWidget(_host(
          RegistrationProgressBar(steps: steps, current: 1, onJump: (_) {})));
      expect(barColour(t, 0), Ds.c.brand);
      expect(barColour(t, 1), Ds.c.divider, reason: 'current, not done');
      expect(barColour(t, 2), Ds.c.divider);
      expect(find.textContaining('✓'), findsNothing);
      final cur = t.widget<Text>(find.text('Location'));
      expect(cur.style?.fontWeight, FontWeight.w700, reason: 'current is bold');
    });

    testWidgets('the current step turns green when its surface says done', (t) async {
      await t.pumpWidget(_host(RegistrationProgressBar(
          steps: steps, current: 2, onJump: (_) {}, currentComplete: true)));
      expect(barColour(t, 2), Ds.c.brand);
    });

    testWidgets('a step BEHIND the current one stays grey until the backend calls it complete',
        (t) async {
      // QA round: a draft resumed on Documents with General and Location
      // unfinished painted both green only because they came first.
      await t.pumpWidget(_host(RegistrationProgressBar(
          steps: [
            {...steps[0], 'complete': false},
            steps[1],
            steps[2],
          ],
          current: 2,
          onJump: (_) {})));
      expect(barColour(t, 0), Ds.c.divider);
      expect(barColour(t, 1), Ds.c.divider);
      expect(barColour(t, 2), Ds.c.divider);
    });
  });

  group('General', () {
    Future<(CustomerFormController, List<Map<String, dynamic>>)> pump(
        WidgetTester t, Map<String, dynamic> Function(String field, String v) verdict) async {
      final calls = <Map<String, dynamic>>[];
      final ctrl = CustomerFormController(formContext: 'signup')..seed(_schema);
      await t.pumpWidget(_host(CustomerRegistrationForm(
        controller: ctrl,
        onlyFields: _fields,
        v4: _v4,
        checkRpc: (fn, p) async {
          calls.add({'fn': fn, ...p});
          return verdict(p['p_field'].toString(), p['p_value'].toString());
        },
      )));
      await t.pump();
      return (ctrl, calls);
    }

    testWidgets('Mr/Ms box sits before the owner name and writes its own key', (t) async {
      final (ctrl, _) = await pump(t, (_, _) => {'ok': true, 'state': 'ok'});
      expect(find.text('PFX Mr'), findsOneWidget);
      expect(ctrl.payload()['owner_salutation'], 'Mr');
      final pfx = t.getTopLeft(find.bySemanticsIdentifier('reg_prefix_owner_salutation'));
      final name = t.getTopLeft(find.widgetWithText(TextField, 'Full name'));
      expect(pfx.dx < name.dx, isTrue);
    });

    testWidgets('the backend\'s +91 shows in the EMPTY, unfocused WhatsApp box', (t) async {
      await pump(t, (_, _) => {'ok': true, 'state': 'ok'});
      expect(find.text('+91'), findsOneWidget,
          reason: 'prefixText hid it until focus; the prefix is always drawn');
    });

    testWidgets('a checked box prints the verdict suffix verbatim', (t) async {
      final (ctrl, calls) = await pump(t, (f, v) => {
            'ok': true, 'state': 'ok', 'blocks': false, 'suffix': 'SFX OK', 'tone': 'success'});
      await t.enterText(find.widgetWithText(TextField, '').at(2), '9876543210');
      await t.pump(const Duration(milliseconds: 50));
      await t.pump();
      expect(calls.last['fn'], 'custreg_contact_check');
      expect(calls.last['p_field'], 'whatsapp_no');
      expect(calls.last['p_value'], '9876543210');
      expect(find.text('SFX OK'), findsOneWidget);
      expect(ctrl.checksBlock, isFalse);
    });

    testWidgets('already registered: card line + Login label, Continue blocked', (t) async {
      final (ctrl, _) = await pump(t, (f, v) => {
            'ok': true, 'state': 'taken', 'blocks': true, 'suffix': 'SFX TAKEN', 'tone': 'warning',
            'card': {'line': 'CARD has an account', 'login_label': 'CARD Login', 'login_number': v}});
      await t.enterText(find.widgetWithText(TextField, '').at(3), 'a@b.co');
      await t.pump(const Duration(milliseconds: 50));
      await t.pump();
      expect(find.text('SFX TAKEN'), findsOneWidget);
      expect(find.text('CARD has an account'), findsOneWidget);
      expect(find.text('CARD Login'), findsOneWidget);
      expect(ctrl.checksBlock, isTrue);
    });

    testWidgets('staff card has no Login when the verdict sends none', (t) async {
      await pump(t, (f, v) => {
            'ok': true, 'state': 'taken', 'blocks': true, 'suffix': 'S', 'tone': 'warning',
            'card': {'line': 'CARD staff line', 'login_label': ''}});
      await t.enterText(find.widgetWithText(TextField, '').at(3), 'a@b.co');
      await t.pump(const Duration(milliseconds: 50));
      await t.pump();
      expect(find.text('CARD staff line'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('Continue reveals the backend "Required" under empty boxes only', (t) async {
      final (ctrl, _) = await pump(t, (_, _) => {'ok': true, 'state': 'ok'});
      expect(find.text('PAYLOAD Required'), findsNothing);
      await t.enterText(find.widgetWithText(TextField, 'Full name'), 'Chandra');
      expect(ctrl.missingAmong(_fields), ['pharmacy_name', 'whatsapp_no', 'email']);
      ctrl.revealRequired();
      await t.pump();
      expect(find.text('PAYLOAD Required'), findsNWidgets(3));
    });
  });

  group('Screen', () {
    tearDown(() => OneRegistrationScreen.rpcTransport = null);

    Map<String, dynamic> step(int n, String key, List<String> fields) => {
          'key': key,
          'n': n,
          'label': 'STEP $key',
          'done_label': 'DONE $key',
          'title': 'TITLE $key',
          'subtitle': '',
          'step_of': 'STEP $n OF 2',
          'fields': fields,
          'docs': false,
          'complete': false,
          'missing': [],
        };

    Map<String, dynamic> payload() => {
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
          'schema': {
            ..._schema,
            'ok': true,
            'context': 'signup',
            'sections': [
              {'key': 'business', 'title': 'BUSINESS', 'fields': _schema['fields']},
            ],
          },
          'prefill': const {},
          'draft': const {},
          'has_draft': false,
          'draft_note': '',
          'documents': {'show': false, 'rows': []},
          'docs_pending': {'show': false},
          'steps': const [],
          'step': const {'n': 1, 'total': 1},
          'wizard': {
            ..._v4,
            'enabled': true,
            'total': 2,
            'resume_step': 0,
            'steps': [step(1, 'shop', _fields), step(2, 'location', ['address'])],
            'continue_label': 'PAYLOAD CONTINUE',
            'back_label': 'PAYLOAD BACK',
            'saving_label': 'PAYLOAD SAVING',
            'submit_label': 'PAYLOAD SUBMIT',
            'submitting_label': 'PAYLOAD SUBMITTING',
          },
        };

    testWidgets('Continue with an empty required box still auto-saves, in place',
        (t) async {
      t.view.physicalSize = const Size(360, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      final calls = <Map<String, dynamic>>[];
      final p = payload();
      OneRegistrationScreen.rpcTransport = (fn, params) async {
        final prm = Map<String, dynamic>.from(params ?? const {});
        calls.add({'fn': fn, 'params': prm});
        if (fn == 'customer_registration_payload') return p;
        if (fn == 'customer_registration_step_save') {
          final to = prm['p_goto'] ?? 'location';
          return {'ok': true, 'step': to, 'step_index': to == 'shop' ? 0 : 1};
        }
        if (fn == 'custreg_contact_check') return {'ok': true, 'state': 'ok'};
        return null;
      };
      await t.pumpWidget(MaterialApp(key: UniqueKey(), home: const OneRegistrationScreen()));
      await t.pumpAndSettle();

      await t.enterText(find.widgetWithText(TextField, 'Full name'), 'Chandra');
      await t.tap(find.text('PAYLOAD CONTINUE'));
      await t.pumpAndSettle();

      final saves =
          calls.where((c) => c['fn'] == 'customer_registration_step_save').toList();
      expect(saves, hasLength(1), reason: 'what was typed is saved while boxes are red');
      expect(saves.single['params']['p_step'], 'shop');
      expect(saves.single['params']['p_goto'], 'shop',
          reason: 'it saves in place and never moves on');
      expect((saves.single['params']['p_values'] as Map)['customer_name'], 'Chandra');
      expect(find.text('PAYLOAD Required'), findsNWidgets(3));
      expect(find.widgetWithText(TextField, 'Full name'), findsOneWidget,
          reason: 'still on the General step');
    });
  });

  group('Documents', () {
    Map<String, dynamic> row(String key, String label,
            {required Map<String, dynamic> circle, required Map<String, dynamic> sub}) =>
        {
          'key': key,
          'label': label,
          'required': true,
          'group': 'required',
          'state': 'needed',
          'thumb': {'kind': 'none'},
          'dont_have': {'show': true, 'on': false, 'label': 'DH', 'undo_label': 'UNDO'},
          'circle': circle,
          'sub': sub,
          'act': {'kind': 'upload', 'label': ''},
          'action': {'kind': 'upload'},
        };

    Map<String, dynamic> block(List<Map<String, dynamic>> rows) => {
          'show': true,
          'layout': 'v4',
          'saved_note': '',
          'reading_label': 'READING',
          'progress': {
            'title': 'PG Required papers',
            'count_label': 'PG 2 of 3 done',
            'bar': true,
            'fraction': 0.667,
            'tone': 'brand',
            'line': 'PG Still needed: GST',
            'line_tone': 'neutral',
          },
          'groups': [
            {'key': 'required', 'title': 'Required', 'counter_label': '', 'rows': rows},
          ],
        };

    testWidgets('one progress card and one sub-line per row, verbatim', (t) async {
      await t.pumpWidget(_host(RegistrationLicencesSection(
        block: block([
          row('dl_20b', 'Drug Licence 20B',
              circle: {'icon': 'check', 'tone': 'success', 'filled': true, 'tap': 'edit'},
              sub: {'text': 'RLF20CT1 · till 24 Mar 2031', 'tone': 'neutral'}),
          row('gst', 'GST', circle: {'icon': 'upload', 'tone': 'brand', 'tap': 'upload'},
              sub: {'text': 'SUB Needed', 'tone': 'warning'}),
        ]),
        picked: const {},
        skipped: const {},
        thumbUrls: const {},
        onUpload: (_) {},
        onView: (_) {},
        onSkipToggle: (_) {},
        onScan: () {},
      )));
      expect(find.bySemanticsIdentifier('reg_doc_progress'), findsOneWidget);
      for (final s in ['PG Required papers', 'PG 2 of 3 done', 'PG Still needed: GST',
                       'RLF20CT1 · till 24 Mar 2031', 'SUB Needed']) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('the circle\'s tap picks edit / upload', (t) async {
      final hits = <String>[];
      await t.pumpWidget(_host(RegistrationLicencesSection(
        block: block([
          row('dl_20b', 'A', circle: {'icon': 'edit', 'tone': 'warning', 'tap': 'edit'},
              sub: {'text': 'x', 'tone': 'warning'}),
          row('gst', 'B', circle: {'icon': 'upload', 'tone': 'brand', 'tap': 'upload'},
              sub: {'text': 'y', 'tone': 'warning'}),
        ]),
        picked: const {},
        skipped: const {},
        thumbUrls: const {},
        onUpload: (r) => hits.add('upload:${r['key']}'),
        onView: (r) => hits.add('view:${r['key']}'),
        onEdit: (r) => hits.add('edit:${r['key']}'),
        onSkipToggle: (_) {},
        onScan: () {},
      )));
      await t.tap(find.bySemanticsIdentifier('reg_lic_action_dl_20b'));
      await t.tap(find.bySemanticsIdentifier('reg_lic_action_gst'));
      expect(hits, ['edit:dl_20b', 'upload:gst']);
      expect(find.byIcon(Icons.edit_rounded), findsOneWidget);
    });
  });
}

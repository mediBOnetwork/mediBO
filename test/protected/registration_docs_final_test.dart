// CMD #2141 — Documents step, final rules (Om, 22 Sep 2026), held down on the
// ONE widget registration and staff Add customer both draw.
//
// What must never drift:
//  • no Skip unless the BACKEND offers it on the row (dont_have.show) — no
//    client-side "required" rule, and a key skipped earlier draws nothing;
//  • a row is two lines at most: the name, then ONE line (row.sub), each
//    ellipsised, never wrapped;
//  • tapping the number of a read row opens its edit sheet; a row still being
//    read shows the backend's reading_label and opens nothing;
//  • the edit sheet picks "Valid till" from a date picker and sends ISO,
//    shows "✓ read" only on fields the photo filled, and saves every field;
//  • v3 AND v4 blocks upload on pick; Submit waits for required_complete and
//    for every upload in flight, and prints the backend's gate line.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/auth/one_registration_screen.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/registration_licences_section.dart';

Map<String, dynamic> _row(String key,
        {bool required = false,
        bool skipShow = false,
        Map<String, dynamic>? edit,
        String sub = 'SUB OPTIONAL'}) =>
    {
      'key': key,
      'label': 'LABEL $key',
      'required': required,
      'reads': true,
      'state': edit == null ? 'needed' : 'uploaded',
      'sub': {'text': sub, 'tone': required ? 'warning' : 'neutral'},
      'tag': {'text': required ? 'TAG MANDATORY' : 'TAG OPTIONAL', 'tone': 'neutral'},
      'circle': {
        'tap': edit == null ? 'upload' : 'edit',
        'icon': edit == null ? 'upload' : 'check',
        'tone': edit == null ? 'brand' : 'success',
        'filled': edit != null,
      },
      'thumb': {'kind': 'none', 'path': '', 'badge': 'PDF', 'pages': 0, 'bucket': 'kyc-docs'},
      'can_view': false,
      'dont_have': {'show': skipShow, 'on': false, 'label': 'SKIP', 'undo_label': 'UNDO'},
      'edit': edit,
    };

final _edit = <String, dynamic>{
  'title': 'EDIT TITLE',
  'line': 'EDIT LINE',
  'fields': [
    {'key': 'number', 'label': 'F NUMBER', 'value': 'RLF20', 'read': true,
     'read_label': 'READ TICK', 'date': false},
    {'key': 'valid_to', 'label': 'F VALID', 'value': '31 Dec 2027', 'read': false,
     'read_label': 'READ TICK', 'date': true},
    {'key': 'name', 'label': 'F NAME', 'value': '', 'read': false,
     'read_label': 'READ TICK', 'date': false},
  ],
  'retake_label': 'RETAKE',
  'confirm_label': 'SAVE',
};

Map<String, dynamic> _block({bool complete = false, List<Map<String, dynamic>>? rows}) => {
      'show': true,
      'layout': 'v4',
      'required_complete': complete,
      'required_done': complete ? 1 : 0,
      'required_total': 1,
      'reading_label': 'READING',
      'upload_failed_label': 'FAILED',
      'footnote': '',
      'saved_note': '',
      'progress': const <String, dynamic>{},
      'scan': const {'show': false},
      'groups': [
        {
          'key': 'all',
          'title': 'DOCUMENTS',
          'counter_label': '',
          'rows': rows ?? [_row('dl_20b', required: true, sub: 'SUB MANDATORY')],
        },
      ],
    };

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

RegistrationLicencesSection _section(Map<String, dynamic> block,
        {Set<String> skipped = const {},
        Set<String> reading = const {},
        void Function(Map<String, dynamic>)? onEdit}) =>
    RegistrationLicencesSection(
      block: block,
      picked: const {},
      skipped: skipped,
      thumbUrls: const {},
      onUpload: (_) {},
      onView: (_) {},
      onSkipToggle: (_) {},
      onScan: () {},
      onEdit: onEdit,
      reading: reading,
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('Rows', () {
    testWidgets('no Skip when the backend does not offer it — even for a skipped key',
        (t) async {
      await t.pumpWidget(_host(_section(
          _block(rows: [_row('dl_20b', required: true), _row('gst')]),
          skipped: {'dl_20b', 'gst'})));
      expect(find.text('SKIP'), findsNothing);
      expect(find.text('UNDO'), findsNothing);
      expect(find.bySemanticsIdentifier('reg_lic_skip_dl_20b'), findsNothing);
      expect(find.bySemanticsIdentifier('reg_lic_skip_gst'), findsNothing);
    });

    testWidgets('Skip appears only where the row offers it — no client-side rule',
        (t) async {
      await t.pumpWidget(_host(_section(_block(rows: [
        _row('dl_20b', required: false, skipShow: true),
        _row('gst', required: true),
      ]))));
      expect(find.bySemanticsIdentifier('reg_lic_skip_dl_20b'), findsOneWidget);
      expect(find.bySemanticsIdentifier('reg_lic_skip_gst'), findsNothing);
    });

    testWidgets('two lines at most: name and row.sub, each one line with ellipsis',
        (t) async {
      await t.pumpWidget(_host(_section(_block(rows: [
        _row('dl_20b', required: true, sub: 'SUB MANDATORY'),
      ]))));
      for (final s in ['LABEL dl_20b', 'SUB MANDATORY']) {
        final txt = t.widget<Text>(find.text(s));
        expect(txt.maxLines, 1, reason: s);
        expect(txt.overflow, TextOverflow.ellipsis, reason: s);
      }
      expect(find.text('TAG MANDATORY'), findsNothing,
          reason: 'the second line is row.sub, never a third line');
    });

    testWidgets('tapping the number of a read row opens its edit sheet', (t) async {
      final hits = <String>[];
      await t.pumpWidget(_host(_section(
          _block(rows: [_row('dl_20b', required: true, edit: _edit, sub: 'RLF20')]),
          onEdit: (r) => hits.add(r['key'].toString()))));
      await t.tap(find.text('RLF20'));
      await t.pump();
      expect(hits, ['dl_20b']);
    });

    testWidgets('a row being read prints reading_label and opens nothing', (t) async {
      final hits = <String>[];
      await t.pumpWidget(_host(_section(
          _block(rows: [_row('dl_20b', required: true, edit: _edit, sub: 'RLF20')]),
          reading: {'dl_20b'},
          onEdit: (r) => hits.add(r['key'].toString()))));
      expect(find.text('READING'), findsOneWidget);
      expect(find.text('RLF20'), findsNothing);
      await t.tap(find.text('READING'));
      await t.pump();
      expect(hits, isEmpty);
    });
  });

  group('Edit sheet', () {
    testWidgets('Valid till is picked (ISO out), ✓ read only on read fields, Save sends all',
        (t) async {
      t.view.physicalSize = const Size(412, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      Map<String, String>? sent;
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showModalBottomSheet<bool>(
                  context: ctx,
                  isScrollControlled: true,
                  builder: (_) => DocReadEditSheet(
                    edit: _edit,
                    thumb: const SizedBox.shrink(),
                    onConfirm: (v) async {
                      sent = v;
                      return null;
                    },
                    onRetake: () {},
                    onViewPhoto: () {},
                  ),
                ),
                child: const Text('OPEN'),
              ),
            ),
          ),
        ),
      ));
      await t.tap(find.text('OPEN'));
      await t.pumpAndSettle();
      expect(find.text('READ TICK'), findsOneWidget);

      await t.tap(find.bySemanticsIdentifier('reg_doc_edit_valid_to'));
      await t.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget,
          reason: 'Valid till opens a date picker, it is never typed');
      await t.tap(find.text('15'));
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
      expect(find.text('2027-12-15'), findsOneWidget);

      await t.enterText(find.bySemanticsIdentifier('reg_doc_edit_name'), 'Chandra Medicals');
      await t.tap(find.text('SAVE'));
      await t.pumpAndSettle();
      expect(sent, {'number': 'RLF20', 'valid_to': '2027-12-15', 'name': 'Chandra Medicals'});
    });

    test('parseDocDate reads the backend and picker shapes only', () {
      expect(parseDocDate('31 Dec 2027'), DateTime(2027, 12, 31));
      expect(parseDocDate('2027-12-15'), DateTime(2027, 12, 15));
      expect(parseDocDate('garbage'), isNull);
    });
  });

  group('Registration', () {
    test('v3 AND v4 blocks upload the moment a paper is picked', () {
      expect(OneRegistrationScreen.uploadsOnPick({'layout': 'v4'}), isTrue);
      expect(OneRegistrationScreen.uploadsOnPick({'layout': 'v3'}), isTrue);
      expect(OneRegistrationScreen.uploadsOnPick({'layout': 'v2'}), isFalse);
      expect(OneRegistrationScreen.uploadsOnPick(const {}), isFalse);
    });

    test('Submit waits for required_complete and for every upload in flight', () {
      expect(OneRegistrationScreen.docsBlockSubmit(_block(complete: false), false), isTrue);
      expect(OneRegistrationScreen.docsBlockSubmit(_block(complete: true), true), isTrue);
      expect(OneRegistrationScreen.docsBlockSubmit(_block(complete: true), false), isFalse);
      expect(OneRegistrationScreen.docsBlockSubmit({'show': false}, true), isFalse,
          reason: 'no documents block, nothing to wait for');
    });

    Map<String, dynamic> step(int n, String key, List<String> fields, {bool docs = false}) => {
          'key': key,
          'n': n,
          'label': 'STEP $key',
          'done_label': 'DONE $key',
          'title': 'TITLE $key',
          'subtitle': '',
          'step_of': 'STEP $n OF 3',
          'fields': fields,
          'docs': docs,
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
            'ok': true,
            'context': 'signup',
            'required_suffix': ' *',
            'fields': const [],
            'sections': const [],
            'required_fields': const [],
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
            'layout': 'v4',
            'enabled': true,
            'total': 3,
            'resume_step': 2,
            'steps': [
              step(1, 'shop', const []),
              step(2, 'location', const []),
              step(3, 'licences', const [], docs: true),
            ],
            'continue_label': 'PAYLOAD CONTINUE',
            'back_label': 'PAYLOAD BACK',
            'saving_label': 'PAYLOAD SAVING',
            'submit_label': 'PAYLOAD SUBMIT',
            'submitting_label': 'PAYLOAD SUBMITTING',
          },
        };

    Future<void> pumpDocsStep(WidgetTester t, Map<String, dynamic> block) async {
      t.view.physicalSize = const Size(360, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      addTearDown(() => OneRegistrationScreen.rpcTransport = null);
      UiCopy.debugSet({'custreg.v4_submit_gate': 'GATE LINE'});
      addTearDown(() => UiCopy.debugSet(const {}));
      final p = payload();
      OneRegistrationScreen.rpcTransport = (fn, params) async {
        if (fn == 'customer_registration_payload') return p;
        if (fn == 'custreg_licences_step') return block;
        return null;
      };
      await t.pumpWidget(MaterialApp(key: UniqueKey(), home: const OneRegistrationScreen()));
      await t.pumpAndSettle();
    }

    FilledButton primary(WidgetTester t) => t.widget<FilledButton>(find.descendant(
        of: find.bySemanticsIdentifier('reg_primary'), matching: find.byType(FilledButton)));

    testWidgets('Submit is off with a Mandatory paper missing, and says why', (t) async {
      await pumpDocsStep(t, _block(complete: false));
      expect(find.text('PAYLOAD SUBMIT'), findsOneWidget);
      expect(primary(t).onPressed, isNull);
      expect(find.text('GATE LINE'), findsOneWidget);
    });

    testWidgets('every Mandatory paper in: Submit is on and the line is gone', (t) async {
      await pumpDocsStep(t, _block(complete: true));
      expect(primary(t).onPressed, isNotNull);
      expect(find.text('GATE LINE'), findsNothing);
    });
  });
}

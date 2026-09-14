// PROTECTED — CMD #1986 (Om: "all fields in agreement should be editable no
// hardcoded at all").
//
// The printed contract has exactly one editor, and this file refuses to let it
// drift back into code:
//   • Every section heading, hint, button caption and empty state on the screen
//     comes from agreement_doc_editor() — nothing is a Dart literal.
//   • The three writes carry the shapes the backend expects: a recital and a
//     defined term through agreement_front_save with their kind, a schedule
//     through agreement_schedule_save with its source, one printed word through
//     agreement_text_save with its key.
//   • A write REDRAWS from the state the backend handed back — the screen never
//     patches its own list, so what is on screen is always what was stored.
//   • can_edit:false is read-only: the backend's notice is printed and no door
//     is live. That is the super-admin gate, drawn from the payload rather than
//     from a role check in Dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/agreement_document_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> editorPayload({bool canEdit = true}) => {
      'ok': true,
      'version_id': 3,
      'version': 2,
      'title': 'Printed document',
      'sub': 'Everything the partner agreement PDF prints is edited here.',
      'can_edit': canEdit,
      'readonly_note': canEdit ? '' : 'Only a super-admin can change this.',
      'save_label': 'Save',
      'delete_label': 'Delete',
      'token_help': 'Type {{partner}} instead of a name.',
      'recitals': {
        'heading': 'Recitals',
        'hint': 'The WHEREAS paragraphs printed before clause 1.',
        'add_label': 'Add a recital',
        'body_hint': 'The wording.',
        'empty': 'No recitals yet. Add the first one.',
        'items': [
          {'id': 11, 'n': 1, 'body': 'WHEREAS the Operator runs the platform;'},
        ],
      },
      'definitions': {
        'heading': 'Defined terms',
        'hint': 'Each term is printed in bold.',
        'add_label': 'Add a defined term',
        'term_hint': 'The term, in quotes',
        'body_hint': 'The wording.',
        'empty': 'No defined terms yet. Add the first one.',
        'items': [
          {'id': 21, 'n': 1, 'term': '"Partner Share"', 'body': 'means 12.50%.'},
        ],
      },
      'schedules': {
        'heading': 'Schedules',
        'hint': 'The schedules printed at the back, in this order.',
        'add_label': 'Add a schedule',
        'code_hint': 'Schedule code',
        'heading_hint': 'Schedule title',
        'intro_hint': 'Opening sentence',
        'note_hint': 'Closing note',
        'source_label': 'Table filled from',
        'empty': 'No schedules yet. Add the first one.',
        'sources': [
          {'key': 'terms', 'label': 'Commercial terms'},
          {'key': 'licences', 'label': 'Licences and expiry'},
          {'key': 'zone', 'label': 'Zone coverage'},
          {'key': 'none', 'label': 'No table - words only'},
        ],
        'items': [
          {
            'id': 31,
            'sort': 1,
            'code': 'Schedule A',
            'heading': 'Commercial terms',
            'intro': 'These are the terms the Platform settles on.',
            'note': 'A change takes effect only through a new version.',
            'source': 'terms',
            'source_label': 'Commercial terms',
            'is_active': true,
          },
        ],
      },
      'wording': {
        'heading': 'Every printed word',
        'hint': 'Each field below is one piece of text on the contract.',
        'empty': 'No fields registered.',
        'groups': [
          {
            'group_label': 'Cover page',
            'sort': '10',
            'fields': [
              {
                'key': 'agree_pdf.cover_kicker',
                'label': 'Kicker above the title',
                'hint': 'Small line above the agreement title.',
                'multiline': false,
                'value': 'Fulfilment partner agreement',
              },
            ],
          },
        ],
      },
    };

Future<List<List<Object?>>> _pump(WidgetTester tester,
    {bool canEdit = true, Map<String, dynamic>? after}) async {
  final calls = <List<Object?>>[];
  AgreementDocumentScreen.rpcTransport = (fn, params) async {
    calls.add([fn, params]);
    if (fn == 'agreement_doc_editor') return editorPayload(canEdit: canEdit);
    return {
      'ok': true,
      'message': 'Saved. The next PDF prints it.',
      'editor': after ?? editorPayload(canEdit: canEdit),
    };
  };
  // Mobile-first, but tall: the editor is a long page and a 412x800 viewport
  // would leave the last section unbuilt, which is a test artefact and not a
  // fact about the screen.
  tester.view.physicalSize = const Size(412, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
      const MaterialApp(home: AgreementDocumentScreen(versionId: 3)));
  await tester.pumpAndSettle();
  return calls;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => AgreementDocumentScreen.rpcTransport = null);

  testWidgets('every word on the editor is the backend\'s', (tester) async {
    await _pump(tester);
    final p = editorPayload();
    for (final s in <String>[
      p['title'] as String,
      p['sub'] as String,
      (p['recitals'] as Map)['heading'] as String,
      (p['recitals'] as Map)['hint'] as String,
      (p['recitals'] as Map)['add_label'] as String,
      (p['definitions'] as Map)['heading'] as String,
      (p['definitions'] as Map)['add_label'] as String,
      (p['schedules'] as Map)['heading'] as String,
      (p['schedules'] as Map)['add_label'] as String,
      (p['wording'] as Map)['heading'] as String,
    ]) {
      expect(find.text(s), findsWidgets, reason: '"$s" must be printed verbatim');
    }
    // the stored rows themselves
    expect(find.text('WHEREAS the Operator runs the platform;'), findsOneWidget);
    expect(find.text('"Partner Share"'), findsOneWidget);
    expect(find.text('Schedule A — Commercial terms'), findsOneWidget);
  });

  testWidgets('editing a recital sends kind + id and redraws from the state '
      'the backend returned', (tester) async {
    final changed = editorPayload();
    (changed['recitals'] as Map)['items'] = [
      {'id': 11, 'n': 1, 'body': 'WHEREAS the Operator now does something else;'}
    ];
    final calls = await _pump(tester, after: changed);

    await tester.tap(find.text('WHEREAS the Operator runs the platform;'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first,
        'WHEREAS the Operator now does something else;');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final save = calls.firstWhere((c) => c[0] == 'agreement_front_save',
        orElse: () => const []);
    expect(save, isNotEmpty);
    final body = (save[1] as Map<String, dynamic>)['p'] as Map<String, dynamic>;
    expect(body['id'], 11);
    expect(body['kind'], 'recital');
    expect(body['body'], 'WHEREAS the Operator now does something else;');

    // The list is the one the BACKEND sent back, not a local patch.
    expect(find.text('WHEREAS the Operator now does something else;'),
        findsOneWidget);
    expect(find.text('WHEREAS the Operator runs the platform;'), findsNothing);
  });

  testWidgets('a new defined term carries version_id and no id', (tester) async {
    final calls = await _pump(tester);
    await tester.tap(find.text('Add a defined term'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '"Zone"');
    await tester.enterText(find.byType(TextField).last, 'means the area.');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final body = ((calls.firstWhere((c) => c[0] == 'agreement_front_save')[1]
        as Map<String, dynamic>)['p']) as Map<String, dynamic>;
    expect(body.containsKey('id'), isFalse);
    expect(body['version_id'], 3);
    expect(body['kind'], 'definition');
    expect(body['term'], '"Zone"');
  });

  testWidgets('a schedule carries the source key the backend offered',
      (tester) async {
    final calls = await _pump(tester);
    await tester.tap(find.text('Schedule A — Commercial terms'));
    await tester.pumpAndSettle();
    // the four sources are the payload's, drawn as chips
    expect(find.text('Licences and expiry'), findsOneWidget);
    await tester.tap(find.text('Licences and expiry'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final body = ((calls.firstWhere((c) => c[0] == 'agreement_schedule_save')[1]
        as Map<String, dynamic>)['p']) as Map<String, dynamic>;
    expect(body['id'], 31);
    expect(body['source'], 'licences');
    expect(body['code'], 'Schedule A');
  });

  testWidgets('one printed word is saved by its KEY, never by its label',
      (tester) async {
    final calls = await _pump(tester);
    await tester.tap(find.text('Cover page'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kicker above the title').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Partner agreement');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final body = ((calls.firstWhere((c) => c[0] == 'agreement_text_save')[1]
        as Map<String, dynamic>)['p']) as Map<String, dynamic>;
    expect(body['key'], 'agree_pdf.cover_kicker');
    expect(body['value'], 'Partner agreement');
    expect(body['version_id'], 3);
  });

  testWidgets('can_edit:false prints the backend notice and opens no door',
      (tester) async {
    await _pump(tester, canEdit: false);
    expect(find.text('Only a super-admin can change this.'), findsOneWidget);

    // Every add button is disabled — the gate is the payload, not a Dart role
    // check, and not a hidden button that still fires.
    for (final f in <Finder>[
      find.widgetWithText(OutlinedButton, 'Add a recital'),
      find.widgetWithText(OutlinedButton, 'Add a defined term'),
      find.widgetWithText(OutlinedButton, 'Add a schedule'),
    ]) {
      expect(tester.widget<OutlinedButton>(f).onPressed, isNull);
    }
    // Tapping a stored row opens nothing.
    await tester.tap(find.text('WHEREAS the Operator runs the platform;'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });
}

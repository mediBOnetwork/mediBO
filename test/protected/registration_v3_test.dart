// CMD #2135 — Registration v3 (General · Location · Documents), held down.
//
// What must never drift:
//  • the step bar prints the backend's labels (no numbers composed in Dart),
//    each centred under its own bar;
//  • store type is ONE chip row whose chips show a short label and store the
//    backend's value ("Retail" stores "Retail Pharmacy");
//  • the State / District sheet prints the official rows it was sent, ticks
//    the current one, filters without inventing names, and hands back a name;
//  • a v3 document row prints the number read off the photo, its "Valid till"
//    line and the backend's action (Edit / Type / View), shows the backend's
//    "Reading the number…" while a read is in flight, and Edit reaches onEdit;
//  • the Edit sheet shows "Read ✓" only on fields the backend marked read and
//    stays open with the backend's sentence when saving is refused.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/widgets/customer_registration_form.dart' show RegChip;
import 'package:pharma_b2b/widgets/registration_licences_section.dart';
import 'package:pharma_b2b/widgets/registration_location_step.dart'
    show PlacePickerSheet;
import 'package:pharma_b2b/widgets/registration_wizard.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Map<String, dynamic> _docRow(
  String key,
  String label, {
  required String state,
  required Map<String, dynamic> act,
  String number = '',
  String validLine = '',
  String line = '',
  String lineTone = 'neutral',
  String statusLabel = '',
  bool canView = false,
  Map<String, dynamic>? edit,
}) =>
    {
      'key': key,
      'label': label,
      'group': 'required',
      'state': state,
      'status_label': statusLabel,
      'status_tone': 'warning',
      'action': {'kind': 'upload', 'icon': 'upload', 'tone': 'brand'},
      'can_view': canView,
      'thumb': {'kind': canView ? 'image' : 'none', 'bucket': 'kyc-docs', 'path': '', 'pages': 1},
      'dont_have': {'show': state == 'needed', 'on': false, 'label': "Don't have", 'undo_label': 'Undo'},
      'reads': true,
      'number': number,
      'valid_line': validLine,
      'line': line,
      'line_tone': lineTone,
      'act': act,
      'edit': edit,
    };

final _edit = <String, dynamic>{
  'title': 'Drug Licence 20B',
  'line': 'Read from your photo · tap the photo to zoom',
  'fields': [
    {'key': 'number', 'label': 'Licence number', 'value': 'CG/RPR/20B/12345', 'read': true, 'read_label': 'Read ✓'},
    {'key': 'valid_to', 'label': 'Valid till', 'value': '31 Mar 2029', 'read': true, 'read_label': 'Read ✓'},
    {'key': 'name', 'label': 'Name on licence', 'value': '', 'read': false, 'read_label': 'Read ✓'},
  ],
  'retake_label': 'Retake photo',
  'confirm_label': 'Looks right',
};

Map<String, dynamic> _block(List<Map<String, dynamic>> rows) => {
      'show': true,
      'layout': 'v3',
      'reading_label': 'Reading the number…',
      'saved_note': '✓ Saved — your uploads stay here if you leave and come back.',
      'scan': {'show': false},
      'groups': [
        {'key': 'required', 'title': 'Required', 'counter_label': '1 of 3 done', 'counter_tone': 'warning', 'rows': rows},
      ],
      'footnote': '',
    };

Widget _section(Map<String, dynamic> block,
        {Set<String> reading = const {},
        void Function(Map<String, dynamic>)? onEdit,
        void Function(Map<String, dynamic>)? onView,
        void Function(Map<String, dynamic>)? onUpload}) =>
    _host(RegistrationLicencesSection(
      block: block,
      picked: const {},
      skipped: const {},
      thumbUrls: const {},
      onUpload: onUpload ?? (_) {},
      onView: onView ?? (_) {},
      onSkipToggle: (_) {},
      onScan: () {},
      onEdit: onEdit,
      reading: reading,
    ));

void main() {
  group('Step bar', () {
    testWidgets('prints the backend labels, centred, no numbers added', (t) async {
      final steps = [
        {'key': 'shop', 'label': 'General', 'done_label': '✓ General', 'complete': true},
        {'key': 'location', 'label': 'Location', 'done_label': '✓ Location', 'complete': false},
        {'key': 'licences', 'label': 'Documents', 'done_label': '✓ Documents', 'complete': false},
      ];
      await t.pumpWidget(_host(
          RegistrationProgressBar(steps: steps, current: 1, onJump: (_) {})));
      expect(find.text('✓ General'), findsOneWidget);
      expect(find.text('Location'), findsOneWidget);
      expect(find.text('Documents'), findsOneWidget);
      for (final w in t.widgetList<Text>(find.byType(Text))) {
        expect(w.textAlign, TextAlign.center, reason: w.data);
        expect(RegExp(r'\d').hasMatch(w.data ?? ''), isFalse, reason: w.data);
      }
    });
  });

  group('Store type chips', () {
    test('a chip shows its label and stores the backend value', () {
      final chips = RegChip.parse([
        {'label': 'Retail', 'value': 'Retail Pharmacy'},
        {'label': 'Hospital', 'value': 'Hospital Pharmacy'},
        'Clinic',
      ]);
      expect(chips.map((c) => c.label), ['Retail', 'Hospital', 'Clinic']);
      expect(chips.map((c) => c.value), ['Retail Pharmacy', 'Hospital Pharmacy', 'Clinic']);
      expect(RegChip.parse(null), isEmpty);
    });
  });

  group('State / District sheet', () {
    final block = {
      'title': 'District',
      'subtitle': 'Chhattisgarh · 33 districts',
      'search_hint': 'Search district',
      'empty_label': 'Nothing matches that — check the spelling',
      'rows': [
        {'name': 'Balod'},
        {'name': 'Bilaspur'},
        {'name': 'Raipur'},
      ],
    };

    testWidgets('prints the rows it was sent and ticks the current one', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: PlacePickerSheet(block: block, current: 'Raipur'))));
      expect(find.text('District'), findsOneWidget);
      expect(find.text('Chhattisgarh · 33 districts'), findsOneWidget);
      expect(find.text('Balod'), findsOneWidget);
      expect(find.text('Bilaspur'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('search narrows the list and never invents a name', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: PlacePickerSheet(block: block, current: ''))));
      await t.enterText(find.byType(TextField), 'bil');
      await t.pump();
      expect(find.text('Bilaspur'), findsOneWidget);
      expect(find.text('Balod'), findsNothing);
      await t.enterText(find.byType(TextField), 'Raypur');
      await t.pump();
      expect(find.text('Nothing matches that — check the spelling'), findsOneWidget);
    });

    testWidgets('a tap hands back the official name', (t) async {
      String? picked;
      await t.pumpWidget(MaterialApp(home: Builder(builder: (ctx) {
        return Scaffold(
          body: TextButton(
            onPressed: () async {
              picked = await showModalBottomSheet<String>(
                  context: ctx,
                  isScrollControlled: true,
                  builder: (_) => PlacePickerSheet(block: block, current: ''));
            },
            child: const Text('open'),
          ),
        );
      })));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Bilaspur'));
      await t.pumpAndSettle();
      expect(picked, 'Bilaspur');
    });
  });

  group('Documents v3 rows', () {
    testWidgets('number, valid line and Edit are the row verbatim', (t) async {
      Map<String, dynamic>? edited;
      await t.pumpWidget(_section(
        _block([
          _docRow('dl_20b', 'Drug Licence 20B',
              state: 'uploaded',
              number: 'RLF20CT2026000911',
              validLine: 'Valid till 24 Mar 2031',
              canView: true,
              act: {'kind': 'edit', 'label': 'Edit'},
              edit: _edit),
        ]),
        onEdit: (r) => edited = r,
      ));
      expect(find.text('RLF20CT2026000911'), findsOneWidget);
      expect(find.text('Valid till 24 Mar 2031'), findsOneWidget);
      expect(find.text('✓ Saved — your uploads stay here if you leave and come back.'),
          findsOneWidget);
      await t.tap(find.text('Edit'));
      expect(edited?['key'], 'dl_20b');
    });

    testWidgets('an unreadable photo says so and offers Type', (t) async {
      await t.pumpWidget(_section(_block([
        _docRow('fssai', 'FSSAI Licence',
            state: 'uploaded',
            line: "Couldn't read — tap to type",
            lineTone: 'warning',
            canView: true,
            act: {'kind': 'type', 'label': 'Type'},
            edit: _edit),
      ])));
      expect(find.text("Couldn't read — tap to type"), findsOneWidget);
      expect(find.text('Type'), findsOneWidget);
    });

    testWidgets('a photo-only paper is View, a needed one is Needed + upload',
        (t) async {
      Map<String, dynamic>? viewed;
      await t.pumpWidget(_section(
        _block([
          _docRow('shop_photo', 'Shop Photo',
              state: 'uploaded',
              line: '✓ Uploaded',
              lineTone: 'success',
              canView: true,
              act: {'kind': 'view', 'label': 'View'}),
          _docRow('pan', 'PAN Card',
              state: 'needed', statusLabel: 'Needed', act: {'kind': 'upload', 'label': ''}),
        ]),
        onView: (r) => viewed = r,
      ));
      expect(find.text('✓ Uploaded'), findsOneWidget);
      expect(find.text('Needed'), findsOneWidget);
      expect(find.text("Don't have"), findsOneWidget);
      await t.tap(find.text('View'));
      expect(viewed?['key'], 'shop_photo');
    });

    testWidgets('a read in flight shows the backend reading line', (t) async {
      await t.pumpWidget(_section(
        _block([
          _docRow('dl_20b', 'Drug Licence 20B',
              state: 'needed', statusLabel: 'Needed', act: {'kind': 'upload', 'label': ''}),
        ]),
        reading: const {'dl_20b'},
      ));
      expect(find.text('Reading the number…'), findsOneWidget);
      expect(find.text('Needed'), findsNothing);
    });
  });

  group('Edit sheet', () {
    testWidgets('Read ✓ only where the backend read it; refusal keeps it open',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DocReadEditSheet(
            edit: _edit,
            thumb: const SizedBox(width: 48, height: 48),
            onConfirm: (v) async =>
                v['valid_to'] == '31 Mar 2029' ? 'Valid till should look like 31 Mar 2029' : null,
            onRetake: () {},
            onViewPhoto: () {},
          ),
        ),
      ));
      expect(find.text('Read ✓'), findsNWidgets(2));
      expect(find.text('CG/RPR/20B/12345'), findsOneWidget);
      expect(find.text('Retake photo'), findsOneWidget);
      await t.tap(find.text('Looks right'));
      await t.pump();
      expect(find.text('Valid till should look like 31 Mar 2029'), findsOneWidget);
      expect(find.byType(DocReadEditSheet), findsOneWidget);
    });
  });
}

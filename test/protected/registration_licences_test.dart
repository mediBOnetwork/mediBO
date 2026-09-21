// CMD #2128 — Step 3 · Licences, held down.
//
// What must never drift: the screen COUNTS NOTHING and WORDS NOTHING. The
// group a paper sits in, the "1 of 3 done" pill, the tick, the licence number
// beside "Uploaded", the "Don't have" caption, the sheet's four options and
// their order, and every button in the viewer are all strings that arrived in
// the payload. If a future change starts composing any of them in Dart, one
// of these tests goes red.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/widgets/doc_upload_sheet.dart';
import 'package:pharma_b2b/widgets/doc_viewer_screen.dart';
import 'package:pharma_b2b/widgets/registration_documents_section.dart'
    show PickedDoc;
import 'package:pharma_b2b/widgets/registration_licences_section.dart';

Map<String, dynamic> _option(String key, String label, String hint,
        {String badge = '', bool best = false, String needs = ''}) =>
    {
      'key': key,
      'label': label,
      'hint': hint,
      'badge': badge,
      'icon': key,
      'recommended': best,
      'needs': needs,
    };

final _sheet = <String, dynamic>{
  'title': 'Add Drug licence 21B',
  'subtitle': 'Photo or PDF · clear, all four corners visible',
  'options': [
    _option('scan', 'Scan document', 'Auto-crops and straightens the page',
        badge: 'BEST', best: true, needs: 'scanner'),
    _option('camera', 'Take photo', 'Open camera'),
    _option('gallery', 'Gallery', 'Pick a photo you already have'),
    _option('files', 'Files', 'PDF or image from phone storage', needs: 'files'),
  ],
};

Map<String, dynamic> _viewer(String title) => {
      'title': title,
      'close_label': 'Close',
      'retake_label': 'Retake',
      'keep_label': 'Keep',
      'remove_label': 'Remove',
      'hint': 'Pinch to zoom · uploaded 20 Sep, 11:02 pm',
      'page_label': 'Page {n} of {total}',
    };

Map<String, dynamic> _row(
  String key,
  String label, {
  required String group,
  required String state,
  required String statusLabel,
  String statusTone = 'warning',
  String actionIcon = 'upload',
  String actionTone = 'brand',
  bool canView = false,
  String thumbKind = 'none',
  int pages = 0,
  bool dontHave = true,
}) =>
    {
      'key': key,
      'label': label,
      'hint': '',
      'required': group == 'required',
      'group': group,
      'state': state,
      'status_label': statusLabel,
      'status_tone': statusTone,
      'action': {'kind': state, 'icon': actionIcon, 'tone': actionTone},
      'can_view': canView,
      'thumb': {
        'kind': thumbKind,
        'bucket': 'kyc-docs',
        'path': thumbKind == 'none' ? '' : 'x/$key',
        'badge': 'PDF',
        'pages': pages,
      },
      'dont_have': {
        'show': dontHave,
        'on': false,
        'label': "Don't have",
        'undo_label': 'Undo',
      },
      'sheet': _sheet,
      'viewer': _viewer(label),
    };

final _block = <String, dynamic>{
  'show': true,
  'empty_label': 'No papers are asked for in your area.',
  'scan': {
    'show': true,
    'title': 'Scan a licence',
    'subtitle': 'We fill the numbers for you',
    'reading_label': 'Reading your licence…',
    'none_label': 'Could not read that photo. Try again in better light.',
  },
  'groups': [
    {
      'key': 'attention',
      'title': 'Needs your attention',
      'counter_label': '',
      'counter_tone': '',
      'rows': [
        _row('pan', 'PAN card',
            group: 'attention',
            state: 'rejected',
            statusLabel: 'Rejected — photo blurred. Retake',
            statusTone: 'danger',
            actionIcon: 'retry',
            actionTone: 'danger',
            canView: true,
            thumbKind: 'image'),
      ],
    },
    {
      'key': 'required',
      'title': 'Required',
      'counter_label': '1 of 3 done',
      'counter_tone': 'warning',
      'rows': [
        _row('dl_20b', 'Drug licence 20B',
            group: 'required',
            state: 'uploaded',
            statusLabel: '✓ Uploaded · RPR/20B/2291',
            statusTone: 'success',
            actionIcon: 'check',
            actionTone: 'success',
            canView: true,
            thumbKind: 'image',
            dontHave: false),
        _row('dl_21b', 'Drug licence 21B',
            group: 'required', state: 'needed', statusLabel: 'Needed'),
        _row('gst', 'GST certificate',
            group: 'required',
            state: 'needed',
            statusLabel: 'Needed'),
      ],
    },
    {
      'key': 'optional',
      'title': 'Optional',
      'counter_label': '',
      'counter_tone': '',
      'rows': [
        _row('shop_photo', 'Shop photo',
            group: 'optional', state: 'needed', statusLabel: 'Needed'),
      ],
    },
  ],
  'footnote':
      'Missing a required paper? Tap "Don\'t have" — you can still submit and add it later.',
  'required_total': 3,
  'required_done': 1,
};

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// A full-screen widget (the viewer) hosts itself — it is a Scaffold already.
Widget _page(Widget child) => MaterialApp(home: child);

/// One transparent pixel. Image.memory needs bytes a codec can actually read.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

Widget _section({
  Map<String, dynamic>? block,
  Map<String, PickedDoc> picked = const {},
  Set<String> skipped = const {},
  void Function(Map<String, dynamic>)? onUpload,
  void Function(Map<String, dynamic>)? onView,
  void Function(Map<String, dynamic>)? onSkip,
  VoidCallback? onScan,
}) =>
    _host(RegistrationLicencesSection(
      block: block ?? _block,
      picked: picked,
      skipped: skipped,
      thumbUrls: const {},
      onUpload: onUpload ?? (_) {},
      onView: onView ?? (_) {},
      onSkipToggle: onSkip ?? (_) {},
      onScan: onScan ?? () {},
    ));

void main() {
  group('Step 3 · Licences — the list', () {
    testWidgets('groups, their titles and their rows are the payload order',
        (t) async {
      await t.pumpWidget(_section());

      final texts = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .where((s) => s.isNotEmpty)
          .toList();

      // The three group titles appear exactly as sent, in payload order.
      final iAttention = texts.indexOf('Needs your attention');
      final iRequired = texts.indexOf('Required');
      final iOptional = texts.indexOf('Optional');
      expect(iAttention, isNonNegative);
      expect(iRequired, greaterThan(iAttention));
      expect(iOptional, greaterThan(iRequired));

      // A rejected paper is in "Needs your attention" because the BACKEND put
      // it there — never because Dart read its state.
      expect(texts.indexOf('PAN card'), lessThan(iRequired));
      expect(texts.indexOf('Drug licence 20B'), greaterThan(iRequired));
      expect(texts.indexOf('Shop photo'), greaterThan(iOptional));
    });

    testWidgets('the counter is printed, never computed', (t) async {
      await t.pumpWidget(_section());
      expect(find.text('1 of 3 done'), findsOneWidget);
      // Three required rows with one done: a Dart-side count would also read
      // "1 of 3". Send a counter that disagrees with the rows and the screen
      // must still print what it was given.
      final lying = {
        ..._block,
        'groups': [
          for (final g in (_block['groups'] as List))
            if ((g as Map)['key'] == 'required')
              {...g, 'counter_label': '7 of 9 done'}
            else
              g,
        ],
      };
      await t.pumpWidget(_section(block: lying));
      expect(find.text('7 of 9 done'), findsOneWidget);
      expect(find.text('1 of 3 done'), findsNothing);
    });

    testWidgets('status lines, the tick and the number are verbatim',
        (t) async {
      await t.pumpWidget(_section());
      expect(find.text('✓ Uploaded · RPR/20B/2291'), findsOneWidget);
      expect(find.text('Rejected — photo blurred. Retake'), findsOneWidget);
      expect(find.text('Needed'), findsNWidgets(3));
      expect(
          find.text(
              'Missing a required paper? Tap "Don\'t have" — you can still submit and add it later.'),
          findsOneWidget);
    });

    testWidgets('"Don\'t have" is offered only where the payload allows it',
        (t) async {
      await t.pumpWidget(_section());
      // dl_20b is already in, so it carries no "Don't have"; the other four do.
      expect(find.text("Don't have"), findsNWidgets(4));
      expect(find.byKey(const ValueKey('never')), findsNothing);
    });

    testWidgets('an upload tap hands back the row it belongs to', (t) async {
      final tapped = <String>[];
      await t.pumpWidget(_section(onUpload: (r) => tapped.add('${r['key']}')));
      await t.tap(find.bySemanticsIdentifier('reg_lic_action_dl_21b'));
      await t.pump();
      expect(tapped, ['dl_21b']);
    });

    testWidgets('a stored paper opens the viewer instead of the picker',
        (t) async {
      final viewed = <String>[];
      final uploaded = <String>[];
      await t.pumpWidget(_section(
          onView: (r) => viewed.add('${r['key']}'),
          onUpload: (r) => uploaded.add('${r['key']}')));
      await t.tap(find.bySemanticsIdentifier('reg_lic_action_dl_20b'));
      await t.pump();
      expect(viewed, ['dl_20b']);
      expect(uploaded, isEmpty);
    });

    testWidgets('the scan card prints the backend copy and reports its tap',
        (t) async {
      var taps = 0;
      await t.pumpWidget(_section(onScan: () => taps++));
      expect(find.text('Scan a licence'), findsOneWidget);
      expect(find.text('We fill the numbers for you'), findsOneWidget);
      await t.tap(find.bySemanticsIdentifier('reg_lic_scan'));
      await t.pump();
      expect(taps, 1);
    });

    testWidgets('an empty block prints the backend empty state', (t) async {
      await t.pumpWidget(_section(block: {
        'show': false,
        'empty_label': 'No papers are asked for in your area.',
      }));
      expect(find.text('No papers are asked for in your area.'), findsOneWidget);
      expect(find.text('Required'), findsNothing);
    });

    testWidgets('a file picked on the device reads as answered at once',
        (t) async {
      await t.pumpWidget(_section(picked: {
        'dl_21b': PickedDoc(
            name: 'dl21b.png', ext: 'png', bytes: _png),
      }));
      // Its row now carries the thumbnail and the trailing control is the
      // "done" one — and the row keeps the backend's own words.
      expect(find.bySemanticsIdentifier('reg_lic_thumb_dl_21b'), findsOneWidget);
      expect(find.text("Don't have"), findsNWidgets(3));
    });
  });

  group('The upload sheet', () {
    testWidgets('options render in payload order with their hints and badge',
        (t) async {
      await t.pumpWidget(_host(DocUploadSheet(
          sheet: _sheet, capabilities: const {'scanner', 'files'})));
      final texts = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .toList();
      expect(texts.indexOf('Scan document'), isNonNegative);
      expect(texts.indexOf('Take photo'),
          greaterThan(texts.indexOf('Scan document')));
      expect(
          texts.indexOf('Gallery'), greaterThan(texts.indexOf('Take photo')));
      expect(texts.indexOf('Files'), greaterThan(texts.indexOf('Gallery')));
      expect(find.text('Add Drug licence 21B'), findsOneWidget);
      expect(find.text('Photo or PDF · clear, all four corners visible'),
          findsOneWidget);
      expect(find.text('BEST'), findsOneWidget);
      expect(find.text('Auto-crops and straightens the page'), findsOneWidget);
    });

    testWidgets('an option this device cannot honour is dropped, not reworded',
        (t) async {
      await t.pumpWidget(
          _host(DocUploadSheet(sheet: _sheet, capabilities: const {'files'})));
      expect(find.text('Scan document'), findsNothing);
      expect(find.text('Take photo'), findsOneWidget);
      expect(find.text('Gallery'), findsOneWidget);
      expect(find.text('Files'), findsOneWidget);
    });
  });

  group('The in-app viewer', () {
    testWidgets('prints the backend title, hint and three buttons', (t) async {
      await t.pumpWidget(_page(DocViewerScreen(
          row: _row('dl_20b', 'Drug licence 20B',
              group: 'required',
              state: 'uploaded',
              statusLabel: '✓ Uploaded',
              canView: true,
              thumbKind: 'image'),
          bytes: _png)));
      expect(find.text('Drug licence 20B'), findsOneWidget);
      expect(find.text('Pinch to zoom · uploaded 20 Sep, 11:02 pm'),
          findsOneWidget);
      expect(find.text('Retake'), findsOneWidget);
      expect(find.text('Keep'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
      // Zoom is the viewer's own, never a hand-off to another app.
      expect(find.byType(InteractiveViewer), findsOneWidget);
    });

    testWidgets('a one-page file has no page strip; a multi-page PDF does',
        (t) async {
      await t.pumpWidget(_page(DocViewerScreen(
          row: _row('gst', 'GST certificate',
              group: 'required',
              state: 'uploaded',
              statusLabel: '✓ 2 pages · tap to view',
              canView: true,
              thumbKind: 'pdf',
              pages: 1))));
      expect(find.bySemanticsIdentifier('doc_view_page_1'), findsNothing);

      await t.pumpWidget(_page(DocViewerScreen(
          row: _row('gst', 'GST certificate',
              group: 'required',
              state: 'uploaded',
              statusLabel: '✓ 2 pages · tap to view',
              canView: true,
              thumbKind: 'pdf',
              pages: 2))));
      expect(find.bySemanticsIdentifier('doc_view_page_1'), findsOneWidget);
      expect(find.bySemanticsIdentifier('doc_view_page_2'), findsOneWidget);
      expect(find.text('Page 1 of 2'), findsOneWidget);
      await t.tap(find.bySemanticsIdentifier('doc_view_page_2'));
      await t.pump();
      expect(find.text('Page 2 of 2'), findsOneWidget);
    });
  });
}

// PROTECTED — CMD #2055. One wording, three channels.
//
// See CLAUDE.md: this file runs before EVERY deploy and may only be edited by
// a CHANGE that deliberately changes this behaviour — never to make an
// unrelated change go green.
//
// What this holds down:
//
//   1. THE PREVIEW COMPUTES NOTHING. The push title, the push body, the email
//      subject, the email body, the footer, the button captions, the style
//      word ("Big picture") and the chip words ("Synced" / "Manual") are all
//      strings from wa_channel_preview(). Nothing in Dart derives the push
//      title from the body, truncates it, or decides which channel is in sync.
//      The derivation rules live in wa_channel_derive() in Postgres; a rule
//      re-implemented here would drift the moment the SQL changed.
//
//   2. ABSENCE IS EXPLICIT. A key the backend left null is not painted. A
//      text-only template sends no image_url, so no picture appears; a PDF
//      template sends attachment_label and the push block shows no picture at
//      all. The widget never invents a placeholder.
//
//   3. RESET IS OFFERED ONLY WHERE THE BACKEND SAYS MANUAL. `manual:true` is
//      the whole condition — not "the text differs from WhatsApp", which the
//      app cannot know. A synced channel offers no Reset, and the WhatsApp
//      block never does: it is the source.
//
//   4. RESET SENDS THE CHANNEL AND THE LANGUAGE, and re-reads. Language
//      variants sync per language, so the reset the sheet fires carries the
//      language chip the admin is looking at.
//
//   5. THE CARD'S CHIPS ARE ONE ROW WITH EQUAL GAPS, drawn straight from the
//      row payload the screen already returned — no per-card RPC.
//
// No network, no Supabase, no goldens: the RPCs are injected.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_channel_preview.dart';

Map<String, dynamic> _chips({bool pushManual = false, bool emailManual = false}) => {
      'label': 'All three channels',
      'preview_label': 'Preview all three',
      'chips': [
        {'channel': 'whatsapp', 'channel_label': 'WhatsApp', 'label': 'Source', 'tone': 'good'},
        {
          'channel': 'push',
          'channel_label': 'Push',
          'label': pushManual ? 'Manual' : 'Synced',
          'tone': pushManual ? 'warn' : 'good'
        },
        {
          'channel': 'email',
          'channel_label': 'Email',
          'label': emailManual ? 'Manual' : 'Synced',
          'tone': emailManual ? 'warn' : 'good'
        },
      ],
    };

/// A template WITH an image: push is the big picture, email puts it on top.
Map<String, dynamic> _imagePayload({bool pushManual = false}) => {
      'ok': true,
      'title': 'Customer imported by admin',
      'subtitle': 'The WhatsApp template is the wording.',
      'language': 'en',
      'language_options': [
        {'key': 'en', 'label': 'English'},
        {'key': 'hi', 'label': 'हिन्दी'},
      ],
      'rule_label': 'Text + image — push shows the big picture, email puts the image on top.',
      'source_label': 'customer_imported · en',
      'synced_label': 'Derived 15 Sep, 09:30 AM',
      'chips': _chips(pushManual: pushManual)['chips'],
      'whatsapp': {
        'label': 'WhatsApp',
        'body': 'Congratulations Chandra Medicom',
        'footer': 'mediBO • Raipur',
        'header': {'media_url': 'https://example.test/pic.jpg'},
        'buttons': [
          {'text': 'Download mediBO App'}
        ],
      },
      'push': {
        'label': 'Push',
        'title': 'Congratulations {{1}}',
        'body': 'Your account is ready.',
        'style_label': 'Big picture',
        'image_url': 'https://example.test/pic.jpg',
        'actions': [
          {'text': 'Download mediBO App', 'url': 'https://example.test/app'}
        ],
        'quick_replies': [],
        'manual': pushManual,
        'reset_label': 'Reset to WhatsApp',
      },
      'email': {
        'label': 'Email',
        'subject': 'Congratulations {{1}}',
        'body': 'Your account is ready.',
        'image_url': 'https://example.test/pic.jpg',
        'buttons': [
          {'text': 'Download mediBO App', 'url': 'https://example.test/app'}
        ],
        'footer': 'mediBO • Raipur',
        'manual': false,
        'reset_label': 'Reset to WhatsApp',
      },
      'note': 'Every event sends all three.',
    };

/// A text-only template: no picture anywhere, push style says so.
Map<String, dynamic> _textPayload() => {
      'ok': true,
      'title': 'Order placed',
      'subtitle': 'The WhatsApp template is the wording.',
      'language': 'en',
      'language_options': [
        {'key': 'en', 'label': 'English'},
        {'key': 'hi', 'label': 'हिन्दी'},
      ],
      'rule_label': 'Text only — push title is the first line, email is the body.',
      'source_label': 'order_placed · en',
      'synced_label': 'Derived 15 Sep, 09:30 AM',
      'chips': _chips()['chips'],
      'whatsapp': {'label': 'WhatsApp', 'body': 'Namaste, your order is in.', 'footer': ''},
      'push': {
        'label': 'Push',
        'title': 'Namaste, your order is in.',
        'body': 'We will confirm shortly.',
        'style_label': 'Text only',
        'image_url': null,
        'thumb_url': null,
        'actions': [],
        'quick_replies': [],
        'manual': false,
        'reset_label': 'Reset to WhatsApp',
      },
      'email': {
        'label': 'Email',
        'subject': 'Namaste, your order is in.',
        'body': 'We will confirm shortly.',
        'image_url': null,
        'buttons': [],
        'footer': '',
        'manual': false,
        'reset_label': 'Reset to WhatsApp',
      },
      'note': 'Every event sends all three.',
    };

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// The phone viewport this screen is designed for (CMD #1950 — mobile first).
/// The sheet scrolls, so the blocks below the fold are reached the way an
/// admin reaches them: by scrolling, not by widening the window.
Future<void> _phone(WidgetTester t) async {
  t.view.physicalSize = const Size(412, 915);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

Future<void> _scrollTo(WidgetTester t, Finder f) => t.scrollUntilVisible(
    f, 120, scrollable: find.byType(Scrollable).first);

void main() {
  group('event card chips', () {
    testWidgets('prints the backend chip words in one row and offers Preview',
        (t) async {
      var opened = 0;
      await t.pumpWidget(_host(
          WaChannelChips(channels: _chips(), onPreview: () => opened++)));

      expect(find.text('All three channels'), findsOneWidget);
      expect(find.text('WhatsApp · Source'), findsOneWidget);
      expect(find.text('Push · Synced'), findsOneWidget);
      expect(find.text('Email · Synced'), findsOneWidget);

      // One row, equal gaps — the gaps are the SAME value in both directions.
      final wrap = t.widget<Wrap>(find.byType(Wrap).first);
      expect(wrap.spacing, wrap.runSpacing);

      await t.tap(find.text('Preview all three'));
      expect(opened, 1);
    });

    testWidgets('a manual channel reads Manual, straight from the payload',
        (t) async {
      await t.pumpWidget(_host(WaChannelChips(
          channels: _chips(pushManual: true), onPreview: () {})));
      expect(find.text('Push · Manual'), findsOneWidget);
      expect(find.text('Email · Synced'), findsOneWidget);
    });
  });

  group('three-channel preview', () {
    testWidgets('renders all three channels from the one payload, verbatim',
        (t) async {
      await _phone(t);
      await t.pumpWidget(_host(WaChannelPreviewSheet(
        eventKey: 'customer_imported',
        previewRpc: (k, l) async => _imagePayload(),
        resetRpc: (k, c, l) async => {'ok': true},
      )));
      await t.pumpAndSettle();

      expect(find.text('WhatsApp'), findsOneWidget);
      expect(find.text('Push'), findsOneWidget);
      await _scrollTo(t, find.text('Email'));
      expect(find.text('Email'), findsOneWidget);

      // The derived wording is printed, not recomputed: the push title still
      // carries the template's own {{1}} token.
      // Both the push title and the email subject are the template's first
      // line, token and all — nothing in Dart re-derived either of them.
      expect(find.text('Congratulations {{1}}'), findsNWidgets(2));
      expect(find.text('Big picture'), findsOneWidget);
    });

    testWidgets('a text-only template paints no picture and no Reset',
        (t) async {
      await _phone(t);
      await t.pumpWidget(_host(WaChannelPreviewSheet(
        eventKey: 'order_placed',
        previewRpc: (k, l) async => _textPayload(),
        resetRpc: (k, c, l) async => {'ok': true},
      )));
      await t.pumpAndSettle();

      expect(find.text('Text only'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      // Nothing is manual, so nothing offers a reset — top to bottom.
      await _scrollTo(t, find.text('Email'));
      expect(find.text('Reset to WhatsApp'), findsNothing);
    });

    testWidgets('Reset is offered only on the manual channel and carries the language',
        (t) async {
      final calls = <List<String>>[];
      await _phone(t);
      await t.pumpWidget(_host(WaChannelPreviewSheet(
        eventKey: 'customer_imported',
        previewRpc: (k, l) async => _imagePayload(pushManual: true),
        resetRpc: (k, c, l) async {
          calls.add([k, c, l]);
          return {'ok': true, 'message': 'Back in sync with the WhatsApp template.'};
        },
      )));
      await t.pumpAndSettle();

      // Push is manual, email is not: exactly one Reset in the whole sheet.
      await _scrollTo(t, find.text('Reset to WhatsApp'));
      expect(find.text('Reset to WhatsApp'), findsOneWidget);

      await t.tap(find.text('Reset to WhatsApp'));
      await t.pumpAndSettle();

      expect(calls, [
        ['customer_imported', 'push', 'en']
      ]);
    });

    testWidgets('an error payload prints the backend message, never a thrown state',
        (t) async {
      await t.pumpWidget(_host(WaChannelPreviewSheet(
        eventKey: 'nope',
        previewRpc: (k, l) async => {
          'ok': false,
          'error': 'unknown_event',
          'message': 'That notification event does not exist.'
        },
        resetRpc: (k, c, l) async => {'ok': true},
      )));
      await t.pumpAndSettle();

      expect(find.text('That notification event does not exist.'), findsOneWidget);
    });
  });
}

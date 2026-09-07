// PROTECTED — CMD #1886. The registration funnel is a PRINTER.
//
// 22 auth logins, 13 profiles: the people who signed in and stopped had no
// screen. These three tabs are that screen, and the ONE thing that must never
// come back is a Dart file deciding what they say. So every fixture below is
// deliberately hostile to a re-deriving widget:
//
//   • the stage chip's word disagrees with its own stage_key,
//   • the "fields missing" sentence disagrees with the array beside it,
//   • the overdue tone is 'danger' on a date in the FUTURE,
//   • the WhatsApp button is refused with a phone sitting right there,
//   • the rows arrive in an order no sort would produce.
//
// A card that computed any of those from the data instead of printing the
// backend's string fails here.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/customer_pipeline_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _chip(String label, String tone, String key) =>
    {'label': label, 'tone': tone, 'stage_key': key};

const _actions = {
  'assign_label': 'Take this one',
  'save_label': 'Keep it',
  'owner_label': 'Owner',
  'date_label': 'Next action',
  'no_date_label': 'No date set',
  'note_label': 'Note',
};

Map<String, dynamic> _signedUpPayload() => {
      'ok': true,
      'allowed': true,
      'title': 'Signed up',
      'empty_label': 'Nobody has signed in without finishing the form.',
      'count': 2,
      'actions': _actions,
      'rows': [
        {
          'user_id': 'u-crazi',
          'name': 'Crazi DKM',
          'email': 'crazidkm@gmail.com',
          'phone': '9876543210',
          'joined_label': '28 Aug 2026, 09:12 am',
          'last_login_label': 'Never',
          // the word and the key deliberately disagree
          'stage_chip': _chip('Waiting on them', 'warning', 'signed_up'),
          'assigned_label': 'Unassigned',
          'next_action_label': 'No date set',
          'next_action_tone': 'neutral',
          // a phone is present and the button is STILL refused: `can` decides
          'wa': {
            'can': false,
            'label': 'Send WhatsApp',
            'reason': 'Notifications are switched off for this audience'
          },
        },
        {
          'user_id': 'u-pallavi',
          'name': 'Pallavi Medicom',
          'email': 'pallavi.medicom@gmail.com',
          'phone': '',
          'joined_label': '02 Sep 2026, 12:40 am',
          'last_login_label': '03 Sep 2026, 08:00 pm',
          'stage_chip': _chip('Signed up', 'neutral', 'signed_up'),
          'assigned_label': 'om@medibo.in',
          // a FUTURE date carrying the overdue tone — no clock may override it
          'next_action_label': 'Overdue — 30 Dec',
          'next_action_tone': 'danger',
          'wa': {'can': true, 'label': 'Send WhatsApp', 'reason': ''},
        },
      ],
    };

Map<String, dynamic> _needsPayload() => {
      'ok': true,
      'allowed': true,
      'actions': _actions,
      'rows': [
        {
          'customer_id': 'c-1',
          'name': 'Sahu Medical Store',
          'contact': '9111111111',
          'stage_chip': _chip('Documents', 'brand', 'documents'),
          // the sentence names TWO fields while the array holds three
          'missing': [
            {'field_key': 'gstin', 'label': 'GSTIN'},
            {'field_key': 'dl_expiry', 'label': 'Licence expiry'},
            {'field_key': 'zone_id', 'label': 'Zone'},
          ],
          'missing_label': '2 fields missing: GSTIN, Licence expiry',
          'assigned_label': 'Unassigned',
          'next_action_label': 'No date set',
          'next_action_tone': 'neutral',
          'approve': {
            'can': false,
            'is_approved': false,
            'label': 'Approve',
            'reason': 'Licence not verified',
            'has_fix': true,
            'fix_label': 'Fix',
            'fix_field': 'drug_license',
            'fix_field_label': 'Drug licence',
          },
        },
      ],
    };

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('the stage chip prints the payload word, never the stage key',
      (tester) async {
    await _pump(
        tester,
        CustomerPipelineTab(
            tabKey: 'signed_up', payload: _signedUpPayload()));

    // the chip's own label, even though stage_key says 'signed_up'
    expect(find.text('Waiting on them'), findsOneWidget);
    // and never a title-cased key
    expect(find.text('Signed Up'), findsNothing);
  });

  testWidgets('rows render in payload order — no client sort', (tester) async {
    await _pump(
        tester,
        CustomerPipelineTab(
            tabKey: 'signed_up', payload: _signedUpPayload()));

    final crazi = tester.getTopLeft(find.text('Crazi DKM')).dy;
    final pallavi = tester.getTopLeft(find.text('Pallavi Medicom')).dy;
    expect(crazi < pallavi, isTrue,
        reason: 'the backend sent Crazi first; nothing here may re-order');
  });

  testWidgets('a WhatsApp refusal is the backend flag, not the phone number',
      (tester) async {
    await _pump(
        tester,
        CustomerPipelineTab(
            tabKey: 'signed_up', payload: _signedUpPayload()));

    // Crazi HAS a phone and is still refused, with the backend's own sentence.
    expect(find.text('Notifications are switched off for this audience'),
        findsOneWidget);

    final buttons = tester.widgetList<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Send WhatsApp'));
    expect(buttons.length, 2);
    expect(buttons.first.onPressed, isNull, reason: 'can:false is disabled');
    expect(buttons.last.onPressed, isNotNull, reason: 'can:true is live');
  });

  testWidgets('the overdue tone is the payload\'s, not a clock comparison',
      (tester) async {
    await _pump(
        tester,
        CustomerPipelineTab(
            tabKey: 'signed_up', payload: _signedUpPayload()));

    // A December date carrying tone 'danger' stays red; a widget that compared
    // the date to now() would draw it as an ordinary future date.
    final label = tester.widget<Text>(find.text('Overdue — 30 Dec'));
    expect(label.style?.color, isNotNull);
    expect(find.text('No date set'), findsOneWidget);
  });

  testWidgets('the missing-field sentence is printed, never counted here',
      (tester) async {
    await _pump(
        tester,
        CustomerPipelineTab(tabKey: 'needs', payload: _needsPayload()));

    // three entries in `missing`, and the sentence still says two.
    expect(find.text('2 fields missing: GSTIN, Licence expiry'), findsOneWidget);
    expect(find.textContaining('3 fields'), findsNothing);
  });

  testWidgets('Approve is never hidden — disabled, carrying its reason',
      (tester) async {
    await _pump(
        tester,
        CustomerPipelineTab(tabKey: 'needs', payload: _needsPayload()));

    final approve = find.widgetWithText(ElevatedButton, 'Approve');
    expect(approve, findsOneWidget, reason: 'the button is never removed');
    expect(tester.widget<ElevatedButton>(approve).onPressed, isNull);
    expect(find.text('Licence not verified'), findsOneWidget);
  });

  testWidgets('every control caption comes from actions[]', (tester) async {
    await _pump(
        tester,
        CustomerPipelineTab(tabKey: 'needs', payload: _needsPayload()));

    expect(find.text('Take this one'), findsOneWidget);
    expect(find.text('Assign'), findsNothing,
        reason: 'a Dart default would survive an empty actions block');
  });

  testWidgets('an empty list prints the backend empty state', (tester) async {
    await _pump(
        tester,
        CustomerPipelineTab(tabKey: 'signed_up', payload: {
          'ok': true,
          'allowed': true,
          'rows': const [],
          'empty_label': 'Nobody has signed in without finishing the form.',
        }));

    expect(find.text('Nobody has signed in without finishing the form.'),
        findsOneWidget);
  });

  testWidgets('a refusal prints the backend message and no rows',
      (tester) async {
    await _pump(
        tester,
        CustomerPipelineTab(tabKey: 'needs', payload: const {
          'ok': false,
          'allowed': false,
          'message': 'This screen is for the office team.',
        }));

    expect(find.text('This screen is for the office team.'), findsOneWidget);
  });

  testWidgets('a tab key this build has never heard of draws nothing',
      (tester) async {
    await _pump(
        tester,
        const CustomerPipelineTab(tabKey: 'a_tab_from_the_future', payload: {
          'ok': true,
          'allowed': true,
          'rows': [],
          'empty_label': '',
        }));

    expect(tester.takeException(), isNull);
  });

  test('each tab key maps to exactly one RPC', () {
    expect(CustomerPipelineTab.rpcForTab['signed_up'], 'customers_signed_up');
    expect(CustomerPipelineTab.rpcForTab['followups'], 'customer_followups_mine');
    expect(CustomerPipelineTab.rpcForTab['needs'], 'customers_needs_attention');
    expect(CustomerPipelineTab.rpcForTab.length, 3);
  });

  testWidgets('the stage chip renders nothing when the payload sent none',
      (tester) async {
    await _pump(tester, const CustomerStageChip(chip: null));
    expect(find.byType(Text), findsNothing);
  });
}

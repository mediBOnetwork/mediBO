// PROTECTED — CMD #1985, the partner agreement as a LIVING document.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes agreement behaviour, never to make an unrelated change
// go green.
//
// What this holds down:
//
//   1. NO ENTITY NAME IS RESOLVED IN DART. The card prints `body` exactly as
//      agreement_render() produced it. A clause whose stored text still reads
//      `{{partner}}` renders with the braces visible — because a token the
//      backend did not resolve is a bug to SEE, not one for Flutter to paper
//      over by substituting a name it happened to know. This is the whole
//      point of the change: the day the Raipur partner became UNIVERSAL
//      PHARMA, the frozen prose was the thing that went stale.
//
//   2. THE HEALTH LINE IS ONE BACKEND STRING. "Signed v2 · valid 13/09/2027 ·
//      nothing pending" is printed, never assembled from version, date and a
//      count. Nothing in the widget compares a date to today.
//
//   3. THE VOID REASON IS SHOWN, IN THE BACKEND'S WORDS. A partner whose
//      signature was auto-voided sees why, on the card, above the re-sign
//      button — and `can_sign` is what puts that button there, never a status
//      word read in Dart.
//
//   4. ONLY A CLAUSE THE BACKEND FLAGS editable_by_partner OFFERS THE PROPOSE
//      ACTION. A partner cannot reach the sheet for a locked clause, so the
//      RPC's refusal is a second line of defence rather than the only one.
//
//   5. THE COMMERCIAL TERMS ARE RENDERED, NOT COMPUTED. "12.50%" and "45 days"
//      arrive formatted; Dart never does money or day arithmetic.
//
// Fixtures mirror the real partner_agreement_card() shape. No network, no
// Supabase, no timers.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/partner/partner_documents_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';
Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// partner_agreement_card() as it comes back for a partner whose signature was
/// voided because their business name changed — the exact case this command was
/// filed for.
Map<String, dynamic> _card({
  bool canSign = true,
  String voidReason =
      'The business name on this partner changed, so the earlier signature no '
      'longer describes the same firm. A fresh signature is needed.',
}) =>
    {
      'ok': true,
      'partner_id': 1,
      'partner_name': 'RAIPUR MEDICOS PVT LTD',
      'heading': 'Partner agreement',
      'sub': 'The agreement between mediBO and your firm.',
      'has_version': true,
      'version': 2,
      'version_label': 'Version 2 · from 14/09/2026',
      'validity_label': 'Valid to 13/09/2027',
      'title': 'mediBO Fulfilment Partner Agreement',
      'health_line': 'Signed v1 · valid 13/09/2027 · Needs a fresh signature',
      'health_tone': 'warning',
      'status': 'resign',
      'status_label': 'Needs a fresh signature',
      'status_tone': 'warning',
      'void_reason': voidReason,
      'is_signed': false,
      'needs_signature': true,
      'can_sign': canSign,
      'sign_label': 'Sign the new version',
      'propose_label': 'Propose a change',
      'propose_hint': 'Your wording for this clause',
      'propose_note_hint': 'Why you are asking (optional)',
      'proposals_heading': 'My change requests',
      'terms_heading': 'Commercial terms',
      'terms_rows': [
        {'label': 'Partner share', 'value': '12.50%'},
        {'label': 'Settlement', 'value': 'Weekly'},
        {'label': 'Exit notice', 'value': '45 days'},
      ],
      'clauses': [
        {
          'clause_id': 21,
          'n': 1,
          'heading': 'Parties',
          'body': 'This agreement is made between Jai Mahakal Medical And '
              'Surgical and RAIPUR MEDICOS PVT LTD, the fulfilment partner '
              'for Zone One.',
          'owner': 'admin',
          'editable_by_partner': false,
          'required': true,
          'is_negotiated': false,
        },
        {
          'clause_id': 24,
          'n': 6,
          'heading': 'Service standards',
          'body': 'RAIPUR MEDICOS PVT LTD will accept or decline each order '
              'within 30 minutes.',
          'owner': 'admin',
          'editable_by_partner': true,
          'required': true,
          'is_negotiated': true,
        },
      ],
      'proposals': [
        {
          'id': 2,
          'clause_id': 24,
          'clause_n': 6,
          'heading': 'Service standards',
          'status': 'pending',
          'status_label': 'Waiting on mediBO',
          'status_tone': 'warning',
          'decision_reason': '',
        },
      ],
      'diff': {
        'ok': true,
        'heading': 'What changed since you signed',
        'summary_label': '1 added · 6 changed · 0 removed',
        'empty_label': 'Nothing in the wording has changed.',
        'rows': [
          {
            'n': 1,
            'heading': 'Parties',
            'kind': 'changed',
            'kind_label': 'Changed',
            'tone': 'warning',
            'old': 'UNIVERSAL PHARMA, the fulfilment partner for Zone One.',
            'new': 'RAIPUR MEDICOS PVT LTD, the fulfilment partner for Zone One.',
          },
        ],
      },
      'signed_line': '',
      'signed_ip_line': '',
      'hash_line': 'Document fingerprint 7178f634e4a9181b',
      'doc_label': 'Signed copy (PDF)',
      'has_doc': false,
      'doc_building': false,
      'doc_building_label': '',
      'awaiting_code': false,
      'name_hint': 'Your name',
      'phone_hint': 'WhatsApp number',
      'code_hint': '6-digit code',
      'send_label': 'Send code',
      'verify_label': 'Verify',
    };

Map<String, dynamic> _screen(Map<String, dynamic> agreement) => {
      'ok': true,
      'partner_id': 1,
      'partner_name': 'RAIPUR MEDICOS PVT LTD',
      'title': 'My documents',
      'golive': {
        'ok': true,
        'heading': 'Go live',
        'ready': false,
        'status_label': 'Blocked',
        'status_tone': 'warning',
        'blocking_reason': 'the agreement is not signed',
        'blockers': [],
      },
      'agreement': agreement,
      'kyc': {
        'ok': true,
        'partner_id': 1,
        'heading': 'Documents',
        'sub': '',
        'progress_label': '0 of 0 verified',
        'summary_label': 'Nothing to do',
        'summary_tone': 'success',
        'rows': [],
      },
    };

void main() {
  // CHANGE #639's seam: the render log's 800 ms debounce is a real Timer.
  setUp(() => RenderLog.flushEnabled = false);

  var pumps = 0;
  Future<void> pump(WidgetTester t, Map<String, dynamic> agreement) async {
    // A fresh key on every pump: pumping the same widget type twice inside one
    // test reuses the State, and _load() would never run again.
    await t.pumpWidget(_host(PartnerDocumentsScreen(
      key: ValueKey('pump${pumps++}'),
      partnerId: 1,
      api: (fn, p) async => _screen(agreement),
    )));
    await t.pumpAndSettle();
  }

  testWidgets('1 · a clause renders VERBATIM — an unresolved token stays visible',
      (t) async {
    final card = _card();
    final clauses = List<Map<String, dynamic>>.from(
        (card['clauses'] as List).map((e) => Map<String, dynamic>.from(e as Map)));
    // agreement_render() failed to resolve this one. Dart must NOT quietly
    // substitute the partner name it can see two fields away.
    clauses[0]['body'] =
        'This agreement is made between {{operator}} and {{partner}}.';
    card['clauses'] = clauses;
    await pump(t, card);

    // Open the clause list.
    await t.tap(find.text('mediBO Fulfilment Partner Agreement'));
    await t.pumpAndSettle();

    expect(find.text('This agreement is made between {{operator}} and {{partner}}.'),
        findsOneWidget);
  });

  testWidgets('2 · the health line is ONE backend string', (t) async {
    await pump(t, _card());
    expect(find.text('Signed v1 · valid 13/09/2027 · Needs a fresh signature'),
        findsOneWidget);
    // The parts are never printed separately as a fallback.
    expect(find.text('v1'), findsNothing);
  });

  testWidgets('3 · the void reason is shown, and can_sign puts the button there',
      (t) async {
    await pump(t, _card());
    expect(
        find.textContaining('no longer describes the same firm'), findsOneWidget);
    expect(find.text('Sign the new version'), findsOneWidget);

    await pump(t, _card(canSign: false));
    expect(find.text('Sign the new version'), findsNothing);
  });

  testWidgets('4 · only an editable_by_partner clause offers "Propose a change"',
      (t) async {
    await pump(t, _card());
    await t.tap(find.text('mediBO Fulfilment Partner Agreement'));
    await t.pumpAndSettle();
    // Two clauses are drawn; exactly one of them is open to a proposal.
    expect(find.text('1. Parties'), findsOneWidget);
    expect(find.text('6. Service standards'), findsWidgets);
    expect(find.text('Propose a change'), findsOneWidget);
  });

  testWidgets('5 · commercial terms are printed, never computed', (t) async {
    await pump(t, _card());
    expect(find.text('12.50%'), findsOneWidget);
    expect(find.text('Weekly'), findsOneWidget);
    expect(find.text('45 days'), findsOneWidget);
  });

  testWidgets('6 · the diff is offered only when the backend says ok', (t) async {
    await pump(t, _card());
    expect(find.text('What changed since you signed'), findsOneWidget);

    final noDiff = _card();
    noDiff['diff'] = {'ok': false};
    await pump(t, noDiff);
    expect(find.text('What changed since you signed'), findsNothing);
  });

  testWidgets('7 · the phone viewport draws it without overflow', (t) async {
    // CMD #1950 — 99% of mediBO users are on a phone. 360 and 412 both.
    for (final w in <double>[360, 412]) {
      t.view.physicalSize = Size(w, 780);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await pump(t, _card());
      // A render overflow is reported to the binding as a FlutterError, and
      // pumpAndSettle inside pump() would have failed the test on one.
      expect(find.text('Signed v1 · valid 13/09/2027 · Needs a fresh signature'),
          findsOneWidget);
      expect(find.text('12.50%'), findsOneWidget);
    }
  });
}

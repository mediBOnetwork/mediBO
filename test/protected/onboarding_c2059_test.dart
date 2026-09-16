// PROTECTED — CMD #2059.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes customer onboarding.
//
// What this holds down:
//
//   1. NO FORCED REDIRECT. Whether signing up opens the registration form is
//      the BACKEND's answer: landingPlan pushes exactly what `signup_route`
//      names, and an empty signup_route (the default after #2059) means the
//      user lands on Home with nothing pushed over it. A Dart-side rule about
//      needs_profile would put the decision back in the app.
//
//   2. THE ORDER GATE SAYS HOW IT IS ANSWERED. `action_kind` is carried
//      verbatim off my_session().order_gate; 'registration_sheet' is what the
//      cart reads, and it is never inferred from the reason string.
//
//   3. THE FORM IS ALREADY IN THE APP'S HANDS. The registration block that
//      rides on the home payload seeds the form: fields come from the payload
//      schema, the login identity prefills them, and a saved DRAFT outranks
//      that prefill. Nothing about the field list is written in Dart.
//
//   4. AUTOSAVE SENDS ONLY WHAT CHANGED, as a backend draft write.
//
//   5. AN EMPTY CACHE SHOWS A FIELD SKELETON, never a lone spinner.
//
//   6a. THE HELD PAYLOAD BELONGS TO ONE ACCOUNT (CMD #2063). The surface
//      carries the signed-in customer's name, email, phone and half-typed shop
//      address, and the form paints from it BEFORE any refresh can land — so a
//      slot keyed by role alone handed the previous customer's identity to the
//      next person to sign in on the same phone. identify() is the only door:
//      a different auth user drops the held payload on the spot, and signing
//      out forgets the device copy WITHOUT deleting the account's backend
//      draft (that draft is what "reopening resumes" means).
//
//   6. THE STEP STRIP IS THE PAYLOAD. "Step 1 of 2", each step's name, its
//      state word and the progress sentence are printed verbatim, in payload
//      order, and BOTH steps are reachable — the documents step is never
//      hidden behind the details form.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/app_session.dart';
import 'package:pharma_b2b/screens/auth/login_view.dart';
import 'package:pharma_b2b/services/registration_payload.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/customer_registration_form.dart';
import 'package:pharma_b2b/widgets/customer_surface_widgets.dart';

// ── fixtures — the shape customer_registration_payload() returns ────────────

Map<String, dynamic> _schema() => {
      'sections': [
        {
          'key': 'business',
          'title': 'Your pharmacy',
          'fields': [
            {'key': 'pharmacy_name', 'label': 'Pharmacy name', 'type': 'text'},
            {'key': 'customer_name', 'label': 'Owner name', 'type': 'text'},
            {'key': 'whatsapp_no', 'label': 'WhatsApp number', 'type': 'phone'},
            {'key': 'email', 'label': 'Email', 'type': 'email'},
          ],
        },
      ],
      'fields': [
        {'key': 'pharmacy_name', 'label': 'Pharmacy name', 'type': 'text'},
        {'key': 'customer_name', 'label': 'Owner name', 'type': 'text'},
        {'key': 'whatsapp_no', 'label': 'WhatsApp number', 'type': 'phone'},
        {'key': 'email', 'label': 'Email', 'type': 'email'},
      ],
      'required_fields': ['pharmacy_name', 'whatsapp_no'],
    };

Map<String, dynamic> _surface({
  Map<String, dynamic>? draft,
  bool needs = true,
}) =>
    {
      'signed_in': true,
      'needs': needs,
      'stage': 'details',
      'route': '/complete-registration',
      'step': {
        'n': 1,
        'total': 2,
        'label': 'Step 1 of 2',
        'done': 0,
        'ratio': 0.0,
        'progress_label': '0 of 2 steps done',
      },
      'steps': [
        {
          'n': 1,
          'key': 'details',
          'label': 'Business details',
          'step_label': 'Step 1 of 2',
          'route': '/complete-registration',
          'done': false,
          'state': 'current',
          'state_label': 'Now',
        },
        {
          'n': 2,
          'key': 'documents',
          'label': 'Documents',
          'step_label': 'Step 2 of 2',
          'route': '/customer/documents',
          'done': false,
          'state': 'todo',
          'state_label': 'Next',
        },
      ],
      'schema': _schema(),
      'prefill': {
        'customer_name': 'Om Prakash Sahu',
        'email': 'om@example.com',
        'whatsapp_no': '9812345678',
      },
      'draft': draft ?? const <String, dynamic>{},
      'autosave': {
        'enabled': true,
        'debounce_ms': 800,
        'saving_label': 'Saving…',
        'saved_label': 'Saved',
      },
      'sheet': {
        'title': 'Register to place your order',
        'line': 'Your cart is saved.',
        'close_label': 'Not now',
        'done_message': 'Details saved — back to your cart.',
      },
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  setUp(() {
    RegistrationSurface.resetForTest();
    RegistrationSurface.rpcTransport = null;
  });

  tearDown(() => RegistrationSurface.rpcTransport = null);

  // ── 1. No forced redirect ────────────────────────────────────────────────
  group('the backend decides whether the form opens itself', () {
    test('an empty signup_route lands on Home and pushes NOTHING', () {
      final plan = landingPlan({
        'signed_in': true,
        'needs_profile': true,
        'home_route': '/store',
        'signup_route': '',
        'signup_form_route': '/complete-registration',
      });
      expect(plan.home, '/store');
      expect(plan.overlay, '',
          reason: 'needs_profile must NOT open the form by itself');
    });

    test('a signup_route the backend DOES name is still pushed over Home', () {
      final plan = landingPlan({
        'signed_in': true,
        'home_route': '/store',
        'signup_route': '/complete-registration',
      });
      expect(plan.home, '/store');
      expect(plan.overlay, '/complete-registration');
    });
  });

  // ── 2. The order gate names its own answer ───────────────────────────────
  group('order_gate.action_kind', () {
    test('is carried verbatim, never inferred from the reason', () {
      final gate = OrderGate.fromJson({
        'has_blocker': true,
        'reason': 'not_registered',
        'title': 'Finish registering',
        'message': 'Add your pharmacy details.',
        'action_kind': 'registration_sheet',
      });
      expect(gate.actionKind, 'registration_sheet');
      expect(gate.reason, 'not_registered');
    });

    test('is empty when the backend did not send one', () {
      final gate = OrderGate.fromJson({
        'has_blocker': true,
        'reason': 'suspended',
      });
      expect(gate.actionKind, '');
    });
  });

  // ── 3/4. The surface seeds the form; the draft outranks the prefill ──────
  // ── CMD #2063 — one account's payload never opens another's form ────────
  group('the held payload is addressed to ONE account', () {
    test('a different auth user drops what is held, in memory', () {
      RegistrationSurface.identify(authUserId: 'user-a', role: 'customer');
      RegistrationSurface.seed(_surface(draft: {'pharmacy_name': 'A Medical'}));
      expect(RegistrationSurface.hasForm, isTrue);

      RegistrationSurface.identify(authUserId: 'user-b', role: 'customer');
      expect(RegistrationSurface.hasForm, isFalse,
          reason: "customer B must not open customer A's form");
      expect(RegistrationSurface.draft, isEmpty);
      expect(RegistrationSurface.prefill, isEmpty);

      final ctrl = CustomerFormController(formContext: 'signup');
      addTearDown(ctrl.dispose);
      expect(ctrl.seedFromSurface(), isFalse,
          reason: 'nothing is held, so the screen falls back to load()');
    });

    test('the SAME auth user keeps what is held', () {
      RegistrationSurface.identify(authUserId: 'user-a', role: 'customer');
      RegistrationSurface.seed(_surface(draft: {'pharmacy_name': 'A Medical'}));
      RegistrationSurface.identify(authUserId: 'user-a', role: 'customer');
      expect(RegistrationSurface.hasForm, isTrue);
      expect(RegistrationSurface.draft['pharmacy_name'], 'A Medical');
    });

    test('a role change on the same account also drops it', () {
      RegistrationSurface.identify(authUserId: 'user-a', role: 'customer');
      RegistrationSurface.seed(_surface());
      RegistrationSurface.identify(authUserId: 'user-a', role: 'admin');
      expect(RegistrationSurface.hasForm, isFalse);
    });

    test('signing out forgets the DEVICE copy and never deletes the draft',
        () async {
      final calls = <String>[];
      RegistrationSurface.rpcTransport = (fn, params) async {
        calls.add(fn);
        return {'ok': true};
      };
      RegistrationSurface.identify(authUserId: 'user-a', role: 'customer');
      RegistrationSurface.seed(_surface(draft: {'pharmacy_name': 'A Medical'}));

      await RegistrationSurface.clear();

      expect(RegistrationSurface.hasForm, isFalse);
      expect(calls, isEmpty,
          reason:
              'customer_reg_draft_clear on sign-out would break "reopening '
              'resumes, even after restart" — the draft is cleared on SUBMIT');
    });

    test('submitting IS where the backend draft is cleared', () async {
      final calls = <String>[];
      RegistrationSurface.rpcTransport = (fn, params) async {
        calls.add(fn);
        return <String, dynamic>{};
      };
      RegistrationSurface.identify(authUserId: 'user-a', role: 'customer');
      RegistrationSurface.seed(_surface(draft: {'pharmacy_name': 'A Medical'}));

      await RegistrationSurface.submitted();

      expect(calls, contains('customer_reg_draft_clear'));
      expect(RegistrationSurface.draft, isEmpty);
    });
  });

  group('the form the home feed delivered', () {
    test('adopt() keeps the block; a payload without one changes nothing', () {
      RegistrationSurface.adopt(_surface());
      expect(RegistrationSurface.hasForm, isTrue);
      expect(RegistrationSurface.needs, isTrue);
      RegistrationSurface.adopt(null);
      expect(RegistrationSurface.hasForm, isTrue,
          reason: 'an anonymous feed must not wipe a held surface');
    });

    test('seedFromSurface fills fields, prefill first, draft on top', () {
      RegistrationSurface.seed(_surface(draft: {'pharmacy_name': 'Om Medical'}));
      final ctrl = CustomerFormController(formContext: 'signup');
      addTearDown(ctrl.dispose);

      expect(ctrl.seedFromSurface(), isTrue);
      expect(ctrl.ready, isTrue);
      expect(ctrl.fields.map((f) => f['key']).toList(),
          ['pharmacy_name', 'customer_name', 'whatsapp_no', 'email']);
      // Prefill from the login identity…
      expect(ctrl.controllerFor('customer_name').text, 'Om Prakash Sahu');
      expect(ctrl.controllerFor('whatsapp_no').text, '9812345678');
      // …and what was typed last time wins over it.
      expect(ctrl.controllerFor('pharmacy_name').text, 'Om Medical');
    });

    test('an empty surface seeds nothing — the screen falls back to load()',
        () {
      final ctrl = CustomerFormController(formContext: 'signup');
      addTearDown(ctrl.dispose);
      expect(ctrl.seedFromSurface(), isFalse);
      expect(ctrl.ready, isFalse);
    });

    test('autosave sends ONLY the fields that changed', () async {
      RegistrationSurface.seed(_surface());
      final calls = <({String fn, Map<String, dynamic>? params})>[];
      RegistrationSurface.rpcTransport = (fn, params) async {
        calls.add((fn: fn, params: params));
        return {'ok': true, 'saved': true};
      };

      final ctrl = CustomerFormController(formContext: 'signup');
      addTearDown(ctrl.dispose);
      ctrl.seedFromSurface();
      ctrl.enableAutosave();

      ctrl.controllerFor('pharmacy_name').text = 'Om Medical';
      await ctrl.flushDraft();

      expect(calls.length, 1);
      expect(calls.single.fn, 'customer_reg_draft_save');
      expect(calls.single.params!['p_patch'], {'pharmacy_name': 'Om Medical'},
          reason: 'the prefilled fields were not touched, so they are not sent');
      expect(ctrl.draftLabel.value, 'Saved');

      // Nothing changed since: nothing is sent.
      await ctrl.flushDraft();
      expect(calls.length, 1);
    });
  });

  // ── 5. A skeleton, never a lone spinner ──────────────────────────────────
  testWidgets('an empty cache renders the field skeleton', (tester) async {
    final ctrl = CustomerFormController(formContext: 'signup');
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: CustomerRegistrationForm(controller: ctrl)),
    ));
    await tester.pump();

    expect(find.byType(FormFieldsSkeleton), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  // ── 6. The step strip is the payload ─────────────────────────────────────
  testWidgets('both steps are printed verbatim and both are reachable',
      (tester) async {
    final s = _surface();
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RegistrationStepStrip(
          step: Map<String, dynamic>.from(s['step'] as Map),
          steps: (s['steps'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList(),
          onOpen: opened.add,
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('Step 1 of 2'), findsWidgets);
    expect(find.text('Step 2 of 2'), findsOneWidget);
    expect(find.text('Business details'), findsOneWidget);
    expect(find.text('Documents'), findsOneWidget);
    expect(find.text('0 of 2 steps done'), findsOneWidget);
    expect(find.text('Now'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);

    // The documents step is reachable from here — not locked behind step 1.
    await tester.tap(find.text('Documents'));
    await tester.pump();
    expect(opened, ['/customer/documents']);
  });
}

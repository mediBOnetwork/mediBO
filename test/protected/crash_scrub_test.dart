// PROTECTED — CHANGE #473.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes what a crash report may carry, never to make an
// unrelated change go green.
//
// What this holds down — the privacy contract of client crash reporting:
//
//   1. THE APP DOES NOT KNOW WHAT IS SENSITIVE. Every key, every pattern and
//      the redaction mask arrive from crash_config_get(). There is no Dart list
//      of "things that look like a phone number" to drift out of step with the
//      backend's. Adding a field to the redaction list must be an UPDATE, not a
//      deploy — so this file feeds the scrubber a config and asserts on the
//      OUTPUT, never on a hard-coded rule.
//
//   2. NO RULES MEANS NO EVENT. A scrubber that has not been handed the rules
//      redacts nothing, so an event reaching beforeSend before the config lands
//      is DROPPED, not sent bare. "I don't know what's sensitive yet" can only
//      ever mean send nothing.
//
//   3. THE MASK IS THE BACKEND'S WORD. The test asserts the config's own mask
//      string comes back — a Dart literal like '***' would be a second copy of
//      an answer that belongs to one place.
//
//   4. NESTING IS NOT AN ESCAPE HATCH. A phone number three maps deep inside a
//      breadcrumb, or inside a list, is redacted exactly like a top-level one.
//      Crash payloads are nested by construction, so a shallow scrubber is a
//      leak with a passing test.
//
//   5. A KEYED VALUE LOSES THE WHOLE VALUE. `customer_name: 'Ram Medical'`
//      cannot be pattern-matched away — no regex knows a name — so a key on the
//      backend's list is replaced wholesale rather than searched.
//
//   6. NON-PII SURVIVES. A crash report with everything redacted is useless.
//      The exception type, the file, the line, quantities and status codes must
//      pass through untouched, or the next engineer stops reading these.
//
//   7. ONE BAD PATTERN DOES NOT DISABLE THE REST. A regex the Dart engine
//      cannot compile is skipped; the other rules still run.
//
// Pure Dart: no Sentry, no Supabase, no network, no widgets. That is why this
// runs in milliseconds on the VM — see CLAUDE.md's note about keeping the
// protected suite fast.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/crash_scrub.dart';

/// The rules as `crash_config_get()` actually returns them. Copied from the
/// live payload so a backend change that breaks the client parse fails HERE.
const _mask = '[redacted]';

const _scrubKeys = <String>[
  'phone',
  'customer_name',
  'address',
  'gstin',
  'upi',
  'access_token',
  'medicine_name',
  'otp',
];

// ORDER MATTERS and the order is the backend's: a 15-digit UTR contains a
// 10-digit run that looks exactly like a mobile number, so the long/structured
// rules must run before phone_in or half the UTR survives in front of the mask.
// This list is the live `crash_config.scrub_patterns`, in its live order.
const _scrubPatterns = <Map<String, dynamic>>[
  {
    'name': 'jwt',
    'regex': r'eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}',
    'ci': false
  },
  {'name': 'bearer', 'regex': r'bearer\s+[A-Za-z0-9._-]{8,}', 'ci': true},
  {
    'name': 'email',
    'regex': r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
    'ci': false
  },
  {
    'name': 'gstin',
    'regex': r'[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{3}',
    'ci': false
  },
  {'name': 'pan', 'regex': r'[A-Z]{5}[0-9]{4}[A-Z]', 'ci': false},
  {'name': 'long_digits', 'regex': r'[0-9]{11,}', 'ci': false},
  {
    'name': 'aadhaar',
    'regex': r'[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}',
    'ci': false
  },
  {'name': 'phone_in', 'regex': r'(\+?91[ -]?)?[6-9][0-9]{9}', 'ci': false},
];


CrashScrubber _build({
  List<dynamic> keys = _scrubKeys,
  List<dynamic> patterns = _scrubPatterns,
  String mask = _mask,
}) =>
    CrashScrubber.fromConfig(
      scrubKeys: keys,
      scrubPatterns: patterns,
      mask: mask,
    );

void main() {
  group('CrashScrubber — the rules come from the backend', () {
    test('an unconfigured scrubber has no rules and redacts nothing', () {
      // RULE 2. CrashReporting.scrubEvent turns this into "drop the event";
      // what matters here is that the scrubber never invents a rule list.
      expect(CrashScrubber.empty.hasRules, isFalse);
      expect(CrashScrubber.empty.text('call 9876543210'), 'call 9876543210');

      final loaded = _build();
      expect(loaded.hasRules, isTrue);
    });

    test('the mask is the backend string, not a Dart literal', () {
      // RULE 3 — swap the mask in the config and the output follows it.
      final s = _build(mask: '<<gone>>');
      expect(s.text('reach me on 9876543210'), 'reach me on <<gone>>');
    });

    test('a pattern this engine cannot compile is skipped, not fatal', () {
      // RULE 7 — an unbalanced group would throw at RegExp construction.
      final s = _build(patterns: <Map<String, dynamic>>[
        {'name': 'broken', 'regex': r'([0-9]{3}', 'ci': false},
        ..._scrubPatterns,
      ]);
      expect(s.hasRules, isTrue);
      expect(s.text('otp for 9876543210'), 'otp for $_mask');
    });
  });

  group('CrashScrubber.text — patterns run over every string', () {
    final s = _build();

    test('an Indian mobile number is redacted', () {
      expect(s.text('RangeError while calling 9876543210'),
          'RangeError while calling $_mask');
      expect(s.text('supplier on +91 9123456789'), 'supplier on $_mask');
    });

    test('an email address is redacted', () {
      expect(s.text('failed for om@medibo.in'), 'failed for $_mask');
    });

    test('a bearer token and a JWT are redacted, case-insensitively', () {
      // RULE: `ci` travels as DATA because Dart's RegExp rejects inline (?i).
      expect(s.text('header Bearer sb_secret_abcdefgh12'), 'header $_mask');
      expect(
          s.text(
              'token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U'),
          'token $_mask');
    });

    test('a GSTIN, a PAN and a long digit run are redacted', () {
      expect(s.text('gst 22AAAAA0000A1Z5 pan ABCDE1234F'),
          'gst $_mask pan $_mask');
      expect(s.text('utr 123456789012345'), 'utr $_mask',
          reason:
              'a UTR must be redacted WHOLE — phone_in would otherwise eat its '
              'last ten digits and leave the first five in the clear');
      expect(s.text('id 1234 5678 9012'), 'id $_mask');
    });

    test('the useful half of a crash survives untouched', () {
      // RULE 6 — this is the whole reason to scrub instead of not reporting.
      const line =
          'StateError: Bad state: no element (package:pharma_b2b/screens/cart_screen.dart:412:9) qty=3 status=409';
      expect(s.text(line), line);
    });

    test('a null or empty string is empty, never the mask', () {
      expect(s.text(null), '');
      expect(s.text(''), '');
    });
  });

  group('CrashScrubber.value — nesting is not an escape hatch', () {
    final s = _build();

    test('a key on the backend list loses its WHOLE value', () {
      // RULE 5 — no regex can recognise a person's name or a shop's name.
      final out = s.map(<String, dynamic>{
        'customer_name': 'Ram Medical Store',
        'medicine_name': 'Dolo 650',
        'qty': 12,
      });
      expect(out['customer_name'], _mask);
      expect(out['medicine_name'], _mask);
      expect(out['qty'], 12, reason: 'a quantity is trade data, not PII');
    });

    test('key matching ignores case, the way the backend matches it', () {
      final out = s.map(<String, dynamic>{'Phone': '9876543210', 'GSTIN': 'x'});
      expect(out['Phone'], _mask);
      expect(out['GSTIN'], _mask);
    });

    test('a value buried three levels deep inside lists is still redacted', () {
      // RULE 4 — breadcrumbs and `extra` are nested by construction.
      final out = s.map(<String, dynamic>{
        'breadcrumbs': <dynamic>[
          <String, dynamic>{
            'category': 'rpc',
            'message': 'orders_place',
            'data': <String, dynamic>{
              'status': 400,
              'note': 'rejected for om@medibo.in',
              'lines': <dynamic>[
                <String, dynamic>{'address': '12 MG Road, Raipur', 'qty': 2},
              ],
            },
          },
        ],
      });
      final crumb = (out['breadcrumbs'] as List).first as Map<String, dynamic>;
      final data = crumb['data'] as Map<String, dynamic>;
      final lines = data['lines'] as List;
      final line = lines.first as Map<String, dynamic>;

      expect(crumb['message'], 'orders_place',
          reason: 'an RPC name is not PII and is the point of the breadcrumb');
      expect(data['status'], 400);
      expect(data['note'], 'rejected for $_mask');
      expect(line['address'], _mask);
      expect(line['qty'], 2);
    });

    test('numbers, bools and nulls pass through as themselves', () {
      final out = s.map(<String, dynamic>{
        'ms': 812,
        'ok': false,
        'missing': null,
      });
      expect(out['ms'], 812);
      expect(out['ok'], isFalse);
      expect(out['missing'], isNull);
    });

    test('a non-JSON object is stringified and scrubbed, never passed raw', () {
      final out = s.value(<dynamic>[Uri.parse('https://medibo.in/u/9876543210')]);
      expect((out as List).first, contains(_mask));
    });

    test('a null map is an empty map, not a crash', () {
      expect(s.map(null), isEmpty);
    });
  });
}

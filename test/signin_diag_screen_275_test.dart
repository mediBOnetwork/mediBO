// CHANGE #275 — the Sign-in Diagnostics screen prints auth_diag_list() verbatim.
//
// The screen exists because the Play-build failure had nowhere to be read. It
// must therefore add nothing of its own: every label, the tone, the hint and
// above all the signing SHA-1 come from the payload, and a backend refusal is
// rendered as the backend worded it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_service.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/signin_diag_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

class _FakeSvc extends DevQueueService {
  // autoRefreshToken:false — GoTrue otherwise starts a 10s periodic timer that
  // outlives the widget tree and trips flutter_test's !timersPending.
  _FakeSvc(this.payload)
      : super(
            client: SupabaseClient('http://localhost:1', 'test-key',
                authOptions:
                    const AuthClientOptions(autoRefreshToken: false)));
  final Map<String, dynamic> payload;
  @override
  Future<Map<String, dynamic>> authDiagList({int limit = 50}) async => payload;
}

const _row = {
  'when_label': '19 Aug, 17:02:24 IST',
  'code_label': 'canceled',
  'tone': 'warning',
  'stage_label': 'authenticate',
  'platform_label': 'android',
  'description': 'Activity was cancelled by the user.',
  'details': '',
  'hint': 'Credential Manager reports a provider-side failure as a cancellation.',
  'build_label': '1.3.8 (21)',
  'signing_label': '17:7A:DC:8E:D8:F4:6B:CB:02:8B:80:4F:35:F5:DC:7F:2B:4B:93:9D',
  'package_label': 'in.medibo.app',
  'elapsed_label': '8421 ms',
};

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  Future<void> pump(WidgetTester t, Map<String, dynamic> payload) async {
    await t.pumpWidget(MaterialApp(
        home: SignInDiagScreen(service: _FakeSvc(payload))));
    await t.pumpAndSettle();
  }

  testWidgets('renders the payload verbatim, signing fingerprint included',
      (t) async {
    await pump(t, const {
      'ok': true,
      'title': 'Sign-in diagnostics',
      'subtitle': 'Every Google sign-in failure recorded on a real device.',
      'count_label': '1 recorded',
      'empty_label': 'nothing yet',
      'refresh_label': 'Refresh',
      'rows': [_row],
    });

    expect(find.text('Sign-in diagnostics'), findsOneWidget);
    expect(find.text('Every Google sign-in failure recorded on a real device.'),
        findsOneWidget);
    expect(find.text('1 recorded'), findsOneWidget);
    expect(find.text('canceled'), findsOneWidget);
    expect(find.text('Activity was cancelled by the user.'), findsOneWidget);
    expect(find.text('19 Aug, 17:02:24 IST'), findsOneWidget);
    expect(find.text('1.3.8 (21)'), findsOneWidget);
    expect(find.text('8421 ms'), findsOneWidget);
    // The fact the whole screen exists for.
    expect(
        find.text('17:7A:DC:8E:D8:F4:6B:CB:02:8B:80:4F:35:F5:DC:7F:2B:4B:93:9D'),
        findsOneWidget);
    // The empty state is NOT drawn when there are rows.
    expect(find.text('nothing yet'), findsNothing);
  });

  testWidgets('an empty log shows the backend guidance, not a blank page',
      (t) async {
    await pump(t, const {
      'ok': true,
      'title': 'Sign-in diagnostics',
      'subtitle': 's',
      'count_label': '0 recorded',
      'empty_label': 'No sign-in failures recorded yet. Tap Continue with Google.',
      'refresh_label': 'Refresh',
      'rows': [],
    });

    expect(find.text('No sign-in failures recorded yet. Tap Continue with Google.'),
        findsOneWidget);
  });

  testWidgets('ok:false renders the backend refusal, never a Dart sentence',
      (t) async {
    await pump(t, const {
      'ok': false,
      'title': 'Sign-in diagnostics',
      'error': 'Sign-in diagnostics is a super-admin screen.',
    });

    expect(find.text('Sign-in diagnostics is a super-admin screen.'),
        findsOneWidget);
  });
}

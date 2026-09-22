// CMD #2156 — the customer app never prints technical error text.
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/customer_error.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    UiCopy.debugSet({'net.load_failed': "Couldn't load this. Check your internet."});
  });

  const failed = "Couldn't load this. Check your internet.";

  test('plumbing becomes net.load_failed', () {
    for (final raw in [
      'PostgrestException(message: canceling statement due to statement timeout, code: 57014, details: null, hint: null)',
      'ClientException: XMLHttpRequest error.',
      'TimeoutException after 0:00:09.000000: Future not completed',
      '{"code":"PGRST301","message":"JWT expired"}',
      'Null check operator used on a null value',
      "type 'Null' is not a subtype of type 'String'",
      'order_hours_closed',
      '#0      main (file:///x.dart:1:1)',
    ]) {
      expect(CustomerError.text(raw), failed, reason: raw);
    }
    expect(
        CustomerError.text(const PostgrestException(
            message: 'canceling statement due to statement timeout', code: '57014')),
        failed);
  });

  test('a human backend sentence reads through', () {
    expect(CustomerError.text(const PostgrestException(message: 'Your credit limit is used up.')),
        'Your credit limit is used up.');
    expect(CustomerError.text('Exception: Please add a delivery address first.'),
        'Please add a delivery address first.');
  });
}

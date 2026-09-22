// CMD #2151 — the two pickers on the customer's General step.
//
// WhatsApp box tap → the phone's own number list (Android: Google Phone
// Number Hint, via the `medibo/phone_hint` channel in MainActivity). Email
// box tap → the Google account list (Android: google_sign_in's account
// sheet; the account is read for its address and signed straight back out —
// this is not a login). On web both return null: the boxes carry the
// backend's autofillHints, so the browser's own autofill is the picker.
//
// Nothing here judges the value: whatever comes back goes into the box and
// through the same custreg_contact_check a typed value does.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../screens/auth/login_screen.dart' show kGoogleWebClientId;

/// Where "Login" on a taken card leaves its intent for the login screen:
/// 'otp' (send the code at once) or 'google' (open the account list).
const String kLoginIntentKey = 'medibo_login_intent';

class ContactPickers {
  ContactPickers._();

  static const MethodChannel _phone = MethodChannel('medibo/phone_hint');

  /// Tests swap these for fakes; production uses the platform pickers.
  static Future<String?> Function() phone = _nativePhone;
  static Future<String?> Function() email = _nativeEmail;

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<String?> _nativePhone() async {
    if (!_android) return null;
    try {
      final v = await _phone.invokeMethod<String>('pick');
      return (v == null || v.trim().isEmpty) ? null : v.trim();
    } catch (_) {
      // Closed sheet, no SIM, an older build without the channel: the box
      // simply stays a box.
      return null;
    }
  }

  static bool _gsiReady = false;

  static Future<String?> _nativeEmail() async {
    if (!_android) return null;
    try {
      final g = GoogleSignIn.instance;
      if (!_gsiReady) {
        try {
          await g.initialize(serverClientId: kGoogleWebClientId);
        } catch (_) {}
        _gsiReady = true;
      }
      final a = await g.authenticate(scopeHint: const ['email']);
      final e = a.email.trim();
      try {
        await g.signOut();
      } catch (_) {}
      return e.isEmpty ? null : e;
    } catch (_) {
      return null;
    }
  }
}

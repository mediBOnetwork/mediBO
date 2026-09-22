// CMD #2171 (Om, live bug on APK 1.3.33) — THE one phone cleaner.
//
// Picking "0835 788 1873" from the phone's own number list filled the box with
// "+448357881873" and the live check said Invalid. The picked string was put
// into the field almost as it came — only the punctuation was dropped, the "+"
// and the country code stayed — so a sheet that offers a number in any
// international form broke the box it filled.
//
// There were already two rules in the app: the login screen's (last 10 digits,
// which is right) and the registration form's (strip punctuation, keep the +,
// which is wrong). Two rules is how one of them stays wrong. This is the ONE,
// and every surface calls it: the pickers, browser autofill, a paste and
// ordinary typing, on the login screen, on registration and on staff Add
// customer.
//
// The RULE, in Om's words:
//   • strip spaces, dashes, brackets and any leading "+";
//   • drop a leading country code (91, or any other — 44 — ) and a leading 0;
//   • keep the LAST [digits] digits;
//   • never ADD a country code — "+91" is a fixed label outside the field.
//
// Keeping the last N digits does all three at once, which is why it is the
// whole rule: +448357881873, +91 83578 81873, 08357881873 and 8357881873 all
// land as 8357881873.
//
// It does not JUDGE. Whether ten digits starting 6-9 are a real number, and
// what to say when they are not, stays with custreg_contact_check — this file
// never writes a word and never colours a box.

import 'package:flutter/services.dart';

class PhoneClean {
  PhoneClean._();

  /// How many digits an Indian mobile number has. The backend sends its own
  /// (`wizard.phone_digits`); this is the fallback for a payload that predates
  /// it, never a second opinion.
  static const int defaultDigits = 10;

  /// A number from ANY source → its last [digits] digits.
  static String clean(String raw, {int digits = defaultDigits}) {
    final d = raw.replaceAll(RegExp(r'\D'), '');
    if (digits <= 0) return d;
    return d.length > digits ? d.substring(d.length - digits) : d;
  }

  /// How many characters this edit inserted — two or more means it arrived in
  /// one go (a picker, autofill, a paste) rather than under a fingertip.
  static int insertedLength(String a, String b) {
    var p = 0;
    while (p < a.length && p < b.length && a[p] == b[p]) {
      p++;
    }
    var s = 0;
    while (s < a.length - p && s < b.length - p &&
        a[a.length - 1 - s] == b[b.length - 1 - s]) {
      s++;
    }
    return b.length - p - s;
  }
}

/// Digits only, capped at [digits] — and a value that arrives in ONE GO keeps
/// its LAST [digits] digits instead of its first, so a pasted or picked
/// "+44 8357 881873" becomes 8357881873 rather than 4483578818.
///
/// Typing by hand still fills from the left and stops at the cap: a finger
/// cannot mean "you have the wrong end of my number".
class PhoneCleanFormatter extends TextInputFormatter {
  PhoneCleanFormatter({this.digits = PhoneClean.defaultDigits, this.onBulk});

  final int digits;

  /// Told when a whole number landed at once: the raw text and what it cleaned
  /// to. The registration box uses it to run the live check immediately.
  final void Function(String raw, String clean)? onBulk;

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    var d = newValue.text.replaceAll(RegExp(r'\D'), '');
    final bulk = PhoneClean.insertedLength(oldValue.text, newValue.text) >= 2;
    if (digits > 0 && d.length > digits) {
      d = bulk ? d.substring(d.length - digits) : d.substring(0, digits);
    }
    if (bulk && d.length == digits) onBulk?.call(newValue.text, d);
    return TextEditingValue(
      text: d,
      selection: TextSelection.collapsed(offset: d.length),
    );
  }
}

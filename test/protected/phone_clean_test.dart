// PROTECTED — CMD #2171.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how a phone number is cleaned.
//
// Om, on APK 1.3.33: picking "0835 788 1873" from the phone's own number list
// filled the WhatsApp box with "+448357881873", and the live check said
// Invalid. The picked string had gone into the field with only its punctuation
// removed — the "+" and the country code stayed — because the registration
// form had its OWN rule while the login screen had the right one. Two rules is
// how one of them stays wrong.
//
// What this holds down, on the ONE cleaner every surface now calls:
//
//   1. THE RULE: the LAST ten digits are the number. That drops a "+", a 91, a
//      44, any other country code and a leading 0 in a single step, and it can
//      never cut the number from the front.
//
//   2. Om's own five examples land as 8357881873 / 9876543210. They are in
//      this test by name, so a future "simplification" that breaks one of them
//      fails here rather than on a phone.
//
//   3. Nothing is ever ADDED: no country code, no prefix. "+91" is a label
//      outside the box, never part of its value.
//
//   4. A value that arrives in ONE GO (picker, autofill, paste) keeps its LAST
//      ten digits; typing by hand still fills from the left and stops at ten.
//      A finger cannot mean "you have the wrong end of my number".
//
//   5. Nothing here JUDGES. The cleaner returns whatever it has, short or odd;
//      custreg_contact_check decides what is a real number and says so in its
//      own words.
//
// No network, no Supabase, no platform channel.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/utils/phone_clean.dart';

TextEditingValue _v(String s) =>
    TextEditingValue(text: s, selection: TextSelection.collapsed(offset: s.length));

void main() {
  group('the rule', () {
    test('the bug Om reported: a picked +44 number lands as ten digits', () {
      expect(PhoneClean.clean('+448357881873'), '8357881873');
      expect(PhoneClean.clean('0835 788 1873'), '8357881873');
    });

    test("Om's other four examples", () {
      expect(PhoneClean.clean('+91 98765 43210'), '9876543210');
      expect(PhoneClean.clean('098765 43210'), '9876543210');
      expect(PhoneClean.clean('9876543210'), '9876543210');
      expect(PhoneClean.clean('+91-98765 43210'), '9876543210');
    });

    test('brackets, dashes and spaces are punctuation, not digits', () {
      expect(PhoneClean.clean('(0) 83578-81873'), '8357881873');
    });

    test('nothing is ever added', () {
      expect(PhoneClean.clean('8357881873'), '8357881873');
      expect(PhoneClean.clean('8357881873').startsWith('+'), isFalse);
      expect(PhoneClean.clean('8357881873').startsWith('91'), isFalse);
    });

    test('it does not judge — a short or odd value comes back as it is', () {
      expect(PhoneClean.clean('83578'), '83578');
      expect(PhoneClean.clean(''), '');
      expect(PhoneClean.clean('12345678901234'), '5678901234');
    });

    test('the length is the backend\'s, not a constant here', () {
      expect(PhoneClean.clean('+448357881873', digits: 8), '57881873');
    });
  });

  group('the box', () {
    test('a number that arrives in one go keeps its LAST ten digits', () {
      final f = PhoneCleanFormatter();
      expect(f.formatEditUpdate(_v(''), _v('+448357881873')).text, '8357881873');
      expect(f.formatEditUpdate(_v(''), _v('+91 98765 43210')).text, '9876543210');
    });

    test('typing by hand fills from the left and stops at ten', () {
      final f = PhoneCleanFormatter();
      expect(f.formatEditUpdate(_v('983578818'), _v('9835788187')).text,
          '9835788187');
      // the eleventh keystroke is refused, not shifted
      expect(f.formatEditUpdate(_v('9835788187'), _v('98357881873')).text,
          '9835788187');
    });

    test('a whole number landing at once is announced once', () {
      final seen = <String>[];
      final f = PhoneCleanFormatter(onBulk: (raw, clean) => seen.add(clean));
      f.formatEditUpdate(_v(''), _v('+448357881873'));
      expect(seen, ['8357881873']);
    });
  });
}

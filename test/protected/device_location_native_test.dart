// PROTECTED — CMD #2171.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how the NATIVE app reads the device's position.
//
// Om, on Android 1.3.33: on the registration Location step, "Use my location"
// did nothing — the system permission popup never appeared — and the amber
// bar's "Turn on" link did nothing either. The cause was not the screen: the
// native half of DeviceLocation was a stub that answered null to every call
// "because there is no browser Geolocation", so on the phone nothing was ever
// asked and nothing was ever read. The button had only ever worked in a
// browser, where the other half of the conditional import lives.
//
// What this holds down, on the native file the app actually ships:
//
//   1. A fix is ASKED FOR. With the grant already given, best()/current()
//      reach the platform's 'fix' method and return its coordinates.
//
//   2. Without the grant, the dialog is RAISED first — 'requestPermission'
//      is called, and only then 'fix'. This is the line whose absence was
//      the bug.
//
//   3. A refusal is honoured: no 'fix' call, and null back. The screen draws
//      its amber bar from that null; nothing here writes a word about it.
//
//   4. Null is still null — a platform that answers nothing, answers nothing.
//      No coordinate is ever invented, and 0,0 (the Gulf of Guinea) is not a
//      position.
//
// No network, no Supabase, no platform channel — the transport seam is stubbed.
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/device_location_stub.dart';

void main() {
  final calls = <String>[];

  setUp(() => calls.clear());
  tearDown(() => DeviceLocation.transport = null);

  void stub({
    required bool granted,
    bool grantOnAsk = false,
    Map<String, dynamic>? fix,
  }) {
    var have = granted;
    DeviceLocation.transport = (method, [args]) async {
      calls.add(method);
      switch (method) {
        case 'hasPermission':
          return have;
        case 'requestPermission':
          if (grantOnAsk) have = true;
          return have;
        case 'fix':
          return fix;
        case 'openSettings':
          return true;
      }
      return null;
    };
  }

  test('granted: the fix is read from the platform', () async {
    stub(granted: true, fix: {'lat': 21.2514, 'lng': 81.6296, 'accuracy': 12.0});
    final f = await DeviceLocation.best();
    expect(f, isNotNull);
    expect(f!.lat, 21.2514);
    expect(f.lng, 81.6296);
    expect(f.accuracy, 12.0);
    expect(calls, contains('fix'));
  });

  test('not granted: the dialog is raised BEFORE the fix is read', () async {
    stub(
        granted: false,
        grantOnAsk: true,
        fix: {'lat': 21.0, 'lng': 81.0, 'accuracy': 8.0});
    final f = await DeviceLocation.best();
    expect(f, isNotNull, reason: 'granted in the dialog, so a fix follows');
    expect(calls.indexOf('requestPermission') < calls.indexOf('fix'), isTrue,
        reason: 'the popup comes first — this is the #2171 bug');
  });

  test('refused: nothing is read and nothing is invented', () async {
    stub(granted: false, fix: {'lat': 21.0, 'lng': 81.0});
    expect(await DeviceLocation.best(), isNull);
    expect(await DeviceLocation.current(), isNull);
    expect(calls, contains('requestPermission'));
    expect(calls, isNot(contains('fix')));
  });

  test('no platform answer, and 0,0, are both null', () async {
    stub(granted: true, fix: null);
    expect(await DeviceLocation.best(), isNull);
    stub(granted: true, fix: {'lat': 0.0, 'lng': 0.0});
    expect(await DeviceLocation.best(), isNull,
        reason: '0,0 is the Gulf of Guinea, not a shop');
  });

  test('openSettings is a door, not a decision', () async {
    stub(granted: false);
    expect(await DeviceLocation.openSettings(), isTrue);
    expect(calls, contains('openSettings'));
  });
}

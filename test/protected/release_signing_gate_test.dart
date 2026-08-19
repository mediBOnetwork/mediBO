// CHANGE #283 — the gate that guards the signing key.
//
// A device on 1.3.11 (24) reported signing SHA-1
// 69:37:2B:88:E2:5F:38:D3:23:C1:46:DE:3D:12:BE:39:22:8C:5B:C5, which matched no
// keystore on the build host, and the working assumption became "the release is
// debug-signed". It was not. `apksigner verify --print-certs` on the exact APK
// at the app_releases URL returned ONE signer, CN=mediBO, SHA-1
// CB:88:BD:C5:2B:90:15:04:CD:58:3D:45:B0:69:7D:1E:58:40:60:55 — the original
// upload key. The reporting device had `install_source=com.android.vending`:
// it installed from the Play Store, and Play App Signing strips the upload
// signature and re-signs with its own app-signing key. 69:37:2B is that key.
// (The host's debug certificate is 2B:5F:FC:12:…, a different number again.)
//
// The artifact was right, but every check standing between a build and a user
// was ADVISORY, so nobody could prove it in the moment:
//
//   * build_apk.sh ran `apksigner … | grep DN:` — a print. Nothing read its
//     exit code, so a wrong-key APK walked past it.
//   * publish_apk.sh matched the DN STRING "CN=mediBO". A DN is a self-declared
//     label: `keytool -genkey -dname "CN=mediBO"` mints a brand-new key that
//     passes that check and installs for nobody.
//   * build_aab.sh checked the KEYSTORE before building and never looked at the
//     bundle it produced — a signingConfig that failed to apply stayed
//     invisible until Play rejected the upload.
//
// scripts/verify_signing.sh replaces all three with one fingerprint assertion
// on the PRODUCED FILE, the same contract as scripts/check_16kb.py. This file
// pins that wiring: drop the gate from any of the three scripts and the
// protected suite goes red, which stops the deploy that removed it.
//
// It reads the shipped scripts as text on purpose and asserts the CONTRACT —
// the gate is invoked, its exit code is honoured, the expected fingerprint is
// the upload key — never the wording of a log line, so ordinary edits to those
// scripts stay free.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Strips shell comments so a rule is never "satisfied" by a line that merely
/// mentions it in prose. Only executable shell counts as enforcement.
String _code(String source) => source
    .split('\n')
    .map((line) => line.trimLeft().startsWith('#') ? '' : line)
    .join('\n');

/// The ORIGINAL mediBO upload key. Play matches an upload against this, and a
/// sideloaded APK must carry it to install over the previous release.
const kUploadKeySha1 =
    'CB:88:BD:C5:2B:90:15:04:CD:58:3D:45:B0:69:7D:1E:58:40:60:55';

/// The certificate a Play-INSTALLED copy reports. It is not ours and never
/// appears in a build: Play generates it and re-signs every upload with it.
/// It is named here only so the next person who sees it can place it — the
/// build must never be changed to produce it, and it must never be registered
/// anywhere to make a check pass.
const kPlayAppSigningSha1 =
    '69:37:2B:88:E2:5F:38:D3:23:C1:46:DE:3D:12:BE:39:22:8C:5B:C5';

void main() {
  final root = Directory.current.path;
  final gate = File('$root/scripts/verify_signing.sh');
  final buildApk = File('$root/scripts/build_apk.sh');
  final buildAab = File('$root/scripts/build_aab.sh');
  final publishApk = File('$root/scripts/publish_apk.sh');

  group('the signing gate exists and is the one source of the identity', () {
    test('scripts/verify_signing.sh is present and executable', () {
      expect(gate.existsSync(), isTrue,
          reason: 'scripts/verify_signing.sh is the signing gate — restore it');
      final mode = gate.statSync().mode;
      expect(mode & 0x40, isNot(0),
          reason: 'verify_signing.sh must be owner-executable');
    });

    test('it expects the ORIGINAL upload key, not whatever a device reports',
        () {
      final code = _code(gate.readAsStringSync());
      expect(code, contains(kUploadKeySha1),
          reason: 'the gate must assert the original mediBO upload key');
      expect(code, isNot(contains(kPlayAppSigningSha1)),
          reason: 'the Play app-signing key must never be accepted by a build '
              'gate — registering it would let a non-upload-key artifact ship');
    });

    test('a mismatch fails the process — the gate is not a report', () {
      final code = _code(gate.readAsStringSync());
      expect(code, contains(RegExp(r'exit\s+1')),
          reason: 'the gate must exit non-zero on a wrong key');
    });

    test('a bundle is checked for integrity, not only for whose cert it holds',
        () {
      // An .aab is a plain zip. `zip bundle.aab payload.txt` appends an entry
      // AFTER signing and META-INF still holds the upload certificate, so a
      // cert-only read passes a bundle carrying content nobody signed. Proven
      // against a real jar-signed bundle in #283 before this check existed.
      final code = _code(gate.readAsStringSync());
      expect(code, contains('jarsigner -verify'),
          reason: 'the AAB path must ask jarsigner whether the signature '
              'actually covers the bundle, not just read its certificate');
      expect(code, contains(RegExp(r"grep\s+-qi\s+'unsigned entries'")),
          reason: 'an entry added after signing must fail the gate');
      expect(code, isNot(contains('jarsigner -verify -strict')),
          reason: 'an upload key is self-signed by design; -strict fails every '
              'legitimate bundle on chainNotValidated');
    });

    test('it publishes the expected fingerprint so nothing pastes it twice',
        () {
      expect(_code(gate.readAsStringSync()), contains('--expected'),
          reason: 'verify_signing.sh --expected is the single source of the '
              'expected fingerprint for the rest of the lane');
    });
  });

  group('every path that produces or ships an artifact runs the gate', () {
    for (final entry in {
      'scripts/build_apk.sh': buildApk,
      'scripts/build_aab.sh': buildAab,
      'scripts/publish_apk.sh': publishApk,
    }.entries) {
      test('${entry.key} invokes verify_signing.sh', () {
        expect(entry.value.existsSync(), isTrue);
        expect(_code(entry.value.readAsStringSync()),
            contains('verify_signing.sh'),
            reason: '${entry.key} must assert the signer of the artifact it '
                'produces or uploads');
      });
    }

    test('no script re-introduces the advisory `apksigner | grep DN` print',
        () {
      for (final f in [buildApk, buildAab, publishApk]) {
        final code = _code(f.readAsStringSync());
        expect(code, isNot(contains(RegExp(r'apksigner.*\|\s*grep'))),
            reason: '${f.path}: piping apksigner into grep discards the exit '
                'code — that is exactly the advisory check #283 removed');
      }
    });

    test('publish_apk.sh no longer decides identity from the certificate DN',
        () {
      final code = _code(publishApk.readAsStringSync());
      expect(code, isNot(contains(RegExp(r'case\s+"?\$CERT'))),
          reason: 'a DN string match accepts any self-minted "CN=mediBO" key; '
              'identity is the fingerprint');
    });

    test('build_aab.sh checks the produced bundle, not only the keystore', () {
      final code = _code(buildAab.readAsStringSync());
      final gateLine = code.indexOf('verify_signing.sh "\$AAB"');
      final buildLine = code.indexOf('flutter build appbundle');
      expect(gateLine, greaterThan(-1),
          reason: 'the bundle itself must be verified after it is built');
      expect(buildLine, greaterThan(-1));
      expect(gateLine, greaterThan(buildLine),
          reason: 'verifying the artifact must happen AFTER the build that '
              'produces it — a pre-build keystore check cannot see a '
              'signingConfig that failed to apply');
    });
  });
}

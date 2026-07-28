import 'dart:js_interop';
import 'dart:math';
import 'dart:convert';

const _kGisClientId =
    '565577322247-9ls2ocm01sjilq2sb17r5afm6se9jfr4.apps.googleusercontent.com';

@JS('mediboIsMobile')
external bool _mediboIsMobileJs();

/// Returns true on mobile/tablet browsers (phones, touch-only devices).
/// Defaults to false (desktop) if JS is unavailable.
bool isMobileWeb() {
  try { return _mediboIsMobileJs(); } catch (_) { return false; }
}

@JS('mediboIsCoarsePointer')
external bool _mediboIsCoarsePointerJs();

/// CHANGE #399: true when the primary pointer is touch (coarse), for
/// diagnosing touch-vs-mouse Google sign-in behavior via render-log.
/// Defaults to false if JS is unavailable.
bool isCoarsePointer() {
  try { return _mediboIsCoarsePointerJs(); } catch (_) { return false; }
}

/// Nonce pair: raw bytes (base64url, passed to Supabase signInWithIdToken) and
/// SHA-256 hex hash (passed to GIS initialize so it embeds it in the JWT nonce claim).
({String rawNonce, String hashedNonce}) _generateNoncePair() {
  final rand = Random.secure();
  final bytes = List<int>.generate(18, (_) => rand.nextInt(256));
  final raw = base64Url.encode(bytes); // base64url, no padding needed by Supabase
  // SHA-256 via a simple pure-Dart implementation (avoids external package dep).
  final hash = _sha256Hex(utf8.encode(raw));
  return (rawNonce: raw, hashedNonce: hash);
}

/// Pure-Dart SHA-256 → lowercase hex string.
/// Spec: FIPS 180-4. This avoids adding the `crypto` package dependency.
String _sha256Hex(List<int> message) {
  // Initial hash values (first 32 bits of fractional parts of sqrt of first 8 primes)
  var h = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  // Round constants (first 32 bits of fractional parts of cbrt of first 64 primes)
  const k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  int _mask(int x) => x & 0xFFFFFFFF;
  int _rotr(int x, int n) => _mask(x >>> n) | _mask(x << (32 - n));
  int _add(int a, int b) => _mask(a + b);

  // Pre-processing: padding
  final bitLen = message.length * 8;
  final List<int> msg = List.from(message)..add(0x80);
  while (msg.length % 64 != 56) msg.add(0x00);
  // Append 64-bit big-endian bit length
  for (var i = 7; i >= 0; i--) {
    msg.add((bitLen >>> (i * 8)) & 0xFF);
  }

  // Process each 512-bit (64-byte) chunk
  for (var chunk = 0; chunk < msg.length; chunk += 64) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      w[i] = (msg[chunk + i * 4] << 24) |
              (msg[chunk + i * 4 + 1] << 16) |
              (msg[chunk + i * 4 + 2] << 8) |
               msg[chunk + i * 4 + 3];
      w[i] = _mask(w[i]);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i-15], 7) ^ _rotr(w[i-15], 18) ^ (w[i-15] >>> 3);
      final s1 = _rotr(w[i-2], 17) ^ _rotr(w[i-2],  19) ^ (w[i-2]  >>> 10);
      w[i] = _mask(_add(_add(_add(w[i-16], s0), w[i-7]), s1));
    }

    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];

    for (var i = 0; i < 64; i++) {
      final S1   = _rotr(e, 6)  ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch   = (e & f) ^ (~e & g);
      final temp1 = _add(_add(_add(_add(hh, S1), _mask(ch)), k[i]), w[i]);
      final S0   = _rotr(a, 2)  ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj  = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = _add(S0, _mask(maj));

      hh = g; g = f; f = e;
      e  = _add(d, temp1);
      d  = c; c = b; b = a;
      a  = _add(temp1, temp2);
    }

    h[0] = _add(h[0], a); h[1] = _add(h[1], b);
    h[2] = _add(h[2], c); h[3] = _add(h[3], d);
    h[4] = _add(h[4], e); h[5] = _add(h[5], f);
    h[6] = _add(h[6], g); h[7] = _add(h[7], hh);
  }

  return h.map((v) => v.toRadixString(16).padLeft(8, '0')).join();
}

@JS('mediboLastGisError')
external JSString _mediboLastGisErrorJs();

/// Why the last Google attempt failed, for render-log diagnosis only.
/// Never shown to a user.
String lastGisError() {
  try {
    return _mediboLastGisErrorJs().toDart;
  } catch (_) {
    return '';
  }
}

@JS('mediboGisPrewarm')
external JSPromise<JSString?> _mediboGisPrewarm(
    JSString clientId, JSString hashedNonce);

@JS('mediboGisPromptNow')
external JSPromise<JSString?> _mediboGisPromptNow();

@JS('mediboIsStandalone')
external bool _mediboIsStandaloneJs();

/// True when the app is running as an installed PWA (standalone display mode).
/// In that mode a full-page OAuth redirect leaves the app and shows browser
/// chrome, so it must never be used as a silent fallback.
bool isStandalonePwa() {
  try {
    return _mediboIsStandaloneJs();
  } catch (_) {
    return false;
  }
}

/// One Tap could not be shown at all (library missing, or a moment we could not
/// classify).
class GisOneTapUnavailable implements Exception {
  const GisOneTapUnavailable();
}

/// CHANGE #563: Google refused to display the sheet — cooldown after an earlier
/// dismissal, no Google session on the device, or a FedCM refusal.
///
/// This must NEVER trigger a navigation. The caller shows the backend's
/// `google_unavailable_note` and reveals the `google_browser_label` link; only a
/// deliberate tap on that link may open the full-page browser chooser.
class GisOneTapSuppressed implements Exception {
  const GisOneTapSuppressed();
}

/// The user deliberately dismissed the chooser — do not fall back.
class GisOneTapCancelled implements Exception {
  const GisOneTapCancelled();
}

/// The nonce pair for the current sign-in attempt. The hashed half goes to
/// Google (embedded in the JWT's nonce claim), the raw half to Supabase, which
/// re-hashes it to verify — so the raw half must survive until the credential
/// comes back.
({String rawNonce, String hashedNonce})? _warmPair;

({String idToken, String rawNonce}) _wrap(String? token) {
  if (token == null || token.isEmpty) throw const GisOneTapSuppressed();
  final raw = _warmPair?.rawNonce;
  if (raw == null) throw const GisOneTapSuppressed();
  return (idToken: token, rawNonce: raw);
}

Never _rethrowAsGis(Object e) {
  final s = e.toString();
  if (s.contains('cancelled')) throw const GisOneTapCancelled();
  // CHANGE #563: everything the JS bridge cannot turn into a credential now
  // arrives as 'suppressed' — nothing here may cause a navigation.
  if (s.contains('suppressed')) throw const GisOneTapSuppressed();
  throw const GisOneTapUnavailable();
}

/// CHANGE #562: load GIS and run `initialize()` up front, so the later tap can
/// call `prompt()` synchronously and keep its transient user activation —
/// without which Chrome silently refuses to display the One Tap sheet.
///
/// Safe to call repeatedly; returns true once the library is initialised.
Future<bool> gisPrewarm() async {
  _warmPair ??= _generateNoncePair();
  try {
    final r = await _mediboGisPrewarm(
      _kGisClientId.toJS,
      _warmPair!.hashedNonce.toJS,
    ).toDart;
    return r?.toDart == 'ready';
  } catch (_) {
    return false;
  }
}

/// CHANGE #562: Google One Tap via GIS — restored as the ONLY in-app Google
/// path, because it is the only one that has ever worked here: the Supabase
/// auth log holds four successful grant_type=id_token logins, all from this
/// path on the pre-#557 build, and none since FedCM replaced it.
///
/// Google draws the sheet itself and it lists the device's signed-in accounts;
/// nothing of ours is rendered, so no layout is involved.
///
/// MUST be called directly from the tap handler with no awaits in between, or
/// the user activation is lost and the sheet will not display.
///
/// CHANGE #563: throws [GisOneTapCancelled] when the user closed the sheet —
/// the caller stays put and re-enables the button — or [GisOneTapSuppressed]
/// when Google refused to display it, which reveals the browser-chooser link.
/// Neither outcome may navigate on its own.
Future<({String idToken, String rawNonce})> gisPromptOneTap() async {
  try {
    final r = await _mediboGisPromptNow().toDart;
    return _wrap(r?.toDart);
  } on GisOneTapSuppressed {
    rethrow;
  } on GisOneTapUnavailable {
    rethrow;
  } catch (e) {
    _rethrowAsGis(e);
  }
}

@JS('mediboGisDisableAutoSelect')
external bool _mediboGisDisableAutoSelectJs();

/// CHANGE #563: called on logout so the next sign-in always shows the chooser
/// rather than silently reusing the last account.
bool gisDisableAutoSelect() {
  try {
    return _mediboGisDisableAutoSelectJs();
  } catch (_) {
    return false;
  }
}

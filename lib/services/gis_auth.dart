import 'dart:js_interop';
import 'dart:math';
import 'dart:convert';

const _kGisClientId =
    '565577322247-9ls2ocm01sjilq2sb17r5afm6se9jfr4.apps.googleusercontent.com';

@JS('mediboGisSignIn')
external JSPromise<JSString?> _mediboGisSignIn(JSString clientId, JSString hashedNonce);

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

/// Opens the GIS modal.
/// Returns `(idToken, rawNonce)` on success, or throws on cancel/timeout.
/// Correct mapping:
///   hashedNonce → GIS initialize (embedded in JWT nonce claim by Google)
///   rawNonce    → Supabase signInWithIdToken(nonce:)   (Supabase re-hashes to verify)
Future<({String idToken, String rawNonce})> gisSignInWithNonce() async {
  final pair = _generateNoncePair();
  final result = await _mediboGisSignIn(
    _kGisClientId.toJS,
    pair.hashedNonce.toJS,
  ).toDart;
  final token = result?.toDart;
  if (token == null || token.isEmpty) throw Exception('GIS sign-in cancelled or failed');
  return (idToken: token, rawNonce: pair.rawNonce);
}

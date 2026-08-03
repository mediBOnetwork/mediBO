// PROTECTED — CHANGE #643.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes payment-proof loading, never to make an unrelated change
// go green.
//
// The bug: the customer's cash-payment proof showed "Couldn't load proof — tap
// to retry" while the same image rendered fine for admin. Proofs live in TWO
// private buckets — cash/WhatsApp proofs in 'whatsapp-media', customer-app
// uploads in 'payment-proofs' — and WHICH one is per-claim. The app used to
// guess it from the path prefix, and every surface rolled its own fetch.
//
// What must never regress:
//
//   1. The bucket used is the one the PAYLOAD named, verbatim. A cash proof
//      whose entry says 'whatsapp-media' must be signed against
//      'whatsapp-media' — never a bucket chosen here.
//   2. A second entry naming 'payment-proofs' routes to 'payment-proofs'. One
//      loader, two answers, both from the payload.
//   3. The fetch is the SIGNED/authenticated call. Both buckets are private, so
//      a public URL fails regardless of storage policy — the loader must never
//      reach for one.
//   4. A failure is diagnosable: the bucket, the path and the storage error all
//      reach the log (PART B). This failure used to be silent, which is why it
//      took a live DB session to find.
//   5. A missing bucket is REPORTED, not guessed.
//   6. A retry actually re-requests (PART C) — a failed load is not cached.
//
// Pure VM test: no Supabase, no dart:html, no network. The signer is injected.

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/payment_proof.dart';

/// One recorded signer invocation.
class _SignCall {
  final String bucket;
  final String path;
  final int expiresIn;
  _SignCall(this.bucket, this.path, this.expiresIn);
  @override
  String toString() => 'sign($bucket, $path, $expiresIn)';
}

/// Records every call and returns a signed-looking URL. Note the shape: a
/// SIGNED url carries /object/sign/ and a token. A public url would be
/// /object/public/ — asserted against below.
class _FakeSigner {
  final List<_SignCall> calls = [];
  final bool fail;
  _FakeSigner({this.fail = false});

  Future<String> call(String bucket, String path, int expiresIn) async {
    calls.add(_SignCall(bucket, path, expiresIn));
    if (fail) {
      throw Exception('StorageException(statusCode: 400, error: Bad Request)');
    }
    return 'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/'
        'object/sign/$bucket/$path?token=fake';
  }
}

class _Log {
  final List<String> lines = [];
  void call(String key, String value) => lines.add('$key|$value');
  String get joined => lines.join('\n');
}

/// The real customer payload row for the ₹3,500 cash claim on CPO020826CHAO1.
const _cashEntry = {
  'amount_label': '₹3,500.00',
  'method': 'cash',
  'screenshot': 'cash_payments/cash_1785656698115.jpg',
  'bucket': 'whatsapp-media',
};

/// A UPI screenshot, which lives in the OTHER bucket.
const _upiEntry = {
  'amount_label': '₹10,770.73',
  'method': 'online',
  'screenshot': 'a1b2c3/upi_1785656000000.jpg',
  'bucket': 'payment-proofs',
};

/// The case that actually discriminates. Every realistic fixture has a path
/// prefix that AGREES with its bucket, so a loader still guessing from the
/// prefix passes those by luck. Here the payload says 'payment-proofs' while
/// the path starts 'cash_payments/' — the old guess would answer
/// 'whatsapp-media'. Only a loader that reads the payload gets this right.
const _contradictingEntry = {
  'screenshot': 'cash_payments/cash_1785656698115.jpg',
  'bucket': 'payment-proofs',
};

void main() {
  test('the payload bucket WINS over what the path prefix suggests', () async {
    final signer = _FakeSigner();
    final loader = PaymentProofLoader(signer: signer.call);

    final res = await loader.load(
      payloadBucket: _contradictingEntry['bucket'],
      path: _contradictingEntry['screenshot']!,
    );

    expect(res.ok, isTrue);
    expect(signer.calls.single.bucket, 'payment-proofs',
        reason: 'a cash_payments/ path must NOT force whatsapp-media when the '
            'payload named a different bucket');
  });

  test('the bucket comes from the entry, not from the path', () async {
    final signer = _FakeSigner();
    final loader = PaymentProofLoader(signer: signer.call);

    final res = await loader.load(
      payloadBucket: _cashEntry['bucket'],
      path: _cashEntry['screenshot']!,
    );

    expect(res.ok, isTrue, reason: 'error was: ${res.error}');
    expect(signer.calls, hasLength(1));
    expect(signer.calls.single.bucket, 'whatsapp-media',
        reason: 'must use the bucket the payload named');
    expect(signer.calls.single.path, 'cash_payments/cash_1785656698115.jpg');
    expect(res.bucket, 'whatsapp-media');
  });

  test('a second entry naming payment-proofs routes to THAT bucket', () async {
    final signer = _FakeSigner();
    final loader = PaymentProofLoader(signer: signer.call);

    await loader.load(
        payloadBucket: _cashEntry['bucket'], path: _cashEntry['screenshot']!);
    await loader.load(
        payloadBucket: _upiEntry['bucket'], path: _upiEntry['screenshot']!);

    expect(signer.calls.map((c) => c.bucket).toList(),
        ['whatsapp-media', 'payment-proofs'],
        reason: 'one loader, two buckets, both from the payload');
  });

  test('the fetch is the signed call, never a public URL', () async {
    final signer = _FakeSigner();
    final loader = PaymentProofLoader(signer: signer.call);

    final res = await loader.load(
        payloadBucket: _cashEntry['bucket'], path: _cashEntry['screenshot']!);

    // The signer is the ONLY way this loader can produce a URL — there is no
    // other code path to reach for.
    expect(signer.calls, hasLength(1));
    // An hour-long signed URL, per the documented TTL.
    expect(signer.calls.single.expiresIn,
        PaymentProofLoader.kSignedUrlTtlSeconds);
    expect(signer.calls.single.expiresIn, 3600);
    // These buckets are private: a public-object URL cannot work.
    expect(res.url, contains('/object/sign/'));
    expect(res.url, isNot(contains('/object/public/')));
  });

  test('a failure logs the bucket, the path and the storage error', () async {
    final signer = _FakeSigner(fail: true);
    final log = _Log();
    final loader = PaymentProofLoader(signer: signer.call, logger: log.call);

    final res = await loader.load(
        payloadBucket: _cashEntry['bucket'], path: _cashEntry['screenshot']!);

    expect(res.ok, isFalse);
    expect(res.error, contains('400'));
    expect(log.joined, contains('bucket=whatsapp-media'));
    expect(log.joined, contains('path=cash_payments/cash_1785656698115.jpg'));
    expect(log.joined, contains('Bad Request'),
        reason: 'the storage message itself must reach the log');
  });

  test('a missing bucket is reported, never guessed', () async {
    final signer = _FakeSigner();
    final log = _Log();
    final loader = PaymentProofLoader(signer: signer.call, logger: log.call);

    final res = await loader.load(
        payloadBucket: null, path: 'cash_payments/cash_1785656698115.jpg');

    expect(res.ok, isFalse);
    expect(signer.calls, isEmpty,
        reason: 'the app must not invent a bucket from the path prefix');
    expect(log.joined, contains('c643_proof_no_bucket'));
  });

  test('retry re-requests — a failed load is not cached', () async {
    // Fails first, succeeds on the retry: exactly the "backend was fixed, now
    // tap retry" case that must work without a reinstall.
    var attempts = 0;
    Future<String> flaky(String bucket, String path, int ttl) async {
      attempts++;
      if (attempts == 1) throw Exception('403 Unauthorized');
      return 'https://x/storage/v1/object/sign/$bucket/$path?token=ok';
    }

    final loader = PaymentProofLoader(signer: flaky);

    final first = await loader.load(
        payloadBucket: 'whatsapp-media', path: 'cash_payments/a.jpg');
    expect(first.ok, isFalse);

    final second = await loader.load(
        payloadBucket: 'whatsapp-media', path: 'cash_payments/a.jpg');
    expect(second.ok, isTrue, reason: 'the retry must actually re-request');
    expect(attempts, 2);
  });
}

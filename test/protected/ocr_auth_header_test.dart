// CMD #2082 — the bulk-upload OCR request MUST carry Authorization.
//
// Every Bulk → Camera / Upload File call used to be a bare `http.post` with
// only `Content-Type`. The functions gateway runs with verify_jwt=true, so it
// answered 401 UNAUTHORIZED_NO_AUTH_HEADER before gemini-ocr ever ran and the
// customer saw "Something went wrong communicating with the AI service".
//
// This test holds the contract down without a network call: it drives the same
// OcrEdge door the bulk-upload screen calls and asserts what actually leaves
// the device — Authorization (the session JWT, or the anon key when signed
// out), apikey, the function name, and the body the function expects.
//
// It must never be "fixed" by making gemini-ocr public: verify_jwt stays on.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pharma_b2b/services/ocr_edge_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _fakeUrl = 'https://project.supabase.co/functions/v1';
const _anonKey = 'anon-key-jwt';
const _sessionJwt = 'session-access-token';

/// Records the request the functions client actually sends and replies with a
/// canned gemini-ocr payload.
class _RecordingClient extends http.BaseClient {
  http.BaseRequest? seen;
  String? seenBody;
  int status = 200;
  String responseBody = '{"text":"OK"}';
  String contentType = 'application/json';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    seen = request;
    if (request is http.Request) seenBody = request.body;
    final bytes = utf8.encode(responseBody);
    return http.StreamedResponse(
      Stream.value(bytes),
      status,
      headers: {'Content-Type': contentType},
      request: request,
    );
  }
}

void main() {
  late _RecordingClient recorder;

  void useClient({String? authToken}) {
    recorder = _RecordingClient();
    EdgeFn.clientOverride = () => FunctionsClient(
          _fakeUrl,
          {
            'Authorization': 'Bearer ${authToken ?? _anonKey}',
            'apikey': _anonKey,
          },
          httpClient: recorder,
        );
  }

  tearDown(() => EdgeFn.clientOverride = null);

  test('bulk upload OCR request carries Authorization and apikey', () async {
    useClient(authToken: _sessionJwt);

    final res = await OcrEdge.call(
      imageBase64: 'BASE64IMAGE',
      mimeType: 'image/jpeg',
      prompt: 'Extract the medicines',
    );

    final headers = recorder.seen!.headers;
    // The whole point of the change: the gateway sees a bearer token.
    expect(headers['Authorization'], 'Bearer $_sessionJwt');
    expect(headers['apikey'], _anonKey);
    expect(headers['Authorization'], isNot('Bearer '));

    // It is still the gemini-ocr function, with the body the function reads.
    expect(recorder.seen!.url.path, endsWith('/gemini-ocr'));
    final sent = jsonDecode(recorder.seenBody!) as Map<String, dynamic>;
    expect(sent['image_base64'], 'BASE64IMAGE');
    expect(sent['mime_type'], 'image/jpeg');
    expect(sent['prompt'], 'Extract the medicines');

    expect(res.statusCode, 200);
    expect(res.json['text'], 'OK');
  });

  test('signed-out upload still sends the anon key as Authorization', () async {
    useClient(); // no session — the functions client falls back to the anon key

    await OcrEdge.call(prompt: 'map these columns');

    expect(recorder.seen!.headers['Authorization'], 'Bearer $_anonKey');
    expect(recorder.seen!.headers['apikey'], _anonKey);
  });

  test('a 401 from the gateway surfaces as a non-200, never a throw', () async {
    useClient(authToken: _sessionJwt);
    recorder.status = 401;
    recorder.responseBody =
        '{"code":"UNAUTHORIZED_NO_AUTH_HEADER","message":"Missing authorization header"}';

    final res = await OcrEdge.call(prompt: 'anything');

    expect(res.statusCode, 401);
    expect(res.json['code'], 'UNAUTHORIZED_NO_AUTH_HEADER');
  });

  test('any other JSON edge call goes through the same authed door', () async {
    useClient(authToken: _sessionJwt);
    recorder.responseBody = '{"items":[],"stats":{"matched":0}}';

    final res = await EdgeFn.postJson('match-companies', {'supplier_id': 'S1'});

    expect(recorder.seen!.headers['Authorization'], 'Bearer $_sessionJwt');
    expect(recorder.seen!.headers['apikey'], _anonKey);
    expect(recorder.seen!.url.path, endsWith('/match-companies'));
    expect(jsonDecode(recorder.seenBody!)['supplier_id'], 'S1');
    expect(res.json['stats']['matched'], 0);
  });

  test('no screen posts to functions/v1 without the authed client', () {
    // A raw gateway URL in a screen is how #2082 happened. bill-pdf is the one
    // allowed exception (binary response) and carries the headers by hand.
    final offenders = <String>[];
    final dir = Directory('lib');
    for (final f in dir.listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      if (!src.contains('functions/v1')) continue;
      if (f.path.endsWith('orders_screen.dart') &&
          src.contains("'apikey': SupabaseConfig.anonKey")) {
        continue;
      }
      offenders.add(f.path);
    }
    expect(offenders, isEmpty,
        reason: 'call edge functions through EdgeFn/OcrEdge, not a raw URL');
  });
}

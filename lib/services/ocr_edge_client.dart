import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Authenticated client for the `gemini-ocr` edge function.
///
/// CMD #2082 — every Bulk → Camera / Upload File call used to be a bare
/// `http.post` carrying only `Content-Type`. The functions gateway runs with
/// `verify_jwt=true`, so it rejected the request before the function ever ran:
/// 401 `UNAUTHORIZED_NO_AUTH_HEADER`, surfaced to the customer as
/// "Something went wrong communicating with the AI service".
///
/// Going through `Supabase.instance.client.functions.invoke` is the fix: the
/// functions client always attaches `Authorization` (the signed-in session's
/// JWT, or the anon key when signed out) and `apikey`. The function stays
/// private — `verify_jwt` is NOT relaxed.
///
/// Call sites keep their old shape (`statusCode` / `body`), so the migration is
/// a one-line swap at each of them.
class OcrEdgeResponse {
  const OcrEdgeResponse(this.statusCode, this.body, this.json);

  /// HTTP-equivalent status: 200 on success, the gateway/function status on
  /// failure (401 when auth is missing, 500 when the function threw).
  final int statusCode;

  /// The raw JSON body, exactly as the old `http.Response.body` read.
  final String body;

  /// The decoded payload — `{}` when the function returned something unusable.
  final Map<String, dynamic> json;
}

/// Generic authed door to any JSON edge function.
///
/// Anything that posts JSON and reads JSON back goes through here, so the
/// gateway always sees `Authorization` + `apikey`. Binary responses (bill-pdf)
/// must NOT use this: the functions client utf8-decodes any non-JSON,
/// non-octet-stream body and would corrupt the bytes.
class EdgeFn {
  /// Test seam. Protected tests point this at a [FunctionsClient] built on a
  /// recording http client so the Authorization/apikey contract can be asserted
  /// without a network call. Production leaves it null.
  static FunctionsClient Function()? clientOverride;

  static FunctionsClient get client =>
      clientOverride?.call() ?? Supabase.instance.client.functions;

  static Future<OcrEdgeResponse> postJson(
    String functionName,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    try {
      final res =
          await client.invoke(functionName, body: body).timeout(timeout);
      final data = res.data;
      final map = data is Map
          ? Map<String, dynamic>.from(data)
          : (data is String && data.isNotEmpty
              ? _tryDecode(data)
              : <String, dynamic>{});
      return OcrEdgeResponse(res.status, jsonEncode(map), map);
    } on FunctionException catch (e) {
      final details = e.details;
      final map = details is Map
          ? Map<String, dynamic>.from(details)
          : <String, dynamic>{'error': details?.toString() ?? e.reasonPhrase};
      return OcrEdgeResponse(e.status, jsonEncode(map), map);
    }
  }

  static Map<String, dynamic> _tryDecode(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}

/// The one door to `gemini-ocr`. Never call the function over raw http:
/// the request is rejected at the gateway without these headers.
class OcrEdge {
  static const String functionName = 'gemini-ocr';

  /// Headers the functions client attaches to every invoke. Kept here so the
  /// protected test can assert the contract without a network call.
  static List<String> get requiredHeaders =>
      const ['Authorization', 'apikey', 'Content-Type'];

  static Future<OcrEdgeResponse> call({
    String imageBase64 = '',
    String mimeType = 'text/plain',
    required String prompt,
    String? mode,
    Duration timeout = const Duration(seconds: 60),
  }) {
    return EdgeFn.postJson(
      functionName,
      {
        'image_base64': imageBase64,
        'mime_type': mimeType,
        'prompt': prompt,
        if (mode != null) 'mode': mode,
      },
      timeout: timeout,
    );
  }
}

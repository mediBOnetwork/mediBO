// CHANGE #275 — the sign-in failure recorder.
//
// Google sign-in failed silently on the Play build: the platform error was
// swallowed by the "user cancelled" branch, and the only breadcrumbs went to
// render_log — whose singleton row is WIPED by the next web deploy. So a real
// device failure left literally no trace anywhere, and Supabase auth logs
// showed zero attempts because the flow died before any network call.
//
// This service is the durable channel. Every non-success outcome of the native
// Google flow is posted to `auth_diag_note`, together with the running APK's
// package name, versionCode and SIGNING CERTIFICATE SHA-1 — the one fact that
// separates a sideloaded build from the Play-re-signed one.
//
// The RPC answers with the wording to show ({show, tone, message}). Nothing
// here coins a sentence: if the backend says show:false the user sees nothing,
// and if it says show:true the app prints its string verbatim.
//
// Best-effort by construction: a diagnostic must never be the reason a sign-in
// fails, so every call is wrapped and a failure returns null.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// What the backend decided to show for a recorded failure.
typedef DiagAdvice = ({bool show, String? message, String? tone});

class SignInDiag {
  static const MethodChannel _channel =
      MethodChannel('in.medibo.app/signin_diag');

  /// CHANGE #279 — the OAuth client id the app actually sent, recorded with
  /// every failure and printed in the backend's sentence. The login screen sets
  /// it once before it calls the native flow, so the value on the row is the
  /// value that went to Google — not one re-read from a constant afterwards.
  static String? clientId;

  /// Cached device facts — one platform round-trip per app run.
  static Map<String, dynamic>? _facts;

  /// Test seam: the RPC and the platform channel are both replaceable so the
  /// protected test can assert what gets recorded with no Supabase and no
  /// Android.
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function(Map<String, dynamic> params)?
      rpcOverride;

  @visibleForTesting
  static Map<String, dynamic>? factsOverride;

  @visibleForTesting
  static void resetForTest() {
    rpcOverride = null;
    factsOverride = null;
    _facts = null;
    clientId = null;
  }

  static Future<Map<String, dynamic>> _deviceFacts() async {
    if (factsOverride != null) return factsOverride!;
    if (_facts != null) return _facts!;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return _facts = const <String, dynamic>{};
    }
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
          'deviceFacts');
      return _facts = raw == null
          ? const <String, dynamic>{}
          : raw.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return _facts = const <String, dynamic>{};
    }
  }

  /// Records one failed sign-in attempt and returns the backend's advice.
  ///
  /// [code] is the REAL platform code (GoogleSignInExceptionCode.name, or one
  /// of the app's own stage codes such as `no_id_token`), never a rewording.
  static Future<DiagAdvice?> note({
    required String stage,
    required String code,
    String? description,
    String? details,
    int? elapsedMs,
  }) async {
    try {
      final facts = await _deviceFacts();
      final params = <String, dynamic>{
        'p_platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
        'p_stage': stage,
        'p_code': code,
        'p_description': description,
        'p_details': details,
        'p_elapsed_ms': elapsedMs,
        'p_app_version': facts['version_name'],
        'p_version_code': facts['version_code'],
        'p_package_name': facts['package_name'],
        'p_signing_sha1': facts['signing_sha1'],
        // CHANGE #279 — everything needed to settle a certificate argument in
        // one row: the current signer's SHA-256, where Android says the APK was
        // installed from, and the client id that was sent.
        'p_signing_sha256': facts['signing_sha256'],
        'p_install_source': facts['install_source'],
        'p_client_id': clientId,
        'p_extra': <String, dynamic>{
          if (facts['android_sdk'] != null) 'android_sdk': facts['android_sdk'],
          if (facts['signers_sha1'] != null)
            'signers_sha1': facts['signers_sha1'],
          if (facts['history_sha1'] != null)
            'history_sha1': facts['history_sha1'],
          if (facts['has_multiple_signers'] != null)
            'has_multiple_signers': facts['has_multiple_signers'],
          if (facts['facts_error'] != null)
            'facts_error': facts['facts_error'],
        },
      };

      final Map<String, dynamic>? reply = rpcOverride != null
          ? await rpcOverride!(params)
          : _asMap(await Supabase.instance.client
              .rpc('auth_diag_note', params: params));
      if (reply == null) return null;
      final msg = reply['message'];
      return (
        show: reply['show'] == true,
        message: msg is String && msg.isNotEmpty ? msg : null,
        tone: reply['tone'] as String?,
      );
    } catch (_) {
      // Never let the recorder break the flow it is recording.
      return null;
    }
  }

  static Map<String, dynamic>? _asMap(dynamic v) =>
      v is Map ? v.cast<String, dynamic>() : null;
}

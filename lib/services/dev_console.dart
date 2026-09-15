// CHANGE #1761 — the dev-queue control plane lives on its own Supabase project
// (medibo-dev). The Dev Queue screens keep RENDERING exactly as before; the only
// thing that changed is WHICH project their RPCs are sent to.
//
// How the screen gets there, with no dev URL or key in Dart:
//   1. production's `dev_console_token()` (super admin only) hands back the dev
//      project's url + anon key and a short-lived HMAC token;
//   2. a second SupabaseClient is built from that payload with the token as the
//      `x-dev-console` header;
//   3. medibo-dev's `_dev_guard()` verifies the header with the same vault secret.
// The token's life is the backend's (`exp`); this class only re-mints when the
// backend says it is about to expire.
import 'package:supabase_flutter/supabase_flutter.dart';

/// One minted ticket. Everything in it came from `dev_console_token()`.
class DevConsoleToken {
  const DevConsoleToken({
    required this.token,
    required this.exp,
    required this.url,
    required this.anonKey,
    required this.email,
  });

  factory DevConsoleToken.fromPayload(Map<String, dynamic> p) {
    final exp = p['exp'];
    return DevConsoleToken(
      token: (p['token'] ?? '').toString(),
      exp: exp is num ? exp.toInt() : int.tryParse('$exp') ?? 0,
      url: (p['url'] ?? '').toString(),
      anonKey: (p['anon_key'] ?? '').toString(),
      email: (p['email'] ?? '').toString(),
    );
  }

  final String token;

  /// Unix seconds, as minted by production.
  final int exp;
  final String url;
  final String anonKey;
  final String email;

  static const String headerName = 'x-dev-console';

  bool get isUsable => token.isNotEmpty && url.isNotEmpty && anonKey.isNotEmpty;

  /// Re-mint when less than [margin] of the backend-issued life remains.
  bool needsRefresh(DateTime now, {Duration margin = const Duration(minutes: 10)}) {
    final nowS = now.toUtc().millisecondsSinceEpoch ~/ 1000;
    return nowS >= exp - margin.inSeconds;
  }

  Map<String, String> get headers => {headerName: token};
}

/// How a ticket is minted — the production RPC by default, a fake in tests.
typedef DevConsoleMinter = Future<Map<String, dynamic>> Function();

/// Owns the medibo-dev client for the whole app: one ticket, re-minted only when
/// the backend's `exp` says so.
class DevConsole {
  DevConsole({DevConsoleMinter? mint, DateTime Function()? clock})
      : _mint = mint ?? _rpcMint,
        _clock = clock ?? DateTime.now;

  static final DevConsole instance = DevConsole();

  final DevConsoleMinter _mint;
  final DateTime Function() _clock;

  DevConsoleToken? _token;
  SupabaseClient? _client;
  int _mints = 0;

  /// Tickets minted so far (tests read this to prove caching).
  int get mints => _mints;

  DevConsoleToken? get token => _token;

  static Future<Map<String, dynamic>> _rpcMint() async {
    final raw = await Supabase.instance.client.rpc('dev_console_token');
    final v = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  /// The client every Dev Queue RPC goes through. Errors from the minting RPC
  /// are rethrown untouched — the screen shows the backend's own words.
  Future<SupabaseClient> client() async {
    final t = _token;
    if (t != null && t.isUsable && !t.needsRefresh(_clock()) && _client != null) {
      return _client!;
    }
    final fresh = DevConsoleToken.fromPayload(await _mint());
    if (!fresh.isUsable) {
      throw StateError('dev_console_token returned no usable ticket');
    }
    _mints += 1;
    _client?.dispose();
    _token = fresh;
    _client = SupabaseClient(fresh.url, fresh.anonKey, headers: fresh.headers);
    return _client!;
  }

  /// Forget the ticket (sign-out, or a 401 from medibo-dev).
  void reset() {
    _client?.dispose();
    _client = null;
    _token = null;
  }
}

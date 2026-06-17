import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models/user_profile.dart';
import 'services/gis_auth.dart' show gisSignInWithNonce, isMobileWeb;
import 'utils/render_log.dart';

class AuthNotifier extends ChangeNotifier {
  UserProfile? _profile;
  bool _loading = true;
  bool _profileLoading = false;
  bool _needsProfile = false;
  bool _isAdmin = false;
  bool _isSuperAdmin = false;
  // Supplier role state
  bool _isSupplier = false;
  String? _supplierName;
  String? _supplierId;
  String? _supplierStatus; // 'ok'|'pending_approval'|'not_found'|'conflict'
  RealtimeChannel? _profileChannel;
  int _initStartMs = 0;

  bool get loading => _loading;
  bool get profileLoading => _profileLoading;
  bool get needsProfile => _needsProfile;
  bool get isAdmin => _isAdmin;
  bool get isSuperAdmin => _isSuperAdmin;
  bool get isSupplier => _isSupplier;
  String? get supplierName => _supplierName;
  String? get supplierId => _supplierId;
  String? get supplierStatus => _supplierStatus;
  bool get isAuthenticated =>
      Supabase.instance.client.auth.currentUser != null;
  UserProfile? get profile => _profile;

  /// True when logged in AND has submitted a pharmacy_profiles row.
  bool get isRegistered => isAuthenticated && _profile != null;

  /// True when registered AND admin has approved the account AND not suspended.
  bool get canOrder => isRegistered &&
      (_profile?.isApproved ?? false) &&
      (_profile?.status != 'suspended');

  late final StreamSubscription<AuthState> _sub;
  // Prevents _init() and initialSession from both finalising loading state.
  bool _initDone = false;

  AuthNotifier() {
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen(_onAuthChange);
    _init();
  }

  // Fire-and-forget tracer — writes one row per event to auth_debug_log via RPC.
  // postgrest-dart Futures are LAZY: .then() must be called to materialize the
  // HTTP request; a bare unawaited rpc() call sends nothing.
  void _trace(String event, String detail) {
    try {
      final s = Supabase.instance.client.auth.currentSession;
      Supabase.instance.client.rpc('log_auth_debug', params: {
        'p_email': s?.user.email ??
            (Supabase.instance.client.auth.currentUser?.email ?? ''),
        'p_event': event,
        'p_detail': detail,
      // ignore: unnecessary_lambdas
      }).then((_) {}).catchError((_) {});
    } catch (_) {}
  }

  // Fast-path: if currentUser is already available synchronously (SDK restored
  // session before AuthNotifier was created), resolve loading immediately.
  // Otherwise gate on _onAuthChange(initialSession) which fires from BehaviorSubject.
  Future<void> _init() async {
    _initStartMs = DateTime.now().millisecondsSinceEpoch;
    RenderLog.write('auth55_flow', 'implicit');
    final session = Supabase.instance.client.auth.currentSession;
    final user = session?.user ?? Supabase.instance.client.auth.currentUser;
    RenderLog.write('auth55_init_user', user?.email ?? 'null');
    if (user != null && !_initDone) {
      _initDone = true;
      final waitedMs = DateTime.now().millisecondsSinceEpoch - _initStartMs;
      _trace('boot',
          '${RenderLog.authStorageInfo()}; '
          'getSession=yes; mem=yes; initEvent=sync; gate=in; '
          'waitedMs=$waitedMs; flow=implicit; build=${RenderLog.buildHash}; change=60');
      RenderLog.write('auth55_restore',
          'initialSession user=${user.email ?? 'null'}; logged_in=true; from=restored_session');
      try {
        await Future.wait([
          _loadProfile(user.id),
          _resolveRole(user.email ?? ''),
        ]);
      } catch (_) {
        // Profile/role failure must NOT clear the session.
      }
      if (_loading) {
        _loading = false;
        RenderLog.write('auth54_stuck_guard', 'loading_cleared');
        notifyListeners();
      }
    }
    // If user is null: session may still be restoring asynchronously.
    // _onAuthChange(initialSession) will fire via BehaviorSubject replay and
    // handle the gate decision — including a recovery attempt if lskeys found.
  }

  void _onAuthChange(AuthState state) async {
    // initialSession fires on every startup — BehaviorSubject replays it to
    // new subscribers. This is the definitive auth gate: if SDK restored a
    // session it's in currentSession; if it failed, we attempt manual recovery.
    if (state.event == AuthChangeEvent.initialSession) {
      if (_initDone) return; // fast-path in _init() already handled it
      _initDone = true;
      final waitedMs = DateTime.now().millisecondsSinceEpoch - _initStartMs;
      try {
        Session? session = Supabase.instance.client.auth.currentSession ?? state.session;
        User? user = session?.user;
        String recoveryResult = 'none';

        // Recovery: if SDK couldn't restore the session (setInitialSession threw)
        // but the auth token is still in localStorage, try explicit token refresh.
        // This uphold the INVARIANT: lskeys found → gate=in after cold reopen.
        if (user == null) {
          final lsRaw = RenderLog.getRawAuthSession();
          if (lsRaw != null) {
            try {
              final parsed = jsonDecode(lsRaw) as Map<String, dynamic>;
              final refreshToken = parsed['refresh_token'] as String?;
              if (refreshToken != null && refreshToken.isNotEmpty) {
                final resp = await Supabase.instance.client.auth.setSession(refreshToken);
                session = resp.session;
                user = session?.user;
                recoveryResult = user != null ? 'ok' : 'no_user';
              } else {
                recoveryResult = 'no_refresh';
              }
            } catch (_) {
              recoveryResult = 'failed';
            }
          }
        }

        final gate = user != null ? 'in' : 'out';
        _trace('boot',
            '${RenderLog.authStorageInfo()}; '
            'getSession=${session != null ? 'yes' : 'no'}; '
            'mem=${user != null ? 'yes' : 'no'}; '
            'initEvent=initialSession; gate=$gate; '
            'recovery=$recoveryResult; '
            'waitedMs=$waitedMs; flow=implicit; '
            'build=${RenderLog.buildHash}; change=60');

        if (user != null) {
          RenderLog.write('auth_email', user.email ?? 'unknown');
          RenderLog.write('auth55_restore',
              'initialSession user=${user.email ?? 'null'}; logged_in=true; from=restored_session');
          try {
            await Future.wait([
              _loadProfile(user.id),
              _resolveRole(user.email ?? ''),
            ]);
          } catch (_) {
            // Profile/role failure must NOT clear the session.
          }
        }
      } finally {
        if (_loading) {
          _loading = false;
          RenderLog.write('auth54_stuck_guard', 'loading_cleared');
          notifyListeners();
        }
      }
      return;
    }

    // Allow signedIn/tokenRefreshed to break through the loading guard when a
    // session is present — this handles the implicit-flow case where the SDK
    // fires signedIn AFTER initialSession(null) during the OAuth callback.
    final isSignIn = state.event == AuthChangeEvent.signedIn ||
        state.event == AuthChangeEvent.tokenRefreshed;
    final hasSession = state.session != null ||
        Supabase.instance.client.auth.currentSession != null;
    if (_loading && !(isSignIn && hasSession)) {
      RenderLog.write('auth55_event_blocked', '${state.event.name}_blocked_by_loading');
      return;
    }

    if (state.event == AuthChangeEvent.signedIn ||
        state.event == AuthChangeEvent.tokenRefreshed) {
      RenderLog.write('auth55_signed_in', 'event_received; loading_was=$_loading');
      final session = state.session ?? Supabase.instance.client.auth.currentSession;
      // Belt-and-suspenders: explicitly write the session to localStorage under
      // the SDK's own key so a cold reopen always finds it, regardless of whether
      // the SDK's async persist stream ran before the tab was closed.
      if (session != null) {
        try {
          RenderLog.persistAuthSession(jsonEncode(session.toJson()));
        } catch (_) {}
      }
      _trace('signedIn',
          '${RenderLog.authStorageInfo()}; '
          'mem=${session != null ? 'yes' : 'no'}; '
          'hasRefresh=${session?.refreshToken != null && (session!.refreshToken?.isNotEmpty ?? false)}; '
          'build=${RenderLog.buildHash}; change=60');
      final user = session?.user ?? Supabase.instance.client.auth.currentUser;
      if (user != null) {
        RenderLog.write('auth_email', user.email ?? 'unknown');
        if (_loading) {
          // We broke through the guard — take over loading state.
          _initDone = true;
          await Future.wait([
            _loadProfile(user.id),
            _resolveRole(user.email ?? ''),
          ]);
          _loading = false;
          notifyListeners();
        } else {
          _profileLoading = true;
          notifyListeners();
          await Future.wait([
            _loadProfile(user.id),
            _resolveRole(user.email ?? ''),
          ]);
          _profileLoading = false;
          notifyListeners();
        }
      } else if (_loading) {
        _loading = false;
        notifyListeners();
      }
    } else if (state.event == AuthChangeEvent.signedOut) {
      _profile = null;
      _needsProfile = false;
      _profileLoading = false;
      _isAdmin = false;
      _isSuperAdmin = false;
      _isSupplier = false;
      _supplierName = null;
      _supplierId = null;
      _supplierStatus = null;
      _profileChannel?.unsubscribe();
      _profileChannel = null;
      _trace('signedOut', 'app cleared state');
      RenderLog.write('auth_email', 'signed_out');
      RenderLog.write('auth_role', 'none');
      notifyListeners();
    }
  }

  Future<void> _loadProfile(String userId) async {
    try {
      final res = await Supabase.instance.client
          .from('pharmacy_profiles')
          .select()
          .eq('user_id', userId)
          .maybeSingle();
      if (res != null) {
        _profile = UserProfile.fromJson(res);
        _needsProfile = false;
      } else {
        _profile = null;
        _needsProfile = true;
      }
    } catch (_) {
      _needsProfile = true;
    }
    _subscribeProfileRealtime(userId);
  }

  void _subscribeProfileRealtime(String userId) {
    _profileChannel?.unsubscribe();
    final ts = DateTime.now().millisecondsSinceEpoch;
    _profileChannel = Supabase.instance.client
        .channel('user_profile_$ts')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'pharmacy_profiles',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) async {
            final newRecord = payload.newRecord;
            if (newRecord.isNotEmpty) {
              _profile = UserProfile.fromJson(newRecord);
              notifyListeners();
            } else {
              await _loadProfileSilent(userId);
            }
          },
        )
        .subscribe();
  }

  Future<void> _loadProfileSilent(String userId) async {
    try {
      final res = await Supabase.instance.client
          .from('pharmacy_profiles')
          .select()
          .eq('user_id', userId)
          .maybeSingle();
      if (res != null) {
        _profile = UserProfile.fromJson(res);
        notifyListeners();
      }
    } catch (_) {}
  }

  // DB-authoritative role resolution via get_my_role() RPC.
  // Precedence: super_admin > admin > supplier > customer > none.
  // No hardcoded email constants — the DB is the single source of truth.
  Future<void> _resolveRole(String email) async {
    if (email.isEmpty) {
      _isAdmin = false;
      _isSuperAdmin = false;
      _isSupplier = false;
      _supplierName = null;
      _supplierId = null;
      _supplierStatus = null;
      return;
    }
    try {
      final role = await Supabase.instance.client.rpc('get_my_role') as String;
      RenderLog.write('auth_role', role);
      _isAdmin = role == 'super_admin' || role == 'admin';
      _isSuperAdmin = role == 'super_admin';
      _isSupplier = false;
      _supplierName = null;
      _supplierId = null;
      _supplierStatus = null;

      if (!_isAdmin) {
        // Resolve supplier details (approved or pending).
        await _checkSupplierStatus(email);
      }
    } catch (_) {
      _isAdmin = false;
      _isSuperAdmin = false;
      _isSupplier = false;
      _supplierStatus = null;
    }
  }

  // Resolve supplier role by calling claim_supplier_profile RPC.
  Future<void> _checkSupplierStatus(String email) async {
    try {
      final res = await Supabase.instance.client
          .rpc('claim_supplier_profile', params: {'p_email': email}) as Map;
      final status = res['status'] as String? ?? 'not_found';
      _supplierStatus = status;
      if (status == 'ok') {
        _isSupplier = true;
        _supplierName = res['supplier_name'] as String?;
        _supplierId   = res['id'] as String?;
      } else {
        _isSupplier = false;
        _supplierName = status == 'pending_approval' ? res['supplier_name'] as String? : null;
        _supplierId   = null;
      }
    } catch (_) {
      _isSupplier = false;
      _supplierStatus = null;
    }
  }

  Future<void> saveProfile(UserProfile profile) async {
    await Supabase.instance.client
        .from('pharmacy_profiles')
        .upsert(profile.toInsertJson(), onConflict: 'user_id');
    _profile = profile;
    _needsProfile = false;
    notifyListeners();
  }

  Future<void> signInWithGoogle() async {
    if (isMobileWeb()) {
      // Mobile: straight redirect OAuth with implicit flow.
      // Do NOT signOut before redirect — the code_verifier created by PKCE would
      // be lost across the redirect boundary on mobile in-app browsers, causing
      // bad_code_verifier. Implicit flow returns tokens in the URL fragment instead.
      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: 'https://medibo.in',
        queryParams: {'prompt': 'select_account'},
      );
      RenderLog.write('auth55_oauth_initiated', 'google redirect; response_type=expected_token');
    } else {
      // Desktop: GIS id-token popup (FedCM-enabled) + nonce pair.
      //   hashedNonce → GIS initialize (embedded in JWT nonce claim by Google)
      //   rawNonce    → Supabase signInWithIdToken (Supabase re-hashes to verify)
      final gis = await gisSignInWithNonce();
      RenderLog.write('nonce_pair_ok', true);
      await Supabase.instance.client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: gis.idToken,
        nonce: gis.rawNonce,
      );
      RenderLog.write('google_idtoken_exchange_ok', true);
      final email = Supabase.instance.client.auth.currentUser?.email ?? 'unknown';
      RenderLog.write('auth54_login_ok', 'method=google_idtoken; user=$email');
    }
  }

  Future<void> signOut() async {
    RenderLog.write('auth54_signout', 'scope=local; reason=manual_logout');
    await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
  }

  @override
  void dispose() {
    _sub.cancel();
    _profileChannel?.unsubscribe();
    super.dispose();
  }
}

/// Exposes [AuthNotifier] to the widget tree. Rebuilds dependents on change.
class UserState extends InheritedNotifier<AuthNotifier> {
  const UserState({
    super.key,
    required AuthNotifier notifier,
    required super.child,
  }) : super(notifier: notifier);

  static AuthNotifier of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<UserState>();
    assert(s != null, 'UserState not found in widget tree');
    return s!.notifier!;
  }

  /// One-shot read without subscribing to changes.
  static AuthNotifier read(BuildContext context) {
    final s = context.getInheritedWidgetOfExactType<UserState>();
    assert(s != null, 'UserState not found in widget tree');
    return s!.notifier!;
  }
}

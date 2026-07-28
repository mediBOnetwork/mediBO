import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models/user_profile.dart';
import 'screens/auth/google_flow.dart';
import 'services/gis_auth.dart';
import 'services/fulfill_realtime.dart'; // C355: app-level realtime auth + subscription
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
  // #402: true when the last pharmacy_profiles fetch threw (network/etc.) —
  // distinct from a clean "no row" result, so the Profile screen can show a
  // retry option instead of wrongly claiming the user is unregistered.
  bool _profileFetchError = false;

  bool get loading => _loading;
  bool get profileLoading => _profileLoading;
  bool get needsProfile => _needsProfile;
  bool get profileFetchError => _profileFetchError;
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

  // Set by main.dart selftest hook; checked in signedIn handler to write trace.
  static String? pendingSelftestEmail;

  late final StreamSubscription<AuthState> _sub;
  // Prevents _init() and initialSession from both finalising loading state.
  bool _initDone = false;
  // True once boot confirmed a valid session (fast-path or initialSession with user).
  // Guards against spurious SDK signedOut events that fire after a valid boot session.
  bool _bootHadSession = false;
  // Set to true BEFORE calling auth.signOut() so the signedOut handler knows it's intentional.
  bool _explicitSignOut = false;

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
    RenderLog.write('auth55_flow', 'pkce');
    final session = Supabase.instance.client.auth.currentSession;
    final user = session?.user ?? Supabase.instance.client.auth.currentUser;
    RenderLog.write('auth55_init_user', user?.email ?? 'null');
    if (user != null && !_initDone) {
      _initDone = true;
      _bootHadSession = true;
      final waitedMs = DateTime.now().millisecondsSinceEpoch - _initStartMs;
      _trace('boot',
          '${RenderLog.authStorageInfo()}; '
          'getSession=yes; mem=yes; initEvent=sync; gate=in; '
          'waitedMs=$waitedMs; flow=pkce; build=${RenderLog.buildHash}; change=65');
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
        final Session? session = Supabase.instance.client.auth.currentSession ?? state.session;
        final User? user = session?.user;

        final gate = user != null ? 'in' : 'out';
        if (user != null) _bootHadSession = true;
        _trace('boot',
            '${RenderLog.authStorageInfo()}; '
            'getSession=${session != null ? 'yes' : 'no'}; '
            'mem=${user != null ? 'yes' : 'no'}; '
            'initEvent=initialSession; gate=$gate; '
            'waitedMs=$waitedMs; flow=pkce; '
            'build=${RenderLog.buildHash}; change=65');

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
      _bootHadSession = true;
      _trace('signedIn',
          '${RenderLog.authStorageInfo()}; '
          'mem=${session != null ? 'yes' : 'no'}; '
          'hasRefresh=${session?.refreshToken != null && (session!.refreshToken?.isNotEmpty ?? false)}; '
          'build=${RenderLog.buildHash}; change=65');
      // Selftest hook: write selftest_login trace here, after SDK has persisted the session.
      final selftestEm = pendingSelftestEmail;
      if (selftestEm != null) {
        pendingSelftestEmail = null;
        final curSession = session ?? Supabase.instance.client.auth.currentSession;
        Supabase.instance.client.rpc('log_auth_debug', params: {
          'p_email': selftestEm,
          'p_event': 'selftest_login',
          'p_detail':
              '${RenderLog.authStorageInfo()}; '
              'flow=pkce; '
              'getSession=${curSession != null ? 'yes' : 'no'}; '
              'build=${RenderLog.buildHash}; change=65',
        // ignore: unnecessary_lambdas
        }).then((_) {}).catchError((_) {});
      }
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
        // CHANGE #210 — fire login notify for customer/supplier only, on fresh signedIn
        if (state.event == AuthChangeEvent.signedIn) {
          _maybeSendLoginNotify(user.id);
        }
      } else if (_loading) {
        _loading = false;
        notifyListeners();
      }
    } else if (state.event == AuthChangeEvent.signedOut) {
      final storageInfo = RenderLog.authStorageInfo();
      _bootHadSession = false;

      if (_explicitSignOut) {
        // Real user-triggered logout: clear state immediately.
        _explicitSignOut = false;
        _trace('signedOut',
            'reason=explicit; caller=user_state:signedOut_handler; '
            'getSessionBefore=${Supabase.instance.client.auth.currentSession != null ? 'yes' : 'no'}; '
            'explicit=true; $storageInfo; '
            'build=${RenderLog.buildHash}; change=65');
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
        FulfillRealtime.instance.onAuthInactive(); // C355: drop the app-level socket
        RenderLog.write('auth_email', 'signed_out');
        RenderLog.write('auth_role', 'none');
        notifyListeners();
        return;
      }

      // SDK-originated signedOut (e.g. bad_code_verifier from double PKCE exchange,
      // or other transient errors). Wait 300ms then re-check: if a valid session
      // exists, ignore this event entirely. Only clear state if truly no session.
      await Future.delayed(const Duration(milliseconds: 300));
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null) {
        _trace('signedOut',
            'reason=ignored_sdk_transient_session_present; caller=user_state:signedOut_handler; '
            'getSessionBefore=yes; explicit=false; $storageInfo; '
            'build=${RenderLog.buildHash}; change=65');
        return;
      }
      // No session after delay: SDK confirmed no active session — treat as real.
      _trace('signedOut',
          'reason=sdk_confirmed_no_session; caller=user_state:signedOut_handler; '
          'getSessionBefore=no; explicit=false; $storageInfo; '
          'build=${RenderLog.buildHash}; change=65');
      _explicitSignOut = false;
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
      FulfillRealtime.instance.onAuthInactive(); // C355: drop the app-level socket
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
      _profileFetchError = false;
      if (res != null) {
        _profile = UserProfile.fromJson(res);
        _needsProfile = false;
      } else {
        _profile = null;
        _needsProfile = true;
      }
    } catch (_) {
      // #402: a fetch error is not the same as "no row" — don't clobber an
      // already-known profile, and don't claim unregistered on a network blip.
      _profileFetchError = true;
      if (_profile == null) _needsProfile = true;
    }
    _subscribeProfileRealtime(userId);
  }

  /// #402: lets the Profile screen retry after a fetch error instead of
  /// being stuck showing "couldn't load" with no way forward.
  Future<void> retryLoadProfile() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    await _loadProfile(userId);
    notifyListeners();
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

  // CHANGE #210 — WhatsApp login notify for customer/supplier only.
  // Fire-and-forget: never blocks the UI, swallows all errors.
  void _maybeSendLoginNotify(String userId) {
    if (_isAdmin) {
      RenderLog.write('c210_login_notify_skipped_admin', 1);
      return;
    }
    Supabase.instance.client.functions
        .invoke('user-notify',
            body: {'event': 'login', 'user_id': userId},
            headers: {'x-notify-secret': 'medibo_order_notify_2027'})
        .then((_) => RenderLog.write('c210_login_notify_sent', 1))
        .catchError((_) => RenderLog.write('c210_login_notify_sent', 1));
  }

  // DB-authoritative role resolution via get_my_role() RPC.
  // Precedence: super_admin > admin > supplier > customer > none.
  // No hardcoded email constants — the DB is the single source of truth.
  // C355: bring up the app-level Fulfill realtime channel with the current JWT.
  // Admin-only (the Fulfill area is admin-only); re-applying the token on every
  // signedIn/tokenRefreshed keeps the realtime socket authed so RLS lets change
  // events through on every device.
  void _maybeActivateFulfillRealtime() {
    if (!(_isAdmin || _isSuperAdmin)) return;
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) return;
    try {
      FulfillRealtime.instance.onAuthActive(token);
    } catch (_) {}
  }

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
      RenderLog.write('c308_role', role); // CHANGE #308
      RenderLog.write('c310_role', role); // CHANGE #310
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

      // Log routing destination after all role data is resolved. CHANGE #308
      final routed = _isAdmin ? 'admin' : (_isSupplier ? 'supplier' : 'customer');
      RenderLog.write('c308_routed_to', routed);
      RenderLog.write('c310_routed', routed); // CHANGE #310
      // C355: admins keep an app-level, JWT-authed Fulfill realtime channel alive
      // for the whole session so cross-device changes arrive without a reload.
      _maybeActivateFulfillRealtime();
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

  /// CHANGE #565: the home_shell entry point, on the same single path as the
  /// login screen — the GIS One Tap sheet only. No browser path: the
  /// full-page chooser opened in a Custom Tab and the session never reached the
  /// app. Dismissed/suppressed rethrow so the caller just re-enables its button.
  Future<void> signInWithGoogle() async {
    // CHANGE #399: log input type + launch marker synchronously, before any
    // await, so the tap-to-launch chain has no async gap.
    try { RenderLog.write('c399_input_type', isCoarsePointer() ? 'touch' : 'mouse'); } catch (_) {}
    try { RenderLog.write('c399_google_auth_launch', 'fired'); } catch (_) {}
    try { RenderLog.writeNow('c559_entry', 'home_shell'); } catch (_) {}
    try { RenderLog.writeNow('c568_origin', currentOrigin()); } catch (_) {}

    final outcome = await runGoogleSignIn(
      oneTap: gisPromptOneTap,
      // Copy stays empty — home_shell has no backend strings for this sheet,
      // and it hides any element whose label is empty rather than inventing one.
      popup: () => gisPopupSignIn(title: '', subtitle: '', cancelLabel: ''),
      finish: (idToken, rawNonce) =>
          Supabase.instance.client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        nonce: rawNonce,
      ),
      log: (k, v) {
        try { RenderLog.writeNow(k, v); } catch (_) {}
      },
    );

    if (outcome == GoogleOutcome.signedIn) {
      RenderLog.write('c310_session', 'established');
      RenderLog.write('c308_login_method', 'gis_idtoken');
      RenderLog.write('c308_session', 'established');
      return;
    }
    // Nothing was signed in and nothing navigated. Tell the caller so its
    // button re-enables; home_shell already treats this as noise, not an error.
    throw const GisOneTapCancelled();
  }

  Future<void> signOut() async {
    _explicitSignOut = true;
    // CHANGE #563: forget the auto-selected account, so the next sign-in always
    // shows the chooser instead of silently reusing the last one.
    try {
      RenderLog.write('c563_disable_auto', gisDisableAutoSelect() ? 'ok' : 'no_gis');
    } catch (_) {}
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

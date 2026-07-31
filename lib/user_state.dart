import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models/app_session.dart';
import 'screens/auth/google_flow.dart';
import 'services/gis_auth.dart';
import 'services/delivery_role_state.dart'; // C629: is this login a delivery account?
import 'services/fulfill_realtime.dart'; // C355: app-level realtime auth + subscription
import 'utils/render_log.dart';

/// CHANGE #571 — ONE question, ONE answer.
///
/// Before this change AuthNotifier asked the backend the same question three
/// different ways on every sign-in:
///   1. `get_my_role()`            -> then re-derived isAdmin in Dart
///   2. `claim_supplier_profile()` -> then re-derived isSupplier in Dart
///   3. a direct `pharmacy_profiles` select keyed on **user_id** (the LOGIN,
///      not the account) -> then re-derived isRegistered / canOrder in Dart
///
/// Three answers to one question is precisely the disagreement that let admin
/// sessions open customer screens, and that made a fully registered customer
/// read as "Not Registered" after a Google login (the profile row's user_id
/// pointed at a different credential).
///
/// Now: a single `my_session()` call. Every getter below is a straight read of
/// that payload. Nothing on this class branches on `role`, and nothing here
/// keys account data to `auth.currentUser`.
class AuthNotifier extends ChangeNotifier {
  AppSession _session = AppSession.signedOut;
  bool _loading = true;
  bool _profileLoading = false;
  bool _sessionFetchError = false;
  RealtimeChannel? _profileChannel;
  int _initStartMs = 0;

  /// The whole answer. Widgets should prefer this over the shims below.
  AppSession get session => _session;

  bool get loading => _loading;
  bool get profileLoading => _profileLoading;

  /// #402: true when the last my_session() fetch threw (network/etc.) — which
  /// is NOT the same as a clean "no account" answer, so the Profile screen can
  /// offer a retry instead of wrongly claiming the user is unregistered.
  bool get sessionFetchError => _sessionFetchError;
  bool get profileFetchError => _sessionFetchError;

  // ── Backend booleans, read not derived. ─────────────────────────────────
  bool get isAdmin => _session.isAdmin;
  bool get isSuperAdmin => _session.isSuperAdmin;
  bool get isSupplier => _session.isSupplier;
  String get supplierName => _session.supplierName;
  String get supplierId => _session.supplierId;
  String get supplierStatus => _session.supplierStatus;
  bool get isPendingSupplier => _session.isPendingSupplier;
  bool get needsProfile => _session.needsProfile;

  /// True when this ACCOUNT has a customer profile. Not "approved" — for that
  /// the backend ships [canOrder]. Keeping these apart is deliberate.
  bool get isRegistered => _session.hasCustomerAccount;

  /// THE ordering boolean. Never recomputed from approval + suspension here.
  bool get canOrder => _session.canPlaceOrder;

  /// The decided, pre-worded gate. Widgets print it; they never compose it.
  OrderGate get orderGate => _session.orderGate;
  BulkWaGate get bulkWaGate => _session.bulkWaGate;

  /// Display name with the backend's own fallback ('My Account'), so no Dart
  /// string is invented when a name is missing.
  String get headerTitle => _session.headerTitle;
  String get displayName => _session.displayName;
  String get statusLabel => _session.statusLabel;

  /// A credential exists. Deliberately NOT an account test — use [isRegistered]
  /// or [session].ownerId for anything about the account.
  bool get isAuthenticated =>
      Supabase.instance.client.auth.currentUser != null;

  /// RULE 4 mismatch guard — true when the cached session was resolved against
  /// the auth user that is live right now. Anything account-shaped must refuse
  /// to render when this is false.
  bool get matchesAuthUser {
    final live = Supabase.instance.client.auth.currentUser?.id ?? '';
    if (!_session.signedIn) return live.isEmpty;
    return live.isNotEmpty && live == _session.authUserId;
  }

  /// RULE 6 — which surfaces may render. The backend decided; this only
  /// applies the mismatch guard on top.
  AccountSurface get surface =>
      _session.surface(matchesAuthUser: matchesAuthUser);

  // Set by main.dart selftest hook; checked in signedIn handler to write trace.
  static String? pendingSelftestEmail;

  late final StreamSubscription<AuthState> _sub;
  // Prevents _init() and initialSession from both finalising loading state.
  bool _initDone = false;
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
      final waitedMs = DateTime.now().millisecondsSinceEpoch - _initStartMs;
      _trace('boot',
          '${RenderLog.authStorageInfo()}; '
          'getSession=yes; mem=yes; initEvent=sync; gate=in; '
          'waitedMs=$waitedMs; flow=pkce; build=${RenderLog.buildHash}; change=571');
      RenderLog.write('auth55_restore',
          'initialSession user=${user.email ?? 'null'}; logged_in=true; from=restored_session');
      try {
        await _loadSession();
      } catch (_) {
        // Session fetch failure must NOT clear the credential.
      }
      if (_loading) {
        _loading = false;
        RenderLog.write('auth54_stuck_guard', 'loading_cleared');
        notifyListeners();
      }
    }
    // If user is null: session may still be restoring asynchronously.
    // _onAuthChange(initialSession) will fire via BehaviorSubject replay and
    // handle the gate decision.
  }

  void _onAuthChange(AuthState state) async {
    // initialSession fires on every startup — BehaviorSubject replays it to
    // new subscribers. This is the definitive auth gate.
    if (state.event == AuthChangeEvent.initialSession) {
      if (_initDone) return; // fast-path in _init() already handled it
      _initDone = true;
      final waitedMs = DateTime.now().millisecondsSinceEpoch - _initStartMs;
      try {
        final Session? session =
            Supabase.instance.client.auth.currentSession ?? state.session;
        final User? user = session?.user;

        final gate = user != null ? 'in' : 'out';
        _trace('boot',
            '${RenderLog.authStorageInfo()}; '
            'getSession=${session != null ? 'yes' : 'no'}; '
            'mem=${user != null ? 'yes' : 'no'}; '
            'initEvent=initialSession; gate=$gate; '
            'waitedMs=$waitedMs; flow=pkce; '
            'build=${RenderLog.buildHash}; change=571');

        if (user != null) {
          RenderLog.write('auth_email', user.email ?? 'unknown');
          RenderLog.write('auth55_restore',
              'initialSession user=${user.email ?? 'null'}; logged_in=true; from=restored_session');
          try {
            await _loadSession();
          } catch (_) {
            // Session fetch failure must NOT clear the credential.
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
    // session is present. tokenRefreshed matters as much as signedIn: setSession
    // (the WhatsApp OTP path) emits ONLY tokenRefreshed, so a signedIn-only
    // listener is dead on that path — that was the cause of #566.
    final isSignIn = state.event == AuthChangeEvent.signedIn ||
        state.event == AuthChangeEvent.tokenRefreshed;
    final hasSession = state.session != null ||
        Supabase.instance.client.auth.currentSession != null;
    if (_loading && !(isSignIn && hasSession)) {
      RenderLog.write('auth55_event_blocked', '${state.event.name}_blocked_by_loading');
      return;
    }

    if (state.event == AuthChangeEvent.signedIn ||
        state.event == AuthChangeEvent.tokenRefreshed ||
        state.event == AuthChangeEvent.userUpdated) {
      RenderLog.write('auth55_signed_in', 'event_received; loading_was=$_loading');
      final session = state.session ?? Supabase.instance.client.auth.currentSession;
      _trace('signedIn',
          '${RenderLog.authStorageInfo()}; '
          'mem=${session != null ? 'yes' : 'no'}; '
          'hasRefresh=${session?.refreshToken != null && (session!.refreshToken?.isNotEmpty ?? false)}; '
          'build=${RenderLog.buildHash}; change=571');
      // Selftest hook: write selftest_login trace after SDK has persisted session.
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
              'build=${RenderLog.buildHash}; change=571',
        // ignore: unnecessary_lambdas
        }).then((_) {}).catchError((_) {});
      }
      final user = session?.user ?? Supabase.instance.client.auth.currentUser;
      if (user != null) {
        RenderLog.write('auth_email', user.email ?? 'unknown');
        // RULE: on ANY auth change, drop all account state FIRST, then refetch,
        // then render. Never render a session resolved against a different user.
        if (user.id != _session.authUserId) _clearAccountState();
        if (_loading) {
          _initDone = true;
          await _loadSession();
          _loading = false;
          notifyListeners();
        } else {
          _profileLoading = true;
          notifyListeners();
          await _loadSession();
          _profileLoading = false;
          notifyListeners();
        }
        // CHANGE #210 — fire login notify for customer/supplier only.
        if (state.event == AuthChangeEvent.signedIn) {
          _maybeSendLoginNotify(user.id);
        }
      } else if (_loading) {
        _loading = false;
        notifyListeners();
      }
    } else if (state.event == AuthChangeEvent.signedOut) {
      final storageInfo = RenderLog.authStorageInfo();

      if (_explicitSignOut) {
        _explicitSignOut = false;
        _trace('signedOut',
            'reason=explicit; caller=user_state:signedOut_handler; '
            'getSessionBefore=${Supabase.instance.client.auth.currentSession != null ? 'yes' : 'no'}; '
            'explicit=true; $storageInfo; '
            'build=${RenderLog.buildHash}; change=571');
        _clearAccountState();
        notifyListeners();
        return;
      }

      // SDK-originated signedOut (e.g. bad_code_verifier from double PKCE
      // exchange). Wait 300ms then re-check: if a valid session exists, ignore
      // this event entirely. Only clear state if truly no session.
      await Future.delayed(const Duration(milliseconds: 300));
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null) {
        _trace('signedOut',
            'reason=ignored_sdk_transient_session_present; caller=user_state:signedOut_handler; '
            'getSessionBefore=yes; explicit=false; $storageInfo; '
            'build=${RenderLog.buildHash}; change=571');
        return;
      }
      _trace('signedOut',
          'reason=sdk_confirmed_no_session; caller=user_state:signedOut_handler; '
          'getSessionBefore=no; explicit=false; $storageInfo; '
          'build=${RenderLog.buildHash}; change=571');
      _explicitSignOut = false;
      _clearAccountState();
      notifyListeners();
    }
  }

  /// Hard reset. Every piece of account state goes at once — there is no
  /// partial clear, because a half-cleared session is exactly the state that
  /// leaks one account's data into another's screen.
  void _clearAccountState() {
    _session = AppSession.signedOut;
    _profileLoading = false;
    _sessionFetchError = false;
    _profileChannel?.unsubscribe();
    _profileChannel = null;
    FulfillRealtime.instance.onAuthInactive(); // C355: drop the app-level socket
    // CHANGE #629: the delivery answer belongs to the credential that just went
    // away. A stale "yes" would open the rider interface for the next login.
    DeliveryRoleState.instance.clear();
    RenderLog.write('auth_email', 'signed_out');
    RenderLog.write('auth_role', 'none');
  }

  /// The ONE fetch. One RPC, one payload, no reconciliation.
  Future<void> _loadSession() async {
    try {
      final raw = await Supabase.instance.client.rpc('my_session');
      final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (map is! Map) {
        _sessionFetchError = true;
        return;
      }
      final next = AppSession.fromJson(map.cast<String, dynamic>());
      _sessionFetchError = false;

      // RULE 4 — never adopt a payload that resolved against a different auth
      // user than the one live right now (a stale in-flight response).
      final live = Supabase.instance.client.auth.currentUser?.id ?? '';
      if (next.signedIn && live.isNotEmpty && next.authUserId != live) {
        RenderLog.write('c571_session_mismatch_dropped', 1);
        return;
      }

      _session = next;
      RenderLog.write('auth_role', next.role);
      RenderLog.write('c571_surface', next.surfaceName);
      RenderLog.write('c571_can_order', next.canPlaceOrder.toString());
      RenderLog.write('c571_gate_reason', next.orderGate.reason);

      // C355: admins keep an app-level, JWT-authed Fulfill realtime channel
      // alive so cross-device changes arrive without a reload.
      _maybeActivateFulfillRealtime();
      _subscribeProfileRealtime();

      // CHANGE #629 — "is this login a delivery account?" is asked here, in the
      // ONE place a session is fetched, so every path that resolves a session
      // (initialSession, signedIn, and the tokenRefreshed-only WhatsApp OTP
      // path of #566) probes exactly once. Not awaited: a delivery probe must
      // never sit in front of first paint, and DeliveryRoleState answers
      // "unresolved", never "no", when it fails.
      unawaited(DeliveryRoleState.instance.probe());
    } catch (_) {
      // A fetch error is NOT a clean "no account" answer. Keep whatever we
      // already had and flag the error so the UI can offer a retry.
      _sessionFetchError = true;
    }
  }

  /// #402: lets the Profile screen retry after a fetch error instead of being
  /// stuck showing "couldn't load" with no way forward.
  Future<void> retryLoadProfile() async {
    await _loadSession();
    notifyListeners();
  }

  /// Realtime is a REFETCH TRIGGER, never a source of truth: a changed row
  /// re-runs my_session() rather than being parsed into local state, so the
  /// backend stays the only thing that ever answers.
  void _subscribeProfileRealtime() {
    final accountId = _session.customerId;
    if (accountId.isEmpty) return;
    _profileChannel?.unsubscribe();
    final ts = DateTime.now().millisecondsSinceEpoch;
    _profileChannel = Supabase.instance.client
        .channel('user_profile_$ts')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'pharmacy_profiles',
          // Keyed to the ACCOUNT id, not the login. #571.
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: accountId,
          ),
          callback: (_) async {
            await _loadSession();
            notifyListeners();
          },
        )
        .subscribe();
  }

  // CHANGE #210 — WhatsApp login notify for customer/supplier only.
  // Fire-and-forget: never blocks the UI, swallows all errors.
  void _maybeSendLoginNotify(String userId) {
    if (_session.isAdmin) {
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

  // C355: bring up the app-level Fulfill realtime channel with the current JWT.
  void _maybeActivateFulfillRealtime() {
    if (!_session.isAdmin) return;
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) return;
    try {
      FulfillRealtime.instance.onAuthActive(token);
    } catch (_) {}
  }

  /// Registration write. Goes through an RPC that keys to the ACCOUNT and
  /// refuses client-supplied approval, and returns the fresh session — so the
  /// app renders the server's answer rather than an optimistic guess.
  Future<void> saveProfile(Map<String, dynamic> payload) async {
    final raw = await Supabase.instance.client
        .rpc('save_customer_profile', params: {'p': payload});
    final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
    if (map is Map) {
      _session = AppSession.fromJson(map.cast<String, dynamic>());
      _subscribeProfileRealtime();
    } else {
      await _loadSession();
    }
    notifyListeners();
  }

  /// CHANGE #565: the home_shell entry point, on the same single path as the
  /// login screen — the GIS One Tap sheet only.
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

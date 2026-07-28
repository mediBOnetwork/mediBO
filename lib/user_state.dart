// CHANGE #558 — one session source of truth.
//
// RULE 1  my_session() is the ONLY thing that decides role, account, display
//         name and landing route. There is no email sniffing, no cached
//         isAdmin flag, no role in SharedPreferences, no role passed between
//         screens as a constructor argument.
// RULE 2  Nothing renders before the session resolves. [loading] stays true
//         until my_session() has returned for the current auth user.
// RULE 3  Every auth change hard-resets every scrap of account state (here and
//         in every registered reset hook) before the new session is fetched.
// RULE 4  [sessionMatchesAuthUser] compares the backend's auth_user_id against
//         the SDK's current user id. On a mismatch the cached session is
//         discarded and re-fetched; callers must not render until it matches.
// RULE 5  The guest cart is claimed immediately after sign-in and BEFORE
//         my_session() is called.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models/app_session.dart';
import 'models/session_gate.dart';
import 'models/user_profile.dart';
import 'services/gis_auth.dart';
import 'services/fulfill_realtime.dart'; // C355: app-level realtime auth + subscription
import 'utils/render_log.dart';

class AuthNotifier extends ChangeNotifier {
  AuthNotifier({@visibleForTesting bool listenToAuth = true}) {
    gate = SessionGate(
      currentAuthUserId: _currentUserId,
      refetch: () => _resolve(reason: 'mismatch'),
    );
    gate.addListener(notifyListeners);
    if (listenToAuth) {
      _sub = Supabase.instance.client.auth.onAuthStateChange.listen(_onAuthChange);
      // A session may already have been restored synchronously; resolve either way.
      unawaited(_resolve(reason: 'boot'));
    }
  }

  // ── The one session object ────────────────────────────────────────────────
  //
  // Held by the gate, which owns RULES 2/4/6. Nothing in this class keeps a
  // second copy, and no other class keeps one at all.
  late final SessionGate gate;

  AppSession? get _session => gate.session;

  UserProfile? _profile;
  bool _profileLoading = false;
  bool _needsProfile = false;
  bool _profileFetchError = false;
  RealtimeChannel? _profileChannel;

  StreamSubscription<AuthState>? _sub;

  /// Serialises overlapping resolves (boot + signedIn can race).
  Future<void>? _inFlight;

  /// Set to true BEFORE auth.signOut() so the handler knows it was deliberate.
  bool _explicitSignOut = false;

  /// Set by the main.dart selftest hook; consumed in the signedIn handler.
  static String? pendingSelftestEmail;

  // ── Wiring supplied by main.dart (keeps this file free of dart:html) ──────

  /// Everything outside this notifier that holds account data registers a
  /// clear here: cart, order lists, view-as, dashboard counters, image and
  /// name caches. RULE 3 fires all of them on every auth change.
  final List<void Function()> _resetHooks = <void Function()>[];

  /// Returns the guest uid the app already uses for delete_guest_cart, or null.
  ///
  /// Deliberately synchronous: the cart's own signedIn handler starts merging
  /// and eventually clears that uid, so it has to be captured in the same
  /// microtask the event arrives in, before anything can await.
  String? Function()? guestUidProvider;

  /// Captured on signedIn, consumed by the next resolve — which claims the
  /// guest cart BEFORE calling my_session(), per RULE 5. Held here rather than
  /// awaited in the event handler so that every caller awaiting [_resolve]
  /// (including the login screen) waits for the claim too.
  String? _pendingGuestUid;

  /// Called after a sign-out has cleared everything, to land on /login.
  void Function()? onSignedOutNavigate;

  void addResetHook(void Function() hook) => _resetHooks.add(hook);

  // ── Session-derived getters — RULE 1 ──────────────────────────────────────

  AppSession? get session => _session;

  /// True until my_session() has resolved for the current auth user.
  bool get loading => _session == null;

  bool get isAdmin => _session?.isAdmin ?? false;
  bool get isSuperAdmin => _session?.isSuperAdmin ?? false;
  bool get isSupplier => _session?.isSupplier ?? false;
  String get role => _session?.role ?? 'none';

  /// The account's name as the backend resolved it — pharmacy, supplier,
  /// worker or admin email. Never derived from the Supabase user.
  String get displayName => _session?.displayName ?? '';
  String get loginEmail => _session?.loginEmail ?? '';
  String get homeRoute => _session?.homeRoute ?? '/login';

  String? get supplierId => _session?.supplierId;
  String? get supplierName => isSupplier ? _session?.displayName : null;
  String? get supplierStatus => _session?.supplierStatus;

  bool get isAuthenticated => _session?.signedIn ?? false;

  bool get profileLoading => _profileLoading;
  bool get needsProfile => _needsProfile;
  bool get profileFetchError => _profileFetchError;
  UserProfile? get profile => _profile;

  bool get isRegistered => isAuthenticated && _profile != null;

  bool get canOrder =>
      isRegistered &&
      (_profile?.isApproved ?? false) &&
      (_profile?.status != 'suspended');

  // ── RULE 4 — mismatch guard ───────────────────────────────────────────────

  /// True when the cached session was resolved for exactly the auth user the
  /// SDK currently holds. False means: do not render account data.
  bool get sessionMatchesAuthUser => gate.matchesAuthUser;

  String? _currentUserId() {
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// Call from a build() that is about to render account data. If the cached
  /// session belongs to somebody else, this discards it and re-fetches; the
  /// caller renders a neutral state until [sessionMatchesAuthUser] is true.
  void ensureSessionMatchesAuthUser() {
    if (gate.matchesAuthUser || _session == null) return;
    try {
      RenderLog.write('c558_mismatch',
          'cached=${_session?.authUserId ?? 'null'};'
          'current=${_currentUserId() ?? 'null'}');
    } catch (_) {}
    _clearAccountState();
    gate.ensureMatchesAuthUser();
  }

  /// RULE 6 — the single surface decision, owned by the gate.
  AccountSurface surfaceFor({bool actingAsCustomer = false}) =>
      gate.surfaceFor(actingAsCustomer: actingAsCustomer);

  // ── RULE 3 — hard reset ───────────────────────────────────────────────────

  /// Drops every field of the old account held in this notifier.
  void _clearAccountState() {
    _profile = null;
    _needsProfile = false;
    _profileLoading = false;
    _profileFetchError = false;
    _profileChannel?.unsubscribe();
    _profileChannel = null;
    try {
      FulfillRealtime.instance.onAuthInactive(); // C355: drop the app-level socket
    } catch (_) {}
  }

  /// Full reset: this notifier plus every registered holder of account data.
  void _hardReset(String reason) {
    try { RenderLog.write('c558_hard_reset', reason); } catch (_) {}
    gate.clear();
    _clearAccountState();
    for (final hook in _resetHooks) {
      try {
        hook();
      } catch (_) {
        // A misbehaving hook must never block the reset of the others.
      }
    }
  }

  // ── RULE 2 — resolve, then render ─────────────────────────────────────────

  /// Fetches my_session() and adopts it, but only if it describes the auth
  /// user the SDK currently holds.
  Future<void> _resolve({required String reason}) {
    final pending = _inFlight;
    if (pending != null) return pending;
    final run = _doResolve(reason).whenComplete(() => _inFlight = null);
    _inFlight = run;
    return run;
  }

  Future<void> _doResolve(String reason) async {
    debugResolveCount++;

    // RULE 5 — claim the guest cart first, and always before my_session().
    // Best effort: the result body is ignored, and a failure never blocks the
    // session from resolving.
    final guestUid = _pendingGuestUid;
    _pendingGuestUid = null;
    if (guestUid != null && guestUid.isNotEmpty) {
      try {
        await Supabase.instance.client
            .rpc('claim_guest_cart', params: {'p_guest_uid': guestUid});
        RenderLog.write('c558_guest_cart_claimed', guestUid);
      } catch (e) {
        try { RenderLog.write('c558_guest_cart_error', e.toString()); } catch (_) {}
      }
    }

    final before = _currentUserId();
    AppSession resolved;
    try {
      final raw = await Supabase.instance.client.rpc('my_session');
      final map = raw is Map
          ? raw.cast<String, dynamic>()
          : <String, dynamic>{'signed_in': false};
      resolved = AppSession.fromJson(map);
    } catch (e) {
      // A failed fetch must not invent a role. Signed-out is only adopted when
      // the SDK agrees there is no user; otherwise leave the session unresolved
      // so the UI keeps waiting rather than rendering a guess.
      try { RenderLog.write('c558_session_error', e.toString()); } catch (_) {}
      if (before == null) gate.adopt(AppSession.signedOut);
      return;
    }

    // The user may have changed while the RPC was in flight.
    final after = _currentUserId();
    if (after != before) {
      try { RenderLog.write('c558_resolve_stale', 'reason=$reason'); } catch (_) {}
      unawaited(_resolve(reason: 'restale'));
      return;
    }
    if (resolved.signedIn && after != null && resolved.authUserId != after) {
      try {
        RenderLog.write(
            'c558_resolve_mismatch', 'rpc=${resolved.authUserId};sdk=$after');
      } catch (_) {}
      return;
    }

    gate.adopt(resolved);
    try {
      RenderLog.write(
          'c558_session',
          'reason=$reason;role=${resolved.role};admin=${resolved.isAdmin};'
              'route=${resolved.homeRoute}');
      RenderLog.write('auth_role', resolved.role);
      RenderLog.write(
          'auth_email', resolved.signedIn ? resolved.loginEmail : 'signed_out');
    } catch (_) {}

    if (!resolved.signedIn) return;

    // Post-resolve enrichment. None of it can change the role.
    if (resolved.isAdmin) {
      _activateFulfillRealtime();
    } else if (!resolved.isSupplier) {
      await _resolveSupplierStatus(resolved);
    }
    await _loadProfile(resolved.authUserId);
    notifyListeners();
  }

  /// Public re-fetch, used by the login screen once a session exists.
  Future<void> refreshSession() => _resolve(reason: 'manual');

  // ── Auth events — RULE 3 ──────────────────────────────────────────────────

  Future<void> _onAuthChange(AuthState state) async {
    final event = state.event;
    final currentId = _currentUserId();

    switch (event) {
      case AuthChangeEvent.initialSession:
        // Boot. The constructor's _resolve() usually wins the race; this is
        // the path where the SDK restored the session asynchronously.
        await _resolve(reason: 'initialSession');
        return;

      case AuthChangeEvent.signedIn:
        _writeSelftestTrace();
        // RULE 5 — capture the guest uid synchronously, before the cart's own
        // signedIn handler can clear it and before any await. The claim itself
        // runs inside _resolve(), ahead of my_session().
        try {
          _pendingGuestUid = guestUidProvider?.call();
        } catch (_) {}
        _hardReset('signedIn');
        notifyListeners(); // paint the neutral loading state immediately
        await _resolve(reason: 'signedIn');
        if (isAuthenticated && !isAdmin) _sendLoginNotify();
        return;

      case AuthChangeEvent.userUpdated:
        _hardReset('userUpdated');
        notifyListeners();
        await _resolve(reason: 'userUpdated');
        return;

      case AuthChangeEvent.tokenRefreshed:
        // Only a *different* user matters here; a routine refresh must not
        // wipe the screen the user is looking at.
        if (currentId != null && currentId != _session?.authUserId) {
          _hardReset('tokenRefreshed:userChanged');
          notifyListeners();
          await _resolve(reason: 'tokenRefreshed');
        }
        return;

      case AuthChangeEvent.signedOut:
        if (!_explicitSignOut) {
          // The SDK emits spurious signedOut events (e.g. a double PKCE
          // exchange). Re-check before tearing the session down.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (Supabase.instance.client.auth.currentSession != null) {
            try { RenderLog.write('c558_signout_ignored', 'session_still_present'); } catch (_) {}
            return;
          }
        }
        _explicitSignOut = false;
        _hardReset('signedOut');
        gate.adopt(AppSession.signedOut);
        try {
          RenderLog.write('auth_email', 'signed_out');
          RenderLog.write('auth_role', 'none');
        } catch (_) {}
        try {
          onSignedOutNavigate?.call();
        } catch (_) {}
        return;

      default:
        return;
    }
  }

  void _writeSelftestTrace() {
    final email = pendingSelftestEmail;
    if (email == null) return;
    pendingSelftestEmail = null;
    try {
      Supabase.instance.client.rpc('log_auth_debug', params: {
        'p_email': email,
        'p_event': 'selftest_login',
        'p_detail': '${RenderLog.authStorageInfo()}; flow=pkce; '
            'build=${RenderLog.buildHash}; change=558',
        // ignore: unnecessary_lambdas
      }).then((_) {}).catchError((_) {});
    } catch (_) {}
  }

  // ── Enrichment (never decides the role) ───────────────────────────────────

  /// Distinguishes an unapproved supplier from a plain customer so the waiting
  /// screen still works. The email comes from the session, never from the
  /// Supabase user.
  Future<void> _resolveSupplierStatus(AppSession s) async {
    if (s.loginEmail.isEmpty) return;
    try {
      final res = await Supabase.instance.client
          .rpc('claim_supplier_profile', params: {'p_email': s.loginEmail});
      final status = res is Map ? res['status'] as String? : null;
      if (_session?.authUserId != s.authUserId) return; // account changed mid-flight
      gate.adopt(_session!.withSupplierStatus(status));
    } catch (_) {
      // No status is not the same as "not a supplier" — leave it null.
    }
  }

  void _activateFulfillRealtime() {
    try {
      final token = Supabase.instance.client.auth.currentSession?.accessToken;
      if (token == null || token.isEmpty) return;
      FulfillRealtime.instance.onAuthActive(token);
    } catch (_) {}
  }

  // CHANGE #210 — WhatsApp login notify for customer/supplier only.
  void _sendLoginNotify() {
    final userId = _session?.authUserId;
    if (userId == null || userId.isEmpty) return;
    Supabase.instance.client.functions
        .invoke('user-notify',
            body: {'event': 'login', 'user_id': userId},
            headers: {'x-notify-secret': 'medibo_order_notify_2027'})
        .then((_) => RenderLog.write('c210_login_notify_sent', 1))
        .catchError((_) => RenderLog.write('c210_login_notify_sent', 1));
  }

  // ── Pharmacy profile ──────────────────────────────────────────────────────

  Future<void> _loadProfile(String userId) async {
    try {
      final res = await Supabase.instance.client
          .from('pharmacy_profiles')
          .select()
          .eq('user_id', userId)
          .maybeSingle();
      if (_session?.authUserId != userId) return; // account changed mid-flight
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

  /// #402: lets the Profile screen retry after a fetch error.
  Future<void> retryLoadProfile() async {
    final userId = _session?.authUserId;
    if (userId == null || userId.isEmpty) return;
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
            if (_session?.authUserId != userId) return;
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
      if (res != null && _session?.authUserId == userId) {
        _profile = UserProfile.fromJson(res);
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> saveProfile(UserProfile profile) async {
    await Supabase.instance.client
        .from('pharmacy_profiles')
        .upsert(profile.toInsertJson(), onConflict: 'user_id');
    _profile = profile;
    _needsProfile = false;
    notifyListeners();
  }

  // ── Sign-in / sign-out ────────────────────────────────────────────────────

  // CHANGE #310: Two-attempt Google sign-in.
  // Attempt A: GIS programmatic prompt (no rendered HTML button).
  // Attempt B: OAuth PKCE redirect — only when GIS can't load at all.
  Future<void> signInWithGoogle() async {
    try { RenderLog.write('c399_input_type', isCoarsePointer() ? 'touch' : 'mouse'); } catch (_) {}
    try { RenderLog.write('c399_google_auth_launch', 'fired'); } catch (_) {}

    bool gisLibraryUnavailable = false;
    try {
      RenderLog.write('c310_method', 'gis_idtoken');
      final (:idToken, :rawNonce) = await gisSignInWithNonce();
      RenderLog.write('c310_gis_loaded', 'true');
      await Supabase.instance.client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        nonce: rawNonce,
      );
      RenderLog.write('c310_session', 'established');
      return;
    } catch (e) {
      final errStr = e.toString();
      gisLibraryUnavailable = errStr.contains('gis-load-timeout') ||
          errStr.contains('gis-not-loaded') ||
          errStr.contains('gis-init-error');
      RenderLog.write('c310_gis_loaded', gisLibraryUnavailable ? 'false' : 'true');
      if (!gisLibraryUnavailable) rethrow;
    }

    RenderLog.write('c310_method', 'oauth_redirect');
    await Supabase.instance.client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: 'https://medibo.in',
    );
    RenderLog.write('c310_session', 'redirect_initiated');
  }

  /// CHANGE #555: the OAuth PKCE redirect on its own — the mandatory fallback
  /// when the One Tap bottom sheet cannot be shown.
  Future<void> signInWithGoogleOAuth() async {
    RenderLog.write('c555_method', 'oauth_redirect');
    await Supabase.instance.client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: 'https://medibo.in',
    );
    RenderLog.write('c555_session', 'redirect_initiated');
  }

  Future<void> signOut() async {
    _explicitSignOut = true;
    RenderLog.write('auth54_signout', 'scope=local; reason=manual_logout');
    await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
  }

  // ── Test seams ────────────────────────────────────────────────────────────

  /// Installs a session directly. Widget tests only — in the app a session
  /// only ever comes from my_session().
  @visibleForTesting
  void debugSetSession(AppSession? s) => gate.adopt(s);

  /// Counts calls to the resolver so a test can assert a re-fetch happened.
  @visibleForTesting
  int debugResolveCount = 0;

  @override
  void dispose() {
    _sub?.cancel();
    gate.removeListener(notifyListeners);
    gate.dispose();
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

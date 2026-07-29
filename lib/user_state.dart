import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_navigator.dart';
import 'models/app_session.dart';
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

  // ── CHANGE #571: the session, and the account it belongs to ───────────────
  //
  // The shell used to pick its surface from _isAdmin/_isSupplier and keep
  // whatever it had last drawn. After logout those booleans flipped, the nav
  // redrew from them — and the body did not, because nothing told the shell
  // its account had changed. These three fields are that signal.

  /// The last resolved `my_session()`. Never null: before the first resolve,
  /// and for the whole of a signed-out session, it is [AppSession.signedOut].
  AppSession _session = AppSession.signedOut;

  /// True while a `my_session()` for a NEW account is in flight. The shell
  /// renders the neutral loading state for the whole of it — never the
  /// previous account's screen, never a guessed default.
  bool _sessionResolving = false;

  /// Bumped once per account change. The shell compares it and throws away
  /// every scrap of per-account state when it moves.
  int _accountEpoch = 0;

  /// The auth user id [_session] was resolved for. A signedIn/tokenRefreshed
  /// event whose user id still matches this is a token refresh, not a new
  /// account, and must NOT clear anything.
  String _sessionAuthUserId = '';

  AppSession get session => _session;
  bool get sessionResolving => _sessionResolving;
  int get accountEpoch => _accountEpoch;

  /// RULE 4 — the cached session must belong to the auth user the SDK is
  /// holding right now, or nothing account-shaped may render.
  ///
  /// A signed-out session is exempt, and that exemption is load-bearing: it is
  /// also what [_fetchSession] falls back to when the backend is unreachable.
  /// Without it an unreachable backend would read as "mismatch" forever and
  /// pin the app on a spinner. A signed-out payload carries no account, so it
  /// cannot be the wrong account's data — the worst it can do is show the
  /// public storefront, which is what a failed role lookup already did.
  bool get _matchesAuthUser {
    if (!_session.signedIn) return true;
    final live = Supabase.instance.client.auth.currentUser?.id ?? '';
    return _session.authUserId == live;
  }

  /// The one question the shell asks: which surface am I allowed to draw?
  /// The answer is the backend's `surface` string, resolved in [AppSession].
  AccountSurface surfaceFor({bool actingAsCustomer = false}) {
    if (_sessionResolving) return AccountSurface.unresolved;
    return _session.surface(
      matchesAuthUser: _matchesAuthUser,
      actingAsCustomer: actingAsCustomer,
    );
  }

  /// True when logged in AND has submitted a pharmacy_profiles row.
  bool get isRegistered => isAuthenticated && _profile != null;

  /// True when registered AND admin has approved the account AND not suspended.
  bool get canOrder => isRegistered &&
      (_profile?.isApproved ?? false) &&
      (_profile?.status != 'suspended');

  // Set by main.dart selftest hook; checked in signedIn handler to write trace.
  static String? pendingSelftestEmail;

  late final StreamSubscription<AuthState> _sub;
  Timer? _resolveWatchdog;
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

  // ── CHANGE #571: account change ───────────────────────────────────────────

  /// Asks the backend who this is. Bounded and retried, because the caller is
  /// showing a spinner until it returns and a hung request must not become an
  /// infinite one.
  ///
  /// On total failure it returns [AppSession.signedOut]. That is the fail-safe
  /// direction and it is deliberate: the signed-out surface is the only one
  /// that cannot show another account's data. The login screen re-asks
  /// `my_session()` as soon as it paints, so a network blip during an account
  /// switch heals itself instead of stranding anyone.
  Future<AppSession> _fetchSession() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final raw = await Supabase.instance.client
            .rpc('my_session')
            .timeout(const Duration(seconds: 4));
        if (raw is Map) {
          return AppSession.fromJson(Map<String, dynamic>.from(raw));
        }
      } catch (_) {
        // fall through to the retry / signed-out fallback
      }
      if (attempt == 0) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
    RenderLog.write('c571_session_failed', '1');
    return AppSession.signedOut;
  }

  /// Publishes a freshly fetched session. `supplier_status` is stapled on here
  /// because it comes from a different RPC (`claim_supplier_profile`) that has
  /// just finished alongside it, and [AppSession.surface] needs both to tell a
  /// supplier awaiting approval from a plain customer.
  void _applyResolvedSession(AppSession resolved) {
    _session = resolved.withSupplierStatus(_supplierStatus);
    _sessionAuthUserId = _session.authUserId;
    RenderLog.write('c571_surface', _session.surfaceName);
  }

  /// Belt-and-braces for the BOOT RESILIENCE RULE: whatever happens inside
  /// [_fetchSession], the neutral loading state is never permanent.
  void _armResolveWatchdog(int epoch) {
    _resolveWatchdog?.cancel();
    _resolveWatchdog = Timer(const Duration(seconds: 10), () {
      if (epoch != _accountEpoch || !_sessionResolving) return;
      _sessionResolving = false;
      _loading = false;
      RenderLog.write('c571_resolve_watchdog', 'forced;epoch=$epoch');
      notifyListeners();
    });
  }

  /// Everything this app knows about an account, dropped.
  ///
  /// The cart, the order list and the acting-as selection are cleared by their
  /// own owners — [CartModel] on the same auth event, ViewAs from main.dart on
  /// the epoch bump — because they own that state and this class must not
  /// reach across and hold a second copy of it.
  void _clearAccountState() {
    _profile = null;
    _needsProfile = false;
    _profileLoading = false;
    _profileFetchError = false;
    _isAdmin = false;
    _isSuperAdmin = false;
    _isSupplier = false;
    _supplierName = null;
    _supplierId = null;
    _supplierStatus = null;
    _profileChannel?.unsubscribe();
    _profileChannel = null;
    FulfillRealtime.instance.onAuthInactive(); // drop the app-level socket
  }

  /// The ONE handler for "the account on screen is no longer the account we
  /// are signed in as" — logout, login, and a switch straight from one account
  /// to another. Rule 4 of the change: all three take this same path, so a
  /// switch between accounts cannot show the previous account's screen either.
  ///
  /// Order matters. Clear first and publish that immediately, so the frame
  /// after the auth event already shows the neutral loading state. Only then
  /// ask the backend who we are, and only then navigate.
  Future<void> _onAccountChanged(String reason) async {
    final epoch = ++_accountEpoch;
    RenderLog.write('c571_account_changed', '$reason;epoch=$epoch');
    _armResolveWatchdog(epoch);

    _sessionResolving = true;
    _session = AppSession.signedOut;
    _sessionAuthUserId = '';
    _clearAccountState();
    RenderLog.write('c571_cleared', reason);
    notifyListeners();

    // Take the previous account's screens off the glass NOW, before waiting on
    // anything. The root route is the shell, and the shell is already showing
    // the neutral loading state after the notify above — but a pushed screen
    // (Bags, WhatsApp, Manage Admins, any open dialog) sits ON TOP of it and
    // would stay there, fully visible, for the whole of the my_session() round
    // trip. home_route replaces the stack properly once it arrives; this is
    // just what happens in the meantime.
    _popToRoot();

    final live = Supabase.instance.client.auth.currentUser;
    AppSession resolved;
    if (live == null) {
      // Nobody is signed in. my_session() would answer the signed-out payload
      // and we already hold an identical copy of it — but home_route has to
      // come from the backend, so ask anyway rather than assume '/login'.
      resolved = await _fetchSession();
    } else {
      // Role/profile feed the parts of the app that have not moved onto the
      // session object yet; they resolve alongside it, never after render.
      final results = await Future.wait<Object?>([
        _fetchSession(),
        _loadProfile(live.id).then<Object?>((_) => null),
        _resolveRole(live.email ?? '').then<Object?>((_) => null),
      ]);
      resolved = results.first as AppSession;
    }

    if (epoch != _accountEpoch) {
      // A newer account change started while we were waiting. It owns the
      // screen now; anything we publish here would be one account stale.
      RenderLog.write('c571_stale_resolve', 'epoch=$epoch');
      return;
    }

    _resolveWatchdog?.cancel();
    _applyResolvedSession(resolved);
    _sessionResolving = false;
    _loading = false;
    notifyListeners();

    _goToHomeRoute(_session.homeRoute, reason);
  }

  /// Drops everything pushed over the root route. Best-effort: if there is no
  /// navigator yet there is also nothing on it.
  void _popToRoot() {
    try {
      final nav = appNavigatorKey.currentState;
      if (nav == null || !nav.canPop()) return;
      nav.popUntil((r) => r.isFirst);
      RenderLog.write('c571_popped_to_root', '1');
    } catch (e) {
      final msg = e.toString();
      RenderLog.write(
          'c571_pop_error', msg.length > 80 ? msg.substring(0, 80) : msg);
    }
  }

  /// Replaces the entire stack with the backend's `home_route`. Not a pop, not
  /// a push over the top: anything still on the stack belongs to the account
  /// that just went away — a pushed admin sub-screen, an open dialog, the
  /// shell itself — and popping would only uncover more of it.
  void _goToHomeRoute(String route, String reason) {
    if (route.isEmpty) return;
    final nav = appNavigatorKey.currentState;
    if (nav == null) {
      RenderLog.write('c571_nav_skipped', 'no_navigator');
      return;
    }
    if (appRouteTracker.currentRouteName == route) {
      // Already exactly where the backend wants us — the login screen does its
      // own landing for the sign-in it drove. Pushing again would rebuild the
      // shell for nothing.
      RenderLog.write('c571_nav_skipped', 'already_on:$route');
      return;
    }
    try {
      nav.pushNamedAndRemoveUntil(route, (r) => false);
      RenderLog.write('c571_nav', '$reason:$route');
    } catch (e) {
      final msg = e.toString();
      RenderLog.write(
          'c571_nav_error', msg.length > 80 ? msg.substring(0, 80) : msg);
    }
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
        // CHANGE #571 — the session resolves as part of the boot gate, not
        // after it, so the shell never paints a surface it had to guess.
        // No navigation here: on boot the URL the user arrived on wins, or a
        // deep link into /orders would bounce to home_route on every reload.
        final results = await Future.wait<Object?>([
          _fetchSession(),
          _loadProfile(user.id).then<Object?>((_) => null),
          _resolveRole(user.email ?? '').then<Object?>((_) => null),
        ]);
        _applyResolvedSession(results.first as AppSession);
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
            // CHANGE #571 — same as the fast path in _init(): resolve the
            // session inside the boot gate, and do not navigate.
            final results = await Future.wait<Object?>([
              _fetchSession(),
              _loadProfile(user.id).then<Object?>((_) => null),
              _resolveRole(user.email ?? '').then<Object?>((_) => null),
            ]);
            _applyResolvedSession(results.first as AppSession);
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
          // We broke through the guard — take over loading state. Still boot:
          // resolve, do not navigate, the arrival URL wins.
          _initDone = true;
          final results = await Future.wait<Object?>([
            _fetchSession(),
            _loadProfile(user.id).then<Object?>((_) => null),
            _resolveRole(user.email ?? '').then<Object?>((_) => null),
          ]);
          _applyResolvedSession(results.first as AppSession);
          _loading = false;
          notifyListeners();
        } else if (user.id != _sessionAuthUserId) {
          // CHANGE #571 rule 4 — the account on screen is not this account.
          // A fresh login, or a switch straight from one account to another;
          // either way the previous account's screens must not survive it.
          //
          // Keyed on the auth user id rather than the event name on purpose:
          // `setSession(refreshToken)` — the WhatsApp OTP login — resolves
          // through gotrue's refresh path and emits tokenRefreshed, not
          // signedIn (CHANGE #566). Testing the account catches every login
          // method whichever constant the SDK picks for it, and just as
          // importantly a routine hourly token refresh keeps the SAME id and
          // so falls through to the quiet branch below instead of tearing the
          // user's screen down mid-session.
          await _onAccountChanged(state.event.name);
        } else {
          // Same account, new token. Nothing account-shaped changed: refresh
          // profile and role in place, keep the screen exactly as it is.
          _profileLoading = true;
          notifyListeners();
          final results = await Future.wait<Object?>([
            _fetchSession(),
            _loadProfile(user.id).then<Object?>((_) => null),
            _resolveRole(user.email ?? '').then<Object?>((_) => null),
          ]);
          _applyResolvedSession(results.first as AppSession);
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
        RenderLog.write('auth_email', 'signed_out');
        RenderLog.write('auth_role', 'none');
        // CHANGE #571 — clearing the fields is only half of it. The screen the
        // previous account was looking at is still mounted, and the routes it
        // pushed are still on the stack, until this runs.
        await _onAccountChanged('signedOut_explicit');
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
      RenderLog.write('auth_email', 'signed_out');
      RenderLog.write('auth_role', 'none');
      await _onAccountChanged('signedOut_sdk');
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
    _resolveWatchdog?.cancel();
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

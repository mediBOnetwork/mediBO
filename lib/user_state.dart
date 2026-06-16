import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models/user_profile.dart';
import 'services/gis_auth.dart';
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

  // Fallback: if currentUser is already available synchronously (e.g. the
  // initialSession stream event fired before we subscribed), resolve loading
  // immediately so there is no blank splash on fast restores.
  Future<void> _init() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null && !_initDone) {
      _initDone = true;
      await Future.wait([
        _loadProfile(user.id),
        _resolveRole(user.email ?? ''),
      ]);
      if (_loading) {
        _loading = false;
        notifyListeners();
      }
    }
    // If user is null here the session may still be restoring from localStorage;
    // _onAuthChange(initialSession) will handle it and clear _loading.
  }

  void _onAuthChange(AuthState state) async {
    // initialSession fires on every startup — it carries the localStorage-restored
    // session (or null). Must NOT be blocked by the _loading guard.
    if (state.event == AuthChangeEvent.initialSession) {
      if (_initDone) return; // synchronous _init() already handled it
      _initDone = true;
      // Server-validate even the restored session so role is always fresh.
      final resp = await Supabase.instance.client.auth.getUser();
      final user = resp.user;
      if (user != null) {
        RenderLog.write('auth_email', user.email ?? 'unknown');
        await Future.wait([
          _loadProfile(user.id),
          _resolveRole(user.email ?? ''),
        ]);
      }
      _loading = false;
      notifyListeners();
      return;
    }

    if (_loading) return; // wait for initialSession to finish first

    if (state.event == AuthChangeEvent.signedIn) {
      // Server-validate: never trust the in-memory session user for role decisions.
      final resp = await Supabase.instance.client.auth.getUser();
      final user = resp.user;
      if (user != null) {
        RenderLog.write('auth_email', user.email ?? 'unknown');
        _profileLoading = true;
        notifyListeners();
        await Future.wait([
          _loadProfile(user.id),
          _resolveRole(user.email ?? ''),
        ]);
        _profileLoading = false;
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
    // Sign out any stale session before starting the new flow.
    await Supabase.instance.client.auth.signOut();

    // GIS popup — requests an ID token from OUR web client so the Google
    // consent screen reads "Sign in to continue to mediBO" (not supabase.co).
    final idToken = await gisGetIdToken();
    if (idToken == null) throw Exception('Google sign-in cancelled or failed');

    await Supabase.instance.client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
    );
    RenderLog.write('google_idtoken_exchange_ok', true);
  }

  Future<void> signOut() async {
    await Supabase.instance.client.auth.signOut();
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

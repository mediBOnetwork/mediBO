import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models/user_profile.dart';

class AuthNotifier extends ChangeNotifier {
  UserProfile? _profile;
  bool _loading = true;
  bool _profileLoading = false;
  bool _needsProfile = false;
  bool _isAdmin = false;
  bool _isSuperAdmin = false;

  bool get loading => _loading;
  bool get profileLoading => _profileLoading;
  bool get needsProfile => _needsProfile;
  bool get isAdmin => _isAdmin;
  bool get isSuperAdmin => _isSuperAdmin;
  bool get isAuthenticated =>
      Supabase.instance.client.auth.currentUser != null;
  UserProfile? get profile => _profile;

  /// True when logged in AND has submitted a pharmacy_profiles row.
  bool get isRegistered => isAuthenticated && _profile != null;

  /// True when registered AND admin has approved the account AND not suspended.
  bool get canOrder => isRegistered &&
      (_profile?.isApproved ?? false) &&
      (_profile?.status != 'suspended');

  static const _superAdminEmails = {
    'masteromprakashsahu@gmail.com',
    'medibonetwork@gmail.com',
  };

  late final StreamSubscription<AuthState> _sub;

  AuthNotifier() {
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen(_onAuthChange);
    _init();
  }

  Future<void> _init() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      await Future.wait([
        _loadProfile(user.id),
        _checkAdminStatus(user.email ?? ''),
      ]);
    }
    _loading = false;
    notifyListeners();
  }

  void _onAuthChange(AuthState state) async {
    if (_loading) return; // _init handles initial auth state
    if (state.event == AuthChangeEvent.signedIn) {
      final user = state.session?.user;
      if (user != null) {
        _profileLoading = true;
        notifyListeners();
        await Future.wait([
          _loadProfile(user.id),
          _checkAdminStatus(user.email ?? ''),
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
  }

  Future<void> _checkAdminStatus(String email) async {
    if (email.isEmpty) {
      _isAdmin = false;
      _isSuperAdmin = false;
      return;
    }
    final normalised = email.toLowerCase().trim();
    if (_superAdminEmails.contains(normalised)) {
      _isAdmin = true;
      _isSuperAdmin = true;
      return;
    }
    try {
      final res = await Supabase.instance.client
          .from('admins')
          .select('email')
          .eq('email', normalised)
          .maybeSingle();
      _isAdmin = res != null;
      _isSuperAdmin = false;
    } catch (_) {
      _isAdmin = false;
      _isSuperAdmin = false;
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
    await Supabase.instance.client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: 'https://medibo.in',
    );
  }

  Future<void> signOut() async {
    await Supabase.instance.client.auth.signOut();
  }

  @override
  void dispose() {
    _sub.cancel();
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

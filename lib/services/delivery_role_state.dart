// lib/services/delivery_role_state.dart — CHANGE #629
//
// "Is this login a delivery account?" — asked ONCE, of the backend, and cached
// only to avoid a refetch. It is never answered in Dart.
//
// WHY A SECOND RPC AND NOT my_session().surface:
// my_session() has no 'delivery' surface — its v_surface CASE resolves a
// delivery partner's login to 'customer', because a rider is not a supplier,
// not staff and not a pending supplier. Teaching it a new surface means
// altering my_session(), and this change is frontend-only: no existing RPC is
// touched. PART B1 of the spec is explicit that the role signal is
// my_delivery_run().is_partner, so that is the boolean read here. It is still a
// BACKEND boolean — the app only asks and renders.
//
// RULE 4 (account state is server-owned): the answer is stamped with the
// auth_user_id it was resolved against. A mismatch with the live session means
// the cache belongs to a different credential and is refused, not rendered.

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

class DeliveryRoleState extends ChangeNotifier {
  DeliveryRoleState._();
  static final DeliveryRoleState instance = DeliveryRoleState._();

  /// my_delivery_run() payload for the account this probe resolved against.
  Map<String, dynamic>? _payload;

  /// The auth user id [_payload] was fetched for. Empty when unresolved.
  String _forAuthUserId = '';

  bool _loading = false;
  bool _probed = false;

  bool get loading => _loading;

  /// True only once the probe has completed for the LIVE auth user.
  bool get resolved => _probed && _matchesLiveUser;

  bool get _matchesLiveUser {
    final live = Supabase.instance.client.auth.currentUser?.id ?? '';
    return live.isNotEmpty && live == _forAuthUserId;
  }

  /// The backend's boolean. False whenever the cache does not belong to the
  /// live credential — a stale yes must never open the rider interface.
  bool get isPartner {
    if (!_matchesLiveUser) return false;
    return (_payload?['is_partner'] as bool?) ?? false;
  }

  bool get isAgency {
    if (!_matchesLiveUser) return false;
    return (_payload?['is_agency'] as bool?) ?? false;
  }

  /// The last payload, for the shell's first paint. Refetched by the shell
  /// itself thereafter — this is a cache, not the source of truth.
  Map<String, dynamic>? get payload => _matchesLiveUser ? _payload : null;

  /// Wipes everything. Called on every auth change before anything renders.
  void clear() {
    _payload = null;
    _forAuthUserId = '';
    _probed = false;
    _loading = false;
    notifyListeners();
  }

  /// Asks the backend once per signed-in credential. Safe to call repeatedly.
  Future<void> probe({bool force = false}) async {
    final live = Supabase.instance.client.auth.currentUser?.id ?? '';
    if (live.isEmpty) {
      if (_probed || _payload != null) clear();
      return;
    }
    if (!force && _probed && _forAuthUserId == live) return;
    if (_loading) return;

    _loading = true;
    notifyListeners();
    try {
      // BOOT RESILIENCE: the shell holds first paint for a signed-in user until
      // this probe settles, so it MUST settle. A stalled network resolves as a
      // failure below (unresolved, not "no"), and the shell falls through to
      // whatever my_session() already decided.
      final res = await Supabase.instance.client
          .rpc('my_delivery_run')
          .timeout(const Duration(seconds: 6));
      // The credential may have changed while the call was in flight.
      final nowLive = Supabase.instance.client.auth.currentUser?.id ?? '';
      if (nowLive != live) {
        _loading = false;
        notifyListeners();
        return;
      }
      _payload = res is Map ? Map<String, dynamic>.from(res) : null;
      _forAuthUserId = live;
      _probed = true;
      RenderLog.write('c629_delivery_role',
          'is_partner=${(_payload?['is_partner'] as bool?) ?? false};'
          'is_agency=${(_payload?['is_agency'] as bool?) ?? false}');
    } catch (_) {
      // A failed probe is NOT "not a partner" — leave it unresolved so the
      // shell keeps rendering whatever surface my_session() already decided,
      // rather than guessing. The next auth change or refresh retries.
      _payload = null;
      _forAuthUserId = '';
      _probed = false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}

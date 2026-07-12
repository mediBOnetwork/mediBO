import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

/// Holds inquiry_lock_state() — whether new orders are currently blocked
/// because a supplier inquiry is running. Anon+authenticated callable; unlike
/// OrderHoursModel, this has NO admin/ViewAs exemption (enforced server-side
/// by trg_orders_inquiry_lock, deliberately — do not "harmonise" the two).
class InquiryLockModel extends ChangeNotifier {
  bool locked = false;
  String? message;
  bool loaded = false;

  Future<void> refresh() async {
    try {
      final res = await Supabase.instance.client.rpc('inquiry_lock_state');
      final map = Map<String, dynamic>.from(res as Map);
      locked = map['locked'] as bool? ?? false;
      message = map['message'] as String?;
      loaded = true;
      RenderLog.write('c456_cust_inquiry_locked', locked.toString());
      notifyListeners();
    } catch (_) {
      // D2 — FAIL OPEN on the fetch: never invent a block from a network
      // failure. The DB trigger enforces the lock regardless; leave whatever
      // was last known (or the true default above) in place.
    }
  }
}

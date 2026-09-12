// CHANGE #312 — the live wiring for the feature_gaps register.
//
// FeatureGapsScreen takes its two RPCs as callbacks so it stays Supabase-free
// and pumps on the Dart VM. That leaves the actual calls needing ONE home, or
// every entry point (the admin "More" menu, the /admin/feature-gaps URL) grows
// its own copy and they drift. This is that home.
import 'package:supabase_flutter/supabase_flutter.dart';

import '../screens/admin/feature_gaps_screen.dart';

Map<String, dynamic> _one(Object? raw) =>
    Map<String, dynamic>.from((raw is List ? raw.first : raw) as Map);

/// `feature_gaps_list(...)` — gates on is_admin() and answers not_authorized
/// itself, so nothing here guards anything.
Future<Map<String, dynamic>> featureGapsList(Map<String, dynamic> params) async =>
    _one(await Supabase.instance.client.rpc('feature_gaps_list', params: params));

/// `feature_gap_set_status(p_id, p_status)`.
Future<Map<String, dynamic>> featureGapSetStatus(int id, String status) async =>
    _one(await Supabase.instance.client
        .rpc('feature_gap_set_status', params: {'p_id': id, 'p_status': status}));

/// The screen with its live calls attached — the one construction every entry
/// point uses.
FeatureGapsScreen buildFeatureGapsScreen() => FeatureGapsScreen(
      listRpc: featureGapsList,
      statusRpc: featureGapSetStatus,
    );

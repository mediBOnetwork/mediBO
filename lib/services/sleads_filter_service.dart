// CMD #1868 — the four S Leads filter RPCs, in one place.
//
// Kept out of the widget so the filter row and its model stay mountable with
// no Supabase client (test/protected/sleads_filters_test.dart), and so the
// canonical filter map is passed straight through: it goes to the backend
// exactly as the backend returned it.

import 'package:supabase_flutter/supabase_flutter.dart';

class SLeadsFilterService {
  const SLeadsFilterService();

  static Map<String, dynamic> _map(Object? raw) =>
      raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};

  /// The whole filter row — chips, counts, toggles, slider, zone, views — for
  /// the filter state passed in.
  Future<Map<String, dynamic>> filters(Map<String, dynamic> state) async =>
      _map(await Supabase.instance.client
          .rpc('sleads_filters', params: {'p_filters': state}));

  /// "S Leads (N)" for the SAME filters the list is showing.
  Future<Map<String, dynamic>> count(Map<String, dynamic> state) async =>
      _map(await Supabase.instance.client
          .rpc('sleads_count', params: {'p_filters': state}));

  Future<Map<String, dynamic>> saveView(String name, Map<String, dynamic> state) async =>
      _map(await Supabase.instance.client
          .rpc('lead_view_save', params: {'p_name': name, 'p_filters': state}));

  Future<Map<String, dynamic>> applyView(int id) async =>
      _map(await Supabase.instance.client
          .rpc('lead_view_apply', params: {'p_id': id}));

  Future<Map<String, dynamic>> deleteView(int id) async =>
      _map(await Supabase.instance.client
          .rpc('lead_view_delete', params: {'p_id': id}));
}

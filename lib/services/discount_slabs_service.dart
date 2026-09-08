// CHANGE #318 — the live wiring for the discount ladder.
//
// AdminDiscountSlabsScreen takes its four RPCs as callbacks so it stays
// Supabase-free and pumps on the Dart VM. That leaves the actual calls needing
// ONE home, or every entry point grows its own copy and they drift.
import 'package:supabase_flutter/supabase_flutter.dart';

import '../screens/admin/admin_discount_slabs_screen.dart';

Map<String, dynamic> _one(Object? raw) =>
    Map<String, dynamic>.from((raw is List ? raw.first : raw) as Map);

/// `admin_discount_slabs()` — gates on the caller's role and answers
/// not_authorized itself, so nothing here guards anything.
Future<Map<String, dynamic>> discountSlabsList() async =>
    _one(await Supabase.instance.client.rpc('admin_discount_slabs'));

/// `admin_discount_slab_save(p jsonb)` — insert when `id` is absent.
Future<Map<String, dynamic>> discountSlabSave(
        Map<String, dynamic> patch) async =>
    _one(await Supabase.instance.client
        .rpc('admin_discount_slab_save', params: {'p': patch}));

/// `admin_discount_slab_set_active(p_id, p_active)`.
Future<Map<String, dynamic>> discountSlabSetActive(int id, bool active) async =>
    _one(await Supabase.instance.client.rpc('admin_discount_slab_set_active',
        params: {'p_id': id, 'p_active': active}));

/// `admin_discount_slab_delete(p_id)`.
Future<Map<String, dynamic>> discountSlabDelete(int id) async =>
    _one(await Supabase.instance.client
        .rpc('admin_discount_slab_delete', params: {'p_id': id}));

/// The screen with its live calls attached — the one construction every entry
/// point uses.
AdminDiscountSlabsScreen buildDiscountSlabsScreen() =>
    AdminDiscountSlabsScreen(
      listRpc: discountSlabsList,
      saveRpc: discountSlabSave,
      setActiveRpc: discountSlabSetActive,
      deleteRpc: discountSlabDelete,
    );

// lib/screens/delivery/delivery_google_route.dart — CHANGE #629 (PART D)
//
// Road route for a delivery run, on the SAME framework as the Route tab.
//
// D1 — "reuse the Route tab's existing Google Directions code path, do NOT
// write a second one". The Route tab's path is: invoke the `google-route` edge
// function (which is the only thing in this codebase that talks to Google's
// Routes API — computeRoutes with optimizeWaypointOrder: true), then persist
// the answer through an *_apply_google() RPC. That is exactly what happens
// below; the only differences are the RPC it persists through
// (delivery_apply_google instead of route_apply_google) and the id type.
// `lead_id` is an opaque pass-through key in that function — whatever goes in
// comes back in Google's optimised order — so the Route tab keeps sending
// integer lead ids and the run sends delivery UUIDs, through one function.
//
// NO Distance/Route Matrix API is called from here (COST SAFETY rule):
// computeRoutes only, once, per run start / reassignment, ≤25 stops.
//
// D6 — automatic. There is no "optimise" button anywhere; this fires when the
// trip starts and after a reassignment. It can never block or crash the screen:
// every failure path returns quietly and leaves the backend's own
// nearest-neighbour ordering (already applied by delivery_optimize_run) in
// place, so the stop list is never unordered.

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/device_location.dart';
import '../../utils/render_log.dart';

class DeliveryGoogleRoute {
  DeliveryGoogleRoute._();

  /// Optimises [runId] and writes the result back. Returns the
  /// delivery_apply_google() payload, or null when nothing was applied.
  ///
  /// Never throws.
  static Future<Map<String, dynamic>?> optimise(String runId) async {
    try {
      final client = Supabase.instance.client;

      // 1. The run's stops, as the backend sees them.
      final mapRes = await client.rpc('delivery_run_map', params: {'p_run_id': runId});
      if (mapRes is! Map) return null;
      final map = Map<String, dynamic>.from(mapRes);
      if (map['has_run'] != true) return null;

      final waypoints = ((map['waypoints'] as List?) ?? [])
          .map((w) => Map<String, dynamic>.from(w as Map))
          .toList();
      if (waypoints.isEmpty) return null;

      // delivery_apply_google() rejects anything that is not EXACTLY the run's
      // open stops (its own words: status not in ('delivered','cancelled') ->
      // otherwise stop_count_mismatch). delivery_run_map returns delivered
      // stops too, so the same backend predicate is applied to the backend's
      // own `status` value to build the argument list. This is constructing an
      // RPC argument to the contract the RPC states, not deciding what to show.
      final open = waypoints
          .where((w) => w['status'] != 'delivered' && w['status'] != 'cancelled')
          .toList();
      if (open.isEmpty) return null;
      // Google's own cap, mirrored by the edge function.
      if (open.length > 25) {
        RenderLog.write('c629_google_route_skipped', 'stops=${open.length}');
        return null;
      }

      // 2. Origin = the rider's live position (D3). Falls back to the position
      // the backend already has from the heartbeat.
      final fix = await DeviceLocation.current();
      final originLat = fix?.lat ?? (map['origin_lat'] as num?)?.toDouble();
      final originLng = fix?.lng ?? (map['origin_lng'] as num?)?.toDouble();
      if (originLat == null || originLng == null) return null;

      final stops = <Map<String, dynamic>>[];
      for (final w in open) {
        final id = w['delivery_id']?.toString();
        final lat = (w['lat'] as num?)?.toDouble();
        final lng = (w['lng'] as num?)?.toDouble();
        // A stop with no pin cannot be routed; the backend's count would then
        // disagree with ours, and it says so via stop_count_mismatch. Bail out
        // rather than send a list we know is short.
        if (id == null || lat == null || lng == null) return null;
        stops.add({'lead_id': id, 'lat': lat, 'lng': lng});
      }

      // 3. The Route tab's call, unchanged in shape: hub + origin + stops, with
      // waypoint optimisation on inside the function.
      final res = await client.functions.invoke('google-route', body: {
        'hub': {'lat': originLat, 'lng': originLng},
        'origin': {'lat': originLat, 'lng': originLng},
        'stops': stops,
      });
      final data = res.data;
      if (data is! Map || data['error'] != null) return null;

      final optimisedIds = (data['optimised_lead_ids'] as List?)
          ?.map((e) => e.toString())
          .toList();
      if (optimisedIds == null || optimisedIds.length != stops.length) return null;

      final polyline = data['encoded_polyline']?.toString();

      // Per-leg figures, in the driven order. Google returns one leg per hop,
      // including the final hop back to the start; delivery_apply_google reads
      // only legs 1..n (leg i = the drive INTO stop i), so the trailing return
      // leg is dropped here rather than sent and ignored.
      final legMeters = ((data['leg_meters'] as List?) ?? [])
          .map((e) => (e as num).round())
          .toList();
      final legSeconds = ((data['leg_seconds'] as List?) ?? [])
          .map((e) => (e as num).round())
          .toList();
      final n = optimisedIds.length;

      // 4. Persist. The backend recomputes seq, leg_km, cum_km, eta_min,
      // total_km and total_min from these — none of that is worked out here.
      final applied = await client.rpc('delivery_apply_google', params: {
        'p_run_id': runId,
        'p_optimised_delivery_ids': optimisedIds,
        'p_polyline': polyline,
        'p_leg_meters': legMeters.length >= n ? legMeters.sublist(0, n) : null,
        'p_leg_seconds': legSeconds.length >= n ? legSeconds.sublist(0, n) : null,
        'p_origin_lat': originLat,
        'p_origin_lng': originLng,
      });

      if (applied is Map) {
        final out = Map<String, dynamic>.from(applied);
        RenderLog.write('c629_google_route_applied',
            'ok=${out['ok']};stops=${out['stops'] ?? 0};legs=${legMeters.length}');
        return out;
      }
      return null;
    } catch (_) {
      // Google/network/quota failure -> the run keeps the backend's
      // nearest-neighbour order. Never surfaced as a crash.
      return null;
    }
  }
}

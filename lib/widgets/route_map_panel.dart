// CHANGE #453 — Routes tab map. flutter_map + OpenStreetMap tiles, ₹0, no
// Google Maps SDK. DUMB: this widget only DRAWS. Every point, colour, bounds
// and label comes straight from route_plan_map()'s payload — no bounds/centre/
// zoom/colour computation happens here. The one permitted piece of local logic
// is the tiny hex-string -> Color parser below (display encoding, not geometry).
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;

Color hexToColor(String? hex, {Color fallback = Colors.grey}) {
  if (hex == null || hex.isEmpty) return fallback;
  var h = hex.replaceFirst('#', '');
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return v != null ? Color(v) : fallback;
}

class RouteMapPanel extends StatelessWidget {
  final Map<String, dynamic> mapData;
  final bool isDesktop;
  final void Function(String routeId) onSelectRoute;
  final void Function(Map<String, dynamic> marker) onTapStopMarker;

  const RouteMapPanel({
    super.key,
    required this.mapData,
    required this.isDesktop,
    required this.onSelectRoute,
    required this.onTapStopMarker,
  });

  @override
  Widget build(BuildContext context) {
    final mode = mapData['mode']?.toString() ?? 'overview';
    final tileUrl = mapData['tile_url']?.toString() ?? '';
    final attribution = mapData['attribution']?.toString() ?? '';
    final center = Map<String, dynamic>.from(mapData['center'] as Map? ?? {});
    final bounds = Map<String, dynamic>.from(mapData['bounds'] as Map? ?? {});
    final hub = Map<String, dynamic>.from(mapData['hub'] as Map? ?? {});
    final routes = ((mapData['routes'] as List?) ?? [])
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();

    final sw = Map<String, dynamic>.from(bounds['sw'] as Map? ?? {});
    final ne = Map<String, dynamic>.from(bounds['ne'] as Map? ?? {});
    final llBounds = (sw['lat'] != null && ne['lat'] != null)
        ? LatLngBounds(
            ll.LatLng((sw['lat'] as num).toDouble(), (sw['lng'] as num).toDouble()),
            ll.LatLng((ne['lat'] as num).toDouble(), (ne['lng'] as num).toDouble()),
          )
        : null;
    final centerLatLng = center['lat'] != null
        ? ll.LatLng((center['lat'] as num).toDouble(), (center['lng'] as num).toDouble())
        : const ll.LatLng(21.25, 81.62);

    // ── B3 layer 2: one Polyline per route, points/order/colour AS GIVEN ────
    final polylines = <Polyline>[];
    // ── B3 layer 4: route markers (cluster pins in overview, stop pins in detail)
    final routeMarkers = <Marker>[];
    for (final r in routes) {
      final pts = ((r['polyline'] as List?) ?? [])
          .map((p) => ll.LatLng(((p as List)[0] as num).toDouble(), (p[1] as num).toDouble()))
          .toList();
      if (pts.length >= 2) {
        polylines.add(Polyline(
          points: pts,
          color: hexToColor(r['color']?.toString()),
          strokeWidth: mode == 'route' ? 4 : 3,
        ));
      }
      final markers = ((r['markers'] as List?) ?? [])
          .map((m) => Map<String, dynamic>.from(m as Map));
      for (final m in markers) {
        final isCluster = m['is_cluster'] == true;
        final openOk = m['open_ok'] != false; // absent (overview) or true -> ok
        final size = isCluster ? 40.0 : 32.0;
        routeMarkers.add(Marker(
          point: ll.LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()),
          width: size,
          height: size,
          child: GestureDetector(
            onTap: () {
              if (isCluster) {
                onSelectRoute(r['route_id'].toString());
              } else {
                onTapStopMarker(m);
              }
            },
            child: _pin(m['label']?.toString() ?? '', hexToColor(m['color']?.toString()),
                showWarn: !isCluster && !openOk),
          ),
        ));
      }
    }

    // ── B3 layer 3: hub marker, drawn first / distinct icon ─────────────────
    final hubMarker = hub['lat'] != null
        ? Marker(
            point: ll.LatLng((hub['lat'] as num).toDouble(), (hub['lng'] as num).toDouble()),
            width: 36,
            height: 36,
            child: Tooltip(
              message: hub['label']?.toString() ?? '',
              child: Icon(Icons.home_work, color: hexToColor(hub['color']?.toString()), size: 30),
            ),
          )
        : null;

    return SizedBox(
      height: isDesktop ? 420 : 320,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        // Keying on bounds forces FlutterMap to remount (and re-fit its
        // camera) on every overview<->detail switch, instead of keeping the
        // previous camera position — the ONLY way this widget "moves" the
        // camera; no zoom/centre is ever computed, just re-applied from the
        // payload's own `bounds`.
        child: FlutterMap(
          key: ValueKey('$mode-${sw['lat']}-${sw['lng']}-${ne['lat']}-${ne['lng']}'),
          options: MapOptions(
            initialCenter: centerLatLng,
            initialCameraFit: llBounds != null
                ? CameraFit.bounds(bounds: llBounds, padding: const EdgeInsets.all(24))
                : null,
          ),
          children: [
            TileLayer(
              urlTemplate: tileUrl,
              userAgentPackageName: 'in.medibo.app',
            ),
            PolylineLayer(polylines: polylines),
            if (hubMarker != null) MarkerLayer(markers: [hubMarker]),
            MarkerLayer(markers: routeMarkers),
            Align(
              alignment: Alignment.bottomRight,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                color: Colors.white70,
                child: Text(attribution,
                    style: const TextStyle(fontSize: 9, color: Colors.black87)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pin(String label, Color color, {bool showWarn = false}) {
    return Stack(clipBehavior: Clip.none, children: [
      Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
      ),
      if (showWarn)
        const Positioned(
          right: -3, top: -3,
          child: Icon(Icons.warning, size: 13, color: Color(0xFFB45309)),
        ),
    ]);
  }
}

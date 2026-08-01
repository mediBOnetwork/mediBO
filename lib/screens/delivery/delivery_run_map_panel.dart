// lib/screens/delivery/delivery_run_map_panel.dart — CHANGE #629 (PART B2/B3, D5)
//
// The map at the top of the rider screen. DUMB, like every other map in this
// app: it draws the stops it is handed, in the colour the backend chose.
//
// B3 — "Render pin_color verbatim; do not map statuses to colours in Dart."
// There is no status -> colour table anywhere in this file. The only thing done
// to `pin_color` is parsing the backend's own hex string into a Color so the
// canvas can paint it; if the backend changes a colour, this file needs no
// change and no deploy.
//
// D5 — the road polyline is delivery_runs.road_polyline, decoded with the SAME
// decoder the Route tab's map uses (decodeEncodedPolyline, exported from
// route_google_map_panel.dart). No second decoder, no second polyline library.
//
// CHANGE #634 — the base map is now AdaptiveMap, so provider/tiles/key come
// from map_config_get() like every other map surface. Pins, colours and
// ordering are untouched.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../utils/render_log.dart';
import '../../widgets/adaptive_map.dart';
import '../../widgets/route_google_map_panel.dart' show decodeEncodedPolyline;

/// Parses the backend's `#RRGGBB`. Returns null when absent/malformed so the
/// caller can fall back to Google's default marker rather than inventing a
/// colour of its own.
Color? colorFromBackendHex(String? hex) {
  final h = (hex ?? '').trim().replaceFirst('#', '');
  if (h.length != 6 && h.length != 8) return null;
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? null : Color(v);
}

class DeliveryRunMapPanel extends StatefulWidget {
  /// Stops to pin. Each needs lat, lng, pin_color and (optionally) seq +
  /// pharmacy_name — exactly the shape my_delivery_run().stops and
  /// delivery_run_map().waypoints both already have.
  final List<Map<String, dynamic>> stops;

  /// CHANGE #630 (D6): additional people to plot on this SAME map — an
  /// agency's riders, from agency_team().riders. Each needs lat, lng and name;
  /// rows without a fix are skipped rather than dropped at (0,0). They are
  /// deliberately NOT merged into [stops]: a rider is not a stop, has no
  /// pin_color and must not be numbered into the route sequence.
  final List<Map<String, dynamic>> extraMarkers;

  /// delivery_run_map().road_polyline — empty/absent draws no line.
  final String roadPolyline;

  /// The rider's position, when known.
  final double? originLat;
  final double? originLng;

  final double height;
  final void Function(Map<String, dynamic> stop)? onTapStop;

  const DeliveryRunMapPanel({
    super.key,
    required this.stops,
    this.extraMarkers = const [],
    this.roadPolyline = '',
    this.originLat,
    this.originLng,
    this.height = 260,
    this.onTapStop,
  });

  @override
  State<DeliveryRunMapPanel> createState() => _DeliveryRunMapPanelState();
}

class _DeliveryRunMapPanelState extends State<DeliveryRunMapPanel> {
  final Map<String, Uint8List> _iconCache = {};

  @override
  void initState() {
    super.initState();
    _prepareIcons();
  }

  @override
  void didUpdateWidget(covariant DeliveryRunMapPanel old) {
    super.didUpdateWidget(old);
    if (old.stops.length != widget.stops.length || _signature(old.stops) != _signature(widget.stops)) {
      _prepareIcons();
    }
  }

  String _signature(List<Map<String, dynamic>> stops) =>
      stops.map((s) => '${s['delivery_id']}:${s['pin_color']}:${s['seq']}').join(',');

  String _iconKey(Map<String, dynamic> s) {
    final label = (s['seq'] as num?)?.toInt().toString() ?? '';
    return '${s['pin_color'] ?? ''}|$label';
  }

  Future<void> _prepareIcons() async {
    for (final s in widget.stops) {
      final key = _iconKey(s);
      if (_iconCache.containsKey(key)) continue;
      final color = colorFromBackendHex(s['pin_color']?.toString());
      if (color == null) continue;
      final label = (s['seq'] as num?)?.toInt().toString() ?? '';
      _iconCache[key] = await _pinIcon(label, color);
    }
    _iconCache[_kRiderIcon] ??= await _dotIcon(_riderColor);
    _iconCache[_kMeIcon] ??= await _dotIcon(_meColor);
    if (mounted) setState(() {});
  }

  /// Teardrop pin, tip on the coordinate — same shape the Route tab's map uses
  /// (CHANGE #490), just painted in the colour the backend sent. Returns raw
  /// PNG bytes so the same art draws on either base map (#634).
  Future<Uint8List> _pinIcon(String label, Color bg) async {
    const double w = 32.0;
    const double h = 46.0;
    const double scale = 3.0;
    const double headR = w / 2;
    const double cx = w / 2;
    const double cy = headR;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w * scale, h * scale));
    canvas.scale(scale);

    const drawnR = headR - 1.5;
    final theta = 50 * math.pi / 180;
    final baseLeft = Offset(cx - drawnR * math.sin(theta), cy + drawnR * math.cos(theta));
    final baseRight = Offset(cx + drawnR * math.sin(theta), cy + drawnR * math.cos(theta));
    const tip = Offset(cx, h - 1);
    final headPath = Path()..addOval(Rect.fromCircle(center: const Offset(cx, cy), radius: drawnR));
    final tipPath = Path()
      ..moveTo(baseLeft.dx, baseLeft.dy)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(baseRight.dx, baseRight.dy)
      ..close();
    final pinPath = Path.combine(PathOperation.union, headPath, tipPath);

    canvas.drawPath(pinPath, Paint()..color = bg);
    canvas.drawPath(
      pinPath,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    if (label.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white,
            fontSize: label.length > 1 ? 12.0 : 14.0,
            fontWeight: FontWeight.w800,
            shadows: const [Shadow(color: Colors.black45, blurRadius: 1.5, offset: Offset(0, 0.5))],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage((w * scale).round(), (h * scale).round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  /// A small circular dot, used for riders and for the "me" marker — the two
  /// markers that carry no backend pin_color and must never be mistaken for a
  /// numbered delivery stop.
  Future<Uint8List> _dotIcon(Color bg) async {
    const size = 36.0;
    const scale = 3.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size * scale, size * scale));
    canvas.scale(scale);
    const centre = Offset(size / 2, size / 2);
    canvas.drawCircle(centre, size / 2 - 3, Paint()..color = bg);
    canvas.drawCircle(
      centre, size / 2 - 3,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage((size * scale).round(), (size * scale).round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    final pins = <MapPin>[];

    for (var i = 0; i < widget.stops.length; i++) {
      final s = widget.stops[i];
      final lat = (s['lat'] as num?)?.toDouble();
      final lng = (s['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      final seq = (s['seq'] as num?)?.toInt() ?? (i + 1);
      pins.add(MapPin(
        id: 'stop_${s['delivery_id'] ?? i}',
        lat: lat,
        lng: lng,
        iconBytes: _iconCache[_iconKey(s)],
        tipAtPoint: true,
        fallbackColor: colorFromBackendHex(s['pin_color']?.toString()),
        title: s['pharmacy_name']?.toString() ?? '',
        zIndex: 1000 - seq,
        onTap: widget.onTapStop == null ? null : () => widget.onTapStop!(s),
      ));
    }

    // D6 — an agency's riders, in a distinct hue so they can never be mistaken
    // for a delivery stop. No status is read and no colour is chosen per rider.
    for (var i = 0; i < widget.extraMarkers.length; i++) {
      final e = widget.extraMarkers[i];
      final lat = (e['lat'] as num?)?.toDouble();
      final lng = (e['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      pins.add(MapPin(
        id: 'rider_${e['partner_id'] ?? i}',
        lat: lat,
        lng: lng,
        iconBytes: _iconCache[_kRiderIcon],
        iconWidth: 22,
        iconHeight: 22,
        tipAtPoint: false,
        fallbackColor: _riderColor,
        title: e['name']?.toString() ?? '',
        zIndex: 1500,
      ));
    }

    if (widget.originLat != null && widget.originLng != null) {
      pins.add(MapPin(
        id: 'me',
        lat: widget.originLat!,
        lng: widget.originLng!,
        iconBytes: _iconCache[_kMeIcon],
        iconWidth: 22,
        iconHeight: 22,
        tipAtPoint: false,
        fallbackColor: _meColor,
        zIndex: 2000,
      ));
    }

    List<MapPoint> road = const [];
    if (widget.roadPolyline.isNotEmpty) {
      try {
        road = decodeEncodedPolyline(widget.roadPolyline);
      } catch (_) {
        road = const [];
      }
    }

    RenderLog.write('c629_delivery_map', pins.length.toString());
    if (road.length >= 2) {
      RenderLog.write('c629_delivery_road_polyline', road.length.toString());
    }

    return AdaptiveMap(
      pins: pins,
      lines: [
        if (road.length >= 2)
          MapLine(
            id: 'run',
            points: road,
            color: const Color(0xFF1B7A43),
            width: 5,
          ),
      ],
      cameraSignature: '${_signature(widget.stops)}|${widget.extraMarkers.length}|${road.length}',
      height: widget.height,
      logKey: 'c634_delivery_map',
    );
  }
}

// Rider / "me" marker colours. Not derived from any status — these two markers
// have no backend pin_color because they are not delivery stops. They replace
// google_maps_flutter's hueViolet / hueAzure defaults, which only existed while
// the map was hard-wired to Google.
const Color _riderColor = Color(0xFF7C3AED);
const Color _meColor = Color(0xFF2563EB);
const String _kRiderIcon = '__rider__';
const String _kMeIcon = '__me__';

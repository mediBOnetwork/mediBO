// lib/widgets/route_live_workers_map.dart — CMD #1878
//
// The live card on the Routes tab: a map with one dot per worker who is
// sharing a location, plus the share toggle a rep uses to turn his own dot on
// and the "N check-ins pending sync" chip.
//
// DUMB, like every map surface here. It draws route_worker_dots() and nothing
// else: the title, the count line, the empty copy, each dot's label, its
// initials, its age ("7 min ago") and its tone are the backend's answers. This
// file does not know what "stale" means, cannot pluralise, and never decides
// a colour from a number.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../screens/admin/route_stop_checkin_sheet.dart' show routeStopToneColor;
import '../utils/render_log.dart';
import 'adaptive_map.dart';

/// The card's pure reads of route_worker_dots(). Testable without a widget.
class RouteLivePlan {
  const RouteLivePlan._();

  static List<Map<String, dynamic>> dots(Map<String, dynamic>? live) =>
      ((live?['dots'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((e) => e['lat'] != null && e['lng'] != null)
          .toList();

  /// The card is drawn when the backend served this caller at all. ok:false
  /// (partner staff) draws nothing rather than an error.
  static bool shows(Map<String, dynamic>? live) => live?['ok'] == true;

  /// Only a lead worker can share; an admin watches.
  static bool canShare(Map<String, dynamic>? live) => live?['can_share'] == true;

  static int pingMs(Map<String, dynamic>? live) {
    final v = live?['ping_ms'];
    return v is num ? v.toInt() : 15000;
  }

  static int pollMs(Map<String, dynamic>? live) {
    final v = live?['poll_ms'];
    return v is num ? v.toInt() : 20000;
  }

  static String channel(Map<String, dynamic>? live) =>
      live?['channel']?.toString() ?? '';
}

class RouteLiveWorkersMap extends StatefulWidget {
  /// route_worker_dots() verbatim.
  final Map<String, dynamic> live;

  /// The pending-sync chip's caption, already worded by the backend. Null when
  /// nothing is queued — the chip is then absent, not a "0 pending" string.
  final String? pendingLabel;

  /// The offline banner's copy, when the screen is rendering a cached bundle.
  final String? offlineLabel;

  final bool sharing;
  final String? deniedLabel;
  final VoidCallback? onToggleShare;
  final VoidCallback? onRetrySync;
  final String? retryLabel;
  final bool isDesktop;

  const RouteLiveWorkersMap({
    super.key,
    required this.live,
    this.pendingLabel,
    this.offlineLabel,
    this.sharing = false,
    this.deniedLabel,
    this.onToggleShare,
    this.onRetrySync,
    this.retryLabel,
    this.isDesktop = false,
  });

  @override
  State<RouteLiveWorkersMap> createState() => _RouteLiveWorkersMapState();
}

class _RouteLiveWorkersMapState extends State<RouteLiveWorkersMap> {
  final Map<String, Uint8List> _icons = {};

  @override
  void initState() {
    super.initState();
    _prepareIcons();
  }

  @override
  void didUpdateWidget(covariant RouteLiveWorkersMap old) {
    super.didUpdateWidget(old);
    _prepareIcons();
  }

  Future<void> _prepareIcons() async {
    final wanted = <String, Color>{};
    for (final d in RouteLivePlan.dots(widget.live)) {
      final label = d['marker_label']?.toString() ?? '';
      final tone = d['tone']?.toString();
      wanted['$tone|$label'] = routeStopToneColor(tone);
    }
    var added = false;
    for (final e in wanted.entries) {
      if (_icons.containsKey(e.key)) continue;
      _icons[e.key] = await _dotIcon(e.key.split('|').last, e.value);
      added = true;
    }
    if (added && mounted) setState(() {});
  }

  /// A round "worker" dot with the initials the backend sent. Deliberately a
  /// circle, not the teardrop the stops use: a person is at a point, a stop
  /// is a place.
  Future<Uint8List> _dotIcon(String label, Color bg) async {
    const size = 78.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size, size));
    const center = Offset(size / 2, size / 2);
    canvas.drawCircle(center, size / 2 - 10,
        Paint()..color = bg.withValues(alpha: 0.25));
    canvas.drawCircle(center, size / 2 - 16, Paint()..color = bg);
    canvas.drawCircle(
        center,
        size / 2 - 16,
        Paint()
          ..color = Ds.c.surface
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5);
    final tp = TextPainter(
      text: TextSpan(
          text: label,
          style: TextStyle(
              color: Ds.c.surface,
              fontSize: Ds.t.captionSize + Ds.space.x12,
              fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas,
        Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
    final image =
        await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.live;
    if (!RouteLivePlan.shows(live)) return const SizedBox.shrink();
    final dots = RouteLivePlan.dots(live);
    RenderLog.write('c1878_live_card', 1);
    RenderLog.write('c1878_live_dots', dots.length);

    final pins = <MapPin>[];
    for (final d in dots) {
      final lat = (d['lat'] as num?)?.toDouble();
      final lng = (d['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      final tone = d['tone']?.toString();
      final label = d['marker_label']?.toString() ?? '';
      pins.add(MapPin(
        id: 'worker_${d['worker_id']}',
        lat: lat,
        lng: lng,
        iconBytes: _icons['$tone|$label'],
        iconWidth: Ds.space.x32,
        iconHeight: Ds.space.x32,
        tipAtPoint: false,
        fallbackColor: routeStopToneColor(tone),
        title: '${d['label'] ?? ''} · ${d['age_label'] ?? ''}',
        zIndex: d['is_me'] == true ? 2000 : 1500,
      ));
    }

    final children = <Widget>[
      Row(children: [
        Expanded(
            child: Text(live['title']?.toString() ?? '', style: Ds.t.subtitle)),
        if ((live['count_label']?.toString() ?? '').isNotEmpty)
          Text(live['count_label'].toString(), style: Ds.t.caption),
      ]),
    ];

    if (widget.offlineLabel != null && widget.offlineLabel!.isNotEmpty) {
      children
        ..add(SizedBox(height: Ds.space.x8))
        ..add(_banner(widget.offlineLabel!, 'warning'));
    }

    final chips = <Widget>[];
    if (widget.pendingLabel != null && widget.pendingLabel!.isNotEmpty) {
      chips.add(_chip(widget.pendingLabel!, 'warning'));
    }
    if (widget.deniedLabel != null && widget.deniedLabel!.isNotEmpty) {
      chips.add(_chip(widget.deniedLabel!, 'danger'));
    }
    if (chips.isNotEmpty) {
      children
        ..add(SizedBox(height: Ds.space.x12))
        ..add(Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: chips));
    }

    children.add(SizedBox(height: Ds.space.x12));
    if (pins.isEmpty) {
      children.add(Text(live['empty_label']?.toString() ?? '',
          style: Ds.t.bodySecondary));
    } else {
      children.add(AdaptiveMap(
        pins: pins,
        cameraSignature: 'c1878|${pins.length}',
        height: widget.isDesktop ? Ds.space.x48 * 6 : Ds.space.x48 * 4,
        borderRadius: Ds.r.rCard,
        logKey: 'c1878_live_map',
      ));
      children.add(SizedBox(height: Ds.space.x12));
      for (final d in dots) {
        children.add(_dotRow(d));
      }
    }

    if (RouteLivePlan.canShare(live) && widget.onToggleShare != null) {
      children
        ..add(SizedBox(height: Ds.space.x16))
        ..add(SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: OutlinedButton.icon(
            onPressed: widget.onToggleShare,
            icon: Icon(widget.sharing
                ? Icons.location_on_rounded
                : Icons.location_searching_rounded),
            label: Text((widget.sharing
                    ? live['share_on_label']
                    : live['share_off_label'])
                ?.toString() ??
                ''),
          ),
        ));
      final hint = live['share_hint']?.toString() ?? '';
      if (hint.isNotEmpty) {
        children
          ..add(SizedBox(height: Ds.space.x4))
          ..add(Text(hint, style: Ds.t.caption));
      }
    }

    if (widget.onRetrySync != null &&
        (widget.retryLabel ?? '').isNotEmpty &&
        widget.pendingLabel != null) {
      children
        ..add(SizedBox(height: Ds.space.x8))
        ..add(SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: TextButton(
              onPressed: widget.onRetrySync, child: Text(widget.retryLabel!)),
        ));
    }

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x16),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      ),
    );
  }

  Widget _dotRow(Map<String, dynamic> d) {
    final sub = d['sub_label']?.toString() ?? '';
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: Row(children: [
        Container(
          width: Ds.space.x8,
          height: Ds.space.x8,
          decoration: BoxDecoration(
              color: routeStopToneColor(d['tone']?.toString()),
              shape: BoxShape.circle),
        ),
        SizedBox(width: Ds.space.x8),
        Expanded(
          child: Text(
              sub.isEmpty
                  ? (d['label']?.toString() ?? '')
                  : '${d['label'] ?? ''} · $sub',
              style: Ds.t.body,
              overflow: TextOverflow.ellipsis),
        ),
        SizedBox(width: Ds.space.x8),
        Text(d['age_label']?.toString() ?? '', style: Ds.t.caption),
      ]),
    );
  }

  Widget _chip(String label, String tone) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x4),
        decoration: BoxDecoration(
            color: routeStopToneSoftLocal(tone), borderRadius: Ds.r.rChip),
        child: Text(label, style: Ds.t.caption),
      );

  Widget _banner(String label, String tone) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
            color: routeStopToneSoftLocal(tone), borderRadius: Ds.r.rChip),
        child: Text(label, style: Ds.t.caption),
      );
}

/// Tone -> tint, through the token layer. Kept here rather than imported so
/// this widget has one import into the screens folder, not two.
Color routeStopToneSoftLocal(String? tone) {
  switch (tone) {
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    case 'brand':
      return Ds.c.brandSoft;
    case 'info':
      return Ds.c.infoSoft;
    default:
      return Ds.c.bg;
  }
}

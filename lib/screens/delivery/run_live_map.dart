// lib/screens/delivery/run_live_map.dart — CHANGE #700
//
// The rider's dot, live, on the ONE widget both the customer sheet and the
// admin queue open. Two callers, one behaviour — the same reason #629 gave the
// tracking view one widget and two callers.
//
// WHAT CHANGED UNDERNEATH IT
// The customer view used to subscribe to postgres_changes on
// delivery_partner_locations. That table is not in the supabase_realtime
// publication (it holds eight tables and that is the budget), so the
// subscription never received a single event and the map was a photograph that
// refreshed when you reopened the sheet. This listens to a run-scoped BROADCAST
// instead — topic run:<run_id>, private, gated by an RLS policy on
// realtime.messages — so a customer's socket carries the rider bringing THEIR
// order and nothing else.
//
// WHAT THIS WIDGET DECIDES: where to draw the marker between two points, and
// nothing else. The coordinates are the backend's (map_lat/map_lng — already
// road-snapped where OSRM answered), the animation duration is the backend's
// (animate_ms), the staleness sentence is the backend's (live.label), its
// colour is chosen from the backend's own tone name, and the "Showing raw GPS"
// note is a backend string. There is no threshold, no formatting and no
// wording in this file.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import 'delivery_run_map_panel.dart';

/// One rider position, exactly as a payload described it.
class RiderPoint {
  final double lat;
  final double lng;
  final bool snapped;

  const RiderPoint(this.lat, this.lng, this.snapped);

  static RiderPoint? from(Map<String, dynamic> m) {
    // map_lat/map_lng is the pair the backend says to plot: the snapped point
    // when it has one, the raw point when it does not. The choice is made
    // server-side precisely so two maps can never disagree about it.
    final lat = (m['map_lat'] ?? m['rider_lat'] ?? m['lat']) as num?;
    final lng = (m['map_lng'] ?? m['rider_lng'] ?? m['lng']) as num?;
    if (lat == null || lng == null) return null;
    final snapped = m['snapped'] == true || m['rider_snapped'] == true;
    return RiderPoint(lat.toDouble(), lng.toDouble(), snapped);
  }

  /// Straight-line interpolation between the last two points the BACKEND sent.
  /// Straight because those points are already road-snapped: bending them again
  /// here would be this app inventing a path it was never told about.
  static RiderPoint lerp(RiderPoint? a, RiderPoint? b, double t) {
    if (b == null) return a ?? const RiderPoint(0, 0, false);
    if (a == null || t >= 1.0) return b;
    if (t <= 0.0) return a;
    return RiderPoint(
      a.lat + (b.lat - a.lat) * t,
      a.lng + (b.lng - a.lng) * t,
      b.snapped,
    );
  }
}

/// A frame off the run channel. A database broadcast arrives wrapped —
/// {type, event, payload} — so the envelope is opened in exactly one place
/// rather than every reader learning about it.
class RunLiveFrame {
  RunLiveFrame._();

  static Map<String, dynamic> unwrap(Map<String, dynamic> raw) =>
      raw['payload'] is Map
          ? Map<String, dynamic>.from(raw['payload'] as Map)
          : raw;
}

/// The live map: stops + an animated rider marker + the backend's staleness
/// line. [channel] empty means there is nothing to listen to (no run yet, or
/// the stop is already finished) — the map still draws the last known point.
class RunLiveMap extends StatefulWidget {
  final String channel;
  final List<Map<String, dynamic>> stops;
  final RiderPoint? initialPoint;

  /// The backend's `live` block: has / is_live / state / label / tone / age_s.
  final Map<String, dynamic> live;

  /// The backend's sentence for an unsnapped point. Empty when it snapped.
  final String note;

  final int animateMs;
  final double height;
  final String roadPolyline;

  /// Called when a frame arrives, so the host can re-read its own RPC if it
  /// wants the rest of the payload refreshed too. Throttled by the host.
  final void Function(Map<String, dynamic> frame)? onFrame;

  const RunLiveMap({
    super.key,
    required this.channel,
    required this.stops,
    required this.live,
    this.initialPoint,
    this.note = '',
    this.animateMs = 1200,
    this.height = 240,
    this.roadPolyline = '',
    this.onFrame,
  });

  @override
  State<RunLiveMap> createState() => _RunLiveMapState();
}

class _RunLiveMapState extends State<RunLiveMap> with SingleTickerProviderStateMixin {
  RealtimeChannel? _channel;
  AnimationController? _anim;

  RiderPoint? _from;
  RiderPoint? _to;

  /// The newest `live` block seen — the payload's on arrival, the host's until
  /// then. Never recomputed here from a timestamp.
  Map<String, dynamic> _live = const {};
  String _note = '';

  @override
  void initState() {
    super.initState();
    _live = widget.live;
    _note = widget.note;
    _to = widget.initialPoint;
    _from = widget.initialPoint;
    _anim = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.animateMs),
    )..addListener(() {
        if (mounted) setState(() {});
      });
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant RunLiveMap old) {
    super.didUpdateWidget(old);
    // The host re-read its RPC: take its fresher words, but never let a stale
    // refetch drag the marker backwards behind a broadcast frame.
    if (widget.live != old.live) _live = widget.live;
    if (widget.note != old.note) _note = widget.note;
    if (widget.channel != old.channel) {
      _unsubscribe();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _anim?.dispose();
    _unsubscribe();
    super.dispose();
  }

  void _unsubscribe() {
    final ch = _channel;
    _channel = null;
    if (ch == null) return;
    try {
      Supabase.instance.client.removeChannel(ch);
    } catch (_) {}
  }

  void _subscribe() {
    if (widget.channel.isEmpty) return;
    try {
      final ch = Supabase.instance.client.channel(
        widget.channel,
        opts: const RealtimeChannelConfig(private: true),
      );
      ch.onBroadcast(event: 'rider', callback: _onFrame).subscribe();
      _channel = ch;
      RenderLog.write('c700_live_sub', widget.channel);
    } catch (_) {
      // No socket — the map keeps the point it was handed. A tracking view
      // that throws is worse than one that stops moving.
    }
  }

  void _onFrame(Map<String, dynamic> raw) {
    if (!mounted) return;
    final payload = RunLiveFrame.unwrap(raw);
    final next = RiderPoint.from(payload);
    RenderLog.write('c700_live_frame', '1');
    setState(() {
      if (payload['live'] is Map) {
        _live = Map<String, dynamic>.from(payload['live'] as Map);
      }
      _note = payload['note']?.toString() ?? '';
      if (next != null) {
        _from = _current() ?? next;
        _to = next;
        final ms = (payload['animate_ms'] as num?)?.toInt() ?? widget.animateMs;
        _anim
          ?..duration = Duration(milliseconds: ms)
          ..forward(from: 0);
      }
    });
    widget.onFrame?.call(payload);
  }

  /// Where the marker is right now, between the last two points the backend
  /// sent. The maths is [RiderPoint.lerp] so it can be tested without a map.
  RiderPoint? _current() {
    if (_to == null) return null;
    return RiderPoint.lerp(_from, _to, _anim?.value ?? 1.0);
  }

  /// The tone NAME is the backend's; only its colour is looked up here, the
  /// same way pin_color is parsed rather than chosen.
  Color _toneColor(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      case 'info':
        return Ds.c.info;
      default:
        return Ds.c.textSecondary;
    }
  }

  Color _toneBg(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.successSoft;
      case 'warning':
        return Ds.c.warningSoft;
      case 'danger':
        return Ds.c.dangerSoft;
      case 'info':
        return Ds.c.infoSoft;
      default:
        return Ds.c.bg;
    }
  }

  @override
  Widget build(BuildContext context) {
    final here = _current();
    final label = _live['label']?.toString() ?? '';
    final tone = _live['tone']?.toString() ?? 'muted';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x8),
            child: Row(
              children: [
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12, vertical: Ds.space.x4),
                  decoration: BoxDecoration(
                    color: _toneBg(tone),
                    borderRadius: Ds.r.rChip,
                  ),
                  child: Text(label,
                      style: Ds.t.caption.copyWith(color: _toneColor(tone))),
                ),
                if (_note.isNotEmpty) ...[
                  SizedBox(width: Ds.space.x8),
                  Flexible(
                    child: Text(_note,
                        style: Ds.t.caption, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ],
            ),
          ),
        DeliveryRunMapPanel(
          stops: widget.stops,
          roadPolyline: widget.roadPolyline,
          originLat: here?.lat,
          originLng: here?.lng,
          height: widget.height,
        ),
      ],
    );
  }
}

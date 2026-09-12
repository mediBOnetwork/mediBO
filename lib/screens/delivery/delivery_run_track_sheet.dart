// lib/screens/delivery/delivery_run_track_sheet.dart — CMD #454 (feature_gaps #116)
//
// The register's complaint was that delivery_partner_locations is keyed on
// partner_id and every fix overwrote the last one, so there was "no breadcrumb
// trail for a delivery dispute, no proof of the route taken, no way to verify
// distance for payout, and the customer's map can only ever show a dot".
//
// The trail now exists (delivery_partner_location_history) and
// delivery_run_track() reads it. This sheet is the surface that makes it
// reachable: ops opens it from the delivery row's "Route taken" action.
//
// It computes nothing. The point count, the distance and the distance sentence
// are all printed exactly as the RPC sent them — including the empty state's
// wording.
//
// CHANGE #700 — the same sheet is now the ADMIN'S LIVE MAP. It was a list of
// coordinates: true history, but useless for "where is that rider right now",
// which is the question ops actually asks while a round is running. The live
// half subscribes to the run's broadcast through RunLiveMap — the SAME widget
// the customer sheet uses, so the two can never show a different dot — and
// prints the backend's own staleness line above it. The trail list below is
// unchanged, and is what a dispute is settled with.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import 'run_live_map.dart';

class DeliveryRunTrackSheet extends StatefulWidget {
  const DeliveryRunTrackSheet({super.key, required this.runId});

  final String runId;

  /// Opens the sheet. Kept here so every caller opens it the same way.
  static Future<void> open(BuildContext context, String runId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
      ),
      builder: (_) => DeliveryRunTrackSheet(runId: runId),
    );
  }

  @override
  State<DeliveryRunTrackSheet> createState() => _DeliveryRunTrackSheetState();
}

class _DeliveryRunTrackSheetState extends State<DeliveryRunTrackSheet> {
  Map<String, dynamic>? _data;

  /// delivery_live_state() — the rider's current point, the channel to listen
  /// on, and the staleness sentence. A separate payload from the trail on
  /// purpose: one answers "where now", the other "where has it been", and
  /// merging them would make a composite this screen owns.
  Map<String, dynamic> _live = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = Supabase.instance.client;
    try {
      final res = await client
          .rpc('delivery_run_track', params: {'p_run_id': widget.runId});
      if (!mounted) return;
      setState(() {
        _data = res is Map ? Map<String, dynamic>.from(res) : null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
    try {
      final live = await client
          .rpc('delivery_live_state', params: {'p_run_id': widget.runId});
      if (!mounted) return;
      if (live is Map && live['ok'] == true) {
        setState(() => _live = Map<String, dynamic>.from(live));
      }
    } catch (_) {
      // No live block -> the sheet is the trail it has always been.
    }
  }

  @override
  Widget build(BuildContext context) {
    final points = (_data?['points'] as List?) ?? const [];
    // The backend's own sentence, or its own refusal message. Never a Dart one.
    final subtitle = (_data?['distance_label'] ?? _data?['message'] ?? '').toString();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(c('delivery.track_title'), style: Ds.t.title),
          if (subtitle.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(subtitle, style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x16),
          // CHANGE #700 — the live half, shown only while the backend says
          // there is a rider position to show. Same widget as the customer's.
          if (_live['has_rider'] == true) ...[
            RunLiveMap(
              channel: _live['channel']?.toString() ?? '',
              stops: const [],
              live: _live['live'] is Map
                  ? Map<String, dynamic>.from(_live['live'] as Map)
                  : const {},
              note: _live['note']?.toString() ?? '',
              animateMs: (_live['animate_ms'] as num?)?.toInt() ?? 1200,
              initialPoint: RiderPoint.from(_live),
              height: 220,
            ),
            SizedBox(height: Ds.space.x24),
          ],
          if (_loading)
            const _TrackSkeleton()
          else if (points.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: Ds.space.x24),
              child: Text(c('delivery.track_empty'),
                  textAlign: TextAlign.center, style: Ds.t.bodySecondary),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: points.length,
                separatorBuilder: (_, _) => Divider(height: 1, color: Ds.c.divider),
                itemBuilder: (_, i) {
                  final p = Map<String, dynamic>.from(points[i] as Map);
                  return Padding(
                    padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
                    child: Row(children: [
                      Icon(Icons.circle, size: 8, color: Ds.c.brand),
                      SizedBox(width: Ds.space.x12),
                      Expanded(
                        child: Text('${p['lat']}, ${p['lng']}', style: Ds.t.body),
                      ),
                      Text(p['ts']?.toString() ?? '', style: Ds.t.caption),
                    ]),
                  );
                },
              ),
            ),
        ]),
      ),
    );
  }
}

/// A skeleton, not a bare spinner — the design QA checklist's loading rule.
class _TrackSkeleton extends StatelessWidget {
  const _TrackSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        3,
        (_) => Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x12),
          child: Container(
            height: Ds.space.x32,
            decoration: BoxDecoration(
              color: Ds.c.bg,
              borderRadius: Ds.r.rChip,
            ),
          ),
        ),
      ),
    );
  }
}

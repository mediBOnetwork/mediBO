// lib/screens/delivery/rider_leaderboard_sheet.dart — CHANGE #406 (PART 3)
//
// Riders never saw their own standing. The office has had it since #309 —
// admin_delivery_dashboard() prints drops, on-time and rating per rider — and
// the rider had no way to see the number they were being judged by.
//
// This is the SAME arithmetic, not a second one: delivery_leaderboard() reads
// _sla_block() for on-time and delivery_ratings over ninety days for the star,
// exactly as the dashboard does, so the rider and the office can never be
// looking at two different truths about the same week.
//
// The sheet computes nothing. Rank, the "#3 of 11" line, the You marker, the
// captions, the week, and the sentence shown when an agency has switched
// ranking off — all payload. An agency that opts out gets that sentence rather
// than a blank screen, because a screen that renders nothing is indistinguish-
// able from a screen that is broken.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

Future<void> showRiderLeaderboard(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => const RiderLeaderboardSheet(),
    );

class RiderLeaderboardSheet extends StatefulWidget {
  const RiderLeaderboardSheet({super.key});

  @override
  State<RiderLeaderboardSheet> createState() => _RiderLeaderboardSheetState();
}

class _RiderLeaderboardSheetState extends State<RiderLeaderboardSheet> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client.rpc('delivery_leaderboard');
      if (!mounted) return;
      setState(() {
        _p = res is Map ? Map<String, dynamic>.from(res) : const {};
        _loading = false;
      });
      if (_p['shown'] == true) RenderLog.write('c406_leaderboard', 1);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> _boards() =>
      (_p['boards'] as List?)
          ?.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList() ??
      const [];

  Widget _board(Map<String, dynamic> b) {
    final rows = (b['rows'] as List?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        const <Map<String, dynamic>>[];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(height: Ds.space.x24),
      Row(children: [
        Expanded(child: Text(b['title']?.toString() ?? '', style: Ds.t.subtitle)),
        Text(b['rank_label']?.toString() ?? '',
            style: Ds.t.bodyStrong.copyWith(color: Ds.c.brand)),
      ]),
      SizedBox(height: Ds.space.x12),
      if (rows.isEmpty)
        Text(_p['empty_label']?.toString() ?? '', style: Ds.t.caption)
      else
        Container(
          decoration: BoxDecoration(
            color: Ds.c.surface,
            border: Border.all(color: Ds.c.divider),
            borderRadius: Ds.r.rCard,
          ),
          child: Column(children: [
            // Column headers, in the backend's words and the backend's order.
            Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x16, vertical: Ds.space.x8),
              child: Row(children: [
                SizedBox(width: Ds.space.x32),
                const Expanded(child: SizedBox.shrink()),
                _head(b['drops_caption']),
                _head(b['on_time_caption']),
                _head(b['rating_caption']),
              ]),
            ),
            Divider(height: 1, color: Ds.c.divider),
            for (final r in rows) _row(r),
          ]),
        ),
    ]);
  }

  Widget _head(Object? label) => SizedBox(
        width: 64,
        child: Text(label?.toString() ?? '',
            style: Ds.t.caption, textAlign: TextAlign.right),
      );

  Widget _cell(Object? value, {bool strong = false}) => SizedBox(
        width: 64,
        child: Text(value?.toString() ?? '',
            style: strong ? Ds.t.bodyStrong : Ds.t.body,
            textAlign: TextAlign.right),
      );

  Widget _row(Map<String, dynamic> r) {
    final isMe = r['is_me'] == true;
    return Container(
      constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x16, vertical: Ds.space.x8),
      decoration: BoxDecoration(
        color: isMe ? Ds.c.brandSoft : Ds.c.surface,
        border: Border(top: BorderSide(color: Ds.c.divider, width: 0.5)),
      ),
      child: Row(children: [
        SizedBox(
          width: Ds.space.x32,
          child: Text('${r['rank'] ?? ''}',
              style: isMe
                  ? Ds.t.bodyStrong.copyWith(color: Ds.c.brand)
                  : Ds.t.bodySecondary),
        ),
        Expanded(
          child: Text(
            r['name']?.toString() ?? '',
            style: isMe ? Ds.t.bodyStrong.copyWith(color: Ds.c.brand) : Ds.t.body,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        _cell(r['drops'], strong: isMe),
        _cell(r['on_time_label'], strong: isMe),
        _cell(r['rating_label'], strong: isMe),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, scrollCtrl) => SingleChildScrollView(
          controller: scrollCtrl,
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x32),
          child: _loading
              ? Padding(
                  padding: EdgeInsets.symmetric(vertical: Ds.space.x48),
                  child: const Center(child: CircularProgressIndicator()),
                )
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_p['title']?.toString() ?? '', style: Ds.t.title),
                  SizedBox(height: Ds.space.x4),
                  Text(
                    // Opted out, or not a rider: whichever sentence the backend
                    // sent is the only one shown.
                    _p['shown'] == true
                        ? '${_p['subtitle'] ?? ''} · ${_p['week_label'] ?? ''}'
                        : (_p['message']?.toString() ?? ''),
                    style: Ds.t.caption,
                  ),
                  if (_p['shown'] == true)
                    for (final b in _boards()) _board(b),
                ]),
        ),
      );
}

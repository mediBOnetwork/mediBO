// lib/screens/admin/admin_sos_screen.dart — CHANGE #406 (PARTS 1 & 2, admin side)
//
// Two panels the delivery-ops screen hosts, both of them the office's half of
// something a rider or a customer started:
//
//   AdminSosPanel        — open rider SOS alerts: see it, own it, close it.
//   AdminReattemptPanel  — the stops we promised to try again, and the slot the
//                          customer asked for.
//
// WHY THE SOS PANEL EXISTS AT ALL, GIVEN THE PUSH. delivery_sos_raise() fires
// the urgent notify() route, which is what actually wakes somebody up. But a
// notification cannot be acknowledged, cannot be closed, and cannot be seen by
// the second person who picks up the phone — and until an SOS is CLOSED the
// rider's handset keeps streaming its position every ten seconds. A push with
// no screen behind it is an alert nobody can finish.
//
// WHY THE REATTEMPT PANEL EXISTS. delivery_fail() has been writing
// deliveries.next_attempt_on since it was written, and nothing has ever read
// it: admin_delivery_queue() is scoped to orders CREATED on the chosen date, so
// a stop failed on Monday for Tuesday was invisible on Tuesday. The customer's
// new reschedule would have written into the same void. This is the read.
//
// Neither panel words anything. Titles, empty states, chips, button labels and
// the status colour pairs are all payload.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

Color? _hex(Object? raw) {
  final s = (raw?.toString() ?? '').trim().replaceFirst('#', '');
  if (s.length != 6 && s.length != 8) return null;
  final v = int.tryParse(s.length == 6 ? 'FF$s' : s, radix: 16);
  return v == null ? null : Color(v);
}

List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

Widget _card({required String title, required List<Widget> children, Widget? trailing}) =>
    Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: Ds.t.subtitle)),
          ?trailing,
        ]),
        SizedBox(height: Ds.space.x12),
        ...children,
      ]),
    );

// ─────────────────────────────────────────────────────────────────────────────
// SOS
// ─────────────────────────────────────────────────────────────────────────────
class AdminSosPanel extends StatefulWidget {
  const AdminSosPanel({super.key});

  @override
  State<AdminSosPanel> createState() => _AdminSosPanelState();
}

class _AdminSosPanelState extends State<AdminSosPanel> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client
          .rpc('admin_sos_list', params: {'p_status': 'open'});
      if (!mounted) return;
      setState(() {
        _p = res is Map ? Map<String, dynamic>.from(res) : const {};
        _loading = false;
      });
      RenderLog.write('c406_admin_sos', _p['open_count'] ?? 0);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _act(Object? id, String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.rpc('admin_sos_action',
          params: {'p_id': id, 'p_action': action, 'p_note': null});
      if (!mounted) return;
      setState(() {
        // The write returns the recomputed list, so the panel never patches a
        // row itself and never shows a state the server did not produce.
        final m = res is Map ? Map<String, dynamic>.from(res) : const {};
        if (m['state'] is Map) _p = Map<String, dynamic>.from(m['state'] as Map);
        _busy = false;
      });
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _p['allowed'] != true) return const SizedBox.shrink();
    final rows = _rows(_p['rows']);

    return _card(
      title: _p['title']?.toString() ?? '',
      children: rows.isEmpty
          ? [Text(_p['empty_label']?.toString() ?? '', style: Ds.t.caption)]
          : [for (final r in rows) _row(r)],
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final colors = r['status_colors'] is Map
        ? Map<String, dynamic>.from(r['status_colors'] as Map)
        : const <String, dynamic>{};
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(r['rider']?.toString() ?? '', style: Ds.t.bodyStrong)),
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x4),
            decoration: BoxDecoration(
              color: _hex(colors['bg']) ?? Ds.c.dangerSoft,
              borderRadius: Ds.r.rChip,
            ),
            child: Text(r['status_label']?.toString() ?? '',
                style: Ds.t.caption.copyWith(color: _hex(colors['fg']) ?? Ds.c.danger)),
          ),
        ]),
        SizedBox(height: Ds.space.x4),
        Text(
          '${r['raised_label'] ?? ''} · ${r['phone'] ?? ''}',
          style: Ds.t.caption,
        ),
        SizedBox(height: Ds.space.x8),
        Row(children: [
          if ((r['map_url']?.toString() ?? '').isNotEmpty)
            _action(r['map_label'], () async {
              // The map link is the backend's own string; opening it is the
              // only thing this button does.
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => _MapLinkPage(url: r['map_url'].toString()),
              ));
            }),
          if (r['can_ack'] == true)
            _action(r['ack_label'], () => _act(r['id'], 'acknowledge')),
          if (r['can_resolve'] == true)
            _action(r['resolve_label'], () => _act(r['id'], 'resolve')),
        ]),
        Divider(height: Ds.space.x24, color: Ds.c.divider),
      ]),
    );
  }

  Widget _action(Object? label, VoidCallback onTap) => Padding(
        padding: EdgeInsets.only(right: Ds.space.x8),
        child: SizedBox(
          height: Ds.touch.minTarget,
          child: TextButton(
            onPressed: _busy ? null : onTap,
            child: Text(label?.toString() ?? '',
                style: Ds.t.bodyStrong.copyWith(color: Ds.c.brand)),
          ),
        ),
      );
}

/// The live location, shown rather than handed to another app — the admin app
/// is often already the thing in the operator's hand.
class _MapLinkPage extends StatelessWidget {
  final String url;
  const _MapLinkPage({required this.url});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Ds.c.bg,
        appBar: AppBar(backgroundColor: Ds.c.surface, elevation: 0),
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x24),
            child: SelectableText(url, style: Ds.t.body),
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// REATTEMPTS
// ─────────────────────────────────────────────────────────────────────────────
class AdminReattemptPanel extends StatefulWidget {
  const AdminReattemptPanel({super.key});

  @override
  State<AdminReattemptPanel> createState() => _AdminReattemptPanelState();
}

class _AdminReattemptPanelState extends State<AdminReattemptPanel> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // Both nulls are deliberate: scope_date() and scope_zone() are the
      // BACKEND's answer to "which date and zone is this admin looking at",
      // and every other delivery screen asks the same way.
      final res = await Supabase.instance.client
          .rpc('admin_reattempt_queue', params: {'p_date': null, 'p_zone': null});
      if (!mounted) return;
      setState(() {
        _p = res is Map ? Map<String, dynamic>.from(res) : const {};
        _loading = false;
      });
      RenderLog.write('c406_reattempt_queue', _p['count'] ?? 0);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _p['allowed'] != true) return const SizedBox.shrink();
    final rows = _rows(_p['rows']);

    return _card(
      title: _p['title']?.toString() ?? '',
      children: rows.isEmpty
          ? [Text(_p['empty_label']?.toString() ?? '', style: Ds.t.caption)]
          : [for (final r in rows) _row(r)],
    );
  }

  Widget _row(Map<String, dynamic> r) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(r['pharmacy_name']?.toString() ?? '',
                  style: Ds.t.bodyStrong, overflow: TextOverflow.ellipsis),
            ),
            if (r['is_overdue'] == true)
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x4),
                decoration: BoxDecoration(
                  color: Ds.c.warningSoft,
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(r['due_on']?.toString() ?? '',
                    style: Ds.t.caption.copyWith(color: Ds.c.warning)),
              ),
          ]),
          SizedBox(height: Ds.space.x4),
          // The customer's own words when they chose, the backend's auto line
          // when they did not. Never a blank chip and never a Dart default.
          Text(r['window_chip']?.toString() ?? '', style: Ds.t.caption),
          if ((r['fail_reason']?.toString() ?? '').isNotEmpty)
            Text(r['fail_reason']!.toString(), style: Ds.t.caption),
          Divider(height: Ds.space.x24, color: Ds.c.divider),
        ]),
      );
}

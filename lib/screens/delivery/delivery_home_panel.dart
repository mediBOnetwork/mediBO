// lib/screens/delivery/delivery_home_panel.dart — CHANGE #630 (PART B, PART C)
//
// The rider's home strip, above the map: shift control, today's tiles, and
// today's earnings — plus the History sheet.
//
// B2 — TILES ARE RENDERED, NEVER BUILT. my_delivery_home() returns tiles[] as
// {key, label, value, display?, colors{bg,fg}}. This file prints label, prints
// display when present and value otherwise, and paints with the colours it was
// handed. It does not know what "Distance" is, does not append "km" (the
// backend's `display` already says it), and does not decide that Failed should
// be red. Adding a fifth tile is a backend change and needs no deploy.
//
// B3 — the shift button's WORD and its ACTION both come from the payload
// (shift_button_label / shift_action). There is no on_shift ? 'End' : 'Start'
// anywhere here; that ternary lives in SQL, where the shift table can settle
// the question. The device position is sent with it, as specified.
//
// AN IMPORTANT ASYMMETRY, and why this panel can be absent:
// my_delivery_home() resolves only an ACTIVE partner (`and is_active`), while
// my_delivery_run() — which routes the login to this surface at all — matches
// any registration. So a registered-but-not-yet-approved rider reaches the
// delivery interface and this RPC answers allowed:false. That is not an error
// and is not treated as one: the payload carries its own empty_title and
// empty_note for exactly that state, and they are printed. It is the state
// Tittu was in before being approved through the new admin screen.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../fulfill/fulfill_lookups.dart';
import '../../services/device_location.dart';
import '../../utils/render_log.dart';

Color get _kGreen => FulfillLookups.instance.color('c_ff1b7a43', const Color(0xFF1B7A43));
Color get _kBorder => FulfillLookups.instance.color('c_ffe5e7eb', const Color(0xFFE5E7EB));
Color get _kText => FulfillLookups.instance.color('c_ff111827', const Color(0xFF111827));
Color get _kSub => FulfillLookups.instance.color('c_ff6b7280', const Color(0xFF6B7280));

String _ui(String k) => FulfillLookups.instance.ui(k);

Color? _hex(String? h) {
  final s = (h ?? '').trim().replaceFirst('#', '');
  if (s.length != 6 && s.length != 8) return null;
  final v = int.tryParse(s.length == 6 ? 'FF$s' : s, radix: 16);
  return v == null ? null : Color(v);
}

class DeliveryHomePanel extends StatelessWidget {
  /// my_delivery_home() verbatim.
  final Map<String, dynamic> home;

  /// Refetch after the shift flips — the tiles and the button label both move.
  final Future<void> Function() onChanged;

  const DeliveryHomePanel({
    super.key,
    required this.home,
    required this.onChanged,
  });

  List<Map<String, dynamic>> get _tiles {
    final v = home['tiles'];
    return v is List
        ? v.map((e) => Map<String, dynamic>.from(e as Map)).toList()
        : const [];
  }

  @override
  Widget build(BuildContext context) {
    final active = home['allowed'] != false && home['is_partner'] != false;

    // Attestation fires for BOTH states, and before the early return below.
    // A rider who has registered but not yet been approved is exactly the case
    // this panel most needs to be provable in — if the key only fired once
    // somebody was already approved, it could not prove the not-approved path
    // shipped at all.
    RenderLog.write('c630_delivery_depth',
        'active=$active;on_shift=${home['on_shift'] == true};'
        'tiles=${_tiles.length};agency=${home['is_agency'] == true}');

    // Not an active partner yet — the backend's own two sentences, nothing else.
    if (!active) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(home['empty_title']?.toString() ?? '',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: _kText)),
          if ((home['empty_note']?.toString() ?? '').isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(home['empty_note']!.toString(),
                style: TextStyle(fontSize: 12.5, color: _kSub)),
          ],
        ]),
      );
    }

    final earning = home['earning_today_display']?.toString() ?? '';
    final perDrop = home['per_drop_display']?.toString() ?? '';
    final zone = home['zone_label']?.toString() ?? '';
    final onShift = home['on_shift'] == true;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (earning.isNotEmpty) ...[
                Text(_ui('dlv_earning_today'),
                    style: TextStyle(fontSize: 11.5, color: _kSub)),
                Text(earning,
                    style: TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800, color: _kText)),
              ],
              // Already a finished sentence ("₹25.00 per delivery").
              if (perDrop.isNotEmpty)
                Text(perDrop, style: TextStyle(fontSize: 11.5, color: _kSub)),
              if (zone.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(zone, style: TextStyle(fontSize: 11.5, color: _kSub)),
              ],
            ]),
          ),
          _ShiftButton(
            label: home['shift_button_label']?.toString() ?? '',
            action: home['shift_action']?.toString() ?? '',
            onShift: onShift,
            onChanged: onChanged,
          ),
        ]),

        if (_tiles.isNotEmpty) ...[
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final t in _tiles) _tile(t),
            ]),
          ),
        ],

        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: _kSub,
              padding: EdgeInsets.zero,
            ),
            onPressed: () => showDeliveryHistorySheet(context),
            icon: const Icon(Icons.history, size: 16),
            label: Text(_ui('dlv_history'), style: const TextStyle(fontSize: 12.5)),
          ),
        ),
      ]),
    );
  }

  /// B2 — `display` wins when the backend supplied one, because that is the
  /// finished string (e.g. "3.4 km"); `value` is the raw number for the tiles
  /// that need no unit. Neither is formatted here.
  Widget _tile(Map<String, dynamic> t) {
    final colors = t['colors'] is Map
        ? Map<String, dynamic>.from(t['colors'] as Map)
        : const <String, dynamic>{};
    final display = t['display']?.toString() ?? '';
    final value = t['value']?.toString() ?? '';
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: _hex(colors['bg']?.toString()) ?? Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(display.isNotEmpty ? display : value,
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: _hex(colors['fg']?.toString()) ?? _kText)),
        Text(t['label']?.toString() ?? '',
            style: TextStyle(
                fontSize: 11,
                color: _hex(colors['fg']?.toString()) ?? _kSub)),
      ]),
    );
  }
}

class _ShiftButton extends StatefulWidget {
  final String label;
  final String action;
  final bool onShift;
  final Future<void> Function() onChanged;

  const _ShiftButton({
    required this.label,
    required this.action,
    required this.onShift,
    required this.onChanged,
  });

  @override
  State<_ShiftButton> createState() => _ShiftButtonState();
}

class _ShiftButtonState extends State<_ShiftButton> {
  bool _busy = false;

  Future<void> _tap() async {
    if (_busy || widget.action.isEmpty) return;
    setState(() => _busy = true);
    try {
      // B3 — geo-stamped, like every other delivery write.
      final fix = await DeviceLocation.current();
      final res = await Supabase.instance.client.rpc('delivery_shift', params: {
        'p_action': widget.action,
        'p_lat': fix?.lat,
        'p_lng': fix?.lng,
      });
      if (!mounted) return;
      RenderLog.write('c630_delivery_shift', widget.action);
      await widget.onChanged();
      if (res is Map && mounted) {
        final msg = res['message']?.toString() ?? '';
        if (msg.isNotEmpty) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
        }
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.label.isEmpty) return const SizedBox.shrink();
    // On shift -> outlined (the calm state); off shift -> solid call to action.
    // Which one is which is driven by the backend's own on_shift flag, and the
    // WORD on the button is its shift_button_label either way.
    return widget.onShift
        ? OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: _kText,
              side: BorderSide(color: _kBorder),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: _busy ? null : _tap,
            child: _busyOr(widget.label, _kText),
          )
        : ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kGreen,
              foregroundColor: Colors.white,
              visualDensity: VisualDensity.compact,
            ),
            onPressed: _busy ? null : _tap,
            child: _busyOr(widget.label, Colors.white),
          );
  }

  Widget _busyOr(String label, Color c) => _busy
      ? SizedBox(
          width: 15, height: 15,
          child: CircularProgressIndicator(strokeWidth: 2, color: c))
      : Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700));
}

// ── PART C: history ───────────────────────────────────────────────────────────

Future<void> showDeliveryHistorySheet(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => const _HistorySheet(),
  );
}

class _HistorySheet extends StatefulWidget {
  const _HistorySheet();

  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends State<_HistorySheet> {
  bool _loading = true;
  String _title = '';
  List<Map<String, dynamic>> _days = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client
          .rpc('my_delivery_history', params: {'p_days': 14});
      if (!mounted) return;
      if (res is Map) {
        final m = Map<String, dynamic>.from(res);
        setState(() {
          _title = m['title']?.toString() ?? '';
          _days = m['days'] is List
              ? (m['days'] as List)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList()
              : const [];
          _loading = false;
        });
        RenderLog.write('c630_delivery_history', _days.length.toString());
        return;
      }
      setState(() => _loading = false);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      builder: (context, ctrl) => ListView(
        controller: ctrl,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: _kBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // "Last 14 days" — composed by the RPC, not concatenated here.
          Text(_title.isNotEmpty ? _title : _ui('dlv_history'),
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _kText)),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_days.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text(_ui('dlv_no_history'),
                    style: TextStyle(fontSize: 13, color: _kSub)),
              ),
            )
          else
            for (final d in _days) _dayRow(d),
        ],
      ),
    );
  }

  Widget _dayRow(Map<String, dynamic> d) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // date_label is backend-formatted ("31 Jul") — no Dart date work.
            Text(d['date_label']?.toString() ?? '',
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w700, color: _kText)),
            const SizedBox(height: 2),
            Row(children: [
              _stat(_ui('dlv_tile_delivered'), d['delivered'],
                  const Color(0xFF0F6E56)),
              const SizedBox(width: 10),
              _stat(_ui('dlv_tile_failed'), d['failed'], const Color(0xFFB42318)),
            ]),
          ]),
        ),
        Text(d['earning_display']?.toString() ?? '',
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w800, color: _kText)),
      ]),
    );
  }

  Widget _stat(String label, dynamic value, Color c) => Text(
        '$label ${(value as num?)?.toInt() ?? 0}',
        style: TextStyle(fontSize: 11.5, color: c),
      );
}

// lib/screens/delivery/reschedule_sheet.dart — CHANGE #406 (PART 1)
//
// The customer's half of a failed delivery. delivery_respond() is the RIDER's
// accept/reject; until this change the customer had nothing at all — a failed
// attempt simply reappeared on a date the backend picked.
//
// ONE WIDGET, TWO DOORS. The signed-in Orders screen and the public /track
// link render THIS widget; only the pair of RPC names differs. That is
// deliberate: the backend builds both payloads from the same
// _reschedule_block(), so a day or a window offered on one surface is offered
// on the other, and there is no second place for the rules to drift into.
//
// Nothing here decides anything. Whether the customer may reschedule at all,
// which days exist, which windows exist, how many attempts are left, what the
// refusal says when the cap is reached — every one of those is a field in the
// payload. The widget's whole job is: draw days, draw windows, post the two
// keys back, print the sentence that comes home.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// Which pair of RPCs this sheet talks to. The signed-in customer is
/// identified by their session; the /track link is identified by the delivery's
/// own qr_token, exactly as delivery_track_public does.
enum RescheduleDoor { order, token }

class RescheduleCard extends StatefulWidget {
  /// The order id (RescheduleDoor.order) or the tracking token
  /// (RescheduleDoor.token).
  final String key_;
  final RescheduleDoor door;

  /// Called after a successful write, so the host can refetch its own payload
  /// rather than this card trying to patch someone else's state.
  final Future<void> Function()? onChanged;

  const RescheduleCard({
    super.key,
    required this.key_,
    required this.door,
    this.onChanged,
  });

  @override
  State<RescheduleCard> createState() => _RescheduleCardState();
}

class _RescheduleCardState extends State<RescheduleCard> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;
  bool _busy = false;
  bool _open = false;
  String _day = '';
  String _window = '';
  String _done = '';
  String _error = '';

  String get _readRpc => widget.door == RescheduleDoor.order
      ? 'delivery_reschedule_options'
      : 'delivery_reschedule_public';
  String get _writeRpc => widget.door == RescheduleDoor.order
      ? 'delivery_reschedule_submit'
      : 'delivery_reschedule_submit_public';
  String get _keyParam =>
      widget.door == RescheduleDoor.order ? 'p_order_id' : 'p_token';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client
          .rpc(_readRpc, params: {_keyParam: widget.key_});
      if (!mounted) return;
      setState(() {
        _p = res is Map ? Map<String, dynamic>.from(res) : const {};
        _loading = false;
      });
      if (_p['can_reschedule'] == true) {
        RenderLog.write('c406_resched_offer', 1);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    if (_busy || _day.isEmpty) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final res = await Supabase.instance.client.rpc(_writeRpc, params: {
        _keyParam: widget.key_,
        'p_day': _day,
        // An empty choice is not a client default: the backend's own
        // 'anytime' row is the fallback, and it names itself.
        'p_window': _window.isEmpty ? null : _window,
      });
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : const {};
      if (m['ok'] == true) {
        setState(() {
          _done = m['message']?.toString() ?? '';
          _p = m['state'] is Map
              ? Map<String, dynamic>.from(m['state'] as Map)
              : _p;
          _open = false;
          _busy = false;
        });
        RenderLog.write('c406_resched_submit', 1);
        await widget.onChanged?.call();
      } else {
        // The refusal is the backend's sentence, whichever refusal it is.
        setState(() {
          _error = m['message']?.toString() ?? '';
          _busy = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Map<String, dynamic>> _list(String field) =>
      (_p[field] as List?)
          ?.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList() ??
      const [];

  Widget _chips(
    List<Map<String, dynamic>> items,
    String selected,
    void Function(String) onPick,
  ) =>
      Wrap(
        spacing: Ds.space.x8,
        runSpacing: Ds.space.x8,
        children: [
          for (final it in items)
            _Chip(
              label: it['label']?.toString() ?? '',
              selected: (it['key']?.toString() ?? '') == selected,
              onTap: () => onPick(it['key']?.toString() ?? ''),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    if (_p['ok'] != true) return const SizedBox.shrink();

    final can = _p['can_reschedule'] == true;
    final current = _p['current'] is Map
        ? Map<String, dynamic>.from(_p['current'] as Map)
        : const <String, dynamic>{};

    // Nothing to say: the delivery is live and has not failed, so there is no
    // reschedule to offer and no refusal worth printing either.
    if (!can && (_p['reason']?.toString() ?? '') == 'not_failed') {
      return const SizedBox.shrink();
    }

    return Container(
      margin: EdgeInsets.only(top: Ds.space.x24),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        border: Border.all(color: Ds.c.divider),
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_p['title']?.toString() ?? '', style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x4),
        Text(
          _done.isNotEmpty ? _done : (_p['message']?.toString() ?? ''),
          style: Ds.t.caption,
        ),

        // What is on the books right now, in the backend's words — including
        // the "auto-scheduled" line when nobody has chosen yet.
        if (current.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Row(children: [
            Icon(Icons.event_rounded, size: 18, color: Ds.c.textSecondary),
            SizedBox(width: Ds.space.x8),
            Expanded(
              child: Text(
                '${current['date_label'] ?? ''} · ${current['window_label'] ?? ''}',
                style: Ds.t.bodyStrong,
              ),
            ),
          ]),
        ],

        if (can && !_open) ...[
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Ds.c.brand,
                side: BorderSide(color: Ds.c.brand),
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              onPressed: () => setState(() => _open = true),
              child: Text(_p['cta']?.toString() ?? ''),
            ),
          ),
          SizedBox(height: Ds.space.x8),
          Text(_p['used_label']?.toString() ?? '', style: Ds.t.caption),
        ],

        if (can && _open) ...[
          SizedBox(height: Ds.space.x16),
          Text(_p['day_label']?.toString() ?? '', style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          _chips(_list('days'), _day, (k) => setState(() => _day = k)),
          SizedBox(height: Ds.space.x16),
          Text(_p['window_label']?.toString() ?? '', style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          _chips(_list('windows'), _window, (k) => setState(() => _window = k)),
          if (_error.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(_error,
                style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ],
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Ds.c.brand,
                foregroundColor: Ds.c.surface,
                disabledBackgroundColor: Ds.c.divider,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              // A day is the one thing the customer must choose; the window
              // has a backend default and says so.
              onPressed: (_day.isNotEmpty && !_busy) ? _submit : null,
              child: Text(_p['submit_label']?.toString() ?? ''),
            ),
          ),
        ],

        // Capped, disabled or already escalated: the refusal is already
        // printed above as `message`; this is the extra line that tells the
        // customer a person is now involved.
        if (_p['escalated'] == true) ...[
          SizedBox(height: Ds.space.x12),
          Container(
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
              color: Ds.c.infoSoft,
              borderRadius: Ds.r.rChip,
            ),
            child: Text(_p['escalated_message']?.toString() ?? '',
                style: Ds.t.caption.copyWith(color: Ds.c.info)),
          ),
        ],
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: Ds.r.rChip,
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x16, vertical: Ds.space.x8),
          decoration: BoxDecoration(
            color: selected ? Ds.c.brandSoft : Ds.c.bg,
            border: Border.all(color: selected ? Ds.c.brand : Ds.c.divider),
            borderRadius: Ds.r.rChip,
          ),
          child: Text(
            label,
            style: selected
                ? Ds.t.bodyStrong.copyWith(color: Ds.c.brand)
                : Ds.t.body,
          ),
        ),
      );
}

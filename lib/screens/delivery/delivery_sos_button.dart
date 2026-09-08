// lib/screens/delivery/delivery_sos_button.dart — CHANGE #406 (PART 2)
//
// One button on the rider's active run. No telephony, no new dependency: it
// sends the rider's current fix, and then keeps sending fixes faster than the
// ordinary run ping until a human closes the alert.
//
// THE INTERVAL IS THE BACKEND'S. delivery_sos_raise() and delivery_sos_ping()
// each return `interval_s` and `streaming`; this widget re-arms its timer from
// whatever came back and stops the moment the payload says stop. It never
// decides how long an emergency lasts, and it never decides that an emergency
// is over — that is what "the team closed it" means, and only the team can say
// it. The auto_close_min guard lives in sos_config for the same reason: a phone
// pinging every ten seconds forever is a flat battery, which is the opposite of
// safe, so the BACKEND decides when to let go.
//
// Every word — the button, the confirm sheet, the live banner — is ui_copy.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/device_location.dart';
import '../../utils/render_log.dart';

class DeliverySosButton extends StatefulWidget {
  /// The stop the rider is on, when there is one. Null is fine — an SOS is
  /// about the rider, not the parcel, and delivery_sos_raise() treats it as
  /// context rather than a key.
  final String? deliveryId;

  const DeliverySosButton({super.key, this.deliveryId});

  @override
  State<DeliverySosButton> createState() => _DeliverySosButtonState();
}

class _DeliverySosButtonState extends State<DeliverySosButton> {
  Map<String, dynamic> _s = const {};
  bool _loading = true;
  bool _busy = false;
  int? _sosId;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client.rpc('delivery_sos_state');
      if (!mounted) return;
      final m = res is Map
          ? Map<String, dynamic>.from(res)
          : const <String, dynamic>{};
      setState(() {
        _s = m;
        _loading = false;
        _sosId = m['sos_id'] is int
            ? m['sos_id'] as int
            : int.tryParse(m['sos_id']?.toString() ?? '');
      });
      if (m['can_sos'] == true) RenderLog.write('c406_sos_button', 1);
      // A rider who reopens the app mid-emergency is still in it.
      if (m['has_open'] == true) _arm(m['interval_s']);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _arm(Object? intervalS) {
    final s = intervalS is int ? intervalS : int.tryParse(intervalS?.toString() ?? '');
    _timer?.cancel();
    if (s == null || s <= 0 || _sosId == null) return;
    _timer = Timer.periodic(Duration(seconds: s), (_) => _ping());
  }

  Future<void> _ping() async {
    final id = _sosId;
    if (id == null) return;
    // A fresh fix per tick: the point of the faster stream is that the position
    // MOVES, so a cached reading would be a slower stream wearing a costume.
    final f = await DeviceLocation.current();
    try {
      final res = await Supabase.instance.client.rpc('delivery_sos_ping', params: {
        'p_sos_id': id,
        'p_lat': f?.lat,
        'p_lng': f?.lng,
        'p_accuracy': f?.accuracy,
      });
      if (!mounted) return;
      final m = res is Map
          ? Map<String, dynamic>.from(res)
          : const <String, dynamic>{};
      if (m['streaming'] != true) {
        // Closed, or aged out. Either way the backend said stop.
        _timer?.cancel();
        setState(() {
          _sosId = null;
          _s = {..._s, 'has_open': false, 'active_label': null};
        });
        await _load();
        return;
      }
      setState(() => _s = {..._s, 'active_label': m['message'] ?? _s['active_label']});
    } catch (_) {
      // A dropped ping is not the end of the alert — the next tick tries again.
    }
  }

  Future<void> _raise() async {
    if (_busy) return;
    setState(() => _busy = true);
    final f = await DeviceLocation.current();
    try {
      final res = await Supabase.instance.client.rpc('delivery_sos_raise', params: {
        'p_lat': f?.lat,
        'p_lng': f?.lng,
        'p_accuracy': f?.accuracy,
        'p_delivery_id': widget.deliveryId,
      });
      if (!mounted) return;
      final m = res is Map
          ? Map<String, dynamic>.from(res)
          : const <String, dynamic>{};
      setState(() => _busy = false);
      if (m['ok'] == true) {
        RenderLog.write('c406_sos_raised', 1);
        setState(() {
          _sosId = m['sos_id'] is int
              ? m['sos_id'] as int
              : int.tryParse(m['sos_id']?.toString() ?? '');
          _s = {..._s, 'has_open': true, 'active_label': m['active_label'] ?? m['message']};
        });
        _arm(m['interval_s']);
      }
      _toast(m['message']?.toString() ?? '');
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg, style: Ds.t.body.copyWith(color: Ds.c.surface))));
  }

  Future<void> _confirm() async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_s['confirm_title']?.toString() ?? '',
              style: Ds.t.title, textAlign: TextAlign.center),
          SizedBox(height: Ds.space.x12),
          Text(_s['confirm_body']?.toString() ?? '',
              style: Ds.t.caption, textAlign: TextAlign.center),
          SizedBox(height: Ds.space.x24),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                // The one red action on this screen, and it is destructive in
                // the only sense that matters here: it wakes people up.
                backgroundColor: Ds.c.danger,
                foregroundColor: Ds.c.surface,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(_s['confirm_yes']?.toString() ?? ''),
            ),
          ),
          SizedBox(height: Ds.space.x8),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(_s['confirm_no']?.toString() ?? '',
                  style: Ds.t.body.copyWith(color: Ds.c.textSecondary)),
            ),
          ),
        ]),
      ),
    );
    if (ok == true) await _raise();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _s['can_sos'] != true) return const SizedBox.shrink();

    // Already in it: the banner replaces the button, so a rider cannot open a
    // second alert by pressing again in a panic.
    if (_s['has_open'] == true) {
      return Container(
        margin: EdgeInsets.only(top: Ds.space.x16),
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.dangerSoft,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.danger),
        ),
        child: Row(children: [
          Icon(Icons.sos_rounded, color: Ds.c.danger),
          SizedBox(width: Ds.space.x12),
          Expanded(
            child: Text(_s['active_label']?.toString() ?? '',
                style: Ds.t.bodyStrong.copyWith(color: Ds.c.danger)),
          ),
        ]),
      );
    }

    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x16),
      child: SizedBox(
        width: double.infinity,
        height: Ds.touch.minTarget,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: Ds.c.danger,
            side: BorderSide(color: Ds.c.danger),
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          ),
          onPressed: _busy ? null : _confirm,
          icon: Icon(Icons.sos_rounded, size: 20, color: Ds.c.danger),
          label: Text(
            '${_s['button_label'] ?? ''} · ${_s['hint'] ?? ''}',
            style: Ds.t.bodyStrong.copyWith(color: Ds.c.danger),
          ),
        ),
      ),
    );
  }
}

// CMD #2050 — THE DEVICES SECTION on the Payment alerts screen.
//
// #1931 built payment_alert_device and the per-phone card on the Money home,
// but nothing ever created a row: live had ZERO devices, so the whole payment
// alerts feature had no phone feeding it. This section is the missing surface.
//
// It decides nothing. payment_alert_device_list() hands down the section title,
// the count line, the pairing card, every device row's labels — and which of a
// row's controls may be touched. The section is FULLY live on the web: a paired
// phone's speak switch and its volume are server-side settings the phone obeys,
// so an admin on a laptop changes them exactly like an admin on a phone. The
// one exception is LISTENING itself, which is an Android permission and can
// therefore only be switched from the phone in your hand — and that exception
// arrives as listener_editable / listener_note, not as a kIsWeb branch here.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/payment_alerts_service.dart';
import '../../services/payment_listener_service.dart';
import '../../utils/render_log.dart';
import 'payment_alerts_screen.dart' show payAlertTone, payAlertToneSoft;

String _s(Object? v) => v == null ? '' : v.toString().trim();

List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

class PaymentDevicesSection extends StatefulWidget {
  const PaymentDevicesSection({
    super.key,
    this.rpc,
    this.service,
    this.platform,
    this.deviceId,
  });

  /// Injected in tests so the section is proven against a payload.
  final PayAlertRpc? rpc;

  /// Android's own side: the device id and the notification-access screen.
  final PaymentListenerService? service;

  /// What the backend is told this phone is. Null = ask the service.
  final String? platform;

  /// Null = ask the service (tests pass it straight in).
  final String? deviceId;

  @override
  State<PaymentDevicesSection> createState() => _PaymentDevicesSectionState();
}

class _PaymentDevicesSectionState extends State<PaymentDevicesSection> {
  Map<String, dynamic> _payload = const {};
  bool _loading = true;
  String _error = '';
  /// The call itself failed (no backend on this build, no network). The section
  /// draws NOTHING then — a refusal the backend actually worded is a different
  /// thing, and that one is shown.
  bool _unreachable = false;
  String _busy = '';
  String _device = '';

  PaymentListenerService? get _svc =>
      widget.service ?? (PaymentListenerService.supported
          ? PaymentListenerService.instance
          : null);

  String get _platform => widget.platform ?? PaymentListenerService.platform;

  Future<Map<String, dynamic>> _call(
    String fn,
    Map<String, dynamic> args,
  ) async {
    return (widget.rpc ?? payAlertLiveRpc)(fn, args);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    if (widget.deviceId != null) {
      _device = widget.deviceId!;
    } else {
      final svc = _svc;
      if (svc != null) {
        try {
          _device = (await svc.readState()).deviceId;
        } catch (_) {
          _device = '';
        }
      }
    }
    Map<String, dynamic> res;
    try {
      res = await _call('payment_alert_device_list', <String, dynamic>{
        if (_device.isNotEmpty) 'p_device': _device,
        'p_platform': _platform,
      }).timeout(const Duration(seconds: 12));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _unreachable = true;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _unreachable = false;
      if (res['ok'] == true) {
        _payload = res;
        _error = '';
      } else {
        _error = _s(res['message']).isNotEmpty
            ? _s(res['message'])
            : _s(res['error']);
      }
    });
    RenderLog.write('c2050_device_rows', _rows(_payload['rows']).length);
  }

  Future<void> _set(String device, Map<String, dynamic> patch) async {
    setState(() => _busy = device);
    Map<String, dynamic> res;
    try {
      res = await _call('payment_alert_device_set', <String, dynamic>{
        'p_device': device,
        ...patch,
      });
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'message': e.toString()};
    }
    if (!mounted) return;
    setState(() => _busy = '');
    final msg = _s(res['toast']).isNotEmpty ? _s(res['toast']) : _s(res['message']);
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
    await _load();
  }

  Future<void> _openSettings() async {
    final svc = _svc;
    if (svc == null) return;
    await svc.openSettings();
    if (!mounted) return;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    // Until the backend has answered, this section occupies NOTHING. It is one
    // block inside a screen that draws its own loading state, and a placeholder
    // here would move the queue underneath it on every build where the device
    // list is slow, refused or — on a platform with no listener at all — never
    // coming. The queue's own skeleton is the loading state of this page.
    if (_unreachable) return const SizedBox.shrink();
    if (_loading && _payload.isEmpty) return const SizedBox.shrink();
    if (_error.isNotEmpty) {
      return Text(_error, style: Ds.t.caption);
    }
    final rows = _rows(_payload['rows']);
    final pairing = _payload['pairing'] is Map
        ? Map<String, dynamic>.from(_payload['pairing'] as Map)
        : const <String, dynamic>{};
    final canEdit = _payload['can_edit'] == true;

    // The section owns its own trailing gap. A section that draws NOTHING must
    // also cost nothing: a spacer in the parent would shift the queue below it
    // on a build where the device list never answered.
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x24),
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_s(_payload['title']), style: Ds.t.subtitle),
        if (_s(_payload['count_label']).isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x4),
            child: Text(_s(_payload['count_label']), style: Ds.t.caption),
          ),
        SizedBox(height: Ds.space.x12),
        if (pairing.isNotEmpty)
          _PairingCard(
            pairing: pairing,
            onOpenSettings: _openSettings,
          ),
        if (_s(_payload['note']).isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x8),
            child: Text(_s(_payload['note']), style: Ds.t.caption),
          ),
        if (rows.isEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x12),
            child: _DeviceEmpty(
              label: _s(_payload['empty_label']),
              hint: _s(_payload['empty_hint']),
            ),
          )
        else
          for (final r in rows)
            Padding(
              padding: EdgeInsets.only(top: Ds.space.x12),
              child: _DeviceCard(
                row: r,
                canEdit: canEdit,
                busy: _busy == _s(r['device_id']),
                onListener: (v) => _set(_s(r['device_id']), {
                  'p_listener_enabled': v,
                }),
                onSpeak: (v) => _set(_s(r['device_id']), {
                  'p_speak_enabled': v,
                }),
                onVolume: (v) => _set(_s(r['device_id']), {
                  'p_volume': v,
                }),
              ),
            ),
      ],
      ),
    );
  }
}

// ── the pairing card ─────────────────────────────────────────────────────────
class _PairingCard extends StatelessWidget {
  const _PairingCard({required this.pairing, required this.onOpenSettings});

  final Map<String, dynamic> pairing;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final tone = _s(pairing['status_tone']);
    final cta = _s(pairing['cta_label']);
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(_s(pairing['title']), style: Ds.t.bodyStrong),
              _ToneChip(label: _s(pairing['status_label']), tone: tone),
            ],
          ),
          if (_s(pairing['status_sub']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_s(pairing['status_sub']), style: Ds.t.caption),
          ],
          if (cta.isNotEmpty && pairing['can_open_settings'] == true) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: onOpenSettings,
                child: Text(cta),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── one paired phone ─────────────────────────────────────────────────────────
class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.row,
    required this.canEdit,
    required this.busy,
    required this.onListener,
    required this.onSpeak,
    required this.onVolume,
  });

  final Map<String, dynamic> row;
  final bool canEdit;
  final bool busy;
  final ValueChanged<bool> onListener;
  final ValueChanged<bool> onSpeak;
  final ValueChanged<int> onVolume;

  @override
  Widget build(BuildContext context) {
    final volume = (row['volume'] as num?)?.toInt() ?? 100;
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(_s(row['label']), style: Ds.t.bodyStrong),
              if (row['is_this_device'] == true)
                _ToneChip(label: _s(row['this_label']), tone: 'info'),
              _ToneChip(
                label: _s(row['status_label']),
                tone: _s(row['status_tone']),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Text(_s(row['last_seen']), style: Ds.t.caption),
          Text(_s(row['last_alert']), style: Ds.t.caption),
          Text(_s(row['today_label']), style: Ds.t.caption),
          if (_s(row['version_label']).isNotEmpty)
            Text(_s(row['version_label']), style: Ds.t.caption),
          if (canEdit) ...[
            SizedBox(height: Ds.space.x8),
            // Listening is the device-local one: off this phone the switch is
            // there but inert, and the backend says why on the row itself.
            _SwitchRow(
              label: _s(row['listener_label']),
              state: _s(row['listener_note']),
              value: row['listener_on'] == true,
              onChanged: row['listener_editable'] == true && !busy
                  ? onListener
                  : null,
            ),
            if (row['speak_editable'] != false)
              _SwitchRow(
                label: _s(row['speak_label']),
                state: _s(row['speak_state']),
                value: row['speak_on'] == true,
                onChanged: busy ? null : onSpeak,
              ),
            if (row['volume_editable'] != false) ...[
              SizedBox(height: Ds.space.x8),
              Text(_s(row['volume_label']), style: Ds.t.caption),
              _VolumeSlider(
                value: volume,
                enabled: !busy,
                onSet: onVolume,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

// The volume the backend stored, moved by a finger and written back once the
// finger lifts — the row it belongs to is re-read from the server after that,
// so this local value only ever lives between two payloads.
class _VolumeSlider extends StatefulWidget {
  const _VolumeSlider({
    required this.value,
    required this.enabled,
    required this.onSet,
  });

  final int value;
  final bool enabled;
  final ValueChanged<int> onSet;

  @override
  State<_VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<_VolumeSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final v = (_dragging ?? widget.value.toDouble()).clamp(0, 100).toDouble();
    return SizedBox(
      height: 44,
      child: Slider(
        value: v,
        min: 0,
        max: 100,
        divisions: 10,
        onChanged: widget.enabled ? (n) => setState(() => _dragging = n) : null,
        onChangeEnd: widget.enabled
            ? (n) {
                setState(() => _dragging = null);
                widget.onSet(n.round());
              }
            : null,
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.state = '',
  });

  final String label;
  final String state;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(label, style: Ds.t.body),
                if (state.isNotEmpty) Text(state, style: Ds.t.caption),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _ToneChip extends StatelessWidget {
  const _ToneChip({required this.label, required this.tone});

  final String label;
  final String tone;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Ds.space.x12,
        vertical: Ds.space.x4,
      ),
      decoration: BoxDecoration(
        color: payAlertToneSoft(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(
        label,
        style: Ds.t.caption.copyWith(color: payAlertTone(tone)),
      ),
    );
  }
}

class _DeviceEmpty extends StatelessWidget {
  const _DeviceEmpty({required this.label, required this.hint});

  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x24),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Column(
        children: [
          Text(label, style: Ds.t.body, textAlign: TextAlign.center),
          if (hint.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(hint, style: Ds.t.caption, textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }
}

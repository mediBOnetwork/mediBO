// CMD #1931 — the Money tab's "Hear every payment" card.
//
// Every word on it — title, body, the three bullets, the status chip, the
// button, the switch label, the volume label, the last-payment line, the
// prominent-disclosure sheet — arrives from payment_listener_card(). This file
// decides nothing and words nothing; it lays the payload out and sends taps
// back. `show:false` draws an empty box, which is how the card stays off web
// and off iOS without a platform branch written here.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/payment_listener_service.dart';
import '../legal_pages.dart';

typedef ListenerCardLoader = Future<Map<String, dynamic>> Function();

class PaymentListenerCard extends StatefulWidget {
  const PaymentListenerCard({super.key, this.loader, this.service});

  /// Test seam: the payload, without a phone or a network.
  final ListenerCardLoader? loader;

  /// Test seam: the native bridge.
  final PaymentListenerService? service;

  @override
  State<PaymentListenerCard> createState() => _PaymentListenerCardState();
}

class _PaymentListenerCardState extends State<PaymentListenerCard> {
  Map<String, dynamic> _card = const {};
  bool _loading = true;

  PaymentListenerService get _svc =>
      widget.service ?? PaymentListenerService.instance;

  @override
  void initState() {
    super.initState();
    _load();
    _svc.revision.addListener(_onRevision);
  }

  @override
  void dispose() {
    _svc.revision.removeListener(_onRevision);
    super.dispose();
  }

  void _onRevision() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    Map<String, dynamic> res;
    try {
      if (widget.loader != null) {
        res = await widget.loader!();
      } else {
        await _svc.start();
        res = await _svc.reportState();
        if (res['show'] != true) res = await _svc.card();
      }
    } catch (_) {
      res = const <String, dynamic>{'show': false};
    }
    if (!mounted) return;
    setState(() {
      _card = res;
      _loading = false;
    });
  }

  String _s(Object? v) => v == null ? '' : v.toString();

  /// The PROMINENT DISCLOSURE. Android's own grant screen says nothing about
  /// why mediBO wants this, so the backend's explanation is shown — and has to
  /// be accepted — before the system screen is ever opened.
  Future<void> _enable() async {
    final d = _card['disclosure'];
    final disc = d is Map ? Map<String, dynamic>.from(d) : const {};
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Ds.c.surface,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            Ds.space.x16,
            Ds.space.x8,
            Ds.space.x16,
            Ds.space.x24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_s(disc['title']), style: Ds.t.title),
              SizedBox(height: Ds.space.x12),
              Text(
                _s(disc['body']),
                style: Ds.t.body.copyWith(color: Ds.c.textSecondary),
              ),
              SizedBox(height: Ds.space.x24),
              SizedBox(
                height: Ds.space.x48,
                child: FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(_s(disc['ok'])),
                ),
              ),
              SizedBox(height: Ds.space.x8),
              SizedBox(
                height: Ds.space.x48,
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(_s(disc['cancel'])),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    await _svc.openSettings();
    // Coming back from Settings is the only moment the grant can have changed.
    await _load();
  }

  Future<void> _toggleSpeak(bool on) async {
    setState(() => _card = {..._card, 'speak_on': on});
    final res = await _svc.setSpeak(speak: on);
    if (!mounted || res.isEmpty) return;
    setState(() => _card = res);
    final toast = _s(res['toast']);
    if (toast.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(toast)));
    }
  }

  Future<void> _setVolume(int v) async {
    final res = await _svc.setSpeak(speak: _card['speak_on'] != false, volume: v);
    if (!mounted || res.isEmpty) return;
    setState(() => _card = res);
  }

  Color _toneColor(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      default:
        return Ds.c.textSecondary;
    }
  }

  Color _toneSoft(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.successSoft;
      case 'warning':
        return Ds.c.warningSoft;
      case 'danger':
        return Ds.c.dangerSoft;
      default:
        return Ds.c.bg;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _card['show'] != true) return const SizedBox.shrink();

    final tone = _s(_card['status_tone']);
    final bullets = (_card['bullets'] as List?) ?? const [];
    final queued = _s(_card['queued_label']);
    final volume = (_card['volume'] as num?)?.toInt() ?? 100;
    final speakOn = _card['speak_on'] != false;

    return Container(
      key: const Key('c1931_listener_card'),
      margin: EdgeInsets.only(bottom: Ds.space.x16),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title and the Enabled/Disabled chip. On a 360px phone the chip
          // wraps under the title rather than squeezing it.
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(_s(_card['title']), style: Ds.t.subtitle),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8,
                  vertical: Ds.space.x4,
                ),
                decoration: BoxDecoration(
                  color: _toneSoft(tone),
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(
                  _s(_card['status_label']),
                  style: Ds.t.caption.copyWith(color: _toneColor(tone)),
                ),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Text(
            _s(_card['status_sub']),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
          ),
          SizedBox(height: Ds.space.x12),
          Text(
            _s(_card['body']),
            style: Ds.t.body.copyWith(color: Ds.c.textSecondary),
          ),
          SizedBox(height: Ds.space.x12),
          for (final b in bullets)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check, size: Ds.space.x16, color: Ds.c.success),
                  SizedBox(width: Ds.space.x8),
                  Expanded(
                    child: Text(
                      _s(b),
                      style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          SizedBox(height: Ds.space.x8),
          // The one primary action on this card, full width and 48 high.
          SizedBox(
            width: double.infinity,
            height: Ds.space.x48,
            child: FilledButton(
              key: const Key('c1931_listener_cta'),
              onPressed: _enable,
              child: Text(_s(_card['cta_label'])),
            ),
          ),
          SizedBox(height: Ds.space.x12),
          // The mute switch. Its state lives in the backend, one row per phone.
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(_card['speak_label']), style: Ds.t.body),
                    Text(
                      _s(_card['speak_state']),
                      style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                    ),
                  ],
                ),
              ),
              Switch(
                key: const Key('c1931_listener_speak'),
                value: speakOn,
                onChanged: _toggleSpeak,
              ),
            ],
          ),
          if (speakOn) ...[
            Text(
              _s(_card['volume_label']),
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
            ),
            Slider(
              value: volume.toDouble().clamp(0, 100),
              min: 0,
              max: 100,
              divisions: 10,
              label: '$volume',
              onChanged: (v) => setState(
                () => _card = {..._card, 'volume': v.round()},
              ),
              onChangeEnd: (v) => _setVolume(v.round()),
            ),
          ],
          SizedBox(height: Ds.space.x8),
          Text(
            _s(_card['last_alert']),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
          ),
          if (queued.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: Ds.space.x4),
              child: Text(
                queued,
                style: Ds.t.caption.copyWith(color: Ds.c.warning),
              ),
            ),
          SizedBox(height: Ds.space.x8),
          SizedBox(
            height: Ds.space.x48,
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LegalPageScreen(
                      slug: _s(_card['privacy_slug']).isEmpty
                          ? 'privacy'
                          : _s(_card['privacy_slug']),
                    ),
                  ),
                ),
                child: Text(_s(_card['privacy_label'])),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

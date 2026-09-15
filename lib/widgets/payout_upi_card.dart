import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

/// CMD #1889 — "Where should we send your money?", asked at the FIRST payout.
///
/// Signup never sees this: `pharmacy_payout_upi()` answers `needed:false` until
/// a refund or settlement is actually waiting, and the Billing tab only places
/// the card when the backend says so. Saving a UPI ID does not make it payable
/// — the backend sends ₹1 down the existing verify path and the payout stays
/// blocked until the customer confirms that ₹1 landed.
///
/// Every word on this card is a payload string: title, hint, the amount waiting,
/// the state sentence, both button captions and every toast. Dart computes
/// nothing, formats no money and decides no state.
class PayoutUpiCard extends StatefulWidget {
  const PayoutUpiCard({super.key});

  /// Test seam. Null in production -> the real RPCs.
  static Future<Object?> Function(String rpc, Map<String, dynamic> params)?
      rpcOverride;

  static Future<Object?> rpc(String name, [Map<String, dynamic>? params]) {
    final over = rpcOverride;
    if (over != null) return over(name, params ?? const {});
    return Supabase.instance.client.rpc(name, params: params);
  }

  @override
  State<PayoutUpiCard> createState() => _PayoutUpiCardState();
}

class _PayoutUpiCardState extends State<PayoutUpiCard> {
  Map<String, dynamic> _card = const {};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, dynamic> _asMap(Object? v) {
    final data = v is List ? (v.isEmpty ? null : v.first) : v;
    return data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
  }

  String _s(String k) => (_card[k] ?? '').toString();

  Future<void> _load() async {
    try {
      final m = _asMap(await PayoutUpiCard.rpc('pharmacy_payout_upi'));
      if (!mounted) return;
      setState(() {
        _card = m;
        _loading = false;
      });
      RenderLog.write('c1889_payout_upi', m['ok'] == true ? 1 : 0);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(Map<String, dynamic> res) {
    final msg = (res['message'] ?? '').toString();
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Collect the VPA and send the ₹1. The format rule, the owner rule and the
  /// "a changed VPA drops back to unconfirmed" rule are all the backend's; this
  /// only keeps the button shut until there is something to send.
  Future<void> _addUpi() async {
    final vpa = TextEditingController(text: _s('vpa'));
    final name = TextEditingController(text: _s('vpa_name'));
    final send = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16, Ds.space.x16,
            MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x16),
        child: StatefulBuilder(
          builder: (ctx2, setSheet) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_s('title'), style: Ds.t.title),
              SizedBox(height: Ds.space.x8),
              Text(_s('hint'), style: Ds.t.caption),
              SizedBox(height: Ds.space.x16),
              TextField(
                controller: vpa,
                autofocus: true,
                decoration: InputDecoration(labelText: _s('vpa_label')),
                onChanged: (_) => setSheet(() {}),
              ),
              SizedBox(height: Ds.space.x12),
              TextField(
                controller: name,
                decoration: InputDecoration(labelText: _s('name_label')),
              ),
              SizedBox(height: Ds.space.x24),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: vpa.text.trim().isEmpty
                      ? null
                      : () => Navigator.of(ctx2).pop(true),
                  child: Text(_s('send_label')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final v = vpa.text.trim();
    final n = name.text.trim();
    vpa.dispose();
    name.dispose();
    if (send != true || v.isEmpty) return;
    setState(() => _busy = true);
    try {
      final res = _asMap(await PayoutUpiCard.rpc(
          'pharmacy_upi_verify_start', {'p_vpa': v, 'p_name': n}));
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(res);
      final card = res['card'];
      if (card is Map) {
        setState(() => _card = card.cast<String, dynamic>());
      } else {
        await _load();
      }
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      final res = _asMap(await PayoutUpiCard.rpc('pharmacy_upi_verify_confirm'));
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(res);
      final card = res['card'];
      if (card is Map) {
        setState(() => _card = card.cast<String, dynamic>());
      } else {
        await _load();
      }
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  Color _tone(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'danger':
        return Ds.c.danger;
      case 'info':
        return Ds.c.info;
      default:
        return Ds.c.warning;
    }
  }

  Color _toneSoft(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.successSoft;
      case 'danger':
        return Ds.c.dangerSoft;
      case 'info':
        return Ds.c.infoSoft;
      default:
        return Ds.c.warningSoft;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        height: Ds.space.x48,
        decoration:
            BoxDecoration(color: Ds.c.surface, borderRadius: Ds.r.rCard),
      );
    }
    // needed:false is the signup case — the card draws nothing at all.
    if (_card['ok'] != true || _card['needed'] != true) {
      return const SizedBox.shrink();
    }
    final verified = _card['verified'] == true;
    final pending = _card['test_pending'] == true;
    final canEdit = _card['can_edit'] == true;

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
          Text(_s('title'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x4),
          Text(_s('hint'), style: Ds.t.caption),
          if (_s('due_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(_s('due_label'), style: Ds.t.body),
          ],
          SizedBox(height: Ds.space.x12),
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x8),
            decoration: BoxDecoration(
              color: _toneSoft(_s('state_tone')),
              borderRadius: Ds.r.rChip,
            ),
            child: Text(
              _s('state_label'),
              style: Ds.t.caption.copyWith(color: _tone(_s('state_tone'))),
            ),
          ),
          if (_s('vpa').isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text('${_s('vpa_label')}: ${_s('vpa')}', style: Ds.t.body),
            if (_s('vpa_name').isNotEmpty)
              Text(_s('vpa_name'), style: Ds.t.caption),
          ],
          if (_s('locked_hint').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_s('locked_hint'), style: Ds.t.caption),
          ],
          if (canEdit && !verified) ...[
            SizedBox(height: Ds.space.x16),
            if (pending)
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: _busy ? null : _confirm,
                  child: Text(_s('confirm_label')),
                ),
              )
            else
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: _busy ? null : _addUpi,
                  child: Text(_s('add_label')),
                ),
              ),
            if (pending) ...[
              SizedBox(height: Ds.space.x8),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  onPressed: _busy ? null : _addUpi,
                  child: Text(_s('change_label')),
                ),
              ),
            ],
          ],
          if (canEdit && verified) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: _busy ? null : _addUpi,
                child: Text(_s('change_label')),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

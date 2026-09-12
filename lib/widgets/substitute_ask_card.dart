import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';

/// CHANGE #698 — the ONE widget that draws a substitute offer.
///
/// The in-app card inside an order and the public `/substitute-ask/<token>`
/// page render this same class over the same `substitute_ask_*` payload, so
/// the two surfaces cannot drift: a customer with the app and a customer with
/// only a WhatsApp link are answering literally the same question.
///
/// This widget decides NOTHING:
///   * every string — title, note, the two button labels, the countdown
///     sentence, the "always accept" line, every option's rank label — arrives
///     in the payload and is printed verbatim;
///   * the countdown is the BACKEND's sentence against the backend's clock.
///     There is no timer here, because a phone clock that disagrees with
///     `deadline_at` would show the customer a lie;
///   * options render in payload order, and that order IS the ranking;
///   * a pre-ticked option is `selected:true` in the payload (the customer's
///     own "always accept Y for salt S"), never a guess made here.
///
/// The only state this file owns is which options the finger is currently on
/// and in what order they were tapped — the user's own input, which is exactly
/// what gets posted back.
class SubstituteAskCard extends StatefulWidget {
  final Map<String, dynamic> ask;

  /// Called after a successful submit/skip with the RPC's own reply, so the
  /// host surface can re-render from the backend rather than guess.
  final ValueChanged<Map<String, dynamic>>? onAnswered;

  const SubstituteAskCard({super.key, required this.ask, this.onAnswered});

  /// Test seam, the same shape every other screen here uses: a widget test
  /// feeds payloads back without a network or a Supabase client.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<SubstituteAskCard> createState() => _SubstituteAskCardState();
}

class _SubstituteAskCardState extends State<SubstituteAskCard> {
  /// Tapped product ids, in the order they were tapped. That order is sent as
  /// the ranking, which is what "tick and rank" means without a drag handle on
  /// a 360 px phone.
  final List<int> _picked = <int>[];
  bool _remember = false;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _seed();
  }

  @override
  void didUpdateWidget(covariant SubstituteAskCard old) {
    super.didUpdateWidget(old);
    if (old.ask['ask_id'] != widget.ask['ask_id']) {
      _picked.clear();
      _seed();
    }
  }

  /// A pre-tick is the BACKEND's, never this widget's: `selected` is true only
  /// where the customer already told us to always accept that product.
  void _seed() {
    _remember = widget.ask['remember'] == true;
    for (final o in _options) {
      if (o['selected'] == true) {
        final id = _idOf(o);
        if (id != null && !_picked.contains(id)) _picked.add(id);
      }
    }
  }

  List<Map<String, dynamic>> get _options => ((widget.ask['options'] as List?) ??
          const [])
      .whereType<Map>()
      .map((e) => e.cast<String, dynamic>())
      .toList();

  int? _idOf(Map<String, dynamic> o) {
    final v = o['product_id'];
    if (v is int) return v;
    return int.tryParse('$v');
  }

  String _s(String key) => (widget.ask[key] ?? '').toString();

  Future<void> _send(String fn, Map<String, dynamic> params) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final raw = await SubstituteAskCard.rpc(fn, params);
      final data = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
      if (!mounted) return;
      final map = data is Map
          ? data.cast<String, dynamic>()
          : <String, dynamic>{'ok': false};
      setState(() => _busy = false);
      if (map['ok'] == false) {
        // The refusal sentence is the backend's. No Dart fallback wording.
        setState(() => _error =
            (map['message'] ?? map['title'] ?? map['error'] ?? '').toString());
      }
      widget.onAnswered?.call(map);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ask = widget.ask;
    final open = ask['is_open'] == true;
    final options = _options;

    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_s('order_label').isNotEmpty) ...[
            Text(_s('order_label'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x4),
          ],
          Text(_s('title'), style: Ds.t.subtitle),
          if (_s('note').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s('note'), style: Ds.t.caption),
          ],
          if (_s('countdown_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            _Pill(text: _s('countdown_label'), tone: Ds.c.warning),
          ],
          if (open && options.isEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(_s('empty_label'), style: Ds.t.caption),
          ],
          if (open && options.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            for (final o in options) _optionRow(o),
            if (_s('remember_label').isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              InkWell(
                borderRadius: Ds.r.rButton,
                onTap: _busy ? null : () => setState(() => _remember = !_remember),
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
                  child: Row(
                    children: [
                      Icon(
                        _remember
                            ? Icons.check_box_outlined
                            : Icons.check_box_outline_blank,
                        color: _remember ? Ds.c.brand : Ds.c.textSecondary,
                        size: Ds.space.x24,
                      ),
                      SizedBox(width: Ds.space.x8),
                      Expanded(
                        child: Text(_s('remember_label'), style: Ds.t.caption),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_error.isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(_error, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
            ],
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: (_busy || _picked.isEmpty) ? null : _submit,
                child: Text(_picked.isEmpty
                    ? _s('submit_empty_label')
                    : _s('submit_label')),
              ),
            ),
            SizedBox(height: Ds.space.x8),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: _busy ? null : _skip,
                child: Text(_s('skip_label')),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _submit() => _send('substitute_ask_submit', {
        'p_token': widget.ask['token'],
        'p_product_ids': List<int>.from(_picked),
        'p_remember': _remember,
      });

  void _skip() =>
      _send('substitute_ask_skip', {'p_token': widget.ask['token']});

  Widget _optionRow(Map<String, dynamic> o) {
    final id = _idOf(o);
    final at = id == null ? -1 : _picked.indexOf(id);
    final on = at >= 0;
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: InkWell(
        borderRadius: Ds.r.rCard,
        onTap: (_busy || id == null)
            ? null
            : () => setState(() {
                  if (on) {
                    _picked.remove(id);
                  } else {
                    _picked.add(id);
                  }
                }),
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
          padding: EdgeInsets.all(Ds.space.x12),
          decoration: BoxDecoration(
            color: on ? Ds.c.brandSoft : Ds.c.bg,
            borderRadius: Ds.r.rCard,
            border: Border.all(color: on ? Ds.c.brand : Ds.c.divider),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                on ? Icons.check_box_outlined : Icons.check_box_outline_blank,
                color: on ? Ds.c.brand : Ds.c.textSecondary,
                size: Ds.space.x24,
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((o['name'] ?? '').toString(), style: Ds.t.bodyStrong),
                    if ((o['company'] ?? '').toString().isNotEmpty)
                      Text((o['company'] ?? '').toString(),
                          style: Ds.t.caption),
                    if ((o['strength'] ?? '').toString().isNotEmpty)
                      Text((o['strength'] ?? '').toString(),
                          style: Ds.t.caption),
                    if ((o['pack_label'] ?? '').toString().isNotEmpty)
                      Text((o['pack_label'] ?? '').toString(),
                          style: Ds.t.caption),
                  ],
                ),
              ),
              // The order the customer tapped in IS the ranking they are
              // sending, so it is shown back to them while they choose.
              if (on)
                Padding(
                  padding: EdgeInsets.only(left: Ds.space.x8),
                  child: _Pill(
                      text: '${at + 1}', tone: Ds.c.brand, dense: true),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color tone;
  final bool dense;
  const _Pill({required this.text, required this.tone, this.dense = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: dense ? Ds.space.x8 : Ds.space.x12,
            vertical: Ds.space.x4),
        decoration: BoxDecoration(
          color: Color.alphaBlend(tone.withValues(alpha: 0.12), Ds.c.surface),
          borderRadius: Ds.r.rChip,
        ),
        child: Text(text, style: Ds.t.caption.copyWith(color: tone)),
      );
}

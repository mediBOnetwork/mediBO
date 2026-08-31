import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';

/// CMD #366 row 176 — the ONE substitute chooser, shared by all three
/// surfaces Om asked for: the admin's customer order tab, the customer's own
/// Orders tab, and the public WhatsApp token page. One widget means one
/// meaning for "the customer approved this" — the failure mode of three
/// separate implementations is three subtly different approvals.
///
/// It decides nothing. The heading, the note, every button label and tone, the
/// status line and the option list are all built by `_sub_offer_payload()`.
/// The only state this file owns is which option the person has highlighted
/// before they commit, which is their own input.
///
/// Nothing here can substitute anything. Choosing records a DECISION; applying
/// it to the order line is a separate admin action that the backend refuses
/// unless this decision says 'approved'.
class SubstituteChoice extends StatefulWidget {
  /// The offer payload, exactly as the backend built it.
  final Map<String, dynamic> offer;

  /// Token for the public page; null in-app (the offer id is used instead).
  final String? token;

  /// Called with the fresh payload after a decision lands, so the parent
  /// re-renders from the SERVER's new state rather than a local guess.
  final ValueChanged<Map<String, dynamic>>? onDecided;

  /// Read-only rendering for the admin, who may look but never answer for the
  /// customer.
  final bool readOnly;

  const SubstituteChoice({
    super.key,
    required this.offer,
    this.token,
    this.onDecided,
    this.readOnly = false,
  });

  /// Test seam, same shape as StockUpdateFormScreen.rpcTransport.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<SubstituteChoice> createState() => _SubstituteChoiceState();
}

class _SubstituteChoiceState extends State<SubstituteChoice> {
  int? _chosenId;
  bool _busy = false;
  String _error = '';

  List<Map<String, dynamic>> _list(Object? raw) =>
      ((raw as List?) ?? const []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();

  String _s(Object? v) => v?.toString() ?? '';

  Color _tone(String name) {
    switch (name) {
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'error':
        return Ds.c.danger;
      case 'info':
        return Ds.c.info;
      default:
        return Ds.c.textSecondary;
    }
  }

  Future<void> _decide(String action, {bool needsChoice = false}) async {
    if (needsChoice && _chosenId == null) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final res = await SubstituteChoice.rpc('sub_offer_decide', {
        if (widget.token != null) 'p_token': widget.token,
        if (widget.token == null) 'p_offer_id': widget.offer['offer_id'],
        'p_action': action,
        'p_product_id': needsChoice ? _chosenId : null,
      });
      if (!mounted) return;
      if (res is Map) {
        final m = res.cast<String, dynamic>();
        // ok:false ships its own sentence. Print that, never one typed here.
        if (m['ok'] == false) {
          setState(() => _error = _s(m['message']).isEmpty ? _s(m['error']) : _s(m['message']));
        } else {
          widget.onDecided?.call(m);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.offer;
    final status = _s(o['status']);
    final options = _list(o['options']);
    final buttons = _list(o['buttons']);
    final line = (o['line'] as Map?)?.cast<String, dynamic>() ?? const {};
    final decided = status != 'offered';
    final expired = o['expired'] == true;

    if (expired && status != 'approved') {
      return _Note(text: _s(o['expired_label']), tone: Ds.c.textSecondary);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _s(o['heading']),
          style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700, color: Ds.c.text),
        ),
        SizedBox(height: Ds.space.x4),
        Text(_s(o['note']), style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        SizedBox(height: Ds.space.x12),
        Container(
          padding: EdgeInsets.all(Ds.space.x12),
          decoration: BoxDecoration(
            color: Ds.c.dangerSoft,
            borderRadius: Ds.r.rButton,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _s(line['product_name']),
                  style: Ds.t.body.copyWith(fontWeight: FontWeight.w600, color: Ds.c.text),
                ),
              ),
              Text('× ${line['qty'] ?? 0}',
                  style: Ds.t.body.copyWith(color: Ds.c.text)),
            ],
          ),
        ),
        if (_s(o['status_label']).isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Text(
            _s(o['status_label']),
            style: Ds.t.body.copyWith(
              fontWeight: FontWeight.w600,
              color: _tone(_s(o['status_tone'])),
            ),
          ),
        ],
        if (!decided) ...[
          SizedBox(height: Ds.space.x16),
          // Options render in payload order — the backend has already put the
          // exact-composition, better-earning, better-selling one first.
          for (final opt in options) _option(opt),
          if (_error.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_error, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ],
          if (!widget.readOnly) ...[
            SizedBox(height: Ds.space.x16),
            for (final b in buttons) ...[
              SizedBox(
                width: double.infinity,
                height: Ds.space.x48,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _tone(_s(b['tone'])),
                    side: BorderSide(color: _tone(_s(b['tone']))),
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                  ),
                  onPressed: _busy ||
                          (b['needs_choice'] == true && _chosenId == null)
                      ? null
                      : () => _decide(_s(b['key']),
                          needsChoice: b['needs_choice'] == true),
                  child: Text(_s(b['label'])),
                ),
              ),
              SizedBox(height: Ds.space.x8),
            ],
          ],
        ],
      ],
    );
  }

  Widget _option(Map<String, dynamic> opt) {
    final id = int.tryParse(_s(opt['id']));
    final pricing = (opt['pricing'] as Map?)?.cast<String, dynamic>() ?? const {};
    final saving = (opt['saving'] as Map?)?.cast<String, dynamic>() ?? const {};
    final price = _s(pricing['price_display']);
    final selected = id != null && id == _chosenId;

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: InkWell(
        borderRadius: Ds.r.rButton,
        onTap: widget.readOnly || id == null
            ? null
            : () => setState(() => _chosenId = id),
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.space.x48),
          padding: EdgeInsets.all(Ds.space.x12),
          decoration: BoxDecoration(
            color: selected ? Ds.c.successSoft : Ds.c.surface,
            borderRadius: Ds.r.rButton,
            border: Border.all(
              color: selected ? Ds.c.success : Ds.c.divider,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: Ds.space.x16 + 2,
                color: selected ? Ds.c.success : Ds.c.textSecondary,
              ),
              SizedBox(width: Ds.space.x8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(opt['name']),
                        style: Ds.t.body.copyWith(
                            fontWeight: FontWeight.w600, color: Ds.c.text)),
                    Text(_s(opt['company']),
                        style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
                    if (_s(opt['match_label']).isNotEmpty)
                      Text(_s(opt['match_label']),
                          style:
                              Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
                    // Present only when the backend priced it. An item with no
                    // imported trade rate shows no price and no saving rather
                    // than a placeholder that reads like one.
                    if (saving['has'] == true)
                      Text(_s(saving['label']),
                          style: Ds.t.caption.copyWith(
                              fontWeight: FontWeight.w600,
                              color: Ds.c.success)),
                  ],
                ),
              ),
              if (price.isNotEmpty) ...[
                SizedBox(width: Ds.space.x8),
                Text(price,
                    style: Ds.t.body.copyWith(
                        fontWeight: FontWeight.w700, color: Ds.c.text)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  final Color tone;
  const _Note({required this.text, required this.tone});

  @override
  Widget build(BuildContext context) =>
      Text(text, style: Ds.t.body.copyWith(color: tone));
}

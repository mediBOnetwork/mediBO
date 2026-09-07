// lib/widgets/customer_payment_term_sheet.dart — CHANGE #1888
//
// Payment term, and the reason it is not Cash on Delivery.
//
// COD is the default a shop gets: the column defaults to it, the form field
// defaults to it, and the backfill gave it to the four shops that had no term
// at all. Anything else is a DECISION, so this sheet takes a reason and the
// backend writes it to customer_payment_term_log along with who changed it and
// which zone the shop was in.
//
// The sheet renders customer_payment_term_panel() and nothing else: the title,
// the reason label, the option list, the history lines and the "not in your
// zone" refusal are all the backend's words. A partner sees only its own zone
// because admin_active_zone() decided that, not this file.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

class CustomerPaymentTermSheet extends StatefulWidget {
  const CustomerPaymentTermSheet({super.key, required this.customerId});

  final String customerId;

  /// Returns true when the term was changed, so the caller can refresh.
  static Future<bool> open(BuildContext context, String customerId) async {
    final r = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => CustomerPaymentTermSheet(customerId: customerId),
    );
    return r ?? false;
  }

  @override
  State<CustomerPaymentTermSheet> createState() =>
      _CustomerPaymentTermSheetState();
}

class _CustomerPaymentTermSheetState extends State<CustomerPaymentTermSheet> {
  Map<String, dynamic>? _p;
  String? _error;
  bool _saving = false;
  String _term = '';
  final TextEditingController _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client.rpc(
          'customer_payment_term_panel',
          params: {
            'p': {'customer_id': widget.customerId}
          });
      if (!mounted) return;
      setState(() {
        _p = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
        _term = (_p?['current'] ?? '').toString();
      });
      RenderLog.write('c1888_term_panel', (_p?['ok'] == true) ? 'ok' : 'blocked');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('customer_set_payment_term', params: {
        'p': {
          'customer_id': widget.customerId,
          'payment_term': _term,
          'reason': _reason.text.trim(),
        }
      });
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      RenderLog.write('c1888_term_saved', _term);
      if (!mounted) return;
      final msg = (m['message'] ?? '').toString();
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg, style: Ds.t.body)));
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      // The backend's sentence, not one written here.
      if (mounted) {
        setState(() {
          _error = _message(e);
          _saving = false;
        });
      }
    }
  }

  String _message(Object e) {
    if (e is PostgrestException) {
      return e.message;
    }
    return '$e';
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (p == null) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x32),
        child: Center(
          child: SizedBox(
            width: Ds.space.x24,
            height: Ds.space.x24,
            child: CircularProgressIndicator(color: Ds.c.brand),
          ),
        ),
      );
    }

    final options = ((p['options'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    final history = ((p['history'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final blocked = p['ok'] != true;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        Ds.space.x24,
        Ds.space.x24,
        Ds.space.x24,
        Ds.space.x24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text((p['title'] ?? '').toString(), style: Ds.t.title),
            SizedBox(height: Ds.space.x4),
            Text((p['subtitle'] ?? '').toString(), style: Ds.t.caption),
            if (blocked) ...[
              SizedBox(height: Ds.space.x24),
            ] else ...[
              SizedBox(height: Ds.space.x24),
              DropdownButtonFormField<String>(
                initialValue: options.contains(_term) ? _term : null,
                isExpanded: true,
                style: Ds.t.body,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: Ds.c.bg,
                  contentPadding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12, vertical: Ds.space.x12),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: Ds.r.rButton,
                    borderSide: BorderSide(color: Ds.c.divider),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: Ds.r.rButton,
                    borderSide: BorderSide(color: Ds.c.brand),
                  ),
                  border: OutlineInputBorder(borderRadius: Ds.r.rButton),
                ),
                items: [
                  for (final o in options)
                    DropdownMenuItem<String>(
                        value: o, child: Text(o, style: Ds.t.body)),
                ],
                onChanged: (v) => setState(() => _term = v ?? _term),
              ),
              SizedBox(height: Ds.space.x16),
              Text((p['reason_label'] ?? '').toString(), style: Ds.t.bodyStrong),
              SizedBox(height: Ds.space.x4),
              TextField(
                controller: _reason,
                maxLines: 2,
                style: Ds.t.body,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: Ds.c.bg,
                  hintText: (p['reason_hint'] ?? '').toString(),
                  hintStyle: Ds.t.caption,
                  contentPadding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12, vertical: Ds.space.x12),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: Ds.r.rButton,
                    borderSide: BorderSide(color: Ds.c.divider),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: Ds.r.rButton,
                    borderSide: BorderSide(color: Ds.c.brand),
                  ),
                  border: OutlineInputBorder(borderRadius: Ds.r.rButton),
                ),
              ),
              if (_error != null) ...[
                SizedBox(height: Ds.space.x12),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(Ds.space.x12),
                  decoration: BoxDecoration(
                      color: Ds.c.dangerSoft, borderRadius: Ds.r.rButton),
                  child: Text(_error!, style: Ds.t.caption),
                ),
              ],
              SizedBox(height: Ds.space.x16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Ds.c.brand,
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                  ),
                  onPressed: _saving ? null : _save,
                  child: Text((p['save_label'] ?? '').toString(),
                      style: Ds.t.bodyStrong.copyWith(color: Ds.c.surface)),
                ),
              ),
              SizedBox(height: Ds.space.x24),
              Text((p['history_label'] ?? '').toString(), style: Ds.t.caption),
              SizedBox(height: Ds.space.x8),
              if (history.isEmpty)
                Text((p['empty_label'] ?? '').toString(), style: Ds.t.caption)
              else
                for (final h in history)
                  Padding(
                    padding: EdgeInsets.only(bottom: Ds.space.x8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((h['line'] ?? '').toString(), style: Ds.t.body),
                        Text(
                            '${(h['when'] ?? '').toString()} · ${(h['reason'] ?? '').toString()}',
                            style: Ds.t.caption),
                      ],
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }
}

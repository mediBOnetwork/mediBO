// CHANGE #710 — the public debit-note acknowledgement page, reached from the
// WhatsApp link `/return-ack/<token>`. No auth: the token in the URL is the
// authorisation, exactly the way `/stock-update/<token>` works, and
// supplier_return_ack_form / supplier_return_ack_submit are anon-granted for
// precisely these two calls and nothing else.
//
// This screen decides NOTHING. The eyebrow, the title, the intro, every column
// header, every rupee, the effect sentence, the button label, the success copy
// and both refusals arrive from supplier_return_ack_form(). Lines render in
// payload order. The only state this file owns is the note the supplier is
// typing and whether a submit is in flight.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

class SupplierReturnAckScreen extends StatefulWidget {
  final String token;
  const SupplierReturnAckScreen({super.key, required this.token});

  /// Test seam, the same shape as StockUpdateFormScreen.rpcTransport: a widget
  /// test can feed a payload back without a network or a Supabase client.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<SupplierReturnAckScreen> createState() =>
      _SupplierReturnAckScreenState();
}

String _s(Map? m, String key) {
  final v = m == null ? null : m[key];
  return v == null ? '' : v.toString();
}

List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

class _SupplierReturnAckScreenState extends State<SupplierReturnAckScreen> {
  Map<String, dynamic>? _form;
  final TextEditingController _note = TextEditingController();
  bool _loading = true;
  bool _submitting = false;
  bool _done = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await SupplierReturnAckScreen.rpc(
          'supplier_return_ack_form', {'p_token': widget.token});
      if (!mounted) return;
      setState(() {
        _form = res is Map ? Map<String, dynamic>.from(res) : null;
        _loading = false;
        _done = _form?['already'] == true;
      });
      RenderLog.write('c710_ack_page', _rows(_form?['items']).length);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = '';
    });
    try {
      final res = await SupplierReturnAckScreen.rpc('supplier_return_ack_submit',
          {'p_token': widget.token, 'p_note': _note.text.trim()});
      final m = res is Map ? Map<String, dynamic>.from(res) : const {};
      if (!mounted) return;
      if (m['ok'] == true) {
        setState(() => _done = true);
      } else {
        setState(() => _error = _s(m, 'message'));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = _s(_form, 'submit_error'));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _form;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: Ds.space.x48 * 12),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : f == null || f['ok'] != true
                    ? _Refusal(
                        title: _s(f, 'error_title'),
                        note: _s(f, 'error_note'),
                      )
                    : ListView(
                        padding: EdgeInsets.all(Ds.space.x16),
                        children: _body(f),
                      ),
          ),
        ),
      ),
    );
  }

  List<Widget> _body(Map<String, dynamic> f) {
    final items = _rows(f['items']);
    return [
      SizedBox(height: Ds.space.x24),
      Text(_s(f, 'eyebrow'), style: Ds.t.caption.copyWith(color: Ds.c.brand)),
      SizedBox(height: Ds.space.x4),
      Text(_s(f, 'title'), style: Ds.t.display),
      SizedBox(height: Ds.space.x4),
      Text('${_s(f, 'supplier_name')} · ${_s(f, 'date_label')}',
          style: Ds.t.caption),
      SizedBox(height: Ds.space.x16),
      Text(_s(f, 'intro'), style: Ds.t.body),
      SizedBox(height: Ds.space.x24),
      Container(
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (items.isEmpty)
              Text(_s(f, 'empty_text'), style: Ds.t.caption)
            else
              for (final i in items) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_s(i, 'product_name'), style: Ds.t.body),
                          SizedBox(height: Ds.space.x4),
                          Text(
                              '${_s(i, 'qty_value')} · ${_s(i, 'reason_label')}',
                              style: Ds.t.caption),
                        ],
                      ),
                    ),
                    SizedBox(width: Ds.space.x12),
                    Text(_s(i, 'amount_value'), style: Ds.t.bodyStrong),
                  ],
                ),
                SizedBox(height: Ds.space.x12),
              ],
            Divider(color: Ds.c.divider, height: Ds.space.x24),
            _Total(label: _s(f, 'taxable_label'), value: _s(f, 'taxable_value')),
            _Total(label: _s(f, 'gst_label'), value: _s(f, 'gst_value')),
            _Total(
                label: _s(f, 'total_label'),
                value: _s(f, 'total_value'),
                bold: true),
            SizedBox(height: Ds.space.x8),
            Text(_s(f, 'effect_label'),
                style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ],
        ),
      ),
      SizedBox(height: Ds.space.x24),
      if (_done)
        Container(
          width: double.infinity,
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: BoxDecoration(
            color: Ds.c.successSoft,
            borderRadius: Ds.r.rCard,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_s(f, 'success_title'),
                  style: Ds.t.subtitle.copyWith(color: Ds.c.success)),
              SizedBox(height: Ds.space.x4),
              Text(
                  f['already'] == true
                      ? _s(f, 'already_note')
                      : _s(f, 'success_note'),
                  style: Ds.t.caption),
            ],
          ),
        )
      else ...[
        TextField(
          controller: _note,
          style: Ds.t.body,
          decoration: InputDecoration(
            labelText: _s(f, 'note_hint'),
            labelStyle: Ds.t.caption,
            filled: true,
            fillColor: Ds.c.surface,
            border: OutlineInputBorder(borderRadius: Ds.r.rButton),
          ),
        ),
        SizedBox(height: Ds.space.x16),
        SizedBox(
          width: double.infinity,
          height: Ds.space.x48,
          child: FilledButton(
            onPressed: _submitting ? null : _submit,
            child: Text(_submitting
                ? _s(f, 'submitting_label')
                : _s(f, 'submit_label')),
          ),
        ),
        if (_error.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Text(_error, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
        ],
      ],
      SizedBox(height: Ds.space.x32),
    ];
  }
}

class _Total extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  const _Total({required this.label, required this.value, this.bold = false});

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x4),
      child: Row(
        children: [
          Expanded(
              child: Text(label,
                  style: bold ? Ds.t.bodyStrong : Ds.t.caption)),
          Text(value, style: bold ? Ds.t.bodyStrong : Ds.t.body),
        ],
      ),
    );
  }
}

class _Refusal extends StatelessWidget {
  final String title;
  final String note;
  const _Refusal({required this.title, required this.note});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Ds.t.title),
            SizedBox(height: Ds.space.x8),
            Text(note, style: Ds.t.caption),
          ],
        ),
      );
}

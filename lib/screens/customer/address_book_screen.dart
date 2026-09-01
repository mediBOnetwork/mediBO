import 'package:flutter/material.dart';
import 'package:pharma_b2b/utils/toast.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #460 / feature_gaps 164 — a chain with two branches can finally ship
/// to both.
///
/// pharmacy_profiles held exactly ONE address per account and no table anywhere
/// was named for addresses. `customer_addresses` is that table; this screen is
/// its only customer-facing surface and it computes nothing:
///   • the field list of the add/edit form is `my_addresses().fields`
///   • the address lines on a card are `items[].lines`, already joined
///   • "Default", "Make default", "Remove" and the reason a last address cannot
///     be removed are all backend strings
///   • every toast is the RPC's own `toast` / `message`
/// The default entry is what `_place_order_v2_core()` ships the next order to.
class AddressBookScreen extends StatefulWidget {
  const AddressBookScreen({super.key});

  @override
  State<AddressBookScreen> createState() => _AddressBookScreenState();
}

class _AddressBookScreenState extends State<AddressBookScreen> {
  final _sb = Supabase.instance.client;
  Map<String, dynamic>? _p;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _s(Map m, String k) => (m[k] ?? '').toString();

  List<Map<String, dynamic>> get _items =>
      ((_p ?? const {})['items'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _sb.rpc('my_addresses');
      _p = (res is Map) ? Map<String, dynamic>.from(res) : <String, dynamic>{};
    } catch (_) {
      _p = <String, dynamic>{'ok': false};
    }
    if (!mounted) return;
    setState(() => _loading = false);
    RenderLog.write('customer_addresses', {
      'items': _items.length,
      'defaults': _items.where((e) => e['is_default'] == true).length,
    });
  }

  /// Every mutation returns the WHOLE next payload plus its own toast, so the
  /// screen re-renders from the server's answer and never patches state itself.
  Future<void> _run(Future<dynamic> Function() rpc) async {
    if (_busy) return;
    setState(() => _busy = true);
    Map<String, dynamic> m = const {};
    try {
      final res = await rpc();
      m = (res is Map) ? Map<String, dynamic>.from(res) : const {};
    } catch (_) {
      m = const {'ok': false};
    }
    if (!mounted) return;
    final toast = _s(m, 'toast').isNotEmpty ? _s(m, 'toast') : _s(m, 'message');
    if (m['ok'] == true && m['items'] != null) {
      setState(() {
        _p = m;
        _busy = false;
      });
    } else {
      setState(() => _busy = false);
    }
    if (toast.isNotEmpty) showToast(context, toast, isError: m['ok'] != true);
  }

  Future<void> _openForm({Map<String, dynamic>? existing}) async {
    final p = _p ?? const {};
    final saved = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
      ),
      builder: (_) => _AddressForm(
        title: existing == null ? _s(p, 'add_title') : _s(p, 'edit_title'),
        saveLabel: _s(p, 'save_label'),
        fields: (p['fields'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
        initial: existing == null
            ? const {}
            : Map<String, dynamic>.from(
                (existing['raw'] as Map?) ?? const {}),
        id: existing == null ? null : _s(existing, 'id'),
      ),
    );
    if (saved == null) return;
    await _run(() => _sb.rpc('my_address_save', params: {'p': saved}));
  }

  @override
  Widget build(BuildContext context) {
    final p = _p ?? const {};
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(p, 'title'))),
      floatingActionButton: (p['ok'] == true)
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : () => _openForm(),
              icon: const Icon(Icons.add),
              label: Text(_s(p, 'add_label')),
            )
          : null,
      body: _loading
          ? const _ListSkeleton()
          : (p['ok'] != true)
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(Ds.space.x24),
                    child: Text(_s(p, 'message'),
                        textAlign: TextAlign.center, style: Ds.t.bodySecondary),
                  ),
                )
              : _items.isEmpty
                  ? _empty(p)
                  : ListView(
                      padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16,
                          Ds.space.x16, Ds.space.x48 * 2),
                      children: [
                        if (_s(p, 'note').isNotEmpty) ...[
                          Text(_s(p, 'note'), style: Ds.t.caption),
                          SizedBox(height: Ds.space.x16),
                        ],
                        for (final a in _items) ...[
                          _card(a),
                          SizedBox(height: Ds.space.x12),
                        ],
                      ],
                    ),
    );
  }

  Widget _empty(Map p) => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_s(p, 'empty_title'), style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x8),
              Text(_s(p, 'empty_note'),
                  textAlign: TextAlign.center, style: Ds.t.caption),
            ],
          ),
        ),
      );

  Widget _card(Map<String, dynamic> a) {
    final lines = (a['lines'] as List? ?? const []).map((e) => e.toString());
    final badge = _s(a, 'default_badge');
    final makeDefault = _s(a, 'make_default_label');
    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: BorderRadius.circular(Ds.r.card),
        boxShadow: Ds.elevation.e1,
      ),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(_s(a, 'label'), style: Ds.t.subtitle)),
              if (badge.isNotEmpty)
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x8, vertical: Ds.space.x4),
                  decoration: BoxDecoration(
                    color: Ds.c.successSoft,
                    borderRadius: BorderRadius.circular(Ds.r.chip),
                  ),
                  child: Text(badge, style: Ds.t.caption),
                ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          for (final l in lines)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x4),
              child: Text(l, style: Ds.t.bodySecondary),
            ),
          SizedBox(height: Ds.space.x8),
          Row(
            children: [
              if (makeDefault.isNotEmpty)
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() => _sb.rpc('my_address_set_default',
                            params: {'p_id': _s(a, 'id')})),
                    child: Text(makeDefault),
                  ),
                ),
              const Spacer(),
              SizedBox(
                height: Ds.touch.minTarget,
                child: IconButton(
                  tooltip: _s(a, 'delete_label'),
                  onPressed: (_busy || a['can_delete'] != true)
                      ? null
                      : () => _run(() => _sb.rpc('my_address_delete',
                          params: {'p_id': _s(a, 'id')})),
                  icon: Icon(Icons.delete_outline, color: Ds.c.danger),
                ),
              ),
              SizedBox(
                height: Ds.touch.minTarget,
                child: IconButton(
                  onPressed: _busy ? null : () => _openForm(existing: a),
                  icon: const Icon(Icons.edit_outlined),
                ),
              ),
            ],
          ),
          if (_s(a, 'cannot_delete_note').isNotEmpty)
            Text(_s(a, 'cannot_delete_note'), style: Ds.t.caption),
        ],
      ),
    );
  }
}

/// The add/edit sheet. Its field list is the payload's, so a new address field
/// is a backend row and never a Flutter change.
class _AddressForm extends StatefulWidget {
  final String title;
  final String saveLabel;
  final List<Map<String, dynamic>> fields;
  final Map<String, dynamic> initial;
  final String? id;

  const _AddressForm({
    required this.title,
    required this.saveLabel,
    required this.fields,
    required this.initial,
    this.id,
  });

  @override
  State<_AddressForm> createState() => _AddressFormState();
}

class _AddressFormState extends State<_AddressForm> {
  final Map<String, TextEditingController> _ctl = {};

  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      final key = (f['key'] ?? '').toString();
      _ctl[key] = TextEditingController(
          text: (widget.initial[key] ?? '').toString());
    }
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: Ds.space.x16,
        right: Ds.space.x16,
        top: Ds.space.x16,
        bottom: MediaQuery.of(context).viewInsets.bottom + Ds.space.x24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: Ds.t.title),
            SizedBox(height: Ds.space.x16),
            for (final f in widget.fields) ...[
              TextField(
                controller: _ctl[(f['key'] ?? '').toString()],
                maxLength: (f['max_len'] is num)
                    ? (f['max_len'] as num).toInt()
                    : null,
                maxLines: (f['input_type'] == 'multiline') ? 3 : 1,
                keyboardType: (f['input_type'] == 'phone')
                    ? TextInputType.phone
                    : TextInputType.text,
                decoration: InputDecoration(
                  labelText: (f['label'] ?? '').toString(),
                  hintText: (f['hint'] ?? '').toString(),
                  counterText: '',
                ),
              ),
              SizedBox(height: Ds.space.x12),
            ],
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: () {
                  final out = <String, dynamic>{};
                  if (widget.id != null) out['id'] = widget.id;
                  for (final f in widget.fields) {
                    final key = (f['key'] ?? '').toString();
                    out[key] = _ctl[key]?.text ?? '';
                  }
                  Navigator.of(context).pop(out);
                },
                child: Text(widget.saveLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        for (int i = 0; i < 3; i++) ...[
          Container(
            height: Ds.space.x48 * 2,
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: BorderRadius.circular(Ds.r.card),
            ),
          ),
          SizedBox(height: Ds.space.x12),
        ],
      ],
    );
  }
}

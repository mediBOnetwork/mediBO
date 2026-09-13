// CMD #1935 — Admin › Customer documents.
//
// This is the screen that makes "adding a document, or making one mandatory,
// is a row change, never a deploy" true rather than aspirational. Every row it
// draws is a customer_doc_types row, and the two switches write straight back
// through customer_doc_type_set(). A customer on step 2 sees the change on
// their next read — no build, no upload, no wait.
//
// It decides nothing: the title, the subtitle, both switch labels, the
// requirement caption and the empty state all arrive on
// customer_doc_types_admin(), which also refuses a non-admin caller and hands
// this screen the refusal to print.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

class CustomerDocTypesScreen extends StatefulWidget {
  const CustomerDocTypesScreen({super.key});

  /// Test seam — the same shape every screen in this app uses.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<CustomerDocTypesScreen> createState() => _CustomerDocTypesScreenState();
}

class _CustomerDocTypesScreenState extends State<CustomerDocTypesScreen> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;
  String _busy = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await CustomerDocTypesScreen.rpc('customer_doc_types_admin');
      if (!mounted) return;
      setState(() {
        _p = r is Map ? Map<String, dynamic>.from(r) : const {};
        _loading = false;
      });
      RenderLog.write('c1935_admin_doc_types', _items.length);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      RenderLog.write('c1935_admin_doc_types', 0);
    }
  }

  List<Map<String, dynamic>> get _items {
    final raw = _p['items'];
    if (raw is! List) return const [];
    return raw
        .map((e) => e is Map ? Map<String, dynamic>.from(e) : null)
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  Future<void> _set(String key, Map<String, dynamic> patch) async {
    setState(() => _busy = key);
    try {
      final r = await CustomerDocTypesScreen.rpc(
          'customer_doc_type_set', {'p_key': key, 'p_patch': patch});
      if (!mounted) return;
      final m = r is Map ? Map<String, dynamic>.from(r) : const {};
      final next = m['payload'];
      setState(() {
        _busy = '';
        if (next is Map) _p = Map<String, dynamic>.from(next);
      });
      final msg = (m['message'] ?? '').toString();
      if (msg.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (_) {
      if (mounted) setState(() => _busy = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text((_p['title'] ?? '').toString())),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: EdgeInsets.all(Ds.space.x16),
                children: [
                  if (_p['ok'] != true)
                    Text((_p['message'] ?? '').toString(), style: Ds.t.body)
                  else ...[
                    Text((_p['subtitle'] ?? '').toString(),
                        style: Ds.t.bodySecondary),
                    SizedBox(height: Ds.space.x16),
                    if (items.isEmpty)
                      Text((_p['empty_line'] ?? '').toString(),
                          style: Ds.t.bodySecondary)
                    else
                      for (final it in items) ...[
                        _TypeRow(
                          item: it,
                          requiredLabel:
                              (_p['required_label'] ?? '').toString(),
                          activeLabel: (_p['active_label'] ?? '').toString(),
                          busy: _busy == (it['key'] ?? '').toString(),
                          onSet: (patch) =>
                              _set((it['key'] ?? '').toString(), patch),
                        ),
                        SizedBox(height: Ds.space.x12),
                      ],
                  ],
                  SizedBox(height: Ds.space.x32),
                ],
              ),
      ),
    );
  }
}

class _TypeRow extends StatelessWidget {
  final Map<String, dynamic> item;
  final String requiredLabel;
  final String activeLabel;
  final bool busy;
  final ValueChanged<Map<String, dynamic>> onSet;

  const _TypeRow({
    required this.item,
    required this.requiredLabel,
    required this.activeLabel,
    required this.busy,
    required this.onSet,
  });

  @override
  Widget build(BuildContext context) {
    final hint = (item['hint'] ?? '').toString();
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
          Text((item['label'] ?? '').toString(), style: Ds.t.subtitle),
          if (hint.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(hint, style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x8),
          _Toggle(
            label: requiredLabel,
            value: item['required'] == true,
            busy: busy,
            onChanged: (v) => onSet({'required': v}),
          ),
          _Toggle(
            label: activeLabel,
            value: item['active'] == true,
            busy: busy,
            onChanged: (v) => onSet({'active': v}),
          ),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  final String label;
  final bool value;
  final bool busy;
  final ValueChanged<bool> onChanged;

  const _Toggle({
    required this.label,
    required this.value,
    required this.busy,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: Ds.touch.minTarget,
      child: Row(
        children: [
          Expanded(child: Text(label, style: Ds.t.body)),
          Switch(value: value, onChanged: busy ? null : onChanged),
        ],
      ),
    );
  }
}

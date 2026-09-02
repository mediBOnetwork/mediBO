import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #465 · supplier register row 63, the admin half.
///
/// The public /supplier-signup page writes a `supplier_leads` row; this is
/// where an admin reads the queue and decides. Approving does NOT write a
/// second path into supplier_profiles — admin_supplier_lead_decide() calls the
/// same admin_create_supplier() the admin screens already use, so an approved
/// application produces exactly the supplier an admin would have typed by hand.
///
/// Renderer only: the title, the empty line, both button captions and the
/// result message all arrive in the payload.
class SupplierLeadsScreen extends StatefulWidget {
  const SupplierLeadsScreen({super.key});

  @override
  State<SupplierLeadsScreen> createState() => _SupplierLeadsScreenState();
}

class _SupplierLeadsScreenState extends State<SupplierLeadsScreen> {
  Map<String, dynamic>? _p;
  bool _loading = true;
  String _status = 'new';
  String _busyId = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final raw = await Supabase.instance.client
          .rpc('admin_supplier_leads', params: {'p_status': _status});
      final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (!mounted) return;
      setState(() {
        _p = map is Map ? map.cast<String, dynamic>() : null;
        _loading = false;
      });
      RenderLog.write('c465_sup_leads',
          'rows:${((_p?['rows'] as List?) ?? const []).length};status:$_status');
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _decide(String id, String action) async {
    setState(() => _busyId = id);
    String msg = '';
    try {
      final raw = await Supabase.instance.client.rpc(
          'admin_supplier_lead_decide',
          params: {'p_id': id, 'p_action': action});
      final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      msg = map is Map ? (map['message'] ?? '').toString() : '';
    } catch (_) {
      // The list re-reads either way; the server is the only authority.
    }
    if (!mounted) return;
    setState(() => _busyId = '');
    // The sentence is the backend's, verbatim.
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final rows = ((p?['rows'] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text((p?['title'] ?? '').toString())),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (p != null && p['ok'] != true)
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(Ds.space.x24),
                    child: Text((p['message'] ?? '').toString(),
                        style: Ds.t.body),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.all(Ds.space.x16),
                      child: Row(
                        children: [
                          for (final s in const ['new', 'approved', 'rejected'])
                            Padding(
                              padding: EdgeInsets.only(right: Ds.space.x8),
                              child: ChoiceChip(
                                label: Text(s),
                                selected: _status == s,
                                onSelected: (_) {
                                  setState(() => _status = s);
                                  _load();
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (rows.isEmpty)
                      Padding(
                        padding: EdgeInsets.all(Ds.space.x24),
                        child: Text((p?['empty'] ?? '').toString(),
                            style: Ds.t.body),
                      )
                    else
                      Expanded(
                        child: ListView.separated(
                          padding: EdgeInsets.symmetric(
                              horizontal: Ds.space.x16),
                          itemCount: rows.length,
                          separatorBuilder: (_, _) =>
                              SizedBox(height: Ds.space.x12),
                          itemBuilder: (context, i) =>
                              _leadCard(rows[i], p ?? const {}),
                        ),
                      ),
                  ],
                ),
    );
  }

  Widget _leadCard(Map<String, dynamic> r, Map<String, dynamic> p) {
    final id = (r['id'] ?? '').toString();
    final busy = _busyId == id;
    final decided = (r['status'] ?? '') != 'new';
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: Text((r['name'] ?? '').toString(),
                      style: Ds.t.subtitle)),
              Text((r['when_label'] ?? '').toString(), style: Ds.t.caption),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text(
            [
              (r['contact'] ?? '').toString(),
              (r['mobile'] ?? '').toString(),
              (r['city'] ?? '').toString(),
            ].where((s) => s.isNotEmpty).join(' · '),
            style: Ds.t.caption,
          ),
          SizedBox(height: Ds.space.x8),
          Text('GSTIN ${r['gstin'] ?? ''}', style: Ds.t.body),
          if ((r['dl'] ?? '').toString().isNotEmpty)
            Text((r['dl'] ?? '').toString(), style: Ds.t.caption),
          if (!decided) ...[
            SizedBox(height: Ds.space.x16),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: FilledButton(
                      onPressed: busy ? null : () => _decide(id, 'approve'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Ds.c.brand,
                        shape: RoundedRectangleBorder(
                            borderRadius: Ds.r.rButton),
                      ),
                      child: Text((p['approve_label'] ?? '').toString()),
                    ),
                  ),
                ),
                SizedBox(width: Ds.space.x12),
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed: busy ? null : () => _decide(id, 'reject'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Ds.c.danger,
                      side: BorderSide(color: Ds.c.danger),
                      shape:
                          RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                    ),
                    child: Text((p['reject_label'] ?? '').toString()),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

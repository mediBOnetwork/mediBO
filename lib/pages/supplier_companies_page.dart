import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';
import '../utils/toast.dart';

/// [S1] Supplier portal — the companies he stocks (cmd #401).
///
/// Until now the engine only learned what a supplier does NOT stock, one
/// rejection at a time. This is the other half: he declares his companies and
/// the waterfall asks him first for them.
///
/// Three lists, all built by `supplier_coverage_get`: what he declared, what we
/// SUGGEST from his own past 'Available' answers, and — deliberately on the
/// same screen — the exclusions he already filed. Showing the blocks beside the
/// declarations is what makes the rule legible: a declaration is a preference,
/// an exclusion is a hard block, and the block wins. That sentence is
/// `excluded_note` and it comes from the backend too.
class SupplierCompaniesPage extends StatefulWidget {
  const SupplierCompaniesPage({super.key});

  @override
  State<SupplierCompaniesPage> createState() => _SupplierCompaniesPageState();
}

class _SupplierCompaniesPageState extends State<SupplierCompaniesPage> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _s(Object? v) => v == null ? '' : v.toString();

  List<Map<String, dynamic>> _list(String key) =>
      (_p[key] as List?)
          ?.whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList() ??
      const [];

  Future<void> _load() async {
    try {
      final r = await Supabase.instance.client.rpc('supplier_coverage_get');
      if (!mounted) return;
      setState(() {
        _p = r is Map ? Map<String, dynamic>.from(r) : const {};
        _loading = false;
      });
      RenderLog.write('c401_coverage', _list('declared').length);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _set(String? company, String? category, bool on) async {
    setState(() => _busy = true);
    try {
      final r = await Supabase.instance.client.rpc('supplier_coverage_set', params: {
        'p_company': company,
        'p_category': category,
        'p_on': on,
      });
      final m = r is Map ? Map<String, dynamic>.from(r) : const <String, dynamic>{};
      if (mounted && _s(m['message']).isNotEmpty) {
        showToast(context, _s(m['message']), isError: m['error'] != null);
      }
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(_p['screen_title']))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.all(Ds.space.x16),
              children: [
                Text(_s(_p['intro']), style: Ds.t.bodySecondary),
                SizedBox(height: Ds.space.x24),
                _section(
                  title: _s(_p['declared_title']),
                  empty: _s(_p['declared_empty']),
                  rows: _list('declared'),
                  action: _s(_p['remove_label']),
                  onAction: (r) => _set(_s(r['company']).isEmpty ? null : _s(r['company']),
                      _s(r['category']).isEmpty ? null : _s(r['category']), false),
                ),
                SizedBox(height: Ds.space.x24),
                _section(
                  title: _s(_p['suggest_title']),
                  empty: _s(_p['suggest_empty']),
                  rows: _list('suggestions'),
                  action: _s(_p['add_label']),
                  subKey: 'sub_label',
                  labelKey: 'company',
                  onAction: (r) => _set(_s(r['company']), null, true),
                ),
                SizedBox(height: Ds.space.x24),
                _section(
                  title: _s(_p['excluded_title']),
                  empty: '',
                  note: _s(_p['excluded_note']),
                  rows: _list('excluded'),
                ),
              ],
            ),
    );
  }

  Widget _section({
    required String title,
    required String empty,
    required List<Map<String, dynamic>> rows,
    String? action,
    String? note,
    String labelKey = 'label',
    String? subKey,
    void Function(Map<String, dynamic>)? onAction,
  }) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Ds.t.subtitle),
        if (note != null && note.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(note, style: Ds.t.caption),
        ],
        SizedBox(height: Ds.space.x12),
        if (rows.isEmpty && empty.isNotEmpty)
          Text(empty, style: Ds.t.caption)
        else
          for (final r in rows)
            Container(
              constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
              padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_s(r[labelKey]), style: Ds.t.body),
                      if (subKey != null && _s(r[subKey]).isNotEmpty)
                        Text(_s(r[subKey]), style: Ds.t.caption),
                    ],
                  ),
                ),
                if (action != null && onAction != null)
                  TextButton(
                    onPressed: _busy ? null : () => onAction(r),
                    child: Text(action),
                  ),
              ]),
            ),
      ]),
    );
  }
}

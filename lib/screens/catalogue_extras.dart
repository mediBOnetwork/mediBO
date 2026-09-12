import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../models/product.dart';
import '../utils/render_log.dart';
import '../utils/toast.dart';
import '../widgets/compact_product_card.dart';

/// CHANGE #748 — the three things the Catalogue tab was missing.
///
/// All of it is payload. `catalogue_extras()` says whether each one is offered
/// at all, what it is called, which fields the form asks for and how many rows
/// an export may carry; `catalogue_recent()` groups the new arrivals by company
/// and formats their counts. Nothing here decides placement, wording, a window
/// in days, or whether a product is new — a card is new because it arrived with
/// `is_new`, and the chip prints `new_badge` exactly as it was sent.
typedef CatRpc = Future<dynamic> Function(String fn, Map<String, dynamic>? p);

Future<dynamic> _defaultRpc(String fn, Map<String, dynamic>? p) =>
    Supabase.instance.client.rpc(fn, params: p);

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : const {};

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

/// "Recently added", grouped by company exactly as the backend grouped it.
class CatalogueRecent extends StatefulWidget {
  const CatalogueRecent({super.key, this.rpc});

  final CatRpc? rpc;

  @override
  State<CatalogueRecent> createState() => _CatalogueRecentState();
}

class _CatalogueRecentState extends State<CatalogueRecent> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;

  CatRpc get _rpc => widget.rpc ?? _defaultRpc;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await _rpc('catalogue_recent', const {});
      if (!mounted) return;
      setState(() {
        _p = _map(res);
        _loading = false;
      });
      RenderLog.write('c748_recent',
          'ok=${_p['ok']};groups=${(_p['groups'] as List?)?.length ?? 0}');
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: List.generate(
          3,
          (_) => Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: Container(
              height: Ds.space.x48 * 3,
              decoration:
                  BoxDecoration(color: Ds.c.surface, borderRadius: Ds.r.rCard),
            ),
          ),
        ),
      );
    }
    final groups = (_p['groups'] as List?) ?? const [];
    if (groups.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Text(_s(_p, 'empty_text'),
              textAlign: TextAlign.center, style: Ds.t.body),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: EdgeInsets.all(Ds.space.x16),
        itemCount: groups.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(_p, 'title'), style: Ds.t.title),
                  SizedBox(height: Ds.space.x4),
                  Text(_s(_p, 'subtitle'), style: Ds.t.caption),
                ],
              ),
            );
          }
          return _group(_map(groups[i - 1]));
        },
      ),
    );
  }

  Widget _group(Map<String, dynamic> g) {
    final items = ((g['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => Product.fromHomeCard(Map<String, dynamic>.from(m)))
        .toList(growable: false);
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(_s(g, 'company'), style: Ds.t.subtitle)),
              SizedBox(width: Ds.space.x8),
              Text(_s(g, 'count_label'), style: Ds.t.caption),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          SizedBox(
            height: CompactProductCard.extent,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, _) => SizedBox(width: Ds.space.x12),
              itemBuilder: (context, i) => SizedBox(
                width: 170,
                child: CompactProductCard(
                  product: items[i],
                  onTap: () => Navigator.of(context)
                      .pushNamed('/product/${items[i].id}'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Missing product?" — the form, its duplicate answer, and the requester's own
/// list. The FIELDS are the payload's: the backend decides what is asked and
/// which of them is required, so adding "strength" one day is an INSERT.
class CatalogueRequestSheet extends StatefulWidget {
  const CatalogueRequestSheet({super.key, required this.config, this.rpc});

  final Map<String, dynamic> config;
  final CatRpc? rpc;

  @override
  State<CatalogueRequestSheet> createState() => _CatalogueRequestSheetState();
}

class _CatalogueRequestSheetState extends State<CatalogueRequestSheet> {
  final Map<String, TextEditingController> _c = {};
  Map<String, dynamic> _dupe = const {};
  bool _busy = false;

  CatRpc get _rpc => widget.rpc ?? _defaultRpc;

  List<Map<String, dynamic>> get _fields => ((widget.config['fields'] as List?) ??
          const [])
      .whereType<Map>()
      .map((m) => Map<String, dynamic>.from(m))
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    for (final f in _fields) {
      _c[_s(f, 'key')] = TextEditingController();
    }
    RenderLog.write('c748_request_form', 'fields=${_fields.length}');
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _v(String k) => _c[k]?.text.trim() ?? '';

  /// The duplicate answer arrives from the backend and is SHOWN, not guessed:
  /// the screen never searches the catalogue itself.
  Future<void> _check() async {
    if (_v('name').isEmpty) return;
    try {
      final r = _map(await _rpc(
          'catalogue_request_check', {'p_name': _v('name'), 'p_company': _v('company')}));
      if (!mounted) return;
      setState(() => _dupe = r['duplicate'] == true ? r : const {});
    } catch (_) {/* a failed check must never block the form */}
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = _map(await _rpc('catalogue_request_product', {
        'p_name': _v('name'),
        'p_company': _v('company'),
        'p_salt': _v('salt'),
        'p_pack': _v('pack'),
      }));
      if (!mounted) return;
      final msg = _s(r, 'message');
      if (r['ok'] == true) {
        Navigator.of(context).maybePop();
        if (msg.isNotEmpty) showToast(context, msg);
        return;
      }
      // A duplicate is not an error to shout about — it is the answer.
      if (_s(r, 'error') == 'duplicate') {
        setState(() => _dupe = r);
        return;
      }
      if (msg.isNotEmpty) showToast(context, msg, isError: true);
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = widget.config;
    return Padding(
      padding: EdgeInsets.only(
        left: Ds.space.x16,
        right: Ds.space.x16,
        top: Ds.space.x24,
        bottom: MediaQuery.of(context).viewInsets.bottom + Ds.space.x24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(cfg, 'title'), style: Ds.t.title),
          SizedBox(height: Ds.space.x4),
          Text(_s(cfg, 'subtitle'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x24),
          for (final f in _fields) ...[
            TextField(
              controller: _c[_s(f, 'key')],
              onEditingComplete: _s(f, 'key') == 'name' ? _check : null,
              decoration: InputDecoration(labelText: _s(f, 'label')),
            ),
            SizedBox(height: Ds.space.x12),
          ],
          if (_dupe.isNotEmpty) _dupeCard(),
          SizedBox(height: Ds.space.x12),
          SizedBox(
            width: double.infinity,
            height: Ds.space.x48,
            child: FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(_s(cfg, 'submit_label')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dupeCard() {
    final p = _map(_dupe['product']);
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
          color: Ds.c.infoSoft, borderRadius: Ds.r.rCard),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(_dupe, 'message'), style: Ds.t.body),
          SizedBox(height: Ds.space.x8),
          Text(_s(p, 'name'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          SizedBox(
            height: Ds.space.x48,
            child: TextButton(
              onPressed: () {
                Navigator.of(context).maybePop();
                Navigator.of(context).pushNamed('/product/${p['id']}');
              },
              child: Text(_s(_dupe, 'cta')),
            ),
          ),
        ],
      ),
    );
  }
}

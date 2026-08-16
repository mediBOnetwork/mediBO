import 'package:flutter/material.dart';
import 'package:pharma_b2b/utils/toast.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

/// CHANGE #173 — B2B repeat-buying / reorder suite.
///
/// This screen renders backend payloads verbatim. It answers no question the
/// backend could answer: cadence, "due", prices, availability, swap suggestions
/// and every label all arrive already computed and worded from:
///   • reorder_suggestions()          — predictive "due for reorder" list
///   • reorder_diff(order_id)          — smart basket diff of a past order
///   • reorder_build_cart(ids?)        — build a cart from due/selected items
///   • reorder_apply_diff(order_id)    — build a cart from the reconciled order
///   • reorder_subscription_*          — standing-order set / list / update
///
/// The app only requests and renders; it sends the user's taps back.
class ReorderScreen extends StatefulWidget {
  /// When set, the screen opens in "diff" mode for that past order
  /// (the Smart Basket Diff). When null, it shows predictive suggestions.
  final String? orderId;
  const ReorderScreen({super.key, this.orderId});

  @override
  State<ReorderScreen> createState() => _ReorderScreenState();
}

class _ReorderScreenState extends State<ReorderScreen> {
  final _sb = Supabase.instance.client;
  bool _loading = true;
  bool _busy = false;
  Map<String, dynamic>? _p; // the screen payload (suggestions or diff)

  bool get _diffMode => widget.orderId != null;

  // Backend-worded generic error (payload 'generic_error'), never guessed here.
  String get _genericError => ((_p ?? const {})['generic_error'] ?? '').toString();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = _diffMode
          ? await _sb.rpc('reorder_diff', params: {'p_order_id': widget.orderId})
          : await _sb.rpc('reorder_suggestions');
      _p = (res is Map) ? Map<String, dynamic>.from(res) : <String, dynamic>{};
    } catch (_) {
      _p = <String, dynamic>{'ok': false};
    }
    if (!mounted) return;
    setState(() => _loading = false);
    _logRender();
  }

  void _logRender() {
    final p = _p ?? const {};
    if (_diffMode) {
      final summary = (p['summary'] as Map?) ?? const {};
      RenderLog.write('reorder_screen', {
        'mode': 'diff',
        'lines': (p['lines'] as List?)?.length ?? 0,
        'available': summary['available'] ?? 0,
      });
    } else {
      RenderLog.write('reorder_screen', {
        'mode': 'suggest',
        'items': (p['items'] as List?)?.length ?? 0,
        'due': p['due_count'] ?? 0,
      });
    }
  }

  String _s(Map m, String k) => (m[k] ?? '').toString();

  Color _tone(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      default:
        return Ds.c.textSecondary;
    }
  }

  Future<void> _run(Future<dynamic> Function() rpc,
      {String? okFallback}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await rpc();
      final m = (res is Map) ? Map<String, dynamic>.from(res) : const {};
      final ok = m['ok'] == true;
      final msg = _s(m, 'message');
      if (mounted) {
        showToast(context, msg.isNotEmpty ? msg : (okFallback ?? ''),
            isError: !ok);
      }
    } catch (_) {
      if (mounted) showToast(context, _genericError, isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p ?? const {};
    final title =
        _diffMode ? _s(p, 'title') : _s(p, 'title');
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(title.isEmpty ? 'Reorder' : title, style: Ds.t.subtitle),
        backgroundColor: Ds.c.surface,
        elevation: 0,
      ),
      body: _loading
          ? _skeleton()
          : RefreshIndicator(
              onRefresh: _load,
              child: _diffMode ? _diffBody(p) : _suggestBody(p),
            ),
    );
  }

  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: List.generate(
          5,
          (_) => Container(
            height: 84,
            margin: EdgeInsets.only(bottom: Ds.space.x12),
            decoration: BoxDecoration(
                color: Ds.c.surface, borderRadius: Ds.r.rCard),
          ),
        ),
      );

  // ─── Predictive suggestions ────────────────────────────────────────────────
  Widget _suggestBody(Map p) {
    if (p['has_history'] != true) {
      return _empty(_s(p, 'empty_title'), _s(p, 'empty_note'));
    }
    final items = (p['items'] as List?) ?? const [];
    final due = items.where((e) => (e as Map)['due'] == true).toList();
    final rest = items.where((e) => (e as Map)['due'] != true).toList();
    final hasDue = due.isNotEmpty;

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        _subsLink(_s(p, 'manage_label')),
        if (hasDue) ...[
          _sectionHeader(_s(p, 'due_title'), badge: '${p['due_count'] ?? due.length}'),
          SizedBox(height: Ds.space.x8),
          _primaryButton(
            _s(p, 'add_all_label'),
            onTap: () => _run(
              () => _sb.rpc('reorder_build_cart'),
              okFallback: 'Added',
            ).then((_) => _load()),
          ),
          SizedBox(height: Ds.space.x12),
          ...due.map((e) => _suggestCard(e as Map, p)),
          SizedBox(height: Ds.space.x24),
        ],
        if (rest.isNotEmpty) ...[
          _sectionHeader(_s(p, 'all_title')),
          SizedBox(height: Ds.space.x8),
          ...rest.map((e) => _suggestCard(e as Map, p)),
        ],
      ],
    );
  }

  Widget _suggestCard(Map it, Map p) {
    final canAdd = it['can_add'] == true;
    final due = it['due'] == true;
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _thumb(_s(it, 'image_url')),
          SizedBox(width: Ds.space.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_s(it, 'name'),
                    style: Ds.t.body, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (_s(it, 'marketer').isNotEmpty)
                  Text(_s(it, 'marketer'),
                      style: Ds.t.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                SizedBox(height: Ds.space.x8),
                Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x4, children: [
                  _pill(_s(it, 'qty_label'), Ds.c.bg, Ds.c.textSecondary),
                  if (due && _s(it, 'due_label').isNotEmpty)
                    _pill(_s(it, 'due_label'), Ds.c.warningSoft, Ds.c.warning),
                  if (_s(it, 'since_label').isNotEmpty)
                    _pill(_s(it, 'since_label'), Ds.c.bg, Ds.c.textSecondary),
                ]),
                if (_s(it, 'predicted_label').isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(_s(it, 'predicted_label'), style: Ds.t.caption),
                ],
              ],
            ),
          ),
          SizedBox(width: Ds.space.x8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_s(it, 'price_display'),
                  style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
              SizedBox(height: Ds.space.x8),
              canAdd
                  ? _smallAddButton(_s(p, 'add_label'), () => _run(
                        () => _sb.rpc('reorder_build_cart',
                            params: {
                              'p_product_ids': [_s(it, 'product_id')]
                            }),
                        okFallback: '',
                      ))
                  : Text(_s(it, 'unavailable_label'),
                      style: Ds.t.caption.copyWith(color: Ds.c.danger),
                      textAlign: TextAlign.end),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Smart basket diff ──────────────────────────────────────────────────────
  Widget _diffBody(Map p) {
    if (p['ok'] != true) {
      return _empty(_s(p, 'message').isEmpty ? 'Order not found' : _s(p, 'message'), '');
    }
    final lines = (p['lines'] as List?) ?? const [];
    final summary = (p['summary'] as Map?) ?? const {};
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        if (_s(p, 'order_code').isNotEmpty)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x8),
            child: Text(_s(p, 'order_code'), style: Ds.t.caption),
          ),
        if (_s(summary, 'removed_label').isNotEmpty)
          _banner(_s(summary, 'removed_label'), Ds.c.dangerSoft, Ds.c.danger),
        if (_s(summary, 'changes_label').isNotEmpty)
          _banner(_s(summary, 'changes_label'), Ds.c.warningSoft, Ds.c.warning),
        SizedBox(height: Ds.space.x8),
        ...lines.map((e) => _diffCard(e as Map)),
        SizedBox(height: Ds.space.x16),
        // Standing order toggle — repeat this whole order automatically.
        _repeatToggle(_s(p, 'repeat_label'), _s(p, 'repeat_note')),
        SizedBox(height: Ds.space.x12),
        _primaryButton(
          '${_s(p, 'cta_label')}  (${summary['available'] ?? 0})',
          enabled: (summary['available'] ?? 0) != 0,
          onTap: () => _run(
            () => _sb.rpc('reorder_apply_diff',
                params: {'p_order_id': widget.orderId}),
            okFallback: 'Added',
          ),
        ),
      ],
    );
  }

  Widget _diffCard(Map it) {
    final tone = _s(it, 'price_tone');
    final swap = it['swap'] as Map?;
    final canAdd = it['can_add'] == true;
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(_s(it, 'name'),
                    style: Ds.t.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ),
              SizedBox(width: Ds.space.x8),
              _pill(_s(it, 'status_label'),
                  canAdd ? Ds.c.successSoft : Ds.c.dangerSoft,
                  canAdd ? Ds.c.success : Ds.c.danger),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Row(children: [
            _pill('× ${it['last_qty'] ?? ''}', Ds.c.bg, Ds.c.textSecondary),
            SizedBox(width: Ds.space.x8),
            if (_s(it, 'last_price_display').isNotEmpty)
              Text(_s(it, 'last_price_display'),
                  style: Ds.t.caption.copyWith(
                      decoration: _s(it, 'price_delta_label').isNotEmpty &&
                              tone != 'neutral'
                          ? TextDecoration.lineThrough
                          : null)),
            const Spacer(),
            if (_s(it, 'price_delta_label').isNotEmpty)
              Text(_s(it, 'price_delta_label'),
                  style: Ds.t.caption.copyWith(color: _tone(tone))),
          ]),
          if (swap != null) ...[
            SizedBox(height: Ds.space.x8),
            Container(
              padding: EdgeInsets.all(Ds.space.x8),
              decoration: BoxDecoration(
                  color: Ds.c.infoSoft, borderRadius: Ds.r.rChip),
              child: Row(children: [
                Icon(Icons.swap_horiz, size: 16, color: Ds.c.info),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_s(swap, 'name'),
                          style: Ds.t.caption.copyWith(color: Ds.c.text),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      Text(_s(swap, 'reason'), style: Ds.t.caption),
                    ],
                  ),
                ),
                if (_s(swap, 'price_display').isNotEmpty)
                  Text(_s(swap, 'price_display'), style: Ds.t.caption),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  bool _repeatOn = false;
  Widget _repeatToggle(String label, String note) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        activeColor: Ds.c.brand,
        title: Text(label, style: Ds.t.body),
        subtitle: Text(note, style: Ds.t.caption),
        value: _repeatOn,
        onChanged: _busy
            ? null
            : (v) {
                _repeatOn = v;
                setState(() {});
                _run(
                  () => _sb.rpc('reorder_subscription_set', params: {
                    'p_order_id': widget.orderId,
                    'p_cadence_days': 30,
                    'p_enabled': v,
                  }),
                  okFallback: v ? 'Auto-reorder on' : 'Auto-reorder off',
                );
              },
      ),
    );
  }

  // ─── Auto-reorders (subscriptions) sheet ────────────────────────────────────
  Widget _subsLink(String label) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x16),
        child: InkWell(
          borderRadius: Ds.r.rCard,
          onTap: _openSubs,
          child: Container(
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
                color: Ds.c.brandSoft, borderRadius: Ds.r.rCard),
            child: Row(children: [
              Icon(Icons.autorenew, color: Ds.c.brand, size: 20),
              SizedBox(width: Ds.space.x12),
              Expanded(
                  child: Text(label,
                      style: Ds.t.body.copyWith(color: Ds.c.brandDark))),
              Icon(Icons.chevron_right, color: Ds.c.brand),
            ]),
          ),
        ),
      );

  Future<void> _openSubs() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: Ds.c.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _SubsSheet(sb: _sb),
    );
  }

  // ─── Shared bits ────────────────────────────────────────────────────────────
  Widget _sectionHeader(String text, {String? badge}) => Row(
        children: [
          Text(text, style: Ds.t.title),
          if (badge != null && badge != '0') ...[
            SizedBox(width: Ds.space.x8),
            _pill(badge, Ds.c.warningSoft, Ds.c.warning),
          ],
        ],
      );

  Widget _empty(String title, String note) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.22),
          Icon(Icons.refresh, size: 56, color: Ds.c.textSecondary),
          SizedBox(height: Ds.space.x12),
          Center(child: Text(title, style: Ds.t.subtitle)),
          if (note.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x32),
              child: Text(note,
                  textAlign: TextAlign.center, style: Ds.t.caption),
            ),
          ],
        ],
      );

  Widget _banner(String text, Color bg, Color fg) => Container(
        width: double.infinity,
        margin: EdgeInsets.only(bottom: Ds.space.x8),
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
        child: Text(text, style: Ds.t.caption.copyWith(color: fg)),
      );

  Widget _pill(String text, Color bg, Color fg) => Container(
        padding:
            EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
        decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
        child: Text(text,
            style: Ds.t.caption.copyWith(color: fg, fontWeight: FontWeight.w500)),
      );

  Widget _thumb(String url) => ClipRRect(
        borderRadius: Ds.r.rChip,
        child: url.isEmpty
            ? Container(
                width: 48,
                height: 48,
                color: Ds.c.bg,
                child: Icon(Icons.medication_outlined,
                    color: Ds.c.textSecondary, size: 22))
            : Image.network(url,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                    width: 48,
                    height: 48,
                    color: Ds.c.bg,
                    child: Icon(Icons.medication_outlined,
                        color: Ds.c.textSecondary, size: 22))),
      );

  Widget _primaryButton(String label,
          {required VoidCallback onTap, bool enabled = true}) =>
      SizedBox(
        width: double.infinity,
        height: 48,
        child: ElevatedButton(
          onPressed: (_busy || !enabled) ? null : onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: Ds.c.brand,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          ),
          child: Text(label,
              style: Ds.t.body.copyWith(
                  color: Colors.white, fontWeight: FontWeight.w600)),
        ),
      );

  Widget _smallAddButton(String label, VoidCallback onTap) => SizedBox(
        height: 36,
        child: OutlinedButton(
          onPressed: _busy ? null : onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: Ds.c.brand,
            side: BorderSide(color: Ds.c.brand),
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
          ),
          child: Text(label,
              style: Ds.t.body.copyWith(
                  color: Ds.c.brand, fontWeight: FontWeight.w600)),
        ),
      );
}

/// The auto-reorders management sheet: one RPC, render verbatim, pause/resume/
/// cancel each row. reorder_subscription_update returns the fresh list.
class _SubsSheet extends StatefulWidget {
  final SupabaseClient sb;
  const _SubsSheet({required this.sb});
  @override
  State<_SubsSheet> createState() => _SubsSheetState();
}

class _SubsSheetState extends State<_SubsSheet> {
  Map<String, dynamic>? _p;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await widget.sb.rpc('reorder_subscription_list');
      _p = (res is Map) ? Map<String, dynamic>.from(res) : {};
    } catch (_) {
      _p = {'ok': false};
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _act(String id, String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await widget.sb.rpc('reorder_subscription_update',
          params: {'p_id': id, 'p_action': action});
      if (res is Map) _p = Map<String, dynamic>.from(res);
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  String _s(Map m, String k) => (m[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final p = _p ?? const {};
    final items = (p['items'] as List?) ?? const [];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s(p, 'title').isEmpty ? 'Auto-reorders' : _s(p, 'title'),
                style: Ds.t.title),
            SizedBox(height: Ds.space.x12),
            if (_loading)
              Padding(
                padding: EdgeInsets.all(Ds.space.x24),
                child: const Center(child: CircularProgressIndicator()),
              )
            else if (items.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: Ds.space.x24),
                child: Column(children: [
                  Text(_s(p, 'empty_title'), style: Ds.t.subtitle),
                  SizedBox(height: Ds.space.x4),
                  Text(_s(p, 'empty_note'),
                      textAlign: TextAlign.center, style: Ds.t.caption),
                ]),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: items.length,
                  separatorBuilder: (_, __) => SizedBox(height: Ds.space.x8),
                  itemBuilder: (_, i) => _subRow(items[i] as Map),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _subRow(Map s) {
    Color tone;
    switch (_s(s, 'status_tone')) {
      case 'success':
        tone = Ds.c.success;
        break;
      case 'warning':
        tone = Ds.c.warning;
        break;
      default:
        tone = Ds.c.textSecondary;
    }
    return Container(
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
          color: Ds.c.bg, borderRadius: Ds.r.rCard),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(_s(s, 'cadence_label'), style: Ds.t.body)),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8, vertical: Ds.space.x4),
              decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.12),
                  borderRadius: Ds.r.rChip),
              child: Text(_s(s, 'status_label'),
                  style: Ds.t.caption.copyWith(color: tone)),
            ),
          ]),
          SizedBox(height: Ds.space.x4),
          Text('${_s(s, 'items_label')}   ${_s(s, 'next_run_label')}',
              style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          Row(children: [
            if (s['can_pause'] == true)
              _act3(_s(s, 'pause_label'),
                  () => _act(_s(s, 'id'), 'pause'), Ds.c.warning),
            if (s['can_resume'] == true)
              _act3(_s(s, 'resume_label'),
                  () => _act(_s(s, 'id'), 'resume'), Ds.c.success),
            if (s['can_cancel'] == true)
              _act3(_s(s, 'cancel_label'),
                  () => _act(_s(s, 'id'), 'cancel'), Ds.c.danger),
          ]),
        ],
      ),
    );
  }

  Widget _act3(String label, VoidCallback onTap, Color c) => Padding(
        padding: EdgeInsets.only(right: Ds.space.x8),
        child: OutlinedButton(
          onPressed: _busy ? null : onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: c,
            side: BorderSide(color: c.withValues(alpha: 0.5)),
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
            minimumSize: Size(0, 40),
          ),
          child: Text(label, style: Ds.t.caption.copyWith(color: c)),
        ),
      );
}

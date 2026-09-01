// CMD #430 — Stock audit: count blind, see what is missing, seal the record.
//
// Three surfaces, one payload each:
//   * HOME — start a count (whole shop / one rack / today's ten), the count in
//     progress, the sealed-record state and the shrinkage trend.
//   * SHEET — the counting screen. It cannot show an expected quantity because
//     the backend does not send one while the session is open; `has_expected`
//     is the payload's own word for that, not a client-side guess.
//   * VARIANCE — counted against expected, the second count, and what to do
//     next. Every rupee, every "3 sold while you were counting", every tone and
//     every refusal sentence arrives finished.
//
// The one rule worth stating twice: this screen never decides who may confirm a
// count. It sends the tap and prints what the database answers, including
// "A different person has to count these."
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/pharmacy_audit_api.dart';
import '../../services/pharmacy_shield_api.dart' show ShieldRpc;
import '../../utils/render_log.dart';
import 'pharmacy_reorder_screen.dart';
import 'pharmacy_variance_screen.dart'
    show ShieldCard, ShieldChip, ShieldRefusal, ShieldSkeleton, PharmacyVarianceScreen;
import 'px_screen.dart';

String _s(Object? v) => v == null ? '' : v.toString();
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

class PharmacyAuditScreen extends StatefulWidget {
  final ShieldRpc? rpc;
  const PharmacyAuditScreen({super.key, this.rpc});

  @override
  State<PharmacyAuditScreen> createState() => _PharmacyAuditScreenState();
}

class _PharmacyAuditScreenState extends State<PharmacyAuditScreen> {
  Map<String, dynamic>? _home;
  String? _refusal;
  bool _failed = false;
  bool _busy = false;
  final _scope = TextEditingController();

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PharmacyAuditApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    setState(() {
      _failed = false;
      _refusal = null;
    });
    try {
      final r = await _call('pharmacy_audit_home', const {});
      if (!mounted) return;
      if (r['ok'] != true) {
        setState(() => _refusal = _s(r['message']));
        return;
      }
      setState(() => _home = r);
      RenderLog.write('c430_audit_home', 1);
      RenderLog.write('c430_audit_cycle', _rows(_m(r['cycle'])['rows']).length);
      RenderLog.write('c430_audit_recent', _rows(r['recent']).length);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _start(Map<String, dynamic> kind) async {
    if (_busy) return;
    setState(() => _busy = true);
    Map<String, dynamic> r;
    try {
      r = await _call('pharmacy_audit_start', {
        'p_kind': _s(kind['key']),
        'p_scope_kind': _s(kind['scope']),
        if (kind['needs_value'] == true && _scope.text.trim().isNotEmpty)
          'p_scope_value': _scope.text.trim(),
      });
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['ok'] != true) {
      _toast(_s(r['message']));
      return;
    }
    await _openSheet(_s(r['session_id']));
  }

  Future<void> _openSheet(String sessionId) async {
    if (sessionId.isEmpty) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            PharmacyCountSheetScreen(sessionId: sessionId, rpc: widget.rpc),
      ),
    );
    if (mounted) _boot();
  }

  Future<void> _openVariance(String sessionId) async {
    if (sessionId.isEmpty) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            PharmacyAuditVarianceScreen(sessionId: sessionId, rpc: widget.rpc),
      ),
    );
    if (mounted) _boot();
  }

  @override
  Widget build(BuildContext context) {
    final h = _home;
    if (_refusal != null) return ShieldRefusal(message: _refusal!);
    if (_failed) {
      return ShieldRefusal(message: '', retryLabel: 'Retry', onRetry: _boot);
    }
    if (h == null) return const ShieldSkeleton();

    final open = _m(h['open']);
    final cycle = _m(h['cycle']);
    final seal = _m(h['seal']);
    final trend = _m(h['trend']);
    final kinds = _rows(h['kinds']);
    final needsValue = kinds.any((k) => k['needs_value'] == true);

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        title: Text(_s(h['title']), style: Ds.t.subtitle),
      ),
      body: RefreshIndicator(
        onRefresh: _boot,
        child: ListView(
          padding: EdgeInsets.all(Ds.space.x16),
          children: [
            if (open.isNotEmpty) ...[
              ShieldCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(open['title']), style: Ds.t.title),
                    SizedBox(height: Ds.space.x4),
                    Text(_s(open['label']), style: Ds.t.caption),
                    SizedBox(height: Ds.space.x8),
                    Text(_s(open['progress_label']), style: Ds.t.body),
                    SizedBox(height: Ds.space.x16),
                    SizedBox(
                      height: Ds.touch.minTarget,
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Ds.c.brand,
                          shape: RoundedRectangleBorder(
                            borderRadius: Ds.r.rButton,
                          ),
                        ),
                        onPressed: _busy
                            ? null
                            : () => _s(open['status']) == 'open'
                                  ? _openSheet(_s(open['session_id']))
                                  : _openVariance(_s(open['session_id'])),
                        child: Text(_s(open['title'])),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: Ds.space.x24),
            ],

            ShieldCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(h['start_title']), style: Ds.t.bodyStrong),
                  SizedBox(height: Ds.space.x8),
                  Text(_s(h['start_note']), style: Ds.t.caption),
                  if (needsValue) ...[
                    SizedBox(height: Ds.space.x16),
                    TextField(
                      controller: _scope,
                      decoration: InputDecoration(
                        hintText: _s(h['scope_hint']),
                        filled: true,
                        fillColor: Ds.c.bg,
                        border: OutlineInputBorder(
                          borderRadius: Ds.r.rButton,
                        ),
                      ),
                    ),
                  ],
                  SizedBox(height: Ds.space.x16),
                  Wrap(
                    spacing: Ds.space.x8,
                    runSpacing: Ds.space.x8,
                    children: [
                      for (final k in kinds)
                        SizedBox(
                          height: Ds.touch.minTarget,
                          child: OutlinedButton(
                            onPressed: _busy ? null : () => _start(k),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Ds.c.brand,
                              side: BorderSide(color: Ds.c.divider),
                              shape: RoundedRectangleBorder(
                                borderRadius: Ds.r.rButton,
                              ),
                            ),
                            child: Text(_s(k['label']), style: Ds.t.body),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),

            SizedBox(height: Ds.space.x24),
            Text(_s(cycle['title']), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x4),
            Text(_s(cycle['note']), style: Ds.t.caption),
            SizedBox(height: Ds.space.x12),
            if (_rows(cycle['rows']).isEmpty)
              ShieldCard(
                child: Text(_s(cycle['empty']), style: Ds.t.bodySecondary),
              )
            else
              for (final row in _rows(cycle['rows'])) ...[
                ShieldCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _s(row['product_name']),
                              style: Ds.t.bodyStrong,
                            ),
                            SizedBox(height: Ds.space.x4),
                            Text(
                              '${_s(row['batch_label'])} · ${_s(row['reason'])}',
                              style: Ds.t.caption,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: Ds.space.x12),
                      Text(_s(row['value_display']), style: Ds.t.bodyStrong),
                    ],
                  ),
                ),
                SizedBox(height: Ds.space.x8),
              ],

            SizedBox(height: Ds.space.x24),
            ShieldCard(
              child: Row(
                children: [
                  Expanded(
                    child: Text(_s(seal['title']), style: Ds.t.bodyStrong),
                  ),
                  ShieldChip(
                    label: _s(seal['label']),
                    tone: _s(seal['tone']),
                  ),
                ],
              ),
            ),

            if (_rows(trend['rows']).isNotEmpty) ...[
              SizedBox(height: Ds.space.x24),
              Text(_s(trend['title']), style: Ds.t.bodyStrong),
              SizedBox(height: Ds.space.x12),
              ShieldCard(
                child: Column(
                  children: [
                    for (final row in _rows(trend['rows']))
                      Padding(
                        padding: EdgeInsets.only(bottom: Ds.space.x8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _s(row['category']),
                                style: Ds.t.bodySecondary,
                              ),
                            ),
                            Text(
                              _s(row['value_display']),
                              style: Ds.t.bodyStrong,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],

            if (_rows(_home!['recent']).isNotEmpty) ...[
              SizedBox(height: Ds.space.x24),
              for (final r in _rows(_home!['recent'])) ...[
                InkWell(
                  borderRadius: Ds.r.rCard,
                  onTap: () => _openVariance(_s(r['session_id'])),
                  child: ShieldCard(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_s(r['label']), style: Ds.t.bodyStrong),
                              SizedBox(height: Ds.space.x4),
                              Text(
                                '${_s(r['date_label'])} · ${_s(r['lines_label'])}',
                                style: Ds.t.caption,
                              ),
                            ],
                          ),
                        ),
                        Text(_s(r['value_display']), style: Ds.t.bodyStrong),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: Ds.space.x8),
              ],
            ],
            SizedBox(height: Ds.space.x32),
          ],
        ),
      ),
    );
  }
}

/// The counting screen. It shows what is on the shelf list and what has been
/// counted — and it has no way to show an expected number, because the payload
/// does not contain one while the session is open.
class PharmacyCountSheetScreen extends StatefulWidget {
  final String sessionId;
  final ShieldRpc? rpc;
  const PharmacyCountSheetScreen({
    super.key,
    required this.sessionId,
    this.rpc,
  });

  @override
  State<PharmacyCountSheetScreen> createState() =>
      _PharmacyCountSheetScreenState();
}

class _PharmacyCountSheetScreenState extends State<PharmacyCountSheetScreen> {
  Map<String, dynamic>? _sheet;
  String? _refusal;
  bool _busy = false;
  String _method = 'type';

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PharmacyAuditApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _call('pharmacy_audit_sheet', {
        'p_session_id': widget.sessionId,
      });
      if (!mounted) return;
      if (r['ok'] != true) {
        setState(() => _refusal = _s(r['message']));
        return;
      }
      setState(() => _sheet = r);
      RenderLog.write('c430_audit_sheet', _rows(r['rows']).length);
    } catch (_) {
      if (mounted) setState(() => _refusal = '');
    }
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// The counted number, and — while the strip is in their hand — the expiry
  /// printed on it. Both go to the backend; neither is interpreted here.
  Future<void> _countLine(Map<String, dynamic> row) async {
    final qtyCtl = TextEditingController();
    final expCtl = TextEditingController();
    final sheet = _m(_sheet);
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x24,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + Ds.space.x24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s(row['product_name']), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x4),
            Text(
              '${_s(row['batch_label'])} · ${_s(row['expiry_label'])}',
              style: Ds.t.caption,
            ),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: qtyCtl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                hintText: _s(sheet['search_hint']),
                filled: true,
                fillColor: Ds.c.bg,
                border: OutlineInputBorder(borderRadius: Ds.r.rButton),
              ),
            ),
            if (row['has_expiry'] != true) ...[
              SizedBox(height: Ds.space.x12),
              TextField(
                controller: expCtl,
                decoration: InputDecoration(
                  hintText: _s(row['expiry_prompt']),
                  filled: true,
                  fillColor: Ds.c.bg,
                  border: OutlineInputBorder(borderRadius: Ds.r.rButton),
                ),
              ),
            ],
            SizedBox(height: Ds.space.x24),
            SizedBox(
              height: Ds.touch.minTarget,
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: () => Navigator.pop(sheetContext, true),
                child: Text(_s(sheet['submit_label'])),
              ),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final qty = num.tryParse(qtyCtl.text.trim());
    if (qty == null) return;

    setState(() => _busy = true);
    Map<String, dynamic> r;
    try {
      r = await _call('pharmacy_audit_count', {
        'p_session_id': widget.sessionId,
        'p_lines': [
          {
            'line_id': _s(row['line_id']),
            'qty': qty,
            'method': _method,
            if (expCtl.text.trim().isNotEmpty) 'expiry': expCtl.text.trim(),
          },
        ],
      });
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(_s(r['message']));
    await _load();
  }

  Future<void> _close() async {
    setState(() => _busy = true);
    Map<String, dynamic> r;
    try {
      r = await _call('pharmacy_audit_close', {
        'p_session_id': widget.sessionId,
      });
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['ok'] != true) {
      _toast(_s(r['message']));
      return;
    }
    await Navigator.pushReplacement(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PharmacyAuditVarianceScreen(
          sessionId: widget.sessionId,
          rpc: widget.rpc,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = _sheet;
    if (_refusal != null) return ShieldRefusal(message: _refusal!);
    if (h == null) return const ShieldSkeleton();
    final rows = _rows(h['rows']);

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        title: Text(_s(h['title']), style: Ds.t.subtitle),
      ),
      body: ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          ShieldCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_s(h['progress_label']), style: Ds.t.title),
                if (_s(h['blind_note']).isNotEmpty) ...[
                  SizedBox(height: Ds.space.x8),
                  Text(_s(h['blind_note']), style: Ds.t.caption),
                ],
                SizedBox(height: Ds.space.x16),
                Wrap(
                  spacing: Ds.space.x8,
                  runSpacing: Ds.space.x8,
                  children: [
                    for (final m in _rows(h['methods']))
                      ChoiceChip(
                        label: Text(_s(m['label']), style: Ds.t.caption),
                        selected: _method == _s(m['key']),
                        onSelected: (_) =>
                            setState(() => _method = _s(m['key'])),
                      ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(height: Ds.space.x16),
          if (rows.isEmpty)
            ShieldCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(h['empty']), style: Ds.t.bodyStrong),
                  SizedBox(height: Ds.space.x4),
                  Text(_s(h['empty_hint']), style: Ds.t.caption),
                ],
              ),
            )
          else
            for (final row in rows) ...[
              InkWell(
                borderRadius: Ds.r.rCard,
                onTap: _busy ? null : () => _countLine(row),
                child: ShieldCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _s(row['product_name']),
                              style: Ds.t.bodyStrong,
                            ),
                            SizedBox(height: Ds.space.x4),
                            Text(
                              '${_s(row['batch_label'])} · ${_s(row['expiry_label'])}',
                              style: Ds.t.caption,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: Ds.space.x12),
                      ShieldChip(
                        label: _s(row['counted_label']),
                        tone: row['counted'] == true ? 'success' : 'neutral',
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: Ds.space.x8),
            ],
          SizedBox(height: Ds.space.x24),
          SizedBox(
            height: Ds.touch.minTarget,
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              onPressed: _busy ? null : _close,
              child: Text(_s(h['submit_label'])),
            ),
          ),
          SizedBox(height: Ds.space.x32),
        ],
      ),
    );
  }
}

/// Counted against expected, the second count, and what to chase next.
class PharmacyAuditVarianceScreen extends StatefulWidget {
  final String sessionId;
  final ShieldRpc? rpc;
  const PharmacyAuditVarianceScreen({
    super.key,
    required this.sessionId,
    this.rpc,
  });

  @override
  State<PharmacyAuditVarianceScreen> createState() =>
      _PharmacyAuditVarianceScreenState();
}

class _PharmacyAuditVarianceScreenState
    extends State<PharmacyAuditVarianceScreen> {
  Map<String, dynamic>? _v;
  Map<String, dynamic> _actions = const {};
  Map<String, dynamic> _recount = const {};
  String? _refusal;
  bool _busy = false;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PharmacyAuditApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await _call('pharmacy_audit_variance', {
        'p_session_id': widget.sessionId,
      });
      if (!mounted) return;
      if (v['ok'] != true) {
        setState(() => _refusal = _s(v['message']));
        return;
      }
      final a = await _call('pharmacy_audit_actions', {
        'p_session_id': widget.sessionId,
      });
      final rc = await _call('pharmacy_audit_recount_sheet', {
        'p_session_id': widget.sessionId,
      });
      if (!mounted) return;
      setState(() {
        _v = v;
        _actions = a;
        _recount = rc;
      });
      RenderLog.write('c430_audit_variance', _rows(v['rows']).length);
    } catch (_) {
      if (mounted) setState(() => _refusal = '');
    }
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _recountOne(Map<String, dynamic> row) async {
    final ctl = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x24,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + Ds.space.x24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s(row['product_name']), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x4),
            Text(_s(row['batch_label']), style: Ds.t.caption),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: ctl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                filled: true,
                fillColor: Ds.c.bg,
                border: OutlineInputBorder(borderRadius: Ds.r.rButton),
              ),
            ),
            SizedBox(height: Ds.space.x24),
            SizedBox(
              height: Ds.touch.minTarget,
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: () => Navigator.pop(sheetContext, true),
                child: Text(_s(_m(_recount)['title'])),
              ),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final qty = num.tryParse(ctl.text.trim());
    if (qty == null) return;
    setState(() => _busy = true);
    Map<String, dynamic> r;
    try {
      r = await _call('pharmacy_audit_recount', {
        'p_round_id': _s(row['round_id']),
        'p_qty': qty,
        'p_method': 'type',
      });
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(_s(r['message']));
    await _load();
  }

  Future<void> _accept() async {
    setState(() => _busy = true);
    Map<String, dynamic> r;
    try {
      r = await _call('pharmacy_audit_accept', {
        'p_session_id': widget.sessionId,
      });
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(_s(r['message']));
    if (r['ok'] == true) await _load();
  }

  void _openAction(String routeKey) {
    // A route_key this build has never heard of resolves to nothing, so a
    // backend that learns a new action later cannot crash an old app.
    switch (routeKey) {
      case 'pharmacy_stock_check':
        Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => const PharmacyVarianceScreen()),
        );
        break;
      case 'pharmacy_px':
        Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => const PxScreen()),
        );
        break;
      case 'pharmacy_reorder':
        Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => const PharmacyReorderScreen()),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    if (_refusal != null) return ShieldRefusal(message: _refusal!);
    if (v == null) return const ShieldSkeleton();
    final rows = _rows(v['rows']);
    final recountRows = _rows(_m(_recount)['rows']);
    final actionRows = _rows(_m(_actions)['rows']);

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        title: Text(_s(v['title']), style: Ds.t.subtitle),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.all(Ds.space.x16),
          children: [
            ShieldCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(v['value_display']), style: Ds.t.title),
                  SizedBox(height: Ds.space.x4),
                  Text(_s(v['value_label']), style: Ds.t.caption),
                  SizedBox(height: Ds.space.x8),
                  Text(_s(v['note']), style: Ds.t.caption),
                ],
              ),
            ),

            if (recountRows.isNotEmpty) ...[
              SizedBox(height: Ds.space.x24),
              Text(_s(_m(_recount)['title']), style: Ds.t.bodyStrong),
              SizedBox(height: Ds.space.x4),
              Text(_s(_m(_recount)['note']), style: Ds.t.caption),
              SizedBox(height: Ds.space.x12),
              for (final row in recountRows) ...[
                ShieldCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _s(row['product_name']),
                              style: Ds.t.bodyStrong,
                            ),
                            SizedBox(height: Ds.space.x4),
                            Text(_s(row['batch_label']), style: Ds.t.caption),
                            if (_s(row['blocked_message']).isNotEmpty) ...[
                              SizedBox(height: Ds.space.x4),
                              Text(
                                _s(row['blocked_message']),
                                style: Ds.t.caption,
                              ),
                            ],
                          ],
                        ),
                      ),
                      SizedBox(
                        height: Ds.touch.minTarget,
                        child: TextButton(
                          onPressed: _busy || row['blocked_for_me'] == true
                              ? null
                              : () => _recountOne(row),
                          style: TextButton.styleFrom(
                            foregroundColor: Ds.c.brand,
                          ),
                          child: Text(
                            _s(_m(_recount)['title']),
                            style: Ds.t.body,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: Ds.space.x8),
              ],
            ],

            SizedBox(height: Ds.space.x24),
            for (final row in rows) ...[
              ShieldCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _s(row['product_name']),
                            style: Ds.t.bodyStrong,
                          ),
                        ),
                        Text(
                          _s(row['value_display']),
                          style: Ds.t.bodyStrong,
                        ),
                      ],
                    ),
                    SizedBox(height: Ds.space.x4),
                    Text(
                      '${_s(row['batch_label'])} · ${_s(row['counts_label'])}',
                      style: Ds.t.caption,
                    ),
                    if (_s(row['sold_note']).isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(_s(row['sold_note']), style: Ds.t.caption),
                    ],
                    SizedBox(height: Ds.space.x8),
                    Row(
                      children: [
                        ShieldChip(
                          label: _s(row['variance_label']),
                          tone: _s(row['variance_tone']),
                        ),
                        if (_s(row['second_count']).isNotEmpty) ...[
                          SizedBox(width: Ds.space.x8),
                          Expanded(
                            child: Text(
                              '${_s(row['second_count'])} · ${_s(row['second_by'])}',
                              style: Ds.t.caption,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(height: Ds.space.x8),
            ],

            if (actionRows.isNotEmpty) ...[
              SizedBox(height: Ds.space.x24),
              Text(_s(_m(_actions)['title']), style: Ds.t.bodyStrong),
              SizedBox(height: Ds.space.x12),
              for (final a in actionRows) ...[
                InkWell(
                  borderRadius: Ds.r.rCard,
                  onTap: () => _openAction(_s(a['route_key'])),
                  child: ShieldCard(
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(_s(a['label']), style: Ds.t.body),
                        ),
                        Icon(
                          Icons.chevron_right,
                          size: Ds.t.subtitleSize,
                          color: Ds.c.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: Ds.space.x8),
              ],
            ],

            SizedBox(height: Ds.space.x24),
            if (v['can_accept'] == true)
              SizedBox(
                height: Ds.touch.minTarget,
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Ds.c.brand,
                    shape: RoundedRectangleBorder(
                      borderRadius: Ds.r.rButton,
                    ),
                  ),
                  onPressed: _busy ? null : _accept,
                  child: Text(_s(v['accept_label'])),
                ),
              ),
            SizedBox(height: Ds.space.x32),
          ],
        ),
      ),
    );
  }
}

/// The way in, drawn from `pharmacy_audit_entry()` and nowhere else.
class AuditEntryCard extends StatefulWidget {
  final ShieldRpc? rpc;
  const AuditEntryCard({super.key, this.rpc});

  @override
  State<AuditEntryCard> createState() => _AuditEntryCardState();
}

class _AuditEntryCardState extends State<AuditEntryCard> {
  Map<String, dynamic> _entry = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = widget.rpc != null
          ? await widget.rpc!('pharmacy_audit_entry', const {})
          : await PharmacyAuditApi.entry();
      if (!mounted) return;
      setState(() => _entry = r);
      if (r['show'] == true) RenderLog.write('c430_audit_entry', 1);
    } catch (_) {
      // A dead tile is worse than no tile.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_entry['show'] != true) return const SizedBox.shrink();
    final badge = _s(_entry['badge']);
    return InkWell(
      borderRadius: Ds.r.rCard,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PharmacyAuditScreen(rpc: widget.rpc),
        ),
      ),
      child: ShieldCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(_entry['label']), style: Ds.t.bodyStrong),
                  SizedBox(height: Ds.space.x4),
                  Text(_s(_entry['sub_label']), style: Ds.t.caption),
                ],
              ),
            ),
            if (badge.isNotEmpty) ...[
              SizedBox(width: Ds.space.x12),
              ShieldChip(label: badge, tone: 'info'),
            ],
            SizedBox(width: Ds.space.x8),
            Icon(
              Icons.chevron_right,
              size: Ds.t.subtitleSize,
              color: Ds.c.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// The same entry, as an app-bar icon for the shelf. Label, badge and whether
/// the button exists at all are `pharmacy_audit_entry()`'s call — a shop that
/// is not a pharmacy simply gets no icon, with no role test on this side.
class AuditNavIcon extends StatefulWidget {
  final ShieldRpc? rpc;
  const AuditNavIcon({super.key, this.rpc});

  @override
  State<AuditNavIcon> createState() => _AuditNavIconState();
}

class _AuditNavIconState extends State<AuditNavIcon> {
  Map<String, dynamic> _entry = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = widget.rpc != null
          ? await widget.rpc!('pharmacy_audit_entry', const {})
          : await PharmacyAuditApi.entry();
      if (!mounted) return;
      setState(() => _entry = r);
      if (r['show'] == true) RenderLog.write('c430_audit_nav', 1);
    } catch (_) {
      // no icon is better than a broken one
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_entry['show'] != true) return const SizedBox.shrink();
    final badge = _s(_entry['badge']);
    return IconButton(
      icon: badge.isEmpty
          ? Icon(Icons.fact_check_outlined, color: Ds.c.brand)
          : Badge(
              label: Text(badge),
              backgroundColor: Ds.c.info,
              child: Icon(Icons.fact_check_outlined, color: Ds.c.brand),
            ),
      tooltip: _s(_entry['label']),
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PharmacyAuditScreen(rpc: widget.rpc),
        ),
      ),
    );
  }
}

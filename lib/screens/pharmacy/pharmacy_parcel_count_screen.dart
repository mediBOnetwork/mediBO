// CMD #431 — COUNT A PARCEL.
//
// Two screens, because a parcel count is two moments: choosing the box that
// just arrived, and then standing over it with the bill.
//
//   ParcelCountHomeScreen — the boxes waiting to be counted, in two lists the
//     BACKEND labels: mediBO parcels and other suppliers'.
//   ParcelCountScreen — one parcel. Every line of the bill, what it promised,
//     what the hands found, and the verdict.
//
// This file decides nothing. It does not know that seven against ten is short,
// that a wrong batch outranks a wrong number, that a mediBO mismatch becomes a
// claim while an outside one becomes evidence, or what any of that should be
// called — every verdict, tone, caption, empty state and refusal arrives
// finished on the payload. What Dart owns is the keyboard: which line is being
// counted, and getting the number to the backend fast enough that counting a
// forty-line parcel does not feel like data entry.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_tokens.dart';
import '../../services/pharmacy_parcel_api.dart';
import '../../utils/render_log.dart';
import '../../widgets/image_pick.dart';
import '../admin/feature_gaps_screen.dart' show toneColor, toneSoft;

String _s(Object? v) => v == null ? '' : v.toString();
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

// ── shared chrome ───────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _Card({required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    final body = Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: child,
    );
    if (onTap == null) return body;
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rCard,
      child: body,
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final String tone;
  const _Chip(this.label, this.tone);

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Ds.space.x12,
        vertical: Ds.space.x4,
      ),
      decoration: BoxDecoration(
        color: toneSoft(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(label, style: Ds.t.caption.copyWith(color: toneColor(tone))),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.all(Ds.space.x16),
    children: [
      for (var i = 0; i < 5; i++)
        Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x12),
          child: Container(
            height: Ds.space.x48 + Ds.space.x24,
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: Ds.r.rCard,
            ),
          ),
        ),
    ],
  );
}

/// An error is the backend's sentence plus a way to try again — never a Dart
/// string and never a dead end.
class _Failed extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final String retryLabel;
  const _Failed(this.message, this.onRetry, this.retryLabel);

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: Ds.t.body.copyWith(color: Ds.c.textSecondary),
          ),
          SizedBox(height: Ds.space.x16),
          OutlinedButton(onPressed: onRetry, child: Text(retryLabel)),
        ],
      ),
    ),
  );
}

// ═══════════════════ THE LIST OF PARCELS ═══════════════════════════════════

class ParcelCountHomeScreen extends StatefulWidget {
  const ParcelCountHomeScreen({super.key});

  @override
  State<ParcelCountHomeScreen> createState() => _ParcelCountHomeScreenState();
}

class _ParcelCountHomeScreenState extends State<ParcelCountHomeScreen>
    with SingleTickerProviderStateMixin {
  Map<String, dynamic>? _data;
  String? _error;
  bool _busy = false;
  TabController? _tabs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await PharmacyParcelApi.home();
      if (!mounted) return;
      if (r['ok'] != true) {
        setState(() => _error = _s(r['message']));
        return;
      }
      final tabs = _rows(r['tabs']);
      _tabs?.dispose();
      _tabs = TabController(length: tabs.isEmpty ? 1 : tabs.length, vsync: this);
      setState(() => _data = r);
      RenderLog.write('c431_parcel_home', 1);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _open(String billId) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await PharmacyParcelApi.open(billId);
      if (!mounted) return;
      if (r['ok'] != true) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_s(r['message']))));
        return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ParcelCountScreen(opened: r)),
      );
      if (mounted) _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (_error != null) {
      return Scaffold(
        backgroundColor: Ds.c.bg,
        appBar: AppBar(title: const Text('')),
        body: _Failed(_error!, _load, MaterialLocalizations.of(context)
            .refreshIndicatorSemanticLabel),
      );
    }
    if (d == null) {
      return Scaffold(
        backgroundColor: Ds.c.bg,
        appBar: AppBar(),
        body: const _Skeleton(),
      );
    }

    final tabs = _rows(d['tabs']);
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s(d['title'])),
        bottom: TabBar(
          controller: _tabs,
          tabs: [for (final t in tabs) Tab(text: _s(t['label']))],
        ),
      ),
      body: Column(
        children: [
          if (_s(d['open_label']).isNotEmpty)
            Container(
              width: double.infinity,
              color: toneSoft('warning'),
              padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x16,
                vertical: Ds.space.x12,
              ),
              child: Text(
                _s(d['open_label']),
                style: Ds.t.caption.copyWith(color: toneColor('warning')),
              ),
            ),
          // Where the mediBO half lives now, in the backend's own words —
          // said out loud so nobody hunts this screen for an order's parcel.
          if (_s(d['medibo_hint']).isNotEmpty)
            Container(
              width: double.infinity,
              color: toneSoft('info'),
              padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x16,
                vertical: Ds.space.x12,
              ),
              child: Text(
                _s(d['medibo_hint']),
                style: Ds.t.caption.copyWith(color: toneColor('info')),
              ),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                for (final t in tabs) _list(t, _s(d['outside_hint'])),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(Map<String, dynamic> tab, String outsideHint) {
    final rows = _rows(tab['rows']);
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Text(
            _s(tab['empty']),
            textAlign: TextAlign.center,
            style: Ds.t.body.copyWith(color: Ds.c.textSecondary),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: EdgeInsets.all(Ds.space.x16),
        itemCount: rows.length + (_s(tab['key']) == 'outside' ? 1 : 0),
        separatorBuilder: (_, _) => SizedBox(height: Ds.space.x12),
        itemBuilder: (_, i) {
          if (i >= rows.length) {
            return Padding(
              padding: EdgeInsets.only(top: Ds.space.x12),
              child: Text(
                outsideHint,
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
              ),
            );
          }
          final r = rows[i];
          return _Card(
            onTap: _busy ? null : () => _open(_s(r['bill_id'])),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_s(r['title']), style: Ds.t.subtitle),
                      SizedBox(height: Ds.space.x4),
                      Text(
                        _s(r['subtitle']),
                        style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                      ),
                      SizedBox(height: Ds.space.x4),
                      Text(
                        _s(r['date_label']),
                        style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: Ds.space.x12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _Chip(_s(r['status_label']), _s(r['status_tone'])),
                    SizedBox(height: Ds.space.x8),
                    Text(
                      _s(r['cta']),
                      style: Ds.t.body.copyWith(color: Ds.c.brand),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ═══════════════════ ONE PARCEL ════════════════════════════════════════════

class ParcelCountScreen extends StatefulWidget {
  /// The payload `pharmacy_parcel_open` already returned, so the counter does
  /// not wait for a second round trip to see the first line.
  final Map<String, dynamic> opened;
  const ParcelCountScreen({super.key, required this.opened});

  @override
  State<ParcelCountScreen> createState() => _ParcelCountScreenState();
}

class _ParcelCountScreenState extends State<ParcelCountScreen> {
  late Map<String, dynamic> _data;
  final _find = TextEditingController();
  final _findFocus = FocusNode();
  String _method = 'barcode';
  bool _busy = false;
  String? _pickHint;

  @override
  void initState() {
    super.initState();
    _data = widget.opened;
    RenderLog.write('c431_parcel_count', 1);
  }

  @override
  void dispose() {
    _find.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  String get _sessionId => _s(_data['session_id']);

  /// Every caption on the counting sheet, straight off the payload.
  Map<String, dynamic> get _form => _m(_data['form']);

  Future<void> _reload() async {
    final r = await PharmacyParcelApi.get(_sessionId);
    if (!mounted || r['ok'] != true) return;
    setState(() => _data = r);
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// One token, whichever way it was read. The backend says which line it is.
  Future<void> _lookup(String token) async {
    if (token.trim().isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final r =
          await PharmacyParcelApi.find(_sessionId, token, method: _method);
      if (!mounted) return;
      _find.clear();
      _findFocus.requestFocus();
      if (r['ok'] == true && r['row'] != null) {
        await _countSheet(_m(r['row']));
      } else if (r['ok'] == true) {
        await _pickSheet(_rows(r['rows']), _s(r['pick_label']));
      } else {
        setState(() => _pickHint = _s(r['message']));
        _toast(_s(r['message']));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickSheet(List<Map<String, dynamic>> rows, String title) =>
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: Ds.c.surface,
        shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.all(Ds.space.x16),
                child: Text(title, style: Ds.t.subtitle),
              ),
              for (final r in rows)
                ListTile(
                  title: Text(_s(r['name'])),
                  subtitle: Text(_s(r['expected_label'])),
                  onTap: () {
                    Navigator.pop(ctx);
                    _countSheet(r);
                  },
                ),
            ],
          ),
        ),
      );

  Future<void> _send(String lineId, Map<String, dynamic> patch) async {
    final r = await PharmacyParcelApi.mark(lineId, patch);
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast(_s(r['message']));
      return;
    }
    await _reload();
    final row = _m(r['row']);
    if (row['is_issue'] == true && _s(row['claim_label']).isNotEmpty) {
      _toast(_s(row['claim_label']));
    }
  }

  /// Attach evidence to a line and let the backend decide what that unlocks —
  /// on a mediBO parcel the claim is raised the moment the photo lands.
  Future<void> _attachPhoto(Map<String, dynamic> row) async {
    final picked = await pickImageBytes();
    if (picked == null || !mounted) return;
    final bucket = _s(_data['photo_bucket']);
    final path =
        'parcel/$_sessionId/${_s(row['line_id'])}-${DateTime.now().millisecondsSinceEpoch}.jpg';
    final stored =
        await PharmacyParcelApi.uploadPhoto(bucket, path, picked.bytes);
    if (!mounted || stored == null) return;
    await _send(_s(row['line_id']), {'photo_path': stored});
  }

  Future<void> _countSheet(Map<String, dynamic> row) async {
    final qty = TextEditingController(
      text: row['counted_qty'] == null ? '' : _s(row['counted_qty']),
    );
    final batch = TextEditingController(text: _s(row['counted_batch']));
    final expiry = TextEditingController(text: _s(row['counted_expiry']));
    final damaged = TextEditingController(
      text: _s(row['damaged_qty']) == '0' ? '' : _s(row['damaged_qty']),
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s(row['name']), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x4),
            Text(
              _s(row['expected_label']),
              style: Ds.t.body.copyWith(color: Ds.c.textSecondary),
            ),
            Text(
              _s(row['batch_label']),
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
            ),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: qty,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(labelText: _s(_form['qty'])),
              onSubmitted: (_) => Navigator.pop(ctx),
            ),
            SizedBox(height: Ds.space.x12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: batch,
                    decoration:
                        InputDecoration(labelText: _s(_form['batch'])),
                  ),
                ),
                SizedBox(width: Ds.space.x12),
                Expanded(
                  child: TextField(
                    controller: expiry,
                    decoration:
                        InputDecoration(labelText: _s(_form['expiry'])),
                  ),
                ),
              ],
            ),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: damaged,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(labelText: _s(_form['damaged'])),
            ),
            SizedBox(height: Ds.space.x24),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(_s(_form['save'])),
              ),
            ),
          ],
        ),
      ),
    );

    final patch = <String, dynamic>{'method': _method};
    if (qty.text.trim().isNotEmpty) patch['counted_qty'] = qty.text.trim();
    if (batch.text.trim().isNotEmpty) patch['counted_batch'] = batch.text.trim();
    if (expiry.text.trim().isNotEmpty) {
      patch['counted_expiry'] = expiry.text.trim();
    }
    if (damaged.text.trim().isNotEmpty) {
      patch['damaged_qty'] = damaged.text.trim();
    }
    qty.dispose();
    batch.dispose();
    expiry.dispose();
    damaged.dispose();
    if (patch.length > 1) await _send(_s(row['line_id']), patch);
  }

  Future<void> _finish() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await PharmacyParcelApi.finish(_sessionId);
      if (!mounted) return;
      if (r['ok'] != true) {
        _toast(_s(r['message']));
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_s(r['title'])),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_s(r['message'])),
              if (_s(r['evidence']).isNotEmpty) ...[
                SizedBox(height: Ds.space.x12),
                Text(
                  _s(r['evidence']),
                  style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(_s(_form['close'])),
            ),
          ],
        ),
      );
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final rows = _rows(d['rows']);
    final methods = _rows(d['methods']);

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(d['title']))),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Ds.c.surface,
            padding: EdgeInsets.all(Ds.space.x16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _s(d['subtitle']),
                  style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                ),
                SizedBox(height: Ds.space.x12),
                Row(
                  children: [
                    Expanded(
                      child: Text(_s(d['progress_label']), style: Ds.t.subtitle),
                    ),
                    _Chip(_s(d['match_label']), 'success'),
                    SizedBox(width: Ds.space.x8),
                    _Chip(_s(d['issue_label']), _s(d['issue_tone'])),
                  ],
                ),
                SizedBox(height: Ds.space.x12),
                Row(
                  children: [
                    for (final m in methods)
                      Padding(
                        padding: EdgeInsets.only(right: Ds.space.x8),
                        child: ChoiceChip(
                          label: Text(_s(m['label'])),
                          selected: _method == _s(m['key']),
                          onSelected: (_) =>
                              setState(() => _method = _s(m['key'])),
                        ),
                      ),
                  ],
                ),
                SizedBox(height: Ds.space.x12),
                TextField(
                  controller: _find,
                  focusNode: _findFocus,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: _s(_form['search_hint']),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: () => _lookup(_find.text),
                    ),
                  ),
                  onSubmitted: _lookup,
                ),
                if (_pickHint != null) ...[
                  SizedBox(height: Ds.space.x8),
                  Text(
                    _pickHint!,
                    style: Ds.t.caption.copyWith(color: toneColor('warning')),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Padding(
                      padding: EdgeInsets.all(Ds.space.x24),
                      child: Text(
                        _s(d['empty']),
                        textAlign: TextAlign.center,
                        style: Ds.t.body.copyWith(color: Ds.c.textSecondary),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.all(Ds.space.x16),
                    itemCount: rows.length + 1,
                    separatorBuilder: (_, _) => SizedBox(height: Ds.space.x12),
                    itemBuilder: (_, i) =>
                        i >= rows.length ? _staff(d) : _line(rows[i]),
                  ),
          ),
          if (d['can_finish'] == true)
            SafeArea(
              child: Padding(
                padding: EdgeInsets.all(Ds.space.x16),
                child: SizedBox(
                  width: double.infinity,
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    onPressed: _busy ? null : _finish,
                    child: Text(_s(d['finish_label'])),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _staff(Map<String, dynamic> d) {
    final staff = _rows(d['staff']);
    if (staff.isEmpty) return SizedBox(height: Ds.space.x24);
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _s(d['staff_heading']),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
          ),
          SizedBox(height: Ds.space.x8),
          for (final s in staff)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x4),
              child: Text(_s(s['label']), style: Ds.t.body),
            ),
          SizedBox(height: Ds.space.x8),
          Text(
            _s(d['later_hint']),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _line(Map<String, dynamic> r) => _Card(
    onTap: _busy ? null : () => _countSheet(r),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(_s(r['name']), style: Ds.t.subtitle)),
            SizedBox(width: Ds.space.x8),
            _Chip(_s(r['verdict_label']), _s(r['verdict_tone'])),
          ],
        ),
        SizedBox(height: Ds.space.x4),
        Row(
          children: [
            Expanded(
              child: Text(
                _s(r['expected_label']),
                style: Ds.t.body.copyWith(color: Ds.c.textSecondary),
              ),
            ),
            if (_s(r['counted_label']).isNotEmpty)
              Text(_s(r['counted_label']), style: Ds.t.body),
          ],
        ),
        SizedBox(height: Ds.space.x4),
        Text(
          _s(r['batch_label']),
          style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
        ),
        if (_s(r['by_label']).isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(
            _s(r['by_label']),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
          ),
        ],
        if (_s(r['claim_label']).isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          _Chip(_s(r['claim_label']), 'info'),
        ],
        if (r['needs_photo'] == true) ...[
          SizedBox(height: Ds.space.x12),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : () => _attachPhoto(r),
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(_s(_data['photo_required'])),  // the WHY, from the payload
            ),
          ),
        ],
      ],
    ),
  );
}

/// The way in, drawn from `pharmacy_parcel_entry()` and nowhere else. It sits
/// beside the counter and the shelf in the account screen, and it draws itself
/// only when the backend said to: a supplier, a rider or an admin opening the
/// same screen sees nothing, and the shell still knows nothing about what a
/// pharmacy is.
class ParcelMenuTile extends StatefulWidget {
  /// Called before navigating, so a sheet or a menu can close itself first.
  final VoidCallback? onBeforeOpen;
  const ParcelMenuTile({super.key, this.onBeforeOpen});

  static IconData get icon => Icons.inventory_outlined;

  @override
  State<ParcelMenuTile> createState() => _ParcelMenuTileState();
}

class _ParcelMenuTileState extends State<ParcelMenuTile> {
  Map<String, dynamic>? _e;

  @override
  void initState() {
    super.initState();
    PharmacyParcelApi.entry()
        .then((r) {
          if (mounted && r['show'] == true) setState(() => _e = r);
        })
        // A tile that cannot ask is simply absent — never a broken chip.
        .catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final e = _e;
    if (e == null) return const SizedBox.shrink();
    RenderLog.write('c431_parcel_entry_tile', 1);
    return InkWell(
      onTap: () {
        widget.onBeforeOpen?.call();
        Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => const ParcelCountHomeScreen(),
          ),
        );
      },
      borderRadius: Ds.r.rButton,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x4,
          vertical: Ds.space.x12,
        ),
        child: Row(
          children: [
            Icon(
              ParcelMenuTile.icon,
              size: Ds.t.subtitleSize,
              color: Ds.c.brand,
            ),
            SizedBox(width: Ds.space.x12),
            Expanded(child: Text(_s(e['label']), style: Ds.t.bodyStrong)),
            // The badge is the backend's count of parcels still open, or
            // nothing at all. Dart never pluralises it and never invents a zero.
            if (_s(e['badge']).isNotEmpty) _Chip(_s(e['badge']), 'warning'),
          ],
        ),
      ),
    );
  }
}

/// CMD #431, after Om's steering — the count of a mediBO parcel belongs ON its
/// order, beside Items / Payment / Bill / Track, because a mediBO parcel is not
/// a stray box: it is THIS order, arriving. The standalone screen above keeps
/// only the parcels that have no order behind them.
///
/// Draws nothing at all until `pharmacy_parcel_order_chip` says to — an order
/// that has not been delivered has no parcel in the room yet, and an absent
/// affordance is honest where a greyed-out one is just a puzzle.
class ParcelOrderChip extends StatefulWidget {
  final String orderId;

  /// The card hands its own chip look down, so this widget adds no styling of
  /// its own and the five chips stay one row rather than four plus a stranger.
  final Widget Function(BuildContext, String label, VoidCallback onTap) builder;

  const ParcelOrderChip({
    super.key,
    required this.orderId,
    required this.builder,
  });

  @override
  State<ParcelOrderChip> createState() => _ParcelOrderChipState();
}

class _ParcelOrderChipState extends State<ParcelOrderChip> {
  Map<String, dynamic>? _chip;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  void _ask() {
    PharmacyParcelApi.orderChip(widget.orderId)
        .then((r) {
          if (mounted && r['show'] == true) setState(() => _chip = r);
        })
        .catchError((Object _) {});
  }

  Future<void> _open() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await PharmacyParcelApi.openOrder(widget.orderId);
      if (!mounted) return;
      if (r['ok'] != true) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_s(r['message']))));
        return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => ParcelCountScreen(opened: r)),
      );
      // Coming back, the chip re-asks: "Count" may now read "Counted".
      if (mounted) _ask();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _chip;
    if (c == null) return const SizedBox.shrink();
    RenderLog.write('c431_order_count_chip', 1);
    return widget.builder(context, _s(c['label']), _open);
  }
}

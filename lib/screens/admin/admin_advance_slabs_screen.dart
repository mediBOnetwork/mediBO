import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'feature_gaps_screen.dart' show toneColor, toneSoft;

/// CMD #1932 — the Advance ladder.
///
/// The advance a pharmacy pays is no longer one global percentage: it is a rung
/// picked by how many orders that pharmacy has already PAID IN FULL, per zone,
/// and it is frozen onto the order the moment the order is created.
///
/// This screen decides nothing. Every string it paints — the title, the column
/// headers, each rung's "3rd order onwards", "20%", "On 4 orders", its status
/// chip, the empty state, every toast and every refusal — arrives already
/// worded from `advance_slabs_list()` / `advance_slab_save()` /
/// `advance_slab_toggle()` / `advance_slab_delete()`. Zone scope comes from the
/// header picker through `admin_active_zone()` on the backend, so a partner
/// sees (and may edit) only their own zone and never the all-zones ladder.
class AdminAdvanceSlabsScreen extends StatefulWidget {
  /// Injected for widget tests; production leaves them null and hits Supabase.
  final Future<Map<String, dynamic>> Function()? listRpc;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> patch)?
      saveRpc;
  final Future<Map<String, dynamic>> Function(int id, bool active)? toggleRpc;
  final Future<Map<String, dynamic>> Function(int id)? deleteRpc;

  /// CMD #1933 — "Who can edit": `advance_slabs_access_list()` and
  /// `advance_slabs_access_set(kind, id, can_view, can_write)`. Injected for
  /// the same reason as the four above, and only ever CALLED when the list
  /// payload says `show_access` — the screen never decides who is a super
  /// admin, the backend does.
  final Future<Map<String, dynamic>> Function()? accessListRpc;
  final Future<Map<String, dynamic>> Function(
      String kind, String id, bool canView, bool canWrite)? accessSetRpc;

  const AdminAdvanceSlabsScreen({
    super.key,
    this.listRpc,
    this.saveRpc,
    this.toggleRpc,
    this.deleteRpc,
    this.accessListRpc,
    this.accessSetRpc,
  });

  @override
  State<AdminAdvanceSlabsScreen> createState() =>
      _AdminAdvanceSlabsScreenState();
}

class _AdminAdvanceSlabsScreenState extends State<AdminAdvanceSlabsScreen> {
  Map<String, dynamic> _p = const <String, dynamic>{};
  Map<String, dynamic> _access = const <String, dynamic>{};
  bool _loading = true;
  bool _busy = false;
  bool _accessOpen = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  SupabaseClient get _sb => Supabase.instance.client;

  Future<Map<String, dynamic>> _call(
      String fn, Map<String, dynamic> params) async {
    final res = await _sb.rpc(fn, params: params);
    return res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    Map<String, dynamic> p;
    try {
      p = widget.listRpc != null
          ? await widget.listRpc!()
          : await _call('advance_slabs_list', const <String, dynamic>{});
    } catch (_) {
      p = <String, dynamic>{'ok': false};
    }
    if (!mounted) return;
    setState(() {
      _p = p;
      _loading = false;
    });
    RenderLog.write('advance_slab_rows', _rows.length);
    RenderLog.write('advance_slab_screen', _ok ? 'ok' : 'denied');
    if (_ok && _p['show_access'] == true) await _loadAccess();
  }

  /// The permission matrix, narrowed to this feature. `show_access` is the
  /// backend's verdict that this caller may see it at all.
  Future<void> _loadAccess() async {
    Map<String, dynamic> a;
    try {
      a = widget.accessListRpc != null
          ? await widget.accessListRpc!()
          : await _call('advance_slabs_access_list', const <String, dynamic>{});
    } catch (_) {
      a = <String, dynamic>{'ok': false};
    }
    if (!mounted) return;
    setState(() => _access = a);
    RenderLog.write('advance_slab_access_rows', _accessRows.length);
  }

  Future<void> _setAccess(
      Map<String, dynamic> row, bool canView, bool canWrite) async {
    if (_busy) return;
    setState(() => _busy = true);
    Map<String, dynamic> res;
    try {
      res = widget.accessSetRpc != null
          ? await widget.accessSetRpc!((row['kind'] ?? '').toString(),
              (row['id'] ?? '').toString(), canView, canWrite)
          : await _call('advance_slabs_access_set', {
              'p_kind': row['kind'],
              'p_id': row['id'],
              'p_can_view': canView,
              'p_can_write': canWrite,
            });
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'message': e.toString()};
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _report(res);
    await _loadAccess();
  }

  bool get _ok => _p['ok'] == true;
  bool get _canWrite => _p['can_write'] == true;
  List<Map<String, dynamic>> get _rows => ((_p['rows'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
  List<Map<String, dynamic>> get _columns =>
      ((_p['columns'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
  String _s(String k) => (_p[k] ?? '').toString();
  String _a(String k) => (_access[k] ?? '').toString();
  List<Map<String, dynamic>> get _accessRows =>
      ((_access['rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  /// Every backend answer carries its own wording; this only routes it.
  void _report(Map<String, dynamic> res) {
    final msg = (res['message'] ?? '').toString();
    if (msg.isNotEmpty && mounted) {
      showToast(context, msg, isError: res['ok'] != true);
    }
  }

  Future<void> _toggle(Map<String, dynamic> row, bool next) async {
    if (_busy) return;
    setState(() => _busy = true);
    Map<String, dynamic> res;
    try {
      res = widget.toggleRpc != null
          ? await widget.toggleRpc!((row['id'] as num).toInt(), next)
          : await _call('advance_slab_toggle',
              {'p_id': row['id'], 'p_active': next});
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'message': e.toString()};
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _report(res);
    await _load();
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(_s('delete_confirm'), style: Ds.t.body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_s('cancel_label'))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Ds.c.danger),
            child: Text(_s('delete_label')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    Map<String, dynamic> res;
    try {
      res = widget.deleteRpc != null
          ? await widget.deleteRpc!((row['id'] as num).toInt())
          : await _call('advance_slab_delete', {'p_id': row['id']});
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'message': e.toString()};
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _report(res);
    await _load();
  }

  Future<void> _openEditor([Map<String, dynamic>? row]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
      ),
      builder: (_) => _RungSheet(
        payload: _p,
        row: row,
        onSave: (patch) async {
          Map<String, dynamic> res;
          try {
            res = widget.saveRpc != null
                ? await widget.saveRpc!(patch)
                : await _call('advance_slab_save', {'p': patch});
          } catch (e) {
            res = <String, dynamic>{'ok': false, 'message': e.toString()};
          }
          _report(res);
          return res['ok'] == true;
        },
      ),
    );
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s('title').isEmpty ? '' : _s('title')),
      ),
      floatingActionButton: (_ok && _canWrite)
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : () => _openEditor(),
              backgroundColor: Ds.c.brand,
              foregroundColor: Ds.c.surface,
              icon: const Icon(Icons.add),
              label: Text(_s('add_label')),
            )
          : null,
      body: SafeArea(
        child: _loading
            ? _skeleton()
            : !_ok
                ? _denied()
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16,
                          Ds.space.x16, Ds.space.x48),
                      children: [
                        _header(),
                        if (_s('read_only_hint').isNotEmpty) ...[
                          SizedBox(height: Ds.space.x12),
                          _readOnlyHint(),
                        ],
                        if (_p['show_access'] == true) ...[
                          SizedBox(height: Ds.space.x12),
                          _accessCard(),
                        ],
                        SizedBox(height: Ds.space.x24),
                        if (_rows.isEmpty)
                          _empty()
                        else
                          ..._rows.map(_rungCard),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _header() {
    final sub = _s('subtitle');
    final hint = _s('hint');
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: BorderRadius.circular(Ds.r.card),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_s('zone_label'), style: Ds.t.subtitle),
              ),
              _chip(_s('active_date'), Ds.c.infoSoft, Ds.c.info),
            ],
          ),
          if (sub.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(sub, style: Ds.t.caption),
          ],
          if (hint.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(hint, style: Ds.t.caption),
          ],
        ],
      ),
    );
  }

  Widget _rungCard(Map<String, dynamic> row) {
    String v(String k) => (row[k] ?? '').toString();
    final canEdit = row['can_edit'] == true;
    final canDelete = row['can_delete'] == true;
    // The tone is a design-token NAME from the payload, resolved by the same
    // helper every other backend-toned chip in the app uses — never a hex here.
    final toneBg = toneSoft(row['status_tone']);
    final toneFg = toneColor(row['status_tone']);

    // Column headers come from the payload; the card prints each row under the
    // header the backend named, so a renamed column never needs a deploy.
    String headerFor(String key) {
      for (final c in _columns) {
        if ((c['key'] ?? '') == key) return (c['label'] ?? '').toString();
      }
      return '';
    }

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Container(
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: BorderRadius.circular(Ds.r.card),
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The focal pair: which order this rung starts at, and the
            // advance on it. Everything under them is metadata.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (headerFor('order_label').isNotEmpty) ...[
                        Text(headerFor('order_label'), style: Ds.t.caption),
                        SizedBox(height: Ds.space.x4),
                      ],
                      Text(v('order_label'), style: Ds.t.bodyStrong),
                    ],
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                Text(v('pct_label'), style: Ds.t.subtitle),
              ],
            ),
            SizedBox(height: Ds.space.x8),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                _chip(v('status_label'), toneBg, toneFg),
                _chip(v('zone_label'), Ds.c.brandSoft, Ds.c.brand),
                _chip(v('used_label'), Ds.c.bg, Ds.c.textSecondary),
              ],
            ),
            if (v('effective_label').isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(v('effective_label'), style: Ds.t.caption),
            ],
            if (v('note').isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(v('note'), style: Ds.t.caption),
            ],
            // Worded actions, the same row the Discount-slabs card carries:
            // Edit · the backend's own toggle caption ("Deactivate"/
            // "Activate") · Delete. A Switch would have made the app decide
            // what flipping it means; `toggle_to` is the backend saying it.
            if (canEdit) ...[
              SizedBox(height: Ds.space.x8),
              // Bounded and wrapping: on a 360px phone with a long backend
              // caption the two left actions drop to a second line rather
              // than pushing Delete off the card.
              Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                Expanded(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _CardAction(
                          label: _s('edit_label'),
                          onTap: _busy ? null : () => _openEditor(row)),
                      _CardAction(
                          label: v('toggle_label'),
                          onTap: _busy
                              ? null
                              : () => _toggle(row, row['toggle_to'] == true)),
                    ],
                  ),
                ),
                if (canDelete)
                  _CardAction(
                      label: _s('delete_label'),
                      colour: Ds.c.danger,
                      onTap: _busy ? null : () => _delete(row)),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  /// A read-only admin is TOLD it is read-only. The sentence is the
  /// backend's; the screen never infers "you cannot edit" from a missing
  /// button, and never words the reason itself.
  Widget _readOnlyHint() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.infoSoft,
        borderRadius: BorderRadius.circular(Ds.r.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, size: Ds.space.x16, color: Ds.c.info),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: Text(_s('read_only_hint'),
                style: Ds.t.caption.copyWith(color: Ds.c.info)),
          ),
        ],
      ),
    );
  }

  /// "Who can edit" — the #307 matrix narrowed to this one feature, so a super
  /// admin grants Bilaspur's partner write access from the ladder itself
  /// instead of leaving for the users screen. Both toggles are the backend's
  /// answer; `locked` rows (a super admin) show its note instead of switches.
  Widget _accessCard() {
    final rows = _accessRows;
    final denied = _access.isNotEmpty && _access['ok'] != true;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: BorderRadius.circular(Ds.r.card),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A plain header + disclosure, not an ExpansionTile: a ListTile
          // inside a decorated Container paints its ink on the wrong Material
          // and Flutter asserts on it.
          InkWell(
            onTap: () => setState(() => _accessOpen = !_accessOpen),
            child: Padding(
              padding: EdgeInsets.all(Ds.space.x16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            _a('title').isEmpty
                                ? _s('access_title')
                                : _a('title'),
                            style: Ds.t.bodyStrong),
                        if (_a('subtitle').isNotEmpty) ...[
                          SizedBox(height: Ds.space.x4),
                          Text(_a('subtitle'), style: Ds.t.caption),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(width: Ds.space.x8),
                  Icon(
                      _accessOpen
                          ? Icons.expand_less
                          : Icons.expand_more,
                      color: Ds.c.textSecondary),
                ],
              ),
            ),
          ),
          if (_accessOpen)
            Padding(
              padding: EdgeInsets.fromLTRB(
                  Ds.space.x16, 0, Ds.space.x16, Ds.space.x12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (denied)
                    Text(_a('message'), style: Ds.t.caption)
                  else if (rows.isEmpty)
                    Text(_a('empty_text'), style: Ds.t.caption)
                  else
                    for (final r in rows) _accessRow(r),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _accessRow(Map<String, dynamic> row) {
    String v(String k) => (row[k] ?? '').toString();
    final locked = row['locked'] == true;
    final canView = row['can_view'] == true;
    final canWrite = row['can_write'] == true;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(v('name'), style: Ds.t.body),
          SizedBox(height: Ds.space.x4),
          Text('${v('role_label')} · ${v('zone_label')}', style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          if (locked)
            Text(v('locked_note'), style: Ds.t.caption)
          else
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x4,
              children: [
                _accessToggle(_a('read_label'), canView,
                    (next) => _setAccess(row, next, next ? canWrite : false)),
                _accessToggle(_a('write_label'), canWrite,
                    (next) => _setAccess(row, next ? true : canView, next)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _accessToggle(
      String label, bool value, ValueChanged<bool> onChanged) {
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: value,
            activeThumbColor: Ds.c.brand,
            onChanged: _busy ? null : onChanged,
          ),
          Text(label, style: Ds.t.caption),
          SizedBox(width: Ds.space.x8),
        ],
      ),
    );
  }

  Widget _chip(String label, Color bg, Color fg) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Ds.r.chip),
      ),
      child: Text(label, style: Ds.t.caption.copyWith(color: fg)),
    );
  }

  Widget _empty() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x24),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: BorderRadius.circular(Ds.r.card),
        boxShadow: Ds.elevation.e1,
      ),
      child: Text(_s('empty_text'),
          style: Ds.t.bodySecondary, textAlign: TextAlign.center),
    );
  }

  /// A skeleton, not a bare spinner — the list's own shape while it loads.
  Widget _skeleton() {
    return ListView.builder(
      padding: EdgeInsets.all(Ds.space.x16),
      itemCount: 4,
      itemBuilder: (_, _) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: Container(
          height: Ds.space.x48 + Ds.space.x32,
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: BorderRadius.circular(Ds.r.card),
            boxShadow: Ds.elevation.e1,
          ),
        ),
      ),
    );
  }

  /// The backend's own refusal copy (access_denied), plus Retry.
  Widget _denied() {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The app bar already carries the payload's title; repeating it
            // here would be the screen saying the same thing twice.
            Text(_s('message'),
                style: Ds.t.bodySecondary, textAlign: TextAlign.center),
            SizedBox(height: Ds.space.x16),
            OutlinedButton(onPressed: _load, child: Text(_s('retry_label'))),
          ],
        ),
      ),
    );
  }
}

/// Add / edit one rung. Sends the fields back; every verdict is the backend's.
class _RungSheet extends StatefulWidget {
  final Map<String, dynamic> payload;
  final Map<String, dynamic>? row;
  final Future<bool> Function(Map<String, dynamic> patch) onSave;

  const _RungSheet({
    required this.payload,
    required this.row,
    required this.onSave,
  });

  @override
  State<_RungSheet> createState() => _RungSheetState();
}

class _RungSheetState extends State<_RungSheet> {
  late final TextEditingController _orderNo;
  late final TextEditingController _pct;
  late final TextEditingController _note;
  int? _zoneId;
  DateTime? _validFrom;
  bool _active = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final r = widget.row;
    _orderNo = TextEditingController(text: (r?['order_no'] ?? '').toString());
    _pct = TextEditingController(text: (r?['pct'] ?? '').toString());
    _note = TextEditingController(text: (r?['note'] ?? '').toString());
    _active = r == null ? true : r['active'] == true;
    _validFrom = DateTime.tryParse((r?['valid_from'] ?? '').toString());
    _zoneId = r == null
        ? _defaultZone()
        : (r['zone_id'] is num ? (r['zone_id'] as num).toInt() : null);
  }

  int? _defaultZone() {
    if (widget.payload['can_add_all_zones'] == true) return null;
    final z = widget.payload['zone_id'];
    return z is num ? z.toInt() : null;
  }

  @override
  void dispose() {
    _orderNo.dispose();
    _pct.dispose();
    _note.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _zones =>
      ((widget.payload['zones'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  Map<String, dynamic> get _form => widget.payload['form'] is Map
      ? Map<String, dynamic>.from(widget.payload['form'] as Map)
      : const <String, dynamic>{};

  String _s(String k) => (widget.payload[k] ?? '').toString();
  String _f(String k) => (_form[k] ?? '').toString();

  Future<void> _save() async {
    setState(() => _saving = true);
    final patch = <String, dynamic>{
      if (widget.row != null) 'id': widget.row!['id'],
      'zone_id': _zoneId,
      'order_no': int.tryParse(_orderNo.text.trim()),
      'pct': num.tryParse(_pct.text.trim()),
      'active': _active,
      'note': _note.text.trim(),
      // Sent whenever we have one, so an edit never rewinds the date the rung
      // takes effect from. The backend still owns the fallback.
      if (_validFrom != null)
        'valid_from': _validFrom!.toIso8601String().split('T').first,
    };
    final ok = await widget.onSave(patch);
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x16 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.row == null ? _f('add_title') : _f('edit_title'),
                style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: _orderNo,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: _f('order_label')),
            ),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: _pct,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: _f('pct_label')),
            ),
            SizedBox(height: Ds.space.x12),
            DropdownButtonFormField<int?>(
              initialValue: _zoneId,
              decoration: InputDecoration(labelText: _f('zone_label')),
              items: [
                if (widget.payload['can_add_all_zones'] == true)
                  DropdownMenuItem<int?>(
                    value: null,
                    child: Text(_s('all_zones_label')),
                  ),
                for (final z in _zones)
                  DropdownMenuItem<int?>(
                    value: (z['id'] as num).toInt(),
                    child: Text((z['label'] ?? '').toString()),
                  ),
              ],
              onChanged: (v) => setState(() => _zoneId = v),
            ),
            SizedBox(height: Ds.space.x12),
            // Valid from. The picker writes a date; the LABEL and the display
            // string both come from the payload / the row the backend sent.
            InkWell(
              onTap: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _validFrom ?? now,
                  firstDate: DateTime(now.year - 5),
                  lastDate: DateTime(now.year + 5),
                );
                if (picked != null) setState(() => _validFrom = picked);
              },
              child: InputDecorator(
                decoration: InputDecoration(labelText: _f('from_label')),
                child: SizedBox(
                  height: Ds.touch.minTarget - Ds.space.x16,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                        (widget.row?['effective_label'] ?? '').toString().isEmpty
                            ? (_validFrom == null
                                ? ''
                                : _validFrom!
                                    .toIso8601String()
                                    .split('T')
                                    .first)
                            : (widget.row!['effective_label']).toString(),
                        style: Ds.t.body),
                  ),
                ),
              ),
            ),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: _note,
              decoration: InputDecoration(labelText: _f('note_label')),
            ),
            SizedBox(height: Ds.space.x12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              activeThumbColor: Ds.c.brand,
              title: Text(_f('active_label'), style: Ds.t.body),
              onChanged: (v) => setState(() => _active = v),
            ),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
                child: Text(_f('save_label')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


/// One worded action in a card's action row — the same shape the Discount
/// slabs card uses, so the two screens read as one family. 44px tall because
/// a phone is where this is tapped.
class _CardAction extends StatelessWidget {
  final String label;
  final Color? colour;
  final VoidCallback? onTap;

  const _CardAction({required this.label, this.colour, this.onTap});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: colour ?? Ds.c.brand,
        minimumSize: Size(Ds.touch.minTarget, Ds.touch.minTarget),
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
      ),
      child: Text(label, style: Ds.t.body.copyWith(color: colour ?? Ds.c.brand)),
    );
  }
}

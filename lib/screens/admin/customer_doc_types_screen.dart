// CMD #2060 — Admin › Customer documents: ONE choice per document, per zone.
//
// Two switches (Required, Collected) asked the admin to hold a truth table in
// their head. A document has three states and they are now named out loud:
// Mandatory, Optional, Off. The words, the three options, which one is picked,
// and whether this row is the zone's own or inherited from the defaults all
// arrive on customer_doc_types_admin(); this screen picks none of them.
//
// The zone comes from the header picker, never from here: admin_active_zone()
// pins a partner to their own zone before the RPC is even asked, so "a partner
// edits only their zone" is a backend fact and this screen has no zone control
// of its own to get wrong.
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
      RenderLog.write('c2060_doc_mode', _items.length);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      RenderLog.write('c1935_admin_doc_types', 0);
      RenderLog.write('c2060_doc_mode', 0);
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

  String _s(String k) => (_p[k] ?? '').toString();

  /// Every write answers with the whole screen again, so the payload stays the
  /// single source of what is on it.
  Future<void> _call(String fn, Map<String, dynamic>? args, String busyKey) async {
    setState(() => _busy = busyKey);
    try {
      final r = await CustomerDocTypesScreen.rpc(fn, args);
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

  Future<void> _set(String key, Map<String, dynamic> patch) =>
      _call('customer_doc_type_set', {'p_key': key, 'p_patch': patch}, key);

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final keys = _items.map((e) => (e['key'] ?? '').toString()).toList();
    if (oldIndex < 0 || oldIndex >= keys.length) return;
    var to = newIndex;
    if (to > oldIndex) to -= 1;
    final moved = keys.removeAt(oldIndex);
    keys.insert(to.clamp(0, keys.length), moved);
    await _call('customer_doc_types_reorder', {'p_keys': keys}, '*reorder');
  }

  Future<void> _add() async {
    final name = TextEditingController();
    final hint = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x24,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s('add_title'), style: Ds.t.title),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: name,
              style: Ds.t.body,
              decoration: InputDecoration(labelText: _s('add_name_label')),
            ),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: hint,
              style: Ds.t.body,
              decoration: InputDecoration(labelText: _s('add_hint_label')),
            ),
            SizedBox(height: Ds.space.x24),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(_s('add_save_label')),
              ),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _call('customer_doc_type_add',
        {'p_label': name.text, 'p_hint': hint.text}, '*add');
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final refused = _p.isNotEmpty && _p['ok'] != true;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s('title'))),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: EdgeInsets.all(Ds.space.x16),
                  children: [
                    if (refused)
                      Text(_s('message'), style: Ds.t.body)
                    else ...[
                      _ZoneHeader(
                        payload: _p,
                        busy: _busy == '*copy',
                        onCopyDefaults: () => _call(
                            'customer_doc_zone_copy_defaults', null, '*copy'),
                      ),
                      SizedBox(height: Ds.space.x24),
                      Text(_s('subtitle'), style: Ds.t.bodySecondary),
                      SizedBox(height: Ds.space.x16),
                      if (items.isEmpty)
                        Text(_s('empty_line'), style: Ds.t.bodySecondary)
                      else if (_p['can_reorder'] == true)
                        ReorderableListView(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          buildDefaultDragHandles: false,
                          onReorder: _reorder,
                          children: [
                            for (var i = 0; i < items.length; i++)
                              Padding(
                                key: ValueKey(
                                    (items[i]['key'] ?? i).toString()),
                                padding:
                                    EdgeInsets.only(bottom: Ds.space.x12),
                                child: _TypeRow(
                                  item: items[i],
                                  modeLabel: _s('mode_label'),
                                  dragIndex: i,
                                  busy: _busy ==
                                      (items[i]['key'] ?? '').toString(),
                                  onSet: (patch) => _set(
                                      (items[i]['key'] ?? '').toString(),
                                      patch),
                                ),
                              ),
                          ],
                        )
                      else
                        for (final it in items) ...[
                          _TypeRow(
                            item: it,
                            modeLabel: _s('mode_label'),
                            dragIndex: null,
                            busy: _busy == (it['key'] ?? '').toString(),
                            onSet: (patch) =>
                                _set((it['key'] ?? '').toString(), patch),
                          ),
                          SizedBox(height: Ds.space.x12),
                        ],
                      if (_p['can_add'] == true) ...[
                        SizedBox(height: Ds.space.x24),
                        SizedBox(
                          width: double.infinity,
                          height: Ds.touch.minTarget,
                          child: OutlinedButton.icon(
                            onPressed: _busy.isEmpty ? _add : null,
                            icon: const Icon(Icons.add),
                            label: Text(_s('add_label')),
                          ),
                        ),
                      ],
                      if (_s('reorder_hint').isNotEmpty) ...[
                        SizedBox(height: Ds.space.x12),
                        Text(_s('reorder_hint'), style: Ds.t.caption),
                      ],
                    ],
                    SizedBox(height: Ds.space.x32),
                  ],
                ),
              ),
      ),
    );
  }
}

/// Which zone this list belongs to, said in the backend's words. Nothing here
/// changes the zone — the header picker does that for the whole app.
class _ZoneHeader extends StatelessWidget {
  final Map<String, dynamic> payload;
  final bool busy;
  final VoidCallback onCopyDefaults;

  const _ZoneHeader({
    required this.payload,
    required this.busy,
    required this.onCopyDefaults,
  });

  String _s(String k) => (payload[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final note = _s('zone_note');
    final locked = _s('zone_locked_note');
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(_s('zone_label'), style: Ds.t.caption),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x4),
                decoration: BoxDecoration(
                  color: Ds.c.brandSoft,
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(_s('zone_name'),
                    style: Ds.t.body.copyWith(color: Ds.c.brand)),
              ),
            ],
          ),
          if (note.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(note, style: Ds.t.caption),
          ],
          if (locked.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(locked, style: Ds.t.caption),
          ],
          if (payload['can_copy_defaults'] == true) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: busy ? null : onCopyDefaults,
                child: Text(_s('copy_defaults_label')),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TypeRow extends StatelessWidget {
  final Map<String, dynamic> item;
  final String modeLabel;
  final int? dragIndex;
  final bool busy;
  final ValueChanged<Map<String, dynamic>> onSet;

  const _TypeRow({
    required this.item,
    required this.modeLabel,
    required this.dragIndex,
    required this.busy,
    required this.onSet,
  });

  @override
  Widget build(BuildContext context) {
    final hint = (item['hint'] ?? '').toString();
    final note = (item['note'] ?? '').toString();
    final source = (item['source_label'] ?? '').toString();
    final idx = dragIndex;
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((item['label'] ?? '').toString(),
                        style: Ds.t.subtitle),
                    if (hint.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(hint, style: Ds.t.caption),
                    ],
                  ],
                ),
              ),
              if (idx != null)
                ReorderableDragStartListener(
                  index: idx,
                  child: SizedBox(
                    width: Ds.touch.minTarget,
                    height: Ds.touch.minTarget,
                    child: Icon(Icons.drag_handle, color: Ds.c.textSecondary),
                  ),
                ),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          Text(modeLabel, style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          _ModeChoice(
            options: item['options'],
            value: (item['mode'] ?? '').toString(),
            busy: busy,
            onPick: (v) => onSet({'mode': v}),
          ),
          if (note.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(note, style: Ds.t.caption),
          ],
          if (source.isNotEmpty || item['can_reset'] == true) ...[
            SizedBox(height: Ds.space.x8),
            Wrap(
              spacing: Ds.space.x12,
              runSpacing: Ds.space.x8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (source.isNotEmpty) Text(source, style: Ds.t.caption),
                if (item['can_reset'] == true)
                  SizedBox(
                    height: Ds.touch.minTarget,
                    child: TextButton(
                      onPressed: busy ? null : () => onSet({'reset': true}),
                      child: Text((item['reset_label'] ?? '').toString()),
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

/// The three-way choice. Three equal segments, each at least a touch target
/// tall, so it fits a 360 px phone without a fixed width anywhere.
class _ModeChoice extends StatelessWidget {
  final Object? options;
  final String value;
  final bool busy;
  final ValueChanged<String> onPick;

  const _ModeChoice({
    required this.options,
    required this.value,
    required this.busy,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final raw = options;
    final opts = raw is List
        ? raw
            .map((e) => e is Map ? Map<String, dynamic>.from(e) : null)
            .whereType<Map<String, dynamic>>()
            .toList()
        : const <Map<String, dynamic>>[];
    if (opts.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: Ds.c.bg,
        borderRadius: Ds.r.rButton,
        border: Border.all(color: Ds.c.divider),
      ),
      padding: EdgeInsets.all(Ds.space.x4),
      child: Row(
        children: [
          for (final o in opts)
            Expanded(
              child: _Segment(
                label: (o['label'] ?? '').toString(),
                selected: (o['value'] ?? '').toString() == value,
                busy: busy,
                onTap: () => onPick((o['value'] ?? '').toString()),
              ),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  final String label;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;

  const _Segment({
    required this.label,
    required this.selected,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: Ds.r.rButton,
        child: Container(
          height: Ds.touch.minTarget,
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x4),
          decoration: BoxDecoration(
            color: selected ? Ds.c.brand : Ds.c.surface,
            borderRadius: Ds.r.rButton,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: Ds.t.body.copyWith(
                  color: selected ? Ds.c.surface : Ds.c.text),
            ),
          ),
        ),
      ),
    );
  }
}

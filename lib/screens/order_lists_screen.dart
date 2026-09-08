import 'package:flutter/material.dart';
import 'package:pharma_b2b/utils/toast.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

/// CMD #367 · feature_gaps row 178 — named, saved order lists.
///
/// The pharmacy's "Monthly stock": created from a past order or pasted in,
/// edited, scheduled, shared with the rest of the pharmacy account, and
/// re-fired into the cart in one tap.
///
/// Backed entirely by `order_list_*` RPCs. Every string on this screen —
/// titles, counts, "Every 30 days", "Shared with the pharmacy", the button
/// captions, the match verdicts on a pasted list — arrives in the payload. The
/// paste view is the SAME matcher the WhatsApp bulk path uses, so what the
/// buyer confirms here is what WhatsApp would have understood.
class OrderListsScreen extends StatefulWidget {
  /// When set, the screen opens with a "save this order as a list" prompt.
  final String? fromOrderId;
  const OrderListsScreen({super.key, this.fromOrderId});

  @override
  State<OrderListsScreen> createState() => _OrderListsScreenState();
}

class _OrderListsScreenState extends State<OrderListsScreen> {
  final _sb = Supabase.instance.client;
  bool _loading = true;
  bool _busy = false;
  Map<String, dynamic>? _p;

  Map<String, dynamic> get _copy {
    final v = _p?['copy'];
    return v is Map ? Map<String, dynamic>.from(v) : const {};
  }

  String _c(String k) => (_copy[k] ?? '').toString();
  String _s(String k) => (_p?[k] ?? '').toString();

  List<Map<String, dynamic>> get _lists {
    final v = _p?['lists'];
    if (v is! List) return const [];
    return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await _sb.rpc('order_list_screen');
      if (!mounted) return;
      setState(() {
        _p = (r is Map) ? Map<String, dynamic>.from(r) : null;
        _loading = false;
      });
      RenderLog.write('order_lists_screen', {
        'lists': _lists.length,
        'has_lists': _p?['has_lists'] == true,
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _p = null;
        _loading = false;
      });
    }
  }

  Future<void> _create() async {
    final name = await _askName(_c('create_label'), '');
    if (name == null || name.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await _sb.rpc('order_list_create', params: {
        'p_name': name,
        'p_from_order_id': widget.fromOrderId,
      });
      final m = (r is Map) ? Map<String, dynamic>.from(r) : const {};
      if (mounted && m['ok'] != true) {
        showToast(context, (m['message'] ?? '').toString(), isError: true);
      } else if (mounted) {
        showToast(context, (m['toast'] ?? '').toString());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<String?> _askName(String title, String initial) async {
    final ctrl = TextEditingController(text: initial);
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
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
            Text(title, style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: ctrl,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                hintText: _c('create_hint'),
                filled: true,
                fillColor: Ds.c.bg,
                border: OutlineInputBorder(borderRadius: Ds.r.rButton),
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape:
                      RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: () => Navigator.of(ctx).pop(ctrl.text),
                child: Text(title),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s('title').isEmpty ? _c('title') : _s('title'))),
      floatingActionButton: _p == null
          ? null
          : FloatingActionButton.extended(
              backgroundColor: Ds.c.brand,
              onPressed: _busy ? null : _create,
              icon: const Icon(Icons.playlist_add),
              label: Text(_s('create_label')),
            ),
      body: _loading
          ? const _ListsSkeleton()
          : RefreshIndicator(
              onRefresh: _load,
              child: (_p?['has_lists'] == true) ? _rows() : _empty(),
            ),
    );
  }

  Widget _empty() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          SizedBox(height: Ds.space.x48),
          Icon(Icons.playlist_add_check_outlined,
              size: Ds.space.x48, color: Ds.c.textSecondary),
          SizedBox(height: Ds.space.x16),
          Text(_s('empty_title'),
              textAlign: TextAlign.center, style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
          Text(_s('empty_note'),
              textAlign: TextAlign.center, style: Ds.t.caption),
        ],
      );

  Widget _rows() {
    final rows = _lists;
    return ListView.builder(
      padding: EdgeInsets.all(Ds.space.x16),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final l = rows[i];
        return Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x12),
          child: Material(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            child: InkWell(
              borderRadius: Ds.r.rCard,
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        OrderListDetailScreen(listId: (l['id'] ?? '').toString())));
                await _load();
              },
              child: Container(
                constraints:
                    BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
                padding: EdgeInsets.all(Ds.space.x16),
                decoration: BoxDecoration(
                  borderRadius: Ds.r.rCard,
                  boxShadow: Ds.elevation.e1,
                  color: Ds.c.surface,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text((l['name'] ?? '').toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Ds.t.body
                                  .copyWith(fontWeight: FontWeight.w600)),
                          SizedBox(height: Ds.space.x4),
                          Text(
                            [
                              (l['count_label'] ?? '').toString(),
                              (l['schedule_label'] ?? '').toString(),
                              (l['share_label'] ?? '').toString(),
                            ].where((s) => s.isNotEmpty).join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Ds.t.caption,
                          ),
                          if ((l['due_label'] ?? '').toString().isNotEmpty)
                            Text((l['due_label'] ?? '').toString(),
                                style: Ds.t.caption),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: Ds.c.textSecondary),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One list: its items, its schedule, and the four backend-declared buttons.
class OrderListDetailScreen extends StatefulWidget {
  final String listId;
  const OrderListDetailScreen({super.key, required this.listId});

  @override
  State<OrderListDetailScreen> createState() => _OrderListDetailScreenState();
}

class _OrderListDetailScreenState extends State<OrderListDetailScreen> {
  final _sb = Supabase.instance.client;
  bool _loading = true;
  bool _busy = false;
  Map<String, dynamic>? _p;

  Map<String, dynamic> get _copy {
    final v = _p?['copy'];
    return v is Map ? Map<String, dynamic>.from(v) : const {};
  }

  String _c(String k) => (_copy[k] ?? '').toString();
  String _s(String k) => (_p?[k] ?? '').toString();

  List<Map<String, dynamic>> _arr(Object? v) => (v is List)
      ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : const [];

  Map<String, dynamic> get _schedule {
    final v = _p?['schedule'];
    return v is Map ? Map<String, dynamic>.from(v) : const {};
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await _sb
          .rpc('order_list_detail', params: {'p_id': widget.listId});
      if (!mounted) return;
      setState(() {
        _p = (r is Map) ? Map<String, dynamic>.from(r) : null;
        _loading = false;
      });
      RenderLog.write('order_list_detail', {
        'items': _arr(_p?['items']).length,
        'buttons': _arr(_p?['buttons']).length,
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _p = null;
        _loading = false;
      });
    }
  }

  /// Every mutation lands the same way: call the RPC, adopt the `detail` it
  /// returns, show the toast it worded. The screen re-derives nothing.
  Future<void> _act(String fn, Map<String, dynamic> params,
      {bool pop = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await _sb.rpc(fn, params: params);
      final m = (r is Map) ? Map<String, dynamic>.from(r) : const {};
      if (!mounted) return;
      if (m['ok'] != true) {
        showToast(context, (m['message'] ?? '').toString(), isError: true);
        return;
      }
      final toast = (m['toast'] ?? '').toString();
      if (toast.isNotEmpty) showToast(context, toast);
      if (pop) {
        Navigator.of(context).pop();
        return;
      }
      if (m['detail'] is Map) {
        setState(() => _p = Map<String, dynamic>.from(m['detail'] as Map));
      } else {
        await _load();
      }
    } catch (_) {
      if (mounted) await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onButton(String key) async {
    switch (key) {
      case 'add_to_cart':
        await _act('order_list_to_cart', {'p_id': widget.listId});
        break;
      case 'paste':
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => OrderListPasteScreen(listId: widget.listId)));
        await _load();
        break;
      case 'rename':
        final name = await _renamePrompt();
        if (name != null && name.trim().isNotEmpty) {
          await _act('order_list_rename',
              {'p_id': widget.listId, 'p_name': name});
        }
        break;
      case 'delete':
        await _act('order_list_delete', {'p_id': widget.listId}, pop: true);
        break;
    }
  }

  Future<String?> _renamePrompt() {
    final ctrl = TextEditingController(text: _s('name'));
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
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
            Text(_c('rename_label'), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(
                hintText: _c('create_hint'),
                filled: true,
                fillColor: Ds.c.bg,
                border: OutlineInputBorder(borderRadius: Ds.r.rButton),
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: () => Navigator.of(ctx).pop(ctrl.text),
                child: Text(_c('rename_label')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _arr(_p?['items']);
    final buttons = _arr(_p?['buttons']);
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s('name'))),
      body: _loading
          ? const _ListsSkeleton()
          : _p == null || _p?['ok'] != true
              ? Center(child: Text(_s('message'), style: Ds.t.caption))
              : ListView(
                  padding: EdgeInsets.all(Ds.space.x16),
                  children: [
                    _headerCard(),
                    SizedBox(height: Ds.space.x24),
                    if (items.isEmpty)
                      Text(_s('empty_note'), style: Ds.t.caption)
                    else
                      Container(
                        decoration: BoxDecoration(
                          color: Ds.c.surface,
                          borderRadius: Ds.r.rCard,
                          boxShadow: Ds.elevation.e1,
                        ),
                        padding: EdgeInsets.symmetric(
                            horizontal: Ds.space.x16, vertical: Ds.space.x8),
                        child: Column(
                          children: [
                            for (var i = 0; i < items.length; i++)
                              _itemRow(items[i], i == items.length - 1),
                          ],
                        ),
                      ),
                    SizedBox(height: Ds.space.x24),
                    for (final b in buttons)
                      Padding(
                        padding: EdgeInsets.only(bottom: Ds.space.x8),
                        child: SizedBox(
                          width: double.infinity,
                          height: Ds.touch.minTarget,
                          child: b['tone'] == 'brand'
                              ? FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Ds.c.brand,
                                    shape: RoundedRectangleBorder(
                                        borderRadius: Ds.r.rButton),
                                  ),
                                  onPressed: (_busy || b['enabled'] != true)
                                      ? null
                                      : () =>
                                          _onButton((b['key'] ?? '').toString()),
                                  child: Text((b['label'] ?? '').toString()),
                                )
                              : OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: b['tone'] == 'danger'
                                        ? Ds.c.danger
                                        : Ds.c.text,
                                    side: BorderSide(
                                        color: b['tone'] == 'danger'
                                            ? Ds.c.danger
                                            : Ds.c.divider),
                                    shape: RoundedRectangleBorder(
                                        borderRadius: Ds.r.rButton),
                                  ),
                                  onPressed: (_busy || b['enabled'] != true)
                                      ? null
                                      : () =>
                                          _onButton((b['key'] ?? '').toString()),
                                  child: Text((b['label'] ?? '').toString()),
                                ),
                        ),
                      ),
                    SizedBox(height: Ds.space.x32),
                  ],
                ),
    );
  }

  Widget _headerCard() {
    final sch = _schedule;
    final options = (sch['options'] is List)
        ? (sch['options'] as List).whereType<num>().map((n) => n.toInt()).toList()
        : const <int>[];
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
          Text(_s('count_label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x12),
          // Sharing: the label is the backend's, the switch just reports a tap.
          Row(
            children: [
              Expanded(child: Text(_s('share_label'), style: Ds.t.body)),
              Switch(
                value: _p?['shared'] == true,
                activeThumbColor: Ds.c.brand,
                onChanged: _busy
                    ? null
                    : (v) => _act('order_list_share_set',
                        {'p_id': widget.listId, 'p_shared': v}),
              ),
            ],
          ),
          Divider(color: Ds.c.divider),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((sch['label'] ?? '').toString(), style: Ds.t.body),
                    if ((sch['due_label'] ?? '').toString().isNotEmpty)
                      Text((sch['due_label'] ?? '').toString(),
                          style: Ds.t.caption),
                  ],
                ),
              ),
              Switch(
                value: sch['enabled'] == true,
                activeThumbColor: Ds.c.brand,
                onChanged: _busy
                    ? null
                    : (v) => _act('order_list_schedule_set', {
                          'p_id': widget.listId,
                          'p_cadence_days':
                              ((sch['cadence_days'] ?? 0) as num).toInt() > 0
                                  ? ((sch['cadence_days'] ?? 0) as num).toInt()
                                  : (options.isNotEmpty ? options[2] : 30),
                          'p_enabled': v,
                        }),
              ),
            ],
          ),
          if (sch['enabled'] == true && options.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Wrap(
              spacing: Ds.space.x8,
              children: [
                for (final d in options)
                  ChoiceChip(
                    label: Text('$d'),
                    selected:
                        ((sch['cadence_days'] ?? 0) as num).toInt() == d,
                    selectedColor: Ds.c.brandSoft,
                    onSelected: _busy
                        ? null
                        : (_) => _act('order_list_schedule_set', {
                              'p_id': widget.listId,
                              'p_cadence_days': d,
                              'p_enabled': true,
                            }),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _itemRow(Map<String, dynamic> it, bool last) {
    final qty = ((it['qty'] ?? 1) as num).toInt();
    return Container(
      constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
      padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
      decoration: last
          ? null
          : BoxDecoration(
              border: Border(bottom: BorderSide(color: Ds.c.divider))),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text((it['name'] ?? '').toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.body),
                Text(
                  [
                    (it['company'] ?? '').toString(),
                    (it['pack_label'] ?? '').toString(),
                  ].where((s) => s.isNotEmpty).join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.caption,
                ),
              ],
            ),
          ),
          SizedBox(width: Ds.space.x8),
          IconButton(
            constraints: BoxConstraints(
                minWidth: Ds.touch.minTarget, minHeight: Ds.touch.minTarget),
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: _busy
                ? null
                : () => _act('order_list_item_set', {
                      'p_id': widget.listId,
                      'p_product_id':
                          int.tryParse((it['product_id'] ?? '').toString()),
                      'p_qty': qty - 1,
                    }),
          ),
          Text((it['qty_label'] ?? '').toString(), style: Ds.t.body),
          IconButton(
            constraints: BoxConstraints(
                minWidth: Ds.touch.minTarget, minHeight: Ds.touch.minTarget),
            icon: const Icon(Icons.add_circle_outline),
            onPressed: _busy
                ? null
                : () => _act('order_list_item_set', {
                      'p_id': widget.listId,
                      'p_product_id':
                          int.tryParse((it['product_id'] ?? '').toString()),
                      'p_qty': qty + 1,
                    }),
          ),
        ],
      ),
    );
  }
}

/// The parse-and-confirm view — the in-app equivalent of the WhatsApp bulk
/// path, running through the very same `bulk_match_items` matcher. Verdicts,
/// their words and their tones all come from `order_list_parse`; the app only
/// keeps which rows the buyer ticked.
class OrderListPasteScreen extends StatefulWidget {
  final String listId;
  const OrderListPasteScreen({super.key, required this.listId});

  @override
  State<OrderListPasteScreen> createState() => _OrderListPasteScreenState();
}

class _OrderListPasteScreenState extends State<OrderListPasteScreen> {
  final _sb = Supabase.instance.client;
  final _ctrl = TextEditingController();
  bool _busy = false;
  Map<String, dynamic>? _p;
  ParseSelection _sel = ParseSelection(const []);

  String _c(String k) {
    final v = _p?['copy'];
    return (v is Map ? (v[k] ?? '') : '').toString();
  }

  List<Map<String, dynamic>> get _items {
    final v = _p?['items'];
    if (v is! List) return const [];
    return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Color _tone(String t) {
    switch (t) {
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

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _parse() async {
    setState(() => _busy = true);
    try {
      final r = await _sb.rpc('order_list_parse', params: {'p_text': _ctrl.text});
      if (!mounted) return;
      setState(() {
        _p = (r is Map) ? Map<String, dynamic>.from(r) : null;
        // The BACKEND says which rows arrive pre-ticked; the app does not
        // decide that a 0.72 score is "confident enough".
        _sel = ParseSelection(_items);
      });
      RenderLog.write('order_list_parse', {'rows': _items.length});
    } catch (_) {
      if (mounted) setState(() => _p = null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final chosen = _sel.payload;
    if (chosen.isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await _sb.rpc('order_list_add_parsed',
          params: {'p_id': widget.listId, 'p_items': chosen});
      final m = (r is Map) ? Map<String, dynamic>.from(r) : const {};
      if (!mounted) return;
      if (m['ok'] == true) {
        Navigator.of(context).pop();
      } else {
        showToast(context, (m['message'] ?? '').toString(), isError: true);
      }
    } catch (_) {
      // fall through — the list reloads when this screen pops
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_c('paste_title'))),
      body: ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          TextField(
            controller: _ctrl,
            minLines: 4,
            maxLines: 10,
            decoration: InputDecoration(
              hintText: _c('paste_hint'),
              filled: true,
              fillColor: Ds.c.surface,
              border: OutlineInputBorder(borderRadius: Ds.r.rButton),
            ),
          ),
          SizedBox(height: Ds.space.x12),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Ds.c.brand,
                side: BorderSide(color: Ds.c.brand),
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              onPressed: _busy ? null : _parse,
              child: Text(_c('paste_title')),
            ),
          ),
          if (items.isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            for (var i = 0; i < items.length; i++) _row(items[i], i),
            SizedBox(height: Ds.space.x24),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: (_busy || _sel.isEmpty) ? null : _confirm,
                child: Text(_c('paste_confirm')),
              ),
            ),
          ],
          SizedBox(height: Ds.space.x32),
        ],
      ),
    );
  }

  Widget _row(Map<String, dynamic> it, int i) {
    final canAdd = it['can_add'] == true;
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: Container(
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: Row(
          children: [
            SizedBox(
              width: Ds.touch.minTarget,
              child: Checkbox(
                value: _sel.isPicked(i),
                activeColor: Ds.c.brand,
                onChanged: canAdd
                    ? (v) => setState(() => _sel.toggle(i, v == true))
                    : null,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text((it['name'] ?? '').toString(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.body),
                  Text(
                    [
                      (it['input'] ?? '').toString(),
                      (it['company'] ?? '').toString(),
                    ].where((s) => s.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.caption,
                  ),
                ],
              ),
            ),
            SizedBox(width: Ds.space.x8),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8, vertical: Ds.space.x4),
              decoration: BoxDecoration(
                color: Ds.c.bg,
                borderRadius: Ds.r.rChip,
              ),
              child: Text(
                (it['status_label'] ?? '').toString(),
                style: Ds.t.caption
                    .copyWith(color: _tone((it['status_tone'] ?? '').toString())),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ListsSkeleton extends StatelessWidget {
  const _ListsSkeleton();
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        for (var i = 0; i < 4; i++)
          Container(
            height: Ds.space.x48,
            margin: EdgeInsets.only(bottom: Ds.space.x12),
            decoration: BoxDecoration(
              color: Ds.c.divider,
              borderRadius: Ds.r.rCard,
            ),
          ),
      ],
    );
  }
}


/// The parse-and-confirm tick state, pulled out of the widget so the protected
/// suite can hold it down without a network.
///
/// Two rules, both the backend's: a row arrives ticked ONLY because the
/// payload said `preselected`, and only a row the payload marked `can_add`
/// (i.e. that carries a product_id) can ever be submitted. The app never
/// decides that a match score is "good enough" — that verdict already came
/// down the wire.
class ParseSelection {
  final List<Map<String, dynamic>> items;
  final Set<int> picked;

  ParseSelection(this.items) : picked = <int>{} {
    for (var i = 0; i < items.length; i++) {
      if (items[i]['preselected'] == true) picked.add(i);
    }
  }

  bool isPicked(int i) => picked.contains(i);

  /// A tap only lands on a row the backend allows to be added.
  void toggle(int i, bool on) {
    if (i < 0 || i >= items.length) return;
    if (items[i]['can_add'] != true) return;
    if (on) {
      picked.add(i);
    } else {
      picked.remove(i);
    }
  }

  /// What goes to `order_list_add_parsed`: the ticked rows, in payload order,
  /// each carrying the backend's own product_id and the quantity it parsed.
  List<Map<String, dynamic>> get payload => [
        for (var i = 0; i < items.length; i++)
          if (picked.contains(i) &&
              (items[i]['product_id'] ?? '').toString().isNotEmpty)
            {
              'product_id': items[i]['product_id'],
              'qty': items[i]['qty'],
            }
      ];

  bool get isEmpty => payload.isEmpty;
}

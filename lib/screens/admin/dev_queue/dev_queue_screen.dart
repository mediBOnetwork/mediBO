import 'dart:async';
import 'package:flutter/material.dart';

import '../../../services/ui_copy.dart';
import '../../../utils/toast.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';
import 'dev_queue_bulk_add.dart';
import 'dev_queue_detail.dart';
import 'dev_queue_control.dart';

/// The Dev Queue registry — the permanent development record, rendered from
/// `dev_cmd_list` verbatim. Om pastes specs here; the VM runner claims and
/// builds them; every result lands back in these rows.
class DevQueueScreen extends StatefulWidget {
  final DevQueueService? service; // test seam
  const DevQueueScreen({super.key, this.service});

  @override
  State<DevQueueScreen> createState() => _DevQueueScreenState();
}

class _DevQueueScreenState extends State<DevQueueScreen> {
  late final DevQueueService _svc = widget.service ?? DevQueueService();
  final _searchCtl = TextEditingController();
  Timer? _poll;
  Timer? _debounce;

  bool _loading = true;
  String _title = '';
  String? _status; // null = all
  String? _batch;
  List<Map<String, dynamic>> _rows = const [];
  Map<String, int> _counts = const {};

  bool get _hasActive =>
      _rows.any((r) => r['status'] == 'building' || r['status'] == 'needs_input');

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_hasActive) _load(silent: true);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _debounce?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final p = await _svc.list(
        status: _status,
        search: _searchCtl.text.trim(),
        batch: _batch,
      );
      if (!mounted) return;
      setState(() {
        _title = (p['screen_title'] as String?) ?? _title;
        _rows = ((p['rows'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _counts = ((p['counts'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k.toString(), asInt(v)));
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onSearch(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _load(silent: true));
  }

  Future<void> _openBulkAdd() async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DevQueueBulkAdd(service: _svc),
    );
    if (added == true) _load();
  }

  Future<void> _openDetail(Map<String, dynamic> row) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          DevQueueDetail(id: asInt(row['id']), initialRow: row, service: _svc),
    ));
    _load(silent: true);
  }

  Future<bool> _confirm(String key) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        content: Text(c(key)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(c('dev_queue.btn_cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF991B1B)),
              child: Text(c('dev_queue.btn_delete'))),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    if (!await _confirm('dev_queue.confirm_delete')) return;
    try {
      await _svc.delete(asInt(row['id']));
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    }
    _load(silent: true);
  }

  Future<void> _clearCancelled() async {
    if (!await _confirm('dev_queue.confirm_clear_cancelled')) return;
    try {
      await _svc.deleteCancelled();
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    }
    _load(silent: true);
  }

  Future<void> _reorder(int oldI, int newI) async {
    final rows = [..._rows];
    if (newI > oldI) newI -= 1;
    final moved = rows.removeAt(oldI);
    rows.insert(newI, moved);
    setState(() => _rows = rows);
    try {
      await _svc.reorder(rows.map((r) => asInt(r['id'])).toList());
    } catch (_) {}
    _load(silent: true);
  }

  int get _total => _counts.values.fold(0, (a, b) => a + b);

  @override
  Widget build(BuildContext context) {
    final reorderable = _status == 'pending';
    return Scaffold(
      backgroundColor: kPageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: kBrand),
        title: Text(_title.isEmpty ? c('dev_queue.nav_label') : _title,
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700, color: kTextHi)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: kBorder),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: kBrand,
        onPressed: _openBulkAdd,
        icon: const Icon(Icons.add, color: Colors.white),
        label: Text(c('dev_queue.btn_add'),
            style: const TextStyle(color: Colors.white)),
      ),
      body: SafeArea(
        child: Column(children: [
          DevQueueControl(service: _svc),
          _header(),
          _filters(),
          if (_status == 'cancelled' && _rows.isNotEmpty) _clearBar(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: kBrand))
                : _rows.isEmpty
                    ? _empty()
                    : RefreshIndicator(
                        color: kBrand,
                        onRefresh: _load,
                        child: reorderable
                            ? ReorderableListView.builder(
                                padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                                itemCount: _rows.length,
                                onReorder: _reorder,
                                itemBuilder: (ctx, i) => Padding(
                                  key: ValueKey(_rows[i]['id']),
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: _Row(
                                      row: _rows[i],
                                      draggable: true,
                                      onTap: () =>
                                          _openDetail(_rows[i])),
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                                itemCount: _rows.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 12),
                                itemBuilder: (ctx, i) => _Row(
                                    row: _rows[i],
                                    onTap: () =>
                                        _openDetail(_rows[i]),
                                    onDelete:
                                        _rows[i]['status'] == 'cancelled'
                                            ? () => _delete(_rows[i])
                                            : null),
                              ),
                      ),
          ),
        ]),
      ),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(children: [
          Expanded(
            child: SizedBox(
            height: 40,
            child: TextField(
              controller: _searchCtl,
              onChanged: _onSearch,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: c('dev_queue.search_hint'),
                prefixIcon: const Icon(Icons.search, size: 18, color: kTextLo),
                filled: true,
                fillColor: Colors.white,
                contentPadding: EdgeInsets.zero,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: kBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: kBrand),
                ),
              ),
            ),
          ),
          ),
        ]),
      );

  Widget _filters() {
    final chips = <Widget>[
      _chip(c('dev_queue.filter_all'), null, _total),
    ];
    for (final entry in _counts.entries) {
      chips.add(_chip(statusLabel(entry.key), entry.key, entry.value));
    }
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final ch in chips) Padding(padding: const EdgeInsets.only(right: 8), child: ch),
        ],
      ),
    );
  }

  Widget _chip(String label, String? value, int count) {
    final sel = _status == value;
    return ChoiceChip(
      label: Text('$label ($count)'),
      selected: sel,
      onSelected: (_) {
        setState(() => _status = value);
        _load();
      },
      selectedColor: const Color(0xFFD1FAE5),
      backgroundColor: Colors.white,
      labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: sel ? const Color(0xFF065F46) : kTextLo),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: kBorder),
      ),
    );
  }

  Widget _clearBar() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _clearCancelled,
            icon: const Icon(Icons.delete_sweep_outlined,
                size: 18, color: Color(0xFF991B1B)),
            label: Text(c('dev_queue.btn_clear_cancelled'),
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF991B1B))),
          ),
        ),
      );

  Widget _empty() => ListView(children: [
        const SizedBox(height: 120),
        Icon(Icons.inbox_outlined, size: 56, color: kTextLo.withValues(alpha: 0.5)),
        const SizedBox(height: 16),
        Center(
          child: Text(c('dev_queue.empty_title'),
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: kTextHi)),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(c('dev_queue.empty_body'),
              style: const TextStyle(fontSize: 13, color: kTextLo)),
        ),
      ]);
}

class _Row extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final bool draggable;
  const _Row(
      {required this.row,
      required this.onTap,
      this.onDelete,
      this.draggable = false});

  @override
  Widget build(BuildContext context) {
    final status = (row['status'] ?? 'pending').toString();
    final id = asInt(row['id']);
    final urgent = row['urgent'] == true;
    final rolledBack = row['rolled_back'] == true;
    final batch = (row['batch_label'] ?? '').toString();
    final deploy = row['web_deploy_no'];
    final android = (row['android_status'] ?? 'not_requested').toString();
    final msgs = asInt(row['msg_count']);
    final cost = row['cost_inr'];

    return DqCard(
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          ToneChip(
            label: statusLabel(status),
            tone: statusTone(status),
            spinning: status == 'building',
          ),
          const SizedBox(width: 8),
          Text('#$id',
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: kTextLo)),
          const Spacer(),
          if (draggable)
            const Icon(Icons.drag_handle, size: 18, color: kTextLo),
          if (onDelete != null)
            InkWell(
              onTap: onDelete,
              borderRadius: BorderRadius.circular(20),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.delete_outline,
                    size: 20, color: Color(0xFF991B1B)),
              ),
            ),
        ]),
        const SizedBox(height: 8),
        Text((row['title'] ?? '').toString(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600, color: kTextHi)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (urgent)
            ToneChip(
                label: c('dev_queue.flag_urgent'),
                tone: statusTone('failed'),
                icon: Icons.priority_high),
          if (rolledBack)
            ToneChip(
                label: c('dev_queue.flag_rolled_back'),
                tone: statusTone('paused'),
                icon: Icons.undo),
          if (batch.isNotEmpty)
            ToneChip(label: batch, tone: statusTone('paused'), icon: Icons.label_outline),
          if (android != 'not_requested')
            ToneChip(
                label: androidLabel(android),
                tone: androidTone(android),
                icon: Icons.android,
                spinning: android == 'building'),
          if (deploy != null)
            ToneChip(
                label: '${c('dev_queue.deploy_prefix')}$deploy',
                tone: statusTone('completed'),
                icon: Icons.cloud_done_outlined),
          if ((cost as num?) != null && cost != 0)
            ToneChip(label: rupee(cost), tone: statusTone('paused')),
          if (msgs > 0)
            ToneChip(
                label: '$msgs', tone: statusTone('awaiting_approval'), icon: Icons.chat_bubble_outline),
        ]),
      ]),
    );
  }
}

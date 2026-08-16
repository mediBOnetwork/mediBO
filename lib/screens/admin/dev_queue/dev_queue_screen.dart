import 'dart:async';
import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import '../../../utils/toast.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';
import 'dev_queue_bulk_add.dart';
import 'dev_queue_detail.dart';
import 'dev_queue_control.dart';
import 'dev_queue_gcp.dart';
import 'dev_queue_qa.dart';
import 'dev_queue_questions.dart';
import 'journey_library_screen.dart';
import 'memory_screen.dart';
import 'threads_screen.dart';

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
  Timer? _tick; // 1s ticker for live ATR countdown on building rows
  DateTime _now = DateTime.now();

  // Drafts inbox (generating / ready / failed)
  List<Map<String, dynamic>> _draftsReady = const [];
  List<Map<String, dynamic>> _draftsGenerating = const [];
  List<Map<String, dynamic>> _draftsFailed = const [];
  Timer? _draftPoll;
  int get _draftBadge => _draftsReady.length + _draftsGenerating.length + _draftsFailed.length;

  bool get _hasActive =>
      _rows.any((r) => r['status'] == 'building' || r['status'] == 'needs_input');

  @override
  void initState() {
    super.initState();
    _load();
    _loadDrafts();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_hasActive) _load(silent: true);
    });
    _draftPoll = Timer.periodic(const Duration(seconds: 8), (_) {
      _loadDrafts();
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _hasActive) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _draftPoll?.cancel();
    _tick?.cancel();
    _debounce?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _loadDrafts() async {
    try {
      final p = await _svc.draftsInbox();
      if (!mounted) return;
      setState(() {
        _draftsGenerating = ((p['generating'] as List?) ?? const [])
            .whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        _draftsReady = ((p['ready'] as List?) ?? const [])
            .whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        _draftsFailed = ((p['failed'] as List?) ?? const [])
            .whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      });
    } catch (_) {}
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
        actions: [
          if (_draftBadge > 0)
            Semantics(
              identifier: 'devq_drafts_inbox',
              button: true,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  IconButton(
                    tooltip: c('dev_queue.drafts_inbox_title'),
                    icon: const Icon(Icons.drafts_outlined, color: kBrand),
                    onPressed: () => _showDraftsInbox(context),
                  ),
                  Positioned(
                    top: Ds.space.x8,
                    right: Ds.space.x8,
                    child: Container(
                      padding: EdgeInsets.all(Ds.space.x4 - 1),
                      decoration: BoxDecoration(
                        color: Ds.c.danger,
                        shape: BoxShape.circle,
                      ),
                      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                      child: Text('$_draftBadge',
                          textAlign: TextAlign.center,
                          style: Ds.t.caption.copyWith(
                              fontSize: Ds.t.caption.fontSize! - 4,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          Semantics(
            identifier: 'devq_report_bug',
            button: true,
            child: IconButton(
              tooltip: c('dev_queue.bug_report_tooltip'),
              icon: const Icon(Icons.bug_report_outlined, color: kBrand),
              onPressed: () => showBugReportSheet(context, _svc),
            ),
          ),
          Semantics(
            identifier: 'devq_journey_library',
            button: true,
            child: IconButton(
              tooltip: c('dev_queue.journey_nav_label'),
              icon: const Icon(Icons.map_outlined, color: kBrand),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => JourneyLibraryScreen(service: _svc))),
            ),
          ),
          Semantics(
            identifier: 'devq_gcp_open',
            button: true,
            child: IconButton(
              tooltip: c('dev_queue.gcp_open'),
              icon: const Icon(Icons.cloud_outlined, color: kBrand),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => GcpControlScreen(service: _svc))),
            ),
          ),
          Semantics(
            identifier: 'devq_memory_open',
            button: true,
            child: IconButton(
              tooltip: c('dev_queue.memory_nav_label'),
              icon: const Icon(Icons.memory_outlined, color: kBrand),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => MemoryScreen(service: _svc))),
            ),
          ),
          Semantics(
            identifier: 'devq_threads_open',
            button: true,
            child: IconButton(
              tooltip: c('dev_queue.threads_nav_label'),
              icon: const Icon(Icons.forum_outlined, color: kBrand),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ThreadsScreen(service: _svc))),
            ),
          ),
        ],
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
      // One scroll surface — the control strip, search and filters scroll away
      // with the rows so nothing is trapped behind a fixed header (the whole
      // Dev Queue page scrolls as one, on mobile and desktop alike).
      body: SafeArea(
        child: RefreshIndicator(
          color: kBrand,
          onRefresh: _load,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // CHANGE #73 — the GCP Control banner card was removed; the AppBar
              // cloud icon is now the single entry point (the card was a
              // duplicate that ate screen space).
              SliverToBoxAdapter(child: DevQueueControl(service: _svc)),
              if (_draftBadge > 0)
                SliverToBoxAdapter(child: _draftsStrip()),
              SliverToBoxAdapter(child: _header()),
              SliverToBoxAdapter(child: _filters()),
              if (_status == 'cancelled' && _rows.isNotEmpty)
                SliverToBoxAdapter(child: _clearBar()),
              if (_loading)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(top: 80),
                    child: Center(child: CircularProgressIndicator(color: kBrand)),
                  ),
                )
              else if (_rows.isEmpty)
                SliverToBoxAdapter(child: _empty())
              else if (reorderable)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                  sliver: SliverReorderableList(
                    itemCount: _rows.length,
                    onReorder: _reorder,
                    itemBuilder: (ctx, i) => Padding(
                      key: ValueKey(_rows[i]['id']),
                      padding: const EdgeInsets.only(bottom: 12),
                      child: ReorderableDelayedDragStartListener(
                        index: i,
                        child: _Row(
                            row: _rows[i],
                            now: _now,
                            draggable: true,
                            onTap: () => _openDetail(_rows[i])),
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                  sliver: SliverList.separated(
                    itemCount: _rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (ctx, i) => _Row(
                        row: _rows[i],
                        now: _now,
                        onTap: () => _openDetail(_rows[i]),
                        onDelete: _rows[i]['status'] == 'cancelled'
                            ? () => _delete(_rows[i])
                            : null),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDraftsInbox(BuildContext ctx) {
    showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DraftsInboxSheet(
        service: _svc,
        generating: _draftsGenerating,
        ready: _draftsReady,
        failed: _draftsFailed,
        onRefresh: _loadDrafts,
        onQueued: () {
          Navigator.of(ctx).pop();
          _load();
        },
      ),
    ).then((_) => _loadDrafts());
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
          borderSide: const BorderSide(color: kBorder),
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

  Widget _empty() => Padding(
        padding: const EdgeInsets.only(top: 80, bottom: 40),
        child: Column(children: [
          Icon(Icons.inbox_outlined,
              size: 56, color: kTextLo.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text(c('dev_queue.empty_title'),
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: kTextHi)),
          const SizedBox(height: 6),
          Text(c('dev_queue.empty_body'),
              style: const TextStyle(fontSize: 13, color: kTextLo)),
        ]),
      );

  // Compact strip shown in the scrollable body when drafts exist.
  Widget _draftsStrip() {
    final readyCount = _draftsReady.length;
    final genCount = _draftsGenerating.length;
    final failCount = _draftsFailed.length;
    final parts = <String>[
      if (genCount > 0) '$genCount ${c('dev_queue.draft_generating_label').toLowerCase()}',
      if (readyCount > 0) '$readyCount ${c('dev_queue.draft_ready_label').toLowerCase()}',
      if (failCount > 0) '$failCount ${c('dev_queue.draft_failed_label').toLowerCase()}',
    ];
    final accent = readyCount > 0 ? Ds.c.success : genCount > 0 ? Ds.c.info : Ds.c.danger;
    final bg = readyCount > 0 ? Ds.c.successSoft : genCount > 0 ? Ds.c.infoSoft : Ds.c.dangerSoft;
    return InkWell(
      onTap: () => _showDraftsInbox(context),
      child: Container(
        margin: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x8, Ds.space.x16, 0),
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x12, vertical: Ds.space.x8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: accent, width: 0.5),
        ),
        child: Row(children: [
          if (genCount > 0 && readyCount == 0)
            SizedBox(
              width: Ds.space.x12 + 2,
              height: Ds.space.x12 + 2,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: Ds.c.info),
            )
          else
            Icon(
              readyCount > 0 ? Icons.drafts_outlined : Icons.error_outline,
              size: Ds.space.x16,
              color: accent,
            ),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: Text(
              '${c('dev_queue.drafts_inbox_title')}: ${parts.join(', ')}',
              style: Ds.t.caption.copyWith(fontWeight: FontWeight.w600, color: accent),
            ),
          ),
          Icon(Icons.chevron_right, size: Ds.space.x16, color: accent),
        ]),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final Map<String, dynamic> row;
  final DateTime now;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final bool draggable;
  const _Row(
      {required this.row,
      required this.now,
      required this.onTap,
      this.onDelete,
      this.draggable = false});

  /// Live "time left" chip (building) or "time taken" chip (done), driven by the
  /// backend's eta_at / ttt_display. The countdown is client-ticked to the
  /// server anchor; the estimate itself is the backend's.
  Widget? _timingChip(String status) {
    if (status == 'building') {
      // CHANGE #68 — Claude's estimate (has_eta) drives the countdown, anchored
      // to the backend's eta_at. Rows not reporting an estimate show plain
      // elapsed — never a fake countdown from elapsed time.
      final hasEta = row['has_eta'] == true;
      final eta = DateTime.tryParse((row['eta_at'] ?? '').toString());
      if (hasEta && eta != null) {
        final rem = eta.difference(now);
        final over = rem.isNegative || rem == Duration.zero;
        final s = over ? 0 : rem.inSeconds;
        final label = over
            ? '${row['tat_display'] ?? ''} · ${c('dev_queue.atr_overrun')}'
            : '${(s ~/ 60)}:${(s % 60).toString().padLeft(2, '0')} ${c('dev_queue.atr_label').toLowerCase()}';
        return ToneChip(
            label: label,
            tone: statusTone(over ? 'awaiting_approval' : 'building'),
            icon: Icons.hourglass_bottom);
      }
      final elapsed = (row['elapsed_display'] ?? '').toString();
      if (elapsed.isEmpty) return null;
      return ToneChip(
          label: '$elapsed ${c('dev_queue.elapsed_label').toLowerCase()}',
          tone: statusTone('building'),
          icon: Icons.timelapse_outlined);
    }
    final ttt = (row['ttt_display'] ?? '').toString();
    if (ttt.isNotEmpty && (status == 'completed' || status == 'failed')) {
      return ToneChip(
          label: ttt, tone: statusTone('paused'), icon: Icons.timer_outlined);
    }
    return null;
  }

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
    final age = (row['age_display'] ?? '').toString();
    final tone = statusTone(status);

    final claimedBy = (row['claimed_by'] ?? '').toString();
    final timing = _timingChip(status);
    final footer = <Widget>[
      if (status == 'building' && claimedBy.isNotEmpty)
        ToneChip(
            label: claimedBy,
            tone: statusTone('building'),
            icon: Icons.terminal),
      if (timing != null) timing,
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
      if ((row['route_label'] ?? '').toString().isNotEmpty)
        ToneChip(
            label: (row['route_label']).toString(),
            tone: toneByName((row['route_tone'] ?? 'neutral').toString()),
            icon: routeIcon((row['route'] ?? '').toString())),
      if ((row['area_label'] ?? '').toString().isNotEmpty)
        ToneChip(
            label: (row['area_label']).toString(),
            tone: statusTone('paused'),
            icon: Icons.category_outlined),
      if ((row['speed_display'] ?? '').toString().isNotEmpty)
        ToneChip(
            label: (row['speed_display']).toString(),
            tone: statusTone('completed'),
            icon: Icons.bolt),
      if (batch.isNotEmpty)
        ToneChip(label: batch, tone: statusTone('paused'), icon: Icons.label_outline),
      if (android != 'not_requested')
        ToneChip(
            label: androidLabel(android),
            tone: androidTone(android),
            icon: Icons.android,
            spinning: android == 'building'),
      if (row['has_tokens'] == true)
        ToneChip(
            label: '${row['tokens_display'] ?? ''} · ${row['cost_display'] ?? ''}',
            tone: statusTone('paused'),
            icon: Icons.data_usage),
      if (row['has_tokens'] == true && priceModelChip(row).isNotEmpty)
        ToneChip(
            label: priceModelChip(row),
            tone: statusTone('building'),
            icon: Icons.memory),
      if (msgs > 0)
        ToneChip(
            label: '$msgs',
            tone: statusTone('awaiting_approval'),
            icon: Icons.chat_bubble_outline),
      // Bug-Loop Prevention chips — all rendered verbatim from dev_cmd_list.
      if ((row['qa_chip'] ?? '').toString().isNotEmpty)
        ToneChip(
            label: (row['qa_chip']).toString(),
            tone: toneByName((row['qa_tone'] ?? 'neutral').toString())),
      if ((row['preview_chip'] ?? '').toString().isNotEmpty)
        ToneChip(
            label: (row['preview_chip']).toString(),
            tone: toneByName((row['preview_tone'] ?? 'neutral').toString())),
      if ((row['journey_chip'] ?? '').toString().isNotEmpty)
        ToneChip(
            label: (row['journey_chip']).toString(),
            tone: statusTone('completed')),
    ];

    return DqCard(
      onTap: onTap,
      accent: tone.fg,
      padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          ToneChip(
            label: statusLabel(status),
            tone: tone,
            spinning: status == 'building',
          ),
          const SizedBox(width: 8),
          Text('#$id',
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: kTextLo)),
          if (deploy != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFD1FAE5),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.cloud_done_outlined,
                    size: 13, color: Color(0xFF065F46)),
                const SizedBox(width: 4),
                Text('${c('dev_queue.change_prefix')}$deploy',
                    style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF065F46))),
              ]),
            ),
          ],
          const Spacer(),
          if (age.isNotEmpty && !draggable && onDelete == null)
            Text(age,
                style: const TextStyle(fontSize: 11.5, color: kTextLo)),
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
        const SizedBox(height: 10),
        Text((row['title'] ?? '').toString(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                height: 1.3,
                color: kTextHi)),
        if (footer.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: footer),
        ],
      ]),
    );
  }
}

/// Bottom sheet listing generating, ready, and failed drafts. Tapping a ready
/// draft opens the Questions screen so Om can answer and queue the command.
class _DraftsInboxSheet extends StatefulWidget {
  final DevQueueService service;
  final List<Map<String, dynamic>> generating;
  final List<Map<String, dynamic>> ready;
  final List<Map<String, dynamic>> failed;
  final VoidCallback onRefresh;
  final VoidCallback onQueued;

  const _DraftsInboxSheet({
    required this.service,
    required this.generating,
    required this.ready,
    required this.failed,
    required this.onRefresh,
    required this.onQueued,
  });

  @override
  State<_DraftsInboxSheet> createState() => _DraftsInboxSheetState();
}

class _DraftsInboxSheetState extends State<_DraftsInboxSheet> {
  late List<Map<String, dynamic>> _generating = widget.generating;
  late List<Map<String, dynamic>> _ready = widget.ready;
  late List<Map<String, dynamic>> _failed = widget.failed;
  Timer? _poll;
  final Set<int> _retrying = {};

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 6), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final p = await widget.service.draftsInbox();
      if (!mounted) return;
      setState(() {
        _generating = ((p['generating'] as List?) ?? const [])
            .whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        _ready = ((p['ready'] as List?) ?? const [])
            .whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        _failed = ((p['failed'] as List?) ?? const [])
            .whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      });
      widget.onRefresh();
    } catch (_) {}
  }

  Future<void> _openReady(Map<String, dynamic> draft) async {
    final id = (draft['id'] as num?)?.toInt() ?? 0;
    final spec = (draft['spec'] ?? '').toString();
    final queued = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => DevQueueQuestions(
        service: widget.service,
        draftId: id,
        spec: spec,
        mode: 'auto',
        count: null,
        opts: const {},
      ),
    ));
    if (queued == true) widget.onQueued();
    _refresh();
  }

  Future<void> _retry(Map<String, dynamic> draft) async {
    final id = (draft['id'] as num?)?.toInt() ?? 0;
    if (_retrying.contains(id)) return;
    setState(() => _retrying.add(id));
    try {
      final spec = (draft['spec'] ?? '').toString();
      final mode = (draft['mode'] ?? 'auto').toString();
      final opts = Map<String, dynamic>.from((draft['opts'] as Map?) ?? {});
      final res = await widget.service.draftCreate(spec, mode, null, opts);
      if (!mounted) return;
      final newId = (res['id'] as num?)?.toInt() ?? 0;
      if (newId > 0) {
        showToast(context, c('dev_queue.draft_toast_generating'));
      } else {
        showToast(context, (res['error'] ?? '').toString(), isError: true);
      }
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _retrying.remove(id));
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final allEmpty = _generating.isEmpty && _ready.isEmpty && _failed.isEmpty;
    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.rSheet.topLeft.x)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Handle
        Container(
          margin: EdgeInsets.symmetric(vertical: Ds.space.x8 + 2),
          width: Ds.space.x32 + 4,
          height: Ds.space.x4,
          decoration: BoxDecoration(color: kBorder, borderRadius: Ds.r.rButton),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(Ds.space.x16, 0, Ds.space.x16, Ds.space.x12),
          child: Row(children: [
            Icon(Icons.drafts_outlined, size: Ds.space.x16 + 4, color: kBrand),
            SizedBox(width: Ds.space.x8),
            Text(c('dev_queue.drafts_inbox_title'), style: Ds.t.subtitle),
          ]),
        ),
        const Divider(height: 1),
        if (allEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: Ds.space.x32),
            child: Column(children: [
              Icon(Icons.check_circle_outline,
                  size: Ds.space.x32 + Ds.space.x8, color: kTextLo.withValues(alpha: 0.4)),
              SizedBox(height: Ds.space.x12),
              Text(c('dev_queue.empty_title'), style: Ds.t.caption),
            ]),
          )
        else
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.6,
            ),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x24),
              children: [
                ..._generating.map((d) => _genTile(d)),
                ..._ready.map((d) => _readyTile(d)),
                ..._failed.map((d) => _failedTile(d)),
              ],
            ),
          ),
      ]),
    );
  }

  Widget _genTile(Map<String, dynamic> d) => _tile(
        spec: (d['spec'] ?? '').toString(),
        leading: SizedBox(
          width: Ds.space.x16 + 2,
          height: Ds.space.x16 + 2,
          child: CircularProgressIndicator(strokeWidth: 2, color: Ds.c.info),
        ),
        labelText: c('dev_queue.draft_generating_label'),
        labelColor: Ds.c.info,
        bgColor: Ds.c.infoSoft,
      );

  Widget _readyTile(Map<String, dynamic> d) => _tile(
        spec: (d['spec'] ?? '').toString(),
        leading: Icon(Icons.check_circle_outline, size: Ds.space.x16 + 2, color: Ds.c.success),
        labelText: c('dev_queue.draft_ready_label'),
        labelColor: Ds.c.success,
        bgColor: Ds.c.successSoft,
        trailing: Text(c('dev_queue.draft_tap_hint'),
            style: Ds.t.caption.copyWith(color: Ds.c.success, fontWeight: FontWeight.w600)),
        onTap: () => _openReady(d),
      );

  Widget _failedTile(Map<String, dynamic> d) {
    final id = (d['id'] as num?)?.toInt() ?? 0;
    return _tile(
      spec: (d['spec'] ?? '').toString(),
      leading: Icon(Icons.error_outline, size: Ds.space.x16 + 2, color: Ds.c.danger),
      labelText: c('dev_queue.draft_failed_label'),
      labelColor: Ds.c.danger,
      bgColor: Ds.c.dangerSoft,
      trailing: _retrying.contains(id)
          ? SizedBox(
              width: Ds.space.x16,
              height: Ds.space.x16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Ds.c.danger))
          : TextButton(
              onPressed: () => _retry(d),
              style: TextButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
                  foregroundColor: Ds.c.danger),
              child: Text(c('dev_queue.draft_retry_btn'),
                  style: Ds.t.caption.copyWith(fontWeight: FontWeight.w700, color: Ds.c.danger)),
            ),
    );
  }

  Widget _tile({
    required String spec,
    required Widget leading,
    required String labelText,
    required Color labelColor,
    required Color bgColor,
    Widget? trailing,
    VoidCallback? onTap,
  }) =>
      Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x8),
        child: InkWell(
          onTap: onTap,
          borderRadius: Ds.r.rCard,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x12 + 2, vertical: Ds.space.x12),
            decoration: BoxDecoration(color: bgColor, borderRadius: Ds.r.rCard),
            child: Row(children: [
              leading,
              SizedBox(width: Ds.space.x8 + 2),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: Ds.space.x8 - 2, vertical: Ds.space.x4 - 2),
                    decoration: BoxDecoration(
                      color: Ds.c.surface.withValues(alpha: 0.6),
                      borderRadius: Ds.r.rButton,
                    ),
                    child: Text(labelText,
                        style: Ds.t.caption.copyWith(
                            fontWeight: FontWeight.w700, color: labelColor)),
                  ),
                  SizedBox(height: Ds.space.x4),
                  Text(spec,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.body.copyWith(fontWeight: FontWeight.w500)),
                ]),
              ),
              if (trailing != null) ...[SizedBox(width: Ds.space.x8), trailing],
            ]),
          ),
        ),
      );
}

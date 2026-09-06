import 'dart:async';
import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import '../../../utils/render_log.dart';
import '../../../utils/toast.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';
import 'restart_safety.dart';
import 'dev_queue_bulk_add.dart';
import 'dev_queue_detail.dart';
import 'dev_queue_control.dart';
import 'dev_queue_gcp.dart';
import 'dev_queue_qa.dart';
import 'dev_queue_questions.dart';
import 'cron_health_screen.dart';
import 'runner_ops/runner_ops_card.dart';
import 'strip_v3/strip_v3_card.dart';
import '../admin_heartbeat_screen.dart';        // CHANGE #468
import '../test_mode_screen.dart';             // CHANGE #573, wired #468
import 'journey_library_screen.dart';
import 'triage_inbox_screen.dart';
import 'test_coverage_screen.dart';   // CHANGE #634
import 'journey_bot_screen.dart';     // CHANGE #635
import 'visual_baselines_screen.dart'; // CHANGE #637
import 'play_store_screen.dart';
import 'signin_diag_screen.dart';
import 'memory_screen.dart';
import 'threads_screen.dart';
import '../ops_runbooks_screen.dart';           // CHANGE #474
import 'chaos_lab_screen.dart';
import 'dev_tools_sheet.dart';

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
  /// CHANGE #887 — the list is BOUNDED (list_limits.cards_max, then a 48 kB
  /// payload budget), so a page is the top of the list, not all of it. The
  /// backend words the line; this renders it verbatim, or nothing when empty.
  String _truncNote = '';
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
    // CHANGE #643 — 30 s, and a DELTA. At 5 s this screen was re-reading every
    // command in the queue twelve times a minute; the poll is now both slower
    // and much smaller, and a row that has not moved is not sent at all.
    _poll = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_hasActive) _load(silent: true, delta: true);
    });
    _draftPoll = Timer.periodic(const Duration(seconds: 8), (_) {
      _loadDrafts();
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _hasActive) setState(() => _now = DateTime.now());
    });
    _openDeepLinkedCommand();
    _openDeepLinkedTool();
  }

  /// CHANGE #1802 — `/admin/dev-queue?cmd=1802` opens that command's detail.
  ///
  /// A command's detail screen had no address. Every proof of something built
  /// there — the QA section, the spec checklist, the Android release block —
  /// had to be reached by TAPPING a card, and a Flutter canvas cannot be
  /// tapped by the headless capture the runner uses, so the one screen that
  /// carries the evidence was the one screen that could not be photographed.
  /// The id travels in the query string, which #1365 already taught the router
  /// not to throw away.
  Future<void> _openDeepLinkedCommand() async {
    final raw = Uri.base.queryParameters['cmd'];
    final id = int.tryParse(raw ?? '');
    if (id == null || id <= 0) return;
    // After the first frame, and after the list has loaded, so the detail
    // opens over a populated screen rather than a spinner.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    Map<String, dynamic> row = const {};
    try {
      final hit = _rows.firstWhere((r) => asInt(r['id']) == id,
          orElse: () => const <String, dynamic>{});
      row = Map<String, dynamic>.from(hit);
    } catch (_) {/* the detail reads the row itself */}
    if (!mounted) return;
    await _openDetail({'id': id, ...row});
  }

  /// CHANGE #637 — `/admin/dev-queue?tool=visual_baselines` opens that dev
  /// tool.
  ///
  /// The same hole #1802 closed for a command's detail, one level down: every
  /// dev tool is behind the tools sheet, which is behind a header tap, and a
  /// Flutter canvas cannot be tapped by the headless capture the runner uses.
  /// So a tool screen was reachable by a human and by nothing else, and the
  /// reachability proof §11 demands could never be a picture of the screen.
  /// The key travels in the query string; a key this build does not know opens
  /// nothing, exactly as `openDevTool` already reports for one it cannot route.
  Future<void> _openDeepLinkedTool() async {
    final key = (Uri.base.queryParameters['tool'] ?? '').trim();
    if (key.isEmpty || !kDevToolKeys.contains(key)) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    openDevTool(context, key, service: _svc, onDraftsQueued: _loadDrafts);
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

  /// The cursor the backend handed back on the last read. A delta poll asks for
  /// "what has moved since this", and the backend answers with its own clock —
  /// the client never invents a timestamp.
  String? _since;

  Future<void> _load({bool silent = false, bool delta = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final p = await _svc.list(
        status: _status,
        search: _searchCtl.text.trim(),
        batch: _batch,
        limit: _pageSize,
        updatedSince: delta ? _since : null,
      );
      if (!mounted) return;
      final incoming = ((p['rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      setState(() {
        _title = (p['screen_title'] as String?) ?? _title;
        _since = (p['server_time'] as String?) ?? _since;
        if (p['is_delta'] == true) {
          // Patch in place, in the order we already have. A row the backend
          // did not send did not move, so it stays exactly as it was.
          for (final r in incoming) {
            final id = asInt(r['id']);
            final i = _rows.indexWhere((x) => asInt(x['id']) == id);
            if (i >= 0) {
              _rows[i] = r;
            } else {
              _rows.insert(0, r);
            }
          }
        } else {
          _rows = incoming;
        }
        _counts = ((p['counts'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k.toString(), asInt(v)));
        _truncNote = (p['truncated_note'] as String?) ?? '';
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// One page. The rg guard `c643_dev_cmd_list_payload_small` asserts this page
  /// stays under 50 kB, so a detail field added back to the card turns the
  /// regression guard red in the command that added it.
  static const _pageSize = 25;

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
    // CHANGE #349 — one entry point where nine bare glyphs used to be.
    RenderLog.write('c349_tools_button', 1);
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
          // CHANGE #349 — ONE entry point, not nine bare glyphs.
          //
          // This row used to hold nine IconButtons. `actions:` is a Row: it
          // does not wrap and it does not scroll, so on a phone the last tools
          // were rendered past the right edge and could not be reached at all,
          // and the ones that fitted carried no label. Every tool now lives in
          // the registry and opens from the labelled sheet below, where the
          // list scrolls and each row is the full width of the sheet.
          Padding(
            padding: EdgeInsets.only(right: Ds.space.x8),
            child: Semantics(
              identifier: 'devq_tools',
              button: true,
              child: SizedBox(
                height: Ds.space.x48,
                child: TextButton.icon(
                  onPressed: _openTools,
                  icon: _draftBadge > 0
                      ? Badge(
                          label: Text('$_draftBadge'),
                          child: const Icon(Icons.handyman_outlined,
                              color: kBrand))
                      : const Icon(Icons.handyman_outlined, color: kBrand),
                  label: Text(c('dev_tools.button'),
                      style: Ds.t.bodyStrong.copyWith(color: kBrand)),
                ),
              ),
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
              SliverToBoxAdapter(
                child: Column(children: [
                  // CHANGE #1570 — ONE runner card.
                  //
                  // #1367 stacked the v3 strip ABOVE the v2 control card
                  // rather than replacing it, because v2 owned surfaces v3
                  // did not (the breaker, usage, health, the worker grid,
                  // context economy) and swapping it out wholesale would have
                  // cost a day's working screen. The consequence was two
                  // runner cards at the top of Dev Queue with two sets of the
                  // same three toggles. Neither had to go: v2 is EMBEDDED in
                  // v3 now, as its footer, minus its own chrome and minus the
                  // three toggles v3 already draws with `actual` beside
                  // `desired`. Same surfaces, one card.
                  StripV3Card(
                    footer: DevQueueControl(
                      service: _svc,
                      embedded: true,
                      // CHANGE #1197 — ?panel=runner lands with the runner
                      // panel already open, so its contents can be
                      // photographed and can write their render-log keys at
                      // all.
                      startExpanded:
                          Uri.base.queryParameters['panel'] == 'runner',
                    ),
                  ),
                  // CHANGE #1368 — the policies sit directly under the strip,
                  // and in that order on purpose: the strip answers "is it
                  // running?", this answers "should it be, right now?". A
                  // blocked claim is meaningless until you can see which
                  // policy is doing the blocking, so the two are read together.
                  // (#1570 folded the old control card INTO the strip above;
                  // this one stays its own card because it answers a different
                  // question.)
                  const RunnerOpsCard(),
                ]),
              ),
              if (_draftBadge > 0)
                SliverToBoxAdapter(child: _draftsStrip()),
              SliverToBoxAdapter(child: _header()),
              SliverToBoxAdapter(child: _filters()),
              if (!_loading && _truncNote.isNotEmpty)
                SliverToBoxAdapter(child: _truncBanner()),
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

  /// CHANGE #349 — the labelled tools sheet. `dev_tools()` decides what may
  /// appear; [kDevToolKeys] decides what this build can open. A tool that
  /// fails either gate simply is not on the sheet.
  void _openTools() {
    showDevToolsSheet(
      context,
      load: _svc.devTools,
      available: kDevToolKeys,
      onOpen: (tool) => openDevTool(
        context,
        (tool['tool_key'] ?? '').toString(),
        service: _svc,
        onDraftsQueued: _load,
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

  /// The bound, said out loud. The list is capped by list_limits.cards_max and
  /// then by the payload budget, so a page is the TOP of the registry, not all
  /// of it. `truncated_note` is composed in the backend (ui_copy
  /// `dev_queue.list_truncated`) and printed here verbatim — the app never
  /// counts rows and never words this sentence.
  Widget _truncBanner() => Padding(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x4, Ds.space.x16, Ds.space.x8),
        child: Text(_truncNote, style: Ds.t.caption),
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
      final hasEta = RowLiveness(row).showCountdown;
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
    final live = RowLiveness(row);
    final finish = RowFinish(row);
    final timing = _timingChip(status);
    final footer = <Widget>[
      // A worker name next to a dead heartbeat is the exact lie #229/#230 told
      // for hours after a VM restart. RowLiveness.showWorker gates it on the
      // backend's is_live verdict — see restart_safety.dart (CHANGE #233).
      if (live.showWorker)
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
      // CHANGE #656: the model/effort chip is on EVERY card, not only one that
      // has spent tokens — a pending row has to show what it will build on.
      if (priceModelChip(row).isNotEmpty)
        ToneChip(
            label: priceModelChip(row),
            tone: statusTone('building'),
            icon: Icons.memory),
      if (msgs > 0)
        ToneChip(
            label: '$msgs',
            tone: statusTone('awaiting_approval'),
            icon: Icons.chat_bubble_outline),
      // CHANGE #233 — restart-safety chips, in RowLiveness's order (worst news
      // first). Every string, including the pluralisation and the age, is
      // composed by dev_cmd_list from ui_copy; Dart picks only the glyph.
      for (final ch in live.chips)
        ToneChip(
            label: ch.label,
            tone: toneByName(ch.tone),
            icon: safetyChipIcon(ch.kind)),
      // Bug-Loop Prevention chips — all rendered verbatim from dev_cmd_list.
      if ((row['qa_chip'] ?? '').toString().isNotEmpty)
        ToneChip(
            label: (row['qa_chip']).toString(),
            tone: toneByName((row['qa_tone'] ?? 'neutral').toString())),
      // CHANGE #1674 — the GRADE. Every command was xlarge because size_class
      // was read off the spec's character count, so a two-file fix bought the
      // same hostile QA as a schema rewrite and nothing on the card said so.
      // dev_cmd_grade re-grades from the real diff and composes this sentence;
      // Dart prints it and picks the glyph.
      if ((row['grade_chip'] ?? '').toString().isNotEmpty)
        ToneChip(
            label: (row['grade_chip']).toString(),
            tone: toneByName((row['grade_tone'] ?? 'info').toString()),
            icon: Icons.straighten),
      if ((row['preview_chip'] ?? '').toString().isNotEmpty)
        ToneChip(
            label: (row['preview_chip']).toString(),
            tone: toneByName((row['preview_tone'] ?? 'neutral').toString())),
      if ((row['journey_chip'] ?? '').toString().isNotEmpty)
        ToneChip(
            label: (row['journey_chip']).toString(),
            tone: statusTone('completed')),
      // CHANGE #369 — the finish gate. While a build sits with every condition
      // observed the card says it is closing itself; afterwards it says the
      // harness, not the model, closed it. Both sentences are composed by
      // dev_cmd_list from ui_copy — Dart adds only the glyph.
      if (finish.show)
        ToneChip(
            label: finish.label,
            tone: toneByName(finish.tone),
            icon: Icons.task_alt),
      // CHANGE #327 — the auto-chain. A pending command whose predicted files
      // collide with something in flight says so on its own card: it is queued
      // behind that command, not parked mid-build against a lease. The sentence
      // (and the id list inside it) is composed by dev_cmd_autochain from
      // ui_copy; Dart adds only the glyph.
      if ((row['chain_chip'] ?? '').toString().isNotEmpty)
        ToneChip(
            label: (row['chain_chip']).toString(),
            tone: toneByName((row['chain_tone'] ?? 'info').toString()),
            icon: Icons.link),
      // CHANGE #571 — a parked command is WAITING, not failed. The chip, its
      // wording and its tone all come from dev_cmd_list; the card just prints
      // them, so a wait can never read as a failure again.
      if (WaitView.fromRow(row).chip.isNotEmpty)
        ToneChip(
            label: WaitView.fromRow(row).chip,
            tone: WaitView.fromRow(row).tone,
            icon: Icons.pause_circle_outline),
      // CHANGE #571 — the command's own spec checklist, so an unbuilt spec
      // item is visible on the queue instead of hiding inside a summary.
      if ((row['spec_chip'] ?? '').toString().isNotEmpty)
        ToneChip(
            label: (row['spec_chip']).toString(),
            tone: toneByName((row['spec_tone'] ?? 'neutral').toString()),
            icon: Icons.checklist_rtl),
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


/// CHANGE #349 — every Dev Queue tool this build can open, by the registry's
/// own `route_key`.
///
/// It is the SECOND half of the gate. `dev_tools()` says which tools the
/// registry admits; this set says which of those the running app actually has
/// a screen for. A key in neither place cannot be reached, and a labelled row
/// that would do nothing is never drawn.
const Set<String> kDevToolKeys = <String>{
  'journey_library',
  // CHANGE #639 — Triage. The chaos lab, the visual bot and the safety net all
  // FIND things; this is the one screen where a person says which of them are
  // real. Approving here is what generates the fix command.
  'triage',
  // CHANGE #634 — the coverage ledger. It sits in the same group as the
  // Journey Library on purpose: journeys are what the bot runs, coverage is
  // the list of what it has never run.
  'test_coverage',
  // CHANGE #635 — the journey bot: what the coverage ledger says has never
  // been tested is the list; this is the run that tests it, every role and
  // every hostile variant, with the gaps it filed.
  'journey_bot',
  // CHANGE #637 — the visual-regression review queue: what every registered
  // screen looks like now, beside the picture Om approved.
  'visual_baselines',
  // CHANGE #638 — the chaos lab: seven scripted failures, and Om's own
  // walkthroughs turned into permanent tests.
  'chaos_lab',
  'bug_report',
  'drafts_inbox',
  'cron_health',
  'test_mode',
  'heartbeat',
  'signin_diag',
  'gcp_control',
  'memory',
  'threads',
  'play_store',
  // CHANGE #474 — Failure drills. It belongs to this family, beside Cron
  // health, Test mode and the daily heartbeat: the things that tell an
  // operator whether the platform is still standing up.
  'runbooks',
};

/// Open one registered tool. Returns false for a key this build does not know,
/// so a caller can render the backend's `dev_tools.not_registered` copy rather
/// than doing nothing silently.
bool openDevTool(
  BuildContext context,
  String toolKey, {
  DevQueueService? service,
  VoidCallback? onDraftsQueued,
}) {
  final svc = service ?? DevQueueService();
  void push(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  switch (toolKey) {
    case 'journey_library':
      push(JourneyLibraryScreen(service: svc));
      return true;
    case 'triage':
      push(TriageInboxScreen(service: svc));
      return true;
    case 'test_coverage':
      push(TestCoverageScreen(service: svc));
      return true;
    case 'journey_bot':
      push(JourneyBotScreen(service: svc));
      return true;
    case 'visual_baselines':
      push(VisualBaselinesScreen(service: svc));
      return true;
    case 'chaos_lab':
      push(ChaosLabScreen(service: svc));
      return true;
    case 'bug_report':
      showBugReportSheet(context, svc);
      return true;
    case 'drafts_inbox':
      showDraftsInboxSheet(context, svc, onQueued: onDraftsQueued);
      return true;
    case 'cron_health':
      push(CronHealthScreen(service: svc));
      return true;
    // CHANGE #468 — devtool.test_mode has been in the registry since #573 with
    // no case here, so the tools sheet DROPPED it every time (an unopenable
    // key is never drawn) and it was reachable only from the admin shell. The
    // widened registry test found it; this is the missing door.
    case 'test_mode':
      push(const TestModeScreen());
      return true;
    // CHANGE #468 — the daily canary: one synthetic order walking the whole
    // pipeline, every stage with its own timeout, the first failure alerting.
    case 'heartbeat':
      push(const AdminHeartbeatScreen());
      return true;
    case 'signin_diag':
      push(SignInDiagScreen(service: svc));
      return true;
    case 'gcp_control':
      push(GcpControlScreen(service: svc));
      return true;
    case 'memory':
      push(MemoryScreen(service: svc));
      return true;
    case 'threads':
      push(ThreadsScreen(service: svc));
      return true;
    case 'play_store':
      push(PlayStoreScreen(service: svc));
      return true;
    // CHANGE #474 — the six external dependencies mediBO does not own, what
    // happens by itself when each one breaks, and the last time the fallback
    // was proved by deliberately breaking it. Authorisation is not the door:
    // ops_runbooks_home() and ops_runbook_drill() gate on _ops_admin() and
    // answer anyone else with their own refusal sentence.
    case 'runbooks':
      push(const OpsRunbooksScreen());
      return true;
  }
  return false;
}

/// The drafts inbox, opened from anywhere (the tools sheet, the command
/// palette) rather than only from inside the Dev Queue screen's own state.
Future<void> showDraftsInboxSheet(
  BuildContext context,
  DevQueueService svc, {
  VoidCallback? onQueued,
}) async {
  Map<String, dynamic> p = const <String, dynamic>{};
  try {
    p = await svc.draftsInbox();
  } catch (_) {}
  if (!context.mounted) return;
  List<Map<String, dynamic>> l(String k) => ((p[k] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetCtx) => _DraftsInboxSheet(
      service: svc,
      generating: l('generating'),
      ready: l('ready'),
      failed: l('failed'),
      onRefresh: () {},
      onQueued: () {
        Navigator.of(sheetCtx).pop();
        onQueued?.call();
      },
    ),
  );
}

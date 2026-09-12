import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// CMD #1843 — WIRING ONLY.
///
/// Two finished, render-ready backends had no screen at all: the merge lane's
/// BATCH history (`deploy_lane_batches` — including the "N batches failed in a
/// row, nothing is reaching production" streak) and the monthly cloud-waste
/// scan (`dev_cloud_waste_get`). Remote Control health (`dev_rc_health`) had
/// none either, and it is a banner by nature, so it sits above them.
///
/// Everything else the original audit listed turned out to be drawn already —
/// the audit was taken against a stale `main`. `runner_ops_card` is
/// RunnerOpsCard (#1368); `runner_health_card`, `runner_disk_state`,
/// `build_branch_card`, `runner_blocked_badge` and `dev_context_metrics` all
/// arrive inside `dev_ctl_get()` and are drawn by DevQueueControl on this same
/// screen; `strip_v3_card` is StripV3Card; `runner_boot_status`,
/// `deploy_lane_status` and `dev_agent_sessions_status` are the Cron health
/// screen. Wiring them again would have put two of each on one page — the
/// exact bug #1570 was raised to remove — so they are deliberately not here.
///
/// This file is a PRINTER. Every word, number, rupee figure, tone and heading
/// below arrives inside a payload; nothing is worded, totalled, sorted or
/// inferred here. Rows render in payload order, and a `has:false` payload draws
/// nothing at all rather than an invented empty state.
class DevQueueOps extends StatefulWidget {
  final DevQueueService service;
  const DevQueueOps({super.key, required this.service});

  @override
  State<DevQueueOps> createState() => _DevQueueOpsState();
}

class _DevQueueOpsState extends State<DevQueueOps> {
  Map<String, dynamic> _batches = const {};
  Map<String, dynamic> _waste = const {};
  Map<String, dynamic> _rc = const {};

  bool _wasteOpen = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    // The lane moves on the merge worker's clock, not the reader's.
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    Future<Map<String, dynamic>> safe(
        Future<Map<String, dynamic>> Function() f) async {
      try {
        return await f();
      } catch (_) {
        return const <String, dynamic>{};
      }
    }

    final r = await Future.wait([
      safe(widget.service.deployLaneBatches),
      safe(widget.service.cloudWasteGet),
      safe(widget.service.rcHealth),
    ]);
    if (!mounted) return;
    setState(() {
      _batches = r[0];
      _waste = r[1];
      _rc = r[2];
    });
  }

  // ── payload readers (no defaults, no invented fields) ──────────────────────
  static String _s(Map m, String k) => (m[k] ?? '').toString();
  static List<Map<String, dynamic>> _list(Map m, String k) =>
      ((m[k] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
  static List<String> _strings(Map m, String k) =>
      ((m[k] as List?) ?? const []).map((e) => '$e').toList();

  /// A block is drawn only when its own payload says it has something.
  static bool _shows(Map m) => m.isNotEmpty && (m['has'] ?? false) == true;

  // ── rendering primitives ───────────────────────────────────────────────────
  Widget _heading(String text) => text.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x8),
          child: Text(text,
              style: Ds.t.caption
                  .copyWith(fontWeight: FontWeight.w700, color: Ds.c.text)),
        );

  Widget _caption(String text) => text.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: EdgeInsets.only(top: Ds.space.x4),
          child: Text(text, style: Ds.t.caption),
        );

  /// The one row shape both cards use: a backend label, an optional backend
  /// value chip in the backend's own tone, and the backend's own sub-lines.
  Widget _row({
    required String label,
    String value = '',
    String tone = '',
    List<String> subs = const [],
  }) {
    if (label.isEmpty && value.isEmpty && subs.every((s) => s.isEmpty)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (label.isNotEmpty)
              Text(label,
                  style: Ds.t.caption
                      .copyWith(fontWeight: FontWeight.w600, color: Ds.c.text)),
            for (final s in subs)
              if (s.isNotEmpty) _caption(s),
          ]),
        ),
        if (value.isNotEmpty) ...[
          SizedBox(width: Ds.space.x8),
          ToneChip(label: value, tone: toneByName(tone)),
        ],
      ]),
    );
  }

  Widget _card(List<Widget> body, {VoidCallback? onTap}) => body.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x4),
          child: DqCard(
            onTap: onTap,
            padding: EdgeInsets.all(Ds.space.x12),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: body),
          ),
        );

  @override
  Widget build(BuildContext context) => Column(children: [
        _card(_rcBanner()),
        _card(_batchesCard()),
        _card(_wasteCard(), onTap: _shows(_waste) ? _toggleWaste : null),
      ]);

  void _toggleWaste() => setState(() => _wasteOpen = !_wasteOpen);

  /// dev_rc_health — the Remote Control banner. It is one backend sentence in
  /// one backend tone; when Remote Control is healthy the payload says
  /// `has:false` and nothing is drawn (a permanent green badge is how a real
  /// red stops being read).
  List<Widget> _rcBanner() {
    if (!_shows(_rc)) return const [];
    return [
      _row(
        label: _s(_rc, 'rc_banner'),
        tone: _s(_rc, 'rc_banner_tone'),
        subs: [_s(_rc, 'rc_banner_sub')],
      ),
    ];
  }

  /// deploy_lane_batches — every batch the merge worker ran, its verdict and
  /// the streak line. Nothing on any screen showed this: a run of failed
  /// batches was invisible while nothing reached production.
  List<Widget> _batchesCard() {
    if (!_shows(_batches)) return const [];
    final rows = _list(_batches, 'rows');
    return [
      _heading(_s(_batches, 'heading')),
      if (_s(_batches, 'streak_label').isNotEmpty)
        _row(
            label: _s(_batches, 'streak_label'),
            tone: _s(_batches, 'streak_tone')),
      if (rows.isEmpty) _caption(_s(_batches, 'empty_label')),
      for (final r in rows)
        _row(
          label: _s(r, 'label'),
          value: _s(r, 'value_label'),
          tone: _s(r, 'tone'),
          subs: [_s(r, 'sub_label'), _s(r, 'when_label')],
        ),
      _caption(_s(_batches, 'footnote')),
    ];
  }

  /// dev_cloud_waste_get — the monthly read-only scan. Its `button` ("Scan
  /// now") stays undrawn on purpose: the scan RPC it would call does not exist
  /// yet, and this command adds no backend.
  List<Widget> _wasteCard() {
    if (!_shows(_waste)) return const [];
    return [
      Row(children: [
        Expanded(child: _heading(_s(_waste, 'title'))),
        if (_s(_waste, 'total_display').isNotEmpty)
          ToneChip(label: _s(_waste, 'total_display'), tone: toneByName('')),
        Icon(_wasteOpen ? Icons.expand_less : Icons.expand_more,
            size: Ds.t.subtitleSize, color: Ds.c.textSecondary),
      ]),
      _caption(_s(_waste, 'ran_label')),
      if (_wasteOpen) ...[
        _caption(_s(_waste, 'subtitle')),
        for (final g in _list(_waste, 'groups')) ...[
          _row(
            label: _s(g, 'title'),
            value: _s(g, 'subtotal_display'),
            subs: [_s(g, 'note')],
          ),
          for (final r in _list(g, 'rows'))
            _row(label: _s(r, 'label'), value: _s(r, 'amount_display')),
          if (_list(g, 'rows').isEmpty) _caption(_s(g, 'empty_label')),
        ],
        _caption(_s(_waste, 'blocked')),
        for (final d in _strings(_waste, 'denied')) _caption(d),
        _caption(_s(_waste, 'footer')),
      ],
    ];
  }
}

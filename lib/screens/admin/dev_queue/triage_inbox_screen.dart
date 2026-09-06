import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// CHANGE #639 — the Triage inbox. Om's entire job in the find→fix loop.
///
/// The screen is a PRINTER. Every word on it — the title, the tab labels, the
/// severity and status chips, the button captions, the empty state, the trend
/// rows — arrives from `triage_inbox()` / `triage_trends()` and is drawn
/// verbatim. Nothing here decides whether a finding is real, what severity it
/// is, or whether a fix worked; the two taps send a decision and the backend
/// does the rest.
class TriageInboxScreen extends StatefulWidget {
  final DevQueueService? service;
  const TriageInboxScreen({super.key, this.service});

  @override
  State<TriageInboxScreen> createState() => _TriageInboxScreenState();
}

class _TriageInboxScreenState extends State<TriageInboxScreen> {
  late final DevQueueService _svc = widget.service ?? DevQueueService();

  Map<String, dynamic> _inbox = const {};
  Map<String, dynamic> _trends = const {};
  String _status = 'new';
  bool _loading = true;
  bool _busy = false;
  final Set<int> _expanded = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    Map<String, dynamic> inbox = const {};
    Map<String, dynamic> trends = const {};
    try {
      inbox = await _svc.triageInbox(status: _status);
    } catch (_) {/* the empty state below is the honest answer */}
    try {
      trends = await _svc.triageTrends();
    } catch (_) {/* trends are a bonus; the inbox still works */}
    if (!mounted) return;
    setState(() {
      _inbox = inbox;
      _trends = trends;
      _loading = false;
    });
  }

  List<Map<String, dynamic>> get _rows =>
      (_inbox['rows'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  Future<void> _run(Future<Map<String, dynamic>> Function() call) async {
    if (_busy) return;
    setState(() => _busy = true);
    String? message;
    try {
      final r = await call();
      message = r['message'] as String?;
    } catch (e) {
      // The refusal text is the BACKEND's (the human-only gate, the missing
      // reject reason). It is shown as-is rather than reworded here.
      message = _refusal(e);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (message != null && message.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
    await _load();
  }

  /// PostgrestException carries the backend's own sentence in `message`.
  String _refusal(Object e) {
    try {
      final m = (e as dynamic).message;
      if (m is String && m.trim().isNotEmpty) return m;
    } catch (_) {/* not a Postgrest error */}
    return e.toString();
  }

  @override
  Widget build(BuildContext context) {
    final title = _inbox['title'] as String?;
    return Scaffold(
      backgroundColor: kPageBg,
      appBar: AppBar(
        title: Text(title ?? ''),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: null,
          ),
        ],
      ),
      body: _loading
          ? const _TriageSkeleton()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                    Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x32),
                children: [
                  if ((_inbox['subtitle'] as String?)?.isNotEmpty ?? false)
                    Padding(
                      padding: EdgeInsets.only(bottom: Ds.space.x12),
                      child: Text(_inbox['subtitle'] as String,
                          style: Ds.t.caption),
                    ),
                  TriageTrendBlock(trends: _trends),
                  SizedBox(height: Ds.space.x24),
                  TriageStatusTabs(
                    tabs: _inbox['status_tabs'] as List? ?? const [],
                    onPick: (k) {
                      setState(() => _status = k);
                      _load();
                    },
                  ),
                  SizedBox(height: Ds.space.x16),
                  TriageBulkBar(
                    inbox: _inbox,
                    busy: _busy,
                    onSurface: (s) =>
                        _run(() => _svc.triageApproveBulk(surface: s)),
                    onSeverity: (s) =>
                        _run(() => _svc.triageApproveBulk(severity: s)),
                  ),
                  if (_rows.isEmpty) _EmptyState(inbox: _inbox),
                  for (final r in _rows) ...[
                    SizedBox(height: Ds.space.x12),
                    TriageFindingCard(
                      row: r,
                      busy: _busy,
                      expanded: _expanded.contains(r['id'] as int? ?? -1),
                      onToggle: () => setState(() {
                        final id = r['id'] as int? ?? -1;
                        _expanded.contains(id)
                            ? _expanded.remove(id)
                            : _expanded.add(id);
                      }),
                      onApprove: () =>
                          _run(() => _svc.triageApprove([r['id'] as int])),
                      onReject: () => _askReject(r),
                      shotUrl: (b, p) => _svc.triageShotUrl(b, p),
                    ),
                  ],
                  if (_inbox['has_more'] == true) ...[
                    SizedBox(height: Ds.space.x16),
                    Center(child: Text('${_rows.length} of ${_inbox['total']}',
                        style: Ds.t.caption)),
                  ],
                ],
              ),
            ),
    );
  }

  Future<void> _askReject(Map<String, dynamic> row) async {
    final ctrl = TextEditingController();
    final reason = await showModalBottomSheet<String>(
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(row['plain_line'] as String? ?? '', style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: row['reject_hint'] as String?,
                border: OutlineInputBorder(borderRadius: Ds.r.rButton),
              ),
            ),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(ctrl.text),
                child: Text(row['reject_label'] as String? ?? ''),
              ),
            ),
          ],
        ),
      ),
    );
    if (reason == null) return;
    // An empty reason is NOT swallowed here — it is sent, and the backend's own
    // refusal sentence is what Om reads. One rule, one place.
    await _run(() => _svc.triageReject([row['id'] as int], reason));
  }
}

// ── the card ────────────────────────────────────────────────────────────────

/// The card, public so `test/protected/triage_inbox_test.dart` can pump it with
/// an inline payload and no Supabase. It computes NOTHING: severity, status,
/// tones, button captions, the repro toggle's two labels and whether the two
/// buttons exist at all are the payload's.
class TriageFindingCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool busy;
  final bool expanded;
  final VoidCallback? onToggle;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final Future<String?> Function(String bucket, String path)? shotUrl;

  const TriageFindingCard({
    super.key,
    required this.row,
    this.busy = false,
    this.expanded = false,
    this.onToggle,
    this.onApprove,
    this.onReject,
    this.shotUrl,
  });

  @override
  Widget build(BuildContext context) {
    final sevTone = toneByName(row['severity_tone'] as String? ?? 'neutral');
    final stTone = toneByName(row['status_tone'] as String? ?? 'neutral');
    final repro = (row['repro'] as List? ?? const []);
    final canDecide = row['can_decide'] == true;

    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: kBorder),
        boxShadow: Ds.elevation.e1,
      ),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TriageChip(label: row['severity_label'] as String?, tone: sevTone),
              TriageChip(label: row['status_label'] as String?, tone: stTone),
              if ((row['source_label'] as String?)?.isNotEmpty ?? false)
                Text(row['source_label'] as String, style: Ds.t.caption),
              if ((row['found_label'] as String?)?.isNotEmpty ?? false)
                Text(row['found_label'] as String, style: Ds.t.caption),
              if ((row['seen_label'] as String?)?.isNotEmpty ?? false)
                Text(row['seen_label'] as String, style: Ds.t.caption),
              if ((row['reopen_label'] as String?)?.isNotEmpty ?? false)
                Text(row['reopen_label'] as String, style: Ds.t.caption),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          Text(row['plain_line'] as String? ?? '', style: Ds.t.body),
          if ((row['surface_label'] as String?)?.isNotEmpty ?? false) ...[
            SizedBox(height: Ds.space.x4),
            Text(row['surface_label'] as String, style: Ds.t.caption),
          ],
          if (row['has_shot'] == true && shotUrl != null) ...[
            SizedBox(height: Ds.space.x12),
            _Shot(
              url: shotUrl!(row['shot_bucket'] as String? ?? '',
                  row['shot_path'] as String? ?? ''),
            ),
          ],
          if ((row['escalate_note'] as String?)?.isNotEmpty ?? false) ...[
            SizedBox(height: Ds.space.x12),
            _Note(text: row['escalate_note'] as String, tone: toneByName('danger')),
          ],
          if ((row['verify_detail'] as String?)?.isNotEmpty ?? false) ...[
            SizedBox(height: Ds.space.x8),
            Text(row['verify_detail'] as String, style: Ds.t.caption),
          ],
          if ((row['reject_reason'] as String?)?.isNotEmpty ?? false) ...[
            SizedBox(height: Ds.space.x8),
            Text(row['reject_reason'] as String, style: Ds.t.caption),
          ],
          if ((row['fix_label'] as String?)?.isNotEmpty ?? false) ...[
            SizedBox(height: Ds.space.x8),
            Text(row['fix_label'] as String, style: Ds.t.caption),
          ],
          if (repro.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            InkWell(
              onTap: onToggle,
              borderRadius: Ds.r.rButton,
              child: Container(
                constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
                alignment: Alignment.centerLeft,
                child: Text(
                  (expanded
                          ? row['repro_hide_label'] as String?
                          : row['repro_label'] as String?) ??
                      '',
                  style: Ds.t.caption.copyWith(color: kBrand),
                ),
              ),
            ),
            if (expanded)
              for (final s in repro)
                Padding(
                  padding: EdgeInsets.only(bottom: Ds.space.x4),
                  child: Text('· ${s ?? ''}', style: Ds.t.caption),
                ),
          ],
          if (canDecide) ...[
            SizedBox(height: Ds.space.x12),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: OutlinedButton(
                      onPressed: busy ? null : onReject,
                      child: Text(row['reject_label'] as String? ?? ''),
                    ),
                  ),
                ),
                SizedBox(width: Ds.space.x12),
                Expanded(
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: FilledButton(
                      onPressed: busy ? null : onApprove,
                      child: Text(row['approve_label'] as String? ?? ''),
                    ),
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

// ── small pieces ────────────────────────────────────────────────────────────

class TriageChip extends StatelessWidget {
  final String? label;
  final Tone tone;
  const TriageChip({super.key, required this.label, required this.tone});

  @override
  Widget build(BuildContext context) {
    if (label == null || label!.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: tone.bg, borderRadius: Ds.r.rChip),
      child: Text(label!, style: Ds.t.caption.copyWith(color: tone.fg)),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  final Tone tone;
  const _Note({required this.text, required this.tone});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(color: tone.bg, borderRadius: Ds.r.rButton),
        child: Text(text, style: Ds.t.caption.copyWith(color: tone.fg)),
      );
}

class _Shot extends StatelessWidget {
  final Future<String?> url;
  const _Shot({required this.url});

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
        future: url,
        builder: (ctx, snap) {
          final u = snap.data;
          if (u == null || u.isEmpty) return const SizedBox.shrink();
          return ClipRRect(
            borderRadius: Ds.r.rButton,
            child: Image.network(u,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink()),
          );
        },
      );
}

class TriageStatusTabs extends StatelessWidget {
  final List tabs;
  final void Function(String) onPick;
  const TriageStatusTabs({super.key, required this.tabs, required this.onPick});

  @override
  Widget build(BuildContext context) {
    if (tabs.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final t in tabs.whereType<Map>())
            Padding(
              padding: EdgeInsets.only(right: Ds.space.x8),
              child: ChoiceChip(
                selected: t['selected'] == true,
                onSelected: (_) => onPick(t['key'] as String? ?? 'new'),
                label: Text('${t['label'] ?? ''} ${t['count'] ?? 0}'),
              ),
            ),
        ],
      ),
    );
  }
}

class TriageBulkBar extends StatelessWidget {
  final Map<String, dynamic> inbox;
  final bool busy;
  final void Function(String) onSurface;
  final void Function(String) onSeverity;
  const TriageBulkBar({
    super.key,
    required this.inbox,
    required this.busy,
    required this.onSurface,
    required this.onSeverity,
  });

  @override
  Widget build(BuildContext context) {
    final surfaces = (inbox['bulk_surfaces'] as List? ?? const []);
    final severities = (inbox['bulk_severities'] as List? ?? const []);
    if (surfaces.isEmpty && severities.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (severities.isNotEmpty) ...[
          Text(inbox['bulk_severity_label'] as String? ?? '',
              style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final s in severities.whereType<Map>())
                ActionChip(
                  onPressed:
                      busy ? null : () => onSeverity(s['severity'] as String),
                  backgroundColor: toneByName(s['tone'] as String? ?? '').bg,
                  label: Text('${s['label'] ?? ''}',
                      style: Ds.t.caption.copyWith(
                          color: toneByName(s['tone'] as String? ?? '').fg)),
                ),
            ],
          ),
          SizedBox(height: Ds.space.x16),
        ],
        if (surfaces.isNotEmpty) ...[
          Text(inbox['bulk_surface_label'] as String? ?? '',
              style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final s in surfaces.whereType<Map>().take(8))
                ActionChip(
                  onPressed:
                      busy ? null : () => onSurface(s['surface'] as String),
                  label: Text('${s['label'] ?? ''}', style: Ds.t.caption),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The trend block, public for the protected test. Every number and every word
/// is `triage_trends()`'; nothing is recomputed from the weekly rows.
class TriageTrendBlock extends StatelessWidget {
  final Map<String, dynamic> trends;
  const TriageTrendBlock({super.key, required this.trends});

  @override
  Widget build(BuildContext context) {
    if (trends['has'] != true) return const SizedBox.shrink();
    final stats = (trends['stats'] as List? ?? const []);
    final weeks = (trends['weeks'] as List? ?? const []);
    final worst = (trends['worst'] as List? ?? const []);
    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: kBorder),
        boxShadow: Ds.elevation.e1,
      ),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(trends['title'] as String? ?? '', style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          for (final s in stats.whereType<Map>())
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${s['label'] ?? ''}', style: Ds.t.body),
                        if ((s['sub'] as String?)?.isNotEmpty ?? false)
                          Text(s['sub'] as String, style: Ds.t.caption),
                      ],
                    ),
                  ),
                  SizedBox(width: Ds.space.x12),
                  TriageChip(
                      label: '${s['value'] ?? ''}',
                      tone: toneByName(s['tone'] as String? ?? 'neutral')),
                ],
              ),
            ),
          if (weeks.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(trends['weeks_label'] as String? ?? '', style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
            for (final w in weeks.whereType<Map>())
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x4),
                child: Text('${w['label'] ?? ''}', style: Ds.t.caption),
              ),
          ],
          if (worst.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            Text(trends['worst_label'] as String? ?? '', style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
            for (final w in worst.whereType<Map>())
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${w['label'] ?? ''}', style: Ds.t.body),
                          if ((w['sub'] as String?)?.isNotEmpty ?? false)
                            Text(w['sub'] as String, style: Ds.t.caption),
                        ],
                      ),
                    ),
                    SizedBox(width: Ds.space.x12),
                    TriageChip(
                        label: '${w['value'] ?? ''}',
                        tone: toneByName(w['tone'] as String? ?? 'neutral')),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final Map<String, dynamic> inbox;
  const _EmptyState({required this.inbox});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x32),
        child: Column(
          children: [
            Text(inbox['empty'] as String? ?? '',
                style: Ds.t.body, textAlign: TextAlign.center),
            if ((inbox['empty_hint'] as String?)?.isNotEmpty ?? false) ...[
              SizedBox(height: Ds.space.x8),
              Text(inbox['empty_hint'] as String,
                  style: Ds.t.caption, textAlign: TextAlign.center),
            ],
          ],
        ),
      );
}

/// A skeleton, not a bare spinner (design QA #6).
class _TriageSkeleton extends StatelessWidget {
  const _TriageSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 4; i++)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: Container(
                height: Ds.touch.listRowMinHeight * 2,
                decoration: BoxDecoration(
                  color: Ds.c.surface,
                  borderRadius: Ds.r.rCard,
                  border: Border.all(color: kBorder),
                ),
              ),
            ),
        ],
      );
}

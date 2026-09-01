// CHANGE — feature_gaps #58 (admin / Ops overview, critical): the screen that
// answers "what is stuck right now".
//
// Before this, stalled work sat in seven tables with nothing joining them and —
// the part that actually mattered — no AGE anywhere. admin_dashboard_counts()
// returns six numbers, none of them a duration, so a bill could sit 89 days and
// the home screen showed the same "13" it showed on day one. A number that
// cannot get worse by being ignored is not an ops surface.
//
// THIS FILE COMPUTES NOTHING. It is one RPC printed in payload order:
//
//   • The ORDER is the backend's. `admin_ops_board()` sorts worst-first by how
//     far each queue is past ITS OWN deadline, not by raw age and not by size,
//     so six claims a day past a 24-hour SLA outrank thirteen bills a day past
//     a 48-hour one. Re-sorting here would silently replace that judgement with
//     "biggest list first", which is the ranking the register row rejected.
//   • Every string — title, subtitle, stage, owner, action, count_label,
//     age_label, over_sla_label, the empty state — arrives written. There is no
//     pluralisation, no "N items" built in Dart and no age arithmetic: ages are
//     words from ops_age_label(), because a clock computed on the client drifts
//     from the clock the backend sorted by.
//   • `tone` is a token, mapped to a colour and nothing else. An unknown tone
//     renders neutral rather than blanking the card.
//   • A class disappears from the payload when it is empty, and a re-worded
//     label or a changed SLA is one UPDATE on ops_board_class — no deploy.
//
// Styling is 100% `Ds` tokens (DESIGN.md / CHANGE #66): this file holds zero
// style literals and must stay that way.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

/// Injectable RPC seam — production leaves it null and gets the Supabase call,
/// tests hand in a stub and never touch the network.
typedef AdminOpsBoardRpc = Future<Map<String, dynamic>> Function(int top);

Map<String, dynamic> _asMap(dynamic res) =>
    res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};

Future<Map<String, dynamic>> adminOpsBoard(int top) async => _asMap(
    await Supabase.instance.client.rpc('admin_ops_board', params: {'p_top': top}));

/// Backend tone token -> colour pair (wash, ink). Token to token: no status is
/// interpreted here, and an unrecognised tone stays readable.
(Color, Color) _tone(String? t) => switch (t) {
      'good' => (Ds.c.successSoft, Ds.c.success),
      'warn' => (Ds.c.warningSoft, Ds.c.warning),
      'bad' => (Ds.c.dangerSoft, Ds.c.danger),
      _ => (Ds.c.infoSoft, Ds.c.info),
    };

class AdminOpsBoardScreen extends StatefulWidget {
  /// How many example rows the backend should attach to each class.
  final int top;
  final AdminOpsBoardRpc? boardRpc;

  /// Tapping a class's action jumps to that admin destination. The board never
  /// decides where a route goes — `action_route` is the backend's key and this
  /// callback is whatever the host screen already uses for quick navigation.
  final ValueChanged<String>? onNavigate;

  const AdminOpsBoardScreen({
    super.key,
    this.top = 3,
    this.boardRpc,
    this.onNavigate,
  });

  @override
  State<AdminOpsBoardScreen> createState() => _AdminOpsBoardScreenState();
}

class _AdminOpsBoardScreenState extends State<AdminOpsBoardScreen> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await (widget.boardRpc ?? adminOpsBoard)(widget.top);
      if (!mounted) return;
      if (res['ok'] != true) {
        // A refusal is the backend's sentence, printed as given.
        setState(() {
          _loading = false;
          _error = (res['message'] ?? res['error'] ?? '').toString();
        });
        return;
      }
      setState(() {
        _payload = res;
        _loading = false;
      });
      try {
        RenderLog.write(
            'admin_ops_board', (res['headline_count'] ?? 0).toString());
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload ?? const <String, dynamic>{};
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text((p['title'] ?? c('admin_ops_board.title')).toString()),
        actions: [
          IconButton(
            key: const Key('ops_board_refresh'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: c('admin_ops_board.refresh'),
          ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _load, child: _body(p)),
    );
  }

  Widget _body(Map<String, dynamic> p) {
    if (_loading) return const _BoardSkeleton();
    if (_error != null) return _ErrorState(message: _error!, onRetry: _load);

    final items = (p['items'] as List?) ?? const [];
    return ListView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
      children: [
        _Headline(payload: p),
        if (items.isEmpty)
          _EmptyState(label: (p['empty_label'] ?? '').toString())
        else
          // Payload order IS the ranking. No sort, no filter, no grouping.
          ...items.map((raw) => _ClassCard(
                data: _asMap(raw),
                onNavigate: widget.onNavigate,
              )),
        SizedBox(height: Ds.space.x16),
        if ((p['note'] ?? '').toString().isNotEmpty)
          Text((p['note']).toString(), style: Ds.t.caption),
      ],
    );
  }
}

// ── The headline: one focal element, then supporting data ────────────────────

class _Headline extends StatelessWidget {
  final Map<String, dynamic> payload;
  const _Headline({required this.payload});

  @override
  Widget build(BuildContext context) {
    String s(String k) => (payload[k] ?? '').toString();
    final (wash, ink) = _tone(s('headline_tone'));

    return Container(
      key: const Key('ops_board_headline'),
      width: double.infinity,
      margin: EdgeInsets.only(bottom: Ds.space.x16),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: wash,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: ink.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s('headline_label'), style: Ds.t.display.copyWith(color: ink)),
          SizedBox(height: Ds.space.x4),
          Text(s('subtitle'), style: Ds.t.body),
          if (s('worst_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(s('worst_label'),
                key: const Key('ops_board_worst'),
                style: Ds.t.body.copyWith(fontWeight: FontWeight.w700)),
          ],
          if (s('checked_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(s('checked_label'), style: Ds.t.caption),
          ],
        ],
      ),
    );
  }
}

// ── One stuck class: stage, age, owner, ONE action ───────────────────────────

class _ClassCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final ValueChanged<String>? onNavigate;
  const _ClassCard({required this.data, this.onNavigate});

  @override
  Widget build(BuildContext context) {
    String s(String k) => (data[k] ?? '').toString();
    final (wash, ink) = _tone(s('tone'));
    final route = s('action_route');
    final items = (data['items'] as List?) ?? const [];

    return Container(
      key: Key('ops_board_class_${s('key')}'),
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(s('title'), style: Ds.t.subtitle)),
            SizedBox(width: Ds.space.x8),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x12, vertical: Ds.space.x4),
              decoration:
                  BoxDecoration(color: wash, borderRadius: Ds.r.rChip),
              child: Text(s('count_label'),
                  style: Ds.t.caption
                      .copyWith(color: ink, fontWeight: FontWeight.w600)),
            ),
          ]),
          SizedBox(height: Ds.space.x8),
          // Stage · age · how many are past the deadline — all backend words.
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x4,
            children: [
              _Meta(label: s('stage_label')),
              _Meta(label: s('age_label'), tint: ink),
              _Meta(label: s('over_sla_label'), tint: ink),
              _Meta(label: s('owner_label')),
            ],
          ),
          if (items.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            ...items.map((raw) => _ItemRow(data: _asMap(raw))),
          ],
          if (s('action_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: route.isEmpty || onNavigate == null
                  ? OutlinedButton(
                      onPressed: null, child: Text(s('action_label')))
                  : OutlinedButton(
                      key: Key('ops_board_action_${s('key')}'),
                      onPressed: () => onNavigate!(route),
                      child: Text(s('action_label')),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  final String label;
  final Color? tint;
  const _Meta({required this.label, this.tint});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Text(label,
        style: tint == null ? Ds.t.caption : Ds.t.caption.copyWith(color: tint));
  }
}

/// The oldest few objects in a class, so the number has faces behind it.
class _ItemRow extends StatelessWidget {
  final Map<String, dynamic> data;
  const _ItemRow({required this.data});

  @override
  Widget build(BuildContext context) {
    String s(String k) => (data[k] ?? '').toString();
    final overdue = data['over_sla'] == true;
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s('label'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.body),
              if (s('sub_label').isNotEmpty)
                Text(s('sub_label'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.caption),
            ],
          ),
        ),
        SizedBox(width: Ds.space.x12),
        Text(s('age_label'),
            style: overdue
                ? Ds.t.caption
                    .copyWith(color: Ds.c.danger, fontWeight: FontWeight.w600)
                : Ds.t.caption),
      ]),
    );
  }
}

// ── States ───────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final String label;
  const _EmptyState({required this.label});

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('ops_board_empty'),
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x24),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: Text(label, style: Ds.t.body, textAlign: TextAlign.center),
      );
}

/// A skeleton, not a bare spinner — the board's shape is known before the
/// numbers are.
class _BoardSkeleton extends StatelessWidget {
  const _BoardSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: List.generate(
          4,
          (i) => Container(
            key: Key('ops_board_skeleton_$i'),
            height: Ds.space.x48 + Ds.space.x32,
            margin: EdgeInsets.only(bottom: Ds.space.x12),
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: Ds.r.rCard,
              boxShadow: Ds.elevation.e1,
            ),
          ),
        ),
      );
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          Container(
            key: const Key('ops_board_error'),
            padding: EdgeInsets.all(Ds.space.x16),
            decoration: BoxDecoration(
              color: Ds.c.dangerSoft,
              borderRadius: Ds.r.rCard,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message, style: Ds.t.body.copyWith(color: Ds.c.danger)),
                SizedBox(height: Ds.space.x12),
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed: onRetry,
                    child: Text(c('admin_ops_board.retry')),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
}

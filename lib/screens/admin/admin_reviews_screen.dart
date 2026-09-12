import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CMD #410 — the moderation desk for product reviews, questions and answers.
///
/// Nothing a pharmacy writes is public until it is approved here. The screen
/// renders `review_moderation_queue(status)` verbatim: the four tab labels and
/// their counts, every row's product, author, stars and body, the two verdict
/// captions, the reason placeholder and the empty state are all in the
/// payload. The screen's only decisions are which tab is open and whether the
/// reason sheet is showing.
///
/// The refusal is rendered too. `review_moderation_queue` answers a non-admin
/// with `ok:false, error:'not_authorized'` and its own sentence rather than
/// throwing, so this screen shows the backend's message instead of a blank
/// page — the same contract wa_ops and notify_center use.
class AdminReviewsScreen extends StatefulWidget {
  /// Test seam: production talks to Supabase, a test supplies payloads.
  final Future<dynamic> Function(String fn, Map<String, dynamic>? params)? rpc;
  const AdminReviewsScreen({super.key, this.rpc});

  @override
  State<AdminReviewsScreen> createState() => _AdminReviewsScreenState();
}

class _AdminReviewsScreenState extends State<AdminReviewsScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String _tab = 'pending';
  final Set<String> _busy = {};

  Future<dynamic> _rpc(String fn, [Map<String, dynamic>? params]) =>
      widget.rpc != null
          ? widget.rpc!(fn, params)
          : Supabase.instance.client.rpc(fn, params: params);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final raw = await _rpc('review_moderation_queue', {'p_status': _tab});
      if (!mounted) return;
      setState(() {
        _data = raw is Map ? Map<String, dynamic>.from(raw) : null;
        _loading = false;
      });
      RenderLog.write('c410_review_queue', '$_tab:${_rows.length}');
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _rows =>
      (_data?['rows'] as List?)
          ?.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList() ??
      const <Map<String, dynamic>>[];

  String _s(String key) => (_data?[key] ?? '').toString();

  Future<void> _moderate(
      Map<String, dynamic> row, String verdict, String reason) async {
    final key = '${row['kind']}:${row['id']}';
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    try {
      final res = await _rpc('review_moderate', {
        'p_kind': row['kind'],
        'p_id': int.tryParse('${row['id']}') ?? 0,
        'p_verdict': verdict,
        'p_reason': reason,
      });
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : const {};
      final msg = (m['message'] ?? '').toString();
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (_) {
      // Fall through to the reload: the queue is the source of truth about
      // what actually happened, not a locally patched row.
    }
    if (!mounted) return;
    setState(() => _busy.remove(key));
    await _load();
  }

  /// The rejection reason. The backend REFUSES a rejection with no reason, so
  /// this sheet exists to collect one rather than to enforce it — the rule
  /// lives in SQL and this is the surface for it.
  Future<void> _rejectSheet(Map<String, dynamic> row) async {
    final ctl = TextEditingController();
    final reason = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
      ),
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
            Text(_s('reject_label'), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: ctl,
              autofocus: true,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: _s('reason_hint'),
                filled: true,
                fillColor: Ds.c.bg,
                border: OutlineInputBorder(borderRadius: Ds.r.rButton),
              ),
            ),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(ctl.text),
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.danger,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                child: Text(_s('reject_label')),
              ),
            ),
          ],
        ),
      ),
    );
    ctl.dispose();
    if (reason == null) return;
    await _moderate(row, 'reject', reason);
  }

  @override
  Widget build(BuildContext context) {
    final tabs = (_data?['tabs'] as List?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        const <Map<String, dynamic>>[];

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        title: Text(_s('title'), style: Ds.t.title),
        centerTitle: false,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_data?['ok'] != true)
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(Ds.space.x24),
                    child: Text(_s('message'),
                        style: Ds.t.body, textAlign: TextAlign.center),
                  ),
                )
              : Column(
                  children: [
                    SizedBox(
                      height: 56,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding:
                            EdgeInsets.symmetric(horizontal: Ds.space.x16),
                        children: [
                          for (final t in tabs)
                            Padding(
                              padding: EdgeInsets.only(right: Ds.space.x8),
                              child: _Tab(
                                label: '${t['label']} (${t['count']})',
                                active: '${t['key']}' == _tab,
                                onTap: () {
                                  setState(() => _tab = '${t['key']}');
                                  _load();
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _rows.isEmpty
                          ? Center(
                              child: Text(_s('empty'), style: Ds.t.caption))
                          : ListView.separated(
                              padding: EdgeInsets.all(Ds.space.x16),
                              itemCount: _rows.length,
                              separatorBuilder: (_, _) =>
                                  SizedBox(height: Ds.space.x12),
                              itemBuilder: (_, i) => _QueueCard(
                                row: _rows[i],
                                approveLabel: _s('approve_label'),
                                rejectLabel: _s('reject_label'),
                                busy: _busy.contains(
                                    '${_rows[i]['kind']}:${_rows[i]['id']}'),
                                onApprove: () =>
                                    _moderate(_rows[i], 'approve', ''),
                                onReject: () => _rejectSheet(_rows[i]),
                              ),
                            ),
                    ),
                  ],
                ),
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _Tab({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: Ds.r.rChip,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
          decoration: BoxDecoration(
            color: active ? Ds.c.brand : Ds.c.surface,
            borderRadius: Ds.r.rChip,
            border: Border.all(color: active ? Ds.c.brand : Ds.c.divider),
          ),
          child: Text(
            label,
            style: Ds.t.caption.copyWith(
              color: active ? Ds.c.surface : Ds.c.text,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
}

class _QueueCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final String approveLabel;
  final String rejectLabel;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _QueueCard({
    required this.row,
    required this.approveLabel,
    required this.rejectLabel,
    required this.busy,
    required this.onApprove,
    required this.onReject,
  });

  String _s(String k) => (row[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final stars = row['stars'];
    final flags = int.tryParse('${row['flags'] ?? 0}') ?? 0;
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_s('product'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.bodyStrong),
              ),
              // A reported item is the only red thing on this card.
              if (flags > 0)
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x8, vertical: Ds.space.x4),
                  decoration: BoxDecoration(
                      color: Ds.c.dangerSoft, borderRadius: Ds.r.rChip),
                  child: Text('$flags',
                      style: Ds.t.caption.copyWith(
                          color: Ds.c.danger, fontWeight: FontWeight.w600)),
                ),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Row(
            children: [
              Text(_s('kind'), style: Ds.t.caption),
              if (stars != null) ...[
                SizedBox(width: Ds.space.x8),
                for (var i = 1; i <= 5; i++)
                  Icon(
                    (int.tryParse('$stars') ?? 0) >= i
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    size: Ds.space.x16,
                    color: Ds.c.warning,
                  ),
              ],
              const Spacer(),
              Text(_s('when'), style: Ds.t.caption),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Text(_s('body'), style: Ds.t.body),
          if (_s('author').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s('author'), style: Ds.t.caption),
          ],
          if (_s('reason').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Container(
              padding: EdgeInsets.all(Ds.space.x8),
              decoration: BoxDecoration(
                  color: Ds.c.warningSoft, borderRadius: Ds.r.rButton),
              child: Text(_s('reason'),
                  style: Ds.t.caption.copyWith(color: Ds.c.text)),
            ),
          ],
          SizedBox(height: Ds.space.x12),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: busy ? null : onReject,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Ds.c.danger,
                      side: BorderSide(color: Ds.c.danger),
                      shape:
                          RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                    ),
                    child: Text(rejectLabel),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: busy ? null : onApprove,
                    style: FilledButton.styleFrom(
                      backgroundColor: Ds.c.brand,
                      shape:
                          RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                    ),
                    child: Text(approveLabel),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

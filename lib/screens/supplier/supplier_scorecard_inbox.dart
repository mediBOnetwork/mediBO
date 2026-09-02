import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #465 — supplier register rows 64 and 65, the two things a logged-in
/// supplier could not see about themselves.
///
/// ROW 64: SPN is a GENERATED column on supplier_profiles and
/// inquiry_engine_ranked_suppliers() orders the entire waterfall by it — yet
/// every SPN RPC was admin-side. The number deciding whether a supplier is
/// asked first or never was invisible to the supplier it describes.
///
/// ROW 65: notification_log carried 35 rows for audience='supplier' and every
/// one was channel='whatsapp'. A supplier who opens the app was told nothing.
///
/// Both are pure renderers. Every number is already formatted server-side
/// (points_label, value_label, when_label), every word arrives in the payload,
/// and the badges are counted by the backend from the same tables the tabs
/// read — so a badge here can never disagree with the tab it sits on.

/// Reads `supplier_scorecard()` and prints it. Renders NOTHING when the caller
/// is not a supplier, so it is safe to drop on any screen.
class SupplierScorecardCard extends StatefulWidget {
  const SupplierScorecardCard({super.key});

  @override
  State<SupplierScorecardCard> createState() => _SupplierScorecardCardState();
}

class _SupplierScorecardCardState extends State<SupplierScorecardCard> {
  Map<String, dynamic>? _p;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw =
          await Supabase.instance.client.rpc('supplier_scorecard');
      final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (!mounted || map is! Map) return;
      final p = map.cast<String, dynamic>();
      setState(() => _p = p);
      if (p['ok'] == true) {
        RenderLog.write(
            'c465_spn_card',
            'spn:${(p['spn'] as Map?)?['value'] ?? ''}'
            ';rank:${(p['rank'] as Map?)?['value'] ?? ''}'
            ';parts:${((p['components'] as List?) ?? const []).length}');
      }
    } catch (_) {
      // A card that cannot ask simply does not draw. Boot resilience rule.
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (p == null || p['ok'] != true) return const SizedBox.shrink();
    return SupplierScorecardView(payload: p);
  }
}

/// The card's rendering, with no fetch in it — so the protected suite can hand
/// it a payload and assert that nothing on it is computed in Dart.
class SupplierScorecardView extends StatelessWidget {
  final Map<String, dynamic> payload;
  const SupplierScorecardView({super.key, required this.payload});

  @override
  Widget build(BuildContext context) {
    final p = payload;
    if (p['ok'] != true) return const SizedBox.shrink();
    final spn = (p['spn'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rank = (p['rank'] as Map?)?.cast<String, dynamic>() ?? const {};
    final status = (p['status'] as Map?)?.cast<String, dynamic>() ?? const {};
    final parts = ((p['components'] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map((c) => Map<String, dynamic>.from(c))
        .toList();
    final inactive = status['is_active'] != true;

    return Container(
      margin: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x8),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text((p['title'] ?? '').toString(), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x4),
          Text((p['subtitle'] ?? '').toString(), style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text((spn['label'] ?? '').toString(), style: Ds.t.caption),
                  Text((spn['value_label'] ?? '').toString(),
                      style: Ds.t.display),
                ],
              ),
              const Spacer(),
              if (rank['has'] == true)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text((rank['label'] ?? '').toString(),
                        style: Ds.t.caption),
                    Text((rank['value_label'] ?? '').toString(),
                        style: Ds.t.title),
                    Text((rank['of_label'] ?? '').toString(),
                        style: Ds.t.caption),
                  ],
                ),
            ],
          ),
          // An inactive account scores zero and is never asked. That is the one
          // fact a supplier most needs and least sees, so it is not a chip in a
          // corner — it is a line of the backend's own words.
          if (inactive) ...[
            SizedBox(height: Ds.space.x12),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                  color: Ds.c.warningSoft, borderRadius: Ds.r.rCard),
              child: Text((status['note'] ?? '').toString(), style: Ds.t.body),
            ),
          ],
          if (parts.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            Text((p['components_label'] ?? '').toString(),
                style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
            for (final c in parts)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        (c['choice_label'] ?? '').toString().isEmpty
                            ? (c['label'] ?? '').toString()
                            : '${c['label']} · ${c['choice_label']}',
                        style: Ds.t.body,
                      ),
                    ),
                    SizedBox(width: Ds.space.x8),
                    Text((c['points_label'] ?? '').toString(),
                        style: Ds.t.bodyStrong),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// The in-app inbox (row 65). Opened from the supplier shell's bell.
class SupplierInboxSheet extends StatefulWidget {
  const SupplierInboxSheet({super.key});

  @override
  State<SupplierInboxSheet> createState() => _SupplierInboxSheetState();
}

Future<void> showSupplierInbox(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => const SupplierInboxSheet(),
    );

class _SupplierInboxSheetState extends State<SupplierInboxSheet> {
  Map<String, dynamic>? _p;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await Supabase.instance.client
          .rpc('supplier_inbox', params: {'p_limit': 30});
      final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (!mounted) return;
      setState(() {
        _p = map is Map ? map.cast<String, dynamic>() : null;
        _loading = false;
      });
      final items = ((_p?['items'] as List?) ?? const []).length;
      RenderLog.write('c465_sup_inbox', 'items:$items;unread:${_p?['unread'] ?? 0}');
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _markAll() async {
    try {
      await Supabase.instance.client.rpc('supplier_inbox_mark_read');
    } catch (_) {
      // The list re-reads either way; the server is the only authority on read.
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) =>
      SupplierInboxView(payload: _p, loading: _loading, onMarkAll: _markAll);
}

/// The inbox's rendering, with no fetch in it. Items print in PAYLOAD order,
/// the unread dot is the row's own `is_read`, the empty state is the backend's
/// two sentences, and "Mark all read" appears only when the BACKEND says there
/// is something unread — this widget counts nothing.
class SupplierInboxView extends StatelessWidget {
  final Map<String, dynamic>? payload;
  final bool loading;
  final VoidCallback onMarkAll;
  const SupplierInboxView(
      {super.key,
      required this.payload,
      this.loading = false,
      required this.onMarkAll});

  @override
  Widget build(BuildContext context) {
    final p = payload;
    final items = ((p?['items'] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map((i) => Map<String, dynamic>.from(i))
        .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text((p?['title'] ?? '').toString(),
                        style: Ds.t.subtitle)),
                if ((p?['unread'] as num?) != null &&
                    (p!['unread'] as num) > 0)
                  TextButton(
                    onPressed: onMarkAll,
                    child: Text((p['mark_all'] ?? '').toString()),
                  ),
              ],
            ),
            SizedBox(height: Ds.space.x8),
            if (loading)
              Padding(
                padding: EdgeInsets.all(Ds.space.x24),
                child: const Center(child: CircularProgressIndicator()),
              )
            else if (items.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: Ds.space.x24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((p?['empty'] ?? '').toString(), style: Ds.t.body),
                    SizedBox(height: Ds.space.x4),
                    Text((p?['empty_note'] ?? '').toString(),
                        style: Ds.t.caption),
                  ],
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: items.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: Ds.c.divider),
                  itemBuilder: (context, i) {
                    final it = items[i];
                    final unread = it['is_read'] != true;
                    return Padding(
                      padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (unread)
                                Container(
                                  width: Ds.space.x8,
                                  height: Ds.space.x8,
                                  margin:
                                      EdgeInsets.only(right: Ds.space.x8),
                                  decoration: BoxDecoration(
                                      color: Ds.c.brand,
                                      shape: BoxShape.circle),
                                ),
                              Expanded(
                                child: Text((it['title'] ?? '').toString(),
                                    style: Ds.t.bodyStrong),
                              ),
                              Text((it['when_label'] ?? '').toString(),
                                  style: Ds.t.caption),
                            ],
                          ),
                          SizedBox(height: Ds.space.x4),
                          Text((it['body'] ?? '').toString(),
                              style: Ds.t.caption),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

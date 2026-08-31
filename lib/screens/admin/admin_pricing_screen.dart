import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #355 — feature_gaps #80, "catalogue has no trade price".
///
/// The register row said 2 of 562,549 medicines are priced. That number had no
/// surface: nobody could see it move, and nothing decided anything from it.
/// This screen is that surface — `pricing_coverage_report()` measured against
/// the catalogue, plus the sellability policy the coverage exists to inform.
///
/// Every string on this page is a payload string. The rows, their labels, their
/// values, the percentages, the policy wording and the timestamp are all
/// computed and formatted by the backend; this widget only lays them out.
class AdminPricingScreen extends StatefulWidget {
  const AdminPricingScreen({super.key});

  @override
  State<AdminPricingScreen> createState() => _AdminPricingScreenState();
}

class _AdminPricingScreenState extends State<AdminPricingScreen> {
  Map<String, dynamic>? _report;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _call(String fn, [Map<String, dynamic>? args]) async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final raw = await Supabase.instance.client.rpc(fn, params: args);
      final map = (raw is List ? raw.first : raw) as Map?;
      if (!mounted) return;
      setState(() => _report = map?.cast<String, dynamic>());
      RenderLog.write('c355_pricing_rows',
          ((_report?['rows'] as List?)?.length ?? 0).toString());
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _call('pricing_coverage_report');
  Future<void> _refresh() => _call('pricing_coverage_refresh');
  Future<void> _setMode(String mode) =>
      _call('pricing_policy_set', {'p_mode': mode});

  @override
  Widget build(BuildContext context) {
    final r = _report;
    final rows = ((r?['rows'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList(growable: false);
    final policy = (r?['policy'] as Map?)?.cast<String, dynamic>() ?? const {};
    final options = ((policy['options'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList(growable: false);
    final mode = (policy['mode'] ?? '').toString();

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text((r?['title'] ?? '').toString()),
        actions: [
          IconButton(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: (r?['computed_label'] ?? '').toString(),
          ),
        ],
      ),
      body: _busy && r == null
          ? const _CoverageSkeleton()
          : ListView(
              padding: EdgeInsets.all(Ds.space.x16),
              children: [
                if (_error.isNotEmpty) ...[
                  Text(_error, style: Ds.t.body.copyWith(color: Ds.c.danger)),
                  SizedBox(height: Ds.space.x12),
                  OutlinedButton(onPressed: _load, child: const Text('Retry')),
                  SizedBox(height: Ds.space.x24),
                ],
                Container(
                  decoration: BoxDecoration(
                    color: Ds.c.surface,
                    borderRadius: BorderRadius.circular(Ds.r.card),
                    boxShadow: Ds.elevation.e1,
                  ),
                  padding: EdgeInsets.all(Ds.space.x16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text((r?['computed_label'] ?? '').toString(),
                          style: Ds.t.caption),
                      SizedBox(height: Ds.space.x12),
                      for (final row in rows) _CoverageRow(row: row),
                    ],
                  ),
                ),
                SizedBox(height: Ds.space.x24),
                Container(
                  decoration: BoxDecoration(
                    color: Ds.c.surface,
                    borderRadius: BorderRadius.circular(Ds.r.card),
                    boxShadow: Ds.elevation.e1,
                  ),
                  padding: EdgeInsets.all(Ds.space.x16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text((policy['label'] ?? '').toString(),
                          style: Ds.t.body),
                      SizedBox(height: Ds.space.x12),
                      Wrap(
                        spacing: Ds.space.x8,
                        runSpacing: Ds.space.x8,
                        children: [
                          for (final o in options)
                            ChoiceChip(
                              label: Text((o['label'] ?? '').toString()),
                              selected: (o['mode'] ?? '').toString() == mode,
                              // Design QA: a bare ChoiceChip is ~32 px tall.
                              // The policy switch is a real decision on a real
                              // phone, so it gets a 44 px target.
                              padding: EdgeInsets.symmetric(
                                  horizontal: Ds.space.x12,
                                  vertical: Ds.space.x8),
                              onSelected: _busy
                                  ? null
                                  : (_) =>
                                      _setMode((o['mode'] ?? '').toString()),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _CoverageRow extends StatelessWidget {
  final Map<String, dynamic> row;
  const _CoverageRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final detail = (row['detail'] ?? '').toString();
    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((row['label'] ?? '').toString(), style: Ds.t.body),
                if (detail.isNotEmpty)
                  Text(detail, style: Ds.t.caption),
              ],
            ),
          ),
          SizedBox(width: Ds.space.x12),
          Text((row['value'] ?? '').toString(), style: Ds.t.subtitle),
        ],
      ),
    );
  }
}

class _CoverageSkeleton extends StatelessWidget {
  const _CoverageSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        for (var i = 0; i < 6; i++)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: Container(
              height: Ds.space.x48,
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: BorderRadius.circular(Ds.r.card),
              ),
            ),
          ),
      ],
    );
  }
}

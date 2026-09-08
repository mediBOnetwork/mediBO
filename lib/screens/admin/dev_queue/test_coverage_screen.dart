import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// CHANGE #634 — the coverage ledger, and it is a PRINTER.
///
/// Every word on this screen — the title, the percentage, the headline
/// sentence, each filter's label AND its count, each row's status, sub-line,
/// green-line and flake-line, the empty state, the recent-run rows — is built
/// by `test_coverage_home()` and printed verbatim. Nothing here counts,
/// divides, pluralises or formats a timestamp. A card that recomputed the
/// percentage would disagree with the number Om is watching the moment the
/// backend changed how it is measured, which is exactly the bug this shape
/// makes impossible.
///
/// The only local decisions are which glyph to draw and how to turn a tone
/// NAME into the fixed palette — the same two liberties every other Dev Queue
/// surface takes.
/// `test_coverage_home(filter)`. Injected so the screen stays Supabase-free
/// and pumps on the Dart VM in a widget test, exactly like the tools sheet.
typedef CoverageLoad = Future<Map<String, dynamic>> Function(String filter);

class TestCoverageScreen extends StatefulWidget {
  final DevQueueService? service;

  /// Test seam. When absent the screen builds its own service on first load —
  /// never in initState, so a VM test never touches Supabase.instance.
  final CoverageLoad? load;

  const TestCoverageScreen({super.key, this.service, this.load});

  @override
  State<TestCoverageScreen> createState() => _TestCoverageScreenState();
}

class _TestCoverageScreenState extends State<TestCoverageScreen> {
  DevQueueService? _svcCache;
  DevQueueService get _svc => _svcCache ??= (widget.service ?? DevQueueService());
  Map<String, dynamic> _payload = const {};
  String _filter = 'all';
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final p = widget.load != null
          ? await widget.load!(_filter)
          : await _svc.testCoverageHome(filter: _filter);
      if (!mounted) return;
      setState(() {
        _payload = p;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String _s(String key) => (_payload[key] ?? '').toString();

  List<Map<String, dynamic>> _list(dynamic raw) => ((raw as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  @override
  Widget build(BuildContext context) {
    final headline = Map<String, dynamic>.from(
        (_payload['headline'] as Map?) ?? const <String, dynamic>{});
    final filters = _list(_payload['filters']);
    final rows = _list(_payload['rows']);
    final runs = Map<String, dynamic>.from(
        (_payload['runs'] as Map?) ?? const <String, dynamic>{});

    return Scaffold(
      backgroundColor: kPageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: kBrand),
        title: Text(_s('title'),
            style: Ds.t.subtitle
                .copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
        actions: [
          Semantics(
            identifier: 'coverage_refresh',
            button: true,
            child: IconButton(
              icon: const Icon(Icons.refresh, color: kBrand),
              onPressed: _load,
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: kBorder),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const _CoverageSkeleton()
            : _error.isNotEmpty
                ? _ErrorState(message: _error, onRetry: _load)
                : RefreshIndicator(
                    color: kBrand,
                    onRefresh: _load,
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16,
                          Ds.space.x16, Ds.space.x32),
                      children: [
                        _headlineCard(headline),
                        SizedBox(height: Ds.space.x24),
                        _filterRow(filters),
                        SizedBox(height: Ds.space.x16),
                        if (rows.isEmpty)
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: Ds.space.x32),
                            child: Text(_s('empty_label'),
                                textAlign: TextAlign.center,
                                style: Ds.t.body.copyWith(color: kTextLo)),
                          )
                        else
                          for (final r in rows) _featureRow(r),
                        SizedBox(height: Ds.space.x24),
                        _runsSection(runs),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _headlineCard(Map<String, dynamic> h) {
    if (h.isEmpty) return const SizedBox.shrink();
    final tone = toneByName((h['tone'] ?? 'neutral').toString());
    return DqCard(
      accent: tone.fg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text((h['value'] ?? '').toString(),
              style: Ds.t.display
                  .copyWith(fontWeight: FontWeight.w700, color: tone.fg)),
          SizedBox(width: Ds.space.x12),
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x8),
            child: Text((h['label'] ?? '').toString(),
                style: Ds.t.caption.copyWith(
                    fontWeight: FontWeight.w600, color: kTextLo)),
          ),
        ]),
        SizedBox(height: Ds.space.x8),
        Text(_s('subtitle'), style: Ds.t.body.copyWith(color: kTextHi)),
        if ((h['sub'] ?? '').toString().isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text((h['sub'] ?? '').toString(),
              style: Ds.t.caption.copyWith(color: kTextLo)),
        ],
      ]),
    );
  }

  Widget _filterRow(List<Map<String, dynamic>> filters) {
    if (filters.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: Ds.space.x48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final f in filters)
            Padding(
              padding: EdgeInsets.only(right: Ds.space.x8),
              child: Semantics(
                identifier: 'coverage_filter_${f['key']}',
                button: true,
                child: ChoiceChip(
                  // The count is the backend's; this never counts the rows it
                  // was handed, which would be a different number the moment a
                  // filter is applied.
                  label: Text('${f['label']} ${f['count']}',
                      style: Ds.t.caption.copyWith(
                          fontWeight: FontWeight.w600,
                          color: f['selected'] == true ? Colors.white : kTextHi)),
                  selected: f['selected'] == true,
                  selectedColor: kBrand,
                  backgroundColor: Colors.white,
                  side: BorderSide(
                      color: f['selected'] == true ? kBrand : kBorder),
                  onSelected: (_) {
                    setState(() => _filter = (f['key'] ?? 'all').toString());
                    _load();
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _featureRow(Map<String, dynamic> r) {
    final tone = toneByName((r['tone'] ?? 'neutral').toString());
    final sub = (r['sub_label'] ?? '').toString();
    final green = (r['green_label'] ?? '').toString();
    final flake = (r['flake_label'] ?? '').toString();
    final entry = (r['entry'] ?? '').toString();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: DqCard(
        accent: tone.fg,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text((r['label'] ?? '').toString(),
                  style: Ds.t.body.copyWith(
                      fontWeight: FontWeight.w700, color: kTextHi)),
            ),
            SizedBox(width: Ds.space.x8),
            ToneChip(
                label: (r['status_label'] ?? '').toString(),
                tone: tone,
                icon: Icons.science_outlined),
          ]),
          SizedBox(height: Ds.space.x4),
          Text((r['feature_key'] ?? '').toString(),
              style: Ds.t.caption.copyWith(color: kTextLo)),
          if (sub.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(sub, style: Ds.t.caption.copyWith(color: kTextHi)),
          ],
          // An absent line is OMITTED, never printed as a dash: the backend
          // sends '' when it has nothing to say, and a dash would read as data.
          if (green.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(green, style: Ds.t.caption.copyWith(color: kTextLo)),
          ],
          if (flake.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(flake, style: Ds.t.caption.copyWith(color: kTextLo)),
          ],
          if (entry.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(entry, style: Ds.t.caption.copyWith(color: kTextLo)),
          ],
        ]),
      ),
    );
  }

  Widget _runsSection(Map<String, dynamic> runs) {
    if (runs.isEmpty) return const SizedBox.shrink();
    final rows = _list(runs['rows']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text((runs['title'] ?? '').toString(),
          style:
              Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
      SizedBox(height: Ds.space.x12),
      if (rows.isEmpty)
        Text((runs['none_label'] ?? '').toString(),
            style: Ds.t.caption.copyWith(color: kTextLo))
      else
        for (final r in rows)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x8),
            child: DqCard(
              padding: EdgeInsets.all(Ds.space.x12),
              child: Row(children: [
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((r['label'] ?? '').toString(),
                            style: Ds.t.body.copyWith(
                                fontWeight: FontWeight.w600, color: kTextHi)),
                        Text((r['sub'] ?? '').toString(),
                            style: Ds.t.caption.copyWith(color: kTextLo)),
                      ]),
                ),
                ToneChip(
                    label: (r['value'] ?? '').toString(),
                    tone: toneByName((r['tone'] ?? 'neutral').toString())),
              ]),
            ),
          ),
    ]);
  }
}

/// A skeleton, not a bare spinner — the design QA gate asks for the shape of
/// what is coming rather than an unanchored circle.
class _CoverageSkeleton extends StatelessWidget {
  const _CoverageSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget bar(double w, double h) => Container(
          width: w,
          height: h,
          margin: EdgeInsets.only(bottom: Ds.space.x8),
          decoration: BoxDecoration(
              color: kBorder, borderRadius: Ds.r.rButton),
        );
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        DqCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            bar(120, 32),
            bar(240, 14),
            bar(180, 12),
          ]),
        ),
        SizedBox(height: Ds.space.x24),
        for (var i = 0; i < 5; i++)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: DqCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [bar(200, 16), bar(140, 12)]),
            ),
          ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // The backend's own words, not a Dart fallback sentence.
          Text(message,
              textAlign: TextAlign.center,
              style: Ds.t.caption.copyWith(color: kTextLo)),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            height: 44,
            child: OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: kBrand),
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton)),
              child: Text(c('dev_queue.retry'),
                  style: Ds.t.body.copyWith(
                      color: kBrand, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
  }
}

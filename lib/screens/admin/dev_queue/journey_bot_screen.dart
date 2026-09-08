import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// CHANGE #635 — the journey bot's own surface, and it is a PRINTER.
///
/// Everything here — the title, the headline, each chip, each filter's label,
/// every journey row's scenario name and verdict, the role matrix, the nine
/// pipeline stages, the deploy gate's sentence, every gap's title and repro
/// command, the empty states and the footnote — is built by `autotest_home()`
/// and printed as it arrives. Nothing on this screen counts, divides,
/// pluralises, orders or names a tone. The `9 roles`, the `11 hostile
/// variants` and the `9 stages` are all rows in the database: a card that
/// recomputed any of them would start lying the moment somebody INSERTed a
/// tenth, which is exactly the shape #635 exists to make impossible.
///
/// The only local decisions are the two every Dev Queue surface takes: which
/// glyph to draw, and how to turn a tone NAME into the fixed palette.
typedef AutotestLoad = Future<Map<String, dynamic>> Function(String filter);

class JourneyBotScreen extends StatefulWidget {
  final DevQueueService? service;

  /// Test seam. When absent the screen builds its own service on first load —
  /// never in initState, so a VM test never touches Supabase.instance.
  final AutotestLoad? load;

  const JourneyBotScreen({super.key, this.service, this.load});

  @override
  State<JourneyBotScreen> createState() => _JourneyBotScreenState();
}

class _JourneyBotScreenState extends State<JourneyBotScreen> {
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
          : await _svc.autotestHome(filter: _filter);
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

  Map<String, dynamic> _map(dynamic raw) =>
      Map<String, dynamic>.from((raw as Map?) ?? const <String, dynamic>{});

  @override
  Widget build(BuildContext context) {
    final headline = _map(_payload['headline']);
    final chips = _list(_payload['chips']);
    final filters = _list(_payload['filters']);
    final rows = _list(_payload['rows']);
    final matrix = _list(_payload['matrix']);
    final pipeline = _list(_payload['pipeline']);
    final gaps = _list(_payload['gaps']);
    final smoke = _map(_payload['smoke']);
    final runs = _list(_payload['runs']);

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
            identifier: 'journey_bot_refresh',
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
            ? const _BotSkeleton()
            : _error.isNotEmpty
                ? _BotError(message: _error, onRetry: _load)
                : RefreshIndicator(
                    color: kBrand,
                    onRefresh: _load,
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16,
                          Ds.space.x16, Ds.space.x32),
                      children: [
                        _headlineCard(headline, chips),
                        SizedBox(height: Ds.space.x24),
                        if (smoke.isNotEmpty) ...[
                          _gateCard(smoke),
                          SizedBox(height: Ds.space.x24),
                        ],
                        if (pipeline.isNotEmpty) ...[
                          _section(_s('pipeline_title'), pipeline),
                          SizedBox(height: Ds.space.x24),
                        ],
                        if (matrix.isNotEmpty) ...[
                          _section(_s('matrix_title'), matrix),
                          SizedBox(height: Ds.space.x24),
                        ],
                        Text(_s('rows_title'),
                            style: Ds.t.subtitle.copyWith(
                                fontWeight: FontWeight.w700, color: kTextHi)),
                        SizedBox(height: Ds.space.x12),
                        _filterRow(filters),
                        SizedBox(height: Ds.space.x16),
                        if (rows.isEmpty)
                          Padding(
                            padding:
                                EdgeInsets.symmetric(vertical: Ds.space.x32),
                            child: Text(_s('empty_label'),
                                textAlign: TextAlign.center,
                                style: Ds.t.body.copyWith(color: kTextLo)),
                          )
                        else
                          for (final r in rows) _journeyRow(r),
                        SizedBox(height: Ds.space.x24),
                        _gapsSection(gaps),
                        SizedBox(height: Ds.space.x24),
                        if (runs.isNotEmpty) _section(_s('runs_title'), runs),
                        SizedBox(height: Ds.space.x24),
                        Text(_s('footnote'),
                            style: Ds.t.caption.copyWith(color: kTextLo)),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _headlineCard(Map<String, dynamic> h, List<Map<String, dynamic>> chips) {
    final sub = (h['sub_label'] ?? '').toString();
    return DqCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text((h['value'] ?? '').toString(),
              style: Ds.t.display
                  .copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
          SizedBox(width: Ds.space.x12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: Text((h['label'] ?? '').toString(),
                  style: Ds.t.caption.copyWith(
                      color: toneByName((h['tone'] ?? 'neutral').toString()).fg,
                      fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
        SizedBox(height: Ds.space.x8),
        Text(_s('subtitle'), style: Ds.t.body.copyWith(color: kTextHi)),
        if (sub.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(sub, style: Ds.t.caption.copyWith(color: kTextLo)),
        ],
        if (chips.isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final ch in chips)
                ToneChip(
                    label: (ch['label'] ?? '').toString(),
                    tone: toneByName((ch['tone'] ?? 'neutral').toString())),
            ],
          ),
        ],
      ]),
    );
  }

  /// The deploy gate. Its sentence and its tone are the backend's; this card
  /// never decides whether a smoke "counts".
  Widget _gateCard(Map<String, dynamic> smoke) {
    final tone = toneByName((smoke['tone'] ?? 'neutral').toString());
    final detail = (smoke['detail'] ?? '').toString();
    return DqCard(
      accent: tone.fg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(_s('smoke_title'),
                style: Ds.t.caption.copyWith(
                    color: kTextLo, fontWeight: FontWeight.w600)),
          ),
          ToneChip(
              label: (smoke['label'] ?? '').toString(),
              tone: tone,
              icon: Icons.verified_outlined),
        ]),
        if (detail.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(detail, style: Ds.t.caption.copyWith(color: kTextLo)),
        ],
      ]),
    );
  }

  /// One shape for the three payload-order lists that are label + value + tone:
  /// the pipeline stages, the role matrix and the recent runs.
  Widget _section(String title, List<Map<String, dynamic>> items) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style: Ds.t.subtitle
              .copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
      SizedBox(height: Ds.space.x12),
      for (final it in items)
        Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x8),
          child: DqCard(
            padding: EdgeInsets.all(Ds.space.x12),
            child: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          (it['label'] ?? it['status_label'] ?? '').toString(),
                          style: Ds.t.body.copyWith(
                              fontWeight: FontWeight.w600, color: kTextHi)),
                      if ((it['sub_label'] ?? it['note'] ?? '')
                          .toString()
                          .isNotEmpty) ...[
                        SizedBox(height: Ds.space.x4),
                        Text((it['sub_label'] ?? it['note'] ?? '').toString(),
                            style: Ds.t.caption.copyWith(color: kTextLo)),
                      ],
                    ]),
              ),
              SizedBox(width: Ds.space.x8),
              ToneChip(
                  label: (it['value'] ?? it['status_label'] ?? '').toString(),
                  tone: toneByName((it['tone'] ?? 'neutral').toString())),
            ]),
          ),
        ),
    ]);
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
                identifier: 'journey_bot_filter_${f['key']}',
                button: true,
                child: ChoiceChip(
                  selected: _filter == (f['key'] ?? '').toString(),
                  onSelected: (_) {
                    setState(() => _filter = (f['key'] ?? 'all').toString());
                    _load();
                  },
                  backgroundColor: Colors.white,
                  selectedColor: kBrand,
                  side: const BorderSide(color: kBorder),
                  shape: const StadiumBorder(),
                  label: Text((f['label'] ?? '').toString(),
                      style: Ds.t.caption.copyWith(
                          fontWeight: FontWeight.w600,
                          color: _filter == (f['key'] ?? '').toString()
                              ? Colors.white
                              : kTextHi)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _journeyRow(Map<String, dynamic> r) {
    final tone = toneByName((r['tone'] ?? 'neutral').toString());
    final err = (r['error'] ?? '').toString();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: DqCard(
        accent: tone.fg,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text((r['label'] ?? '').toString(),
                  style: Ds.t.body
                      .copyWith(fontWeight: FontWeight.w600, color: kTextHi)),
            ),
            SizedBox(width: Ds.space.x8),
            ToneChip(
                label: (r['verdict_label'] ?? '').toString(), tone: tone),
          ]),
          SizedBox(height: Ds.space.x4),
          Text(
              '${r['role_label'] ?? ''} · ${r['scenario_label'] ?? ''} · '
              '${r['steps_label'] ?? ''} · ${r['duration_label'] ?? ''}',
              style: Ds.t.caption.copyWith(color: kTextLo)),
          if (err.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(err, style: Ds.t.caption.copyWith(color: kTextHi)),
          ],
        ]),
      ),
    );
  }

  Widget _gapsSection(List<Map<String, dynamic>> gaps) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_s('gaps_title'),
          style: Ds.t.subtitle
              .copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
      SizedBox(height: Ds.space.x12),
      if (gaps.isEmpty)
        Text(_s('gaps_empty'), style: Ds.t.caption.copyWith(color: kTextLo))
      else
        for (final g in gaps)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x8),
            child: DqCard(
              padding: EdgeInsets.all(Ds.space.x12),
              accent: toneByName((g['tone'] ?? 'neutral').toString()).fg,
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text((g['title'] ?? '').toString(),
                    style: Ds.t.body
                        .copyWith(fontWeight: FontWeight.w600, color: kTextHi)),
                SizedBox(height: Ds.space.x4),
                Text((g['sub_label'] ?? '').toString(),
                    style: Ds.t.caption.copyWith(color: kTextLo)),
                if ((g['evidence'] ?? '').toString().isNotEmpty) ...[
                  SizedBox(height: Ds.space.x8),
                  Text((g['evidence'] ?? '').toString(),
                      style: Ds.t.caption.copyWith(color: kTextHi)),
                ],
                if ((g['repro_label'] ?? '').toString().isNotEmpty) ...[
                  SizedBox(height: Ds.space.x8),
                  Text((g['repro_label'] ?? '').toString(),
                      style: Ds.t.caption.copyWith(color: kTextLo)),
                ],
              ]),
            ),
          ),
    ]);
  }
}

/// A skeleton, not a bare spinner — the design QA gate asks for the shape of
/// what is coming rather than an unanchored circle.
class _BotSkeleton extends StatelessWidget {
  const _BotSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget bar(double w, double h) => Container(
          width: w,
          height: h,
          margin: EdgeInsets.only(bottom: Ds.space.x8),
          decoration:
              BoxDecoration(color: kBorder, borderRadius: Ds.r.rButton),
        );
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        DqCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            bar(140, 32),
            bar(260, 14),
            bar(200, 12),
          ]),
        ),
        SizedBox(height: Ds.space.x24),
        for (var i = 0; i < 6; i++)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: DqCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [bar(220, 16), bar(150, 12)]),
            ),
          ),
      ],
    );
  }
}

class _BotError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _BotError({required this.message, required this.onRetry});

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
                  style: Ds.t.body
                      .copyWith(color: kBrand, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
  }
}

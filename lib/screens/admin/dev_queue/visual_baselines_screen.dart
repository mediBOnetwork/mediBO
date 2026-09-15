import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import '../../../utils/toast.dart';
import '../../../utils/render_log.dart';
import '../../../utils/payment_proof.dart';
import '../../../widgets/payment_proof_image.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';
import 'visual_api.dart';

/// CHANGE #637 — the visual-regression review queue, and it is a PRINTER.
///
/// The lane photographs every registered screen per role at every active width
/// and measures it; `visual_baseline_home()` decides what each number MEANS and
/// sends the words. So this screen holds no threshold, no percentage
/// arithmetic, no "changed vs broken" rule and no sentence of its own: the
/// title, the headline, each filter AND its count, each row's status word, its
/// tone, its diff line, the two image captions, the button captions and both
/// toasts all arrive in the payload.
///
/// The one thing it does for itself is what every Dev Queue surface does —
/// resolve a tone NAME to the fixed palette and pick a glyph.
///
/// Approval is the whole point of the screen. A deliberate redesign is not a
/// defect that should scream every night: one tap makes this run's picture the
/// new baseline, and the backend closes the finding it raised.

/// `visual_baseline_home(p_filter)`.
typedef VisualHomeLoad = Future<Map<String, dynamic>> Function(String filter);

/// `visual_baseline_approve(p_shot_id)`.
typedef VisualApprove = Future<Map<String, dynamic>> Function(int shotId);

/// `visual_baseline_approve_run(p_run_id)`.
typedef VisualApproveRun = Future<Map<String, dynamic>> Function(int runId);

/// `visual_run_request(p_lane)`.
typedef VisualRunRequest = Future<Map<String, dynamic>> Function(String lane);

class VisualBaselinesScreen extends StatefulWidget {
  final DevQueueService? service;

  /// Test seams. When absent the screen builds its own service on first load —
  /// never in initState, so a VM test never touches Supabase.instance.
  final VisualHomeLoad? load;
  final VisualApprove? approve;
  final VisualApproveRun? approveRun;
  final VisualRunRequest? runRequest;

  /// How a private-bucket picture is fetched. Injected so the widget test
  /// pumps without Supabase; production passes the shared signed-URL loader.
  final PaymentProofLoader? imageLoader;

  const VisualBaselinesScreen({
    super.key,
    this.service,
    this.load,
    this.approve,
    this.approveRun,
    this.runRequest,
    this.imageLoader,
  });

  @override
  State<VisualBaselinesScreen> createState() => _VisualBaselinesScreenState();
}

class _VisualBaselinesScreenState extends State<VisualBaselinesScreen> {
  VisualBaselinesApi? _apiCache;
  VisualBaselinesApi get _api =>
      _apiCache ??= VisualBaselinesApi(widget.service ?? DevQueueService());

  Map<String, dynamic> _payload = const {};
  String _filter = 'review';
  bool _loading = true;
  bool _busy = false;
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
          : await _api.home(_filter);
      if (!mounted) return;
      // CHANGE #637 — the render-log key this screen is PROVEN by. A string in
      // the bundle only says the code compiled; this says the list painted, and
      // how many rows the backend actually handed it.
      RenderLog.write('c637_visual_rows',
          ((p['rows'] as List?) ?? const []).length);
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

  /// Every action ends the same way: show the BACKEND's message, reload, and
  /// let the payload say what the screen looks like now. Nothing is updated
  /// optimistically — an approval the server did not make must not appear made.
  Future<void> _act(Future<Map<String, dynamic>> Function() call) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final out = await call();
      if (!mounted) return;
      final msg = (out['message'] ?? '').toString();
      if (msg.isNotEmpty) {
        showToast(context, msg, isError: out['ok'] == false);
      }
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final headline = _map(_payload['headline']);
    final filters = _list(_payload['filters']);
    final rows = _list(_payload['rows']);
    final runs = _map(_payload['runs']);
    final approveAll = _map(_payload['approve_all']);
    final runNow = _map(_payload['run_now']);

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
            identifier: 'visual_refresh',
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
            ? const _VisualSkeleton()
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
                        SizedBox(height: Ds.space.x16),
                        _actionRow(approveAll, runNow),
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
                          for (final r in rows) _shotCard(r),
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
    final sub = (h['sub'] ?? '').toString();
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
                style: Ds.t.caption
                    .copyWith(fontWeight: FontWeight.w600, color: kTextLo)),
          ),
        ]),
        SizedBox(height: Ds.space.x8),
        Text(_s('subtitle'), style: Ds.t.body.copyWith(color: kTextHi)),
        // An absent line is omitted, never printed as a dash.
        if (sub.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(sub, style: Ds.t.caption.copyWith(color: kTextLo)),
        ],
      ]),
    );
  }

  Widget _actionRow(Map<String, dynamic> approveAll, Map<String, dynamic> runNow) {
    final canAll = approveAll['has'] == true;
    final runLabel = (runNow['label'] ?? '').toString();
    return Column(children: [
      if (canAll)
        Semantics(
          identifier: 'visual_approve_all',
          button: true,
          child: SizedBox(
            width: double.infinity,
            height: Ds.space.x48,
            child: ElevatedButton(
              onPressed: _busy
                  ? null
                  : () => _act(() => widget.approveRun != null
                      ? widget.approveRun!((approveAll['run_id'] as num).toInt())
                      : _api.approveRun((approveAll['run_id'] as num).toInt())),
              style: ElevatedButton.styleFrom(
                backgroundColor: kBrand,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              child: Text((approveAll['label'] ?? '').toString(),
                  style: Ds.t.body.copyWith(
                      color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      if (canAll && runLabel.isNotEmpty) SizedBox(height: Ds.space.x8),
      if (runLabel.isNotEmpty)
        Semantics(
          identifier: 'visual_run_now',
          button: true,
          child: SizedBox(
            width: double.infinity,
            height: Ds.space.x48,
            child: OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _act(() => widget.runRequest != null
                      ? widget.runRequest!('visual')
                      : _api.runRequest('visual')),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: kBrand),
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              child: Text(runLabel,
                  style: Ds.t.body
                      .copyWith(color: kBrand, fontWeight: FontWeight.w600)),
            ),
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
                identifier: 'visual_filter_${f['key']}',
                button: true,
                child: ChoiceChip(
                  // The count is the backend's — this never counts the rows it
                  // was handed, which is a different number under a filter.
                  label: Text('${f['label']} ${f['count']}',
                      style: Ds.t.caption.copyWith(
                          fontWeight: FontWeight.w600,
                          color:
                              f['selected'] == true ? Colors.white : kTextHi)),
                  selected: f['selected'] == true,
                  selectedColor: kBrand,
                  backgroundColor: Colors.white,
                  side: BorderSide(
                      color: f['selected'] == true ? kBrand : kBorder),
                  onSelected: (_) {
                    setState(() => _filter = (f['key'] ?? 'review').toString());
                    _load();
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _shotCard(Map<String, dynamic> r) {
    final tone = toneByName((r['tone'] ?? 'neutral').toString());
    final detail = (r['detail'] ?? '').toString();
    final diffLabel = (r['diff_label'] ?? '').toString();
    final reviewed = (r['reviewed_label'] ?? '').toString();
    final current = _map(r['current']);
    final baseline = _map(r['baseline']);
    final diff = _map(r['diff']);

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: DqCard(
        accent: tone.fg,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text((r['label'] ?? '').toString(),
                  style: Ds.t.body
                      .copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
            ),
            SizedBox(width: Ds.space.x8),
            ToneChip(
                label: (r['status_label'] ?? '').toString(),
                tone: tone,
                icon: Icons.photo_camera_outlined),
          ]),
          SizedBox(height: Ds.space.x4),
          Text((r['sub_label'] ?? '').toString(),
              style: Ds.t.caption.copyWith(color: kTextLo)),
          if (detail.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(detail, style: Ds.t.caption.copyWith(color: kTextHi)),
          ],
          if (diffLabel.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(diffLabel, style: Ds.t.caption.copyWith(color: kTextLo)),
          ],
          SizedBox(height: Ds.space.x12),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _shotPane(current)),
            // The approved picture is shown only when there IS one: an empty
            // frame beside "no approved baseline yet" would read as a blank
            // screenshot, which is a different finding entirely.
            if (baseline['has'] == true) ...[
              SizedBox(width: Ds.space.x8),
              Expanded(child: _shotPane(baseline)),
            ],
            if (diff['has'] == true) ...[
              SizedBox(width: Ds.space.x8),
              Expanded(child: _shotPane(diff)),
            ],
          ]),
          if (r['can_approve'] == true) ...[
            SizedBox(height: Ds.space.x12),
            Semantics(
              identifier: 'visual_approve_${r['shot_id']}',
              button: true,
              child: SizedBox(
                width: double.infinity,
                height: Ds.space.x48,
                child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _act(() => widget.approve != null
                          ? widget.approve!((r['shot_id'] as num).toInt())
                          : _api.approve((r['shot_id'] as num).toInt())),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: kBrand),
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                  ),
                  child: Text((r['approve_label'] ?? '').toString(),
                      style: Ds.t.body.copyWith(
                          color: kBrand, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ] else if (reviewed.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(reviewed, style: Ds.t.caption.copyWith(color: kTextLo)),
          ],
        ]),
      ),
    );
  }

  /// One captioned picture out of the PRIVATE artifact bucket. The bucket and
  /// the path are the backend's; the screen never builds a URL and never
  /// guesses a bucket.
  Widget _shotPane(Map<String, dynamic> pane) {
    final path = (pane['path'] ?? '').toString();
    final bucket = (pane['bucket'] ?? '').toString();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text((pane['label'] ?? '').toString(),
          style: Ds.t.caption
              .copyWith(fontWeight: FontWeight.w600, color: kTextLo)),
      SizedBox(height: Ds.space.x4),
      if (path.isEmpty)
        Container(
          height: 140,
          decoration: BoxDecoration(
              color: kPageBg, borderRadius: Ds.r.rButton),
        )
      else
        ClipRRect(
          borderRadius: Ds.r.rButton,
          child: PaymentProofImage(
            bucket: bucket,
            path: path,
            fixedHeight: 140,
            loader: widget.imageLoader,
          ),
        ),
      if ((pane['sub'] ?? '').toString().isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text((pane['sub'] ?? '').toString(),
            style: Ds.t.caption.copyWith(color: kTextLo)),
      ],
    ]);
  }

  Widget _runsSection(Map<String, dynamic> runs) {
    if (runs.isEmpty) return const SizedBox.shrink();
    final rows = _list(runs['rows']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text((runs['title'] ?? '').toString(),
          style: Ds.t.subtitle
              .copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
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
/// what is coming.
class _VisualSkeleton extends StatelessWidget {
  const _VisualSkeleton();

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
            bar(120, 32),
            bar(240, 14),
          ]),
        ),
        SizedBox(height: Ds.space.x24),
        for (var i = 0; i < 3; i++)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: DqCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [bar(200, 16), bar(140, 12), bar(double.infinity, 140)]),
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
                  style: Ds.t.body
                      .copyWith(color: kBrand, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
  }
}

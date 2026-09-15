import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #697 — the Feedback desk: NPS trend, dimension averages, and the
/// recent orders that need a callback. Zone-scoped for a partner (their own
/// zone, no picker), all zones for an admin — and that decision is
/// `order_feedback_screen()`'s, signalled by `zone_locked`, never a role test
/// written here.
///
/// Nothing on this screen is computed. Every number arrives already formatted
/// (`nps_label`, `avg_label`, `responses_label`, `worst_label`), every heading
/// comes from ui_copy, and every colour is a backend `tone` name.
class AdminFeedbackScreen extends StatefulWidget {
  const AdminFeedbackScreen({super.key});

  /// Test seam. Null in production means the real RPCs.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<AdminFeedbackScreen> createState() => _AdminFeedbackScreenState();
}

Color _tone(String tone) {
  switch (tone) {
    case 'success':
      return Ds.c.success;
    case 'warning':
      return Ds.c.warning;
    case 'danger':
      return Ds.c.danger;
    case 'brand':
      return Ds.c.brand;
    default:
      return Ds.c.info;
  }
}

Color _toneSoft(String tone) {
  switch (tone) {
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    case 'brand':
      return Ds.c.brandSoft;
    default:
      return Ds.c.infoSoft;
  }
}

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

List<Map<String, dynamic>> _rows(Object? v) => (v as List? ?? const [])
    .whereType<Map>()
    .map((e) => e.cast<String, dynamic>())
    .toList(growable: false);

class _AdminFeedbackScreenState extends State<AdminFeedbackScreen> {
  bool _loading = true;
  Map<String, dynamic> _p = const {};
  int? _zone;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final raw = await AdminFeedbackScreen.rpc(
          'order_feedback_screen', {'p_zone': _zone, 'p_weeks': 8});
      final data = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
      if (!mounted) return;
      setState(() {
        _p = data is Map ? data.cast<String, dynamic>() : const {};
        _loading = false;
      });
      RenderLog.write('c697_feedback_screen', _rows(_p['dimensions']).length);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(_p, 'title'))),
      body: _loading
          ? const _Skeleton()
          : (_p['ok'] != true)
              ? _Message(text: _s(_p, 'message'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.all(Ds.space.x16),
                    children: [
                      if (_p['zone_locked'] != true) _zonePicker(),
                      _headline(),
                      SizedBox(height: Ds.space.x24),
                      _section(_s(_p, 'nps_heading'), _trend()),
                      SizedBox(height: Ds.space.x24),
                      _section(_s(_p, 'dims_heading'), _dimensions()),
                      SizedBox(height: Ds.space.x24),
                      _section(_s(_p, 'worst_heading'), _worst()),
                      SizedBox(height: Ds.space.x32),
                    ],
                  ),
                ),
    );
  }

  Widget _zonePicker() {
    final zones = _rows(_p['zones']);
    if (zones.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x16),
      child: Wrap(
        spacing: Ds.space.x8,
        runSpacing: Ds.space.x8,
        children: [
          for (final z in zones)
            _Pill(
              label: _s(z, 'label'),
              selected: z['selected'] == true,
              onTap: () {
                final id = z['id'];
                setState(() => _zone = id is num ? id.toInt() : null);
                _load();
              },
            ),
        ],
      ),
    );
  }

  Widget _headline() {
    return _Card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x16, vertical: Ds.space.x12),
            decoration: BoxDecoration(
                color: _toneSoft(_s(_p, 'nps_tone')),
                borderRadius: Ds.r.rCard),
            child: Text(_s(_p, 'nps_label'),
                style: Ds.t.display.copyWith(color: _tone(_s(_p, 'nps_tone')))),
          ),
          SizedBox(width: Ds.space.x16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_s(_p, 'nps_hero'), style: Ds.t.bodyStrong),
                SizedBox(height: Ds.space.x4),
                Text(_s(_p, 'responses_label'), style: Ds.t.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String heading, Widget body) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(heading, style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        body,
      ],
    );
  }

  Widget _trend() {
    final rows = _rows(_p['trend']);
    if (rows.isEmpty) return _empty();
    return _Card(
      child: Column(
        children: [
          for (final w in rows)
            Padding(
              padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
              child: Row(
                children: [
                  SizedBox(
                      width: Ds.space.x48 + Ds.space.x24,
                      child: Text(_s(w, 'label'), style: Ds.t.caption)),
                  Expanded(
                      child: Text(_s(w, 'responses_label'),
                          style: Ds.t.caption)),
                  Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x8, vertical: Ds.space.x4),
                    decoration: BoxDecoration(
                        color: _toneSoft(_s(w, 'tone')),
                        borderRadius: Ds.r.rChip),
                    child: Text(_s(w, 'nps_label'),
                        style: Ds.t.caption
                            .copyWith(color: _tone(_s(w, 'tone')))),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _dimensions() {
    final rows = _rows(_p['dimensions']);
    if (rows.isEmpty) return _empty();
    return _Card(
      child: Column(
        children: [
          for (final d in rows)
            Padding(
              padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
              child: Row(
                children: [
                  Expanded(child: Text(_s(d, 'label'), style: Ds.t.body)),
                  Text(_s(d, 'avg_label'),
                      style: Ds.t.bodyStrong
                          .copyWith(color: _tone(_s(d, 'tone')))),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _worst() {
    final rows = _rows(_p['worst']);
    if (rows.isEmpty) return _empty();
    return Column(
      children: [
        for (final w in rows)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                          child: Text(_s(w, 'order_code'),
                              style: Ds.t.bodyStrong)),
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: Ds.space.x8, vertical: Ds.space.x4),
                        decoration: BoxDecoration(
                            color: _toneSoft(_s(w, 'tone')),
                            borderRadius: Ds.r.rChip),
                        child: Text(_s(w, 'worst_label'),
                            style: Ds.t.caption
                                .copyWith(color: _tone(_s(w, 'tone')))),
                      ),
                    ],
                  ),
                  SizedBox(height: Ds.space.x4),
                  Text('${_s(w, 'customer')} · ${_s(w, 'when_label')} · ${_s(w, 'nps_label')}',
                      style: Ds.t.caption),
                  if (w['has_reason'] == true) ...[
                    SizedBox(height: Ds.space.x8),
                    Text(_s(w, 'reason'), style: Ds.t.body),
                  ],
                  // One tap in. The destination is the BACKEND's link — this
                  // screen never assembles a route out of an id.
                  if (_s(w, 'open_link').isNotEmpty) ...[
                    SizedBox(height: Ds.space.x8),
                    SizedBox(
                      height: Ds.touch.minTarget,
                      child: TextButton(
                        onPressed: () => Navigator.of(context)
                            .pushNamed(_s(w, 'open_link')),
                        child: Text(_s(w, 'open_label')),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _empty() => _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s(_p, 'empty_title'), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x4),
            Text(_s(_p, 'empty_note'), style: Ds.t.caption),
          ],
        ),
      );
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) => Container(
        // Full width, always: a card that sizes to its own text (the empty
        // state) sits ragged beside the cards above it.
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: child,
      );
}

class _Pill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Pill(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: Ds.r.rChip,
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.space.x32),
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x12, vertical: Ds.space.x8),
          decoration: BoxDecoration(
            color: selected ? Ds.c.brandSoft : Ds.c.surface,
            borderRadius: Ds.r.rChip,
            border: Border.all(color: selected ? Ds.c.brand : Ds.c.divider),
          ),
          child: Text(label,
              style: selected
                  ? Ds.t.caption.copyWith(color: Ds.c.brand)
                  : Ds.t.caption),
        ),
      );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 5; i++)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: Container(
                height: Ds.space.x48,
                decoration:
                    BoxDecoration(color: Ds.c.surface, borderRadius: Ds.r.rCard),
              ),
            ),
        ],
      );
}

/// The backend's refusal, printed as it arrived.
class _Message extends StatelessWidget {
  final String text;
  const _Message({required this.text});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Text(text, style: Ds.t.bodySecondary),
        ),
      );
}

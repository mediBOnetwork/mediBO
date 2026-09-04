import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/toast.dart';

/// CHANGE #694 — Zone P&L (feature_gaps #157).
///
/// The same screen serves mediBO and the partner, because it is the same
/// payload: `zone_pnl()` returns one slice per zone the caller may see —
/// every zone for an admin, its own for a partner — with the cost lines
/// already filtered by `pnl_line_type.partner_visible`.
///
/// Nothing here is money arithmetic. Every rupee, every percentage, the split
/// sentence, the period labels and the margin tone arrive as strings from the
/// backend, which computes them from `pnl_order_v` and the settlement ledger
/// so the numbers reconcile with the partner's own statement.
class ZonePnlScreen extends StatefulWidget {
  const ZonePnlScreen({super.key});

  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<ZonePnlScreen> createState() => _ZonePnlScreenState();
}

class _ZonePnlScreenState extends State<ZonePnlScreen> {
  Map<String, dynamic> _p = const {};
  /// The RPC did not answer at all — a cancelled statement, an offline tab, a
  /// refusal with no body. There is no payload to render, so the screen says
  /// so in the backend's words instead of painting an empty page.
  bool _failed = false;
  bool _loading = true;
  bool _docBusy = false;
  String _period = 'month';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ZonePnlScreen.rpc('zone_pnl', {'p_period': _period});
      if (!mounted) return;
      final map = res is Map ? Map<String, dynamic>.from(res) : null;
      setState(() {
        _p = map ?? const {};
        // An empty answer is a FAILED answer. It used to be indistinguishable
        // from a refusal, and a refusal renders its own `message` — so a
        // cancelled statement painted a blank page with nothing on it.
        _failed = map == null || map.isEmpty;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _p = const {};
        _failed = true;
        _loading = false;
      });
    }
  }

  void _pickPeriod(String key) {
    if (key.isEmpty || key == _period) return;
    setState(() {
      _period = key;
      _loading = true;
    });
    _load();
  }

  /// Ask for the zone P&L as a document, poll on the backend's OWN `poll_ms`
  /// until it says ready, and open the file at the bucket and path IT named —
  /// the settlement statement's pattern, unchanged. The kind and the ref are
  /// the payload's: this screen never assembles a document reference, so a
  /// partner can only ever ask for the export the backend offered it.
  Future<void> _export(Map<String, dynamic> export) async {
    if (_docBusy) return;
    setState(() => _docBusy = true);
    try {
      var res = _asMap(await ZonePnlScreen.rpc('partner_doc_request', {
        'p_kind': (export['kind'] ?? '').toString(),
        'p_ref': (export['ref'] ?? '').toString(),
      }));
      var guard = 0;
      while (res['ok'] == true &&
          res['status'] == 'building' &&
          guard < 40 &&
          mounted) {
        guard++;
        final ms = int.tryParse('${res['poll_ms'] ?? 1500}') ?? 1500;
        await Future<void>.delayed(Duration(milliseconds: ms));
        res = _asMap(
            await ZonePnlScreen.rpc('partner_doc_status', {'p_id': res['doc_id']}));
      }
      if (!mounted) return;
      final msg = (res['message'] ?? '').toString();
      if (res['ok'] != true || res['status'] != 'ready') {
        if (msg.isNotEmpty) showToast(context, msg, isError: true);
        return;
      }
      final url = await Supabase.instance.client.storage
          .from((res['bucket'] ?? '').toString())
          .createSignedUrl((res['path'] ?? '').toString(),
              int.tryParse('${res['expires_s'] ?? 300}') ?? 300);
      if (!mounted) return;
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (mounted && msg.isNotEmpty) showToast(context, msg);
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _docBusy = false);
    }
  }

  static Map<String, dynamic> _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
          title: Text((_p['title'] ?? '').toString(), style: Ds.t.subtitle)),
      body: SafeArea(
        child: _loading
            ? ZonePnlView.skeleton()
            : _failed
            ? ZonePnlView.loadFailed(onRetry: _load)
            : RefreshIndicator(
                onRefresh: _load,
                child: ZonePnlView(
                  payload: _p,
                  onPeriod: _pickPeriod,
                  onExport: _export,
                  docBusy: _docBusy,
                ),
              ),
      ),
    );
  }
}

/// The rendered P&L, split from the screen so a protected test can pump a
/// payload with no Supabase and no timers.
class ZonePnlView extends StatelessWidget {
  const ZonePnlView({
    super.key,
    required this.payload,
    this.onPeriod,
    this.onExport,
    this.docBusy = false,
  });

  final Map<String, dynamic> payload;
  final ValueChanged<String>? onPeriod;
  final ValueChanged<Map<String, dynamic>>? onExport;
  final bool docBusy;

  static String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  static List<Map<String, dynamic>> _list(Map<String, dynamic> m, String k) =>
      ((m[k] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);

  /// The load itself failed, so there is no payload: the copy is `ui_copy`'s
  /// and the only action is to ask again.
  static Widget loadFailed({required VoidCallback onRetry}) => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(c('zone_pnl.load_failed'),
                  textAlign: TextAlign.center, style: Ds.t.body),
              SizedBox(height: Ds.space.x16),
              SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  onPressed: onRetry,
                  child: Text(c('zone_pnl.retry')),
                ),
              ),
            ],
          ),
        ),
      );

  static Widget skeleton() => Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < 4; i++)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Container(
                    height: Ds.space.x48,
                    decoration: BoxDecoration(
                        color: Ds.c.surface, borderRadius: Ds.r.rCard)),
              ),
          ],
        ),
      );

  Color _tone(String tone) => switch (tone) {
        'danger' => Ds.c.danger,
        'success' => Ds.c.success,
        _ => Ds.c.textSecondary,
      };

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] != true) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Text(_s(payload, 'message'),
              textAlign: TextAlign.center, style: Ds.t.body),
        ),
      );
    }

    final zones = _list(payload, 'zones');
    final periods = _list(payload, 'period_options');
    final labels = Map<String, dynamic>.from(
        (payload['tile_labels'] as Map?) ?? const <String, dynamic>{});

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(_s(payload, 'subtitle'), style: Ds.t.body),
        // The partner is told, in the backend's words, why its list is shorter.
        if (_s(payload, 'view_note').isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(_s(payload, 'view_note'), style: Ds.t.caption),
        ],
        SizedBox(height: Ds.space.x16),
        // The period picker is the payload's own list, and which one is
        // selected is the payload's own flag — never a local index.
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            for (final p in periods)
              ChoiceChip(
                label: Text(_s(p, 'label')),
                selected: p['active'] == true,
                onSelected:
                    onPeriod == null ? null : (_) => onPeriod!(_s(p, 'key')),
              ),
          ],
        ),
        SizedBox(height: Ds.space.x24),
        if (zones.isEmpty)
          Text(_s(payload, 'empty_note'), style: Ds.t.caption)
        else
          for (final z in zones) ...[
            _ZoneCard(
              zone: z,
              labels: labels,
              tone: _tone,
              payload: payload,
              onExport: onExport,
              docBusy: docBusy,
            ),
            SizedBox(height: Ds.space.x16),
          ],
        if (_list(payload, 'trend').isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(_s(payload, 'trend_heading'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          _Trend(points: _list(payload, 'trend')),
        ],
        SizedBox(height: Ds.space.x24),
        Text(_s(payload, 'reconcile_note'), style: Ds.t.caption),
      ],
    );
  }
}

class _ZoneCard extends StatelessWidget {
  const _ZoneCard({
    required this.zone,
    required this.labels,
    required this.tone,
    required this.payload,
    this.onExport,
    this.docBusy = false,
  });

  final Map<String, dynamic> zone;
  final Map<String, dynamic> labels;
  final Color Function(String) tone;
  final Map<String, dynamic> payload;
  final ValueChanged<Map<String, dynamic>>? onExport;
  final bool docBusy;

  static String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  Widget _tile(String label, String value, {Color? colour}) => Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(value, style: Ds.t.body.copyWith(color: colour)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final export = Map<String, dynamic>.from(
        (zone['export'] as Map?) ?? const <String, dynamic>{});
    final lines = ((zone['lines'] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_s(zone, 'zone_name'), style: Ds.t.subtitle),
              ),
              Text(_s(zone, 'split_label'), style: Ds.t.caption),
            ],
          ),
          SizedBox(height: Ds.space.x16),
          Wrap(
            spacing: Ds.space.x24,
            runSpacing: Ds.space.x12,
            children: [
              _tile('${labels['revenue'] ?? ''}', _s(zone, 'revenue_display')),
              _tile('${labels['gross'] ?? ''}', _s(zone, 'gross_display')),
              _tile('${labels['margin'] ?? ''}', _s(zone, 'margin_display'),
                  colour: tone(_s(zone, 'margin_tone'))),
              _tile('${labels['orders'] ?? ''}', _s(zone, 'orders')),
              _tile('${labels['partner'] ?? ''}', _s(zone, 'partner_display')),
              _tile('${labels['medibo'] ?? ''}', _s(zone, 'medibo_display')),
            ],
          ),
          if (lines.isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            Text((payload['costs_heading'] ?? '').toString(),
                style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
            for (final l in lines)
              Padding(
                padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
                child: Row(
                  children: [
                    Expanded(child: Text(_s(l, 'label'), style: Ds.t.body)),
                    SizedBox(width: Ds.space.x12),
                    // The sign is the backend's and it is already in the
                    // string: nothing here decides what is a cost.
                    Text(_s(l, 'amount_display'), style: Ds.t.body),
                  ],
                ),
              ),
          ],
          // The export is the backend's offer, not this card's idea: it draws
          // only when the payload sent one, it prints the label it was given,
          // and it hands `kind` and `ref` straight back. A zone with nobody to
          // send it to arrives has:false with the backend's own note.
          if (export['has'] == true && onExport != null) ...[
            SizedBox(height: Ds.space.x24),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: docBusy ? null : () => onExport!(export),
                child: Text(_s(export, 'label')),
              ),
            ),
          ] else if (_s(export, 'note').isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            Text(_s(export, 'note'), style: Ds.t.caption),
          ],
        ],
      ),
    );
  }
}

/// The trend, drawn from the payload's own points. The bar heights are the
/// only thing computed on this side, and they are geometry, not money.
class _Trend extends StatelessWidget {
  const _Trend({required this.points});

  final List<Map<String, dynamic>> points;

  /// The tallest a bar may draw. The box below is this PLUS the two caption
  /// lines and the gaps between them — summed from the parts it lays out with,
  /// never a round number typed here (#636's lesson: a hardcoded extent
  /// overflows silently the moment a part grows).
  static const double barMax = 88;
  static const double _captionLine = 18;

  static double get extent =>
      barMax + (_captionLine * 2) + (Ds.space.x4 * 3) + 4;

  @override
  Widget build(BuildContext context) {
    final maxRev = points
        .map((p) => (p['revenue'] as num?)?.toDouble() ?? 0)
        .fold<double>(0, (a, b) => b > a ? b : a);
    return SizedBox(
      height: extent,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final p in points)
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text('${p['revenue_display'] ?? ''}',
                        style: Ds.t.caption, maxLines: 1),
                    SizedBox(height: Ds.space.x4),
                    Container(
                      height: maxRev <= 0
                          ? 4
                          : 4 +
                              (barMax - 4) *
                                  (((p['revenue'] as num?)?.toDouble() ?? 0) /
                                      maxRev),
                      decoration: BoxDecoration(
                        color: Ds.c.brand,
                        borderRadius: Ds.r.rChip,
                      ),
                    ),
                    SizedBox(height: Ds.space.x4),
                    Text('${p['label'] ?? ''}',
                        style: Ds.t.caption, maxLines: 1),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

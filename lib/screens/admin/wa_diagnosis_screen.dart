// CHANGE #295 — WhatsApp delivery diagnosis.
//
// One RPC, printed verbatim. `wa_event_diagnosis()` walks every event route
// outside the supplier audience and returns, per event: whether it is on, which
// template it uses and whether Meta approved it, whether the variable map still
// matches that template, whether the code that should fire it actually goes
// through the route (or is still sending free-form text), the last N days of
// sent / delivered / failed, the dominant failure reason, and a one-word
// verdict.
//
// The screen decides NOTHING. Titles, column names, the legend, every label,
// every count sentence and every verdict word arrive in the payload. The only
// thing this file owns is the tone -> palette lookup, which is the same
// contract every other WhatsApp screen uses: an unrecognised tone renders grey
// with its label intact rather than blanking the page.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

/// The filter the summary chips drive. Pure so it can be tested without a
/// widget tree: 'all' keeps the backend's own order, any other key keeps only
/// the rows whose backend `verdict` equals it. The app never invents a verdict.
List<Map<String, dynamic>> waDiagFilter(
        List<Map<String, dynamic>> rows, String key) =>
    key == 'all'
        ? rows
        : rows.where((r) => r['verdict']?.toString() == key).toList();

/// The ONE place a backend tone becomes pixels on this screen.
(Color, Color) _tone(String? tone) => switch (tone) {
      'success' => (Ds.c.successSoft, Ds.c.success),
      'warning' => (Ds.c.warningSoft, Ds.c.warning),
      'danger' => (Ds.c.dangerSoft, Ds.c.danger),
      'info' => (Ds.c.infoSoft, Ds.c.info),
      _ => (Ds.c.bg, Ds.c.textSecondary),
    };

class WaDiagnosisScreen extends StatefulWidget {
  const WaDiagnosisScreen({super.key});

  @override
  State<WaDiagnosisScreen> createState() => _WaDiagnosisScreenState();
}

class _WaDiagnosisScreenState extends State<WaDiagnosisScreen> {
  Map<String, dynamic>? _p;
  String? _error;
  bool _loading = true;
  String _filter = 'all';

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
      final res = await Supabase.instance.client
          .rpc('wa_event_diagnosis', params: {'p_days': 30});
      final map = (res as Map).cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        _p = map;
        _loading = false;
        _error = (map['ok'] == true) ? null : (map['message']?.toString() ?? '');
      });
      final rows = (map['rows'] as List?) ?? const [];
      RenderLog.write('wa_diag_rows', rows.length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  List<Map<String, dynamic>> get _rows {
    final all = ((_p?['rows'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    return waDiagFilter(all, _filter);
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(p?['title']?.toString() ?? ''),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const _DiagSkeleton()
          : (_error != null && _error!.isNotEmpty)
              ? _ErrorState(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16,
                        Ds.space.x16, Ds.space.x32),
                    children: [
                      if ((p?['subtitle']?.toString() ?? '').isNotEmpty)
                        Text(p!['subtitle'].toString(), style: Ds.t.caption),
                      SizedBox(height: Ds.space.x16),
                      WaDiagSummaryChips(
                        items: ((p?['summary'] as List?) ?? const [])
                            .map((e) => (e as Map).cast<String, dynamic>())
                            .toList(),
                        selected: _filter,
                        onPick: (k) => setState(() => _filter = k),
                      ),
                      SizedBox(height: Ds.space.x24),
                      if (_rows.isEmpty)
                        _EmptyState(text: p?['empty_text']?.toString() ?? ''),
                      for (final r in _rows) ...[
                        WaDiagEventCard(row: r),
                        SizedBox(height: Ds.space.x12),
                      ],
                      if ((p?['legend']?.toString() ?? '').isNotEmpty) ...[
                        SizedBox(height: Ds.space.x12),
                        Text(p!['legend'].toString(), style: Ds.t.caption),
                      ],
                    ],
                  ),
                ),
    );
  }
}

class WaDiagSummaryChips extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final String selected;
  final ValueChanged<String> onPick;
  const WaDiagSummaryChips(
      {super.key,
      required this.items,
      required this.selected,
      required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Ds.space.x8,
      runSpacing: Ds.space.x8,
      children: [
        for (final s in items)
          _pill(
            key: s['key']?.toString() ?? 'all',
            label: s['label']?.toString() ?? '',
            value: s['value']?.toString() ?? '',
            tone: s['tone']?.toString(),
          ),
      ],
    );
  }

  Widget _pill(
      {required String key,
      required String label,
      required String value,
      String? tone}) {
    final (bg, fg) = _tone(tone);
    final on = selected == key;
    return InkWell(
      borderRadius: Ds.r.rChip,
      onTap: () => onPick(key),
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x8),
        decoration: BoxDecoration(
          color: on ? bg : Ds.c.surface,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: on ? fg : Ds.c.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(value,
                style: Ds.t.bodyStrong.copyWith(color: on ? fg : Ds.c.text)),
            SizedBox(width: Ds.space.x8),
            Text(label,
                style:
                    Ds.t.caption.copyWith(color: on ? fg : Ds.c.textSecondary)),
          ],
        ),
      ),
    );
  }
}

class WaDiagEventCard extends StatelessWidget {
  final Map<String, dynamic> row;
  const WaDiagEventCard({super.key, required this.row});

  @override
  Widget build(BuildContext context) {
    final (vbg, vfg) = _tone(row['verdict_tone']?.toString());
    final note = row['note']?.toString() ?? '';
    final fail = row['fail_reason']?.toString() ?? '';
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row['label']?.toString() ?? '',
                        style: Ds.t.subtitle),
                    SizedBox(height: Ds.space.x4),
                    Text(
                      '${row['event_key'] ?? ''} · ${row['audience'] ?? ''} · ${row['enabled_label'] ?? ''}',
                      style: Ds.t.caption,
                    ),
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x4),
                decoration:
                    BoxDecoration(color: vbg, borderRadius: Ds.r.rChip),
                child: Text(row['verdict']?.toString() ?? '',
                    style: Ds.t.caption.copyWith(color: vfg)),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          _Line(
              label: 'Template',
              value: row['template']?.toString() ?? '',
              badge: row['template_status']?.toString(),
              badgeTone: row['template_tone']?.toString()),
          _Line(
              label: 'Variables',
              value: row['variables_label']?.toString() ?? '',
              valueTone: row['variables_tone']?.toString()),
          _Line(
              label: 'Emitting',
              value: row['emitting_label']?.toString() ?? '',
              valueTone: row['emitting_tone']?.toString(),
              sub: row['emitters']?.toString()),
          _Line(
              label: 'Delivery',
              value: row['window_label']?.toString() ?? '',
              sub: fail == '—' ? null : fail),
          _Line(
              label: 'Last fired',
              value: row['last_fired']?.toString() ?? ''),
          if (note.isNotEmpty && note != '—') ...[
            SizedBox(height: Ds.space.x8),
            Text(note, style: Ds.t.caption),
          ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final String? badge;
  final String? badgeTone;
  final String? valueTone;
  const _Line(
      {required this.label,
      required this.value,
      this.sub,
      this.badge,
      this.badgeTone,
      this.valueTone});

  @override
  Widget build(BuildContext context) {
    final ink = valueTone == null || valueTone == 'neutral'
        ? Ds.c.text
        : _tone(valueTone).$2;
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: Ds.t.caption),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(value,
                          style: Ds.t.body.copyWith(color: ink)),
                    ),
                    if (badge != null && badge!.isNotEmpty) ...[
                      SizedBox(width: Ds.space.x8),
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: Ds.space.x8, vertical: Ds.space.x4),
                        decoration: BoxDecoration(
                            color: _tone(badgeTone).$1,
                            borderRadius: Ds.r.rChip),
                        child: Text(badge!,
                            style: Ds.t.caption
                                .copyWith(color: _tone(badgeTone).$2)),
                      ),
                    ],
                  ],
                ),
                if (sub != null && sub!.isNotEmpty && sub != '—')
                  Text(sub!, style: Ds.t.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String text;
  const _EmptyState({required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.all(Ds.space.x24),
        decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e1),
        child: Text(text, style: Ds.t.bodySecondary),
      );
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message,
                  textAlign: TextAlign.center, style: Ds.t.bodySecondary),
              SizedBox(height: Ds.space.x16),
              SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                    onPressed: onRetry, child: Text(c('wa_diagnosis.retry'))),
              ),
            ],
          ),
        ),
      );
}

class _DiagSkeleton extends StatelessWidget {
  const _DiagSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 6; i++)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: Container(
                height: 132,
                decoration: BoxDecoration(
                    color: Ds.c.surface,
                    borderRadius: Ds.r.rCard,
                    boxShadow: Ds.elevation.e1),
              ),
            ),
        ],
      );
}

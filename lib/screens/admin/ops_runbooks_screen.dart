// CHANGE #474 — Failure drills: the runbook shelf and its drill button.
//
// Six external dependencies mediBO does not own — WhatsApp, Gemini OCR, the
// supplier at the other end of the waterfall, the rider's phone, Razorpay and
// Postgres itself. Each one has a fallback in the codebase. This screen is
// where an operator reads what that fallback is at 2 a.m., and where anyone
// can prove it still works by deliberately breaking the thing.
//
// THE APP RENDERS. IT NEVER DECIDES. The title, the subtitle, every section
// heading, the manual steps, the drill note, the pass/fail chip, its tone, the
// timestamp sentence, the summary strip, the button captions and the empty and
// denied states all arrive inside `ops_runbooks_home()` / `ops_runbook_drill()`.
// There is no display string, no status→label switch and no date arithmetic in
// this file. The one thing chosen locally is what every screen chooses
// locally: a backend TONE NAME resolved to the fixed design palette.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// Resolves a backend tone name to the design palette. The server decides
/// which colour a chip wears; the app only knows what the names mean.
({Color bg, Color fg}) _tone(String name) {
  switch (name) {
    case 'success':
      return (bg: Ds.c.successSoft, fg: Ds.c.success);
    case 'warning':
      return (bg: Ds.c.warningSoft, fg: Ds.c.warning);
    case 'danger':
      return (bg: Ds.c.dangerSoft, fg: Ds.c.danger);
    case 'brand':
      return (bg: Ds.c.brandSoft, fg: Ds.c.brand);
    case 'info':
      return (bg: Ds.c.infoSoft, fg: Ds.c.info);
    default:
      return (bg: Ds.c.bg, fg: Ds.c.textSecondary);
  }
}

/// Thin RPC layer — one call per method, payload returned untouched.
/// Injected in tests; null in production means the real RPCs.
class RunbooksService {
  RunbooksService({SupabaseClient? client})
      : _c = client ?? Supabase.instance.client;

  final SupabaseClient _c;

  Map<String, dynamic> _asMap(dynamic raw) {
    final v = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> home() async =>
      _asMap(await _c.rpc('ops_runbooks_home'));

  Future<Map<String, dynamic>> drill(String key) async => _asMap(
      await _c.rpc('ops_runbook_drill', params: {'p_key': key}));
}

/// A backend-toned pill. Absent label → absent pill.
class RunbookPill extends StatelessWidget {
  const RunbookPill({super.key, required this.label, required this.tone});

  final String label;
  final String tone;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    final t = _tone(tone);
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: t.bg, borderRadius: Ds.r.rChip),
      child: Text(label,
          style:
              Ds.t.caption.copyWith(color: t.fg, fontWeight: FontWeight.w600)),
    );
  }
}

List<Map<String, dynamic>> _rows(dynamic raw) => raw is List
    ? raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false)
    : const <Map<String, dynamic>>[];

List<String> _strings(dynamic raw) => raw is List
    ? raw.map((e) => e.toString()).toList(growable: false)
    : const <String>[];

/// One runbook, drawn from its card map. Public so the protected test can
/// hand it a payload without a Supabase client anywhere in sight.
class RunbookCard extends StatelessWidget {
  const RunbookCard({
    super.key,
    required this.card,
    required this.onRun,
    this.busy = false,
  });

  final Map<String, dynamic> card;
  final ValueChanged<String> onRun;

  /// True while THIS card's drill is running — the caption swaps to the
  /// payload's own running_label and the button stops accepting taps.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final drill = Map<String, dynamic>.from(
        (card['drill'] as Map?) ?? const <String, dynamic>{});
    final button = Map<String, dynamic>.from(
        (card['button'] as Map?) ?? const <String, dynamic>{});
    final steps = _strings(card['steps']);
    final evidence = _rows(drill['evidence']);
    final owner = (card['owner_label'] ?? '').toString();
    final neverHint = (drill['never_hint'] ?? '').toString();
    final ran = (drill['ran_label'] ?? '').toString();
    final summary = (drill['summary'] ?? '').toString();
    final note = (drill['note'] ?? '').toString();

    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: Ds.space.x16),
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
                child: Text((card['title'] ?? '').toString(),
                    style: Ds.t.subtitle
                        .copyWith(fontWeight: FontWeight.w700)),
              ),
              SizedBox(width: Ds.space.x8),
              RunbookPill(
                  label: (drill['chip_label'] ?? '').toString(),
                  tone: (drill['chip_tone'] ?? '').toString()),
            ],
          ),
          if (owner.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(owner, style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          ],
          for (final s in _rows(card['sections'])) ...[
            SizedBox(height: Ds.space.x12),
            Text((s['heading'] ?? '').toString(),
                style: Ds.t.caption.copyWith(
                    color: Ds.c.textSecondary, fontWeight: FontWeight.w600)),
            SizedBox(height: Ds.space.x4),
            Text((s['body'] ?? '').toString(), style: Ds.t.body),
          ],
          if (steps.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text((card['steps_heading'] ?? '').toString(),
                style: Ds.t.caption.copyWith(
                    color: Ds.c.textSecondary, fontWeight: FontWeight.w600)),
            SizedBox(height: Ds.space.x4),
            for (final step in steps)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('•  ', style: Ds.t.body),
                    Expanded(child: Text(step, style: Ds.t.body)),
                  ],
                ),
              ),
          ],
          SizedBox(height: Ds.space.x16),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
                color: Ds.c.bg, borderRadius: Ds.r.rCard),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((drill['heading'] ?? '').toString(),
                    style: Ds.t.caption.copyWith(
                        color: Ds.c.textSecondary,
                        fontWeight: FontWeight.w600)),
                if (note.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(note, style: Ds.t.body),
                ],
                if (neverHint.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x8),
                  Text(neverHint,
                      style:
                          Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
                ],
                if (ran.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x8),
                  Text(ran,
                      style:
                          Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
                ],
                if (summary.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(summary, style: Ds.t.body),
                ],
                if (evidence.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x8),
                  Text((drill['evidence_heading'] ?? '').toString(),
                      style: Ds.t.caption.copyWith(
                          color: Ds.c.textSecondary,
                          fontWeight: FontWeight.w600)),
                  SizedBox(height: Ds.space.x4),
                  for (final e in evidence)
                    Padding(
                      padding: EdgeInsets.only(bottom: Ds.space.x4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 140,
                            child: Text((e['label'] ?? '').toString(),
                                style: Ds.t.caption
                                    .copyWith(color: Ds.c.textSecondary)),
                          ),
                          Expanded(
                              child: Text((e['value'] ?? '').toString(),
                                  style: Ds.t.caption)),
                        ],
                      ),
                    ),
                ],
                SizedBox(height: Ds.space.x12),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: FilledButton(
                    onPressed: busy
                        ? null
                        : () => onRun((button['key'] ?? '').toString()),
                    child: Text(busy
                        ? (button['running_label'] ?? '').toString()
                        : (button['label'] ?? '').toString()),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class OpsRunbooksScreen extends StatefulWidget {
  const OpsRunbooksScreen({super.key, this.service});

  final RunbooksService? service;

  @override
  State<OpsRunbooksScreen> createState() => _OpsRunbooksScreenState();
}

class _OpsRunbooksScreenState extends State<OpsRunbooksScreen> {
  late final RunbooksService _svc = widget.service ?? RunbooksService();

  Map<String, dynamic>? _p;
  bool _loading = true;
  String _error = '';
  String _busyKey = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final p = await _svc.home();
      if (!mounted) return;
      setState(() {
        _p = p;
        _error = '';
        _loading = false;
      });
      RenderLog.write('c474_runbooks', _rows(p['cards']).length.toString());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _run(String key) async {
    if (key.isEmpty || _busyKey.isNotEmpty) return;
    setState(() => _busyKey = key);
    Map<String, dynamic> res = const {};
    try {
      res = await _svc.drill(key);
    } catch (_) {
      res = const {};
    }
    if (!mounted) return;

    // The reply carries the SAME card shape the home list prints, so the row
    // updates in place from the backend's own answer — nothing is recomputed
    // here and nothing is guessed while the refetch is in flight.
    final card = (res['card'] as Map?)?.cast<String, dynamic>();
    setState(() {
      _busyKey = '';
      if (card != null && _p != null) {
        final cards = _rows(_p!['cards'])
            .map((c) => (c['key'] ?? '') == (card['key'] ?? '') ? card : c)
            .toList();
        _p = {..._p!, 'cards': cards};
      }
    });
    final line = (card?['drill'] as Map?)?['summary']?.toString() ?? '';
    if (line.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(line)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final ok = p != null && p['ok'] == true;
    final cards = ok ? _rows(p['cards']) : const <Map<String, dynamic>>[];
    final summary = ok
        ? Map<String, dynamic>.from(
            (p['summary'] as Map?) ?? const <String, dynamic>{})
        : const <String, dynamic>{};

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(ok ? (p['title'] ?? '').toString() : ''),
      ),
      body: _loading
          ? const _RunbooksSkeleton()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: EdgeInsets.all(Ds.space.x16),
                children: [
                  // A refusal or a read error prints the BACKEND's sentence.
                  if (p != null && p['ok'] == false)
                    Text((p['message'] ?? '').toString(), style: Ds.t.body)
                  else if (_error.isNotEmpty) ...[
                    Text(
                        (p?['error'] ?? '').toString().isEmpty
                            ? _error
                            : (p!['error']).toString(),
                        style: Ds.t.body),
                    SizedBox(height: Ds.space.x12),
                    OutlinedButton(
                        onPressed: _load,
                        child: Text((p?['retry'] ?? '').toString())),
                  ] else if (ok) ...[
                    Text((p['subtitle'] ?? '').toString(),
                        style:
                            Ds.t.body.copyWith(color: Ds.c.textSecondary)),
                    SizedBox(height: Ds.space.x12),
                    RunbookPill(
                        label: (summary['label'] ?? '').toString(),
                        tone: (summary['tone'] ?? '').toString()),
                    SizedBox(height: Ds.space.x24),
                    if (cards.isEmpty)
                      Text((p['empty'] ?? '').toString(), style: Ds.t.body),
                    for (final c in cards)
                      RunbookCard(
                        card: c,
                        busy: _busyKey == (c['key'] ?? '').toString(),
                        onRun: _run,
                      ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _RunbooksSkeleton extends StatelessWidget {
  const _RunbooksSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 4; i++)
            Container(
              height: 132,
              margin: EdgeInsets.only(bottom: Ds.space.x16),
              decoration: BoxDecoration(
                  color: Ds.c.surface, borderRadius: Ds.r.rCard),
            ),
        ],
      );
}

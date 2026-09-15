// CMD #429 — THE PAPER SALE PAD. The page they already write on, photographed.
//
// This screen exists for the pharmacy between #423's inventory and #411's POS:
// one that has stock in the ledger and bills nothing. In a rush hour the
// counter writes the sale on a pad. Retyping it into an app is not going to
// happen, so the app reads the pad instead.
//
// THE REVIEW PUTS THE PHOTO BESIDE THE LINES. That is the whole design of the
// second screen: a parsed line is only trustworthy next to the handwriting it
// came from, and a counter fixing "mtk lc" needs to see what they wrote. On a
// phone the page sits above the list and stays scrollable with it; on a wide
// viewport they sit side by side.
//
// AND IT SAYS WHAT IT IS NOT. `not_an_invoice` is printed on both surfaces, in
// the backend's own words: a paper sale moves stock and never becomes a bill or
// a GST entry. A counter must never be able to believe otherwise.
//
// THIS FILE COMPUTES NOTHING. Every chip, plural, quantity note, "already
// counted from an earlier photo", shortfall sentence and refusal arrives
// finished from paper_sale_home() / _sheet_get(). There is no tally arithmetic
// here, no date format and no decision about which line needs a human.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/paper_sale_api.dart';
import '../../utils/render_log.dart';
import 'pharmacy_expiry_screen.dart' show toneColor, toneSoft;

String _s(Object? v) => v == null ? '' : v.toString();
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

class PaperSaleScreen extends StatefulWidget {
  const PaperSaleScreen({super.key, this.rpc});

  /// Injected in tests so the screen is proven against a payload, not a network.
  final PaperRpc? rpc;

  @override
  State<PaperSaleScreen> createState() => _PaperSaleScreenState();
}

class _PaperSaleScreenState extends State<PaperSaleScreen> {
  Map<String, dynamic> _payload = const {};
  bool _loading = true;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PaperSaleApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    Map<String, dynamic> res;
    try {
      res = await _call('paper_sale_home', {'p_limit': 20});
    } catch (_) {
      res = const {};
    }
    if (!mounted) return;
    setState(() {
      _payload = res;
      _loading = false;
    });
    RenderLog.write('paper_sheets', _rows(res['sheets']).length);
    RenderLog.write('paper_screen', 1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s(_payload['title'])),
        backgroundColor: Ds.c.surface,
        elevation: 0,
      ),
      body: _loading
          ? const _PaperSkeleton()
          : _payload['ok'] != true
          ? _Refusal(message: _s(_payload['message']), onRetry: _load)
          : RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    final today = _m(_payload['today']);
    final sheets = _rows(_payload['sheets']);
    final settings = _m(_payload['settings']);
    final graduation = _m(_payload['graduation']);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(_s(_payload['subtitle']), style: Ds.t.caption),
        SizedBox(height: Ds.space.x16),
        _TodayCard(today: today),
        SizedBox(height: Ds.space.x16),
        // The hard rule, said on the screen the counter uses.
        _Note(text: _s(_payload['not_an_invoice']), tone: 'info'),
        SizedBox(height: Ds.space.x24),
        _Actions(actions: _rows(_payload['actions']), onPick: _startMode),
        if (graduation.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          _GraduationCard(card: graduation, onDismiss: _dismissGraduation),
        ],
        SizedBox(height: Ds.space.x24),
        _NudgeRow(settings: settings, onToggle: _setNudge),
        SizedBox(height: Ds.space.x24),
        if (sheets.isEmpty)
          _Empty(text: _s(_payload['empty']))
        else
          ...sheets.map(
            (s) => Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: _SheetCard(sheet: s, onOpen: () => _openSheet(s)),
            ),
          ),
      ],
    );
  }

  Future<void> _startMode(Map<String, dynamic> action) async {
    final res = await _call('paper_sale_start', {'p_mode': _s(action['key'])});
    if (!mounted) return;
    if (res['ok'] != true) {
      _toast(_s(res['message']));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _GuideSheet(payload: res),
    );
    if (mounted) _load();
  }

  Future<void> _setNudge(bool on) async {
    final res = await _call('paper_sale_settings_set', {
      'p_patch': {'nudge_enabled': on},
    });
    if (!mounted) return;
    _toast(_s(res['message']));
    _load();
  }

  Future<void> _dismissGraduation() async {
    await _call('paper_sale_settings_set', {
      'p_patch': {'dismiss_graduation': true},
    });
    if (mounted) _load();
  }

  Future<void> _openSheet(Map<String, dynamic> sheet) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PaperSheetScreen(
          sheetId: _s(sheet['sheet_id']),
          rpc: widget.rpc,
        ),
      ),
    );
    if (mounted) _load();
  }

  void _toast(String msg) {
    if (msg.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

// ─────────────────────────── ONE PAGE, AND ITS DOUBTS ───────────────────────

class PaperSheetScreen extends StatefulWidget {
  const PaperSheetScreen({super.key, required this.sheetId, this.rpc});
  final String sheetId;
  final PaperRpc? rpc;

  @override
  State<PaperSheetScreen> createState() => _PaperSheetScreenState();
}

class _PaperSheetScreenState extends State<PaperSheetScreen> {
  Map<String, dynamic> _payload = const {};
  bool _loading = true;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PaperSaleApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    Map<String, dynamic> res;
    try {
      res = await _call('paper_sale_sheet_get', {'p_sheet_id': widget.sheetId});
    } catch (_) {
      res = const {};
    }
    if (!mounted) return;
    setState(() {
      _payload = res;
      _loading = false;
    });
    RenderLog.write('paper_lines', _rows(res['lines']).length);
  }

  @override
  Widget build(BuildContext context) {
    final sheet = _m(_payload['sheet']);
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s(sheet['date_label'])),
        backgroundColor: Ds.c.surface,
        elevation: 0,
      ),
      body: _loading
          ? const _PaperSkeleton()
          : _payload['ok'] != true
          ? _Refusal(message: _s(_payload['message']), onRetry: _load)
          : LayoutBuilder(
              builder: (context, c) => c.maxWidth >= 900
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _photo()),
                        Expanded(child: _lines(sheet)),
                      ],
                    )
                  : _lines(sheet, leading: _photo()),
            ),
    );
  }

  /// The handwriting itself. A parsed line is only checkable against the page it
  /// came off, so the page is never more than a glance away.
  Widget _photo() {
    final shots = _rows(_payload['shots']);
    if (shots.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: shots
            .map(
              (s) => Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x8),
                child: ClipRRect(
                  borderRadius: Ds.r.rCard,
                  child: Container(
                    color: Ds.c.surface,
                    height: Ds.space.x48 * 4,
                    alignment: Alignment.center,
                    child: Text(_s(s['path']), style: Ds.t.caption),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _lines(Map<String, dynamic> sheet, {Widget? leading}) {
    final lines = _rows(_payload['lines']);
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        if (leading != null) leading,
        _Note(text: _s(_payload['not_an_invoice']), tone: 'info'),
        SizedBox(height: Ds.space.x16),
        if (_s(sheet['reason']).isNotEmpty) ...[
          _Note(text: _s(sheet['reason']), tone: 'warning'),
          SizedBox(height: Ds.space.x16),
        ],
        ...lines.map(
          (l) => Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: _LineCard(
              line: l,
              onSeedOpening: () => _seedOpening(l),
            ),
          ),
        ),
        if (sheet['can_confirm'] == true) ...[
          SizedBox(height: Ds.space.x24),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: _confirm,
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              child: Text(_s(_payload['confirm_label'])),
            ),
          ),
          SizedBox(height: Ds.space.x8),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              onPressed: _closeDay,
              style: OutlinedButton.styleFrom(
                foregroundColor: Ds.c.brand,
                side: BorderSide(color: Ds.c.divider),
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              child: Text(_s(_payload['close_label'])),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _seedOpening(Map<String, dynamic> line) async {
    final res = await _call('paper_sale_seed_opening', {
      'p_line_id': _s(line['line_id']),
    });
    if (!mounted) return;
    _toast(_s(res['message']));
    _load();
  }

  Future<void> _confirm() async {
    final res = await _call('paper_sale_confirm', {
      'p_sheet_id': widget.sheetId,
    });
    if (!mounted) return;
    _toast(_s(res['message']));
    if (res['ok'] == true) Navigator.of(context).pop();
  }

  Future<void> _closeDay() async {
    final res = await _call('paper_sale_close_day', {
      'p_sheet_id': widget.sheetId,
    });
    if (!mounted) return;
    if (res['ok'] != true) {
      _toast(_s(res['message']));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _ClosedSheet(payload: res),
    );
    if (mounted) Navigator.of(context).pop();
  }

  void _toast(String msg) {
    if (msg.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

// ─────────────────────────── the pieces ─────────────────────────────────────

class _TodayCard extends StatelessWidget {
  const _TodayCard({required this.today});
  final Map<String, dynamic> today;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: EdgeInsets.all(Ds.space.x16),
    decoration: BoxDecoration(
      color: Ds.c.surface,
      borderRadius: Ds.r.rCard,
      boxShadow: Ds.elevation.e1,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_s(today['label']), style: Ds.t.caption),
        SizedBox(height: Ds.space.x4),
        Text(_s(today['summary']), style: Ds.t.title),
      ],
    ),
  );
}

class _Actions extends StatelessWidget {
  const _Actions({required this.actions, required this.onPick});
  final List<Map<String, dynamic>> actions;
  final void Function(Map<String, dynamic>) onPick;

  @override
  Widget build(BuildContext context) => Column(
    children: actions.map((a) {
      final primary = a['primary'] == true;
      return Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x8),
        child: SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: primary
              ? FilledButton(
                  onPressed: () => onPick(a),
                  style: FilledButton.styleFrom(
                    backgroundColor: Ds.c.brand,
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                  ),
                  child: Text(_s(a['label'])),
                )
              : OutlinedButton(
                  onPressed: () => onPick(a),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Ds.c.brand,
                    side: BorderSide(color: Ds.c.divider),
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                  ),
                  child: Text(_s(a['label'])),
                ),
        ),
      );
    }).toList(),
  );
}

class _SheetCard extends StatelessWidget {
  const _SheetCard({required this.sheet, required this.onOpen});
  final Map<String, dynamic> sheet;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final chip = _m(sheet['chip']);
    return InkWell(
      onTap: onOpen,
      borderRadius: Ds.r.rCard,
      child: Container(
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
                  child: Text(_s(sheet['date_label']), style: Ds.t.bodyStrong),
                ),
                SizedBox(width: Ds.space.x8),
                _Chip(label: _s(chip['label']), tone: _s(chip['tone'])),
              ],
            ),
            SizedBox(height: Ds.space.x8),
            Row(
              children: [
                Text(_s(sheet['lines_label']), style: Ds.t.caption),
                if (_s(sheet['new_label']).isNotEmpty) ...[
                  SizedBox(width: Ds.space.x12),
                  Text(_s(sheet['new_label']), style: Ds.t.caption),
                ],
              ],
            ),
            if (_s(sheet['reason']).isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(
                _s(sheet['reason']),
                style: Ds.t.caption.copyWith(color: Ds.c.warning),
              ),
            ],
            if (_s(sheet['error']).isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(
                _s(sheet['error']),
                style: Ds.t.caption.copyWith(color: Ds.c.danger),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({required this.line, required this.onSeedOpening});
  final Map<String, dynamic> line;
  final VoidCallback onSeedOpening;

  @override
  Widget build(BuildContext context) {
    final chip = _m(line['chip']);
    final needs = line['needs_review'] == true;
    final counted = _s(line['counted_note']);
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(
          color: needs ? toneColor(_s(chip['tone'])) : Ds.c.divider,
        ),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // What was WRITTEN on the pad, verbatim. The matched product name
              // is shown under it — never instead of it.
              Expanded(child: Text(_s(line['seen']), style: Ds.t.bodyStrong)),
              SizedBox(width: Ds.space.x8),
              Text(_s(line['qty_label']), style: Ds.t.body),
              if (_s(chip['label']).isNotEmpty) ...[
                SizedBox(width: Ds.space.x8),
                _Chip(label: _s(chip['label']), tone: _s(chip['tone'])),
              ],
            ],
          ),
          if (_s(line['product']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(line['product']), style: Ds.t.caption),
          ],
          for (final k in const [
            'qty_note',
            'on_hand_label',
            'short_label',
            'match_label',
          ])
            if (_s(line[k]).isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(_s(line[k]), style: Ds.t.caption),
            ],
          if (counted.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(
              counted,
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
            ),
          ],
          if (line['offer_opening'] == true) ...[
            SizedBox(height: Ds.space.x12),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: onSeedOpening,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Ds.c.brand,
                  side: BorderSide(color: Ds.c.divider),
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                child: Text(_s(line['offer_opening_label'])),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NudgeRow extends StatelessWidget {
  const _NudgeRow({required this.settings, required this.onToggle});
  final Map<String, dynamic> settings;
  final void Function(bool) onToggle;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(Ds.space.x16),
    decoration: BoxDecoration(
      color: Ds.c.surface,
      borderRadius: Ds.r.rCard,
      boxShadow: Ds.elevation.e1,
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_s(settings['nudge_label']), style: Ds.t.body),
              SizedBox(height: Ds.space.x4),
              Text(_s(settings['nudge_help']), style: Ds.t.caption),
            ],
          ),
        ),
        Switch(
          value: settings['nudge_enabled'] == true,
          activeThumbColor: Ds.c.brand,
          onChanged: onToggle,
        ),
      ],
    ),
  );
}

class _GraduationCard extends StatelessWidget {
  const _GraduationCard({required this.card, required this.onDismiss});
  final Map<String, dynamic> card;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(Ds.space.x16),
    decoration: BoxDecoration(
      color: Ds.c.brandSoft,
      borderRadius: Ds.r.rCard,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_s(card['title']), style: Ds.t.bodyStrong),
        SizedBox(height: Ds.space.x8),
        // Their own numbers, counted by the backend — never a generic pitch.
        Text(_s(card['body']), style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),
        Row(
          children: [
            TextButton(onPressed: onDismiss, child: Text(_s(card['dismiss_label']))),
          ],
        ),
      ],
    ),
  );
}

class _GuideSheet extends StatelessWidget {
  const _GuideSheet({required this.payload});
  final Map<String, dynamic> payload;

  @override
  Widget build(BuildContext context) {
    final points = (payload['guide_points'] is List)
        ? (payload['guide_points'] as List).map(_s).toList()
        : const <String>[];
    return Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(payload['guide']), style: Ds.t.body),
          if (points.isNotEmpty) SizedBox(height: Ds.space.x16),
          ...points.map(
            (p) => Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: Ds.t.bodySize,
                    color: Ds.c.brand,
                  ),
                  SizedBox(width: Ds.space.x8),
                  Expanded(child: Text(p, style: Ds.t.caption)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClosedSheet extends StatelessWidget {
  const _ClosedSheet({required this.payload});
  final Map<String, dynamic> payload;

  @override
  Widget build(BuildContext context) {
    final reorder = _m(payload['reorder']);
    return Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(payload['title']), style: Ds.t.title),
          SizedBox(height: Ds.space.x8),
          Text(_s(payload['message']), style: Ds.t.body),
          if (_s(_m(payload['confirm'])['message']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_s(_m(payload['confirm'])['message']), style: Ds.t.caption),
          ],
          if (_s(_m(payload['confirm'])['short_note']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(
              _s(_m(payload['confirm'])['short_note']),
              style: Ds.t.caption.copyWith(color: Ds.c.warning),
            ),
          ],
          if (reorder.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            Text(_s(reorder['label']), style: Ds.t.bodyStrong),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.tone});
  final String label;
  final String tone;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Ds.space.x12,
        vertical: Ds.space.x4,
      ),
      decoration: BoxDecoration(
        color: toneSoft(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(label, style: Ds.t.caption.copyWith(color: toneColor(tone))),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, this.tone = 'info'});
  final String text;
  final String tone;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: toneSoft(tone),
        borderRadius: Ds.r.rCard,
      ),
      child: Text(text, style: Ds.t.caption.copyWith(color: Ds.c.text)),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(vertical: Ds.space.x48),
    child: Text(text, textAlign: TextAlign.center, style: Ds.t.bodySecondary),
  );
}

class _Refusal extends StatelessWidget {
  const _Refusal({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center, style: Ds.t.body),
          SizedBox(height: Ds.space.x16),
          OutlinedButton(onPressed: onRetry, child: const Text('↻')),
        ],
      ),
    ),
  );
}

class _PaperSkeleton extends StatelessWidget {
  const _PaperSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.all(Ds.space.x16),
    children: List.generate(
      4,
      (_) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: Container(
          height: Ds.space.x48 + Ds.space.x24,
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
          ),
        ),
      ),
    ),
  );
}

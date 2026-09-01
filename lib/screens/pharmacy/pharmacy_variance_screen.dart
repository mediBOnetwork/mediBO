// CMD #413 — Stock check: what was counted, against what was expected.
//
// OWNER ONLY, and not because this file says so. `pharmacy_shield_entry()`
// returns `is_owner`, resolved in the backend from the login itself — a #408
// pharmacy staff account reaches the same shop through `customer_users` and is
// refused by the RPC with its own copy. This screen makes no role test and
// holds no role name.
//
// The wording is deliberately flat. The report says what was counted and what
// was expected, and the note under it says the commonest cause of a short count
// is a sale that was never billed. It never says "theft" and never names a
// person as a cause: a shift carries the SHARE of a difference that matches the
// share it sold, which is a share of the movement, not a finding. Every one of
// those sentences is a `ui_copy` row, so softening a word is an UPDATE.
//
// The count sheet shows NO expected number while it is open. A count you can
// see the answer to is a copy, not a count — so `has_expected` is false until
// the sheet is submitted, and the backend simply does not send the numbers.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/pharmacy_shield_api.dart';
import '../../utils/render_log.dart';
import 'pharmacy_expiry_screen.dart';
import 'px_screen.dart';  // CMD #420 — the pharmacy exchange

String _s(Object? v) => v == null ? '' : v.toString();
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

// ── the chrome both surfaces share ──────────────────────────────────────────

class ShieldCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  const ShieldCard({super.key, required this.child, this.padding});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding ?? EdgeInsets.all(Ds.space.x16),
    decoration: BoxDecoration(
      color: Ds.c.surface,
      borderRadius: Ds.r.rCard,
      boxShadow: Ds.elevation.e1,
    ),
    child: child,
  );
}

class ShieldChip extends StatelessWidget {
  final String label;
  final String tone;
  const ShieldChip({super.key, required this.label, required this.tone});

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
      child: Text(
        label,
        style: Ds.t.caption.copyWith(color: toneColor(tone)),
      ),
    );
  }
}

/// A skeleton, not a bare spinner — the page keeps its shape while it loads.
class ShieldSkeleton extends StatelessWidget {
  const ShieldSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Ds.c.bg,
    body: ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        for (var i = 0; i < 4; i++)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x16),
            child: Container(
              height: Ds.space.x48,
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
              ),
            ),
          ),
      ],
    ),
  );
}

/// The backend's own refusal, printed.
///
/// A Retry appears ONLY when asking again could help: a request that never
/// landed. "This is an owner-only report" is an ANSWER, and offering to ask it
/// again would be a lie.
class ShieldRefusal extends StatelessWidget {
  final String message;
  final String? retryLabel;
  final VoidCallback? onRetry;
  const ShieldRefusal({
    super.key,
    required this.message,
    this.retryLabel,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Ds.c.bg,
    appBar: AppBar(
      backgroundColor: Ds.c.surface,
      surfaceTintColor: Ds.c.surface,
    ),
    body: Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: Ds.t.bodySecondary,
            ),
            if (onRetry != null && (retryLabel ?? '').isNotEmpty) ...[
              SizedBox(height: Ds.space.x24),
              SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  onPressed: onRetry,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Ds.c.brand,
                    side: BorderSide(color: Ds.c.brand),
                    shape: RoundedRectangleBorder(
                      borderRadius: Ds.r.rButton,
                    ),
                  ),
                  child: Text(retryLabel!),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

// ── the report ──────────────────────────────────────────────────────────────

class PharmacyVarianceScreen extends StatefulWidget {
  final ShieldRpc? rpc;
  const PharmacyVarianceScreen({super.key, this.rpc});

  @override
  State<PharmacyVarianceScreen> createState() => _PharmacyVarianceScreenState();
}

class _PharmacyVarianceScreenState extends State<PharmacyVarianceScreen> {
  Map<String, dynamic>? _report;
  String? _refusal;
  bool _failed = false;
  bool _starting = false;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PharmacyShieldApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    setState(() {
      _failed = false;
      _refusal = null;
    });
    try {
      final r = await _call('pharmacy_variance_report', {'p_days': 7});
      if (!mounted) return;
      if (r['ok'] != true) {
        setState(() => _refusal = _s(r['message']));
        return;
      }
      setState(() => _report = r);
      RenderLog.write('c413_variance_report', 1);
      RenderLog.write('c413_variance_items', _rows(r['items']).length);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    Map<String, dynamic> r;
    try {
      r = await _call('pharmacy_count_start', {'p_n': 10});
    } catch (_) {
      if (mounted) setState(() => _starting = false);
      return;
    }
    if (!mounted) return;
    setState(() => _starting = false);
    if (r['ok'] != true) {
      final msg = _s(r['message']);
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PharmacyCountSheetScreen(session: r, rpc: widget.rpc),
      ),
    );
    if (mounted) _boot();
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    if (_refusal != null) return ShieldRefusal(message: _refusal!);
    if (_failed) {
      return ShieldRefusal(message: '', retryLabel: 'Retry', onRetry: _boot);
    }
    if (r == null) return const ShieldSkeleton();

    final items = _rows(r['items']);
    final staff = _rows(r['staff']);

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        title: Text(_s(r['title']), style: Ds.t.subtitle),
      ),
      body: RefreshIndicator(
        onRefresh: _boot,
        child: ListView(
          padding: EdgeInsets.all(Ds.space.x16),
          children: [
            ShieldCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(r['period_label']), style: Ds.t.caption),
                  SizedBox(height: Ds.space.x4),
                  Text(_s(r['leaked_display']), style: Ds.t.title),
                  Text(_s(r['leaked_label']), style: Ds.t.caption),
                ],
              ),
            ),
            SizedBox(height: Ds.space.x24),

            if (items.isEmpty)
              ShieldCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(r['empty']), style: Ds.t.bodyStrong),
                    SizedBox(height: Ds.space.x4),
                    Text(_s(r['empty_hint']), style: Ds.t.caption),
                  ],
                ),
              )
            else
              for (final it in items) ...[
                ShieldCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(_s(it['headline']), style: Ds.t.body),
                      ),
                      SizedBox(width: Ds.space.x8),
                      Text(
                        _s(it['value_display']),
                        style: Ds.t.bodyStrong.copyWith(
                          color: toneColor(_s(it['tone'])),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: Ds.space.x12),
              ],

            SizedBox(height: Ds.space.x24),
            Text(_s(r['staff_title']), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x8),
            Text(_s(r['staff_note']), style: Ds.t.caption),
            SizedBox(height: Ds.space.x12),
            if (staff.isEmpty)
              ShieldCard(
                child: Text(_s(r['staff_empty']), style: Ds.t.bodySecondary),
              )
            else
              for (final st in staff) ...[
                ShieldCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _s(st['staff_label']),
                              style: Ds.t.bodyStrong,
                            ),
                          ),
                          Text(
                            _s(st['value_display']),
                            style: Ds.t.bodyStrong,
                          ),
                        ],
                      ),
                      SizedBox(height: Ds.space.x4),
                      Text(
                        '${_s(st['variance_label'])} · ${_s(st['share_label'])}',
                        style: Ds.t.caption,
                      ),
                      Text(_s(st['trend_label']), style: Ds.t.caption),
                    ],
                  ),
                ),
                SizedBox(height: Ds.space.x12),
              ],

            SizedBox(height: Ds.space.x24),
            Text(_s(r['cause_note']), style: Ds.t.caption),
            SizedBox(height: Ds.space.x24),
            SizedBox(
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: _starting ? null : _start,
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                child: Text(
                  _starting ? _s(r['starting']) : _s(r['start_button']),
                ),
              ),
            ),
            SizedBox(height: Ds.space.x32),
          ],
        ),
      ),
    );
  }
}

// ── the count sheet ─────────────────────────────────────────────────────────

class PharmacyCountSheetScreen extends StatefulWidget {
  final Map<String, dynamic> session;
  final ShieldRpc? rpc;
  const PharmacyCountSheetScreen({
    super.key,
    required this.session,
    this.rpc,
  });

  @override
  State<PharmacyCountSheetScreen> createState() =>
      _PharmacyCountSheetScreenState();
}

class _PharmacyCountSheetScreenState extends State<PharmacyCountSheetScreen> {
  late Map<String, dynamic> _sheet = widget.session;

  /// line_id → what the owner typed. A line left blank stays ABSENT from this
  /// map and is never sent: "I did not count it" and "I counted zero" are
  /// different facts.
  final Map<String, String> _counted = {};
  bool _saving = false;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PharmacyShieldApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    RenderLog.write('c413_count_sheet', _rows(_sheet['lines']).length);
  }

  Future<void> _submit() async {
    final lines = <Map<String, dynamic>>[];
    _counted.forEach((id, text) {
      final v = num.tryParse(text.trim());
      if (v != null) lines.add({'line_id': id, 'counted_qty': v});
    });
    setState(() => _saving = true);
    try {
      final r = await _call('pharmacy_count_submit', {
        'p_session_id': _s(_sheet['session_id']),
        'p_lines': lines,
      });
      if (!mounted) return;
      setState(() {
        _saving = false;
        if (r['ok'] == true) _sheet = r;
      });
      final msg = _s(r['toast']).isNotEmpty ? _s(r['toast']) : _s(r['message']);
      if (msg.isNotEmpty && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
      if (r['ok'] == true) {
        RenderLog.write('c413_count_result', _rows(r['lines']).length);
      }
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = _sheet['is_open'] == true;
    final lines = _rows(_sheet['lines']);
    final labels = _m(_sheet['labels']);
    final staff = _rows(_sheet['staff']);

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        title: Text(_s(_sheet['title']), style: Ds.t.subtitle),
      ),
      body: ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          if (_s(_sheet['hint']).isNotEmpty) ...[
            Text(_s(_sheet['hint']), style: Ds.t.caption),
            SizedBox(height: Ds.space.x16),
          ],
          if (!open) ...[
            ShieldCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(_sheet['leaked_display']), style: Ds.t.title),
                  Text(_s(_sheet['leaked_label']), style: Ds.t.caption),
                  if (_sheet['all_matched'] == true) ...[
                    SizedBox(height: Ds.space.x8),
                    Text(
                      _s(_sheet['clean_message']),
                      style: Ds.t.bodySecondary,
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(height: Ds.space.x24),
          ],

          for (final l in lines) ...[
            _CountRow(
              line: l,
              labels: labels,
              value: _counted[_s(l['line_id'])] ?? '',
              onChanged: open
                  ? (v) => _counted[_s(l['line_id'])] = v
                  : null,
            ),
            SizedBox(height: Ds.space.x12),
          ],

          if (!open && staff.isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            Text(_s(_sheet['staff_title']), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x8),
            Text(_s(_sheet['staff_note']), style: Ds.t.caption),
            SizedBox(height: Ds.space.x12),
            for (final st in staff) ...[
              ShieldCard(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _s(st['staff_label']),
                        style: Ds.t.bodyStrong,
                      ),
                    ),
                    Text(
                      '${_s(st['variance_label'])} · ${_s(st['value_display'])}',
                      style: Ds.t.body,
                    ),
                  ],
                ),
              ),
              SizedBox(height: Ds.space.x12),
            ],
          ],

          if (!open && _s(_sheet['cause_note']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            Text(_s(_sheet['cause_note']), style: Ds.t.caption),
          ],

          if (open) ...[
            SizedBox(height: Ds.space.x24),
            SizedBox(
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: _saving ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                child: Text(
                  _saving
                      ? _s(_sheet['submitting'])
                      : _s(_sheet['submit_button']),
                ),
              ),
            ),
          ],
          SizedBox(height: Ds.space.x32),
        ],
      ),
    );
  }
}

class _CountRow extends StatelessWidget {
  final Map<String, dynamic> line;
  final Map<String, dynamic> labels;
  final String value;
  final ValueChanged<String>? onChanged;
  const _CountRow({
    required this.line,
    required this.labels,
    required this.value,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hasExpected = line['has_expected'] == true;
    return ShieldCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(line['product_name']), style: Ds.t.bodyStrong),
          if (_s(line['pack_label']).isNotEmpty)
            Text(_s(line['pack_label']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x12),
          if (!hasExpected)
            SizedBox(
              height: Ds.touch.minTarget,
              child: TextField(
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: onChanged,
                style: Ds.t.body,
                decoration: InputDecoration(
                  labelText:
                      '${_s(labels['counted'])} (${_s(line['unit'])})',
                  labelStyle: Ds.t.caption,
                  filled: true,
                  fillColor: Ds.c.bg,
                  border: OutlineInputBorder(
                    borderRadius: Ds.r.rButton,
                    borderSide: BorderSide(color: Ds.c.divider),
                  ),
                ),
              ),
            )
          else ...[
            Wrap(
              spacing: Ds.space.x16,
              runSpacing: Ds.space.x4,
              children: [
                _Fact(
                  label: _s(labels['opening']),
                  value: _s(line['opening_label']),
                ),
                _Fact(
                  label: _s(labels['received']),
                  value: _s(line['received_label']),
                ),
                _Fact(
                  label: _s(labels['sold']),
                  value: _s(line['sold_label']),
                ),
                _Fact(
                  label: _s(labels['expected']),
                  value: _s(line['expected_label']),
                ),
                _Fact(
                  label: _s(labels['counted']),
                  value: _s(line['counted_label']),
                ),
              ],
            ),
            SizedBox(height: Ds.space.x12),
            Row(
              children: [
                ShieldChip(
                  label:
                      '${_s(line['state_label'])} ${_s(line['variance_label'])}',
                  tone: _s(line['tone']),
                ),
                const Spacer(),
                Text(
                  _s(line['variance_value_display']),
                  style: Ds.t.bodyStrong,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;
  const _Fact({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Text(label, style: Ds.t.caption),
      Text(value, style: Ds.t.bodyStrong),
    ],
  );
}

// ── the entry point ─────────────────────────────────────────────────────────

/// Boot-time cache of `pharmacy_shield_entry()`, so the tiles cost one call.
class PharmacyShieldEntry {
  PharmacyShieldEntry._();
  static final ValueNotifier<Map<String, dynamic>> value =
      ValueNotifier<Map<String, dynamic>>(const {});

  static Future<void> load({ShieldRpc? rpc}) async {
    try {
      final r = rpc != null
          ? await rpc('pharmacy_shield_entry', const {})
          : await PharmacyShieldApi.entry();
      value.value = r;
    } catch (_) {
      value.value = const {};
    }
  }
}

/// Renders NOTHING unless the backend said `show:true`, and renders the stock
/// check tile only for the tiles the backend actually sent — a staff login
/// never receives it, so this widget never has to know what a staff login is.
class PharmacyShieldTiles extends StatelessWidget {
  final VoidCallback? onBeforeOpen;
  const PharmacyShieldTiles({super.key, this.onBeforeOpen});

  static IconData _icon(String key) {
    switch (key) {
      case 'pharmacy_variance':
        return Icons.fact_check_outlined;
      default:
        return Icons.event_busy_outlined;
    }
  }

  static Widget? screenFor(String routeKey, {ShieldRpc? rpc}) {
    switch (routeKey) {
      case 'pharmacy_expiry':
        return PharmacyExpiryScreen(rpc: rpc);
      case 'pharmacy_variance':
        return PharmacyVarianceScreen(rpc: rpc);
      // CMD #420 — the pharmacy exchange. Registered here rather than in the
      // shell's own switch because it is a pharmacy's surface reached from the
      // admin console, exactly like the two above; px_home() gates on the
      // caller's own shop and renders its own refusal, so no role test here.
      case 'px_exchange':
        return PxScreen(rpc: rpc);
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<Map<String, dynamic>>(
        valueListenable: PharmacyShieldEntry.value,
        builder: (context, entry, _) {
          if (entry['show'] != true) return const SizedBox.shrink();
          final tiles = _rows(entry['tiles']);
          if (tiles.isEmpty) return const SizedBox.shrink();
          RenderLog.write('c413_shield_tiles', tiles.length);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final t in tiles)
                InkWell(
                  onTap: () {
                    final screen = screenFor(_s(t['route_key']));
                    if (screen == null) return;
                    onBeforeOpen?.call();
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(builder: (_) => screen),
                    );
                  },
                  borderRadius: Ds.r.rButton,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x4,
                      vertical: Ds.space.x12,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _icon(_s(t['route_key'])),
                          size: Ds.t.subtitleSize,
                          color: Ds.c.brand,
                        ),
                        SizedBox(width: Ds.space.x12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_s(t['label']), style: Ds.t.bodyStrong),
                              if (_s(t['sub_label']).isNotEmpty)
                                Text(
                                  _s(t['sub_label']),
                                  style: Ds.t.caption,
                                ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          size: Ds.t.subtitleSize,
                          color: Ds.c.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      );
}

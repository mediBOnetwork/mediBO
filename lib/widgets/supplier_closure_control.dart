// cmd #435 — the admin's close / reopen control for a supplier shop.
//
// #401 gave the SUPPLIER a switch for his own shop and gave admin a read-only
// line on the Collect card. The write endpoint — `admin_supplier_set_closed` —
// has been sitting there role-gated and unwired ever since, so the office could
// see that a shop was shut and could not shut one.
//
// This widget is the whole admin surface, and it DECIDES NOTHING. The chip's
// label and its three colours, the sheet's title, intro, hints, both button
// captions, the status line, the reason line, the 90-day history line and every
// history row are strings the backend composed in
// `admin_supplier_closure_panel()`; the toast after a write is the RPC's own
// `message`. There is deliberately no Dart fallback wording anywhere below: an
// empty backend string renders NOTHING rather than a word this file invented.
//
// The one thing Dart does own is the moment the admin picks a reopening time,
// because a date picker is an input, not an answer. The picked value is sent as
// an ISO-8601 UTC instant and comes back rendered in IST by the backend — the
// screen never formats a closure time itself.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../services/ui_copy.dart';
import '../utils/render_log.dart';
import '../utils/toast.dart';
import 'backend_chip.dart';

/// Reads one supplier's closure state out of the map returned by
/// `admin_supplier_closure_states`. Keyed on the trimmed lower-case name, which
/// is the same identity the backend matches closures on.
String supplierClosureKey(String supplierName) =>
    supplierName.trim().toLowerCase();

/// Turns `admin_supplier_closure_states(...)` into `{key: state}`.
Map<String, Map<String, dynamic>> supplierClosureStatesOf(Object? payload) {
  final out = <String, Map<String, dynamic>>{};
  if (payload is! Map) return out;
  final states = payload['states'];
  if (states is! List) return out;
  for (final s in states) {
    if (s is! Map) continue;
    final m = s.cast<String, dynamic>();
    final name = (m['supplier_name'] as String? ?? '').trim();
    if (name.isEmpty) continue;
    out[supplierClosureKey(name)] = m;
  }
  return out;
}

/// The row control: the backend's chip, in a tap target big enough for a thumb.
/// Renders nothing when the backend withheld the chip.
class SupplierClosureControl extends StatelessWidget {
  final String supplierName;
  final Map<String, dynamic>? state;
  final Future<void> Function() onChanged;

  const SupplierClosureControl({
    super.key,
    required this.supplierName,
    required this.state,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final chip = state == null ? null : backendChipOf(state!, 'chip');
    if (!backendChipVisible(chip)) return const SizedBox.shrink();
    RenderLog.write('admin_supplier_closure_chip', chip!['value'] ?? '');
    return Semantics(
      button: true,
      label: chip['label'] as String,
      child: InkWell(
        onTap: () => showSupplierClosureSheet(
          context,
          supplierName: supplierName,
          onChanged: onChanged,
        ),
        borderRadius: BorderRadius.circular(Ds.r.chip),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
            child: Center(child: BackendChip(chip: chip)),
          ),
        ),
      ),
    );
  }
}

/// Opens the availability sheet for [supplierName]. Sheets over dialogs, per
/// DESIGN.md. [onChanged] runs after a write lands so the caller can refresh
/// the list from the backend rather than patching its own copy of the state.
Future<void> showSupplierClosureSheet(
  BuildContext context, {
  required String supplierName,
  required Future<void> Function() onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
    ),
    builder: (_) => _SupplierClosureSheet(
      supplierName: supplierName,
      onChanged: onChanged,
    ),
  );
}

class _SupplierClosureSheet extends StatefulWidget {
  final String supplierName;
  final Future<void> Function() onChanged;
  const _SupplierClosureSheet({
    required this.supplierName,
    required this.onChanged,
  });

  @override
  State<_SupplierClosureSheet> createState() => _SupplierClosureSheetState();
}

class _SupplierClosureSheetState extends State<_SupplierClosureSheet> {
  final _reason = TextEditingController();
  Map<String, dynamic>? _panel;
  DateTime? _until;
  bool _loading = true;
  bool _saving = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final res = await Supabase.instance.client.rpc(
        'admin_supplier_closure_panel',
        params: {'p_supplier': widget.supplierName},
      );
      final m = res is Map ? res.cast<String, dynamic>() : <String, dynamic>{};
      if (!mounted) return;
      setState(() {
        _panel = m;
        _loading = false;
        // A refusal carries the backend's own message when it has one; the
        // machine slug is shown only when it sent nothing else.
        _error = m['ok'] == true
            ? ''
            : (m['message'] as String? ?? m['error'] as String? ?? '');
      });
      RenderLog.write('admin_supplier_closure_panel',
          m['closed'] == true ? 'closed' : 'open');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _pickUntil() async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: _until ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_until ?? now),
    );
    if (!mounted) return;
    setState(() {
      _until = DateTime(day.year, day.month, day.day, time?.hour ?? 0,
          time?.minute ?? 0);
    });
  }

  Future<void> _submit({required bool close}) async {
    setState(() => _saving = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'admin_supplier_set_closed',
        params: {
          'p_supplier': widget.supplierName,
          'p_closed': close,
          'p_until': close ? _until?.toUtc().toIso8601String() : null,
          'p_reason': close ? _reason.text.trim() : null,
        },
      );
      final m = res is Map ? res.cast<String, dynamic>() : <String, dynamic>{};
      final ok = m['ok'] == true;
      // The wording of both the success toast and the refusal is the
      // backend's; only the tone is chosen here.
      final message = m['message'] as String? ?? m['error'] as String? ?? '';
      if (!mounted) return;
      if (message.isNotEmpty) showToast(context, message, isError: !ok);
      RenderLog.write(
          'admin_supplier_closed_write', ok ? (close ? 'closed' : 'reopened') : 'refused');
      if (ok) {
        await widget.onChanged();
        if (mounted) Navigator.of(context).pop();
        return;
      }
      setState(() => _saving = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x16),
          child: _loading
              ? _skeleton()
              : (_panel?['ok'] == true ? _panelBody(_panel!) : _errorBody()),
        ),
      ),
    );
  }

  // A skeleton, not a bare spinner (DESIGN.md states rule).
  Widget _skeleton() => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _bar(widthFactor: 0.6, height: Ds.t.titleSize),
          SizedBox(height: Ds.space.x12),
          _bar(widthFactor: 1, height: Ds.t.bodySize),
          SizedBox(height: Ds.space.x8),
          _bar(widthFactor: 0.8, height: Ds.t.bodySize),
          SizedBox(height: Ds.space.x24),
          _bar(widthFactor: 1, height: Ds.touch.minTarget),
        ],
      );

  Widget _bar({required double widthFactor, required double height}) =>
      FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: widthFactor,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: Ds.c.divider,
            borderRadius: BorderRadius.circular(Ds.r.button),
          ),
        ),
      );

  Widget _errorBody() => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error.isNotEmpty) Text(_error, style: Ds.t.body),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: OutlinedButton(onPressed: _load, child: Text(_retryLabel())),
          ),
        ],
      );

  // Even the Retry caption is backend copy: a network failure means no payload
  // arrived, so it comes from the ui_copy cache (`supplier.closed_retry`)
  // rather than a word written here.
  String _retryLabel() =>
      (_panel?['retry_label'] as String? ?? c('supplier.closed_retry'));

  Widget _panelBody(Map<String, dynamic> p) {
    final closed = p['closed'] == true;
    final tone = (p['status_tone'] as String? ?? '');
    final history = (p['history'] as List?) ?? const [];
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _text(p['screen_title'], Ds.t.title),
          SizedBox(height: Ds.space.x12),
          Row(children: [
            Expanded(child: _text(p['status_label'], _statusStyle(tone))),
          ]),
          if ((p['reason_label'] as String? ?? '').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            _text(p['reason_label'], Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x4),
          _text(p['history_label'], Ds.t.caption),
          SizedBox(height: Ds.space.x24),
          _text(p['intro'], Ds.t.caption),
          SizedBox(height: Ds.space.x24),
          if (!closed) ..._closeForm(p) else ..._reopenForm(p),
          SizedBox(height: Ds.space.x32),
          _text(p['history_title'], Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
          if (history.isEmpty)
            _text(p['history_empty'], Ds.t.caption)
          else
            ...history.whereType<Map>().map((h) => _historyRow(h.cast<String, dynamic>())),
          SizedBox(height: Ds.space.x16),
        ],
      ),
    );
  }

  List<Widget> _closeForm(Map<String, dynamic> p) => [
        TextField(
          controller: _reason,
          style: Ds.t.body,
          decoration: InputDecoration(
            hintText: p['reason_hint'] as String? ?? '',
            hintStyle: Ds.t.caption,
          ),
        ),
        SizedBox(height: Ds.space.x16),
        _text(p['until_hint'], Ds.t.caption),
        SizedBox(height: Ds.space.x8),
        Row(children: [
          Expanded(
            child: SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: _saving ? null : _pickUntil,
                child: Text(
                  _until == null
                      ? (p['until_pick_label'] as String? ?? '')
                      : _untilDisplay(),
                  style: Ds.t.body,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          if (_until != null) ...[
            SizedBox(width: Ds.space.x8),
            SizedBox(
              height: Ds.touch.minTarget,
              child: TextButton(
                onPressed: _saving ? null : () => setState(() => _until = null),
                child: Text(p['until_clear_label'] as String? ?? '',
                    style: Ds.t.body),
              ),
            ),
          ],
        ]),
        SizedBox(height: Ds.space.x24),
        _primary(p['close_button'], () => _submit(close: true)),
      ];

  List<Widget> _reopenForm(Map<String, dynamic> p) => [
        _primary(p['reopen_button'], () => _submit(close: false)),
      ];

  // The picked instant, shown back to the admin in his own device locale until
  // the backend re-renders it in IST on the next payload. This is an INPUT
  // echo, never a closure time the screen composed.
  String _untilDisplay() {
    final d = _until!;
    final l = MaterialLocalizations.of(context);
    return '${l.formatFullDate(d)} ${l.formatTimeOfDay(TimeOfDay.fromDateTime(d))}';
  }

  Widget _primary(Object? label, VoidCallback onTap) {
    final text = (label as String? ?? '');
    if (text.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      width: double.infinity,
      height: Ds.touch.minTarget,
      child: ElevatedButton(
        onPressed: _saving ? null : onTap,
        child: Text(text, style: Ds.t.bodyStrong.copyWith(color: Ds.c.surface)),
      ),
    );
  }

  Widget _historyRow(Map<String, dynamic> h) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _text(h['label'], Ds.t.body),
            if ((h['reason_label'] as String? ?? '').isNotEmpty)
              _text(h['reason_label'], Ds.t.caption),
            _text(h['by_label'], Ds.t.caption),
          ],
        ),
      );

  /// The status line takes its colour from the payload's tone. An unknown tone
  /// is rendered as plain body text — never guessed into a colour.
  TextStyle _statusStyle(String tone) {
    switch (tone) {
      case 'success':
        return Ds.t.bodyStrong.copyWith(color: Ds.c.success);
      case 'warning':
        return Ds.t.bodyStrong.copyWith(color: Ds.c.warning);
      case 'danger':
        return Ds.t.bodyStrong.copyWith(color: Ds.c.danger);
      case 'info':
        return Ds.t.bodyStrong.copyWith(color: Ds.c.info);
      default:
        return Ds.t.body;
    }
  }

  /// Prints a backend string verbatim, or nothing at all when it is absent.
  Widget _text(Object? value, TextStyle style) {
    final s = (value as String? ?? '');
    if (s.isEmpty) return const SizedBox.shrink();
    return Text(s, style: style);
  }
}

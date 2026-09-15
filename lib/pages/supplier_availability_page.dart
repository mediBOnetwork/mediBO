import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';
import '../utils/toast.dart';

/// [S1] Supplier portal — Shop availability (cmd #401).
///
/// One RPC in (`supplier_availability_get`), two RPCs out
/// (`supplier_close_shop` / `supplier_reopen_shop`). Every word on this page —
/// the title, the intro, the status line, the "closed until" text, the toast —
/// is a `ui_copy` row arriving in the payload. Dart decides nothing here, not
/// even whether the shop reads as open: `closed` is the backend's boolean and
/// `status_label` is the backend's sentence.
class SupplierAvailabilityPage extends StatefulWidget {
  const SupplierAvailabilityPage({super.key});

  @override
  State<SupplierAvailabilityPage> createState() => _SupplierAvailabilityPageState();
}

class _SupplierAvailabilityPageState extends State<SupplierAvailabilityPage> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;
  bool _busy = false;
  final _reason = TextEditingController();
  DateTime? _until;

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

  String _s(Object? v) => v == null ? '' : v.toString();

  Future<void> _load() async {
    try {
      final r = await Supabase.instance.client.rpc('supplier_availability_get');
      if (!mounted) return;
      setState(() {
        _p = r is Map ? Map<String, dynamic>.from(r) : const {};
        _loading = false;
      });
      RenderLog.write('c401_avail', _p['closed'] == true ? 'closed' : 'open');
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _call(String fn, Map<String, dynamic>? params) async {
    setState(() => _busy = true);
    try {
      final r = await Supabase.instance.client.rpc(fn, params: params);
      final m = r is Map ? Map<String, dynamic>.from(r) : const <String, dynamic>{};
      if (mounted && _s(m['message']).isNotEmpty) {
        showToast(context, _s(m['message']), isError: m['error'] != null);
      }
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickUntil() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
        context: context, initialTime: const TimeOfDay(hour: 9, minute: 0));
    if (!mounted) return;
    setState(() => _until =
        DateTime(d.year, d.month, d.day, t?.hour ?? 9, t?.minute ?? 0));
  }

  @override
  Widget build(BuildContext context) {
    final closed = _p['closed'] == true;
    final history = (_p['history'] as List?)?.whereType<Map>().toList() ?? const [];
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(_p['screen_title']))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.all(Ds.space.x16),
              children: [
                _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _statusChip(closed),
                  SizedBox(height: Ds.space.x12),
                  Text(_s(_p['intro']), style: Ds.t.bodySecondary),
                  if (_s(_p['reason_label']).isNotEmpty) ...[
                    SizedBox(height: Ds.space.x8),
                    Text(_s(_p['reason_label']), style: Ds.t.caption),
                  ],
                  SizedBox(height: Ds.space.x8),
                  Text(_s(_p['history_label']), style: Ds.t.caption),
                ])),
                SizedBox(height: Ds.space.x24),
                if (!closed) _closeCard() else _reopenCard(),
                SizedBox(height: Ds.space.x24),
                _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_s(_p['history_title']), style: Ds.t.subtitle),
                  SizedBox(height: Ds.space.x12),
                  if (history.isEmpty)
                    Text(_s(_p['history_label']), style: Ds.t.caption)
                  else
                    for (final h in history) ...[
                      Padding(
                        padding: EdgeInsets.only(bottom: Ds.space.x8),
                        child: Row(children: [
                          Expanded(child: Text(_s(h['label']), style: Ds.t.body)),
                          if (_s(h['reason']).isNotEmpty)
                            Flexible(child: Text(_s(h['reason']), style: Ds.t.caption)),
                        ]),
                      ),
                    ],
                ])),
              ],
            ),
    );
  }

  Widget _card(Widget child) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
          boxShadow: Ds.elevation.e1,
        ),
        child: child,
      );

  /// The tone is the backend's (`status_tone`), so a closed shop can never be
  /// painted as an open one by a Dart branch that drifted.
  Widget _statusChip(bool closed) {
    final tone = _s(_p['status_tone']);
    final bg = tone == 'warning' ? Ds.c.warningSoft : Ds.c.successSoft;
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x8),
      decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
      child: Text(_s(_p['status_label']), style: Ds.t.body),
    );
  }

  Widget _closeCard() => _card(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _reason,
            decoration: InputDecoration(labelText: _s(_p['reason_hint'])),
          ),
          SizedBox(height: Ds.space.x16),
          InkWell(
            onTap: _busy ? null : _pickUntil,
            borderRadius: Ds.r.rButton,
            child: Container(
              constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
              alignment: Alignment.centerLeft,
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
              decoration: BoxDecoration(
                  border: Border.all(color: Ds.c.divider),
                  borderRadius: Ds.r.rButton),
              child: Text(
                  _until == null
                      ? _s(_p['until_hint'])
                      : _until!.toLocal().toString(),
                  style: Ds.t.bodySecondary),
            ),
          ),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: _busy
                  ? null
                  : () => _call('supplier_close_shop', {
                        'p_until': _until?.toUtc().toIso8601String(),
                        'p_reason': _reason.text.trim(),
                      }),
              child: Text(_s(_p['close_button'])),
            ),
          ),
        ],
      ));

  Widget _reopenCard() => _card(SizedBox(
        width: double.infinity,
        height: Ds.touch.minTarget,
        child: FilledButton(
          onPressed: _busy ? null : () => _call('supplier_reopen_shop', null),
          child: Text(_s(_p['reopen_button'])),
        ),
      ));
}

// lib/screens/admin/dev_queue/dev_queue_crashes.dart — CHANGE #473
//
// The Crashes card: the last 24 hours of client crashes, by release, on the
// super-admin Dev Queue screen — plus the "Send test crash" button that proves
// the whole path end to end from a real device.
//
// THE CARD COMPUTES NOTHING. Title, subtitle, state chip, every count label,
// every tone name, the empty state, the button's own label, its toasts, and —
// when Sentry is not connected yet — the numbered setup steps and their link
// all arrive from `crash_admin_card()` and are printed verbatim. Nothing here
// pluralises "crash", picks a colour from a number, or knows what a DSN is.
//
// Styled entirely from the `Ds` token layer (DESIGN.md): no colour, size,
// radius, shadow or padding literal lives in this file, so `ui_design_set()`
// restyles it with zero code change. `toneByName` is the shared Dev Queue
// resolver — the backend names a tone, the app looks the name up.
//
// Collapsed by default, like the control strip above it: this is a health
// readout, not the reason Om opened the screen.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../design_tokens.dart';
import '../../../services/crash_reporting.dart';
import '../../../utils/render_log.dart';
import '../../../utils/toast.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

class DevQueueCrashesCard extends StatefulWidget {
  final DevQueueService service;
  const DevQueueCrashesCard({super.key, required this.service});

  @override
  State<DevQueueCrashesCard> createState() => _DevQueueCrashesCardState();
}

class _DevQueueCrashesCardState extends State<DevQueueCrashesCard> {
  Map<String, dynamic> _card = const <String, dynamic>{};
  bool _loading = true;
  bool _expanded = false;
  bool _sending = false;
  int _buffered = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // The card is reachable before boot has finished wiring crash reporting
      // (and on a hot restart), so it makes sure the backend rules are loaded
      // before its own test button can raise anything. Idempotent — the boot
      // call and this one share a single future.
      await CrashReporting.ensureReady();
      final card = await widget.service.crashCard();
      final buffered = await CrashReporting.bufferedCount();
      if (!mounted) return;
      setState(() {
        _card = card;
        _buffered = buffered;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _sendTest() async {
    final btn = _map(_card['test_button']);
    setState(() => _sending = true);
    final ok = await CrashReporting.sendTestCrash();
    if (!mounted) return;
    setState(() => _sending = false);
    // Both toasts are the backend's words — the card never says "sent" itself.
    showToast(
        context, (ok ? btn['toast_ok'] : btn['toast_fail'])?.toString() ?? '');
    await _load();
  }

  Map<String, dynamic> _map(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

  List<Map<String, dynamic>> _list(dynamic v) => (v as List?)
          ?.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList() ??
      const <Map<String, dynamic>>[];

  String _s(dynamic v) => v?.toString() ?? '';

  @override
  Widget build(BuildContext context) {
    if (_loading || _card['ok'] != true) return const SizedBox.shrink();
    final state = _map(_card['state']);
    final tone = toneByName(_s(state['tone']));

    // Proof the card actually painted on the live build — a canvas app cannot
    // be read by a browser tool, so the render-log is the evidence.
    RenderLog.write('c473_crashes_card', 1);
    RenderLog.write('c473_crash_state', _s(state['label']));

    return Container(
      margin: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x8, Ds.space.x16, 0),
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: Ds.r.rChip,
          child: SizedBox(
            height: Ds.touch.minTarget,
            child: Row(children: [
              Icon(Icons.bug_report_outlined,
                  size: Ds.space.x16, color: Ds.c.textSecondary),
              SizedBox(width: Ds.space.x8),
              Text(_s(_card['title']),
                  style: Ds.t.body.copyWith(fontWeight: FontWeight.w700)),
              SizedBox(width: Ds.space.x8),
              Flexible(
                child: Text(_s(_card['total_label']),
                    overflow: TextOverflow.ellipsis, style: Ds.t.caption),
              ),
              const Spacer(),
              ToneChip(label: _s(state['label']), tone: tone),
            ]),
          ),
        ),
        if (_expanded) ...[
          SizedBox(height: Ds.space.x12),
          Text(_s(_card['subtitle']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x12),
          ..._rows(),
          if (_s(_card['fetched_label']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_s(_card['fetched_label']), style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x24),
          _testButton(),
          _setup(),
        ],
      ]),
    );
  }

  List<Widget> _rows() {
    final rows = _list(_card['rows']);
    if (rows.isEmpty) {
      return [Text(_s(_card['empty_label']), style: Ds.t.caption)];
    }
    return [
      for (final r in rows)
        Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x8),
          child: Row(children: [
            Expanded(
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_s(r['release']), style: Ds.t.body),
                if (_s(r['sub_label']).isNotEmpty)
                  Text(_s(r['sub_label']), style: Ds.t.caption),
              ]),
            ),
            SizedBox(width: Ds.space.x12),
            ToneChip(
                label: _s(r['count_label']), tone: toneByName(_s(r['tone']))),
          ]),
        ),
    ];
  }

  Widget _testButton() {
    final btn = _map(_card['test_button']);
    if (btn['enabled'] != true) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: double.infinity,
        height: Ds.touch.minTarget,
        child: OutlinedButton.icon(
          onPressed: _sending ? null : _sendTest,
          icon: _sending
              ? SizedBox(
                  width: Ds.space.x16,
                  height: Ds.space.x16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Ds.c.brand))
              : Icon(Icons.warning_amber_rounded,
                  size: Ds.space.x16, color: Ds.c.brand),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: Ds.c.brand),
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          ),
          label: Text(_s(btn['label']),
              style: Ds.t.body
                  .copyWith(fontWeight: FontWeight.w600, color: Ds.c.brand)),
        ),
      ),
      SizedBox(height: Ds.space.x8),
      Text(_s(btn['hint']), style: Ds.t.caption),
      if (_buffered > 0) ...[
        SizedBox(height: Ds.space.x4),
        // A count, not a sentence: how many events THIS device is still
        // holding because it could not reach the backend.
        Row(children: [
          Icon(Icons.smartphone,
              size: Ds.space.x12, color: Ds.c.textSecondary),
          SizedBox(width: Ds.space.x4),
          Text('$_buffered', style: Ds.t.caption),
        ]),
      ],
    ]);
  }

  Widget _setup() {
    final setup = _map(_card['setup']);
    if (setup['needed'] != true) return const SizedBox.shrink();
    final steps = _list(setup['steps']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(height: Ds.space.x24),
      Divider(height: 1, color: Ds.c.divider),
      SizedBox(height: Ds.space.x16),
      Text(_s(setup['title']),
          style: Ds.t.body.copyWith(fontWeight: FontWeight.w700)),
      if (_s(setup['note']).isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text(_s(setup['note']), style: Ds.t.caption),
      ],
      SizedBox(height: Ds.space.x12),
      for (final step in steps) _step(step),
    ]);
  }

  Widget _step(Map<String, dynamic> step) {
    final action = _map(step['action']);
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: Ds.space.x24,
          child: Text('${step['n']}.', style: Ds.t.caption),
        ),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_s(step['text']), style: Ds.t.body),
            if (action.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              _actionChip(action),
            ],
          ]),
        ),
      ]),
    );
  }

  /// A copy chip or a link chip — which one is the BACKEND's `kind`, so a new
  /// step with a different affordance needs no deploy.
  Widget _actionChip(Map<String, dynamic> action) {
    final kind = _s(action['kind']);
    final label = _s(action['label']);
    final value = _s(action['value']);
    if (value.isEmpty) return const SizedBox.shrink();

    Future<void> tap() async {
      if (kind == 'link') {
        final uri = Uri.tryParse(value);
        if (uri != null) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
        return;
      }
      await Clipboard.setData(ClipboardData(text: value));
      if (!mounted) return;
      showToast(context, value);
    }

    return InkWell(
      onTap: tap,
      borderRadius: Ds.r.rChip,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x8),
        decoration: BoxDecoration(
          color: Ds.c.bg,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(kind == 'link' ? Icons.open_in_new : Icons.copy_all_outlined,
              size: Ds.space.x16, color: Ds.c.brand),
          SizedBox(width: Ds.space.x8),
          Flexible(
            child: Text(kind == 'link' ? label : value,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.caption.copyWith(
                    color: Ds.c.brand, fontWeight: FontWeight.w500)),
          ),
        ]),
      ),
    );
  }
}

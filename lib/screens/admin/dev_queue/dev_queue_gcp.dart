import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/ui_copy.dart';
import '../../../utils/toast.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// GCP Control — the super-admin cockpit for the VM/cloud, rendered entirely
/// from `dev_gcp_get` (polled 15s). Every one-tap action enqueues a gcp command
/// the runner executes; the app only renders state and sends intent. Danger
/// actions (restart) and the budget cap are PIN-gated by the backend.
class GcpControlScreen extends StatefulWidget {
  final DevQueueService service;
  const GcpControlScreen({super.key, required this.service});

  @override
  State<GcpControlScreen> createState() => _GcpControlScreenState();
}

class _GcpControlScreenState extends State<GcpControlScreen> {
  Timer? _poll;
  Map<String, dynamic> _g = const {};
  bool _loading = true;
  bool _busy = false;
  bool _autoCleanPending = false;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final g = await widget.service.gcpGet();
      // Is an auto disk-clean command already queued/building today? The runner
      // names it "Auto: free disk space" — match by that title prefix.
      bool autoClean = false;
      try {
        final l = await widget.service.list(search: 'Auto: free disk space');
        final rows = (l['rows'] as List?)?.whereType<Map>() ?? const [];
        autoClean = rows.any((r) {
          final st = (r['status'] ?? '').toString();
          final t = (r['title'] ?? '').toString();
          return t.startsWith('Auto: free disk space') &&
              (st == 'pending' || st == 'building');
        });
      } catch (_) {/* best-effort note only */}
      if (mounted) setState(() { _g = g; _autoCleanPending = autoClean; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, dynamic> get _uptime =>
      (_g['uptime'] as Map?)?.cast<String, dynamic>() ?? const {};

  /// Percent used parsed from status.disk (e.g. "26G / 30G (93%)"); -1 if absent.
  int get _diskPct {
    final m = RegExp(r'\((\d+)%\)').firstMatch((_status['disk'] ?? '').toString());
    return m == null ? -1 : int.parse(m.group(1)!);
  }

  int get _diskAlertPct {
    final v = _sec['disk_alert_pct'];
    return v is num ? v.toInt() : 85;
  }

  Map<String, dynamic> get _sec =>
      (_g['security'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get _budget =>
      (_g['budget'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get _status =>
      (_g['status'] as Map?)?.cast<String, dynamic>() ?? const {};
  bool get _frozen => _sec['frozen'] == true;
  bool get _pinSet => _sec['pin_set'] == true;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load(silent: true);
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Ask for the 4-8 digit PIN in a small dialog; returns it or null.
  Future<String?> _askPin(String prompt) async {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(prompt),
        content: TextField(
          controller: ctl,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          decoration: InputDecoration(hintText: c('dev_queue.gcp_pin_hint')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(c('dev_queue.btn_cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctl.text.trim()),
              style: FilledButton.styleFrom(backgroundColor: kBrand),
              child: Text(c('dev_queue.btn_submit'))),
        ],
      ),
    );
  }

  Future<void> _action(String action, {bool needsPin = false}) async {
    String? pin;
    if (needsPin) {
      pin = await _askPin(c('dev_queue.gcp_pin_confirm'));
      if (pin == null || pin.isEmpty) return;
    }
    await _run(() async {
      final res = await widget.service.gcpAction(action, pin: pin);
      final id = res['id'];
      if (mounted && id != null) {
        showToast(context, cf('dev_queue.gcp_queued', {'id': '$id'}));
      } else if (mounted && (res['ok'] == false)) {
        showToast(context, c('dev_queue.gcp_action_refused'), isError: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kPageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: kBrand),
        title: Text((_g['screen_title'] ?? c('dev_queue.gcp_title')).toString(),
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700, color: kTextHi)),
        actions: [
          if (!_loading)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(child: _siteChip()),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: kBorder),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kBrand))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                if (_frozen) _frozenBanner() else ...[
                  if (!_pinSet) _pinBanner(),
                  _panelCard(),
                  const SizedBox(height: 12),
                  _costCard(),
                  const SizedBox(height: 12),
                  _actionsCard(),
                  const SizedBox(height: 12),
                  _secretsCard(),
                  const SizedBox(height: 12),
                  _schedulesCard(),
                  const SizedBox(height: 12),
                  _auditCard(),
                  const SizedBox(height: 12),
                  _dangerCard(),
                ],
              ],
            ),
    );
  }

  // ── Frozen (break-glass) ──────────────────────────────────────────────────
  Widget _frozenBanner() => DqCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.ac_unit, color: Color(0xFF991B1B)),
            const SizedBox(width: 8),
            Text(c('dev_queue.gcp_frozen_title'),
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF991B1B))),
          ]),
          const SizedBox(height: 6),
          Text(c('dev_queue.gcp_frozen_body'),
              style: const TextStyle(fontSize: 13, color: kTextLo)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      final pin = await _askPin(c('dev_queue.gcp_unlock_pin'));
                      if (pin != null && pin.isNotEmpty) {
                        _run(() => widget.service.unfreeze(pin));
                      }
                    },
              icon: const Icon(Icons.lock_open),
              label: Text(c('dev_queue.gcp_unlock')),
              style: FilledButton.styleFrom(backgroundColor: kBrand, minimumSize: const Size(0, 48)),
            ),
          ),
        ]),
      );

  Widget _pinBanner() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          const Icon(Icons.shield_outlined, color: Color(0xFF92400E)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(c('dev_queue.gcp_set_pin_prompt'),
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF92400E))),
          ),
          TextButton(
            onPressed: _busy ? null : _changePin,
            child: Text(c('dev_queue.gcp_set_pin'),
                style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF92400E))),
          ),
        ]),
      );

  Future<void> _changePin() async {
    final oldPin = _pinSet ? (await _askPin(c('dev_queue.gcp_old_pin'))) : '';
    if (_pinSet && (oldPin == null || oldPin.isEmpty)) return;
    final newPin = await _askPin(c('dev_queue.gcp_new_pin'));
    if (newPin == null || newPin.isEmpty) return;
    await _run(() async {
      final r = await widget.service.pinSet(oldPin ?? '', newPin);
      if (mounted) {
        showToast(context, c(r['ok'] == true ? 'dev_queue.gcp_pin_saved' : 'dev_queue.gcp_pin_failed'),
            isError: r['ok'] != true);
      }
    });
  }

  // ── Panel: VM + budget + security ─────────────────────────────────────────
  Widget _panelCard() {
    final apis = (_status['apis'] as List?) ?? const [];
    final spent = _budget['spent_inr'];
    final cap = _budget['cap_inr'] ?? _sec['daily_cap_inr'];
    final pct = (spent is num && cap is num && cap > 0)
        ? (spent / cap).clamp(0.0, 1.0)
        : 0.0;
    return DqCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.cloud_outlined, size: 18, color: kTextLo),
          const SizedBox(width: 8),
          Text(c('dev_queue.gcp_panel'),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: kTextLo)),
          const Spacer(),
          ToneChip(
              label: (_status['state'] ?? c('dev_queue.gcp_state_unknown')).toString(),
              tone: statusTone((_status['state'] == 'RUNNING') ? 'completed' : 'paused')),
        ]),
        const SizedBox(height: 12),
        _diskPill(),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, children: [
          _kv(c('dev_queue.gcp_ip'), (_status['ip'] ?? '—').toString()),
          _kv(c('dev_queue.gcp_region'), (_status['region'] ?? '—').toString()),
          _kv(c('dev_queue.gcp_apis'), '${apis.length}'),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Text(c('dev_queue.gcp_budget'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: kTextHi)),
          const Spacer(),
          Text('₹${spent ?? 0} / ₹${cap ?? 0}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kTextHi)),
          const SizedBox(width: 6),
          InkWell(
            onTap: _busy ? null : _editCap,
            child: const Icon(Icons.edit_outlined, size: 16, color: kBrand),
          ),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: pct.toDouble(),
            minHeight: 8,
            backgroundColor: const Color(0xFFF1F2F4),
            valueColor: AlwaysStoppedAnimation(pct > 0.85 ? const Color(0xFF991B1B) : kBrand),
          ),
        ),
      ]),
    );
  }

  Future<void> _editCap() async {
    final ctl = TextEditingController(text: '${_budget['cap_inr'] ?? _sec['daily_cap_inr'] ?? ''}');
    final v = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(c('dev_queue.gcp_cap_title')),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: c('dev_queue.gcp_cap_hint')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(c('dev_queue.btn_cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctl.text.trim()),
              style: FilledButton.styleFrom(backgroundColor: kBrand),
              child: Text(c('dev_queue.btn_submit'))),
        ],
      ),
    );
    final cap = num.tryParse(v ?? '');
    if (cap == null) return;
    final pin = await _askPin(c('dev_queue.gcp_pin_confirm'));
    if (pin == null || pin.isEmpty) return;
    await _run(() async {
      final r = await widget.service.budgetCapSet(cap, pin);
      if (mounted) {
        showToast(context, c(r['ok'] == true ? 'dev_queue.gcp_cap_saved' : 'dev_queue.gcp_pin_failed'),
            isError: r['ok'] != true);
      }
    });
  }

  /// Disk usage row — turns red when pct ≥ the backend's disk_alert_pct, with an
  /// inline "Clean now" chip that enqueues the same local cleanup the auto-cron
  /// uses. Shows a note when an auto-clean is already queued today.
  Widget _diskPill() {
    final pct = _diskPct;
    final alert = _diskAlertPct;
    final red = pct >= 0 && pct >= alert;
    final bg = red ? const Color(0xFFFEE2E2) : kPageBg;
    final fg = red ? const Color(0xFF991B1B) : kTextHi;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          Icon(Icons.storage, size: 16, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c('dev_queue.gcp_disk'),
                  style: TextStyle(fontSize: 11, color: red ? const Color(0xFF991B1B) : kTextLo)),
              const SizedBox(height: 2),
              Text((_status['disk'] ?? '—').toString(),
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: fg)),
            ]),
          ),
          if (red)
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _action('cleanup_disk'),
              icon: const Icon(Icons.cleaning_services, size: 14, color: Color(0xFF991B1B)),
              label: Text(c('dev_queue.gcp_disk_clean_now'),
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF991B1B))),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  side: const BorderSide(color: Color(0xFF991B1B))),
            ),
        ]),
      ),
      if (_autoCleanPending)
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 4),
          child: Row(children: [
            const Icon(Icons.autorenew, size: 13, color: kTextLo),
            const SizedBox(width: 5),
            Text(c('dev_queue.gcp_disk_autoclean'),
                style: const TextStyle(fontSize: 12, color: kTextLo)),
          ]),
        ),
    ]);
  }

  Widget _kv(String k, String v) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
            color: kPageBg, borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(k, style: const TextStyle(fontSize: 11, color: kTextLo)),
          const SizedBox(height: 2),
          Text(v, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: kTextHi)),
        ]),
      );

  // ── Site uptime chip (header) ─────────────────────────────────────────────
  Widget _siteChip() {
    final state = (_uptime['state'] ?? 'unknown').toString();
    late final Color bg, fg;
    late final String label;
    if (state == 'up') {
      bg = const Color(0xFFD1FAE5); fg = const Color(0xFF065F46);
      label = c('dev_queue.gcp_site_up');
    } else if (state == 'down') {
      bg = const Color(0xFFFEE2E2); fg = const Color(0xFF991B1B);
      final since = (_uptime['last_change'] ?? '').toString();
      label = since.isEmpty
          ? c('dev_queue.gcp_site_down')
          : cf('dev_queue.gcp_site_down_since', {'since': _shortTime(since)});
    } else {
      bg = const Color(0xFFF1F2F4); fg = kTextLo;
      label = c('dev_queue.gcp_site_unknown');
    }
    return InkWell(
      onTap: _openSiteSheet,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(state == 'up' ? Icons.check_circle : (state == 'down' ? Icons.error : Icons.help_outline),
              size: 13, color: fg),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
        ]),
      ),
    );
  }

  /// Trim an ISO timestamp to "MM-DD HH:MM" for the chip — no locale math, just
  /// a short slice of the backend's own string.
  String _shortTime(String iso) =>
      iso.length >= 16 ? iso.substring(5, 16).replaceFirst('T', ' ') : iso;

  void _openSiteSheet() {
    final url = (_uptime['url'] ?? '').toString();
    final downCount = (_uptime['down_count'] ?? 0).toString();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c('dev_queue.gcp_site_sheet_title'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: kTextHi)),
          const SizedBox(height: 12),
          Row(children: [
            Text('${c('dev_queue.gcp_site_url')}: ',
                style: const TextStyle(fontSize: 13, color: kTextLo)),
            Expanded(child: Text(url, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: kTextHi))),
            _copyBtn(url),
          ]),
          const SizedBox(height: 6),
          Text(cf('dev_queue.gcp_site_downcount', {'n': downCount}),
              style: const TextStyle(fontSize: 13, color: kTextLo)),
        ]),
      ),
    );
  }

  // ── Cost card ─────────────────────────────────────────────────────────────
  Widget _costCard() {
    final costs = (_g['costs'] as Map?)?.cast<String, dynamic>() ?? const {};
    final byService = (costs['by_service'] as List?)?.whereType<Map>().toList() ?? const [];
    final daily = (costs['daily'] as List?)?.whereType<Map>().toList() ?? const [];
    final total = costs['total_inr'];
    final hasData = byService.isNotEmpty || daily.isNotEmpty || (total is num && total > 0);
    return DqCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.payments_outlined, size: 18, color: kTextLo),
          const SizedBox(width: 8),
          Text(c('dev_queue.gcp_cost_title'),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: kTextLo)),
          const Spacer(),
          if (hasData)
            Text('₹${total ?? 0} · ${c('dev_queue.gcp_cost_30d')}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kTextHi)),
        ]),
        if (!hasData)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(c('dev_queue.gcp_cost_empty'),
                style: const TextStyle(fontSize: 13, color: kTextLo)),
          )
        else ...[
          const SizedBox(height: 12),
          if (byService.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in byService)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                      color: kPageBg, borderRadius: BorderRadius.circular(20)),
                  child: Text('${s['service'] ?? ''} ₹${s['cost_inr'] ?? 0}',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: kTextHi)),
                ),
            ]),
          if (daily.isNotEmpty) ...[
            const SizedBox(height: 14),
            _dailyBars(daily),
          ],
        ],
      ]),
    );
  }

  Widget _dailyBars(List<Map> daily) {
    final vals = daily.map((d) => (d['cost_inr'] is num) ? (d['cost_inr'] as num).toDouble() : 0.0).toList();
    final maxV = vals.fold<double>(0, (a, b) => b > a ? b : a);
    return SizedBox(
      height: 44,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (final v in vals)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Container(
                height: maxV > 0 ? (4 + 40 * (v / maxV)) : 4,
                decoration: BoxDecoration(
                    color: kBrand.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
          ),
      ]),
    );
  }

  // ── One-tap actions ───────────────────────────────────────────────────────
  Widget _actionsCard() {
    return DqCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(c('dev_queue.gcp_actions'),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: kTextLo)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _act('dev_queue.gcp_enable_apis', Icons.api, () => _action('enable_api')),
          _act('dev_queue.gcp_restart', Icons.restart_alt,
              () => _action('restart_vm', needsPin: true), danger: true),
          _act('dev_queue.gcp_disk', Icons.storage, () => _action('resize_disk')),
          _act('dev_queue.gcp_quotas', Icons.speed, () => _action('quotas')),
          _act('dev_queue.gcp_billing', Icons.receipt_long, () => _action('billing_now')),
          _act('dev_queue.gcp_api_keys', Icons.vpn_key_outlined, () => _action('api_keys')),
          _act('dev_queue.gcp_clean_disk', Icons.cleaning_services_outlined, () => _action('cleanup_disk')),
          _act('dev_queue.gcp_snapshot', Icons.camera_alt_outlined, () => _action('snapshot_now')),
          _act('dev_queue.gcp_waste_scan', Icons.search_outlined, () => _action('waste_scan')),
        ]),
      ]),
    );
  }

  Widget _act(String key, IconData icon, VoidCallback onTap, {bool danger = false}) {
    final col = danger ? const Color(0xFF991B1B) : kBrand;
    return OutlinedButton.icon(
      onPressed: _busy ? null : onTap,
      icon: Icon(icon, size: 16, color: col),
      label: Text(c(key), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: col)),
      style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          side: BorderSide(color: col.withValues(alpha: 0.4)),
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10)))),
    );
  }

  // ── Secrets vault ─────────────────────────────────────────────────────────
  Widget _secretsCard() {
    final secrets = (_g['secrets'] as List?)?.whereType<Map>().toList() ?? const [];
    return DqCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(c('dev_queue.gcp_secrets'),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: kTextLo)),
          const Spacer(),
          TextButton.icon(
            onPressed: _busy ? null : () => _addSecret(),
            icon: const Icon(Icons.add, size: 16, color: kBrand),
            label: Text(c('dev_queue.gcp_add_secret'),
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: kBrand)),
          ),
        ]),
        if (secrets.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(c('dev_queue.gcp_no_secrets'),
                style: const TextStyle(fontSize: 13, color: kTextLo)),
          ),
        for (final s in secrets)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              const Icon(Icons.key_outlined, size: 16, color: kTextLo),
              const SizedBox(width: 8),
              Expanded(
                child: Text((s['name'] ?? '').toString(),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: kTextHi)),
              ),
              if (s['rotate_due'] == true)
                ToneChip(label: c('dev_queue.gcp_rotate_due'), tone: statusTone('awaiting_approval')),
              const SizedBox(width: 6),
              Text('••••${s['last4'] ?? ''}',
                  style: const TextStyle(fontSize: 12, color: kTextLo)),
              _copyBtn((s['name'] ?? '').toString()),
              TextButton(
                onPressed: _busy ? null : () => _addSecret(name: (s['name'] ?? '').toString()),
                child: Text(c('dev_queue.gcp_rotate'),
                    style: const TextStyle(fontSize: 12, color: kBrand)),
              ),
            ]),
          ),
      ]),
    );
  }

  Future<void> _addSecret({String? name}) async {
    final nameCtl = TextEditingController(text: name ?? '');
    final valCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(c(name == null ? 'dev_queue.gcp_add_secret' : 'dev_queue.gcp_rotate')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: nameCtl,
            readOnly: name != null,
            decoration: InputDecoration(hintText: c('dev_queue.gcp_secret_name')),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: valCtl,
            autofocus: true,
            obscureText: true,
            decoration: InputDecoration(hintText: c('dev_queue.gcp_secret_value')),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(c('dev_queue.btn_cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(backgroundColor: kBrand),
              child: Text(c('dev_queue.gcp_save_secret'))),
        ],
      ),
    );
    if (ok == true && nameCtl.text.trim().isNotEmpty && valCtl.text.isNotEmpty) {
      await _run(() => widget.service.secretSet(nameCtl.text.trim(), valCtl.text));
      if (mounted) showToast(context, c('dev_queue.gcp_secret_saved'));
    }
  }

  Widget _copyBtn(String text) => IconButton(
        tooltip: c('dev_queue.gcp_copy'),
        icon: const Icon(Icons.copy_outlined, size: 15, color: kTextLo),
        splashRadius: 16,
        onPressed: text.isEmpty
            ? null
            : () {
                Clipboard.setData(ClipboardData(text: text));
                showToast(context, c('dev_queue.gcp_copied'));
              },
      );

  // ── Schedules ─────────────────────────────────────────────────────────────
  Widget _schedulesCard() {
    final rows = (_g['schedules'] as List?)?.whereType<Map>().toList() ?? const [];
    return DqCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(c('dev_queue.gcp_schedules'),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: kTextLo)),
          const Spacer(),
          TextButton.icon(
            onPressed: _busy ? null : () => _editSchedule(),
            icon: const Icon(Icons.add, size: 16, color: kBrand),
            label: Text(c('dev_queue.gcp_add_schedule'),
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: kBrand)),
          ),
        ]),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(c('dev_queue.gcp_no_schedules'),
                style: const TextStyle(fontSize: 13, color: kTextLo)),
          ),
        for (final s in rows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(Icons.schedule,
                size: 18, color: s['enabled'] == false ? kTextLo : kBrand),
            title: Text((s['label'] ?? '').toString(),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: kTextHi)),
            subtitle: Text(
                '${_repeatLabel(s)} · ${(s['hour_ist'] ?? 0).toString().padLeft(2, '0')}:${(s['minute_ist'] ?? 0).toString().padLeft(2, '0')} IST · ${s['goal'] ?? ''}',
                style: const TextStyle(fontSize: 12, color: kTextLo)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 16, color: kTextLo),
                splashRadius: 16,
                onPressed: _busy ? null : () => _editSchedule(row: Map<String, dynamic>.from(s)),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 16, color: Color(0xFF991B1B)),
                splashRadius: 16,
                onPressed: _busy ? null : () => _run(() => widget.service.scheduleDelete((s['id'] as num).toInt())),
              ),
            ]),
          ),
      ]),
    );
  }

  List<String> get _weekdayNames =>
      c('dev_queue.gcp_weekdays').split(',').map((e) => e.trim()).toList();

  /// Human repeat label built from backend data only (weekday names come from
  /// the ui_copy CSV, the ordinal from the row's day_of_month).
  String _repeatLabel(Map s) {
    final dom = s['day_of_month'];
    if (dom is num) return cf('dev_queue.gcp_dom_label', {'n': '${dom.toInt()}'});
    final dows = (s['days_of_week'] as List?)?.whereType<num>().map((e) => e.toInt()).toList() ?? const [];
    if (dows.isEmpty) return c('dev_queue.gcp_repeat_none');
    final names = _weekdayNames;
    final parts = dows.where((d) => d >= 1 && d <= 7).map((d) => names[d - 1]).toList();
    return parts.isEmpty ? c('dev_queue.gcp_repeat_none') : parts.join(', ');
  }

  Future<void> _editSchedule({Map<String, dynamic>? row}) async {
    final labelCtl = TextEditingController(text: (row?['label'] ?? '').toString());
    final goalCtl = TextEditingController(text: (row?['goal'] ?? '').toString());
    final hourCtl = TextEditingController(text: (row?['hour_ist'] ?? 9).toString());
    final minCtl = TextEditingController(text: (row?['minute_ist'] ?? 30).toString());
    bool enabled = row?['enabled'] != false;
    // Repeat mode: monthly when the row carries a day_of_month, else weekly.
    final dom0 = row?['day_of_month'];
    bool monthly = dom0 is num;
    int dom = dom0 is num ? dom0.toInt().clamp(1, 28) : 1;
    final dows = <int>{
      ...((row?['days_of_week'] as List?)?.whereType<num>().map((e) => e.toInt()) ?? const [7])
    };
    final names = _weekdayNames;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(c('dev_queue.gcp_schedule_title')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(controller: labelCtl, decoration: InputDecoration(hintText: c('dev_queue.gcp_schedule_label'))),
              const SizedBox(height: 8),
              TextField(controller: goalCtl, decoration: InputDecoration(hintText: c('dev_queue.gcp_schedule_goal'))),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: hourCtl, keyboardType: TextInputType.number, decoration: InputDecoration(hintText: c('dev_queue.gcp_schedule_hour')))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: minCtl, keyboardType: TextInputType.number, decoration: InputDecoration(hintText: c('dev_queue.gcp_schedule_min')))),
              ]),
              const SizedBox(height: 12),
              Text(c('dev_queue.gcp_repeat'),
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: kTextLo)),
              const SizedBox(height: 6),
              Row(children: [
                _repeatToggle(c('dev_queue.gcp_repeat_weekly'), !monthly, () => setSt(() => monthly = false)),
                const SizedBox(width: 8),
                _repeatToggle(c('dev_queue.gcp_repeat_monthly'), monthly, () => setSt(() => monthly = true)),
              ]),
              const SizedBox(height: 10),
              if (!monthly)
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (int i = 1; i <= 7; i++)
                    FilterChip(
                      label: Text(i <= names.length ? names[i - 1] : '$i',
                          style: const TextStyle(fontSize: 12)),
                      selected: dows.contains(i),
                      selectedColor: const Color(0xFFD1FAE5),
                      checkmarkColor: const Color(0xFF065F46),
                      onSelected: (v) => setSt(() => v ? dows.add(i) : dows.remove(i)),
                    ),
                ])
              else
                Row(children: [
                  Text('${c('dev_queue.gcp_dom')}: ',
                      style: const TextStyle(fontSize: 13, color: kTextLo)),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    value: dom,
                    items: [for (int d = 1; d <= 28; d++) DropdownMenuItem(value: d, child: Text('$d'))],
                    onChanged: (v) => setSt(() => dom = v ?? 1),
                  ),
                ]),
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(c('dev_queue.gcp_schedule_enabled'), style: const TextStyle(fontSize: 13)),
                value: enabled,
                activeTrackColor: kBrand,
                onChanged: (v) => setSt(() => enabled = v),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(c('dev_queue.btn_cancel'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: FilledButton.styleFrom(backgroundColor: kBrand),
                child: Text(c('dev_queue.btn_submit'))),
          ],
        ),
      ),
    );
    if (ok == true && labelCtl.text.trim().isNotEmpty) {
      final payload = <String, dynamic>{
        if (row?['id'] != null) 'id': row!['id'],
        'label': labelCtl.text.trim(),
        'goal': goalCtl.text.trim(),
        'hour_ist': int.tryParse(hourCtl.text.trim()) ?? 9,
        'minute_ist': int.tryParse(minCtl.text.trim()) ?? 30,
        'enabled': enabled,
        // Monthly sends day_of_month (backend ignores days_of_week when set);
        // weekly sends the weekday set and clears day_of_month.
        'day_of_month': monthly ? dom : null,
        'days_of_week': monthly ? <int>[] : (dows.toList()..sort()),
      };
      await _run(() => widget.service.scheduleSave(payload));
    }
  }

  Widget _repeatToggle(String label, bool selected, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? kBrand : kPageBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? kBrand : kBorder),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : kTextHi)),
        ),
      );

  // ── Audit ─────────────────────────────────────────────────────────────────
  Widget _auditCard() {
    return DqCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(c('dev_queue.gcp_audit'),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: kTextLo)),
          const Spacer(),
          TextButton(
            onPressed: _busy ? null : _openAudit,
            child: Text(c('dev_queue.gcp_view_audit'),
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: kBrand)),
          ),
        ]),
        Text(c('dev_queue.gcp_audit_hint'),
            style: const TextStyle(fontSize: 12.5, color: kTextLo)),
      ]),
    );
  }

  Future<void> _openAudit() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _AuditScreen(service: widget.service),
    ));
  }

  // ── Danger: freeze ────────────────────────────────────────────────────────
  Widget _dangerCard() => DqCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c('dev_queue.gcp_breakglass'),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF991B1B))),
          const SizedBox(height: 6),
          Text(c('dev_queue.gcp_freeze_hint'),
              style: const TextStyle(fontSize: 12.5, color: kTextLo)),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          content: Text(c('dev_queue.gcp_freeze_confirm')),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(c('dev_queue.btn_cancel'))),
                            FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF991B1B)),
                                child: Text(c('dev_queue.gcp_freeze'))),
                          ],
                        ),
                      );
                      if (ok == true) _run(() => widget.service.freeze());
                    },
              icon: const Icon(Icons.ac_unit, size: 16, color: Color(0xFF991B1B)),
              label: Text(c('dev_queue.gcp_freeze'),
                  style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF991B1B))),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  side: const BorderSide(color: Color(0xFF991B1B))),
            ),
          ),
        ]),
      );
}

/// Plain "who · what · when" audit log with a search box.
class _AuditScreen extends StatefulWidget {
  final DevQueueService service;
  const _AuditScreen({required this.service});
  @override
  State<_AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<_AuditScreen> {
  final _search = TextEditingController();
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.service.auditList(search: _search.text.trim());
      if (mounted) setState(() { _rows = r; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kPageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: kBrand),
        title: Text(c('dev_queue.gcp_audit'),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: kTextHi)),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _search,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(
              hintText: c('dev_queue.gcp_audit_search'),
              prefixIcon: const Icon(Icons.search, size: 18, color: kTextLo),
              filled: true,
              fillColor: Colors.white,
            ),
          ),
        ),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator(color: kBrand)))
        else
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: kBorder),
              itemBuilder: (_, i) {
                final r = _rows[i];
                return ListTile(
                  dense: true,
                  title: Text(
                      '${r['actor'] ?? r['who'] ?? ''} · ${r['action'] ?? r['what'] ?? ''}',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: kTextHi)),
                  subtitle: Text((r['when'] ?? r['at'] ?? r['created_at'] ?? '').toString(),
                      style: const TextStyle(fontSize: 12, color: kTextLo)),
                );
              },
            ),
          ),
      ]),
    );
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../services/ui_copy.dart';
import '../../../utils/toast.dart';
import '../../../widgets/payment_proof_image.dart';
import 'dev_queue_common.dart';
import 'dev_queue_image_tray.dart';
import 'dev_queue_service.dart';

/// One command, whole story. The registry row (status, decisions, targets,
/// cost) comes from dev_cmd_list; the full spec + live build log + chat come
/// from dev_cmd_spec. Everything is rendered verbatim; the buttons only send
/// the user's intent back to the backend.
class DevQueueDetail extends StatefulWidget {
  final int id;
  final Map<String, dynamic>? initialRow;
  final DevQueueService? service;
  const DevQueueDetail(
      {super.key, required this.id, this.initialRow, this.service});

  @override
  State<DevQueueDetail> createState() => _DevQueueDetailState();
}

class _DevQueueDetailState extends State<DevQueueDetail> {
  late final DevQueueService _svc = widget.service ?? DevQueueService();
  final _reply = TextEditingController();
  List<String> _replyImages = const [];
  List<Map<String, dynamic>> _replyFiles = const [];
  bool _uploading = false;
  Timer? _poll;

  Map<String, dynamic> _row = const {};
  Map<String, dynamic> _spec = const {};
  bool _loading = true;
  bool _busy = false;
  Timer? _tick; // 1s ticker for the live ATR countdown while building
  DateTime _now = DateTime.now();

  String get _status => (_row['status'] ?? '').toString();
  bool get _active => _status == 'building' || _status == 'needs_input';

  @override
  void initState() {
    super.initState();
    if (widget.initialRow != null) {
      _row = widget.initialRow!;
      _loading = false;
    }
    _load();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_active) _load(silent: true);
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _status == 'building') setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    _reply.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final results = await Future.wait([
        _svc.spec(widget.id),
        _svc.list(limit: 500),
      ]);
      final spec = results[0];
      final rows = ((results[1]['rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e));
      final row = rows.firstWhere((r) => asInt(r['id']) == widget.id,
          orElse: () => _row);
      if (!mounted) return;
      setState(() {
        _spec = spec;
        _row = row;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

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

  Future<bool> _confirm(String key) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        content: Text(c(key)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(c('dev_queue.btn_cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(backgroundColor: kBrand),
              child: Text(c('dev_queue.btn_submit'))),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kPageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: kBrand),
        title: Text('#${widget.id}',
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700, color: kTextHi)),
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
                _titleBlock(),
                _plainCard(),
                if (_row['web_deploy_no'] != null) _changeBanner(),
                if (_spec['has_tokens'] == true || _status == 'building')
                  _tokensCard(),
                _timerCard(),
                if (_status == 'needs_input') _needsInputBanner(),
                const SizedBox(height: 12),
                _targets(),
                const SizedBox(height: 12),
                _actions(),
                const SizedBox(height: 12),
                _chat(),
                if ((_row['decisions'] as List?)?.isNotEmpty ?? false)
                  _decisions(),
                if ((_row['screenshots'] as List?)?.isNotEmpty ?? false)
                  _screenshots(),
                if ((_row['error_log'] ?? '').toString().isNotEmpty)
                  _section(c('dev_queue.section_error'),
                      _mono(_row['error_log']), tone: statusTone('failed')),
                _buildLog(),
                _meta(),
              ],
            ),
    );
  }


  /// The plain-language result (for non-technical Om): the backend's own
  /// `plain_summary` shown prominently, with any `result_actions` as one-tap
  /// copy chips (commands, names, links). Absent → nothing renders.
  Widget _plainCard() {
    final plain = (_spec['plain_summary'] ?? '').toString();
    final actions = ((_spec['result_actions'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    if (plain.isEmpty && actions.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (plain.isNotEmpty)
          Text(plain,
              style: const TextStyle(
                  fontSize: 15, height: 1.4, fontWeight: FontWeight.w600, color: Color(0xFF1E3A8A))),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final a in actions) _copyChip(a),
          ]),
        ],
      ]),
    );
  }

  Widget _copyChip(Map<String, dynamic> a) {
    final label = (a['label'] ?? c('dev_queue.result_actions_label')).toString();
    final copy = (a['copy_text'] ?? '').toString();
    return ActionChip(
      avatar: const Icon(Icons.copy_outlined, size: 15, color: Color(0xFF1E40AF)),
      label: Text(label,
          style: const TextStyle(
              fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF1E40AF))),
      backgroundColor: Colors.white,
      side: const BorderSide(color: Color(0xFFBFDBFE)),
      onPressed: copy.isEmpty
          ? null
          : () {
              Clipboard.setData(ClipboardData(text: copy));
              showToast(context, c('dev_queue.gcp_copied'));
            },
    );
  }

  /// A clean, organised header: the status + urgent chips sit on their own row
  /// (wrapping, never colliding), then the command title stands on its own line,
  /// large and prominent — a clear focal element instead of a cramped strip.
  Widget _titleBlock() {
    final title = (_spec['title'] ?? _row['title'] ?? '').toString();
    return DqCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ToneChip(
              label: statusLabel(_status),
              tone: statusTone(_status),
              spinning: _status == 'building'),
          Text('#${widget.id}',
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: kTextLo)),
          if (_spec['kind'] == 'gcp')
            ToneChip(
                label: c('dev_queue.gcp_cloud_badge'),
                tone: statusTone('awaiting_approval'),
                icon: Icons.cloud_outlined),
          if (_row['urgent'] == true)
            ToneChip(
                label: c('dev_queue.flag_urgent'),
                tone: statusTone('failed'),
                icon: Icons.priority_high),
        ]),
        const SizedBox(height: 12),
        Text(title,
            style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                height: 1.3,
                color: kTextHi)),
      ]),
    );
  }

  /// The deployed change number, shown big at the top of a finished command so
  /// Om reads it without hunting. `web_deploy_no` is the change number the
  /// deploy lane stamped.
  Widget _changeBanner() {
    final n = _row['web_deploy_no'];
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFD1FAE5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        const Icon(Icons.cloud_done_outlined, size: 20, color: Color(0xFF065F46)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(c('dev_queue.section_change'),
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF065F46))),
            const SizedBox(height: 2),
            Text('${c('dev_queue.change_prefix')}$n',
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF065F46))),
          ]),
        ),
        if (_row['web_deployed_at'] != null)
          Text(istShort(_row['web_deployed_at'].toString()),
              style: const TextStyle(fontSize: 11, color: Color(0xFF065F46))),
      ]),
    );
  }

  /// Per-command token usage — updates live while building (heartbeat feeds
  /// cost_input/output_tokens) and shows the final total after. All numbers are
  /// backend-formatted display strings.
  Widget _tokensCard() {
    final live = _status == 'building';
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.data_usage, size: 18, color: kTextLo),
          const SizedBox(width: 8),
          Text(c(live ? 'dev_queue.tokens_live' : 'dev_queue.tokens_label'),
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: kTextLo)),
          const Spacer(),
          if (live) _liveBadge(),
        ]),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${_spec['tokens_total_display'] ?? '0'}',
              style: const TextStyle(
                  fontSize: 24, fontWeight: FontWeight.w800, color: kTextHi)),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text('${_spec['cost_display'] ?? ''}',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700, color: kBrand)),
          ),
        ]),
        const SizedBox(height: 4),
        Text(
            '↓ ${_spec['tokens_in_display'] ?? '0'}   ↑ ${_spec['tokens_out_display'] ?? '0'}',
            style: const TextStyle(fontSize: 12, color: kTextLo)),
        if (costNote(_spec).isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(costNote(_spec),
              style: const TextStyle(fontSize: 11, color: kTextLo)),
        ],
        if (priceModelChip(_spec).isNotEmpty) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: ToneChip(
                label: priceModelChip(_spec),
                tone: statusTone('building'),
                icon: Icons.memory),
          ),
        ],
      ]),
    );
  }

  /// Build timing. While building: the estimated total (TAT, backend) and a live
  /// countdown to the backend's eta_at anchor (ATR). After: the real total time
  /// taken (TTT, backend). The app only animates the countdown; every estimate
  /// and label comes from the backend.
  Widget _timerCard() {
    final building = _status == 'building';
    final ttt = (_spec['ttt_display'] ?? '').toString();
    if (!building && ttt.isEmpty) return const SizedBox.shrink();

    Widget stat(String label, String value, IconData icon, Color col) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, size: 15, color: col),
              const SizedBox(width: 5),
              Text(label,
                  style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: kTextLo)),
            ]),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: col)),
          ]),
        );

    final children = <Widget>[];
    if (building) {
      final tat = (_spec['tat_display'] ?? '').toString();
      final eta = DateTime.tryParse((_spec['eta_at'] ?? '').toString());
      String atr;
      Color atrCol = kBrand;
      if (eta != null) {
        final rem = eta.difference(_now);
        if (rem.isNegative) {
          atr = c('dev_queue.atr_overrun');
          atrCol = const Color(0xFF92400E);
        } else {
          atr = _countdown(rem);
        }
      } else {
        atr = '—';
      }
      children.add(stat(c('dev_queue.tat_label'), tat, Icons.timelapse_outlined, kTextHi));
      children.add(const SizedBox(width: 12));
      children.add(stat(c('dev_queue.atr_label'), atr, Icons.hourglass_bottom, atrCol));
    } else {
      children.add(stat(c('dev_queue.ttt_label'), ttt, Icons.check_circle_outline, const Color(0xFF065F46)));
    }

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  /// Live countdown text (client-ticked) toward the backend's eta anchor.
  String _countdown(Duration d) {
    final s = d.inSeconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final ss = s % 60;
    if (h > 0) return '${h}h ${m}m';
    return '$m:${ss.toString().padLeft(2, '0')}';
  }

  Widget _needsInputBanner() => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c('dev_queue.needs_input_banner'),
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF92400E))),
          if ((_row['needs_input_question'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(_row['needs_input_question'].toString(),
                style: const TextStyle(fontSize: 14, color: Color(0xFF92400E))),
          ],
        ]),
      );

  // ── Targets ──────────────────────────────────────────────────────────────
  Widget _targets() {
    final deploy = _row['web_deploy_no'];
    final android = (_row['android_status'] ?? 'not_requested').toString();
    return DqCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(c('dev_queue.section_targets'),
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: kTextLo)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          // Web
          ToneChip(
            label: deploy != null
                ? '${c('dev_queue.label_deploy')} ${c('dev_queue.deploy_prefix')}$deploy'
                : c('dev_queue.toggle_web'),
            tone: deploy != null ? statusTone('completed') : statusTone('paused'),
            icon: Icons.cloud_outlined,
          ),
          if (_row['web_deployed_at'] != null)
            Text(istShort(_row['web_deployed_at'].toString()),
                style: const TextStyle(fontSize: 11, color: kTextLo)),
          // Android
          _androidChip(android),
          // iOS
          ToneChip(
              label: c('dev_queue.ios_soon'),
              tone: statusTone('paused'),
              icon: Icons.apple),
        ]),
      ]),
    );
  }

  Widget _androidChip(String android) {
    switch (android) {
      case 'built':
        final url = (_row['android_artifact_url'] ?? '').toString();
        return GestureDetector(
          onTap: url.isEmpty ? null : () => _open(url),
          child: ToneChip(
              label: c('dev_queue.android_built'),
              tone: androidTone('built'),
              icon: Icons.download),
        );
      case 'building':
      case 'requested':
        return ToneChip(
            label: androidLabel(android),
            tone: androidTone(android),
            icon: Icons.android,
            spinning: android == 'building');
      case 'failed':
        return ToneChip(
            label: c('dev_queue.android_failed'),
            tone: androidTone('failed'),
            icon: Icons.android);
      default: // not_requested — status only. Building is done from the action
        // row (Build APK / Build AAB) so there is ONE place to build, not two.
        return ToneChip(
            label: c('dev_queue.android_not_built'),
            tone: statusTone('paused'),
            icon: Icons.android);
    }
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  // ── Actions (status-driven) ────────────────────────────────────────────────
  // One clean, status-driven action row: exactly one filled PRIMARY action, the
  // rest outlined, destructive in red. Building is only ever offered here (never
  // also from the Targets chips) so there are no duplicate buttons.
  Widget _actions() {
    final btns = <Widget>[];
    void add(String key, VoidCallback onTap,
        {Color? color, IconData? icon, bool primary = false}) {
      btns.add(_ActionBtn(
          label: c(key),
          onTap: _busy ? null : onTap,
          color: color,
          icon: icon,
          primary: primary));
    }

    Future<void> apk() => _run(() => _svc.requestAndroid(widget.id, buildType: 'apk'));
    Future<void> aab() => _run(() => _svc.requestAndroid(widget.id, buildType: 'aab'));

    switch (_status) {
      case 'pending':
        add('dev_queue.btn_edit', _editSpec, icon: Icons.edit_outlined, primary: true);
        add('dev_queue.btn_pause', () => _run(() => _svc.pause(widget.id)));
        add('dev_queue.btn_cancel', () => _cancel(), color: const Color(0xFF991B1B));
        break;
      case 'paused':
        add('dev_queue.btn_resume', () => _run(() => _svc.resume(widget.id)),
            color: kBrand, primary: true);
        add('dev_queue.btn_edit', _editSpec, icon: Icons.edit_outlined);
        add('dev_queue.btn_cancel', () => _cancel(), color: const Color(0xFF991B1B));
        break;
      case 'awaiting_approval':
        add('dev_queue.btn_approve', () => _run(() => _svc.approve(widget.id)),
            color: kBrand, primary: true);
        add('dev_queue.btn_reject', _reject, color: const Color(0xFF991B1B));
        add('dev_queue.btn_edit', _editSpec, icon: Icons.edit_outlined);
        break;
      case 'building':
        add('dev_queue.btn_debug', _debug, icon: Icons.bug_report_outlined, primary: true);
        add('dev_queue.btn_pause', () => _run(() => _svc.pause(widget.id)));
        break;
      case 'completed':
        add('dev_queue.btn_build_apk', apk, icon: Icons.android, color: kBrand, primary: true);
        add('dev_queue.btn_build_aab', aab, icon: Icons.android);
        add('dev_queue.btn_debug', _debug, icon: Icons.bug_report_outlined);
        add('dev_queue.btn_rollback', _rollback,
            color: const Color(0xFF991B1B), icon: Icons.undo);
        break;
      case 'failed':
        add('dev_queue.btn_debug', _debug, icon: Icons.bug_report_outlined, primary: true);
        add('dev_queue.btn_build_apk', apk, icon: Icons.android);
        break;
      case 'needs_input':
        add('dev_queue.btn_cancel', () => _cancel(), color: const Color(0xFF991B1B));
        break;
      case 'cancelled':
        add('dev_queue.btn_delete', () => _delete(),
            color: const Color(0xFF991B1B), icon: Icons.delete_outline);
        break;
    }
    if (btns.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 8, children: btns);
  }

  Future<void> _cancel() async {
    if (await _confirm('dev_queue.confirm_cancel')) {
      _run(() => _svc.cancel(widget.id));
    }
  }

  Future<void> _debug() async {
    if (await _confirm('dev_queue.confirm_debug')) {
      _run(() => _svc.requestDebug(widget.id));
    }
  }

  Future<void> _delete() async {
    if (!await _confirm('dev_queue.confirm_delete')) return;
    setState(() => _busy = true);
    try {
      await _svc.delete(widget.id);
      if (mounted) Navigator.pop(context, true); // row is gone; refresh list
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showToast(context, e.toString(), isError: true);
      }
    }
  }

  Future<void> _rollback() async {
    if (await _confirm('dev_queue.confirm_rollback')) {
      _run(() => _svc.rollback(widget.id));
    }
  }

  Future<void> _reject() async {
    final ctl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: InputDecoration(hintText: c('dev_queue.reject_hint')),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(context, ctl.text.trim()),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF991B1B)),
              child: Text(c('dev_queue.btn_reject'))),
        ],
      ),
    );
    if (reason != null && reason.isNotEmpty) {
      _run(() => _svc.reject(widget.id, reason));
    }
  }

  Future<void> _editSpec() async {
    final ctl = TextEditingController(text: (_spec['spec'] ?? '').toString());
    final next = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: ctl,
            autofocus: true,
            maxLines: 16,
            minLines: 8,
            style: const TextStyle(fontSize: 13, height: 1.4),
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(c('dev_queue.btn_cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctl.text),
              style: FilledButton.styleFrom(backgroundColor: kBrand),
              child: Text(c('dev_queue.btn_save_edit'))),
        ],
      ),
    );
    if (next != null && next.trim().isNotEmpty) {
      _run(() => _svc.update(widget.id, {'spec': next.trim()}));
    }
  }

  // ── Conversation thread (WhatsApp-style) ───────────────────────────────────
  // One chronological thread: the command (spec) is the first message, then
  // every reply, then each result as it lands — all as chat bubbles, with the
  // composer pinned at the bottom. The old separate Spec / Result cards are
  // folded into this so it reads as one conversation.
  Widget _chat() {
    final thread = <Map<String, dynamic>>[];
    // 1. the original command, from Om, carrying its attachments.
    thread.add({
      'sender': 'om',
      'body': (_spec['spec'] ?? _row['title'] ?? '').toString(),
      'images': _spec['images'] ?? const [],
      'attachments': _spec['attachments'] ?? const [],
    });
    // 2. every message in time order — replies AND each completion result are
    // real backend messages, so nothing is force-appended and a later reply can
    // never sort above an earlier result. The backend owns the order.
    thread.addAll(((_spec['messages'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e)));
    return _sectionRaw(
      c('dev_queue.section_chat'),
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final m in thread) _bubble(m),
        const SizedBox(height: 8),
        _composerBar(),
      ]),
    );
  }

  // Note: the attach handlers do NOT early-return on _uploading, and the buttons
  // stay tappable — a cancelled picker must never lock the control. _uploading
  // is only a visual spinner around the actual upload.
  Future<void> _attachReplyImage() async {
    setState(() => _uploading = true);
    try {
      final path = await pickAndUploadDevImage(_svc);
      if (path != null && mounted) {
        setState(() => _replyImages = [..._replyImages, path]);
      }
    } catch (_) {
      if (mounted) showToast(context, c('dev_queue.attach_failed'), isError: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _attachReplyFiles() async {
    setState(() => _uploading = true);
    try {
      final files = await pickAndUploadDevFiles(_svc);
      if (files.isNotEmpty && mounted) {
        setState(() => _replyFiles = [..._replyFiles, ...files]);
      }
    } catch (_) {
      if (mounted) showToast(context, c('dev_queue.attach_failed'), isError: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _sendReply() async {
    final b = _reply.text.trim();
    final imgs = _replyImages;
    final files = _replyFiles;
    if (b.isEmpty && imgs.isEmpty && files.isEmpty) return;
    _reply.clear();
    setState(() {
      _replyImages = const [];
      _replyFiles = const [];
    });
    await _run(() => _svc.reply(widget.id, b, images: imgs, attachments: files));
  }

  IconData _fileIcon(String kind) {
    switch (kind) {
      case 'video':
        return Icons.videocam_outlined;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'image':
        return Icons.image_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  /// A tappable chip for a non-image attachment (video / pdf / doc) — opens the
  /// signed URL. `onRemove` shows an x when composing.
  Widget _fileChip(Map<String, dynamic> a, {VoidCallback? onRemove}) {
    final kind = (a['kind'] ?? 'file').toString();
    final name = (a['name'] ?? 'file').toString();
    return InkWell(
      onTap: onRemove != null
          ? null
          : () async {
              try {
                final url = await _svc.attachmentUrl((a['path'] ?? '').toString());
                await _open(url);
              } catch (_) {}
            },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: kPageBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kBorder),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_fileIcon(kind), size: 18, color: kBrand),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: kTextHi)),
          ),
          if (onRemove != null) ...[
            const SizedBox(width: 6),
            GestureDetector(
                onTap: onRemove,
                child: const Icon(Icons.close, size: 16, color: Color(0xFF991B1B))),
          ],
        ]),
      ),
    );
  }

  /// Renders both image thumbnails and file chips for a saved message's
  /// attachments (kind=image → thumbnail; else → chip).
  Widget _attachmentStrip(dynamic rawImages, dynamic rawAtts) {
    final imgs = ((rawImages as List?) ?? const [])
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList();
    final atts = ((rawAtts as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final imgAtts = atts.where((a) => a['kind'] == 'image').toList();
    final fileAtts = atts.where((a) => a['kind'] != 'image').toList();
    if (imgs.isEmpty && atts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        for (final p in [...imgs, ...imgAtts.map((a) => a['path'].toString())])
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 120,
              height: 120,
              child: PaymentProofImage(
                  bucket: DevQueueService.uploadsBucket, path: p, fixedHeight: 120),
            ),
          ),
        for (final a in fileAtts) _fileChip(a),
      ]),
    );
  }

  /// The Remote-Control-style composer: a pending-image strip, then a rounded
  /// bar carrying the text field, a paperclip attach, and a circular send
  /// arrow. Mirrors the Claude Code Remote Control reply box.
  Widget _composerBar() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_replyImages.isNotEmpty || _replyFiles.isNotEmpty || _uploading)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final a in _replyFiles.where((a) => a['kind'] != 'image'))
              _fileChip(a,
                  onRemove: () => setState(() =>
                      _replyFiles = _replyFiles.where((x) => x != a).toList())),
            for (final a in _replyFiles.where((a) => a['kind'] == 'image'))
              Stack(clipBehavior: Clip.none, children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 64,
                    height: 64,
                    child: PaymentProofImage(
                        bucket: DevQueueService.uploadsBucket,
                        path: a['path'].toString(),
                        fixedHeight: 64,
                        tapToEnlarge: false),
                  ),
                ),
                Positioned(
                  top: -8,
                  right: -8,
                  child: GestureDetector(
                    onTap: () => setState(() =>
                        _replyFiles = _replyFiles.where((x) => x != a).toList()),
                    child: const DecoratedBox(
                      decoration:
                          BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                      child: Icon(Icons.cancel, size: 20, color: Color(0xFF991B1B)),
                    ),
                  ),
                ),
              ]),
            for (final p in _replyImages)
              Stack(clipBehavior: Clip.none, children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 64,
                    height: 64,
                    child: PaymentProofImage(
                        bucket: DevQueueService.uploadsBucket,
                        path: p,
                        fixedHeight: 64,
                        tapToEnlarge: false),
                  ),
                ),
                Positioned(
                  top: -8,
                  right: -8,
                  child: GestureDetector(
                    onTap: () => setState(() => _replyImages =
                        _replyImages.where((x) => x != p).toList()),
                    child: Container(
                      decoration: const BoxDecoration(
                          color: Colors.white, shape: BoxShape.circle),
                      child: const Icon(Icons.cancel,
                          size: 20, color: Color(0xFF991B1B)),
                    ),
                  ),
                ),
              ]),
            if (_uploading)
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: kPageBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kBorder),
                ),
                child: const Center(
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: kBrand))),
              ),
          ]),
        ),
      Container(
        decoration: BoxDecoration(
          color: kPageBg,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: kBorder),
        ),
        padding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _reply,
              minLines: 1,
              maxLines: 5,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: c('dev_queue.reply_hint'),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          IconButton(
            tooltip: c('dev_queue.btn_attach'),
            onPressed: _attachReplyImage,
            icon: const Icon(Icons.image_outlined, size: 22, color: kTextLo),
            splashRadius: 20,
          ),
          IconButton(
            tooltip: c('dev_queue.btn_attach_file'),
            onPressed: _attachReplyFiles,
            icon: const Icon(Icons.attach_file, size: 22, color: kTextLo),
            splashRadius: 20,
          ),
          Container(
            decoration: const BoxDecoration(
                color: kBrand, shape: BoxShape.circle),
            child: IconButton(
              tooltip: c('dev_queue.btn_send'),
              onPressed: _busy ? null : _sendReply,
              icon: const Icon(Icons.arrow_upward, size: 20, color: Colors.white),
              splashRadius: 22,
            ),
          ),
        ]),
      ),
    ]);
  }

  Widget _bubble(Map<String, dynamic> m) {
    final sender = (m['sender'] ?? '').toString();
    final isOm = sender == 'om';
    return Align(
      alignment: isOm ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: isOm ? const Color(0xFFD1FAE5) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kBorder),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c(isOm ? 'dev_queue.sender_om' : 'dev_queue.sender_agent'),
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700, color: kTextLo)),
          const SizedBox(height: 2),
          if ((m['body'] ?? '').toString().isNotEmpty)
            Text((m['body'] ?? '').toString(),
                style: const TextStyle(fontSize: 14, color: kTextHi)),
          _attachmentStrip(m['images'], m['attachments']),
        ]),
      ),
    );
  }

  // ── Decisions ────────────────────────────────────────────────────────────
  Widget _decisions() {
    final ds = ((_row['decisions'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    return _sectionRaw(
      c('dev_queue.section_decisions'),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final d in ds)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((d['question'] ?? '').toString(),
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: kTextHi)),
              const SizedBox(height: 2),
              Row(children: [
                const Icon(Icons.check_circle, size: 14, color: kBrand),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                      '${d['picked'] ?? ''}${(d['reason'] ?? '').toString().isNotEmpty ? ' — ${d['reason']}' : ''}',
                      style: const TextStyle(fontSize: 13, color: kTextLo)),
                ),
              ]),
            ]),
          ),
      ]),
    );
  }

  // ── Screenshots ────────────────────────────────────────────────────────────
  Widget _screenshots() {
    final shots = ((_row['screenshots'] as List?) ?? const [])
        .map((s) => s is Map ? (s['path'] ?? s['url'] ?? '').toString() : s.toString())
        .where((s) => s.isNotEmpty)
        .toList();
    return _sectionRaw(
      c('dev_queue.section_screenshots'),
      SizedBox(
        height: 140,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: shots.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) => ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 180,
              child: PaymentProofImage(
                bucket: 'dev-cmd-proofs',
                path: shots[i],
                fixedHeight: 140,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A pulsing LIVE chip shown while the runner is actively building, so Om can
  /// see at a glance that the log below is a live tail of the VM session.
  Widget _liveBadge() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFFFEE2E2),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
                color: Color(0xFF991B1B), shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(c('dev_queue.live_badge'),
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF991B1B))),
        ]),
      );

  Widget _buildLog() {
    final log = (_spec['build_log'] ?? _row['build_log_tail'] ?? '').toString();
    final live = _spec['is_live'] == true || _status == 'building';
    return _sectionRaw(
      c('dev_queue.section_log'),
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (live)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Align(alignment: Alignment.centerLeft, child: _liveBadge()),
          ),
        log.trim().isEmpty
            ? Text(c('dev_queue.log_empty'),
                style: const TextStyle(fontSize: 13, color: kTextLo))
            : _scrollLog(log),
      ]),
    );
  }

  /// The build log can run to hundreds of lines. It lives in a fixed-height box
  /// with its OWN vertical scroll so a finger-drag inside it scrolls the log
  /// (previously the SelectableText swallowed the drag and nothing moved).
  Widget _scrollLog(String log) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 360),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kPageBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kBorder),
      ),
      child: Scrollbar(
        thumbVisibility: true,
        child: SingleChildScrollView(
          primary: false,
          child: SelectableText(
            log,
            style: const TextStyle(
                fontSize: 12.5,
                height: 1.45,
                fontFamily: 'monospace',
                color: kTextHi),
          ),
        ),
      ),
    );
  }

  Widget _meta() {
    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
                width: 120,
                child: Text(k, style: const TextStyle(fontSize: 12, color: kTextLo))),
            Expanded(
                child: Text(v,
                    style: const TextStyle(fontSize: 13, color: kTextHi))),
          ]),
        );
    return _sectionRaw(
      c('dev_queue.section_cost'),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        kv(c('dev_queue.section_cost'), rupee(_row['cost_inr'] as num?)),
        kv(c('dev_queue.label_tokens'),
            '${asInt(_row['cost_input_tokens'])} / ${asInt(_row['cost_output_tokens'])}'),
        kv(c('dev_queue.label_retry'), '${asInt(_row['retry_count'])}'),
        if ((_row['claimed_by'] ?? '').toString().isNotEmpty)
          kv(c('dev_queue.label_claimed_by'), _row['claimed_by'].toString()),
        kv(c('dev_queue.label_created'), istShort(_row['created_at']?.toString())),
        if (_row['started_at'] != null)
          kv(c('dev_queue.label_started'), istShort(_row['started_at'].toString())),
        if (_row['finished_at'] != null)
          kv(c('dev_queue.label_finished'), istShort(_row['finished_at'].toString())),
      ]),
    );
  }

  // ── Section scaffolding ────────────────────────────────────────────────────
  Widget _section(String title, Widget child, {Tone? tone}) =>
      _sectionRaw(title, child, tone: tone);

  Widget _sectionRaw(String title, Widget child, {Tone? tone}) => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: tone?.bg ?? Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder),
          boxShadow: tone == null
              ? [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 8,
                      offset: const Offset(0, 2)),
                ]
              : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title.toUpperCase(),
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: tone?.fg ?? kTextLo)),
          const SizedBox(height: 10),
          child,
        ]),
      );

  Widget _mono(dynamic text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: kPageBg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText((text ?? '').toString(),
            style: const TextStyle(
                fontSize: 12.5, height: 1.45, fontFamily: 'monospace', color: kTextHi)),
      );
}

class _ActionBtn extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final Color? color;
  final IconData? icon;
  final bool primary;
  const _ActionBtn(
      {required this.label,
      this.onTap,
      this.color,
      this.icon,
      this.primary = false});

  @override
  Widget build(BuildContext context) {
    final col = color ?? (primary ? kBrand : kTextLo);
    const shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)));
    if (primary) {
      // One filled, eye-catching primary action per screen.
      return FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon ?? Icons.chevron_right, size: 16, color: Colors.white),
        label: Text(label,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
        style: FilledButton.styleFrom(
            backgroundColor: col,
            minimumSize: const Size(0, 44),
            shape: shape,
            padding: const EdgeInsets.symmetric(horizontal: 16)),
      );
    }
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon ?? Icons.chevron_right, size: 16, color: col),
      label: Text(label,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: col)),
      style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: shape,
          side: BorderSide(color: col.withValues(alpha: 0.4))),
    );
  }
}

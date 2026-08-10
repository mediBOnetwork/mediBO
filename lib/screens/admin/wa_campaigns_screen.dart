// CHANGE — WhatsApp campaign builder + tracking link redirect (PARTS B, D, E).
//
// /admin/wa-campaigns — the campaign list, the dry run, the schedule/approve
// actions and the recipient log.
//
// This screen computes NOTHING. Every sentence it prints already exists in the
// payload:
//
//   • the policy strip is four sentences the backend built from app_settings
//     ('wa_send_policy'), not four numbers this file formats. Change the send
//     window and the strip changes with no deploy.
//   • status_label / status_tone, summary_label, result_label, schedule_label,
//     audience_label — all printed verbatim.
//   • which buttons exist is can_edit / can_schedule / can_approve / can_pause /
//     can_resume / can_resend_failed. The app never looks at `status` to decide
//     what an admin may do; that would be two answers to one question, and the
//     backend's would be the one the cron obeys.
//   • the recipient filter chips take their words from the rows' own
//     status_label, so this file holds no list of statuses either.
//
// There is deliberately NO "send now to everyone" button. Once scheduled, a
// server cron dispatches inside the send window; a client-side blast would
// bypass the window, the frequency cap and the approval threshold at once.
import 'package:flutter/material.dart';

import '../../features/whatsapp/data/wa_campaign_api.dart';
import '../../features/whatsapp/ui/wa_campaign_chips.dart';
import '../../services/ui_copy.dart' as uicopy;
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'wa_campaign_builder_screen.dart';

const _kGreen = Color(0xFF1B7A43);
const _kBg = Color(0xFFF5F6F8);
const _kCard = Colors.white;
const _kBorder = Color(0xFFE5E7EB);
const _kText = Color(0xFF111827);
const _kMuted = Color(0xFF6B7280);
const _kAmber = Color(0xFF92400E);
const _kRed = Color(0xFFB91C1C);

class WaCampaignsScreen extends StatefulWidget {
  // Injected RPCs — tests stub these; production leaves them null.
  final WaCampaignsScreenRpc? screenRpc;
  final WaCampaignDetailRpc? detailRpc;
  final WaCampaignDryRunRpc? dryRunRpc;
  final WaCampaignScheduleRpc? scheduleRpc;
  final WaCampaignActionRpc? actionRpc;
  final WaCampaignHoldoutRpc? holdoutRpc;

  // Handed to the builder when Edit / New is tapped.
  final WaTemplatesScreenRpc? templatesRpc;
  final WaTemplateTokensRpc? tokensRpc;
  final WaCampaignSaveRpc? saveRpc;
  final WaCampaignPreflightRpc? preflightRpc;
  final WaCampaignEstimateRpc? estimateRpc;
  final WaAudiencesScreenRpc? audiencesRpc;

  const WaCampaignsScreen({
    super.key,
    this.screenRpc,
    this.detailRpc,
    this.dryRunRpc,
    this.scheduleRpc,
    this.actionRpc,
    this.holdoutRpc,
    this.templatesRpc,
    this.tokensRpc,
    this.saveRpc,
    this.preflightRpc,
    this.estimateRpc,
    this.audiencesRpc,
  });

  @override
  State<WaCampaignsScreen> createState() => _WaCampaignsScreenState();
}

class _WaCampaignsScreenState extends State<WaCampaignsScreen> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  String? _error;

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
      final res = await (widget.screenRpc ?? waCampaignsScreen)();
      if (!mounted) return;
      // not_authorized is a payload, not an exception — print what it said.
      if (res['ok'] != true) {
        setState(() {
          _loading = false;
          _error = (res['message'] ?? res['error'] ?? '').toString();
        });
        return;
      }
      setState(() {
        _payload = res;
        _loading = false;
      });
      try {
        RenderLog.write('wa_campaigns_screen',
            'campaigns=${(res['campaigns'] as List?)?.length ?? 0}');
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  List<Map<String, dynamic>> get _campaigns =>
      ((_payload?['campaigns'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  Future<void> _openBuilder({Map<String, dynamic>? campaign}) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WaCampaignBuilderScreen(
          campaign: campaign,
          audiences: (_payload?['audiences'] as List?) ?? const [],
          triggers: (_payload?['triggers'] as List?) ?? const [],
          templatesRpc: widget.templatesRpc,
          tokensRpc: widget.tokensRpc,
          saveRpc: widget.saveRpc,
          preflightRpc: widget.preflightRpc,
          estimateRpc: widget.estimateRpc,
          dryRunRpc: widget.dryRunRpc,
          scheduleRpc: widget.scheduleRpc,
          audiencesRpc: widget.audiencesRpc,
        ),
      ),
    );
    if (changed == true) _load();
  }

  // ── actions ───────────────────────────────────────────────────────────────

  Future<void> _runAction(Map<String, dynamic> c, String action) async {
    final id = (c['id'] ?? '').toString();
    try {
      final res = await (widget.actionRpc ?? waCampaignAction)(id, action);
      if (!mounted) return;
      if (res['ok'] != true) {
        // bad_action carries `allowed` — show the backend's own vocabulary
        // rather than a guess at what went wrong.
        final allowed = (res['allowed'] as List?)?.join(', ') ?? '';
        showToast(
          context,
          [
            (res['message'] ?? res['error'] ?? '').toString(),
            if (allowed.isNotEmpty) allowed,
          ].where((s) => s.isNotEmpty).join(' — '),
          isError: true,
        );
        return;
      }
      if (res.containsKey('requeued')) {
        showToast(
            context,
            uicopy.cf('wa_campaigns.toast_requeued',
                {'n': (res['requeued'] ?? '').toString()}));
      }
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    }
  }

  Future<void> _confirmCancel(Map<String, dynamic> c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(uicopy.c('wa_campaigns.cancel_title')),
        content: Text(
          uicopy.cf('wa_campaigns.cancel_body',
              {'name': (c['name'] ?? '').toString()}),
          style: const TextStyle(fontSize: 13.5, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(uicopy.c('wa_campaigns.cancel_keep')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: _kRed),
            child: Text(uicopy.c('wa_campaigns.cancel_confirm')),
          ),
        ],
      ),
    );
    if (ok == true) await _runAction(c, 'cancel');
  }

  Future<void> _schedule(Map<String, dynamic> c) async {
    final picked = await showWaSchedulePicker(
      context,
      windowLabel: _policyLabel('send_window_label'),
    );
    if (picked == null || !mounted) return;
    try {
      final res = await (widget.scheduleRpc ?? waCampaignSchedule)(
        (c['id'] ?? '').toString(),
        picked.at,
      );
      if (!mounted) return;
      await _showScheduleOutcome(res);
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    }
  }

  Future<void> _showScheduleOutcome(Map<String, dynamic> res) async {
    if (res['error'] == 'preflight_failed') {
      final issues = ((res['issues'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(uicopy.c('wa_campaigns.preflight_failed_title')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final i in issues) _errorLine(i),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(uicopy.c('wa_campaigns.close')),
            ),
          ],
        ),
      );
      return;
    }
    if (res['ok'] != true) {
      showToast(context, (res['message'] ?? res['error'] ?? '').toString(),
          isError: true);
      return;
    }

    final estimate = (res['estimate'] as Map?) ?? const {};
    final estimateLabel = (estimate['label'] ?? '').toString();
    final recipients = (res['recipients'] ?? '').toString();
    final status = (res['status'] ?? '').toString();
    // 'pending_approval' returns its own message; 'scheduled' does not, so the
    // recipient count and the cost line stand in for it.
    final message = (res['message'] ?? '').toString();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(status == 'pending_approval'
            ? uicopy.c('wa_campaigns.outcome_needs_approval')
            : uicopy.c('wa_campaigns.outcome_scheduled')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.isNotEmpty)
              Text(message, style: const TextStyle(fontSize: 14, height: 1.4)),
            if (message.isEmpty)
              Text(
                  uicopy.cf('wa_campaigns.outcome_recipients',
                      {'n': recipients}),
                  style: const TextStyle(fontSize: 14, height: 1.4)),
            if (estimateLabel.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(estimateLabel,
                  style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: _kGreen)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(uicopy.c('wa_campaigns.ok')),
          ),
        ],
      ),
    );
  }

  String _policyLabel(String key) =>
      ((_payload?['policy'] as Map?)?[key] ?? '').toString();

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kCard,
        elevation: 0,
        foregroundColor: _kText,
        title: Text(uicopy.c('wa_campaigns.title'),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: _kBorder),
        ),
        actions: [
          IconButton(
            tooltip: uicopy.c('wa_campaigns.refresh_tooltip'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: _payload == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openBuilder(),
              backgroundColor: _kGreen,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: Text(uicopy.c('wa_campaigns.new_campaign')),
            ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const _ListSkeleton();
    if (_error != null) {
      return _RetryState(message: _error!, onRetry: _load);
    }

    final campaigns = _campaigns;
    final policy = (_payload?['policy'] as Map?) ?? const {};

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        children: [
          _PolicyStrip(
            policy: Map<String, dynamic>.from(policy),
            suppressedLabel: (_payload?['suppressed_label'] ?? '').toString(),
            suppressedCount: _payload?['suppressed_count'],
          ),
          const SizedBox(height: 12),
          if (campaigns.isEmpty)
            _EmptyState(empty: (_payload?['empty'] as Map?) ?? const {})
          else
            for (final c in campaigns)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _CampaignCard(
                  c: c,
                  onEdit: () => _openBuilder(campaign: c),
                  onSchedule: () => _schedule(c),
                  onApprove: () => _runAction(c, 'approve'),
                  onPause: () => _runAction(c, 'pause'),
                  onResume: () => _runAction(c, 'resume'),
                  onCancel: () => _confirmCancel(c),
                  onResendFailed: () => _runAction(c, 'resend_failed'),
                  onDryRun: () => showWaDryRunSheet(
                    context,
                    campaignId: (c['id'] ?? '').toString(),
                    dryRunRpc: widget.dryRunRpc,
                  ),
                  onViewRecipients: () async {
                    await showWaRecipientLog(
                      context,
                      campaignId: (c['id'] ?? '').toString(),
                      campaignName: (c['name'] ?? '').toString(),
                      detailRpc: widget.detailRpc,
                      holdoutRpc: widget.holdoutRpc,
                      // holdout_pct above zero is the backend saying a control
                      // group exists to measure. The section is not offered on
                      // a campaign that never held anyone back.
                      hasHoldout:
                          (num.tryParse((c['holdout_pct'] ?? '').toString()) ??
                                  0) >
                              0,
                      onResendFailed: () => _runAction(c, 'resend_failed'),
                      canResendFailed: c['can_resend_failed'] == true,
                    );
                  },
                ),
              ),
        ],
      ),
    );
  }
}

// ── policy strip ────────────────────────────────────────────────────────────

/// Four sentences and an opt-out count, all built by the backend from
/// app_settings. This widget knows the KEYS, never the VALUES: it cannot tell
/// you what the send window is, and that is the point — changing 9–20 to 10–19
/// is an UPDATE to one jsonb row, not a deploy.
class _PolicyStrip extends StatelessWidget {
  final Map<String, dynamic> policy;
  final String suppressedLabel;
  final dynamic suppressedCount;

  const _PolicyStrip({
    required this.policy,
    required this.suppressedLabel,
    this.suppressedCount,
  });

  @override
  Widget build(BuildContext context) {
    final lines = <(IconData, String)>[
      (Icons.schedule_outlined, (policy['send_window_label'] ?? '').toString()),
      (Icons.repeat_outlined, (policy['frequency_cap_label'] ?? '').toString()),
      (Icons.pause_circle_outline, (policy['auto_pause_label'] ?? '').toString()),
      (Icons.verified_outlined, (policy['approval_label'] ?? '').toString()),
      // suppressed_label is "N customers opted out", already assembled. Only if
      // the backend sent no sentence at all does the raw count stand in — and
      // then it is printed bare, not wrapped in words this file invented.
      (
        Icons.block_outlined,
        suppressedLabel.isNotEmpty
            ? suppressedLabel
            : (suppressedCount == null ? '' : suppressedCount.toString())
      ),
    ].where((e) => e.$2.isNotEmpty).toList();

    if (lines.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(l.$1, size: 15, color: _kMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.$2,
                      style: const TextStyle(
                          fontSize: 12.5, height: 1.35, color: _kMuted),
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

// ── campaign card ───────────────────────────────────────────────────────────

class _CampaignCard extends StatelessWidget {
  final Map<String, dynamic> c;
  final VoidCallback onEdit;
  final VoidCallback onSchedule;
  final VoidCallback onApprove;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;
  final VoidCallback onResendFailed;
  final VoidCallback onDryRun;
  final VoidCallback onViewRecipients;

  const _CampaignCard({
    required this.c,
    required this.onEdit,
    required this.onSchedule,
    required this.onApprove,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    required this.onResendFailed,
    required this.onDryRun,
    required this.onViewRecipients,
  });

  String _s(String k) => (c[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final pausedReason = _s('paused_reason');

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  _s('name'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700, color: _kText),
                ),
              ),
              const SizedBox(width: 8),
              WaToneChip(
                  label: _s('status_label'), tone: c['status_tone']?.toString()),
            ],
          ),
          if (pausedReason.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, size: 14, color: _kAmber),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      pausedReason,
                      style: const TextStyle(
                          fontSize: 12.5, height: 1.3, color: _kAmber),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (_s('template').isNotEmpty) WaPlainChip(label: _s('template')),
              if (_s('category').isNotEmpty) WaPlainChip(label: _s('category')),
              // A repeating campaign spawns a child row per run. is_repeat_child
              // is the backend's answer to "is this one of them?" — the app does
              // not infer it from runs_done being above zero, because the parent
              // carries runs_done too.
              if (c['is_repeat_child'] == true)
                WaPlainChip(
                    label: uicopy.cf('wa_campaigns.chip_run',
                        {'n': (c['runs_done'] ?? '').toString()})),
            ],
          ),
          const SizedBox(height: 8),
          _metaRow(Icons.people_outline, _s('audience_label')),
          _metaRow(Icons.event_outlined, _s('schedule_label')),
          _metaRow(Icons.repeat_outlined, _s('repeat_label')),
          _metaRow(Icons.shield_outlined, _s('holdout_label')),
          _metaRow(Icons.send_outlined, _s('summary_label')),
          _metaRow(Icons.trending_up, _s('result_label')),
          _budgetBlock(),
          // blank_values counts recipients whose variables resolved to nothing.
          // It is a warning, never a block: the backend already decided those
          // messages may go, and blank_warning is its sentence about them.
          WaWarnBanner(text: _blankValues > 0 ? _s('blank_warning') : ''),
          const SizedBox(height: 10),
          const Divider(height: 1, color: _kBorder),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              // Strictly flag-gated. A missing flag is a false, never a guess
              // from `status`.
              if (c['can_edit'] == true)
                _action(Icons.edit_outlined,
                    uicopy.c('wa_campaigns.action_edit'), onEdit),
              if (c['can_schedule'] == true)
                _action(Icons.schedule_send_outlined,
                    uicopy.c('wa_campaigns.action_schedule'), onSchedule),
              if (c['can_approve'] == true)
                _action(Icons.verified_outlined,
                    uicopy.c('wa_campaigns.action_approve'), onApprove,
                    primary: true),
              if (c['can_pause'] == true)
                _action(Icons.pause_circle_outline,
                    uicopy.c('wa_campaigns.action_pause'), onPause),
              if (c['can_resume'] == true)
                _action(Icons.play_circle_outline,
                    uicopy.c('wa_campaigns.action_resume'), onResume),
              if (c['can_resend_failed'] == true)
                _action(Icons.refresh,
                    uicopy.c('wa_campaigns.action_resend_failed'),
                    onResendFailed),
              _action(Icons.science_outlined,
                  uicopy.c('wa_campaigns.action_dry_run'), onDryRun),
              _action(Icons.receipt_long_outlined,
                  uicopy.c('wa_campaigns.action_view_recipients'),
                  onViewRecipients),
              if (c['can_edit'] == true)
                _action(Icons.cancel_outlined,
                    uicopy.c('wa_campaigns.action_cancel'), onCancel,
                    danger: true),
            ],
          ),
        ],
      ),
    );
  }

  int get _blankValues =>
      int.tryParse((c['blank_values'] ?? '').toString()) ?? 0;

  /// budget_label is the whole sentence ("₹412 of ₹1,000 spent"); budget_tone
  /// says whether that is fine, tight or over; budget_pct fills the bar. Not one
  /// of the three is derived from the others here — a campaign with no cap sends
  /// an empty label and this block disappears.
  Widget _budgetBlock() {
    final label = _s('budget_label');
    if (label.isEmpty) return const SizedBox.shrink();
    final pct = num.tryParse((c['budget_pct'] ?? '').toString());
    final tone = c['budget_tone']?.toString();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          WaToneChip(label: label, tone: tone),
          if (pct != null) ...[
            const SizedBox(height: 6),
            WaToneBar(pct: pct, tone: tone),
          ],
        ],
      ),
    );
  }

  Widget _metaRow(IconData icon, String text) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: _kMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 12.5, height: 1.35, color: _kMuted)),
          ),
        ],
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback onTap,
      {bool primary = false, bool danger = false}) {
    final fg = danger ? _kRed : (primary ? Colors.white : _kText);
    final bg = primary ? _kGreen : const Color(0xFFF9FAFB);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: primary ? _kGreen : _kBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
          ],
        ),
      ),
    );
  }
}

// ── empty / error / skeleton ────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final Map empty;
  const _EmptyState({required this.empty});

  @override
  Widget build(BuildContext context) {
    final title = (empty['title'] ?? '').toString();
    final note = (empty['note'] ?? '').toString();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          const Icon(Icons.campaign_outlined, size: 40, color: Color(0xFF9CA3AF)),
          const SizedBox(height: 12),
          if (title.isNotEmpty)
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: _kText)),
          if (note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(note,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13, height: 1.4, color: _kMuted)),
          ],
        ],
      ),
    );
  }
}

class _RetryState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _RetryState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 36, color: _kRed),
              const SizedBox(height: 12),
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: _kMuted)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: onRetry,
                style: ElevatedButton.styleFrom(
                    backgroundColor: _kGreen, foregroundColor: Colors.white),
                child: Text(uicopy.c('wa_campaigns.retry')),
              ),
            ],
          ),
        ),
      );
}

class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (var i = 0; i < 4; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                height: i == 0 ? 96 : 150,
                decoration: BoxDecoration(
                  color: _kCard,
                  border: Border.all(color: _kBorder),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(Color(0xFFD1D5DB)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
}

Widget _errorLine(String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 15, color: _kRed),
          const SizedBox(width: 7),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 13, height: 1.35, color: _kRed)),
          ),
        ],
      ),
    );

/// Shared with the builder so a preflight failure reads identically wherever it
/// surfaces. Strings are the backend's, printed one per line, unedited.
Widget waPreflightErrors(List<String> errors) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final e in errors) _errorLine(e)],
    );

// ── schedule picker ─────────────────────────────────────────────────────────

class WaScheduleChoice {
  /// null == send at the next opportunity; the backend coalesces it to now()
  /// and the cron still holds it to the send window.
  final DateTime? at;
  const WaScheduleChoice(this.at);
}

/// "Send now" or a date+time. Note the picked value is the DEVICE's wall clock
/// sent as an instant (toUtc) — for the Raipur admins that is IST, which is what
/// the window label above the picker states. This file does not apply a +05:30
/// constant of its own: the offset belongs to the backend's timezone, not to a
/// number hardcoded in Dart.
Future<WaScheduleChoice?> showWaSchedulePicker(
  BuildContext context, {
  String windowLabel = '',
}) async {
  return showModalBottomSheet<WaScheduleChoice>(
    context: context,
    backgroundColor: _kCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(uicopy.c('wa_campaigns.schedule_sheet_title'),
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: _kText)),
            if (windowLabel.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(windowLabel,
                  style: const TextStyle(fontSize: 12.5, color: _kMuted)),
            ],
            const SizedBox(height: 14),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bolt_outlined, color: _kGreen),
              title: Text(uicopy.c('wa_campaigns.schedule_next_window_title'),
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              subtitle: Text(
                  uicopy.c('wa_campaigns.schedule_next_window_note'),
                  style: const TextStyle(fontSize: 12, color: _kMuted)),
              onTap: () => Navigator.pop(ctx, const WaScheduleChoice(null)),
            ),
            const Divider(height: 1, color: _kBorder),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined, color: _kGreen),
              title: Text(uicopy.c('wa_campaigns.schedule_pick_datetime'),
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              onTap: () async {
                final now = DateTime.now();
                final d = await showDatePicker(
                  context: ctx,
                  initialDate: now,
                  firstDate: now.subtract(const Duration(days: 1)),
                  lastDate: now.add(const Duration(days: 365)),
                );
                if (d == null || !ctx.mounted) return;
                final t = await showTimePicker(
                  context: ctx,
                  initialTime: TimeOfDay.fromDateTime(now),
                );
                if (t == null || !ctx.mounted) return;
                Navigator.pop(
                  ctx,
                  WaScheduleChoice(
                      DateTime(d.year, d.month, d.day, t.hour, t.minute)),
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}

// ── dry run sheet (PART D1) ─────────────────────────────────────────────────

/// Shows the template body, then each sample's phone and its `preview` string.
///
/// The preview is NOT built here. wa_render_preview() substitutes the variables
/// server-side and the sheet prints the result — if Dart did the substitution it
/// would be a second renderer, and the one an admin approved would not be the
/// one Meta receives.
Future<void> showWaDryRunSheet(
  BuildContext context, {
  required String campaignId,
  WaCampaignDryRunRpc? dryRunRpc,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: _kCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _DryRunSheet(campaignId: campaignId, dryRunRpc: dryRunRpc),
  );
}

class _DryRunSheet extends StatefulWidget {
  final String campaignId;
  final WaCampaignDryRunRpc? dryRunRpc;
  const _DryRunSheet({required this.campaignId, this.dryRunRpc});

  @override
  State<_DryRunSheet> createState() => _DryRunSheetState();
}

class _DryRunSheetState extends State<_DryRunSheet> {
  Map<String, dynamic>? _res;
  bool _loading = true;
  String? _error;

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
      final res =
          await (widget.dryRunRpc ?? waCampaignDryRun)(widget.campaignId, 3);
      if (!mounted) return;
      if (res['ok'] != true) {
        setState(() {
          _loading = false;
          _error = (res['message'] ?? res['error'] ?? '').toString();
        });
        return;
      }
      setState(() {
        _res = res;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (_, scroll) {
        if (_loading) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(40),
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation(_kGreen),
              ),
            ),
          );
        }
        if (_error != null) {
          return _RetryState(message: _error!, onRetry: _load);
        }

        final res = _res ?? const {};
        final body = (res['template_body'] ?? '').toString();
        final samples = ((res['samples'] as List?) ?? const [])
            .whereType<Map>()
            .toList();
        final estimate = (res['estimate'] as Map?) ?? const {};
        final estimateLabel = (estimate['label'] ?? '').toString();
        final pending = (res['pending'] ?? '').toString();

        return ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Text(uicopy.c('wa_campaigns.dry_run_title'),
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, color: _kText)),
            const SizedBox(height: 12),
            if (body.isNotEmpty) ...[
              Text(uicopy.c('wa_campaigns.dry_run_template_body'),
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: _kMuted)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF9FAFB),
                  border: Border.all(color: _kBorder),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(body,
                    style: const TextStyle(
                        fontSize: 12.5, height: 1.4, color: _kMuted)),
              ),
              const SizedBox(height: 14),
            ],
            if (samples.isEmpty)
              Text(uicopy.c('wa_campaigns.dry_run_empty'),
                  style: const TextStyle(fontSize: 13, color: _kMuted))
            else
              for (final s in samples)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE7FFDB),
                      border: Border.all(color: const Color(0xFFC7EBB5)),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((s['phone'] ?? '').toString(),
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: _kGreen)),
                        const SizedBox(height: 6),
                        Text((s['preview'] ?? '').toString(),
                            style: const TextStyle(
                                fontSize: 13.5, height: 1.45, color: _kText)),
                      ],
                    ),
                  ),
                ),
            const SizedBox(height: 6),
            if (estimateLabel.isNotEmpty)
              Row(
                children: [
                  const Icon(Icons.payments_outlined, size: 16, color: _kGreen),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(estimateLabel,
                        style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: _kGreen)),
                  ),
                ],
              ),
            if (pending.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                    uicopy.cf('wa_campaigns.pending_count', {'n': pending}),
                    style: const TextStyle(fontSize: 12, color: _kMuted)),
              ),
          ],
        );
      },
    );
  }
}

// ── recipient log (PART E) ──────────────────────────────────────────────────

Future<void> showWaRecipientLog(
  BuildContext context, {
  required String campaignId,
  required String campaignName,
  WaCampaignDetailRpc? detailRpc,
  WaCampaignHoldoutRpc? holdoutRpc,
  bool hasHoldout = false,
  VoidCallback? onResendFailed,
  bool canResendFailed = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: _kCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _RecipientLogSheet(
      campaignId: campaignId,
      campaignName: campaignName,
      detailRpc: detailRpc,
      holdoutRpc: holdoutRpc,
      hasHoldout: hasHoldout,
      onResendFailed: onResendFailed,
      canResendFailed: canResendFailed,
    ),
  );
}

class _RecipientLogSheet extends StatefulWidget {
  final String campaignId;
  final String campaignName;
  final WaCampaignDetailRpc? detailRpc;
  final WaCampaignHoldoutRpc? holdoutRpc;
  final bool hasHoldout;
  final VoidCallback? onResendFailed;
  final bool canResendFailed;

  const _RecipientLogSheet({
    required this.campaignId,
    required this.campaignName,
    this.detailRpc,
    this.holdoutRpc,
    this.hasHoldout = false,
    this.onResendFailed,
    this.canResendFailed = false,
  });

  @override
  State<_RecipientLogSheet> createState() => _RecipientLogSheetState();
}

class _RecipientLogSheetState extends State<_RecipientLogSheet> {
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true;
  String? _error;

  /// null == the All chip. Otherwise a raw `status` value taken from the rows
  /// themselves — this file holds no list of statuses.
  String? _filter;

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
      final res =
          await (widget.detailRpc ?? waCampaignDetail)(widget.campaignId, 100);
      if (!mounted) return;
      if (res['ok'] != true) {
        setState(() {
          _loading = false;
          _error = (res['message'] ?? res['error'] ?? '').toString();
        });
        return;
      }
      setState(() {
        _rows = ((res['recipients'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// One chip per status actually present, labelled with that status's own
  /// `status_label` from the payload. No counts are recomputed here — the chips
  /// select rows, they do not claim totals.
  List<(String?, String)> _chips() {
    final seen = <String, String>{};
    for (final r in _rows) {
      final key = (r['status'] ?? '').toString();
      if (key.isEmpty) continue;
      seen.putIfAbsent(key, () => (r['status_label'] ?? key).toString());
    }
    return [
      (null, uicopy.c('wa_campaigns.filter_all')),
      ...seen.entries.map((e) => (e.key, e.value)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (_, scroll) {
        if (_loading) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(40),
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation(_kGreen),
              ),
            ),
          );
        }
        if (_error != null) {
          return _RetryState(message: _error!, onRetry: _load);
        }

        final visible = _filter == null
            ? _rows
            : _rows.where((r) => (r['status'] ?? '').toString() == _filter)
                .toList();

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.campaignName,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: _kText),
                    ),
                  ),
                  if (widget.canResendFailed && widget.onResendFailed != null)
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        widget.onResendFailed!.call();
                      },
                      icon: const Icon(Icons.refresh, size: 15),
                      label: Text(uicopy.c('wa_campaigns.action_resend_failed'),
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                ],
              ),
            ),
            if (widget.hasHoldout)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: WaHoldoutSection(
                  campaignId: widget.campaignId,
                  holdoutRpc: widget.holdoutRpc,
                ),
              ),
            SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final ch in _chips())
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(ch.$2,
                            style: const TextStyle(fontSize: 12)),
                        selected: _filter == ch.$1,
                        onSelected: (_) => setState(() => _filter = ch.$1),
                        selectedColor: const Color(0xFFD1FAE5),
                        backgroundColor: const Color(0xFFF9FAFB),
                        side: const BorderSide(color: _kBorder),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1, color: _kBorder),
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Text(uicopy.c('wa_campaigns.log_empty'),
                          style: const TextStyle(fontSize: 13, color: _kMuted)),
                    )
                  : ListView.separated(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      itemCount: visible.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 14, color: _kBorder),
                      itemBuilder: (_, i) => _RecipientRow(r: visible[i]),
                    ),
            ),
          ],
        );
      },
    );
  }
}

// ── control group ───────────────────────────────────────────────────────────

/// The held-back slice, measured. wa_campaign_holdout() compares the people who
/// received the campaign against the people deliberately not sent to, over its
/// own measure_days window, and returns `summary` as the finished sentence plus
/// `lift_pct` as the one number worth reading.
///
/// Nothing here is arithmetic. order_pct, revenue and lift_pct arrive computed;
/// if this file divided orders by people it would publish a second answer to a
/// question the backend has already answered from the same rows.
class WaHoldoutSection extends StatefulWidget {
  final String campaignId;
  final WaCampaignHoldoutRpc? holdoutRpc;

  const WaHoldoutSection({
    super.key,
    required this.campaignId,
    this.holdoutRpc,
  });

  @override
  State<WaHoldoutSection> createState() => _WaHoldoutSectionState();
}

class _WaHoldoutSectionState extends State<WaHoldoutSection> {
  Map<String, dynamic>? _res;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res =
          await (widget.holdoutRpc ?? waCampaignHoldout)(widget.campaignId);
      if (!mounted) return;
      final err = waPayloadError(res);
      setState(() {
        _loading = false;
        _error = err;
        _res = err == null ? res : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: SizedBox(
          height: 16,
          width: 16,
          child: CircularProgressIndicator(
              strokeWidth: 2, valueColor: AlwaysStoppedAnimation(_kGreen)),
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(_error!,
            style: const TextStyle(fontSize: 12.5, color: _kMuted)),
      );
    }

    final res = _res ?? const {};
    final summary = (res['summary'] ?? '').toString();
    final lift = (res['lift_pct'] ?? '').toString();
    final sent = (res['sent_group'] as Map?) ?? const {};
    final held = (res['holdout_group'] as Map?) ?? const {};
    final measuredFrom = (res['measured_from'] ?? '').toString();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(uicopy.c('wa_campaigns.holdout_title'),
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: _kText)),
          if (summary.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(summary,
                style: const TextStyle(
                    fontSize: 12.5, height: 1.4, color: _kMuted)),
          ],
          if (lift.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(lift,
                style: const TextStyle(
                    fontSize: 26, fontWeight: FontWeight.w700, color: _kGreen)),
          ],
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                  child: _group(uicopy.c('wa_campaigns.holdout_group_sent'),
                      sent)),
              const SizedBox(width: 12),
              Expanded(
                  child: _group(uicopy.c('wa_campaigns.holdout_group_held'),
                      held)),
            ],
          ),
          if (measuredFrom.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(measuredFrom,
                style: const TextStyle(fontSize: 11.5, color: _kMuted)),
          ],
        ],
      ),
    );
  }

  /// `caption` is the column heading. Every VALUE below it is the backend's.
  Widget _group(String caption, Map group) {
    Widget line(String k) {
      final v = (group[k] ?? '').toString();
      if (v.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(v,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: _kText)),
      );
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(caption,
              style: const TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w600, color: _kMuted)),
          line('people'),
          line('order_pct'),
          line('revenue'),
        ],
      ),
    );
  }
}

class _RecipientRow extends StatelessWidget {
  final Map<String, dynamic> r;
  const _RecipientRow({required this.r});

  String _s(String k) => (r[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final skip = _s('skip_reason');
    final err = _s('error');
    final sent = _s('sent_label');
    final revenue = _s('revenue_label');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(_s('phone'),
                  style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: _kText)),
            ),
            WaToneChip(
                label: _s('status_label'),
                tone: r['status_tone']?.toString(),
                fontSize: 11),
          ],
        ),
        if (sent.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(sent,
                style: const TextStyle(fontSize: 11.5, color: _kMuted)),
          ),
        if (r['clicked'] == true || r['ordered'] == true || revenue.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Wrap(
              spacing: 5,
              runSpacing: 4,
              children: [
                if (r['clicked'] == true)
                  WaToneChip(
                      label: uicopy.c('wa_campaigns.chip_clicked'),
                      tone: 'blue'),
                if (r['ordered'] == true)
                  WaToneChip(
                      label: uicopy.c('wa_campaigns.chip_ordered'),
                      tone: 'green'),
                if (revenue.isNotEmpty)
                  WaToneChip(label: revenue, tone: 'green'),
              ],
            ),
          ),
        // skip_reason and error are printed EXACTLY as stored — they are the
        // record of why a message did not go, and a prettier paraphrase would
        // make an audit unanswerable.
        if (skip.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(skip,
                style: const TextStyle(fontSize: 11.5, color: _kAmber)),
          ),
        if (err.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(err,
                style: const TextStyle(fontSize: 11.5, color: _kRed)),
          ),
      ],
    );
  }
}

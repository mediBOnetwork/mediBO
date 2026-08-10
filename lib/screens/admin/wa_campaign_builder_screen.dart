// CHANGE — WhatsApp campaign builder + tracking link redirect (PART C).
//
// Five steps: template, audience, variables, link, schedule.
//
// The builder collects INPUT. It does not judge it. Whether the variable count
// matches the template, whether a tracking link has a URL button to ride on,
// whether the template is still Approved at Meta, whether anyone is left after
// suppression and the frequency cap — every one of those is wa_campaign_preflight(),
// and its errors[] are printed word for word. Schedule stays disabled while that
// list is non-empty.
//
// This matters more here than anywhere else on the screen: a variable-count
// mismatch does not fail one message, it makes Meta reject EVERY message in the
// campaign. If Dart carried its own opinion of "looks fine" the two would drift,
// and the one the admin trusted would be the one that is not enforced.
import 'package:flutter/material.dart';

import '../../services/ui_copy.dart';
import '../../features/whatsapp/data/wa_campaign_api.dart';
import '../../features/whatsapp/ui/wa_campaign_chips.dart';
import '../../utils/toast.dart';
import 'wa_campaigns_screen.dart';

const _kGreen = Color(0xFF1B7A43);
const _kBg = Color(0xFFF5F6F8);
const _kCard = Colors.white;
const _kBorder = Color(0xFFE5E7EB);
const _kText = Color(0xFF111827);
const _kMuted = Color(0xFF6B7280);
const _kRed = Color(0xFFB91C1C);
const _kAmber = Color(0xFF92400E);

/// Placeholders Meta substitutes: {{1}}, {{2}} … The builder needs the COUNT to
/// draw the right number of rows. It is a form-layout question, not a validity
/// question — wa_campaign_preflight() remains the only thing that decides
/// whether the count is right, and it blocks the send when it is not.
final _kPlaceholder = RegExp(r'\{\{(\d+)\}\}');

class WaCampaignBuilderScreen extends StatefulWidget {
  /// Existing campaign row (from wa_campaigns_screen) when editing; null = new.
  final Map<String, dynamic>? campaign;

  /// Audience and trigger options, passed down from the list payload so the
  /// builder never invents a segment the backend cannot resolve.
  final List<dynamic> audiences;
  final List<dynamic> triggers;

  final WaTemplatesScreenRpc? templatesRpc;
  final WaTemplateTokensRpc? tokensRpc;
  final WaCampaignSaveRpc? saveRpc;
  final WaCampaignPreflightRpc? preflightRpc;
  final WaCampaignEstimateRpc? estimateRpc;
  final WaCampaignDryRunRpc? dryRunRpc;
  final WaCampaignScheduleRpc? scheduleRpc;

  /// Saved segments come from their own screen's RPC. A failure here costs the
  /// builder one row of chips, never the form.
  final WaAudiencesScreenRpc? audiencesRpc;

  const WaCampaignBuilderScreen({
    super.key,
    this.campaign,
    this.audiences = const [],
    this.triggers = const [],
    this.templatesRpc,
    this.tokensRpc,
    this.saveRpc,
    this.preflightRpc,
    this.estimateRpc,
    this.dryRunRpc,
    this.scheduleRpc,
    this.audiencesRpc,
  });

  @override
  State<WaCampaignBuilderScreen> createState() =>
      _WaCampaignBuilderScreenState();
}

class _WaCampaignBuilderScreenState extends State<WaCampaignBuilderScreen> {
  final _nameCtrl = TextEditingController();
  final _linkCtrl = TextEditingController();
  final _throttleCtrl = TextEditingController(text: '60');
  final _needsCtrl = TextEditingController();

  // Budget / control group / repeat. Every one of these is INPUT — none of them
  // is consulted to decide anything on this screen. Whether a ₹500 cap is
  // reached, whether a 20% control group is even allowed on this audience, when
  // the next weekly run falls: all three are the backend's answers, arriving
  // back as budget_label, holdout_taken and repeat_label.
  final _budgetCtrl = TextEditingController();
  final _repeatIntervalCtrl = TextEditingController(text: '1');
  final _repeatDomCtrl = TextEditingController();
  final _repeatMaxRunsCtrl = TextEditingController();
  double _holdoutPct = 0;
  String _repeatKind = 'none';
  final Set<int> _repeatDays = <int>{};
  DateTime? _repeatUntil;

  List<Map<String, dynamic>> _templates = const [];
  List<Map<String, dynamic>> _tokens = const [];
  List<Map<String, dynamic>> _savedSegments = const [];
  bool _loading = true;
  String? _loadError;

  /// Sentences the last save handed back. Neither blocks anything; both are
  /// printed word for word and cleared on the next save.
  String _blankWarning = '';
  String _holdoutNote = '';

  Map<String, dynamic>? _template;

  // Step 2 — saved segment XOR segment XOR trigger. At most one is non-null.
  String? _audienceKey;
  String? _triggerKey;
  String? _savedAudienceId;

  /// One row per placeholder. `token` is a key from wa_template_tokens();
  /// `text` is used when that key is the fixed-text option.
  final List<_VarRow> _vars = [];

  // Post-save state.
  String? _campaignId;
  List<String> _preflightErrors = const [];
  bool _preflightRan = false;
  int _recipients = 0;
  String _estimateLabel = '';
  bool _saving = false;

  bool get _canSchedule =>
      _campaignId != null && _preflightRan && _preflightErrors.isEmpty;

  @override
  void initState() {
    super.initState();
    final c = widget.campaign;
    if (c != null) {
      _campaignId = (c['id'] ?? '').toString();
      _nameCtrl.text = (c['name'] ?? '').toString();
      // Hydrate from the row's RAW values, never from its labels. budget_label
      // is a sentence for reading; budget_inr is the number the field edits.
      final budget = (c['budget_inr'] ?? '').toString();
      if (budget.isNotEmpty && budget != '0') _budgetCtrl.text = budget;
      _holdoutPct =
          (num.tryParse((c['holdout_pct'] ?? '').toString()) ?? 0).toDouble();
      final kind = (c['repeat_kind'] ?? '').toString();
      if (kind.isNotEmpty) _repeatKind = kind;
    }
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _linkCtrl.dispose();
    _throttleCtrl.dispose();
    _needsCtrl.dispose();
    _budgetCtrl.dispose();
    _repeatIntervalCtrl.dispose();
    _repeatDomCtrl.dispose();
    _repeatMaxRunsCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final screen = await (widget.templatesRpc ?? waTemplatesScreen)();
      final tokens = await (widget.tokensRpc ?? waTemplateTokens)();
      // Saved segments are a convenience, not a requirement: if this RPC is
      // unhappy the builder still opens with the built-in segments and triggers.
      List<Map<String, dynamic>> segments = const [];
      try {
        final aud = await (widget.audiencesRpc ?? waAudiencesScreen)();
        if (waPayloadError(aud) == null) {
          segments = ((aud['rows'] as List?) ?? const [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      } catch (_) {}
      if (!mounted) return;
      if (screen['ok'] != true) {
        setState(() {
          _loading = false;
          _loadError = (screen['message'] ?? screen['error'] ?? '').toString();
        });
        return;
      }
      setState(() {
        // can_use_in_campaign is the backend's answer to "may this template
        // send?". The app does not re-derive it from status == 'APPROVED'.
        _templates = ((screen['templates'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .where((t) => t['can_use_in_campaign'] == true)
            .toList();
        _tokens = tokens
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _savedSegments = segments;
        _loading = false;
      });
      // Editing an existing campaign: reload the template it already uses so
      // the variable rows are drawn before anything is touched.
      final c = widget.campaign;
      if (c != null) {
        final name = (c['template'] ?? '').toString();
        final match = _templates.where((t) => t['name'] == name).toList();
        if (match.isNotEmpty) _selectTemplate(match.first);
        await _runPreflight();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e.toString();
      });
    }
  }

  /// The one place the template drives the form: the body's placeholders decide
  /// how many variable rows exist, and the template's category decides the rate
  /// the estimate RPC is asked about.
  void _selectTemplate(Map<String, dynamic> t) {
    final body = (t['body_preview'] ?? '').toString();
    final numbers = _kPlaceholder
        .allMatches(body)
        .map((m) => int.tryParse(m.group(1) ?? '') ?? 0)
        .where((n) => n > 0)
        .toSet();
    final count = numbers.isEmpty ? 0 : numbers.reduce((a, b) => a > b ? a : b);

    setState(() {
      _template = t;
      _vars
        ..clear()
        ..addAll(List.generate(count, (_) => _VarRow()));
      // The template changed, so anything preflight said about the old one is
      // stale. Never leave a green light standing over a changed form.
      _preflightRan = false;
      _preflightErrors = const [];
      _estimateLabel = '';
    });
  }

  String get _category => (_template?['category'] ?? '').toString();

  // ── save / preflight ──────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_template == null) {
      showToast(context, c('wa_campaign_builder_screen.pick_a_template_first'),
          isError: true);
      return;
    }
    setState(() => _saving = true);

    // `needs` value, if the chosen segment/trigger asked for one.
    final needsKey = _selectedNeeds();
    final params = <String, dynamic>{};
    if (needsKey != null && _needsCtrl.text.trim().isNotEmpty) {
      final raw = _needsCtrl.text.trim();
      // zone_id / days / hours / limit are all numeric on the backend; send a
      // number when it parses so jsonb carries the right type.
      params[needsKey] = int.tryParse(raw) ?? raw;
    }

    // A saved segment is a THIRD kind of audience, not a variant of the second:
    // audience_kind is the literal 'saved' and the only param is the segment's
    // id. The rules behind that id live in the segment, so the campaign never
    // carries a copy of them that could drift.
    String? audienceKind = _triggerKey != null ? null : _audienceKey;
    if (_triggerKey == null && _savedAudienceId != null) {
      audienceKind = 'saved';
      params
        ..clear()
        ..['audience_id'] = _savedAudienceId;
    }

    try {
      final res = await (widget.saveRpc ?? waCampaignSave)({
        'p_id': _campaignId,
        'p_name': _nameCtrl.text.trim(),
        'p_template_id': (_template?['id'] ?? '').toString(),
        'p_audience_kind': audienceKind,
        'p_audience_params': params,
        'p_variable_map': _vars.map((v) => v.value(_tokens)).toList(),
        'p_link_target': _linkCtrl.text.trim().isEmpty
            ? null
            : _linkCtrl.text.trim(),
        'p_trigger_kind': _triggerKey,
        'p_scheduled_at': null,
        'p_throttle': int.tryParse(_throttleCtrl.text.trim()) ?? 60,
        // Empty budget field == no cap. Not 0 — 0 would be a cap of nothing.
        'p_budget_inr': _budgetCtrl.text.trim().isEmpty
            ? null
            : num.tryParse(_budgetCtrl.text.trim()),
        'p_holdout_pct': _holdoutPct.round(),
        'p_repeat_kind': _repeatKind,
        'p_repeat_interval': int.tryParse(_repeatIntervalCtrl.text.trim()),
        // Sent as the form holds them, whatever kind is selected. Which of
        // these matter for 'weekly' vs 'monthly' is the backend's call, not a
        // second opinion assembled here.
        'p_repeat_days_of_week': _repeatDays.isEmpty
            ? null
            : (_repeatDays.toList()..sort()),
        'p_repeat_day_of_month': int.tryParse(_repeatDomCtrl.text.trim()),
        'p_repeat_until': _repeatUntil?.toUtc().toIso8601String(),
        'p_repeat_max_runs': int.tryParse(_repeatMaxRunsCtrl.text.trim()),
      });
      if (!mounted) return;

      if (res['ok'] != true) {
        // template_not_approved / locked / template_required / not_authorized —
        // the backend's message, not a translation of its error code.
        setState(() => _saving = false);
        final msg = (res['message'] ?? res['error'] ?? '').toString();
        showToast(context, msg, isError: true);
        return;
      }

      final campaign = (res['campaign'] as Map?) ?? const {};
      final blank = int.tryParse((res['blank_values'] ?? '').toString()) ?? 0;
      final taken = int.tryParse((res['holdout_taken'] ?? '').toString()) ?? 0;
      setState(() {
        _campaignId = (campaign['id'] ?? _campaignId ?? '').toString();
        // blank_values > 0 means some recipients resolve a variable to nothing.
        // The send is still allowed — the backend said ok — so this is a
        // banner, not a gate.
        _blankWarning = blank > 0
            ? (res['blank_warning'] ?? campaign['blank_warning'] ?? '')
                .toString()
            : '';
        // Asked for a control group and got none. The backend refuses on a
        // small audience and says why; that sentence is the whole explanation
        // and this file adds nothing to it.
        _holdoutNote = (_holdoutPct > 0 && taken == 0)
            ? (res['message'] ?? '').toString()
            : '';
        _saving = false;
      });
      // ALWAYS preflight after a save. A save that succeeded is not a campaign
      // that can send.
      await _runPreflight();
      if (mounted) showToast(context, c('wa_campaign_builder_screen.saved'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showToast(context, e.toString(), isError: true);
    }
  }

  Future<void> _runPreflight() async {
    final id = _campaignId;
    if (id == null || id.isEmpty) return;
    try {
      final res = await (widget.preflightRpc ?? waCampaignPreflight)(id);
      if (!mounted) return;
      final errors = ((res['errors'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
      final recipients = int.tryParse((res['recipients'] ?? '0').toString()) ?? 0;
      setState(() {
        _preflightErrors = errors;
        _preflightRan = true;
        _recipients = recipients;
      });
      await _refreshEstimate(recipients);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _preflightErrors = [e.toString()];
        _preflightRan = true;
      });
    }
  }

  /// The cost line. recipients comes from preflight (the count that survived
  /// suppression and the frequency cap), the rate from the template's category.
  /// Neither number is multiplied here — wa_campaign_estimate() returns the
  /// finished sentence.
  Future<void> _refreshEstimate(int recipients) async {
    if (_category.isEmpty) return;
    try {
      final est = await (widget.estimateRpc ?? waCampaignEstimate)(
          recipients, _category);
      if (!mounted) return;
      setState(() => _estimateLabel = (est['label'] ?? '').toString());
    } catch (_) {
      // A missing cost line is not worth failing the screen over.
    }
  }

  String? _selectedNeeds() {
    final list = _triggerKey != null ? widget.triggers : widget.audiences;
    final key = _triggerKey ?? _audienceKey;
    if (key == null) return null;
    for (final e in list) {
      if (e is Map && e['key'] == key) {
        final n = (e['needs'] ?? '').toString();
        return n.isEmpty ? null : n;
      }
    }
    return null;
  }

  Future<void> _schedule() async {
    final id = _campaignId;
    if (id == null) return;
    final picked = await showWaSchedulePicker(context);
    if (picked == null || !mounted) return;
    try {
      final res =
          await (widget.scheduleRpc ?? waCampaignSchedule)(id, picked.at);
      if (!mounted) return;
      if (res['error'] == 'preflight_failed') {
        setState(() {
          _preflightErrors = ((res['issues'] as List?) ?? const [])
              .map((e) => e.toString())
              .toList();
          _preflightRan = true;
        });
        return;
      }
      if (res['ok'] != true) {
        showToast(context, (res['message'] ?? res['error'] ?? '').toString(),
            isError: true);
        return;
      }
      final est = (res['estimate'] as Map?) ?? const {};
      showToast(
        context,
        [
          (res['message'] ?? '').toString(),
          if ((est['label'] ?? '').toString().isNotEmpty)
            (est['label']).toString(),
        ].where((s) => s.isNotEmpty).join(' · '),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    }
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kCard,
        elevation: 0,
        foregroundColor: _kText,
        title: Text(
          widget.campaign == null ? 'New campaign' : 'Edit campaign',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: _kBorder),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation(_kGreen)))
          : _loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_loadError!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 13, color: _kMuted)),
                        const SizedBox(height: 14),
                        ElevatedButton(
                          onPressed: _load,
                          style: ElevatedButton.styleFrom(
                              backgroundColor: _kGreen,
                              foregroundColor: Colors.white),
                          child: Text(c('wa_campaign_builder_screen.retry')),
                        ),
                      ],
                    ),
                  ),
                )
              : _form(),
    );
  }

  Widget _form() => ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
        children: [
          _card(
            'Name',
            [
              TextField(
                controller: _nameCtrl,
                decoration: _dec('Campaign name'),
              ),
            ],
          ),
          _card('1 · Template', [_templateStep()]),
          _card('2 · Audience', [_audienceStep()]),
          _card('3 · Variables', [_variablesStep()]),
          _card('4 · Tracking link', [_linkStep()]),
          _card('5 · Schedule', [_scheduleStep()]),
          _card('Budget', [_budgetStep()]),
          _card('Hold back', [_holdoutStep()]),
          _card('Repeat', [_repeatStep()]),
          WaWarnBanner(text: _blankWarning),
          WaWarnBanner(text: _holdoutNote),
          if (_preflightRan) _preflightCard(),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _kGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: _saving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation(Colors.white)))
                      : const Icon(Icons.save_outlined, size: 17),
                  label: Text(c('wa_campaign_builder_screen.save')),
                ),
              ),
              if (_campaignId != null) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => showWaDryRunSheet(
                    context,
                    campaignId: _campaignId!,
                    dryRunRpc: widget.dryRunRpc,
                  ),
                  icon: const Icon(Icons.science_outlined, size: 16),
                  label: Text(c('wa_campaign_builder_screen.dry_run')),
                ),
              ],
            ],
          ),
          if (_campaignId != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                // Disabled while preflight has anything to say. This is the
                // guard that stops a send Meta would reject wholesale.
                onPressed: _canSchedule ? _schedule : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kGreen,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFFE5E7EB),
                  disabledForegroundColor: const Color(0xFF9CA3AF),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.schedule_send_outlined, size: 17),
                label: Text(c('wa_campaign_builder_screen.schedule')),
              ),
            ),
          ],
        ],
      );

  Widget _card(String title, List<Widget> children) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _kCard,
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: _kText)),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      );

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      );

  // Step 1 ─────────────────────────────────────────────────────────────────
  Widget _templateStep() {
    if (_templates.isEmpty) {
      return Text(
        c('wa_campaign_builder_screen.no_approved_template'),
        style: const TextStyle(fontSize: 12.5, height: 1.4, color: _kMuted),
      );
    }
    return Column(
      children: [
        for (final t in _templates)
          InkWell(
            onTap: () => _selectTemplate(t),
            child: Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _template?['id'] == t['id']
                    ? const Color(0xFFF0FDF4)
                    : Colors.white,
                border: Border.all(
                    color: _template?['id'] == t['id'] ? _kGreen : _kBorder),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((t['name'] ?? '').toString(),
                            style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: _kText)),
                        const SizedBox(height: 4),
                        Wrap(spacing: 5, children: [
                          if ((t['language'] ?? '').toString().isNotEmpty)
                            WaPlainChip(label: (t['language']).toString()),
                          if ((t['category_label'] ?? t['category'] ?? '')
                              .toString()
                              .isNotEmpty)
                            WaPlainChip(
                                label: (t['category_label'] ?? t['category'])
                                    .toString()),
                        ]),
                      ],
                    ),
                  ),
                  if (_template?['id'] == t['id'])
                    const Icon(Icons.check_circle, size: 18, color: _kGreen),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // Step 2 ─────────────────────────────────────────────────────────────────
  Widget _audienceStep() {
    final needs = _selectedNeeds();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_savedSegments.isNotEmpty) ...[
          Text(c('wa_campaign_builder_screen.saved_segment'),
              style: const TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w600, color: _kMuted)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in _savedSegments)
                ChoiceChip(
                  // name and match_label are the segment's own words. The chip
                  // never states how many people match — `matches` is a live
                  // count on the segments screen, and a stale copy pinned here
                  // would be a second answer to it.
                  label: Text(
                    [
                      (s['name'] ?? '').toString(),
                      (s['match_label'] ?? '').toString(),
                    ].where((e) => e.isNotEmpty).join(' · '),
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: _savedAudienceId == (s['id'] ?? '').toString(),
                  onSelected: (_) => setState(() {
                    _savedAudienceId = (s['id'] ?? '').toString();
                    _audienceKey = null;
                    _triggerKey = null;
                    _needsCtrl.clear();
                    _preflightRan = false;
                  }),
                  selectedColor: const Color(0xFFD1FAE5),
                  backgroundColor: const Color(0xFFF9FAFB),
                  side: const BorderSide(color: _kBorder),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        Text(c('wa_campaign_builder_screen.segment'),
            style: const TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w600, color: _kMuted)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final a in widget.audiences.whereType<Map>())
              ChoiceChip(
                label: Text((a['label'] ?? '').toString(),
                    style: const TextStyle(fontSize: 12)),
                selected: _audienceKey == a['key'],
                onSelected: (_) => setState(() {
                  _audienceKey = (a['key'] ?? '').toString();
                  // Mutually exclusive: a campaign is a segment blast OR a
                  // trigger, never both. wa_campaign_materialize() ignores
                  // audience_kind entirely once trigger_kind is set, so
                  // leaving both selected would show an audience that is not
                  // the one that sends.
                  _triggerKey = null;
                  _savedAudienceId = null;
                  _needsCtrl.clear();
                }),
                selectedColor: const Color(0xFFD1FAE5),
                backgroundColor: const Color(0xFFF9FAFB),
                side: const BorderSide(color: _kBorder),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(c('wa_campaign_builder_screen.trigger'),
            style: const TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w600, color: _kMuted)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in widget.triggers.whereType<Map>())
              ChoiceChip(
                label: Text((t['label'] ?? '').toString(),
                    style: const TextStyle(fontSize: 12)),
                selected: _triggerKey == t['key'],
                onSelected: (_) => setState(() {
                  _triggerKey = (t['key'] ?? '').toString();
                  _audienceKey = null;
                  _savedAudienceId = null;
                  _needsCtrl.clear();
                }),
                selectedColor: const Color(0xFFD1FAE5),
                backgroundColor: const Color(0xFFF9FAFB),
                side: const BorderSide(color: _kBorder),
              ),
          ],
        ),
        // Exactly one extra input, and only when the chosen entry asked for
        // one. The KEY is the backend's ('zone_id' | 'days' | 'hours' |
        // 'limit') and is sent back under that same key.
        if (needs != null) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _needsCtrl,
            keyboardType: TextInputType.number,
            decoration: _dec(needs),
          ),
        ],
      ],
    );
  }

  // Step 3 ─────────────────────────────────────────────────────────────────
  Widget _variablesStep() {
    if (_template == null) {
      return Text(c('wa_campaign_builder_screen.pick_a_template_first'),
          style: const TextStyle(fontSize: 12.5, color: _kMuted));
    }
    if (_vars.isEmpty) {
      return Text(c('wa_campaign_builder_screen.this_template_has_no_variables'),
          style: const TextStyle(fontSize: 12.5, color: _kMuted));
    }
    return Column(
      children: [
        for (var i = 0; i < _vars.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _varRow(i),
          ),
      ],
    );
  }

  Widget _varRow(int i) {
    final row = _vars[i];
    final token = _tokenFor(row.tokenKey);
    final example = (token?['example'] ?? '').toString();
    // The fixed-text option is a token like any other — wa_template_tokens()
    // ships it as 'custom' with an empty example, so this file does not decide
    // that "custom means type your own", the payload does.
    final isCustom = row.tokenKey != null && example.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('{{${i + 1}}}',
            style: const TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w700, color: _kMuted)),
        const SizedBox(height: 5),
        DropdownButtonFormField<String>(
          initialValue: row.tokenKey,
          isExpanded: true,
          decoration: _dec('Choose a value'),
          items: [
            for (final t in _tokens)
              DropdownMenuItem(
                value: (t['key'] ?? '').toString(),
                child: Text((t['label'] ?? '').toString(),
                    style: const TextStyle(fontSize: 13)),
              ),
          ],
          onChanged: (v) => setState(() {
            row.tokenKey = v;
            _preflightRan = false;
          }),
        ),
        if (example.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('e.g. $example',
                style: const TextStyle(fontSize: 11.5, color: _kMuted)),
          ),
        if (isCustom)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextField(
              controller: row.textCtrl,
              decoration: _dec('Fixed text'),
              onChanged: (_) => _preflightRan = false,
            ),
          ),
      ],
    );
  }

  Map<String, dynamic>? _tokenFor(String? key) {
    if (key == null) return null;
    for (final t in _tokens) {
      if (t['key'] == key) return t;
    }
    return null;
  }

  // Step 4 ─────────────────────────────────────────────────────────────────
  Widget _linkStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _linkCtrl,
            decoration: _dec('https://medibo.in/catalogue'),
            onChanged: (_) => _preflightRan = false,
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline, size: 14, color: _kAmber),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  c('wa_campaign_builder_screen.tracking_needs_url_button'),
                  style: const TextStyle(
                      fontSize: 11.5, height: 1.35, color: _kAmber),
                ),
              ),
            ],
          ),
        ],
      );

  // Step 5 ─────────────────────────────────────────────────────────────────
  Widget _scheduleStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _throttleCtrl,
            keyboardType: TextInputType.number,
            decoration: _dec('Messages per minute'),
          ),
          const SizedBox(height: 8),
          Text(
            c('wa_campaign_builder_screen.sending_starts_automatically'),
            style: const TextStyle(fontSize: 11.5, height: 1.35, color: _kMuted),
          ),
          if (_estimateLabel.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.payments_outlined, size: 16, color: _kGreen),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(_estimateLabel,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: _kGreen)),
                ),
              ],
            ),
          ],
        ],
      );

  // Budget ─────────────────────────────────────────────────────────────────
  /// One optional number. What it buys, when it is reached and what happens
  /// then are all the backend's; this field only carries the cap up.
  Widget _budgetStep() => TextField(
        controller: _budgetCtrl,
        keyboardType: TextInputType.number,
        decoration: _dec('₹'),
        onChanged: (_) => _preflightRan = false,
      );

  // Hold back ──────────────────────────────────────────────────────────────
  /// 0–50%. The slider states an INTENTION; holdout_taken in the save response
  /// states what actually happened, and when those disagree the backend's
  /// message is printed instead of a number this file made up.
  Widget _holdoutStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Slider(
            value: _holdoutPct.clamp(0, 50),
            min: 0,
            max: 50,
            divisions: 50,
            activeColor: _kGreen,
            label: '${_holdoutPct.round()}',
            onChanged: (v) => setState(() {
              _holdoutPct = v;
              _preflightRan = false;
            }),
          ),
          Text('${_holdoutPct.round()}',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: _kText)),
        ],
      );

  // Repeat ─────────────────────────────────────────────────────────────────
  /// The four kinds are the values p_repeat_kind accepts, printed as
  /// themselves. Weekday numbers are the backend's convention (0 = Sunday) and
  /// are sent as numbers, never as the day names drawn beside them.
  Widget _repeatStep() {
    const kinds = ['none', 'daily', 'weekly', 'monthly'];
    const dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final k in kinds)
              ChoiceChip(
                label: Text(k, style: const TextStyle(fontSize: 12)),
                selected: _repeatKind == k,
                onSelected: (_) => setState(() {
                  _repeatKind = k;
                  _preflightRan = false;
                }),
                selectedColor: const Color(0xFFD1FAE5),
                backgroundColor: const Color(0xFFF9FAFB),
                side: const BorderSide(color: _kBorder),
              ),
          ],
        ),
        if (_repeatKind != 'none') ...[
          const SizedBox(height: 12),
          TextField(
            controller: _repeatIntervalCtrl,
            keyboardType: TextInputType.number,
            decoration: _dec('Every'),
          ),
        ],
        if (_repeatKind == 'weekly') ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var d = 0; d < dayNames.length; d++)
                FilterChip(
                  label: Text(dayNames[d],
                      style: const TextStyle(fontSize: 12)),
                  selected: _repeatDays.contains(d),
                  onSelected: (on) => setState(() {
                    if (on) {
                      _repeatDays.add(d);
                    } else {
                      _repeatDays.remove(d);
                    }
                  }),
                  selectedColor: const Color(0xFFD1FAE5),
                  backgroundColor: const Color(0xFFF9FAFB),
                  side: const BorderSide(color: _kBorder),
                ),
            ],
          ),
        ],
        if (_repeatKind == 'monthly') ...[
          const SizedBox(height: 12),
          TextField(
            controller: _repeatDomCtrl,
            keyboardType: TextInputType.number,
            decoration: _dec('Day of month'),
          ),
        ],
        if (_repeatKind != 'none') ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final now = DateTime.now();
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _repeatUntil ?? now,
                      firstDate: now,
                      lastDate: now.add(const Duration(days: 730)),
                    );
                    if (d != null) setState(() => _repeatUntil = d);
                  },
                  icon: const Icon(Icons.event_outlined, size: 15),
                  label: Text(
                    _repeatUntil == null
                        ? 'Until'
                        : _repeatUntil!.toIso8601String().substring(0, 10),
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _repeatMaxRunsCtrl,
                  keyboardType: TextInputType.number,
                  decoration: _dec('Max runs'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _preflightCard() => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _preflightErrors.isEmpty
              ? const Color(0xFFF0FDF4)
              : const Color(0xFFFEF2F2),
          border: Border.all(
              color: _preflightErrors.isEmpty
                  ? const Color(0xFFBBF7D0)
                  : const Color(0xFFFECACA)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _preflightErrors.isEmpty ? 'Ready to schedule' : 'Fix before sending',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _preflightErrors.isEmpty ? _kGreen : _kRed,
              ),
            ),
            const SizedBox(height: 6),
            if (_preflightErrors.isEmpty)
              Text(
                  cf('wa_campaign_builder_screen.recipients',
                      {'a': '$_recipients'}),
                  style: const TextStyle(fontSize: 12.5, color: _kMuted))
            else
              waPreflightErrors(_preflightErrors),
          ],
        ),
      );
}

class _VarRow {
  String? tokenKey;
  final TextEditingController textCtrl = TextEditingController();

  /// What goes into p_variable_map — an ARRAY OF STRINGS.
  ///
  /// wa_render_vars() takes each string and replaces {{token_key}} with that
  /// recipient's value, so a bound row sends the literal "{{customer_name}}"
  /// and a fixed-text row sends its text unchanged. Anything else (a JSON
  /// object, a bare key) silently renders as itself in the customer's message.
  String value(List<Map<String, dynamic>> tokens) {
    final key = tokenKey;
    if (key == null) return '';
    for (final t in tokens) {
      if (t['key'] == key) {
        final example = (t['example'] ?? '').toString();
        if (example.isEmpty) return textCtrl.text.trim();
        return '{{$key}}';
      }
    }
    return '{{$key}}';
  }
}

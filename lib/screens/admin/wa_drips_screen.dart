// CHANGE — drip sequences for WhatsApp.
//
// /admin/wa-drips — a named sequence of templates sent N days apart, with an
// exit condition ("stop the moment they order"). A campaign fires once; a
// sequence keeps a person moving through steps until they exit or finish.
//
// Everything on this screen that reads like a sentence is one the backend
// wrote: status_label / status_tone, audience_label, exit_label, and each
// step's delay_label. The app never says "Day 3" — it prints delay_label,
// because the rule that turns 3 into those words lives beside the cron that
// obeys it.
//
// The three lifecycle buttons are gated on can_start / can_pause / can_stop,
// never on `status`. A sequence can be paused for reasons that have nothing to
// do with the status an admin sees (a template falling out of approval at Meta,
// the send window closing), and only the backend knows all of them.
//
// The step editor deliberately does NOT pre-filter the template list to
// approved templates. wa_drip_step_save() refuses a non-approved template and
// explains why; hiding those templates here would replace that explanation
// with a silence, and the admin would be left wondering where the template
// went.
import 'package:flutter/material.dart';

import '../../features/whatsapp/data/wa_campaign_api.dart';
import '../../features/whatsapp/ui/wa_campaign_chips.dart';
import '../../services/ui_copy.dart' as uicopy;
import '../../utils/render_log.dart';
import '../../utils/toast.dart';

const _kGreen = Color(0xFF1B7A43);
const _kBg = Color(0xFFF5F6F8);
const _kCard = Colors.white;
const _kBorder = Color(0xFFE5E7EB);
const _kText = Color(0xFF111827);
const _kMuted = Color(0xFF6B7280);
const _kRed = Color(0xFFB91C1C);

class WaDripsScreen extends StatefulWidget {
  final WaDripsScreenRpc? screenRpc;
  final WaDripSaveRpc? saveRpc;
  final WaDripStepSaveRpc? stepSaveRpc;
  final WaDripActionRpc? actionRpc;
  final WaTemplatesScreenRpc? templatesRpc;
  final WaAudiencesScreenRpc? audiencesRpc;

  const WaDripsScreen({
    super.key,
    this.screenRpc,
    this.saveRpc,
    this.stepSaveRpc,
    this.actionRpc,
    this.templatesRpc,
    this.audiencesRpc,
  });

  @override
  State<WaDripsScreen> createState() => _WaDripsScreenState();
}

class _WaDripsScreenState extends State<WaDripsScreen> {
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
      final res = await (widget.screenRpc ?? waDripsScreen)();
      if (!mounted) return;
      final err = waPayloadError(res);
      setState(() {
        _loading = false;
        _error = err;
        _payload = err == null ? res : null;
      });
      if (err == null) {
        try {
          RenderLog.write(
              'wa_drips_screen', 'rows=${(res['rows'] as List?)?.length ?? 0}');
        } catch (_) {}
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  List<Map<String, dynamic>> get _rows =>
      ((_payload?['rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  Future<void> _runAction(Map<String, dynamic> d, String action) async {
    try {
      final res = await (widget.actionRpc ?? waDripAction)(
          (d['id'] ?? '').toString(), action);
      if (!mounted) return;
      final err = waPayloadError(res);
      if (err != null) {
        showToast(context, err, isError: true);
        return;
      }
      // steps_affected / people_affected are the backend's account of what the
      // action actually moved. Reported only when it moved something — a zero
      // is not news worth a toast.
      final steps = int.tryParse((res['steps_affected'] ?? '').toString()) ?? 0;
      final people =
          int.tryParse((res['people_affected'] ?? '').toString()) ?? 0;
      if (steps > 0 || people > 0) {
        showToast(
            context,
            uicopy.cf('wa_drips.toast_affected',
                {'steps': '$steps', 'people': '$people'}));
      }
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    }
  }

  Future<void> _openEditor({Map<String, dynamic>? drip}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WaDripEditor(
          drip: drip,
          saveRpc: widget.saveRpc,
          audiencesRpc: widget.audiencesRpc,
        ),
      ),
    );
    if (saved == true) _load();
  }

  Future<void> _openStepEditor(Map<String, dynamic> d,
      {Map<String, dynamic>? step}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WaDripStepEditor(
          dripId: (d['id'] ?? '').toString(),
          step: step,
          nextStepNo: ((d['steps'] as List?) ?? const []).length + 1,
          stepSaveRpc: widget.stepSaveRpc,
          templatesRpc: widget.templatesRpc,
        ),
      ),
    );
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kCard,
        elevation: 0,
        foregroundColor: _kText,
        title: Text(uicopy.c('wa_drips.title'),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: _kBorder),
        ),
        actions: [
          IconButton(
            tooltip: uicopy.c('wa_drips.refresh_tooltip'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: _payload == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openEditor(),
              backgroundColor: _kGreen,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: Text(uicopy.c('wa_drips.new_sequence')),
            ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
            strokeWidth: 2.5, valueColor: AlwaysStoppedAnimation(_kGreen)),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 36, color: _kRed),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: _kMuted)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _load,
                style: ElevatedButton.styleFrom(
                    backgroundColor: _kGreen, foregroundColor: Colors.white),
                child: Text(uicopy.c('wa_drips.retry')),
              ),
            ],
          ),
        ),
      );
    }

    final rows = _rows;
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            (_payload?['empty_copy'] ?? '').toString(),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13.5, height: 1.4, color: _kMuted),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        children: [
          for (final d in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: WaDripCard(
                d: d,
                onStart: () => _runAction(d, 'start'),
                onPause: () => _runAction(d, 'pause'),
                onStop: () => _runAction(d, 'stop'),
                onEdit: () => _openEditor(drip: d),
                onAddStep: () => _openStepEditor(d),
                onEditStep: (s) => _openStepEditor(d, step: s),
              ),
            ),
        ],
      ),
    );
  }
}

/// One sequence: its status, its audience, its exit rule, its steps as a
/// timeline, and how many people are in each of the three states.
class WaDripCard extends StatelessWidget {
  final Map<String, dynamic> d;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onStop;
  final VoidCallback onEdit;
  final VoidCallback onAddStep;
  final void Function(Map<String, dynamic> step) onEditStep;

  const WaDripCard({
    super.key,
    required this.d,
    required this.onStart,
    required this.onPause,
    required this.onStop,
    required this.onEdit,
    required this.onAddStep,
    required this.onEditStep,
  });

  String _v(String k) => (d[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final steps = ((d['steps'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

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
                child: Text(_v('name'),
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: _kText)),
              ),
              const SizedBox(width: 8),
              WaToneChip(
                  label: _v('status_label'), tone: d['status_tone']?.toString()),
            ],
          ),
          const SizedBox(height: 8),
          _metaRow(Icons.people_outline, _v('audience_label')),
          _metaRow(Icons.logout_outlined, _v('exit_label')),
          if (steps.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final s in steps) _stepTile(s),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              _stat('Active', _v('active')),
              const SizedBox(width: 20),
              _stat('Exited', _v('exited')),
              const SizedBox(width: 20),
              _stat('Completed', _v('completed')),
            ],
          ),
          const SizedBox(height: 8),
          const Divider(height: 1, color: _kBorder),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              // Strictly flag-gated. A missing flag is a false, never a guess
              // from `status`.
              if (d['can_start'] == true)
                _action(Icons.play_arrow_outlined, 'Start', onStart,
                    primary: true),
              if (d['can_pause'] == true)
                _action(Icons.pause_circle_outline, 'Pause', onPause),
              if (d['can_stop'] == true)
                _action(Icons.stop_circle_outlined, 'Stop', onStop,
                    danger: true),
              _action(Icons.edit_outlined, 'Edit', onEdit),
              _action(Icons.add, 'Add step', onAddStep),
            ],
          ),
        ],
      ),
    );
  }

  /// delay_label carries the whole "when" ("Day 3", "immediately"); `sent` is
  /// how many have gone through this step so far.
  Widget _stepTile(Map<String, dynamic> s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: InkWell(
          onTap: () => onEditStep(s),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF9FAFB),
              border: Border.all(color: _kBorder),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: Color(0xFFD1FAE5),
                    shape: BoxShape.circle,
                  ),
                  child: Text((s['step_no'] ?? '').toString(),
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF065F46))),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text((s['template'] ?? '').toString(),
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: _kText)),
                      if ((s['delay_label'] ?? '').toString().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text((s['delay_label']).toString(),
                              style: const TextStyle(
                                  fontSize: 11.5, color: _kMuted)),
                        ),
                    ],
                  ),
                ),
                WaPlainChip(label: (s['sent'] ?? '').toString()),
              ],
            ),
          ),
        ),
      );

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

  Widget _stat(String caption, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(caption,
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600, color: _kMuted)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: _kText)),
        ],
      );

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

// ── sequence editor ─────────────────────────────────────────────────────────

/// Name, audience, exit rule, throttle. The audience is a saved segment: the
/// rules behind it live in the segment, so a sequence never carries a copy of
/// them that could drift out of step with the segments screen.
class WaDripEditor extends StatefulWidget {
  final Map<String, dynamic>? drip;
  final WaDripSaveRpc? saveRpc;
  final WaAudiencesScreenRpc? audiencesRpc;

  const WaDripEditor({
    super.key,
    this.drip,
    this.saveRpc,
    this.audiencesRpc,
  });

  @override
  State<WaDripEditor> createState() => _WaDripEditorState();
}

class _WaDripEditorState extends State<WaDripEditor> {
  final _nameCtrl = TextEditingController();
  final _windowCtrl = TextEditingController();
  final _throttleCtrl = TextEditingController(text: '60');
  bool _exitOnOrder = true;
  String? _audienceId;
  List<Map<String, dynamic>> _segments = const [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final d = widget.drip;
    if (d != null) _nameCtrl.text = (d['name'] ?? '').toString();
    _loadSegments();
  }

  Future<void> _loadSegments() async {
    try {
      final res = await (widget.audiencesRpc ?? waAudiencesScreen)();
      if (!mounted) return;
      if (waPayloadError(res) != null) return;
      setState(() {
        _segments = ((res['rows'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      });
    } catch (_) {
      // A sequence can still be renamed or re-throttled without the list.
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _windowCtrl.dispose();
    _throttleCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final res = await (widget.saveRpc ?? waDripSave)({
        'p_id': widget.drip?['id'],
        'p_name': _nameCtrl.text.trim(),
        'p_audience_kind': _audienceId == null ? null : 'saved',
        'p_audience_params':
            _audienceId == null ? <String, dynamic>{} : {'audience_id': _audienceId},
        'p_exit_on_order': _exitOnOrder,
        'p_exit_window_days': int.tryParse(_windowCtrl.text.trim()),
        'p_throttle_per_min': int.tryParse(_throttleCtrl.text.trim()),
      });
      if (!mounted) return;
      setState(() => _saving = false);
      final err = waPayloadError(res);
      if (err != null) {
        showToast(context, err, isError: true);
        return;
      }
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showToast(context, e.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: _kBg,
        appBar: AppBar(
          backgroundColor: _kCard,
          elevation: 0,
          foregroundColor: _kText,
          title: Text(
            widget.drip == null ? 'New sequence' : 'Edit sequence',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(1),
            child: Divider(height: 1, color: _kBorder),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
          children: [
            waEditorCard('Name', [
              TextField(controller: _nameCtrl, decoration: waDec('Sequence name')),
            ]),
            waEditorCard('Saved segment', [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in _segments)
                    ChoiceChip(
                      label: Text((s['name'] ?? '').toString(),
                          style: const TextStyle(fontSize: 12)),
                      selected: _audienceId == (s['id'] ?? '').toString(),
                      onSelected: (_) => setState(
                          () => _audienceId = (s['id'] ?? '').toString()),
                      selectedColor: const Color(0xFFD1FAE5),
                      backgroundColor: const Color(0xFFF9FAFB),
                      side: const BorderSide(color: _kBorder),
                    ),
                ],
              ),
            ]),
            waEditorCard('Exit', [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _exitOnOrder,
                activeThumbColor: _kGreen,
                onChanged: (v) => setState(() => _exitOnOrder = v),
                title: Text(uicopy.c('wa_drips.exit_on_order'),
                    style: const TextStyle(fontSize: 13.5)),
              ),
              TextField(
                controller: _windowCtrl,
                keyboardType: TextInputType.number,
                decoration: waDec('Exit window (days)'),
              ),
            ]),
            waEditorCard('Throttle', [
              TextField(
                controller: _throttleCtrl,
                keyboardType: TextInputType.number,
                decoration: waDec('Messages per minute'),
              ),
            ]),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.save_outlined, size: 17),
                label: Text(uicopy.c('wa_drips.save')),
              ),
            ),
          ],
        ),
      );
}

// ── step editor ─────────────────────────────────────────────────────────────

/// One step: its number, how many days after the previous one it goes, which
/// template it sends, and an optional link target.
///
/// The template list is NOT filtered to approved templates — see the file
/// header. wa_drip_step_save()'s refusal is rendered verbatim, so an admin who
/// picks a pending template is told exactly that, by the thing that decided it.
class WaDripStepEditor extends StatefulWidget {
  final String dripId;
  final Map<String, dynamic>? step;
  final int nextStepNo;
  final WaDripStepSaveRpc? stepSaveRpc;
  final WaTemplatesScreenRpc? templatesRpc;

  const WaDripStepEditor({
    super.key,
    required this.dripId,
    this.step,
    this.nextStepNo = 1,
    this.stepSaveRpc,
    this.templatesRpc,
  });

  @override
  State<WaDripStepEditor> createState() => _WaDripStepEditorState();
}

class _WaDripStepEditorState extends State<WaDripStepEditor> {
  final _stepNoCtrl = TextEditingController();
  final _delayCtrl = TextEditingController(text: '0');
  final _linkCtrl = TextEditingController();

  List<Map<String, dynamic>> _templates = const [];
  String? _templateId;
  bool _saving = false;
  String _refusal = '';

  @override
  void initState() {
    super.initState();
    final s = widget.step;
    _stepNoCtrl.text =
        (s?['step_no'] ?? widget.nextStepNo).toString();
    _loadTemplates();
  }

  Future<void> _loadTemplates() async {
    try {
      final res = await (widget.templatesRpc ?? waTemplatesScreen)();
      if (!mounted) return;
      if (waPayloadError(res) != null) return;
      setState(() {
        _templates = ((res['templates'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _stepNoCtrl.dispose();
    _delayCtrl.dispose();
    _linkCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _refusal = '';
    });
    try {
      final res = await (widget.stepSaveRpc ?? waDripStepSave)({
        'p_drip_id': widget.dripId,
        'p_step_no': int.tryParse(_stepNoCtrl.text.trim()),
        'p_delay_days': int.tryParse(_delayCtrl.text.trim()),
        'p_template_id': _templateId,
        'p_variable_map': const <dynamic>[],
        'p_link_target':
            _linkCtrl.text.trim().isEmpty ? null : _linkCtrl.text.trim(),
      });
      if (!mounted) return;
      final err = waPayloadError(res);
      setState(() {
        _saving = false;
        // Kept on screen rather than flashed as a toast: the admin has to
        // change the template to get past it.
        _refusal = err ?? '';
      });
      if (err != null) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _refusal = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: _kBg,
        appBar: AppBar(
          backgroundColor: _kCard,
          elevation: 0,
          foregroundColor: _kText,
          title: Text(
            widget.step == null ? 'Add step' : 'Edit step',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(1),
            child: Divider(height: 1, color: _kBorder),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
          children: [
            waEditorCard('Step', [
              TextField(
                controller: _stepNoCtrl,
                keyboardType: TextInputType.number,
                decoration: waDec('Step'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _delayCtrl,
                keyboardType: TextInputType.number,
                decoration: waDec('Delay (days)'),
              ),
            ]),
            waEditorCard('Template', [
              for (final t in _templates)
                InkWell(
                  onTap: () =>
                      setState(() => _templateId = (t['id'] ?? '').toString()),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: _templateId == (t['id'] ?? '').toString()
                          ? const Color(0xFFF0FDF4)
                          : Colors.white,
                      border: Border.all(
                          color: _templateId == (t['id'] ?? '').toString()
                              ? _kGreen
                              : _kBorder),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text((t['name'] ?? '').toString(),
                              style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: _kText)),
                        ),
                        // The template's own status, so the admin can see which
                        // ones the backend is likely to refuse — without this
                        // file deciding on its behalf.
                        WaToneChip(
                            label: (t['status_label'] ?? '').toString(),
                            tone: t['status_tone']?.toString()),
                      ],
                    ),
                  ),
                ),
            ]),
            waEditorCard('Link', [
              TextField(controller: _linkCtrl, decoration: waDec('Link')),
            ]),
            WaWarnBanner(text: _refusal),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.save_outlined, size: 17),
                label: Text(uicopy.c('wa_drips.save')),
              ),
            ),
          ],
        ),
      );
}

// ── shared editor chrome ────────────────────────────────────────────────────

Widget waEditorCard(String title, List<Widget> children) => Container(
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

InputDecoration waDec(String hint) => InputDecoration(
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    );

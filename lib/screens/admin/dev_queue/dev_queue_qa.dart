import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import '../../../utils/toast.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// Bug-Loop Prevention — the QA & Journeys surface.
///
/// THE APP RENDERS. IT NEVER DECIDES. Every label, tone name, severity and
/// status here is a string the backend already computed (dev_cmd_qa_detail);
/// this file only places them on screen and sends taps back.

/// The QA + journey block on a command's detail screen. Renders the command's
/// QA verdict, its findings (severity → tone from the backend) and every
/// journey run with its evidence — plus a Waive button when the backend says
/// the gate may be waived with the deploy PIN.
class QaJourneySection extends StatefulWidget {
  final int id;
  final DevQueueService svc;
  const QaJourneySection({super.key, required this.id, required this.svc});

  @override
  State<QaJourneySection> createState() => _QaJourneySectionState();
}

class _QaJourneySectionState extends State<QaJourneySection> {
  Map<String, dynamic> _d = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.svc.qaDetail(widget.id);
      if (!mounted) return;
      setState(() {
        _d = d;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    if (_d['ok'] != true || _d['qa_required'] != true) {
      return const SizedBox.shrink();
    }
    final findings = _list(_d['findings']);
    final runs = _list(_d['runs']);
    final canWaive = _d['can_waive'] == true;
    final previewLabel = (_d['preview_label'] ?? '').toString();

    return Container(
      margin: EdgeInsets.only(top: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: kBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.verified_outlined, size: Ds.space.x16 + 2, color: kTextLo),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: Text(c('dev_queue.qa_section_title').toUpperCase(),
                style: Ds.t.caption
                    .copyWith(fontWeight: FontWeight.w700, color: kTextLo)),
          ),
          ToneChip(
            label: (_d['qa_status_label'] ?? '').toString(),
            tone: toneByName((_d['qa_status_tone'] ?? 'neutral').toString()),
          ),
        ]),
        if (previewLabel.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Align(
            alignment: Alignment.centerLeft,
            child: ToneChip(
                label: previewLabel,
                tone: toneByName(
                    (_d['preview_status'] == 'promoted') ? 'success' : 'info'),
                icon: Icons.rocket_launch_outlined),
          ),
        ],

        // Findings
        SizedBox(height: Ds.space.x12),
        Text(c('dev_queue.qa_findings_title'),
            style: Ds.t.caption.copyWith(fontWeight: FontWeight.w700)),
        SizedBox(height: Ds.space.x8),
        if (findings.isEmpty)
          Text((_d['findings_empty'] ?? '').toString(),
              style: Ds.t.caption.copyWith(color: kTextLo))
        else
          Column(children: [for (final f in findings) _finding(f)]),

        // Journey runs
        SizedBox(height: Ds.space.x12),
        Text(c('dev_queue.qa_runs_title'),
            style: Ds.t.caption.copyWith(fontWeight: FontWeight.w700)),
        SizedBox(height: Ds.space.x8),
        if (runs.isEmpty)
          Text((_d['runs_empty'] ?? '').toString(),
              style: Ds.t.caption.copyWith(color: kTextLo))
        else
          Column(children: [for (final r in runs) _run(r)]),

        if (canWaive) ...[
          SizedBox(height: Ds.space.x12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => _waive(context),
              icon: Icon(Icons.gpp_maybe_outlined,
                  size: Ds.space.x16, color: Ds.c.danger),
              label: Text(c('dev_queue.qa_waive_btn'),
                  style: Ds.t.body.copyWith(
                      fontWeight: FontWeight.w600, color: Ds.c.danger)),
              style: OutlinedButton.styleFrom(
                  minimumSize: Size(0, Ds.touch.minTarget),
                  side: BorderSide(color: Ds.c.danger)),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _finding(Map<String, dynamic> f) {
    final detail = (f['detail'] ?? '').toString();
    return Semantics(
      identifier: 'qa_finding_${f['id']}',
      child: Container(
        margin: EdgeInsets.only(bottom: Ds.space.x8),
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
          color: kPageBg,
          borderRadius: Ds.r.rButton,
          border: Border.all(color: kBorder),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ToneChip(
                label: (f['severity_label'] ?? '').toString(),
                tone: toneByName((f['severity_tone'] ?? 'neutral').toString())),
            SizedBox(width: Ds.space.x8),
            Expanded(
              child: Text((f['title'] ?? '').toString(),
                  style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
            ),
            SizedBox(width: Ds.space.x8),
            ToneChip(
                label: (f['status_label'] ?? '').toString(),
                tone: toneByName((f['status_tone'] ?? 'neutral').toString())),
          ]),
          if (detail.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(detail, style: Ds.t.caption.copyWith(color: kTextLo)),
          ],
        ]),
      ),
    );
  }

  Widget _run(Map<String, dynamic> r) {
    final duration = (r['duration_display'] ?? '').toString();
    final at = (r['at_display'] ?? '').toString();
    final evidence = r['evidence'];
    final proof = (evidence is Map ? (evidence['db_proof'] ?? '') : '').toString();
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x8),
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: kPageBg,
        borderRadius: Ds.r.rButton,
        border: Border.all(color: kBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text((r['name'] ?? '').toString(),
                style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
          ),
          ToneChip(
              label: (r['status_label'] ?? '').toString(),
              tone: toneByName((r['status_tone'] ?? 'neutral').toString())),
        ]),
        if (duration.isNotEmpty || at.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text([at, duration].where((s) => s.isNotEmpty).join('  ·  '),
              style: Ds.t.caption.copyWith(color: kTextLo)),
        ],
        if (proof.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(proof, style: Ds.t.caption.copyWith(color: kTextLo)),
        ],
      ]),
    );
  }

  Future<void> _waive(BuildContext context) async {
    final ok = await showQaWaiveDialog(context, widget.svc, widget.id);
    if (ok == true) _load();
  }

  List<Map<String, dynamic>> _list(dynamic v) => (v as List?)
          ?.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList() ??
      const [];
}

/// PIN-gated waive dialog. The backend re-checks the PIN and owns the verdict;
/// the app only collects the PIN and renders success/failure copy.
Future<bool?> showQaWaiveDialog(
    BuildContext context, DevQueueService svc, int id) {
  final pin = TextEditingController();
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(c('dev_queue.qa_waive_title'), style: Ds.t.subtitle),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(c('dev_queue.qa_waive_hint'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),
        TextField(
          controller: pin,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
              labelText: c('dev_queue.qa_waive_pin'),
              border: const OutlineInputBorder()),
        ),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(c('dev_queue.cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Ds.c.danger),
          onPressed: () async {
            try {
              final res = await svc.qaWaive(id, pin.text.trim());
              if (!ctx.mounted) return;
              if (res['ok'] == true) {
                Navigator.pop(ctx, true);
                showToast(ctx, c('dev_queue.qa_waive_ok'));
              } else {
                showToast(ctx, c('dev_queue.qa_waive_bad_pin'), isError: true);
              }
            } catch (_) {
              if (ctx.mounted) {
                showToast(ctx, c('dev_queue.qa_waive_bad_pin'), isError: true);
              }
            }
          },
          child: Text(c('dev_queue.qa_waive_submit')),
        ),
      ],
    ),
  );
}

/// "Report a bug" sheet — opened from the Dev Queue header. Om types what broke
/// and picks an area; the backend creates a linked fix command + permanent
/// journey and returns the new command id, which we surface verbatim.
Future<void> showBugReportSheet(BuildContext context, DevQueueService svc,
    {String? defaultArea}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
    builder: (ctx) => _BugReportSheet(svc: svc, defaultArea: defaultArea),
  );
}

class _BugReportSheet extends StatefulWidget {
  final DevQueueService svc;
  final String? defaultArea;
  const _BugReportSheet({required this.svc, this.defaultArea});

  @override
  State<_BugReportSheet> createState() => _BugReportSheetState();
}

class _BugReportSheetState extends State<_BugReportSheet> {
  final _text = TextEditingController();
  List<Map<String, dynamic>> _areas = const [];
  String? _area;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _area = widget.defaultArea;
    _loadAreas();
  }

  Future<void> _loadAreas() async {
    try {
      final a = await widget.svc.areasGet();
      if (!mounted) return;
      setState(() {
        _areas = a;
        _area ??= a.isNotEmpty ? (a.first['area'] ?? '').toString() : null;
      });
    } catch (_) {/* picker just stays on the default */}
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final t = _text.text.trim();
    if (t.isEmpty) {
      showToast(context, c('dev_queue.bug_report_empty'), isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await widget.svc.bugReport(t, _area ?? '');
      if (!mounted) return;
      Navigator.pop(context);
      final id = res['fix_command'];
      showToast(context, cf('dev_queue.bug_report_created', {'id': '$id'}));
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showToast(context, e.toString(), isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x16 + bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.bug_report_outlined, color: kBrand, size: Ds.space.x24),
          SizedBox(width: Ds.space.x8),
          Text(c('dev_queue.bug_report_title'),
              style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700)),
        ]),
        SizedBox(height: Ds.space.x8),
        Text(c('dev_queue.bug_report_hint'),
            style: Ds.t.caption.copyWith(color: kTextLo)),
        SizedBox(height: Ds.space.x16),
        TextField(
          controller: _text,
          autofocus: true,
          minLines: 3,
          maxLines: 6,
          decoration: InputDecoration(
              hintText: c('dev_queue.bug_report_hint'),
              border: const OutlineInputBorder()),
        ),
        SizedBox(height: Ds.space.x12),
        Row(children: [
          Text('${c('dev_queue.bug_report_area')}:',
              style: Ds.t.caption.copyWith(color: kTextLo)),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: DropdownButton<String>(
              value: _area,
              isExpanded: true,
              items: [
                for (final a in _areas)
                  DropdownMenuItem(
                    value: (a['area'] ?? '').toString(),
                    child: Text((a['label'] ?? '').toString(),
                        style: Ds.t.body),
                  ),
              ],
              onChanged: (v) => setState(() => _area = v),
            ),
          ),
        ]),
        SizedBox(height: Ds.space.x16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: kBrand, minimumSize: Size(0, Ds.touch.minTarget)),
            onPressed: _busy ? null : _submit,
            child: Text(c('dev_queue.bug_report_submit'),
                style: Ds.t.body.copyWith(color: Colors.white)),
          ),
        ),
      ]),
    );
  }
}
